import FaroCore
import SwiftUI

/// Barra superior: semáforos, pestañas y poco más. Mismo fondo que el terminal, sin líneas.
struct TopBar: View {
    let controller: TerminalWindowController
    @Bindable var model: WindowModel
    @Environment(\.palette) private var palette

    var body: some View {
        if AppModel.shared.settings.tabsInSidebar {
            compact
        } else {
            full
        }
    }

    /// Con las pestañas en la barra lateral, arriba solo queda el título del panel activo.
    private var compact: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 12)
            if let session = model.selected {
                HStack(spacing: 6) {
                    if let agent = session.agent { AgentLogo(agent: agent, size: 11) }
                    Text(session.displayTitle).font(.ui(12.5, .medium)).foregroundStyle(palette.secondaryText)
                    Text(session.locationSubtitle).font(.ui(12)).foregroundStyle(palette.tertiaryText)
                }
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer(minLength: 12)
            PortsButton(model: model).demoAnchor("ports")
            IconButton(symbol: "magnifyingglass", help: "Buscar o ejecutar (⌘P)") { controller.togglePalette() }
                .demoAnchor("search")
            IconButton(symbol: "slider.horizontal.3", help: "Ajustes (⌘,)") { SettingsWindow.show() }
                .padding(.trailing, 10)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { controller.window?.zoom(nil) }
    }

    private var full: some View {
        HStack(spacing: 0) {
            if !model.isFullScreen && !model.isDropdown {
                TrafficLights(controller: controller, active: model.isKey || DemoMode.enabled)
                    .padding(.leading, 14)
                    .padding(.trailing, 16)
            } else {
                Color.clear.frame(width: 12)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(model.tabs) { tab in
                        TabItem(tab: tab, selected: tab.id == model.selectedTab?.id) {
                            controller.select(tab)
                        } close: {
                            controller.closeTab(tab)
                        }
                        .demoAnchor("tab-\(tab.id.uuidString)")
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                            controller.move(id, before: tab.id)
                            return true
                        }
                    }
                    NewTabButtons(controller: controller)
                        .padding(.leading, 4)
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            IconButton(symbol: "sidebar.left", help: "Pestañas en la barra lateral (⌃⌘S)") {
                AppModel.shared.settings.tabsInSidebar = true
            }
            .demoAnchor("sidebar")
            PortsButton(model: model).demoAnchor("ports")
            IconButton(symbol: "magnifyingglass", help: "Buscar o ejecutar (⌘P)") { controller.togglePalette() }
                .demoAnchor("search")
            IconButton(symbol: "slider.horizontal.3", help: "Ajustes (⌘,)") { SettingsWindow.show() }
                .padding(.trailing, 10)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { controller.window?.zoom(nil) }
    }
}

/// Cerrar, minimizar y pantalla completa, dibujados por Faro. Con ⌥ el botón verde amplía.
struct TrafficLights: View {
    let controller: TerminalWindowController
    let active: Bool
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.373, blue: 0.341), "xmark", "Cerrar") { controller.window?.performClose(nil) }
            light(Color(red: 0.996, green: 0.737, blue: 0.180), "minus", "Minimizar") { controller.window?.miniaturize(nil) }
            light(Color(red: 0.157, green: 0.784, blue: 0.251), "arrow.up.left.and.arrow.down.right", "Pantalla completa") {
                if NSEvent.modifierFlags.contains(.option) { controller.window?.zoom(nil) } else { controller.window?.toggleFullScreen(nil) }
            }
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, _ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(active || hovering ? color : palette.hairline)
                .overlay(Circle().strokeBorder(.black.opacity(active || hovering ? 0.12 : 0), lineWidth: 0.5))
                .overlay {
                    if hovering {
                        Image(systemName: symbol)
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct TabItem: View {
    let tab: TerminalTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false
    private var controller: TerminalWindowController { tab.sessions[0].window! }

    var body: some View {
        let session = tab.focused ?? tab.sessions[0]
        let panes = tab.sessions.count
        HStack(spacing: 7) {
            Group {
                if let agent = session.agent ?? tab.sessions.lazy.compactMap(\.agent).first {
                    AgentLogo(agent: agent, size: 12)
                } else if session.runningCommand != nil {
                    Circle().fill(palette.accent).frame(width: 5, height: 5)
                        .phaseAnimator([0.35, 1]) { dot, phase in dot.opacity(phase) }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(selected ? palette.accent : palette.tertiaryText)
                }
            }
            .frame(width: 12, height: 12)

            Text(Projects.shared.project(tab.projectID)?.name ?? session.displayTitle)
                .font(.ui(12.5, selected ? .medium : .regular))
                .foregroundStyle(selected ? palette.text : hovering ? palette.secondaryText : palette.tertiaryText)
                .lineLimit(1)

            if panes > 1 {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 8.5, weight: .medium))
                    Text("\(panes)").font(.ui(10.5, .medium))
                }
                .foregroundStyle(palette.tertiaryText)
                .help("\(panes) paneles")
            }

            ZStack {
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(palette.hover))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cerrar pestaña")
                } else if tab.sessions.contains(where: \.hasUnseenActivity) {
                    Circle().fill(palette.accent).frame(width: 5, height: 5)
                } else if session.lastCommandFailed {
                    Circle().fill(palette.failure).frame(width: 5, height: 5)
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 26)
        .frame(minWidth: 70, maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? palette.raised : hovering ? palette.raised.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Dividir a la derecha") { controller.split(.horizontal, from: session) }
            Button("Dividir hacia abajo") { controller.split(.vertical, from: session) }
            Divider()
            Button("Nueva pestaña aquí") { session.window?.newTab(directory: session.cwd) }
            Menu("Abrir IA aquí") {
                ForEach(AppModel.shared.installedAgents) { agent in
                    Button(agent.name) { session.window?.newTab(directory: session.cwd, kind: .agent(agent)) }
                }
            }
            Divider()
            Button("Abrir carpeta en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
            Button("Copiar ruta") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
            Divider()
            Button("Cerrar pestaña", action: close)
        }
        .help(SuggestionEngine.abbreviate(session.cwd) + (panes > 1 ? " · \(panes) paneles" : ""))
    }
}

/// «+» abre una terminal; al lado, el logo de Claude y un menú con el resto de IAs instaladas.
struct NewTabButtons: View {
    let controller: TerminalWindowController
    var showPlus = true
    @Environment(\.palette) private var palette
    private var agents: [AIAgent] { AppModel.shared.installedAgents }

    var body: some View {
        HStack(spacing: 0) {
            if showPlus {
                IconButton(symbol: "plus", help: "Nueva pestaña (⌘T)") { controller.newTab() }
            }
            if agents.contains(.claude) {
                Button { controller.newTab(kind: .agent(.claude)) } label: {
                    AgentLogo(agent: .claude, size: 13).frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle())
                .help("Nueva sesión de Claude Code (⇧⌘C)")
                .accessibilityLabel("Nueva sesión de Claude Code")
            }
            if agents.contains(where: { $0 != .claude }) || !Projects.shared.all.isEmpty {
                Menu {
                    if !Projects.shared.all.isEmpty {
                        Section("Proyectos") {
                            ForEach(Projects.shared.recent.prefix(9)) { project in
                                Button("\(project.name)  ·  \(project.summary)") { Projects.shared.open(project) }
                            }
                        }
                    }
                    Section("Abrir en esta carpeta") {
                        ForEach(agents) { agent in
                            Button {
                                controller.newTab(kind: .agent(agent))
                            } label: {
                                if let image = Logos.image(agent, dark: palette.theme.isDark) {
                                    Label { Text(agent.name) } icon: { Image(nsImage: Self.menuIcon(image)) }
                                } else {
                                    Text(agent.name)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 20, height: 24)
                .foregroundStyle(palette.tertiaryText)
                .help("Otras IAs")
            }
        }
    }

    static func menuIcon(_ image: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Fondo suave al pasar el ratón, sin bordes.
struct HoverStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isPressed ? palette.hover : hovering ? palette.raised : .clear))
            .onHover { hovering = $0 }
    }
}
