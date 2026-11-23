import FaroCore
import SwiftUI

/// Línea de estado inferior: dónde estás, la rama, qué harías después y cómo fue lo último.
/// Texto discreto que se ilumina al pasar el ratón.
struct StatusBar: View {
    let session: TerminalSession
    @Bindable var model: WindowModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button {
                    model.folderBrowserVisible.toggle()
                } label: {
                    Image(systemName: model.folderBrowserVisible ? "folder.fill" : "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.folderBrowserVisible ? palette.accent : palette.tertiaryText)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle())
                .help("Explorar carpetas (⌘O)")
                .accessibilityLabel("Explorar carpetas")

                Breadcrumb(session: session)
            }
            .layoutPriority(1)

            if let branch = session.context.gitBranch ?? session.git?.branch {
                GitBadge(session: session, branch: branch).demoAnchor("git")
            }

            Spacer(minLength: 8)

            if let command = session.runningCommand, let since = session.runningSince {
                Running(session: session, command: command, since: since)
            } else {
                if session.buffer.isEmpty && !session.predictions.isEmpty {
                    Predictions(session: session)
                }
                if let exit = session.lastExit, let ms = session.lastDuration {
                    LastStatus(session: session, exit: exit, ms: ms)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 30)
    }
}

private struct Breadcrumb: View {
    let session: TerminalSession
    @Environment(\.palette) private var palette

    var segments: [(name: String, path: String)] {
        let home = NSHomeDirectory()
        var result: [(String, String)] = []
        var rest = session.cwd
        var current = "/"
        if rest == home || rest.hasPrefix(home + "/") {
            result.append(("~", home))
            current = home
            rest = String(rest.dropFirst(home.count))
        } else {
            result.append(("/", "/"))
        }
        for part in rest.split(separator: "/") {
            current = (current as NSString).appendingPathComponent(String(part))
            result.append((String(part), current))
        }
        return result
    }

    var body: some View {
        let all = segments
        let visible = all.count > 5 ? [all[0]] + all.suffix(3) : all
        HStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, segment in
                if index > 0 && !(index == 1 && visible[0].name == "/") {
                    Text(all.count > 5 && index == 1 ? "/ … /" : "/")
                        .font(.ui(12))
                        .foregroundStyle(palette.tertiaryText.opacity(0.7))
                        .padding(.horizontal, 1)
                }
                Segment(name: segment.name, isLast: index == visible.count - 1) {
                    session.navigate(to: segment.path)
                }
                .help(index == visible.count - 1 ? session.cwd : "Ir a \(segment.path)")
                .demoAnchor("crumb-\(segment.name)")
            }
        }
    }
}

private struct Segment: View {
    let name: String
    let isLast: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.ui(12, isLast ? .medium : .regular))
                .foregroundStyle(isLast ? palette.text.opacity(0.9) : hovering ? palette.text : palette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering && !isLast ? palette.raised : .clear))
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .onHover { hovering = $0 }
    }
}

private struct Predictions: View {
    let session: TerminalSession
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(session.predictions.prefix(3)) { s in
                PredictionButton(suggestion: s, session: session)
            }
        }
        .frame(maxWidth: 480, alignment: .trailing)
    }
}

private struct PredictionButton: View {
    let suggestion: Suggestion
    let session: TerminalSession
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) { session.run(suggestion.replacement) } else { session.setBuffer(suggestion.replacement) }
            session.window?.focusTerminal()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "return")
                    .font(.system(size: 8.5, weight: .semibold))
                    .opacity(hovering ? 1 : 0.6)
                Text(suggestion.title)
                    .font(.code(11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(hovering ? palette.text : palette.tertiaryText)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(suggestion.detail)\nClic: escribirlo · ⌥ clic: ejecutarlo")
    }
}

private struct Running: View {
    let session: TerminalSession
    let command: String
    let since: Date
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            if let agent = session.agent {
                AgentLogo(agent: agent, size: 11)
                Text(agent.name).font(.ui(11.5, .medium)).foregroundStyle(palette.secondaryText)
            } else {
                Circle().fill(palette.accent).frame(width: 5, height: 5)
                    .phaseAnimator([0.3, 1]) { dot, phase in dot.opacity(phase) }
                Text(command.count > 40 ? String(command.prefix(39)) + "…" : command)
                    .font(.code(11.5))
                    .lineLimit(1)
                    .foregroundStyle(palette.secondaryText)
            }
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.elapsed(context.date.timeIntervalSince(since)))
                    .font(.ui(11.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.tertiaryText)
            }
        }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let total = Int(s)
        return total < 60 ? "\(total) s" : "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private struct LastStatus: View {
    let session: TerminalSession
    let exit: Int32
    let ms: Int
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if exit != 0 && !TerminalSession.wasStopped(exit) && AIAgent.detect(command: session.lastCommand ?? "") == nil {
                Button {
                    session.explainLastError()
                } label: {
                    HStack(spacing: 5) {
                        AgentLogo(agent: .claude, size: 11)
                        Text("Explicar error").font(.ui(11.5, .medium))
                    }
                    .foregroundStyle(hovering ? palette.text : palette.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(hovering ? palette.hover : palette.raised))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Claude Code recibe el comando y su salida y te dice qué pasó (⇧⌘E)")
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(exit == 0 ? palette.success : TerminalSession.wasStopped(exit) ? palette.tertiaryText : palette.failure)
                    .frame(width: 6, height: 6)
                if exit != 0 || ms >= 100 {
                    Text(exit == 0 ? Notifier.format(ms) : "\(exit) · \(Notifier.format(ms))")
                        .font(.ui(11.5))
                        .monospacedDigit()
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .help(session.lastCommand.map { "\($0)\n" + (exit == 0 ? "Terminó bien" : TerminalSession.wasStopped(exit) ? "Detenido (\(exit))" : "Código de salida \(exit)") } ?? "")
        }
    }
}
