import AppKit
import FaroCore
import Observation
import os
import SwiftTerm

/// Una pestaña: su shell, lo que sabemos de ella (carpeta, comando, línea) y sus sugerencias.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum Kind: Equatable {
        case shell
        case agent(AIAgent)
    }

    let id = UUID()
    let kind: Kind
    var cwd: String
    var terminalTitle = ""
    var runningCommand: String?
    var runningSince: Date?
    var atPrompt = false
    var integrationActive = false
    var exited = false
    var hasUnseenActivity = false

    var buffer = ""
    var cursor = 0
    /// Texto seleccionado en la línea (con ⇧ y las flechas, o ⌘A), en caracteres.
    var selection: Range<Int>?
    var lastCommand: String?
    /// El último comando no pudo usar su puerto porque otro proceso lo tiene ocupado.
    var portConflict: PortConflictInfo?
    @ObservationIgnored var portCheck: Task<Void, Never>?
    /// Cada comando con su salida, para resaltarlo y copiarlo como un bloque.
    @ObservationIgnored var blocks = CommandBlocks()
    @ObservationIgnored var blockOverlay: BlockOverlay?
    @ObservationIgnored var viewportCache: ViewportCache?
    /// Ha llegado salida desde la última vez que se miró la pantalla (se escribe desde otro hilo).
    @ObservationIgnored let viewportDirty = OSAllocatedUnfairLock(initialState: true)
    var lastExit: Int32?
    var lastDuration: Int?

    /// Qué hace la IA de esta pestaña, si hay una: trabajando, esperándote o terminada.
    var agentPhase: AgentTracker.Phase = .idle
    var agentScreen = AgentScreen()

    var context = ProjectContext()
    /// Cambios, rama y commits por subir o bajar del repositorio de git de esta carpeta.
    var git: GitStatus?
    @ObservationIgnored var gitTask: Task<Void, Never>?
    var predictions: [Suggestion] = []
    var suggestions: [Suggestion] = []
    var selectedIndex = 0
    var popupVisible = false
    var ghost: String?
    /// Posición del cursor del terminal, en coordenadas del área del terminal (origen arriba a la izquierda).
    var caret: CGRect = .zero

    @ObservationIgnored let view: FaroTerminalView
    /// Contenedor que muestra ahora la vista (ver `TerminalContainer`).
    @ObservationIgnored var hostSerial = 0
    @ObservationIgnored private var tracker = AgentTracker()
    @ObservationIgnored private var agentWatch: Task<Void, Never>?
    @ObservationIgnored private let lastOutput = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    @ObservationIgnored weak var window: TerminalWindowController?
    @ObservationIgnored private var oscToken: TerminalOscObservation?
    @ObservationIgnored private var pendingStartup: String?
    @ObservationIgnored private var typedSinceLastBuffer = false
    @ObservationIgnored private var selectionMoved = false
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored let controlDirectory: URL

    static let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("faro-\(getuid())", isDirectory: true)

    init(directory: String, kind: Kind, startupCommand: String? = nil) {
        self.kind = kind
        self.cwd = directory
        if let startupCommand {
            self.pendingStartup = startupCommand
        } else if case .agent(let agent) = kind {
            self.pendingStartup = agent.launchCommand
        }
        self.controlDirectory = Self.tempRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        self.view = FaroTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        try? FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        view.session = self
        view.processDelegate = self
        refreshContext()
    }

    // MARK: Proceso

    func start() {
        let settings = AppModel.shared.settings
        view.apply(settings: settings, theme: AppModel.shared.theme)
        let env0 = ProcessInfo.processInfo.environment
        let shell = settings.shell.isEmpty ? (env0["SHELL"] ?? "/bin/zsh") : settings.shell
        var env = env0.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Faro"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        if env["LANG"] == nil { env["LANG"] = "es_ES.UTF-8" }
        if AppModel.testMode { env["FARO_NO_HISTORY"] = "1" }
        if (shell as NSString).lastPathComponent == "zsh" {
            env = ShellIntegration.environment(base: env, controlDirectory: controlDirectory, minimalPrompt: settings.minimalPrompt)
        }
        oscToken = view.observeOscEvents { [weak self] event in
            guard event.code == ShellIntegration.oscCode, let shellEvent = ShellEvent(payload: event.payload) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(shellEvent) }
            }
        }
        let lastOutput = self.lastOutput
        let viewportDirty = self.viewportDirty
        view.setProcessOutputHandler {
            MemoryMonitor.shared.noteActivity()
            lastOutput.withLock { $0 = .now }
            viewportDirty.withLock { $0 = true }
        }
        view.startProcess(
            executable: shell,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: cwd
        )
        if pendingStartup != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !self.integrationActive, let command = self.pendingStartup else { return }
                self.pendingStartup = nil
                self.view.send(txt: command + "\r")
            }
        }
    }

    func close() {
        stopWatchingAgent()
        if view.process?.running == true { view.terminate() }
        oscToken = nil
        contextTask?.cancel()
        try? FileManager.default.removeItem(at: controlDirectory)
    }

    // MARK: Eventos de la shell

    func handle(_ event: ShellEvent) {
        integrationActive = true
        switch event {
        case .cwd(let path):
            if path != cwd {
                cwd = path
                refreshContext()
            }
            AppModel.shared.visit(directory: path)
            Workspace.shared.setNeedsSave()
        case .prompt:
            blockPromptShown()
            atPrompt = true
            runningCommand = nil
            runningSince = nil
            updatePredictions()
            if let command = pendingStartup {
                pendingStartup = nil
                run(command)
            }
        case .exec(let command):
            atPrompt = false
            runningCommand = command
            runningSince = Date()
            lastCommand = command
            hideSuggestions()
            AppModel.shared.record(command: command, directory: cwd)
            if AIAgent.detect(command: command) != nil { watchAgent() }
            watchForPortConflict(command)
            blockStarted(command)
            Ports.shared.refresh(after: .seconds(5))
            Workspace.shared.setNeedsSave()
        case .done(let exit, let ms):
            stopWatchingAgent()
            portCheck?.cancel()
            blocks.finish(exit: exit, milliseconds: ms)
            if exit != 0, !Self.wasStopped(exit), let command = lastCommand { checkPortConflict(command) }
            lastExit = exit
            lastDuration = ms
            if let command = lastCommand {
                AppModel.shared.complete(command: command, directory: cwd, exit: exit, milliseconds: ms)
                Notifier.commandFinished(command: command, exit: exit, milliseconds: ms, session: self)
            }
            refreshContext()
            Ports.shared.refresh(after: .milliseconds(600))
            Workspace.shared.setNeedsSave()
        case .buffer(let text, let cursor, let selection):
            buffer = text
            self.cursor = cursor
            self.selection = selection
            updateSuggestions(typed: typedSinceLastBuffer)
            typedSinceLastBuffer = false
        }
    }

    // MARK: Sugerencias

    func noteTyping() { typedSinceLastBuffer = true }

    private func updateSuggestions(typed: Bool) {
        let settings = AppModel.shared.settings
        guard settings.suggestions, atPrompt, !buffer.isEmpty, cursor == buffer.count, !buffer.contains("\n") else {
            hideSuggestions()
            return
        }
        let engine = AppModel.shared.engine(for: context)
        let list = engine.suggestions(buffer: buffer, cwd: cwd)
        suggestions = list
        ghost = settings.ghostText
            ? list.first { $0.replacement.hasPrefix(buffer) && $0.replacement.count > buffer.count }
                .map { String($0.replacement.dropFirst(buffer.count)) }
            : nil
        if typed {
            popupVisible = !list.isEmpty
            selectedIndex = 0
            selectionMoved = false
        } else if !popupVisible || list.isEmpty {
            popupVisible = false
        }
        scheduleCaretUpdate()
    }

    func hideSuggestions() {
        popupVisible = false
        ghost = nil
        suggestions = []
        selectionMoved = false
    }

    func updatePredictions() {
        guard AppModel.shared.settings.suggestions else { predictions = []; return }
        predictions = AppModel.shared.engine(for: context).predictions(cwd: cwd, limit: 3)
    }

    private func scheduleCaretUpdate() {
        for delay in [0.016, 0.06] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.updateCaret() }
            }
        }
    }

    func updateCaret() {
        guard let container = view.superview else { return }
        let rect = container.convert(view.caretFrame, from: view)
        if rect != caret { caret = rect }
    }

    /// Teclas que Faro atiende antes que la shell. Devuelve true si se ha consumido.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let editing = atPrompt && integrationActive

        if let action = Self.editAction(keyCode: event.keyCode, mods: mods) {
            if editing, ghost != nil, cursor == buffer.count, popupVisible == false || !selectionMoved {
                if action == .lineEnd, let ghost { setBuffer(buffer + ghost); return true }
                if action == .wordRight, let ghost { setBuffer(buffer + Self.firstWord(of: ghost)); return true }
            }
            return perform(action)
        }

        if Self.isTyping(event, mods: mods) {
            noteTyping()
            if editing, selection != nil {
                send(.deleteSelection)
                if event.keyCode == 51 { return true }
            }
        } else if editing, selection != nil, mods.isEmpty, (123...126).contains(event.keyCode), !popupVisible {
            send(.deselect)
        }

        guard atPrompt, mods.isEmpty || mods == .shift else { return false }
        switch event.keyCode {
        case 125 where popupVisible:
            selectedIndex = min(selectedIndex + 1, suggestions.count - 1)
            selectionMoved = true
            return true
        case 126 where popupVisible:
            selectedIndex = max(selectedIndex - 1, 0)
            selectionMoved = true
            return true
        case 48 where popupVisible && mods.isEmpty:
            accept(suggestions[safe: selectedIndex])
            return true
        case 124 where ghost != nil && cursor == buffer.count && !selectionMoved && mods.isEmpty:
            if let ghost { setBuffer(buffer + ghost) }
            return true
        case 36, 76:
            if popupVisible && selectionMoved, let s = suggestions[safe: selectedIndex] {
                accept(s)
                return true
            }
            hideSuggestions()
            return false
        case 53 where popupVisible || ghost != nil:
            hideSuggestions()
            return true
        default:
            return false
        }
    }

    /// Atajos de edición de texto de macOS: ⌘⌫, ⌥⌫, ⌘←, ⌥→, ⇧ para seleccionar, ⌘Z…
    static func editAction(keyCode: UInt16, mods: NSEvent.ModifierFlags) -> EditAction? {
        switch (keyCode, mods) {
        case (51, .command): .deleteToLineStart
        case (117, .command): .deleteToLineEnd
        case (51, .option): .deleteWordLeft
        case (117, .option): .deleteWordRight
        case (123, .command), (115, []): .lineStart
        case (124, .command), (119, []): .lineEnd
        case (123, .option): .wordLeft
        case (124, .option): .wordRight
        case (123, .shift): .selectLeft
        case (124, .shift): .selectRight
        case (123, [.shift, .option]): .selectWordLeft
        case (124, [.shift, .option]): .selectWordRight
        case (123, [.shift, .command]), (115, .shift): .selectToLineStart
        case (124, [.shift, .command]), (119, .shift): .selectToLineEnd
        case (6, .command): .undo
        case (6, [.command, .shift]): .redo
        default: nil
        }
    }

    /// En la shell de Faro, la acción exacta; en otros programas (Claude Code, ssh…) su
    /// equivalente de readline; en pantallas completas (vim, htop) la tecla sigue su curso normal.
    @discardableResult
    func perform(_ action: EditAction) -> Bool {
        if atPrompt && integrationActive {
            send(action)
            return true
        }
        guard view.terminalInputStateSnapshot()?.isAlternateBuffer != true, let bytes = action.readlineFallback else { return false }
        view.send(data: bytes[...])
        return true
    }

    private func send(_ action: EditAction) {
        view.send(data: action.sequence[...])
    }

    static func firstWord(of text: String) -> String {
        var out = ""
        var seenWord = false
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if seenWord && !isWord { break }
            if isWord { seenWord = true }
            out.append(ch)
        }
        return out
    }

    // MARK: Selección en la línea

    var selectedPromptText: String? {
        guard let selection, atPrompt else { return nil }
        let chars = Array(buffer)
        guard selection.lowerBound >= 0, selection.upperBound <= chars.count else { return nil }
        return String(chars[selection])
    }

    func copyPromptSelection(cut: Bool = false) -> Bool {
        guard let text = selectedPromptText, !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if cut { send(.deleteSelection) }
        return true
    }

    func selectWholeLine() -> Bool {
        guard atPrompt, integrationActive, !buffer.isEmpty else { return false }
        send(.selectAll)
        return true
    }

    /// Letras, números, símbolos (también con Mayúsculas u Opción) y borrar cuentan como escribir;
    /// flechas, atajos y teclas de función no.
    private static func isTyping(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 51 { return mods.isEmpty }
        guard mods.subtracting([.shift, .option]).isEmpty, let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy { s in
            !CharacterSet.controlCharacters.contains(s) && !(0xF700...0xF8FF).contains(s.value)
        }
    }

    func accept(_ suggestion: Suggestion?) {
        guard let suggestion else { return }
        setBuffer(suggestion.replacement)
        typedSinceLastBuffer = suggestion.isDirectory
    }

    // MARK: Control de la shell

    @discardableResult
    private func control(_ op: String, _ argument: String) -> Bool {
        guard integrationActive, atPrompt else { return false }
        let url = controlDirectory.appendingPathComponent("request")
        do {
            try (op + "\n" + argument).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        view.send(data: ShellIntegration.controlKey[...])
        return true
    }

    func setBuffer(_ text: String) {
        if !control("setbuf", text) && atPrompt {
            view.send(txt: "\u{15}" + text)
        }
    }

    func run(_ command: String) {
        hideSuggestions()
        hideBlock()
        if !control("run", command) {
            view.send(txt: "\u{15}" + command + "\r")
        }
    }

    /// Ir a una carpeta sin escribir `cd`. Si hay un programa en marcha, se abre en una pestaña nueva.
    func navigate(to path: String) {
        guard path != cwd else { return }
        if atPrompt && control("cd", path) { return }
        if atPrompt {
            view.send(txt: "\u{15} cd " + Tokenizer.escape(path) + "\r")
        } else {
            window?.newTab(directory: path)
        }
    }

    // MARK: Contexto del proyecto

    func refreshContext() {
        contextTask?.cancel()
        let dir = cwd
        contextTask = Task { [weak self] in
            let ctx = await Task.detached(priority: .utility) { ProjectDetector.detect(directory: dir) }.value
            guard !Task.isCancelled, let self, self.cwd == dir else { return }
            if ctx != self.context { self.context = ctx }
            self.updatePredictions()
            self.refreshGit(after: .zero)
        }
    }

    // MARK: Git

    nonisolated static let gitExecutable = GitStatus.executable()

    /// Relee `git status` (unos milisegundos, en segundo plano). Solo se llama cuando algo puede
    /// haber cambiado: al cambiar de carpeta, al terminar un comando o una IA, al volver a Faro.
    func refreshGit(after delay: Duration = .milliseconds(200)) {
        gitTask?.cancel()
        guard context.gitRoot != nil, let git = Self.gitExecutable else {
            if self.git != nil { self.git = nil }
            return
        }
        let dir = cwd
        gitTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let status = await Task.detached(priority: .utility) { GitStatus.read(directory: dir, git: git) }.value
            guard !Task.isCancelled, let self, self.cwd == dir else { return }
            if status != self.git { self.git = status }
        }
    }

    // MARK: Actividad de la IA

    /// Mientras se ejecuta una IA, mira su pantalla cada segundo para saber si trabaja,
    /// si te espera o si ha terminado. Solo corre en ese caso: en reposo no gasta nada.
    private func watchAgent() {
        agentWatch?.cancel()
        tracker = AgentTracker()
        agentWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.pollAgent()
            }
        }
    }

    private func pollAgent() {
        let lines = view.visibleRowsText(0..<400)
        let screen = AgentScreenReader.read(lines)
        let recent = ContinuousClock.now - lastOutput.withLock { $0 } < .milliseconds(1_500)
        let changed = tracker.update(screen, outputRecently: recent)
        if screen != agentScreen { agentScreen = screen }
        if changed {
            agentPhase = tracker.phase
            if case .finished = tracker.phase {
                Island.shared.agentFinished(self)
                refreshGit()
            }
            Island.shared.refresh()
            Ports.shared.refresh(after: .seconds(1))
        }
    }

    private func stopWatchingAgent() {
        agentWatch?.cancel()
        agentWatch = nil
        guard agentPhase != .idle else { return }
        tracker = AgentTracker()
        agentPhase = .idle
        Island.shared.refresh()
    }

    /// Has visto el resultado: deja de avisarse en la isla.
    func acknowledgeAgent() {
        guard case .finished = agentPhase else { return }
        tracker.acknowledge()
        agentPhase = .idle
    }

    // MARK: Claude

    /// Agente de IA que se está ejecutando en esta pestaña (o que se está abriendo).
    var agent: AIAgent? {
        if let command = runningCommand { return AIAgent.detect(command: command) }
        if case .agent(let a) = kind, !integrationActive || pendingStartup != nil { return a }
        return nil
    }

    var isClaude: Bool { agent == .claude }

    var lastCommandFailed: Bool { (lastExit ?? 0) != 0 && !Self.wasStopped(lastExit ?? 0) && atPrompt }

    /// Lo paraste tú (⌃C, cerrar el servidor desde Faro, kill): no es un fallo del comando.
    static func wasStopped(_ exit: Int32) -> Bool { [129, 130, 137, 143].contains(exit) }

    /// PID de la shell de esta terminal, para saber qué servidores salieron de aquí.
    var shellPid: pid_t? {
        guard let process = view.process else { return nil }
        let pid = process.shellPid
        return pid > 0 ? pid : nil
    }

    /// Abre Claude Code en una pestaña nueva con el comando que ha fallado y su salida.
    func explainLastError() {
        guard let command = lastCommand, let exit = lastExit else { return }
        askClaude(command: command, exit: exit, output: outputOfLastCommand(command, maxLines: 80), directory: cwd)
    }

    /// Abre Claude al lado con un comando y su salida: si falló, para que lo explique y lo arregle.
    func askClaude(command: String, exit: Int32?, output: String, directory: String) {
        let failed = (exit ?? 0) != 0
        let header = failed
            ? "En mi terminal ha fallado este comando (código de salida \(exit ?? 0)) en la carpeta \(directory):"
            : "Este es un comando que he ejecutado en mi terminal, en la carpeta \(directory):"
        let prompt = """
        \(header)

        $ \(command)

        Esta es la salida:
        ```
        \(output)
        ```

        \(failed ? (DemoMode.enabled ? "Explícame qué ha pasado y arréglalo." : "Explícame qué ha pasado y cómo solucionarlo.") : "Ayúdame a entender esta salida.")
        """
        let dir = Self.tempRoot.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + ".txt")
        guard (try? prompt.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        let launch = AppModel.testMode && !DemoMode.enabled ? "cat \(Tokenizer.escape(file.path))" : "clear; claude \"$(<\(Tokenizer.escape(file.path)))\""
        // Claude se abre al lado, en un panel, para ver el error y la explicación a la vez.
        window?.split(.horizontal, kind: .agent(.claude), startupCommand: launch, from: self)
    }

    /// Salida del último comando: lo que hay en pantalla entre la línea donde se escribió
    /// y el prompt actual.
    /// `promptShown`: la última línea es ya el prompt siguiente y no es salida del comando.
    func outputOfLastCommand(_ command: String, maxLines: Int, promptShown: Bool = true) -> String {
        guard let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: 2_000)) else { return "" }
        var lines = snapshot.rows.map(\.text)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if promptShown && !lines.isEmpty { lines.removeLast() }
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        if let start = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(firstLine) }) {
            lines = Array(lines[(start + 1)...])
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    // MARK: Presentación

    var displayTitle: String {
        if let agent { return agent.shortName }
        if let command = runningCommand {
            let short = command.split(separator: " ").prefix(3).joined(separator: " ")
            return short.count > 22 ? String(short.prefix(21)) + "…" : short
        }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// Dónde está, para mostrar bajo el título: la carpeta que la contiene y la rama de git.
    var locationSubtitle: String {
        if let command = runningCommand, agent == nil { return command }
        let home = NSHomeDirectory()
        var place: String
        if agent != nil {
            place = SuggestionEngine.abbreviate(cwd)
        } else if cwd == home {
            place = "Carpeta personal"
        } else {
            place = SuggestionEngine.abbreviate((cwd as NSString).deletingLastPathComponent)
        }
        if let branch = context.gitBranch { place += " · " + branch }
        return place
    }

    var symbol: String {
        runningCommand != nil ? "circle.dashed" : "terminal"
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        updateCaret()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard !integrationActive, let directory, let url = URL(string: directory), url.isFileURL else { return }
        cwd = url.path
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        exited = true
        window?.sessionEnded(self)
        Ports.shared.refresh(after: .seconds(1))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
