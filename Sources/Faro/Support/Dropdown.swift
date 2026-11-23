import AppKit
import FaroCore
import Observation

/// Terminal desplegable: con el atajo global baja desde arriba encima de cualquier app y con el
/// mismo atajo se esconde, devolviendo el foco a donde estabas. Sus pestañas siguen vivas
/// mientras está escondida.
@MainActor
@Observable
final class Dropdown {
    static let shared = Dropdown()

    /// El atajo no se ha podido registrar (otra app lo tiene en exclusiva).
    private(set) var hotKeyFailed = false
    @ObservationIgnored private(set) var controller: TerminalWindowController?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Al pasar a otra app (clic fuera), se esconde sin robarle el foco.
                // En Faro Dev (modo de prueba) no: las pruebas le devuelven el foco a otra app.
                if AppModel.shared.settings.dropdownHideOnBlur && !AppModel.testMode { Dropdown.shared.hide(restoreFocus: false) }
            }
        }
    }

    var isVisible: Bool { controller?.window?.isVisible == true }

    func applySettings() {
        let settings = AppModel.shared.settings
        if settings.dropdownEnabled {
            GlobalHotKey.shared.action = { Dropdown.shared.toggle() }
            hotKeyFailed = !GlobalHotKey.shared.register(GlobalHotKey.shortcut(settings.dropdownShortcut))
            if isVisible, let window = controller?.window, let screen = window.screen ?? NSScreen.main {
                window.setFrame(frame(on: screen), display: true, animate: true)
            }
        } else {
            GlobalHotKey.shared.unregister()
            hotKeyFailed = false
            hide(restoreFocus: false)
        }
    }

    func toggle() {
        if let window = controller?.window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            hide(restoreFocus: true)
        } else {
            show()
        }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        let controller = self.controller ?? make()
        guard let window = controller.window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let target = frame(on: screen)
        if !window.isVisible || window.screen != screen {
            window.setFrame(target.offsetBy(dx: 0, dy: target.height), display: false)
            window.alphaValue = 0
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }
        controller.focusTerminal()
    }

    /// `restoreFocus`: vuelve a la app en la que estabas antes de abrirla.
    func hide(restoreFocus: Bool) {
        guard let window = controller?.window, window.isVisible else { return }
        let frame = window.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
        if restoreFocus, let previous = previousApp, !previous.isTerminated {
            previous.activate()
        }
        previousApp = nil
    }

    /// Se ha cerrado su última pestaña: la próxima vez se abre una nueva.
    func closed() {
        controller = nil
        if let previous = previousApp, !previous.isTerminated { previous.activate() }
        previousApp = nil
    }

    private func make() -> TerminalWindowController {
        let controller = TerminalWindowController(dropdown: true)
        AppModel.shared.windows.append(controller)
        controller.newTab(directory: NSHomeDirectory())
        self.controller = controller
        return controller
    }

    /// A todo lo ancho, pegada bajo la barra de menús, con el alto elegido.
    private func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let height = (visible.height * min(max(AppModel.shared.settings.dropdownHeight, 0.25), 0.9)).rounded()
        return NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
    }
}
