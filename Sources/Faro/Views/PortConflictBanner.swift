import FaroCore
import SwiftUI

/// Aviso cuando un comando no puede usar su puerto: quién lo tiene ocupado y un botón para
/// cerrarlo y volver a lanzar el comando.
struct PortConflictBanner: View {
    let session: TerminalSession
    let conflict: PortConflictInfo
    @Bindable var model: WindowModel
    @Environment(\.palette) private var palette
    private static let amber = Color(red: 1, green: 0.72, blue: 0.3)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Self.amber)
            if let agent = conflict.occupant?.launchedBy {
                AgentLogo(agent: agent, size: 12)
            }
            message
                .font(.ui(12))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if conflict.resolving {
                ProgressView().controlSize(.small)
                Text("Cerrando…").font(.ui(12)).foregroundStyle(palette.tertiaryText)
            } else if conflict.canClose {
                Button(session.runningCommand == nil ? "Cerrarlo y reintentar" : "Cerrarlo y reiniciar") {
                    session.resolvePortConflict()
                }
                .buttonStyle(.plain)
                .font(.ui(12, .semibold))
                .foregroundStyle(palette.background)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.amber))
                .help("Cierra \(conflict.occupant?.label ?? "el proceso") y vuelve a lanzar «\(conflict.command)»")
                .demoAnchor("conflict-close")
            }
            Button { model.portsVisible = true } label: {
                Text("Puertos").font(.ui(12, .medium)).foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Ver todos los puertos abiertos (⌃⌘P)")
            Button { session.portConflict = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.tertiaryText)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(HoverStyle())
            .help("Ocultar")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(Self.amber.opacity(palette.theme.isDark ? 0.09 : 0.14))
        .overlay(alignment: .top) { Self.amber.opacity(0.35).frame(height: 0.5) }
    }

    @ViewBuilder private var message: some View {
        let port = Text(verbatim: ":\(conflict.port)").font(.code(12).weight(.semibold)).foregroundColor(palette.text)
        if conflict.failed {
            Text("No se ha podido liberar el puerto \(port). Ciérralo desde Puertos o usa otro.")
        } else if conflict.isAirPlay {
            Text("El puerto \(port) lo usa **AirPlay** del Mac. Desactiva «Receptor AirPlay» en Ajustes del Sistema → General → AirDrop y Handoff, o usa otro puerto.")
        } else if let occupant = conflict.occupant {
            if occupant.isApp {
                Text("El puerto \(port) lo usa la app **\(occupant.name)**. Ciérrala o usa otro puerto.")
            } else {
                Text("El puerto \(port) lo tiene **\(occupant.label)**\(Text(verbatim: details(occupant)))")
            }
        } else {
            Text("El puerto \(port) lo ocupa un proceso del sistema o de otro usuario.")
        }
    }

    private func details(_ occupant: ListeningPort) -> String {
        var parts: [String] = []
        if let dir = occupant.directory, dir != NSHomeDirectory() { parts.append((dir as NSString).lastPathComponent) }
        if let started = occupant.started { parts.append(Self.age(Date().timeIntervalSince(started))) }
        if let agent = occupant.launchedBy { parts.append("lo dejó \(agent.shortName)") }
        return parts.isEmpty ? "." : " · " + parts.joined(separator: " · ")
    }

    private static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<60: return "abierto ahora"
        case ..<3600: return "abierto hace \(s / 60) min"
        case ..<86_400: return "abierto hace \(s / 3600) h"
        default: return "abierto hace \(s / 86_400) d"
        }
    }
}
