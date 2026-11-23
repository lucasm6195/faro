import AppKit
import FaroCore
import SwiftUI

/// Modo demo (solo para grabar el vídeo de presentación): datos de prueba en lugar de los tuyos
/// y un guion que maneja Faro solo. Se activa con la variable de entorno FARO_DEMO
/// («record» graba el vídeo; «snapshot» guarda una captura).
enum DemoMode {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let enabled = environment["FARO_DEMO"] != nil
    /// Carpeta con los proyectos de ejemplo (dentro de tu carpeta personal, para que se vea «~/…»).
    nonisolated static let root = environment["FARO_DEMO_ROOT"] ?? NSHomeDirectory() + "/FaroDemo"
    nonisolated static let app = root + "/acme-web"
    nonisolated static let output = URL(fileURLWithPath: environment["FARO_DEMO_OUT"] ?? NSTemporaryDirectory() + "faro-demo")
    /// Tamaño de la ventana en el vídeo.
    nonisolated static let windowSize = CGSize(width: 1280, height: 760)

    nonisolated static var settings: FaroSettings {
        var s = FaroSettings()
        s.activityIsland = true
        s.islandSound = false
        s.dropdownEnabled = false
        s.restoreSession = false
        s.notifyLongCommands = false
        s.fontSize = 14
        s.followSystemAppearance = false
        s.themeID = environment["FARO_DEMO_THEME"] ?? "faro-noche"
        return s
    }

    nonisolated static var places: [String] {
        ["acme-web", "acme-web/src", "acme-web/src/app", "api", "mobile", "docs"].map { root + "/" + $0 }
    }

    /// Historial de ejemplo: lo que aprenden las sugerencias y las predicciones.
    nonisolated static var history: [CommandRecord] {
        let now = Date()
        var records: [CommandRecord] = []
        let commands: [(String, String, Int)] = [
            ("git status", app, 14), ("npm run dev", app, 11), ("git add -A", app, 6), ("git commit -m \"Arregla el menú\"", app, 3),
            ("git push", app, 5), ("npm test", app, 6), ("npm install", app, 2), ("code .", app, 3), ("git pull", app, 4),
            ("npm run build", app, 3), ("cd acme-web", root, 6), ("ls", root, 4), ("git log --oneline -5", app, 3),
        ]
        for (command, dir, times) in commands {
            for i in 0..<times {
                records.append(CommandRecord(command: command, directory: dir, date: now.addingTimeInterval(-Double(i * 3_600 + command.count * 60)),
                                             exit: 0, milliseconds: 300))
            }
        }
        // Secuencias habituales, para que la barra prediga el siguiente comando.
        for i in 0..<4 {
            let base = now.addingTimeInterval(-Double(86_400 * (i + 1)))
            for (j, command) in ["git status", "git add -A", "git commit -m \"Arregla el menú\"", "git push"].enumerated() {
                records.append(CommandRecord(command: command, directory: app, date: base.addingTimeInterval(Double(j * 30)), exit: 0, milliseconds: 200))
            }
        }
        return records.sorted { $0.date < $1.date }
    }

    /// Solo los servidores de la carpeta de ejemplo (nada de lo que tengas abierto tú).
    nonisolated static func filter(_ ports: [ListeningPort]) -> [ListeningPort] {
        guard enabled else { return ports }
        return ports.filter { $0.directory?.hasPrefix(root) == true }
    }

    /// Antes de crear nada: el proyecto de ejemplo para «Abrir Acme».
    @MainActor
    static func prepare() {
        guard enabled else { return }
        let project = Project(name: "Acme", directory: app, layout: .split(
            horizontal: true, fraction: 0.5,
            first: .terminal(directory: nil, command: "git log --oneline -5"),
            second: .split(horizontal: false, fraction: 0.55,
                           first: .terminal(directory: nil, command: "npm run dev"),
                           second: .terminal(directory: nil, command: nil))))
        try? ProjectStore.save([project], to: Projects.file)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    @MainActor
    static func launched() {
        guard enabled, let controller = AppModel.shared.frontWindow, let window = controller.window else { return }
        // Abajo del todo: arriba queda sitio libre para grabar la isla del notch.
        let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
        window.setFrame(NSRect(x: screen.midX - windowSize.width / 2, y: screen.minY + 24,
                               width: windowSize.width, height: windowSize.height), display: true)
        switch environment["FARO_DEMO"] {
        case "snapshot":
            if let text = environment["FARO_DEMO_TYPE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    MainActor.assumeIsolated {
                        guard let session = controller.model.selected else { return }
                        for character in text {
                            session.noteTyping()
                            session.view.send(txt: String(character))
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                MainActor.assumeIsolated {
                    DemoRecorder.snapshot(of: window, to: output.appendingPathComponent("snapshot.png"))
                    NSApp.terminate(nil)
                }
            }
        case "record":
            // El guion lo maneja todo: tu ratón no toca la ventana mientras se graba.
            window.ignoresMouseEvents = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                await DemoDirector(controller: controller).run()
                NSApp.terminate(nil)
            }
        default:
            break
        }
    }
}

/// Dónde está cada botón de la interfaz (en puntos de la ventana, origen arriba a la izquierda),
/// para que el guion pueda pulsarlo y el montaje sepa dónde dibujar el cursor.
@MainActor
final class DemoAnchors {
    static let shared = DemoAnchors()
    var frames: [String: CGRect] = [:]
}

extension View {
    @ViewBuilder
    func demoAnchor(_ id: String) -> some View {
        if DemoMode.enabled {
            onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                MainActor.assumeIsolated { DemoAnchors.shared.frames[id] = frame }
            }
        } else {
            self
        }
    }
}

/// Ejecuta el guion del vídeo con teclas y clics de verdad, y apunta cuándo y dónde pasa cada
/// cosa (cursor, clics, zooms, rótulos) para el montaje.
@MainActor
final class DemoDirector {
    let controller: TerminalWindowController
    let window: NSWindow
    private var recorder: DemoCapture?
    private var events: [[String: Any]] = []
    private var cursor = CGPoint(x: 900, y: 520)
    private var random: UInt64 = 42

    init(controller: TerminalWindowController) {
        self.controller = controller
        window = controller.window!
    }

    private var size: CGSize { window.frame.size }
    private var now: Double { recorder?.elapsed ?? 0 }

    // MARK: Guion

    private var session: TerminalSession? { controller.model.selected }

    func run() async {
        let url = DemoMode.output.appendingPathComponent("raw.mov")
        let recorder: DemoCapture
        // Mejor la pantalla de verdad (60 fps reales, con animaciones y la isla); si no hay
        // permiso de grabación de pantalla, Faro se dibuja a sí mismo.
        if let screen = try? await ScreenRecorder.make(window: window, url: url) {
            recorder = ScreenCapture(screen)
        } else if let own = try? DemoRecorder(window: window, url: url) {
            own.start()
            recorder = own
        } else {
            return
        }
        self.recorder = recorder
        log("cursor", ["x": cursor.x, "y": cursor.y, "dur": 0])
        await wait(0.9)

        // 1. Sugerencias
        caption("Sugerencias mientras escribes", "Aprende de tu historial y de tu proyecto")
        zoom(promptRect(height: 200), scale: 1.9)
        await wait(0.9)
        await typeTerminal("git st")
        await wait(1.4)
        keys("→")
        if let session, let ghost = session.ghost { session.setBuffer(session.buffer + ghost) }
        DemoRecorder.activity()
        await wait(0.7)
        enter()
        await wait(1.9)

        // 2. Git en la barra inferior
        caption("Git de un vistazo", "Cambios y commits por subir, siempre a la vista")
        zoom(CGRect(x: 0, y: size.height - 120, width: 620, height: 120), scale: 2.1)
        await move(to: center("git"), duration: 0.9)
        await wait(1.8)

        // 3. La ruta es un botón
        caption("Muévete sin escribir cd", "Cada parte de la ruta es un botón")
        await move(to: center("crumb-FaroDemo"), duration: 0.6)
        await wait(0.3)
        await click { self.session?.navigate(to: DemoMode.root) }
        await wait(1.0)
        zoom(promptRect(height: 240), scale: 1.8)
        await typeTerminal("ls")
        enter()
        await wait(1.8)

        // 4. Proyectos
        unzoom()
        caption("Proyectos con un clic", "Su servidor, git y sus paneles, todo montado")
        await move(to: center("search"), duration: 0.9)
        await click { self.controller.togglePalette() }
        await wait(0.7)
        await typePalette("acme")
        await wait(1.0)
        submitPalette()
        await wait(1.2)
        await move(to: CGPoint(x: size.width * 0.75, y: size.height * 0.3), duration: 0.8)
        await wait(2.6)

        // 5. Puerto ocupado
        caption("¿Puerto ocupado?", "Faro te dice quién lo tiene y lo cierra por ti")
        await move(to: CGPoint(x: size.width * 0.25, y: size.height * 0.55), duration: 0.7)
        await click { self.focusPane(0) }
        await wait(0.3)
        await typeTerminal("npm run dev")
        enter()
        await wait(2.2)
        zoom(CGRect(x: 0, y: size.height - 150, width: size.width, height: 150), scale: 1.6)
        await wait(0.7)
        await move(to: center("conflict-close"), duration: 1.0)
        await wait(0.6)
        await click { self.session?.resolvePortConflict() }
        await wait(1.6)
        unzoom()
        await wait(2.4)

        // 6. Puertos abiertos
        caption("Puertos abiertos", "Lo que sigue escuchando y quién lo dejó")
        await move(to: center("ports"), duration: 0.9)
        await click { self.controller.model.portsVisible = true }
        await wait(0.6)
        let panel = DemoAnchors.shared.frames["ports-panel"] ?? CGRect(x: size.width - 400, y: 40, width: 390, height: 120)
        zoom(panel.insetBy(dx: -40, dy: -30), scale: 2.0)
        await wait(3.0)
        keys("esc")
        controller.model.portsVisible = false
        DemoRecorder.activity()
        unzoom()
        await wait(0.7)

        // 7. Bloques de comandos
        caption("Cada comando es un bloque", "Cópialo, repítelo o pregúntale a Claude")
        await move(to: CGPoint(x: size.width * 0.75, y: size.height * 0.82), duration: 0.8)
        await click { self.focusPane(2) }
        await wait(0.3)
        await typeTerminal("npm test")
        enter()
        await wait(1.8)
        let tested = session
        if let (point, viewPoint) = blockPoint() {
            await move(to: point, duration: 1.0)
            tested?.hoverBlock(at: viewPoint)
            DemoRecorder.activity()
            zoom(CGRect(x: size.width / 2, y: point.y - 110, width: size.width / 2, height: 220), scale: 1.9)
            await wait(2.2)
            tested?.hoverBlock(at: viewPoint)
            if let button = claudeButton(of: tested) {
                await move(to: button, duration: 0.7)
                await wait(0.35)
            }
        }
        if let tested, let block = tested.blocks.all.last(where: { !$0.isRunning }) {
            await click { tested.askClaude(about: block) }
        }
        tested?.hideBlock()
        unzoom()
        DemoRecorder.activity()

        // 8. Claude y la isla del notch
        await claudeAndNotch()

        // 9. Temas
        caption("12 temas", "Y cambio automático con el modo claro u oscuro")
        for theme in ["tokyo night", "latte", "dracula", "faro noche"] {
            keys("⌘P")
            controller.togglePalette()
            DemoRecorder.activity()
            await wait(0.45)
            await typePalette(theme)
            await wait(0.35)
            submitPalette()
            await wait(1.35)
        }

        // 10. Barra lateral
        caption("Pestañas arriba o a un lado", "Con sus carpetas, ramas y paneles")
        await move(to: center("sidebar"), duration: 0.9)
        await click { AppModel.shared.settings.tabsInSidebar = true }
        await wait(2.8)
        await move(to: center("sidebar-top"), duration: 0.8)
        await click { AppModel.shared.settings.tabsInSidebar = false }
        await wait(1.3)
        caption(nil, nil)
        await wait(0.6)

        let summary = await recorder.stop()
        let timeline: [String: Any] = [
            "window": ["width": size.width, "height": size.height, "scale": window.backingScaleFactor],
            "duration": now, "events": events, "recorder": summary, "capture": recorder.info,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted]) {
            try? data.write(to: DemoMode.output.appendingPathComponent("timeline.json"))
        }
    }

    /// Claude se abre al lado con el error; mientras trabaja te vas a otra pestaña y la isla del
    /// notch te avisa cuando te necesita y cuando acaba. Claude es de verdad: lo que tarda y lo
    /// que pregunta cambia de una vez a otra, así que el guion espera a cada estado (y las esperas
    /// largas van aceleradas en el vídeo).
    private func claudeAndNotch() async {
        caption("Claude, al lado", "Con el comando y su salida, sin copiar nada")
        guard let claude = await until(25, { self.claudeSession(where: { $0.agentPhase != .idle }) }) else {
            await wait(2)
            return
        }
        // ⇧⇥: que acepte las ediciones él solo y no se pare a preguntar.
        await wait(0.6)
        await acceptEdits(claude)
        await wait(2.0)

        // A otra pestaña: Claude ya no se ve y aparece en el notch.
        caption("El notch te avisa", "Claude trabaja y tú sigues a lo tuyo")
        if let first = controller.model.tabs.first {
            await move(to: center("tab-\(first.id.uuidString)"), duration: 0.8)
            await click { self.controller.select(first) }
        }
        await wait(0.6)
        zoomNotch()
        await move(to: CGPoint(x: size.width * 0.62, y: 150), duration: 0.9)
        await wait(2.6)

        // Mientras trabaja, el vídeo va acelerado. Si aun así pregunta algo, se acepta.
        speed(6)
        let deadline = Date().addingTimeInterval(180)
        var finished = false
        while Date() < deadline {
            if case .finished = claude.agentPhase { finished = true; break }
            if case .needsInput = claude.agentPhase {
                // Un permiso se acepta con ↩; si pregunta con palabras, se le contesta.
                claude.view.send(txt: "\r")
                await wait(3)
                if case .needsInput = claude.agentPhase {
                    for c in "Sí, arréglalo" { claude.view.send(txt: String(c)); await wait(0.05) }
                    claude.view.send(txt: "\r")
                    await wait(3)
                }
                continue
            }
            if claude.agent == nil { break }
            await wait(0.2)
        }
        speed(1)
        if finished {
            caption("Claude ha terminado", "Te lo dice el notch, sin mirar la terminal")
            zoomNotch()
            await wait(2.4)
            await openFromNotch(claude)
            await wait(3.4)
        }
        unzoom()
        await wait(0.6)
    }

    /// Cambia Claude a «aceptar ediciones» con ⇧⇥ (da vueltas por los modos hasta llegar).
    private func acceptEdits(_ claude: TerminalSession) async {
        keys("⇧⇥")
        for _ in 0..<5 {
            if claude.view.visibleRowsText(0..<400).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).contains(where: { $0.lowercased().contains("accept edits") }) { return }
            claude.view.send(txt: "\u{1b}[Z")
            DemoRecorder.activity()
            await wait(0.6)
        }
    }

    /// El cursor va al notch, la isla se abre y un clic lleva a la sesión de Claude.
    private func openFromNotch(_ claude: TerminalSession) async {
        await move(to: CGPoint(x: size.width / 2 - 70, y: -12), duration: 0.9)
        Island.shared.setExpanded(true)
        await wait(1.8)
        await move(to: CGPoint(x: size.width / 2 - 40, y: 40), duration: 0.5)
        await wait(0.3)
        await click {
            Island.shared.open(claude)
            self.window.makeFirstResponder(claude.view)
        }
        await wait(0.5)
        unzoom()
        if let frame = claude.view.superview.map({ $0.convert($0.bounds, to: nil) }) {
            await move(to: CGPoint(x: frame.midX, y: size.height - frame.midY), duration: 0.8)
        }
    }

    private func claudeSession(where condition: (TerminalSession) -> Bool) -> TerminalSession? {
        controller.model.allSessions.first { $0.agent == .claude && condition($0) }
    }

    /// Espera (como mucho `timeout` segundos) a que algo pase.
    private func until<T>(_ timeout: Double, _ check: @escaping @MainActor () -> T?) async -> T? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let value = check() { return value }
            await wait(0.1)
        }
        return nil
    }

    /// El botón de Claude en la barra del bloque (en la ventana, origen arriba).
    private func claudeButton(of session: TerminalSession?) -> CGPoint? {
        guard let session, let overlay = session.blockOverlay, let bar = overlay.toolbarFrame else { return nil }
        let frame = overlay.convert(bar, to: nil)
        // Botones de 24 de ancho; el de Claude es el penúltimo (el último es «volver a ejecutar»).
        let x = frame.maxX - 2 - (session.atPrompt ? 24 : 0) - 12
        return CGPoint(x: x, y: size.height - frame.midY)
    }

    /// Velocidad del vídeo a partir de aquí (las esperas largas van aceleradas).
    private func speed(_ factor: Double) { log("speed", ["scale": factor]) }

    /// La cámara sube al notch (fuera de la ventana, arriba en el escritorio).
    private func zoomNotch(scale: Double = 1.5) {
        log("zoom", ["x": size.width / 2, "y": -40, "scale": scale, "free": true])
    }

    /// Pone el foco en un panel de la pestaña (en orden de lectura).
    private func focusPane(_ index: Int) {
        guard let tab = controller.model.selectedTab, let target = tab.sessions[safe: index] else { return }
        controller.focus(target)
        window.makeFirstResponder(target.view)
        DemoRecorder.activity()
    }

    private func typeTerminal(_ text: String) async {
        for character in text {
            session?.noteTyping()
            session?.view.send(txt: String(character))
            DemoRecorder.activity()
            await wait(0.075 + nextRandom() * 0.06)
        }
    }

    private func enter() {
        session?.view.send(txt: "\r")
        DemoRecorder.activity()
    }

    private func typePalette(_ text: String) async {
        var typed = ""
        for character in text {
            typed.append(character)
            controller.model.demoQuery = typed
            DemoRecorder.activity()
            await wait(0.05 + nextRandom() * 0.035)
        }
    }

    private func submitPalette() {
        controller.model.demoSubmit += 1
        controller.model.demoQuery = nil
        DemoRecorder.activity(1.2)
    }

    /// Una tecla en pantalla (para el rótulo de atajos del montaje).
    private func keys(_ label: String) { log("keys", ["title": label]) }

    // MARK: Piezas

    private func log(_ kind: String, _ fields: [String: Any] = [:]) {
        var event = fields
        event["t"] = now
        event["kind"] = kind
        events.append(event)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func caption(_ title: String?, _ subtitle: String?) {
        log("caption", ["title": title ?? "", "subtitle": subtitle ?? ""])
    }

    private func zoom(_ rect: CGRect, scale: Double) {
        log("zoom", ["x": rect.midX, "y": rect.midY, "scale": scale])
    }

    private func unzoom() { log("zoom", ["x": size.width / 2, "y": size.height / 2, "scale": 1.0]) }

    private func center(_ anchor: String) -> CGPoint {
        guard let frame = DemoAnchors.shared.frames[anchor] else { return cursor }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// La línea del prompt de la terminal activa y lo que hay debajo.
    private func promptRect(height: CGFloat) -> CGRect {
        guard let session = controller.model.selected else { return CGRect(origin: .zero, size: size) }
        let caret = session.view.convert(session.view.caretFrame, to: nil)
        let top = size.height - caret.maxY
        return CGRect(x: 0, y: max(0, top - 30), width: min(size.width, 760), height: height)
    }

    /// Un punto sobre la salida del último comando de la terminal activa (en la ventana y en la vista).
    private func blockPoint() -> (CGPoint, NSPoint)? {
        guard let session = controller.model.selected, let block = session.blocks.all.last(where: { !$0.isRunning }) else { return nil }
        guard let snapshot = session.view.terminalContentSnapshot(region: .viewport) else { return nil }
        let height = session.view.caretFrame.height
        let topEdge = session.view.caretFrame.maxY + CGFloat(snapshot.cursorRow - snapshot.capturedRange.lowerBound) * height
        let row = min(block.startRow + 2, block.endRow ?? block.startRow)
        let y = topEdge - (CGFloat(row - snapshot.capturedRange.lowerBound) + 0.5) * height
        let viewPoint = NSPoint(x: session.view.bounds.width * 0.4, y: y)
        let point = session.view.convert(viewPoint, to: nil)
        return (CGPoint(x: point.x, y: size.height - point.y), viewPoint)
    }

    private func nextRandom() -> Double {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return Double(random >> 33) / Double(1 << 31)
    }

    /// Mueve el cursor con una curva suave, enviando el movimiento a la ventana (para lo que
    /// reacciona al pasar el ratón) y apuntándolo para dibujarlo en el montaje.
    private func move(to target: CGPoint, duration: Double) async {
        let start = cursor
        log("cursor", ["x": target.x, "y": target.y, "dur": duration])
        let steps = max(1, Int(duration * 60))
        for i in 1...steps {
            let p = Double(i) / Double(steps)
            let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            cursor = CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
            await wait(1.0 / 60)
        }
        cursor = target
    }

    /// Un clic donde está el cursor: se apunta para el montaje y se hace lo que haría ese botón.
    private func click(_ action: @escaping @MainActor () -> Void) async {
        log("click", ["x": cursor.x, "y": cursor.y])
        await wait(0.08)
        action()
        DemoRecorder.activity(1.2)
    }
}
