import AppKit
import FaroCore
import SwiftTerm

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private let editorMenu = EditorMenu()
    private let projectMenu = ProjectMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DemoMode.prepare()
        Fonts.registerBundled()
        NSApp.mainMenu = buildMenu()
        installKeyMonitor()
        installMouseMonitor()
        let app = AppModel.shared
        app.bootstrap()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppModel.shared.systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                }
            }
        }
        Dropdown.shared.applySettings()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if Workspace.shared.restore(), let front = AppModel.shared.windows.last {
            present(front)
        }
        // Si Faro se ha abierto para una carpeta, un script o un enlace ssh, esa petición llega
        // justo después: la ventana vacía solo se crea si no ha llegado ninguna.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if AppModel.shared.windows.isEmpty { self.present(AppModel.shared.newWindow()) }
                DemoMode.launched()
            }
        }
    }

    private func present(_ controller: TerminalWindowController) {
        // Modo de prueba: la ventana aparece encima sin quitar el foco del teclado a otra app.
        if ProcessInfo.processInfo.environment["FARO_TEST_BACKGROUND"] == "1" {
            controller.window?.level = .floating
            controller.window?.orderFrontRegardless()
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    // MARK: Faro como terminal principal

    /// Carpetas (arrastradas al icono o «Abrir con»), scripts `.command`, ejecutables y
    /// enlaces `ssh://`, `telnet://` y `x-man-page://`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    private func open(_ url: URL) {
        if url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                openTab(directory: url.path)
            } else {
                openTab(directory: url.deletingLastPathComponent().path, command: Tokenizer.escape(url.path))
            }
            return
        }
        switch url.scheme?.lowercased() {
        case "ssh":
            guard let host = url.host(), !host.isEmpty else { return }
            var command = "ssh "
            if let port = url.port { command += "-p \(port) " }
            if let user = url.user(), !user.isEmpty { command += Tokenizer.escape(user) + "@" }
            openTab(directory: nil, command: command + Tokenizer.escape(host))
        case "telnet":
            guard let host = url.host(), !host.isEmpty else { return }
            openTab(directory: nil, command: "telnet " + Tokenizer.escape(host) + (url.port.map { " \($0)" } ?? ""))
        case "x-man-page":
            let parts = ([url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return }
            openTab(directory: nil, command: "man " + parts.map(Tokenizer.escape).joined(separator: " "))
        default:
            return
        }
    }

    private func openTab(directory: String?, command: String? = nil, kind: TerminalSession.Kind = .shell) {
        if let front = AppModel.shared.frontWindow {
            front.newTab(directory: directory, kind: kind, startupCommand: command)
            present(front)
        } else {
            let controller = AppModel.shared.newWindow(directory: directory, kind: kind, startupCommand: command)
            present(controller)
        }
    }

    /// Servicio del Finder: clic derecho en una carpeta → Servicios → Nueva pestaña de Faro aquí.
    @objc func openFolderService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for dir in Self.folders(in: pboard) { openTab(directory: dir) }
    }

    /// Servicio del Finder: abre Claude Code en esa carpeta.
    @objc func openClaudeService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for dir in Self.folders(in: pboard) { openTab(directory: dir, kind: .agent(.claude)) }
    }

    private static func folders(in pboard: NSPasteboard) -> [String] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue ? url.path : url.deletingLastPathComponent().path
        }
    }

    /// Con la desplegable activa, Faro sigue abierto sin ventanas para que el atajo funcione.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.settings.dropdownEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { present(AppModel.shared.newWindow()) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DemoMode.enabled { return .terminateNow }
        let sessions = AppModel.shared.windows.flatMap(\.model.allSessions)
        // Las IAs no cuentan como «programas que se perderán» si se van a retomar al volver.
        let restoring = AppModel.shared.settings.restoreSession
        let running = sessions.filter { $0.runningCommand != nil && !(restoring && $0.agent != nil) }.compactMap(\.runningCommand)
        Workspace.shared.saveBeforeQuit()
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "¿Salir de Faro?"
        alert.informativeText = "Se cerrarán \(running.count == 1 ? "un programa en marcha" : "\(running.count) programas en marcha"): \(running.prefix(3).joined(separator: ", "))."
            + (restoring ? "\n\nLas pestañas, las carpetas y las conversaciones de Claude se recuperarán al volver a abrir Faro." : "")
        alert.addButton(withTitle: "Salir")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateNow }
        Workspace.shared.cancelQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for window in AppModel.shared.windows {
            for session in window.model.allSessions { session.close() }
        }
        if let data = try? JSONEncoder().encode(AppModel.shared.directories) {
            try? data.write(to: AppModel.directoriesFile, options: .atomic)
        }
    }

    // MARK: Acciones

    private var front: TerminalWindowController? { AppModel.shared.frontWindow }
    private var session: TerminalSession? { front?.model.selected }

    @objc func newTab(_ sender: Any?) {
        if let front { front.newTab() } else { AppModel.shared.newWindow() }
    }

    @objc func newClaudeTab(_ sender: Any?) {
        if let front { front.newTab(kind: .agent(.claude)) } else { AppModel.shared.newWindow(kind: .agent(.claude)) }
    }

    @objc func newWindow(_ sender: Any?) { AppModel.shared.newWindow(directory: session?.cwd) }

    @objc func closeTab(_ sender: Any?) {
        if let window = NSApp.keyWindow, !(window.windowController is TerminalWindowController) {
            window.performClose(sender)
            return
        }
        guard let front, let session else { return }
        if let running = session.runningCommand {
            let alert = NSAlert()
            alert.messageText = "¿Cerrar la pestaña?"
            alert.informativeText = "«\(running)» sigue en marcha."
            alert.addButton(withTitle: "Cerrar")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        front.close(session)
    }

    @objc func showPalette(_ sender: Any?) { front?.togglePalette() }
    @objc func splitRight(_ sender: Any?) { front?.split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { front?.split(.vertical) }
    @objc func paneLeft(_ sender: Any?) { front?.focusPane(.left) }
    @objc func paneRight(_ sender: Any?) { front?.focusPane(.right) }
    @objc func paneUp(_ sender: Any?) { front?.focusPane(.up) }
    @objc func paneDown(_ sender: Any?) { front?.focusPane(.down) }
    @objc func growLeft(_ sender: Any?) { front?.resizePane(.left) }
    @objc func growRight(_ sender: Any?) { front?.resizePane(.right) }
    @objc func growUp(_ sender: Any?) { front?.resizePane(.up) }
    @objc func growDown(_ sender: Any?) { front?.resizePane(.down) }
    @objc func zoomPane(_ sender: Any?) { front?.toggleZoom() }
    @objc func toggleTabsSidebar(_ sender: Any?) { AppModel.shared.settings.tabsInSidebar.toggle() }
    @objc func toggleIsland(_ sender: Any?) { AppModel.shared.settings.activityIsland.toggle() }
    @objc func showFolders(_ sender: Any?) { front?.model.folderBrowserVisible.toggle() }
    @objc func showPorts(_ sender: Any?) { front?.model.portsVisible.toggle() }
    @objc func toggleDropdown(_ sender: Any?) { Dropdown.shared.toggle() }
    @objc func toggleDropdownEnabled(_ sender: Any?) { AppModel.shared.settings.dropdownEnabled.toggle() }
    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
    @objc func nextTab(_ sender: Any?) { front?.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { front?.selectTab(offset: -1) }
    @objc func selectTabNumber(_ sender: NSMenuItem) { front?.selectTab(number: sender.tag) }
    @objc func clearScreen(_ sender: Any?) { session?.view.send(txt: "\u{0c}") }
    @objc func biggerFont(_ sender: Any?) { AppModel.shared.settings.fontSize = min(AppModel.shared.settings.fontSize + 1, 32) }
    @objc func smallerFont(_ sender: Any?) { AppModel.shared.settings.fontSize = max(AppModel.shared.settings.fontSize - 1, 8) }
    @objc func resetFont(_ sender: Any?) { AppModel.shared.settings.fontSize = FaroSettings().fontSize }
    @objc func explainError(_ sender: Any?) { session?.explainLastError() }

    // MARK: Teclado

    /// Las teclas pasan por aquí antes que por los menús y el terminal, para que la pestaña
    /// activa atienda las sugerencias y los atajos de edición tipo documento (⌘⌫, ⌥←, ⇧→…).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                if event.keyCode == 53, let controller = event.window?.windowController as? TerminalWindowController,
                   controller.model.portsVisible {
                    controller.model.portsVisible = false
                    return true
                }
                guard let window = event.window,
                      let view = window.firstResponder as? FaroTerminalView,
                      let session = view.session else { return false }
                return session.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    /// Bloques de comandos: al mover el ratón sobre un panel se resalta el comando que hay debajo.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let window = event.window, let controller = window.windowController as? TerminalWindowController,
                      let tab = controller.model.selectedTab else { return }
                let sessions = tab.zoomed.map { [$0] } ?? tab.sessions
                guard AppModel.shared.settings.commandBlocks, event.type == .mouseMoved else {
                    // Un clic fuera de la barra de acciones (para seleccionar texto) quita el resaltado.
                    let hit = window.contentView?.hitTest(event.locationInWindow)
                    if event.type == .leftMouseDown, hit?.isDescendant(ofBlockOverlay: ()) == true { return }
                    for session in sessions { session.hideBlock() }
                    return
                }
                for session in sessions where session.view.window === window {
                    let point = session.view.convert(event.locationInWindow, from: nil)
                    if session.view.bounds.contains(point) { session.hoverBlock(at: point) } else { session.hideBlock() }
                }
            }
            return event
        }
    }

    @objc func copyLastOutput(_ sender: Any?) { front?.model.selected?.copyLastOutput() }

    @objc func copyText(_ sender: Any?) {
        if let session, session.view.selectionActive == false, session.copyPromptSelection() { return }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
    }

    @objc func cutText(_ sender: Any?) {
        if let session, session.copyPromptSelection(cut: true) { return }
        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: sender)
    }

    @objc func selectAllText(_ sender: Any?) {
        if let window = NSApp.keyWindow, window.firstResponder is FaroTerminalView, let session, session.selectWholeLine() { return }
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
    }

    @objc func undoEdit(_ sender: Any?) {
        if let window = NSApp.keyWindow, window.firstResponder is FaroTerminalView, let session { session.perform(.undo); return }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }

    @objc func redoEdit(_ sender: Any?) {
        if let window = NSApp.keyWindow, window.firstResponder is FaroTerminalView, let session { session.perform(.redo); return }
        NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
    }

    @objc func newAgentTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let agent = AIAgent(rawValue: raw) else { return }
        if let front { front.newTab(kind: .agent(agent)) } else { AppModel.shared.newWindow(kind: .agent(agent)) }
    }

    @objc func previousPrompt(_ sender: Any?) {
        guard let view = session?.view, let row = view.previousSemanticPromptRow() else { return }
        view.scrollTo(row: row)
    }

    @objc func nextPrompt(_ sender: Any?) {
        guard let view = session?.view, let row = view.nextSemanticPromptRow() else { return }
        view.scrollTo(row: row)
    }

    // MARK: Menú

    private func paneMenuItem() -> NSMenuItem {
        func arrow(_ key: Int) -> String { String(UnicodeScalar(UInt32(key))!) }
        let entries: [(String, Selector, Int, NSEvent.ModifierFlags)] = [
            ("Ir al panel de la izquierda", #selector(paneLeft(_:)), NSLeftArrowFunctionKey, [.command, .option]),
            ("Ir al panel de la derecha", #selector(paneRight(_:)), NSRightArrowFunctionKey, [.command, .option]),
            ("Ir al panel de arriba", #selector(paneUp(_:)), NSUpArrowFunctionKey, [.command, .option]),
            ("Ir al panel de abajo", #selector(paneDown(_:)), NSDownArrowFunctionKey, [.command, .option]),
            ("Mover divisor a la izquierda", #selector(growLeft(_:)), NSLeftArrowFunctionKey, [.command, .control]),
            ("Mover divisor a la derecha", #selector(growRight(_:)), NSRightArrowFunctionKey, [.command, .control]),
            ("Mover divisor arriba", #selector(growUp(_:)), NSUpArrowFunctionKey, [.command, .control]),
            ("Mover divisor abajo", #selector(growDown(_:)), NSDownArrowFunctionKey, [.command, .control]),
        ]
        let menu = NSMenu(title: "Paneles")
        for (index, entry) in entries.enumerated() {
            if index == 4 { menu.addItem(.separator()) }
            let i = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: arrow(entry.2))
            i.keyEquivalentModifierMask = entry.3
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let zoom = NSMenuItem(title: "Ampliar o restaurar panel", action: #selector(zoomPane(_:)), keyEquivalent: "\r")
        zoom.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(zoom)
        let item = NSMenuItem(title: "Paneles", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func agentsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Nueva sesión de IA", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Nueva sesión de IA")
        menu.delegate = self
        item.submenu = menu
        return item
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }

        _ = submenu("Faro", [
            item("Acerca de Faro", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Ajustes…", #selector(showSettings(_:)), ","),
            .separator(),
            item("Ocultar Faro", #selector(NSApplication.hide(_:)), "h"),
            item("Ocultar otras", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Mostrar todo", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Salir de Faro", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = submenu("Shell", [
            item("Nueva pestaña", #selector(newTab(_:)), "t"),
            item("Nueva sesión de Claude Code", #selector(newClaudeTab(_:)), "c", [.command, .shift]),
            agentsMenuItem(),
            item("Nueva ventana", #selector(newWindow(_:)), "n"),
            projectMenu.item(),
            .separator(),
            item("Paleta de comandos…", #selector(showPalette(_:)), "p"),
            item("Explorar carpetas…", #selector(showFolders(_:)), "o"),
            item("Puertos abiertos…", #selector(showPorts(_:)), "p", [.command, .control]),
            editorMenu.item(),
            item("Explicar el último error con Claude", #selector(explainError(_:)), "e", [.command, .shift]),
            .separator(),
            item("Dividir a la derecha", #selector(splitRight(_:)), "d"),
            item("Dividir hacia abajo", #selector(splitDown(_:)), "d", [.command, .shift]),
            paneMenuItem(),
            .separator(),
            item("Cerrar panel", #selector(closeTab(_:)), "w"),
        ])

        let find = item("Buscar…", #selector(TerminalView.performFindPanelAction(_:)), "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        _ = submenu("Edición", [
            item("Deshacer", #selector(undoEdit(_:)), "z"),
            item("Rehacer", #selector(redoEdit(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cortar", #selector(cutText(_:)), "x"),
            item("Copiar", #selector(copyText(_:)), "c"),
            item("Copiar salida del último comando", #selector(copyLastOutput(_:)), "c", [.command, .option]),
            item("Pegar", #selector(NSText.paste(_:)), "v"),
            item("Seleccionar todo", #selector(selectAllText(_:)), "a"),
            .separator(),
            find,
        ])

        _ = submenu("Visualización", [
            item("Pestañas en la barra lateral", #selector(toggleTabsSidebar(_:)), "s", [.command, .control]),
            item("Isla de actividad en el notch", #selector(toggleIsland(_:)), "i", [.command, .control]),
            item("Terminal desplegable con atajo", #selector(toggleDropdownEnabled(_:))),
            .separator(),
            item("Aumentar letra", #selector(biggerFont(_:)), "+"),
            item("Reducir letra", #selector(smallerFont(_:)), "-"),
            item("Tamaño original", #selector(resetFont(_:)), "0"),
            .separator(),
            item("Limpiar pantalla", #selector(clearScreen(_:)), "k"),
            item("Comando anterior", #selector(previousPrompt(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            item("Comando siguiente", #selector(nextPrompt(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!)),
            .separator(),
            item("Pantalla completa", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        var windowItems = [
            item("Terminal desplegable", #selector(toggleDropdown(_:))),
            .separator(),
            item("Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Pestaña siguiente", #selector(nextTab(_:)), "]", [.command, .shift]),
            item("Pestaña anterior", #selector(previousTab(_:)), "[", [.command, .shift]),
        ]
        for n in 1...9 {
            windowItems.append(item(n == 9 ? "Última pestaña" : "Pestaña \(n)", #selector(selectTabNumber(_:)), "\(n)", tag: n))
        }
        NSApp.windowsMenu = submenu("Ventana", windowItems)
        return main
    }
}

extension AppDelegate: NSMenuDelegate {
    /// El submenú de IAs se rellena al abrirlo, con las que estén instaladas y su logo.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dark = AppModel.shared.theme.isDark
        for agent in AppModel.shared.installedAgents {
            let item = NSMenuItem(title: agent.name, action: #selector(newAgentTab(_:)), keyEquivalent: "")
            item.representedObject = agent.rawValue
            if let logo = Logos.image(agent, dark: dark) {
                item.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    logo.draw(in: rect)
                    return true
                }
            }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No hay ninguna instalada", action: nil, keyEquivalent: ""))
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabsSidebar(_:)) {
            menuItem.state = AppModel.shared.settings.tabsInSidebar ? .on : .off
        }
        if menuItem.action == #selector(toggleDropdown(_:)) {
            let settings = AppModel.shared.settings
            menuItem.title = "Terminal desplegable" + (settings.dropdownEnabled ? "  (\(GlobalHotKey.shortcut(settings.dropdownShortcut).label))" : "")
            menuItem.state = Dropdown.shared.isVisible ? .on : .off
        }
        if menuItem.action == #selector(toggleDropdownEnabled(_:)) {
            let settings = AppModel.shared.settings
            menuItem.title = "Terminal desplegable con \(GlobalHotKey.shortcut(settings.dropdownShortcut).label)"
            menuItem.state = settings.dropdownEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleDropdown(_:)) && !AppModel.shared.settings.dropdownEnabled {
            menuItem.title = "Terminal desplegable"
            return false
        }
        if menuItem.action == #selector(toggleIsland(_:)) {
            menuItem.state = AppModel.shared.settings.activityIsland ? .on : .off
        }
        return true
    }
}

/// Shell → Abrir archivos en ▸ VS Code / Cursor / …, con una marca en el elegido.
@MainActor
final class EditorMenu: NSObject, NSMenuDelegate {
    func item() -> NSMenuItem {
        let item = NSMenuItem(title: "Abrir archivos en", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Abrir archivos en")
        menu.delegate = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = Editors.preferred
        for editor in Editors.installed {
            let entry = NSMenuItem(title: editor.name, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = editor.rawValue
            entry.image = Editors.icon(editor)
            entry.state = editor == current ? .on : .off
            menu.addItem(entry)
        }
        let system = NSMenuItem(title: "La app por defecto de cada archivo", action: #selector(choose(_:)), keyEquivalent: "")
        system.target = self
        system.state = current == nil ? .on : .off
        menu.addItem(.separator())
        menu.addItem(system)
    }

    @objc func choose(_ sender: NSMenuItem) {
        Editors.choose((sender.representedObject as? String).flatMap(CodeEditor.init(rawValue:)))
    }
}

/// Shell → Proyectos ▸ Acme, Faro…; crear uno para esta carpeta o guardar la pestaña.
@MainActor
final class ProjectMenu: NSObject, NSMenuDelegate {
    func item() -> NSMenuItem {
        let item = NSMenuItem(title: "Proyectos", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Proyectos")
        menu.delegate = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, project) in Projects.shared.recent.enumerated() {
            let entry = NSMenuItem(title: project.name, action: #selector(open(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            entry.keyEquivalentModifierMask = [.command, .control]
            entry.target = self
            entry.representedObject = project.id
            entry.toolTip = project.summary + "\n" + SuggestionEngine.abbreviate(project.directory)
            entry.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
            menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for (title, selector) in [("Crear proyecto para esta carpeta…", #selector(create(_:))),
                                  ("Guardar esta pestaña como proyecto…", #selector(saveTab(_:))),
                                  ("Gestionar proyectos…", #selector(manage(_:)))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let project = Projects.shared.project(id) else { return }
        Projects.shared.open(project)
    }

    @objc func create(_ sender: Any?) {
        guard let session = AppModel.shared.frontWindow?.model.selected else { return }
        Projects.shared.createForFolder(of: session)
    }

    @objc func saveTab(_ sender: Any?) {
        guard let tab = AppModel.shared.frontWindow?.model.selectedTab else { return }
        Projects.shared.saveTab(tab)
    }

    @objc func manage(_ sender: Any?) { SettingsWindow.show(tab: "projects") }
}

extension NSView {
    /// Está dentro de la barra de acciones de un bloque.
    func isDescendant(ofBlockOverlay _: Void) -> Bool {
        var view: NSView? = self
        while let current = view {
            if current is BlockOverlay { return true }
            view = current.superview
        }
        return false
    }
}
