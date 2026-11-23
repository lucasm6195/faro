import Foundation

/// Herramientas de IA para la terminal. Faro las reconoce al ejecutarse (para mostrar su logo)
/// y permite abrir una sesión nueva de cualquiera que esté instalada.
public enum AIAgent: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, opencode, cursor, copilot, qwen, grok, ollama

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .cursor: "Cursor Agent"
        case .copilot: "Copilot CLI"
        case .qwen: "Qwen Code"
        case .grok: "Grok CLI"
        case .ollama: "Ollama"
        }
    }

    /// Nombre corto para la pestaña.
    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .qwen: "Qwen"
        case .grok: "Grok"
        case .ollama: "Ollama"
        }
    }

    /// Programas que lo arrancan.
    public var executables: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .gemini: ["gemini"]
        case .opencode: ["opencode"]
        case .cursor: ["cursor-agent"]
        case .copilot: ["copilot"]
        case .qwen: ["qwen"]
        case .grok: ["grok"]
        case .ollama: ["ollama"]
        }
    }

    /// Comando para abrir una sesión nueva.
    public var launchCommand: String {
        switch self {
        case .ollama: "ollama run llama3.2"
        default: executables[0]
        }
    }

    /// Archivo del logo (de svgl.app) para fondo claro y oscuro.
    public var logo: (light: String, dark: String) {
        switch self {
        case .claude: ("claude-ai-icon", "claude-ai-icon")
        case .codex: ("openai", "openai_dark")
        case .gemini: ("gemini", "gemini")
        case .opencode: ("opencode", "opencode-dark")
        case .cursor: ("cursor_light", "cursor_dark")
        case .copilot: ("copilot", "copilot_dark")
        case .qwen: ("qwen_light", "qwen_dark")
        case .grok: ("grok-light", "grok-dark")
        case .ollama: ("ollama_light", "ollama_dark")
        }
    }

    /// Reconoce el agente a partir de la línea de comando (`claude --continue`, `npx codex`…).
    public static func detect(command: String) -> AIAgent? {
        // «clear; claude …» o «cd x && codex»: cuenta lo último que se ejecuta.
        if let last = lastSegment(of: command), last != command { return detect(command: last) }
        var words = command.split(separator: " ").map(String.init)
        while let first = words.first, ["npx", "bunx", "pnpx", "sudo", "exec", "command"].contains(first) || first.contains("=") {
            words.removeFirst()
        }
        guard let first = words.first else { return nil }
        let name = (first as NSString).lastPathComponent
        return allCases.first { $0.executables.contains(name) || ($0 == .codex && name == "@openai/codex") }
    }

    /// El último comando de una línea con «;», «&&» o «||» (sin mirar dentro de las comillas).
    static func lastSegment(of command: String) -> String? {
        var quote: Character?
        var start = command.startIndex
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ";" || c == "&" || c == "|" {
                start = command.index(after: i)
            }
            i = command.index(after: i)
        }
        let last = command[start...].trimmingCharacters(in: .whitespaces)
        return last.isEmpty ? nil : last
    }
}
