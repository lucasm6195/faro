import AppKit
import FaroCore
import Observation
import SwiftUI

@MainActor
@Observable
final class WindowModel {
    var tabs: [TerminalTab] = []
    var selectedTabID: UUID?
    var paletteVisible = false
    var folderBrowserVisible = false
    var portsVisible = false
    var isKey = true
    var isFullScreen = false
    /// La terminal desplegable del atajo global: sin semáforos, pegada arriba de la pantalla.
    var isDropdown = false
    /// Solo para el vídeo de presentación: el guion escribe en la paleta y la confirma.
    var demoQuery: String?
    var demoSubmit = 0

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } ?? tabs.first }
    /// Panel activo de la pestaña activa.
    var selected: TerminalSession? { selectedTab?.focused }
    /// Todas las terminales de la ventana, en todas las pestañas y paneles.
    var allSessions: [TerminalSession] { tabs.flatMap(\.sessions) }

    func tab(containing session: TerminalSession) -> TerminalTab? { tabs.first { $0.contains(session) } }
}

/// Ventana sin el marco del sistema: así las esquinas pueden ser pequeñas (10 pt) y el borde
/// de medio píxel. Los semáforos los dibuja Faro.
final class FaroWindow: NSWindow {
    static let cornerRadius: CGFloat = 10

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable, .miniaturizable, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.fullScreenPrimary, .managed]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }

    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    override func performZoom(_ sender: Any?) { zoom(sender) }
}

/// Recorta el contenido con esquinas redondeadas y dibuja el borde fino.
final class RoundedContainer: NSView {
    init(content: NSView) {
        super.init(frame: content.frame)
        wantsLayer = true
        layer?.cornerRadius = FaroWindow.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func style(border: NSColor, fullScreen: Bool, dropdown: Bool = false) {
        layer?.cornerRadius = fullScreen ? 0 : FaroWindow.cornerRadius
        layer?.borderWidth = fullScreen ? 0 : 0.5
        layer?.borderColor = border.cgColor
        // La desplegable cuelga del borde de arriba: solo redondea las esquinas de abajo.
        layer?.maskedCorners = dropdown ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let model = WindowModel()
    private var container: RoundedContainer?
    private var responderObservation: NSKeyValueObservation?

    init(dropdown: Bool = false) {
        let window = FaroWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620))
        window.minSize = NSSize(width: 480, height: 200)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        if dropdown {
            // Encima de todo, en todos los escritorios y también sobre apps a pantalla completa.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isMovable = false
            window.styleMask.remove(.resizable)
        } else {
            window.setFrameAutosaveName("FaroVentana")
            if AppModel.shared.windows.contains(where: { !$0.model.isDropdown }), let last = AppModel.shared.frontWindow?.window {
                window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 28, y: last.frame.maxY - 28))
            } else if !window.setFrameUsingName("FaroVentana") {
                window.center()
            }
        }
        super.init(window: window)
        model.isDropdown = dropdown
        window.delegate = self
        let container = RoundedContainer(content: NSHostingView(rootView: RootView(controller: self, model: model)))
        window.contentView = container
        self.container = container
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.firstResponderChanged() } }
        }
        applySettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Pestañas

    private func makeSession(directory: String?, kind: TerminalSession.Kind, startupCommand: String?) -> TerminalSession {
        let dir = directory ?? model.selected?.cwd ?? (DemoMode.enabled ? DemoMode.app : NSHomeDirectory())
        let session = TerminalSession(directory: dir, kind: kind, startupCommand: startupCommand)
        session.window = self
        return session
    }

    @discardableResult
    func newTab(directory: String? = nil, kind: TerminalSession.Kind = .shell, startupCommand: String? = nil) -> TerminalSession {
        let session = makeSession(directory: directory, kind: kind, startupCommand: startupCommand)
        let tab = TerminalTab(session: session)
        if let current = model.selectedTab, let index = model.tabs.firstIndex(where: { $0 === current }) {
            model.tabs.insert(tab, at: index + 1)
        } else {
            model.tabs.append(tab)
        }
        session.start()
        select(tab)
        Workspace.shared.setNeedsSave()
        return session
    }

    /// Vuelve a montar las pestañas y paneles de una ventana guardada.
    func restore(_ snapshot: WorkspaceSnapshot.Window) {
        if let f = snapshot.frame, f.count == 4 {
            let frame = NSRect(x: f[0], y: f[1], width: max(f[2], 480), height: max(f[3], 280))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { window?.setFrame(frame, display: false) }
        }
        for saved in snapshot.tabs {
            let root = build(saved.root)
            let sessions = root.sessions
            guard let first = sessions.first else { continue }
            let tab = TerminalTab(session: first)
            tab.root = root
            tab.focusedID = sessions[safe: saved.focused]?.id ?? first.id
            tab.zoomedID = saved.zoomed.flatMap { sessions[safe: $0]?.id }
            tab.projectID = saved.project
            model.tabs.append(tab)
            for session in sessions { session.start() }
        }
        if let tab = model.tabs[safe: snapshot.selectedTab] ?? model.tabs.first { select(tab) }
    }

    /// Monta la pestaña de un proyecto. `replacingOnlyTab`: en una ventana recién creada,
    /// sustituye la pestaña vacía con la que nace.
    func openProject(_ project: Project, replacingOnlyTab: Bool = false) {
        let initial = replacingOnlyTab ? model.tabs.first : nil
        let root = build(project.layout, base: project.directory)
        let sessions = root.sessions
        guard let first = sessions.first else { return }
        let tab = TerminalTab(session: first)
        tab.root = root
        tab.projectID = project.id
        if let current = model.selectedTab, let index = model.tabs.firstIndex(where: { $0 === current }) {
            model.tabs.insert(tab, at: index + 1)
        } else {
            model.tabs.append(tab)
        }
        for session in sessions { session.start() }
        select(tab)
        if let initial { closeTab(initial) }
        Workspace.shared.setNeedsSave()
    }

    private func build(_ pane: Project.Pane, base: String) -> PaneNode {
        switch pane {
        case .terminal(let directory, let command):
            let fm = FileManager.default
            let dir = [directory, base].compactMap { $0 }.first { fm.fileExists(atPath: $0) } ?? NSHomeDirectory()
            let text = command?.trimmingCharacters(in: .whitespaces)
            return .leaf(makeSession(directory: dir, kind: .shell, startupCommand: text?.isEmpty == false ? text : nil))
        case .split(let horizontal, let fraction, let first, let second):
            let split = PaneSplit(axis: horizontal ? .horizontal : .vertical, first: build(first, base: base), second: build(second, base: base))
            split.fraction = min(max(fraction, 0.1), 0.9)
            return .split(split)
        }
    }

    private func build(_ pane: WorkspaceSnapshot.Pane) -> PaneNode {
        switch pane {
        case .leaf(let leaf):
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: leaf.directory, isDirectory: &isDir) && isDir.boolValue
            let agent = leaf.agent.flatMap(AIAgent.init(rawValue:))
            let kind: TerminalSession.Kind = leaf.agentTab && agent != nil ? .agent(agent!) : .shell
            return .leaf(makeSession(directory: exists ? leaf.directory : NSHomeDirectory(), kind: kind, startupCommand: leaf.resumeCommand))
        case .split(let horizontal, let fraction, let first, let second):
            let split = PaneSplit(axis: horizontal ? .horizontal : .vertical, first: build(first), second: build(second))
            split.fraction = min(max(fraction, 0.1), 0.9)
            return .split(split)
        }
    }

    func select(_ tab: TerminalTab) {
        model.selectedTabID = tab.id
        model.folderBrowserVisible = false
        for s in tab.sessions { s.hasUnseenActivity = false }
        focusTerminal()
        Island.shared.refresh()
        Workspace.shared.setNeedsSave()
    }

    /// Activa un panel (y su pestaña).
    func focus(_ session: TerminalSession) {
        guard let tab = model.tab(containing: session) else { return }
        tab.focusedID = session.id
        session.hasUnseenActivity = false
        if model.selectedTabID != tab.id { select(tab) } else { focusTerminal() }
        Island.shared.refresh()
    }

    func selectTab(offset: Int) {
        guard let current = model.selectedTab, let i = model.tabs.firstIndex(where: { $0 === current }) else { return }
        let n = model.tabs.count
        select(model.tabs[((i + offset) % n + n) % n])
    }

    func selectTab(number: Int) {
        guard !model.tabs.isEmpty else { return }
        select(number >= 9 || number > model.tabs.count ? model.tabs[model.tabs.count - 1] : model.tabs[number - 1])
    }

    func closeTab(_ tab: TerminalTab) {
        guard let index = model.tabs.firstIndex(where: { $0 === tab }) else { return }
        for s in tab.sessions { s.close() }
        model.tabs.remove(at: index)
        Workspace.shared.setNeedsSave()
        if model.tabs.isEmpty {
            window?.close()
        } else if model.selectedTabID == tab.id || model.selectedTabID == nil {
            select(model.tabs[min(index, model.tabs.count - 1)])
        }
    }

    /// Cierra un panel; si era el único de su pestaña, cierra la pestaña.
    func close(_ session: TerminalSession) {
        guard let tab = model.tab(containing: session) else { return }
        if tab.remove(session) {
            session.close()
            focusTerminal()
            Workspace.shared.setNeedsSave()
        } else {
            closeTab(tab)
        }
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = model.tabs.remove(at: from)
        let to = model.tabs.firstIndex(where: { $0.id == target }) ?? model.tabs.count
        model.tabs.insert(tab, at: to)
        Workspace.shared.setNeedsSave()
    }

    func sessionEnded(_ session: TerminalSession) {
        close(session)
    }

    func isVisible(_ session: TerminalSession) -> Bool {
        guard let tab = model.selectedTab, tab.contains(session) else { return false }
        return tab.zoomedID == nil || tab.zoomedID == session.id
    }

    // MARK: Paneles

    @discardableResult
    func split(_ axis: SplitAxis, kind: TerminalSession.Kind = .shell, startupCommand: String? = nil,
               from source: TerminalSession? = nil) -> TerminalSession? {
        guard let target = source ?? model.selected, let tab = model.tab(containing: target) else { return nil }
        let session = makeSession(directory: target.cwd, kind: kind, startupCommand: startupCommand)
        // Tamaño aproximado del panel nuevo antes de arrancar la shell, para que empiece con
        // las columnas correctas y no tenga que redibujar el primer prompt.
        var frame = target.view.bounds
        if axis == .horizontal { frame.size.width = max(200, frame.width / 2 - 1) } else { frame.size.height = max(120, frame.height / 2 - 1) }
        session.view.frame = frame
        tab.split(target, adding: session, axis: axis)
        session.start()
        Workspace.shared.setNeedsSave()
        if model.selectedTabID != tab.id { select(tab) } else { focusTerminal() }
        return session
    }

    func focusPane(_ direction: PaneDirection) {
        guard let tab = model.selectedTab, tab.zoomedID == nil,
              let id = tab.neighbour(of: tab.focusedID, direction),
              let session = tab.sessions.first(where: { $0.id == id }) else { return }
        focus(session)
    }

    func resizePane(_ direction: PaneDirection) {
        guard let tab = model.selectedTab else { return }
        tab.resize(tab.focusedID, direction)
    }

    func toggleZoom() {
        guard let tab = model.selectedTab, tab.isSplit else { return }
        tab.zoomedID = tab.zoomedID == nil ? tab.focusedID : nil
        focusTerminal()
    }

    /// Si el foco del teclado pasa a otro panel (por un clic), lo marcamos como activo.
    func firstResponderChanged() {
        guard let view = window?.firstResponder as? FaroTerminalView, let session = view.session,
              let tab = model.tab(containing: session), tab.focusedID != session.id else { return }
        tab.focusedID = session.id
        session.hasUnseenActivity = false
        Island.shared.refresh()
    }

    func applySettings() {
        let app = AppModel.shared
        container?.style(border: app.palette.nsHairline, fullScreen: model.isFullScreen, dropdown: model.isDropdown)
        window?.invalidateShadow()
        window?.appearance = NSAppearance(named: app.theme.isDark ? .darkAqua : .aqua)
        for session in model.allSessions {
            session.view.apply(settings: app.settings, theme: app.theme)
        }
    }

    func togglePalette() {
        model.paletteVisible.toggle()
        if !model.paletteVisible, let view = model.selected?.view { window?.makeFirstResponder(view) }
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let session = self.model.selected else { return }
                self.window?.makeFirstResponder(session.view)
                session.updateCaret()
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for session in model.allSessions { session.close() }
        model.tabs.removeAll()
        AppModel.shared.windowClosed(self)
        if model.isDropdown { Dropdown.shared.closed() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.isKey = true
        // Puede que hayas cambiado archivos en el editor mientras tanto.
        for session in model.selectedTab?.sessions ?? [] { session.refreshGit() }
        focusTerminal()
        model.selected?.hasUnseenActivity = false
    }

    func windowDidResignKey(_ notification: Notification) { model.isKey = false }

    func windowDidResize(_ notification: Notification) {
        window?.invalidateShadow()
        Workspace.shared.setNeedsSave()
    }

    func windowDidMove(_ notification: Notification) { Workspace.shared.setNeedsSave() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        model.isFullScreen = true
        applySettings()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
        applySettings()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = model.allSessions.compactMap(\.runningCommand)
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Cerrar la ventana?"
        alert.informativeText = "Hay \(running.count == 1 ? "un programa" : "\(running.count) programas") en marcha: \(running.prefix(3).joined(separator: ", "))."
        alert.addButton(withTitle: "Cerrar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
