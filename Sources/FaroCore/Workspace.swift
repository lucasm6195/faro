import Foundation

/// Lo que hay abierto en Faro (ventanas, pestañas, paneles y carpetas), para recuperarlo al
/// volver a abrir. No guarda la salida de los terminales, solo dónde estaba cada uno y qué IA
/// tenía en marcha.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var windows: [Window]
    public var savedAt: Date

    public init(windows: [Window], savedAt: Date = Date()) {
        self.windows = windows
        self.savedAt = savedAt
    }

    public struct Window: Codable, Equatable, Sendable {
        /// x, y, ancho y alto en coordenadas de pantalla.
        public var frame: [Double]?
        public var tabs: [Tab]
        public var selectedTab: Int

        public init(frame: [Double]?, tabs: [Tab], selectedTab: Int) {
            self.frame = frame
            self.tabs = tabs
            self.selectedTab = selectedTab
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var root: Pane
        /// Posición (en orden de lectura) del panel activo y del ampliado.
        public var focused: Int
        public var zoomed: Int?
        /// Proyecto del que viene la pestaña.
        public var project: UUID?

        public init(root: Pane, focused: Int, zoomed: Int? = nil, project: UUID? = nil) {
            self.root = root
            self.focused = focused
            self.zoomed = zoomed
            self.project = project
        }
    }

    public indirect enum Pane: Codable, Equatable, Sendable {
        case leaf(Leaf)
        /// `horizontal`: uno al lado del otro.
        case split(horizontal: Bool, fraction: Double, first: Pane, second: Pane)

        public var leaves: [Leaf] {
            switch self {
            case .leaf(let leaf): [leaf]
            case .split(_, _, let a, let b): a.leaves + b.leaves
            }
        }

        public func mapLeaves(_ transform: (Leaf) -> Leaf) -> Pane {
            switch self {
            case .leaf(let leaf): .leaf(transform(leaf))
            case .split(let h, let f, let a, let b): .split(horizontal: h, fraction: f, first: a.mapLeaves(transform), second: b.mapLeaves(transform))
            }
        }
    }

    public struct Leaf: Codable, Equatable, Sendable {
        public var directory: String
        /// La IA que tenía en marcha (`claude`, `codex`…), si tenía una.
        public var agent: String?
        /// Abierta como pestaña de IA (al salir de la IA se cierra), no como shell.
        public var agentTab: Bool
        /// Conversación de Claude Code que había en el panel, para retomarla. "" si Claude estaba
        /// abierto pero aún sin ningún mensaje (se abre uno nuevo).
        public var claudeSession: String?
        /// Solo mientras se guarda: la shell del panel, para buscar su Claude.
        public var shellPid: Int32?

        public init(directory: String, agent: String? = nil, agentTab: Bool = false, claudeSession: String? = nil, shellPid: Int32? = nil) {
            self.directory = directory
            self.agent = agent
            self.agentTab = agentTab
            self.claudeSession = claudeSession
            self.shellPid = shellPid
        }

        enum CodingKeys: String, CodingKey { case directory, agent, agentTab, claudeSession }

        /// Comando para volver a abrir su IA: Claude retoma su conversación; las demás empiezan de nuevo.
        public var resumeCommand: String? {
            guard let raw = agent, let agent = AIAgent(rawValue: raw) else { return nil }
            if agent == .claude {
                if let id = claudeSession, ClaudeSessions.isValidID(id) { return "claude --resume \(id)" }
                return claudeSession == "" ? "claude" : "claude --continue"
            }
            return agent.launchCommand
        }
    }

    // MARK: Archivo

    public static func load(from url: URL) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WorkspaceSnapshot.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Rellena la conversación de Claude de cada panel mirando qué Claude corre bajo su shell.
    public func resolvingClaudeSessions(directory: URL = ClaudeSessions.defaultDirectory) -> WorkspaceSnapshot {
        let children = PortScanner.childrenTable()
        var copy = self
        copy.windows = windows.map { window in
            var w = window
            w.tabs = window.tabs.map { tab in
                var t = tab
                t.root = tab.root.mapLeaves { leaf in
                    var l = leaf
                    guard let shell = leaf.shellPid else { return l }
                    if let found = ClaudeSessions.running(under: shell, children: children, directory: directory) {
                        l.agent = AIAgent.claude.rawValue
                        l.claudeSession = found
                    }
                    return l
                }
                return t
            }
            return w
        }
        return copy
    }
}

/// Las conversaciones de Claude Code: cada proceso de Claude deja una ficha en
/// `~/.claude/sessions/<pid>.json` con el id de su conversación.
public enum ClaudeSessions {
    public static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)

    /// Id de la conversación del Claude que corre bajo esa shell (o es ella), si hay uno; "" si
    /// hay un Claude pero todavía sin conversación guardada.
    public static func running(under shell: Int32, children: [Int32: [Int32]], directory: URL = defaultDirectory) -> String? {
        var queue = [shell]
        var seen: Set<Int32> = []
        while let pid = queue.popLast(), seen.insert(pid).inserted {
            if let id = sessionID(pid: pid, directory: directory) { return id }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return nil
    }

    static func sessionID(pid: Int32, directory: URL) -> String? {
        let file = directory.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? Int).map(Int32.init) == pid,
              let id = object["sessionId"] as? String, isValidID(id) else { return nil }
        // Sin ningún mensaje todavía no hay conversación que retomar.
        return hasTranscript(id, directory: directory) ? id : ""
    }

    static func hasTranscript(_ id: String, directory: URL) -> Bool {
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return false }
        return dirs.contains { FileManager.default.fileExists(atPath: projects.appendingPathComponent("\($0)/\(id).jsonl").path) }
    }

    /// Solo ids con forma de UUID: el id acaba en un comando de la shell.
    public static func isValidID(_ id: String) -> Bool {
        id.count <= 64 && !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") }
    }
}
