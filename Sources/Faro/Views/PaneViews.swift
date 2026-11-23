import AppKit
import FaroCore
import SwiftUI

/// Dibuja el árbol de paneles de una pestaña.
struct PaneTree: View {
    let node: PaneNode
    let tab: TerminalTab
    let controller: TerminalWindowController

    var body: some View {
        switch node {
        case .leaf(let session):
            PaneLeaf(session: session, tab: tab)
        case .split(let split):
            SplitPane(split: split, tab: tab, controller: controller)
        }
    }
}

private struct PaneLeaf: View {
    let session: TerminalSession
    let tab: TerminalTab
    @Environment(\.palette) private var palette

    var body: some View {
        let focused = tab.focusedID == session.id
        let showFocus = tab.isSplit && tab.zoomedID == nil
        ZStack(alignment: .topLeading) {
            TerminalHost(session: session, focused: focused)
            SuggestionOverlay(session: session)
        }
        .padding(.horizontal, AppModel.shared.settings.padding)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .overlay {
            if showFocus && !focused {
                // Los paneles inactivos se apagan un poco, como en Warp.
                palette.background.opacity(palette.theme.isDark ? 0.42 : 0.35)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if showFocus && focused {
                palette.accent.opacity(0.7).frame(height: 1.5).padding(.horizontal, 1)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .id(session.id)
    }
}

private struct SplitPane: View {
    @Bindable var split: PaneSplit
    let tab: TerminalTab
    let controller: TerminalWindowController
    @Environment(\.palette) private var palette
    private let space = "split"

    var body: some View {
        GeometryReader { geo in
            let horizontal = split.axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let firstSize = max(80, (total - 1) * split.fraction)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                PaneTree(node: split.first, tab: tab, controller: controller)
                    .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                Divider(split: split, total: total, horizontal: horizontal, space: space)
                PaneTree(node: split.second, tab: tab, controller: controller)
            }
        }
        .coordinateSpace(.named(space + split.id.uuidString))
    }
}

/// Línea de 1 px entre paneles; se arrastra desde una franja más ancha e invisible.
private struct Divider: View {
    @Bindable var split: PaneSplit
    let total: CGFloat
    let horizontal: Bool
    let space: String
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? palette.accent.opacity(0.6) : palette.hairline)
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 9 : nil, height: horizontal ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(space + split.id.uuidString))
                            .onChanged { value in
                                dragging = true
                                let position = horizontal ? value.location.x : value.location.y
                                split.fraction = min(0.88, max(0.12, position / max(total, 1)))
                            }
                            .onEnded { _ in dragging = false }
                    )
                    .onTapGesture(count: 2) { split.fraction = 0.5 }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Arrastra para cambiar el tamaño · doble clic para igualar")
    }
}
