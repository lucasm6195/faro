import AppKit
import FaroCore
import Observation
import os

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: FaroSettings {
        didSet {
            guard settings != oldValue else { return }
            if !DemoMode.enabled { settings.save() }
            palette = Palette(settings.theme(systemIsDark: systemIsDark))
            MemoryMonitor.shared.setEnabled(settings.trimMemoryWhenIdle)
            for window in windows { window.applySettings() }
            if settings.activityIsland != oldValue.activityIsland { Island.shared.refresh() }
            if settings.dropdownEnabled != oldValue.dropdownEnabled || settings.dropdownShortcut != oldValue.dropdownShortcut
                || settings.dropdownHeight != oldValue.dropdownHeight {
                Dropdown.shared.applySettings()
            }
        }
    }

    var systemIsDark: Bool {
        didSet {
            guard systemIsDark != oldValue else { return }
            palette = Palette(settings.theme(systemIsDark: systemIsDark))
            for window in windows { window.applySettings() }
        }
    }

    private(set) var palette: Palette
    /// Herramientas de IA instaladas en este Mac (las que tienen su programa en el PATH).
    private(set) var installedAgents: [AIAgent] = []
    private(set) var historyVersion = 0

    @ObservationIgnored private(set) var history = HistoryIndex()
    @ObservationIgnored private(set) var directories = DirectoryIndex()
    @ObservationIgnored private var executables = PrefixIndex([String]())
    @ObservationIgnored private(set) var places: [String] = []
    @ObservationIgnored private var cachedEngine: SuggestionEngine?
    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private var saveDirectoriesTask: Task<Void, Never>?
    @ObservationIgnored var windows: [TerminalWindowController] = []
    @ObservationIgnored let log = Logger(subsystem: "dev.faro", category: "app")

    nonisolated static let dataDirectory = FaroSettings.directory
    nonisolated static let directoriesFile = dataDirectory.appendingPathComponent("directories.json")

    private init() {
        let settings = DemoMode.enabled ? DemoMode.settings : FaroSettings.load()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.settings = settings
        self.systemIsDark = dark
        self.palette = Palette(settings.theme(systemIsDark: dark))
        self.store = HistoryStore(url: Self.dataDirectory.appendingPathComponent("history.jsonl"))
        MemoryMonitor.shared.setEnabled(settings.trimMemoryWhenIdle)
    }

    var theme: Theme { palette.theme }

    // MARK: Arranque

    func bootstrap() {
        try? ShellIntegration.install()
        Ports.shared.refresh()
        if DemoMode.enabled {
            // Datos de prueba: en el vídeo no sale nada tuyo.
            var index = HistoryIndex()
            var dirs = DirectoryIndex()
            for record in DemoMode.history {
                index.record(record)
                if let exit = record.exit { index.complete(command: record.command, exit: exit) }
                if let dir = record.directory { dirs.visit(dir, date: record.date) }
            }
            history = index
            directories = dirs
            places = DemoMode.places
            invalidateEngine()
        }
        Task.detached(priority: .utility) { [store] in
            if DemoMode.enabled {
                let path = await Executables.loginPath()
                let names = Executables.scan(path: path)
                let agents = AIAgent.allCases.filter { Set(names).contains($0.executables.first ?? "") }
                await MainActor.run {
                    AppModel.shared.installedAgents = agents
                    AppModel.shared.executables = PrefixIndex(names)
                    AppModel.shared.invalidateEngine()
                }
                return
            }
            let zsh = ZshHistoryImporter.load(from: URL(fileURLWithPath: NSHomeDirectory() + "/.zsh_history"))
            let own = await store.loadAll()
            var index = HistoryIndex()
            for r in zsh { index.record(r) }
            for r in own {
                index.record(r)
                if let exit = r.exit { index.complete(command: r.command, exit: exit) }
            }
            let dirs = (try? Data(contentsOf: AppModel.directoriesFile))
                .flatMap { try? JSONDecoder().decode(DirectoryIndex.self, from: $0) } ?? DirectoryIndex()
            await MainActor.run {
                AppModel.shared.history = index
                AppModel.shared.directories = dirs
                AppModel.shared.invalidateEngine()
            }
            let places = AppModel.scanPlaces()
            await MainActor.run {
                AppModel.shared.places = places
                AppModel.shared.invalidateEngine()
            }
            let path = await Executables.loginPath()
            let names = Executables.scan(path: path)
            let prefix = PrefixIndex(names)
            let available = Set(names)
            let agents = AIAgent.allCases.filter { $0.executables.contains(where: available.contains) }
            await MainActor.run {
                AppModel.shared.installedAgents = agents
                AppModel.shared.executables = prefix
                AppModel.shared.invalidateEngine()
            }
        }
    }

    // MARK: Historial

    /// En el modo de prueba no se guarda nada en el historial.
    nonisolated static let testMode = ProcessInfo.processInfo.environment["FARO_TEST_BACKGROUND"] == "1"

    func record(command: String, directory: String) {
        guard !Self.testMode else { return }
        let record = CommandRecord(command: command, directory: directory, date: Date())
        history.record(record)
        invalidateEngine()
        Task { await store.append(record) }
    }

    func complete(command: String, directory: String, exit: Int32, milliseconds: Int) {
        guard !Self.testMode else { return }
        history.complete(command: command, exit: exit)
        if exit != 0 { invalidateEngine() }
        let record = CommandRecord(command: command, directory: directory, date: Date(), exit: exit, milliseconds: milliseconds)
        Task { await store.append(record) }
    }

    func visit(directory: String) {
        guard !Self.testMode else { return }
        directories.visit(directory)
        cachedEngine?.directories = directories
        saveDirectoriesTask?.cancel()
        saveDirectoriesTask = Task { [directories] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let data = try? JSONEncoder().encode(directories)
            try? data?.write(to: Self.directoriesFile, options: .atomic)
        }
    }

    func engine(for context: ProjectContext) -> SuggestionEngine {
        if cachedEngine == nil {
            cachedEngine = SuggestionEngine(history: history, directories: directories, context: context, executables: executables)
            cachedEngine?.places = places
        }
        var engine = cachedEngine!
        engine.context = context
        return engine
    }

    /// Carpetas de la carpeta personal y un nivel más (por ejemplo cada proyecto dentro de
    /// ~/Proyectos), para poder saltar a ellas por nombre desde el primer día.
    nonisolated static func scanPlaces(limit: Int = 4_000) -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // Escritorio, Documentos y Descargas están protegidas por macOS: entrar en ellas en segundo
        // plano haría saltar el aviso de permisos al abrir Faro. Solo se recorren cuando vas tú.
        let skip: Set<String> = ["Library", "Applications", "Music", "Movies", "Pictures", "Public", "node_modules",
                                 "Desktop", "Documents", "Downloads"]
        func subdirectories(_ path: String) -> [String] {
            guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
            return names.filter { !$0.hasPrefix(".") && !skip.contains($0) }.compactMap { name in
                let full = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue ? full : nil
            }
        }
        var result: [String] = []
        for first in subdirectories(home) {
            result.append(first)
            if result.count >= limit { break }
            result.append(contentsOf: subdirectories(first).prefix(300))
        }
        return Array(result.prefix(limit))
    }

    private func invalidateEngine() {
        cachedEngine = nil
        historyVersion += 1
    }

    // MARK: Ventanas

    @discardableResult
    func newWindow(directory: String? = nil, kind: TerminalSession.Kind = .shell, startupCommand: String? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController()
        windows.append(controller)
        controller.newTab(directory: directory, kind: kind, startupCommand: startupCommand)
        controller.showWindow(nil)
        return controller
    }

    func windowClosed(_ controller: TerminalWindowController) {
        windows.removeAll { $0 === controller }
        Workspace.shared.setNeedsSave()
    }

    func restoreWindow(_ snapshot: WorkspaceSnapshot.Window) {
        let controller = TerminalWindowController()
        windows.append(controller)
        controller.restore(snapshot)
        if controller.model.tabs.isEmpty {
            windows.removeAll { $0 === controller }
            return
        }
        controller.showWindow(nil)
    }

    var frontWindow: TerminalWindowController? {
        if let key = NSApp.keyWindow?.windowController as? TerminalWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? TerminalWindowController { return main }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
            ?? windows.last { !$0.model.isDropdown || $0.window?.isVisible == true }
    }

    var sessionCount: Int { windows.reduce(0) { $0 + $1.model.allSessions.count } }
}
