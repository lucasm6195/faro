import AppKit
import FaroCore
import Observation

/// Proyectos guardados: «Abrir Acme» monta su pestaña (Claude, servidor, git…) de un clic.
@MainActor
@Observable
final class Projects {
    static let shared = Projects()

    /// Faro Dev usa su propio archivo.
    nonisolated static let file = AppModel.dataDirectory.appendingPathComponent(
        DemoMode.enabled ? "projects-demo.json" : AppModel.testMode ? "projects-test.json" : "projects.json")

    private(set) var all: [Project]

    private init() {
        all = ProjectStore.load(from: Self.file)
    }

    /// Los abiertos más recientemente primero.
    var recent: [Project] {
        all.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { id in all.first { $0.id == id } } }

    private func persist() {
        let snapshot = all
        Task.detached(priority: .utility) { try? ProjectStore.save(snapshot, to: Projects.file) }
    }

    func update(_ project: Project) {
        if let i = all.firstIndex(where: { $0.id == project.id }) { all[i] = project } else { all.append(project) }
        persist()
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        persist()
    }

    // MARK: Abrir

    /// Si ya está abierto, te lleva a su pestaña; si no, la monta en la ventana de delante.
    func open(_ project: Project) {
        for controller in AppModel.shared.windows {
            if let tab = controller.model.tabs.first(where: { $0.projectID == project.id }) {
                controller.window?.makeKeyAndOrderFront(nil)
                controller.select(tab)
                NSApp.activate()
                return
            }
        }
        var opened = project
        opened.lastOpened = Date()
        update(opened)
        if let front = AppModel.shared.frontWindow {
            front.openProject(opened)
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = AppModel.shared.newWindow(directory: project.directory)
            controller.openProject(opened, replacingOnlyTab: true)
        }
    }

    // MARK: Crear

    /// Propone un proyecto para la carpeta de esta terminal (Claude + servidor + shell) y lo abre.
    func createForFolder(of session: TerminalSession) {
        let directory = session.context.gitRoot ?? session.context.root ?? session.cwd
        if let existing = all.first(where: { $0.directory == directory }) {
            open(existing)
            return
        }
        let context = ProjectDetector.detect(directory: directory)
        let claude = AppModel.shared.installedAgents.contains(.claude)
        let project = Project.suggested(directory: directory, context: context, claude: claude)
        guard let named = askName(for: project, message: "Se abrirá así: \(project.summary). Luego puedes cambiar los comandos en Ajustes → Proyectos.") else { return }
        update(named)
        open(named)
    }

    /// Guarda la pestaña tal como está (paneles, carpetas y lo que corre en cada uno).
    func saveTab(_ tab: TerminalTab) {
        guard let first = tab.sessions.first else { return }
        let directory = first.context.gitRoot ?? first.context.root ?? first.cwd
        let layout = Self.pane(tab.root, base: directory)
        let existing = project(tab.projectID) ?? all.first { $0.directory == directory }
        var project = Project(id: existing?.id ?? UUID(), name: existing?.name ?? (directory as NSString).lastPathComponent,
                              directory: directory, layout: layout, lastOpened: Date())
        let message = existing == nil
            ? "Al abrirlo se montará esta pestaña: \(project.summary)."
            : "Se actualizará «\(project.name)» con esta pestaña: \(project.summary)."
        guard let named = askName(for: project, title: existing == nil ? "Nombre del proyecto" : "Actualizar proyecto", message: message) else { return }
        project = named
        update(project)
        tab.projectID = project.id
    }

    private static func pane(_ node: PaneNode, base: String) -> Project.Pane {
        switch node {
        case .leaf(let session):
            var command = session.runningCommand
            // Las IAs se guardan con su comando normal (sin `--resume <id>` de esta sesión).
            if let agent = session.agent { command = agent.launchCommand }
            return .terminal(directory: session.cwd == base ? nil : session.cwd, command: command)
        case .split(let split):
            return .split(horizontal: split.axis == .horizontal, fraction: split.fraction,
                          first: pane(split.first, base: base), second: pane(split.second, base: base))
        }
    }

    private func askName(for project: Project, title: String = "Nombre del proyecto", message: String) -> Project? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: project.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var named = project
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { named.name = name }
        return named
    }
}
