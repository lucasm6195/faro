import FaroCore
import SwiftUI

/// Pestañas en vertical, a la izquierda. Cada pestaña muestra su carpeta o lo que se ejecuta,
/// y si está dividida, sus paneles debajo.
struct Sidebar: View {
    let controller: TerminalWindowController
    @Bindable var model: WindowModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if !model.isFullScreen && !model.isDropdown {
                    TrafficLights(controller: controller, active: model.isKey || DemoMode.enabled)
                }
                Spacer()
                IconButton(symbol: "sidebar.left", help: "Pestañas arriba (⌃⌘S)") {
                    AppModel.shared.settings.tabsInSidebar = false
                }
                .demoAnchor("sidebar-top")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        SidebarTab(tab: tab, index: index, selected: tab.id == model.selectedTab?.id, controller: controller)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                                controller.move(id, before: tab.id)
                                return true
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
            }
            .scrollIndicators(.never)

            HStack(spacing: 2) {
                Button {
                    controller.newTab()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Nueva pestaña").font(.ui(12.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle())
                .help("Nueva pestaña (⌘T)")
                NewTabButtons(controller: controller, showPlus: false)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
        .background(palette.raised.opacity(palette.theme.isDark ? 0.55 : 0.7))
    }
}

private struct SidebarTab: View {
    let tab: TerminalTab
    let index: Int
    let selected: Bool
    let controller: TerminalWindowController
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let session = tab.focused ?? tab.sessions[0]
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 9) {
                TabGlyph(session: session, tab: tab, selected: selected)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Projects.shared.project(tab.projectID)?.name ?? session.displayTitle)
                        .font(.ui(13, selected ? .medium : .regular))
                        .foregroundStyle(selected ? palette.text : palette.secondaryText)
                        .lineLimit(1)
                    Text(session.locationSubtitle)
                        .font(.ui(11.5))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                ZStack {
                    if hovering {
                        Button { controller.closeTab(tab) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(palette.hover))
                        }
                        .buttonStyle(.plain)
                        .help("Cerrar pestaña")
                        .accessibilityLabel("Cerrar pestaña")
                    } else if tab.sessions.contains(where: \.hasUnseenActivity) {
                        Circle().fill(palette.accent).frame(width: 6, height: 6)
                    } else if session.lastCommandFailed {
                        Circle().fill(palette.failure).frame(width: 6, height: 6)
                    } else if index < 9 {
                        Text("⌘\(index + 1)").font(.ui(10.5)).foregroundStyle(palette.tertiaryText.opacity(selected ? 1 : 0.7))
                    }
                }
                .frame(minWidth: 22, minHeight: 18)
            }
            if tab.isSplit {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tab.sessions) { pane in
                        PaneRow(pane: pane, tab: tab, focused: pane.id == tab.focusedID && selected, controller: controller)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 25)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? palette.hover : hovering ? palette.hover.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { controller.select(tab) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Dividir a la derecha") { controller.split(.horizontal, from: session) }
            Button("Dividir hacia abajo") { controller.split(.vertical, from: session) }
            Divider()
            Button("Abrir carpeta en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
            Button("Copiar ruta") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
            Divider()
            Button("Cerrar pestaña") { controller.closeTab(tab) }
        }
    }
}

/// Un panel de una pestaña dividida.
private struct PaneRow: View {
    let pane: TerminalSession
    let tab: TerminalTab
    let focused: Bool
    let controller: TerminalWindowController
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let agent = pane.agent {
                AgentLogo(agent: agent, size: 10)
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(focused ? palette.accent : palette.tertiaryText, lineWidth: 1)
                    .frame(width: 9, height: 7)
            }
            Text(pane.displayTitle)
                .font(.ui(11.5, focused ? .medium : .regular))
                .foregroundStyle(focused ? palette.text : hovering ? palette.secondaryText : palette.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture { controller.focus(pane) }
        .onHover { hovering = $0 }
    }
}

/// Logo de la IA, punto animado si algo se ejecuta, o el «›» de la terminal.
struct TabGlyph: View {
    let session: TerminalSession
    let tab: TerminalTab
    let selected: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        if let agent = session.agent ?? tab.sessions.lazy.compactMap(\.agent).first {
            AgentLogo(agent: agent, size: 13)
        } else if session.runningCommand != nil {
            Circle().fill(palette.accent).frame(width: 6, height: 6)
                .phaseAnimator([0.35, 1]) { dot, phase in dot.opacity(phase) }
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(selected ? palette.accent : palette.tertiaryText)
        }
    }
}

/// Borde arrastrable para cambiar el ancho de la barra lateral.
struct SidebarResizer: View {
    @Binding var width: Double
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(hovering ? palette.accent.opacity(0.5) : palette.hairline.opacity(0.6))
            .frame(width: hovering ? 2 : 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = start ?? width
                            start = base
                            width = min(380, max(170, base + value.translation.width))
                        }
                        .onEnded { _ in
                            start = nil
                            AppModel.shared.settings.sidebarWidth = width
                        })
            }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
