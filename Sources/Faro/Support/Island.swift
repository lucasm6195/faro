import AppKit
import FaroCore
import Observation
import SwiftUI

@MainActor
@Observable
final class IslandModel {
    var sessions: [TerminalSession] = []
    var expanded = false
    var hasNotch = true
    var notchWidth: CGFloat = 180
    var barHeight: CGFloat = 32
}

/// Isla de actividad en el notch: muestra las IAs que trabajan, te esperan o han terminado
/// mientras no las estás mirando. No existe (ni gasta nada) cuando no hay nada que contar.
@MainActor
final class Island {
    static let shared = Island()

    let model = IslandModel()
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private let wing: CGFloat = 78

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Island.shared.refresh() }
            })
        }
    }

    // MARK: Qué mostrar

    func refresh() {
        guard AppModel.shared.settings.activityIsland else { hide(); return }
        var entries: [TerminalSession] = []
        for controller in AppModel.shared.windows {
            // En el vídeo de la demo, Faro está delante aunque grabe en segundo plano.
            let windowInFront = DemoMode.enabled || (NSApp.isActive && controller.window?.isKeyWindow == true)
            for session in controller.model.allSessions where session.agentPhase != .idle {
                if windowInFront && controller.isVisible(session) {
                    session.acknowledgeAgent()
                } else {
                    entries.append(session)
                }
            }
        }
        model.sessions = entries.sorted { Self.priority($0) > Self.priority($1) }
        if model.sessions.isEmpty { hide() } else { show() }
    }

    private static func priority(_ s: TerminalSession) -> Int {
        switch s.agentPhase {
        case .needsInput: 3
        case .finished: 2
        case .working: 1
        case .idle: 0
        }
    }

    func agentFinished(_ session: TerminalSession) {
        let looking = NSApp.isActive && session.window?.window?.isKeyWindow == true && session.window?.isVisible(session) == true
        if !looking && AppModel.shared.settings.islandSound { NSSound(named: "Glass")?.play() }
    }

    func open(_ session: TerminalSession) {
        if !DemoMode.enabled { NSApp.activate() }
        session.window?.window?.makeKeyAndOrderFront(nil)
        session.window?.focus(session)
        session.acknowledgeAgent()
        model.expanded = false
        refresh()
    }

    func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        model.expanded = expanded
        layout(animated: true)
    }

    // MARK: Panel

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovable = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = DemoMode.enabled
            p.contentView = NSHostingView(rootView: IslandView(model: model))
            panel = p
            if ProcessInfo.processInfo.environment["FARO_ISLAND_EXPANDED"] == "1" { model.expanded = true }
            layout(animated: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        } else {
            layout(animated: true)
        }
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        model.expanded = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        })
    }

    /// Pantalla donde va la isla: la que tiene notch (en la demo, la de la ventana grabada).
    static var screen: NSScreen? {
        if DemoMode.enabled, let screen = AppModel.shared.frontWindow?.window?.screen { return screen }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// Ancho y alto del notch de esa pantalla (nil si no tiene). En la demo siempre hay notch.
    static func notch(of screen: NSScreen) -> (width: CGFloat, height: CGFloat)? {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (max(120, screen.frame.width - left.width - right.width), screen.safeAreaInsets.top)
        }
        return DemoMode.enabled ? (185, 32) : nil
    }

    private func layout(animated: Bool) {
        guard let panel, let screen = Self.screen else { return }
        let notch = Self.notch(of: screen) != nil
        model.hasNotch = notch
        if let size = Self.notch(of: screen) {
            model.notchWidth = size.width
            model.barHeight = size.height
        } else {
            model.notchWidth = 0
            model.barHeight = 30
        }
        let collapsedWidth = notch ? model.notchWidth + wing * 2 : 210
        let width = model.expanded ? max(collapsedWidth, 400) : collapsedWidth
        let rows = CGFloat(min(model.sessions.count, 3))
        let height = model.barHeight + (model.expanded ? rows * 58 + 10 : 0)
        let top = notch ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

// MARK: Vista

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let radius: CGFloat = model.expanded ? 22 : (model.hasNotch ? 13 : 15)
        VStack(spacing: 0) {
            if let top = model.sessions.first {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        AgentBadge(session: top, size: 15)
                        if model.sessions.count > 1 {
                            Text("+\(model.sessions.count - 1)")
                                .font(.ui(11, .semibold)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(.leading, model.hasNotch ? 16 : 12)
                    Spacer(minLength: model.notchWidth)
                    IslandStatus(session: top)
                        .padding(.trailing, model.hasNotch ? 16 : 12)
                }
                .frame(height: model.barHeight)
                .contentShape(Rectangle())
                .onTapGesture { Island.shared.open(top) }

                if model.expanded {
                    VStack(spacing: 4) {
                        ForEach(model.sessions.prefix(3)) { session in
                            IslandRow(session: session)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: model.hasNotch ? 0 : radius, bottomLeadingRadius: radius,
                                   bottomTrailingRadius: radius, topTrailingRadius: model.hasNotch ? 0 : radius,
                                   style: .continuous)
                .fill(.black)
        )
        .environment(\.colorScheme, .dark)
        .onHover { Island.shared.setExpanded($0) }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: model.expanded)
    }
}

/// Logo de la IA con un anillo de progreso, o con su estado si espera o ha terminado.
private struct AgentBadge: View {
    let session: TerminalSession
    let size: CGFloat

    var body: some View {
        ZStack {
            if let agent = session.agent ?? agentOfLastCommand {
                AgentLogo(agent: agent, size: size)
            } else {
                Image(systemName: "sparkle").font(.system(size: size * 0.8)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
    private var agentOfLastCommand: AIAgent? { session.lastCommand.flatMap(AIAgent.detect) }
}

private struct IslandStatus: View {
    let session: TerminalSession

    var body: some View {
        switch session.agentPhase {
        case .working(let since):
            HStack(spacing: 6) {
                if let p = session.agentScreen.progress {
                    ProgressRing(progress: p).frame(width: 13, height: 13)
                    Text("\(session.agentScreen.tasksDone ?? 0)/\(session.agentScreen.tasksTotal ?? 0)")
                        .font(.ui(12, .semibold)).monospacedDigit().foregroundStyle(.white)
                } else {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Self.elapsed(ctx.date.timeIntervalSince(since)))
                            .font(.ui(12, .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        case .needsInput:
            HStack(spacing: 5) {
                Circle().fill(Color(red: 1, green: 0.72, blue: 0.3)).frame(width: 6, height: 6)
                Text("Te espera").font(.ui(12, .semibold)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.45))
            }
        case .finished:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.5))
                Text("Listo").font(.ui(12, .semibold)).foregroundStyle(.white)
            }
        case .idle:
            EmptyView()
        }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t < 60 ? "\(t) s" : "\(t / 60):\(String(format: "%02d", t % 60))"
    }
}

private struct IslandRow: View {
    let session: TerminalSession
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            AgentBadge(session: session, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.agent?.name ?? session.lastCommand.flatMap(AIAgent.detect)?.name ?? "IA")
                        .font(.ui(13, .semibold)).foregroundStyle(.white)
                    Text(session.displayFolder).font(.ui(12)).foregroundStyle(.white.opacity(0.5))
                }
                Text(detail).font(.ui(11.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                if case .working = session.agentPhase, let p = session.agentScreen.progress {
                    ProgressView(value: p).progressViewStyle(.linear).tint(.white).frame(height: 3)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Island.shared.open(session) }
    }

    private var detail: String {
        switch session.agentPhase {
        case .working:
            if let status = session.agentScreen.status { return status }
            if let done = session.agentScreen.tasksDone, let total = session.agentScreen.tasksTotal { return "\(done) de \(total) tareas" }
            return "Trabajando…"
        case .needsInput: return "Te está preguntando algo"
        case .finished(_, let after): return "Terminó en \(IslandStatus.elapsed(after))"
        case .idle: return ""
        }
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}
