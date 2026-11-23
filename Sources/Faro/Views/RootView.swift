import AppKit
import FaroCore
import SwiftUI

struct RootView: View {
    let controller: TerminalWindowController
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }
    @State private var sidebarWidth = 230.0

    var body: some View {
        let palette = app.palette
        HStack(spacing: 0) {
            if app.settings.tabsInSidebar {
                Sidebar(controller: controller, model: model)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarResizer(width: $sidebarWidth)
            }
        VStack(spacing: 0) {
            TopBar(controller: controller, model: model)
            Group {
                if let tab = model.selectedTab {
                    if let zoomed = tab.zoomed {
                        PaneTree(node: .leaf(zoomed), tab: tab, controller: controller)
                    } else {
                        PaneTree(node: tab.root, tab: tab, controller: controller)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let session = model.selected {
                if let conflict = session.portConflict {
                    PortConflictBanner(session: session, conflict: conflict, model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                StatusBar(session: session, model: model)
            }
        }
        }
        .animation(.spring(duration: 0.25, bounce: 0.1), value: app.settings.tabsInSidebar)
        .onAppear { sidebarWidth = app.settings.sidebarWidth }
        .background {
            if app.settings.backgroundOpacity < 1 {
                ZStack {
                    VisualEffectBackground()
                    palette.background.opacity(app.settings.backgroundOpacity)
                }
            } else {
                palette.background
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.folderBrowserVisible, let session = model.selected {
                ZStack(alignment: .bottomLeading) {
                    Color.black.opacity(0.001)
                        .onTapGesture { closeFolders() }
                    FolderBrowser(session: session, dismiss: closeFolders)
                        .floatingPanel(palette)
                        .padding(.leading, 10 + (app.settings.tabsInSidebar ? sidebarWidth + 1 : 0))
                        .padding(.bottom, 34)
                        .onKeyPress(.escape) { closeFolders(); return .handled }
                        .transition(.offset(y: 8).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.15), value: model.folderBrowserVisible)
        .overlay(alignment: .topTrailing) {
            if model.portsVisible {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .onTapGesture { closePorts() }
                    PortsPanel(controller: controller, dismiss: closePorts)
                        .floatingPanel(palette)
                        .demoAnchor("ports-panel")
                        .padding(.trailing, 10)
                        .padding(.top, 40)
                        .onKeyPress(.escape) { closePorts(); return .handled }
                        .transition(.offset(y: -6).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.15), value: model.portsVisible)
        .overlay {
            if model.paletteVisible {
                CommandPalette(controller: controller, model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.paletteVisible)
        .environment(\.palette, palette)
        .ignoresSafeArea()
        .preferredColorScheme(palette.theme.isDark ? .dark : .light)
    }

    func closePorts() {
        model.portsVisible = false
        controller.focusTerminal()
    }

    func closeFolders() {
        model.folderBrowserVisible = false
        controller.focusTerminal()
    }
}

extension View {
    /// Panel flotante: material translúcido, borde de medio punto y sombra suave.
    func floatingPanel(_ palette: Palette, radius: CGFloat = 12) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.background.opacity(0.82))
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(palette.theme.isDark ? 0.45 : 0.14), radius: 24, y: 10)
    }
}

/// Aloja la vista de terminal de la pestaña activa. Las pestañas ocultas se sacan de la
/// jerarquía de vistas para que no dibujen ni ocupen memoria de pantalla.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    var focused = true

    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        container.show(session, focus: focused)
    }

    static func dismantleNSView(_ container: TerminalContainer, coordinator: ()) {
        container.release()
    }
}

/// Contenedor de una vista de terminal. Durante un cambio (dividir, ampliar, cerrar un panel)
/// pueden coexistir el contenedor viejo y el nuevo de la misma terminal: solo el más reciente
/// la muestra, para que no se la quiten el uno al otro.
final class TerminalContainer: NSView {
    @MainActor private static var created = 0
    let serial: Int
    private weak var session: TerminalSession?
    override var isFlipped: Bool { true }

    init() {
        Self.created += 1
        serial = Self.created
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ session: TerminalSession, focus: Bool) {
        guard serial >= session.hostSerial else { return }
        session.hostSerial = serial
        self.session = session
        let view = session.view
        if view.superview !== self {
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        if focus, let window, window.firstResponder !== view { window.makeFirstResponder(view) }
    }

    func release() {
        guard let session, session.hostSerial == serial else { return }
        session.hostSerial = 0
        if session.view.superview === self { session.view.removeFromSuperview() }
    }

    override func layout() {
        super.layout()
        if let view = session?.view, view.superview === self { view.frame = bounds }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(Theme.faroNoche)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
