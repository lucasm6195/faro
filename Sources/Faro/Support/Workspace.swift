import AppKit
import FaroCore

/// Guarda lo que hay abierto (ventanas, pestañas, paneles, carpetas y conversaciones de Claude)
/// y lo recupera al volver a abrir Faro. Se guarda al salir y, por si Faro se cierra de golpe,
/// unos segundos después de cada cambio. Nada se ejecuta mientras no cambia nada.
@MainActor
final class Workspace {
    static let shared = Workspace()

    /// Faro Dev usa su propio archivo: nunca retoma las conversaciones del Faro de verdad.
    nonisolated static let file = AppModel.dataDirectory.appendingPathComponent(AppModel.testMode ? "workspace-test.json" : "workspace.json")

    private var pending: Task<Void, Never>?
    private var restoring = false
    /// Al salir ya se ha guardado: lo que se cierre después no debe borrarlo.
    private(set) var terminating = false

    func setNeedsSave() {
        guard !restoring, !terminating else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let snapshot = self.snapshot()
            await Task.detached(priority: .utility) {
                try? snapshot.resolvingClaudeSessions().save(to: Workspace.file)
            }.value
        }
    }

    /// Al salir: se guarda ya, mientras los Claude siguen vivos para leer su conversación.
    func saveBeforeQuit() {
        pending?.cancel()
        terminating = true
        try? snapshot().resolvingClaudeSessions().save(to: Self.file)
    }

    func cancelQuit() { terminating = false }

    // MARK: Foto de lo abierto

    func snapshot() -> WorkspaceSnapshot {
        // La desplegable no se guarda: es de usar y tirar, y vuelve con el atajo.
        let windows = AppModel.shared.windows.filter { !$0.model.isDropdown }
        let front: TerminalWindowController? = AppModel.shared.frontWindow.flatMap { $0.model.isDropdown ? nil : $0 }
        let ordered = windows.filter { $0 !== front } + (front.map { [$0] } ?? [])
        return WorkspaceSnapshot(windows: ordered.compactMap { controller in
            let tabs = controller.model.tabs
            guard !tabs.isEmpty else { return nil }
            let frame = controller.window.map { w -> [Double] in
                let f = controller.model.isFullScreen ? (w.screen?.visibleFrame ?? w.frame) : w.frame
                return [f.minX, f.minY, f.width, f.height]
            }
            let selected = tabs.firstIndex { $0.id == controller.model.selectedTab?.id } ?? 0
            return .init(frame: frame, tabs: tabs.map(Self.tab), selectedTab: selected)
        })
    }

    private static func tab(_ tab: TerminalTab) -> WorkspaceSnapshot.Tab {
        let sessions = tab.sessions
        return .init(root: pane(tab.root),
                     focused: sessions.firstIndex { $0.id == tab.focusedID } ?? 0,
                     zoomed: tab.zoomedID.flatMap { id in sessions.firstIndex { $0.id == id } },
                     project: tab.projectID)
    }

    private static func pane(_ node: PaneNode) -> WorkspaceSnapshot.Pane {
        switch node {
        case .leaf(let session):
            var agentTab = false
            if case .agent = session.kind { agentTab = true }
            return .leaf(.init(directory: session.cwd, agent: session.agent?.rawValue, agentTab: agentTab, shellPid: session.shellPid))
        case .split(let split):
            return .split(horizontal: split.axis == .horizontal, fraction: split.fraction, first: pane(split.first), second: pane(split.second))
        }
    }

    // MARK: Recuperar

    /// Vuelve a abrir lo de la última vez. Devuelve false si no había nada que recuperar.
    func restore() -> Bool {
        guard AppModel.shared.settings.restoreSession,
              let snapshot = WorkspaceSnapshot.load(from: Self.file), !snapshot.windows.isEmpty else { return false }
        restoring = true
        defer { restoring = false }
        for window in snapshot.windows {
            AppModel.shared.restoreWindow(window)
        }
        return !AppModel.shared.windows.isEmpty
    }
}
