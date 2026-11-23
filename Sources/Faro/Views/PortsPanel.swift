import AppKit
import FaroCore
import SwiftUI

/// Panel de puertos abiertos: qué servidores siguen en marcha, quién los lanzó y un botón
/// para cerrarlos.
struct PortsPanel: View {
    let controller: TerminalWindowController
    let dismiss: () -> Void
    @Environment(\.palette) private var palette
    @State private var showApps = false
    private var ports: Ports { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Puertos abiertos").font(.ui(13, .semibold))
                if !ports.servers.isEmpty {
                    Text("\(ports.servers.count)")
                        .font(.ui(11, .semibold)).monospacedDigit()
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(palette.raised))
                }
                Spacer()
                if ports.servers.count > 1 {
                    Button("Cerrar todos") { ports.closeAllServers() }
                        .buttonStyle(.plain)
                        .font(.ui(11.5, .medium))
                        .foregroundStyle(palette.failure)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.failure.opacity(0.1)))
                        .help("Cierra todos los servidores de desarrollo (no las apps)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if ports.servers.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(palette.success)
                            Text("No hay servidores en marcha").font(.ui(12.5, .medium))
                            Text("Cuando tú o una IA arranquéis uno (npm run dev, vite…), aparecerá aquí.")
                                .font(.ui(11.5))
                                .foregroundStyle(palette.tertiaryText)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .padding(.horizontal, 16)
                    }
                    ForEach(ports.servers) { port in
                        PortRow(port: port, controller: controller, dismiss: dismiss)
                    }
                    if !ports.apps.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showApps.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .rotationEffect(.degrees(showApps ? 90 : 0))
                                Text("Apps y sistema")
                                Text("\(ports.apps.count)").monospacedDigit()
                                Spacer()
                            }
                            .font(.ui(11.5, .medium))
                            .foregroundStyle(palette.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showApps {
                            ForEach(ports.apps) { port in
                                PortRow(port: port, controller: controller, dismiss: dismiss, compact: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 380)
        .onAppear { ports.panelsOpen += 1 }
        .onDisappear { ports.panelsOpen -= 1 }
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let controller: TerminalWindowController
    let dismiss: () -> Void
    var compact = false
    @Environment(\.palette) private var palette
    @State private var hovering = false
    private var ports: Ports { .shared }

    var body: some View {
        let closing = ports.closing.contains(port.id)
        let failed = ports.failed.contains(port.id)
        let session = ports.session(for: port)
        HStack(spacing: 10) {
            Circle()
                .fill(closing ? palette.tertiaryText : port.isApp ? palette.tertiaryText.opacity(0.6) : palette.success)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: ":\(port.port)")
                        .font(.code(compact ? 12 : 13).weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(port.label)
                        .font(.ui(compact ? 12 : 12.5, .medium))
                        .foregroundStyle(compact ? palette.secondaryText : palette.text)
                        .lineLimit(1)
                    if !port.localOnly && !port.isApp {
                        Text("red")
                            .font(.ui(10, .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(palette.accent.opacity(0.12)))
                            .help("Acepta conexiones desde otros dispositivos de tu red")
                    }
                }
                if !compact || hovering {
                    HStack(spacing: 4) {
                        if let agent = port.launchedBy {
                            AgentLogo(agent: agent, size: 10)
                        }
                        Text(failed ? "No se ha podido cerrar" : closing ? "Cerrando…" : detail(session: session))
                            .foregroundStyle(failed ? palette.failure : palette.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.ui(11.5))
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                if hovering || !compact {
                    if !port.isApp {
                        RowButton(symbol: "safari", help: "Abrir \(port.url.absoluteString)") { NSWorkspace.shared.open(port.url) }
                    }
                    if let session {
                        RowButton(symbol: "terminal", help: "Ir a su pestaña") {
                            session.window?.focus(session)
                            dismiss()
                        }
                    }
                }
                if closing {
                    ProgressView().controlSize(.small).frame(width: 26, height: 24)
                } else if hovering || !compact {
                    RowButton(symbol: "xmark", help: port.isApp ? "Cerrar \(port.name)" : "Cerrar el servidor", destructive: true) {
                        ports.close(port)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, compact ? 5 : 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Abrir en el navegador") { NSWorkspace.shared.open(port.url) }
            Button("Copiar dirección") { copy(port.url.absoluteString) }
            if let dir = port.directory {
                Button("Abrir carpeta en pestaña nueva") { controller.newTab(directory: dir); dismiss() }
                Button("Mostrar carpeta en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
            }
            Button("Copiar comando") { copy(port.arguments.joined(separator: " ")) }
            Divider()
            Button("Cerrar (PID \(port.root))", role: .destructive) { ports.close(port) }
        }
        .help(port.arguments.joined(separator: " "))
    }

    private func detail(session: TerminalSession?) -> String {
        var parts: [String] = []
        if let dir = port.directory, dir != NSHomeDirectory() {
            parts.append((dir as NSString).lastPathComponent)
        }
        if let started = port.started {
            parts.append(Self.age(Date().timeIntervalSince(started)))
        }
        if let agent = port.launchedBy {
            parts.append("lo dejó \(agent.shortName)")
        } else if let session {
            parts.append(session.window === controller ? "desde una pestaña de esta ventana" : "desde otra ventana de Faro")
        } else if port.parents.isEmpty && !port.isApp {
            parts.append("servicio")
        }
        return parts.joined(separator: " · ")
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<60: return "ahora"
        case ..<3600: return "hace \(s / 60) min"
        case ..<86_400: return "hace \(s / 3600) h"
        default: return "hace \(s / 86_400) d"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive && hovering ? palette.failure : hovering ? palette.text : palette.tertiaryText)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? (destructive ? palette.failure.opacity(0.12) : palette.raised) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Botón de la barra superior: un enchufe con el número de servidores en marcha.
struct PortsButton: View {
    @Bindable var model: WindowModel
    @Environment(\.palette) private var palette
    private var count: Int { Ports.shared.servers.count }

    var body: some View {
        Button { model.portsVisible.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "powerplug.portrait")
                    .font(.system(size: 11.5, weight: .medium))
                if count > 0 {
                    Text("\(count)").font(.ui(11.5, .semibold)).monospacedDigit()
                }
            }
            .foregroundStyle(model.portsVisible ? palette.accent : count > 0 ? palette.secondaryText : palette.tertiaryText)
            .padding(.horizontal, count > 0 ? 7 : 0)
            .frame(minWidth: 26, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle())
        .help(count == 0 ? "Puertos abiertos (⌃⌘P)" : count == 1 ? "1 servidor en marcha (⌃⌘P)" : "\(count) servidores en marcha (⌃⌘P)")
        .accessibilityLabel("Puertos abiertos")
    }
}
