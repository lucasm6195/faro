import AppKit
import FaroCore
import SwiftUI

/// Barra inferior: rama, cambios sin guardar en un commit y commits por subir (↑) o bajar (↓).
/// Al pulsarlo se abre el panel de git.
struct GitBadge: View {
    let session: TerminalSession
    let branch: String
    @Environment(\.palette) private var palette
    @State private var showing = false
    private static let amber = Color(red: 0.95, green: 0.68, blue: 0.3)

    var body: some View {
        let git = session.git
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold))
                    Text(git?.branch ?? branch).font(.ui(11.5)).lineLimit(1)
                }
                if let git {
                    if git.conflicts > 0 {
                        Text("!\(git.conflicts)").foregroundStyle(palette.failure)
                    }
                    if git.changes > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Self.amber).frame(width: 5, height: 5)
                            Text("\(git.changes)")
                        }
                    }
                    if git.ahead > 0 { Text("↑\(git.ahead)") }
                    if git.behind > 0 { Text("↓\(git.behind)").foregroundStyle(palette.accent) }
                }
            }
            .font(.ui(11.5, .medium))
            .monospacedDigit()
            .foregroundStyle(showing ? palette.secondaryText : palette.tertiaryText)
            .padding(.horizontal, 5)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle())
        .help(Self.summary(git, branch: branch))
        .popover(isPresented: $showing, arrowEdge: .top) {
            GitPanel(session: session, close: { showing = false })
                .environment(\.palette, palette)
        }
        .onChange(of: showing) { _, open in if open { session.refreshGit(after: .zero) } }
    }

    static func summary(_ git: GitStatus?, branch: String) -> String {
        guard let git else { return "Rama \(branch)" }
        var parts = ["Rama \(git.branch ?? branch)"]
        parts.append(git.isClean ? "sin cambios" : git.changes == 1 ? "1 archivo cambiado" : "\(git.changes) archivos cambiados")
        if git.ahead > 0 { parts.append("\(git.ahead) por subir") }
        if git.behind > 0 { parts.append("\(git.behind) por bajar") }
        return parts.joined(separator: " · ")
    }
}

/// Panel de git: qué ha cambiado (clic para abrirlo en el editor) y pull, push o commit.
struct GitPanel: View {
    let session: TerminalSession
    let close: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let git = session.git
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                    Text(git?.branch ?? session.context.gitBranch ?? "—").font(.ui(13, .semibold))
                    Spacer()
                    Button { session.refreshGit(after: .zero) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .medium))
                            .frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverStyle())
                    .help("Volver a mirar")
                }
                Text(subtitle(git)).font(.ui(11.5)).foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 8)

            if let git, !git.files.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(git.files) { file in
                            GitFileRow(file: file, root: session.context.gitRoot ?? session.cwd, close: close)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            } else if git != nil {
                Text("Todo guardado en commits.")
                    .font(.ui(12)).foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }

            palette.hairline.frame(height: 0.5)
            HStack(spacing: 6) {
                action("Pull", "arrow.down", highlight: (git?.behind ?? 0) > 0) { run("git pull") }
                action("Push", "arrow.up", highlight: (git?.ahead ?? 0) > 0) { run("git push") }
                if let git, !git.isClean {
                    action("Commit…", "checkmark.circle", highlight: false) { commit() }
                    action("Diff", "plus.forwardslash.minus", highlight: false) { run("git --no-pager diff --stat && git --no-pager diff") }
                }
                Spacer()
            }
            .padding(10)
            if !session.atPrompt {
                Text("Hay un programa en marcha en esta terminal: los botones esperan al prompt.")
                    .font(.ui(11)).foregroundStyle(palette.tertiaryText)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(width: 340)
    }

    private func subtitle(_ git: GitStatus?) -> String {
        guard let git else { return "Leyendo…" }
        var parts: [String] = []
        if let upstream = git.upstream {
            if git.ahead == 0 && git.behind == 0 {
                parts.append("Al día con \(upstream)")
            } else {
                if git.ahead > 0 { parts.append("\(git.ahead) \(git.ahead == 1 ? "commit" : "commits") por subir") }
                if git.behind > 0 { parts.append("\(git.behind) por bajar de \(upstream)") }
            }
        } else {
            parts.append("Sin rama remota")
        }
        parts.append(git.isClean ? "sin cambios" : git.changes == 1 ? "1 archivo cambiado" : "\(git.changes) archivos cambiados")
        return parts.joined(separator: " · ")
    }

    private func action(_ title: String, _ symbol: String, highlight: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.ui(12, .medium))
                .foregroundStyle(highlight ? palette.accent : palette.secondaryText)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlight ? palette.accent.opacity(0.12) : palette.raised))
        }
        .buttonStyle(.plain)
        .disabled(!session.atPrompt)
    }

    private func run(_ command: String) {
        close()
        session.run(command)
        session.window?.focusTerminal()
    }

    private func commit() {
        let alert = NSAlert()
        alert.messageText = "Commit"
        alert.informativeText = "Se guardarán todos los cambios (git add -A) con este mensaje."
        let field = NSTextField(string: "")
        field.placeholderString = "Qué has cambiado"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Hacer commit")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run("git add -A && git commit -m \(Tokenizer.escape(text))")
    }
}

private struct GitFileRow: View {
    let file: GitStatus.File
    let root: String
    let close: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(file.letter)
                .font(.code(11.5).weight(.bold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(file.path)
                .font(.ui(12))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if file.isStaged {
                Text("preparado").font(.ui(10.5)).foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let path = (root as NSString).appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: path) { Editors.open(path: path, line: nil, column: nil) }
            close()
        }
        .help(file.isUntracked ? "Archivo nuevo, sin añadir a git. Clic para abrirlo." : "Clic para abrirlo en el editor")
    }

    private var color: Color {
        switch file.letter {
        case "!", "D": palette.failure
        case "?", "A": palette.success
        default: Color(red: 0.95, green: 0.68, blue: 0.3)
        }
    }
}
