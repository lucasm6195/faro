import Foundation

/// Lo que se puede saber de una herramienta de IA mirando su pantalla.
public struct AgentScreen: Equatable, Sendable {
    /// Está generando o ejecutando algo (muestra «esc to interrupt» o similar).
    public var working = false
    /// Te está preguntando algo y espera tu respuesta.
    public var needsInput = false
    /// Tareas de su lista hechas y en total, si muestra una lista.
    public var tasksDone: Int?
    public var tasksTotal: Int?
    /// Lo que dice que está haciendo («Leyendo archivos…»), si se ve.
    public var status: String?

    public init(working: Bool = false, needsInput: Bool = false, tasksDone: Int? = nil, tasksTotal: Int? = nil, status: String? = nil) {
        self.working = working
        self.needsInput = needsInput
        self.tasksDone = tasksDone
        self.tasksTotal = tasksTotal
        self.status = status
    }

    /// Avance de 0 a 1 según la lista de tareas, si la hay.
    public var progress: Double? {
        guard let done = tasksDone, let total = tasksTotal, total > 0 else { return nil }
        return Double(done) / Double(total)
    }
}

/// Lee la pantalla de Claude Code, Codex, Gemini CLI, OpenCode… Son heurísticas sobre lo que
/// esas herramientas muestran; si cambian su texto, simplemente se pierde el detalle.
public enum AgentScreenReader {
    static let workingMarkers = ["esc to interrupt", "esc to cancel", "ctrl+c to interrupt", "press esc to stop"]
    static let questionMarkers = [
        "do you want to", "would you like to", "allow this", "approve", "(y/n)", "[y/n]", "yes, and don't ask",
        "¿quieres", "¿deseas", "permitir", "waiting for your", "press enter to continue",
    ]
    static let pendingBoxes: Set<Character> = ["☐", "◻", "□", "◯", "○"]
    static let doneBoxes: Set<Character> = ["☒", "☑", "✔", "✓", "✅", "◼", "■"]

    public static func read(_ lines: [String]) -> AgentScreen {
        var screen = AgentScreen()
        let recent = lines.suffix(40)

        for line in recent.reversed() {
            let lower = line.lowercased()
            if workingMarkers.contains(where: lower.contains) || isSpinner(line) {
                screen.working = true
                screen.status = statusText(line)
                break
            }
        }
        let tail = recent.suffix(14).map { $0.lowercased() }
        let asks = tail.contains { line in questionMarkers.contains(where: line.contains) }
        // Un menú de opciones («❯ 1. Yes») manda aunque siga a la vista la línea de «trabajando».
        let menu = tail.contains { $0.range(of: #"^\s*(❯|>)?\s*1\.\s"#, options: .regularExpression) != nil }
        if asks && (menu || !screen.working) {
            screen.needsInput = true
            screen.working = false
        }

        // La lista de tareas más reciente: líneas seguidas que empiezan por una casilla.
        var done = 0, total = 0, inBlock = false
        for line in recent.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .drop { $0 == "⎿" || $0 == "│" || $0 == " " || $0 == "-" || $0 == "*" }
            guard let first = trimmed.first else {
                if inBlock { break } else { continue }
            }
            if doneBoxes.contains(first) {
                done += 1; total += 1; inBlock = true
            } else if pendingBoxes.contains(first) {
                total += 1; inBlock = true
            } else if inBlock {
                break
            }
        }
        if total >= 2 {
            screen.tasksDone = done
            screen.tasksTotal = total
        }
        return screen
    }

    /// La línea de «trabajando» de Claude Code y similares, aunque no diga «esc to interrupt»
    /// (en paneles estrechos no cabe): «✻ Fermenting… (5s · thinking)», «· Running… (1m 20s)».
    static func isSpinner(_ line: String) -> Bool {
        line.range(of: #"…\s*\((\d+m\s*)?\d+s\b"#, options: .regularExpression) != nil
    }

    /// «✻ Pondering… (12s · ↑ 1.2k tokens · esc to interrupt)» → «Pondering…»
    static func statusText(_ line: String) -> String? {
        var text = line
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        text = text.trimmingCharacters(in: .whitespaces)
        while let first = text.first, !first.isLetter && !first.isNumber { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 60, !text.lowercased().contains("esc to") else { return nil }
        return text
    }
}

/// Estado de una herramienta de IA a lo largo del tiempo: trabajando → terminado.
public struct AgentTracker: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case working(since: Date)
        case needsInput
        case finished(at: Date, after: TimeInterval)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var screen = AgentScreen()
    private var quietPolls = 0
    private var workStarted: Date?

    public init() {}

    /// Se llama cada segundo con la pantalla actual. Devuelve true si la fase ha cambiado.
    @discardableResult
    public mutating func update(_ screen: AgentScreen, outputRecently: Bool, now: Date = Date()) -> Bool {
        self.screen = screen
        let old = phase
        if screen.working {
            quietPolls = 0
            if workStarted == nil { workStarted = now }
            if case .working = phase {} else { phase = .working(since: workStarted ?? now) }
        } else if screen.needsInput {
            quietPolls = 0
            phase = .needsInput
        } else if case .working(let since) = phase {
            // Dos lecturas seguidas sin señales de trabajo ni salida nueva: ha terminado.
            quietPolls = outputRecently ? 0 : quietPolls + 1
            if quietPolls >= 2 {
                let duration = now.timeIntervalSince(since)
                phase = duration >= 4 ? .finished(at: now, after: duration) : .idle
                workStarted = nil
            }
        } else if phase == .needsInput {
            phase = .idle
        }
        return phase != old
    }

    public mutating func acknowledge() {
        if case .finished = phase { phase = .idle }
    }
}
