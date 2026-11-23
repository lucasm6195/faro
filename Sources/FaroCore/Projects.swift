import Foundation

/// Un proyecto: una carpeta y cómo te gusta tenerla abierta (paneles y qué corre en cada uno).
/// «Abrir Acme» monta la pestaña entera de un clic.
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directory: String
    public var layout: Pane
    public var lastOpened: Date?

    public init(id: UUID = UUID(), name: String, directory: String, layout: Pane, lastOpened: Date? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.layout = layout
        self.lastOpened = lastOpened
    }

    public indirect enum Pane: Codable, Equatable, Sendable {
        /// Un terminal: su carpeta (nil = la del proyecto) y lo que se lanza al abrirlo.
        case terminal(directory: String?, command: String?)
        /// `horizontal`: uno al lado del otro.
        case split(horizontal: Bool, fraction: Double, first: Pane, second: Pane)

        public var terminals: [(directory: String?, command: String?)] {
            switch self {
            case .terminal(let d, let c): [(d, c)]
            case .split(_, _, let a, let b): a.terminals + b.terminals
            }
        }

        /// Cambia el comando del terminal número `index` (en orden de lectura).
        public func settingCommand(_ command: String?, at index: Int) -> Pane {
            var counter = 0
            func walk(_ pane: Pane) -> Pane {
                switch pane {
                case .terminal(let d, let c):
                    defer { counter += 1 }
                    return counter == index ? .terminal(directory: d, command: command) : .terminal(directory: d, command: c)
                case .split(let h, let f, let a, let b):
                    let first = walk(a)
                    return .split(horizontal: h, fraction: f, first: first, second: walk(b))
                }
            }
            return walk(self)
        }
    }

    /// «Claude · npm run dev · shell»
    public var summary: String {
        layout.terminals.map { t in
            guard let command = t.command, !command.isEmpty else { return "shell" }
            if let agent = AIAgent.detect(command: command) { return agent.shortName }
            return command
        }.joined(separator: " · ")
    }

    // MARK: Propuesta para una carpeta

    /// El comando que arranca el proyecto en desarrollo, si se reconoce.
    public static func devCommand(_ context: ProjectContext) -> String? {
        let commands = context.commands.map(\.command)
        for suffix in [" dev", " start"] {
            if let found = commands.first(where: { $0.hasSuffix(suffix) && !$0.contains("&&") }) { return found }
        }
        if let expo = commands.first(where: { $0 == "npx expo start" }) { return expo }
        return nil
    }

    /// Claude a la izquierda; a la derecha el servidor arriba y una shell abajo (para git).
    /// Sin Claude o sin servidor, se quitan esos paneles.
    public static func suggested(directory: String, context: ProjectContext, claude: Bool) -> Project {
        let name = (directory as NSString).lastPathComponent
        let dev = devCommand(context)
        let shell = Pane.terminal(directory: nil, command: nil)
        let right: Pane = dev.map { .split(horizontal: false, fraction: 0.5, first: .terminal(directory: nil, command: $0), second: shell) } ?? shell
        let layout: Pane = claude
            ? .split(horizontal: true, fraction: 0.55, first: .terminal(directory: nil, command: "claude"), second: right)
            : right
        return Project(name: name, directory: directory, layout: layout)
    }
}

/// Los proyectos guardados, en `~/Library/Application Support/Faro/projects.json`.
public enum ProjectStore {
    public static func load(from url: URL) -> [Project] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Project].self, from: data)) ?? []
    }

    public static func save(_ projects: [Project], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(projects).write(to: url, options: .atomic)
    }
}
