import AppKit
import UserNotifications

/// Avisa cuando termina un comando largo y no lo estás mirando.
@MainActor
enum Notifier {
    private static var authorized: Bool?

    static func commandFinished(command: String, exit: Int32, milliseconds: Int, session: TerminalSession) {
        guard AppModel.shared.settings.notifyLongCommands, milliseconds >= 10_000 else { return }
        let visible = NSApp.isActive && session.window?.isVisible(session) == true && session.window?.window?.isKeyWindow == true
        if visible { return }
        if session.window?.isVisible(session) != true { session.hasUnseenActivity = true }
        let content = UNMutableNotificationContent()
        content.title = exit == 0 ? "Terminado: \(short(command))"
            : TerminalSession.wasStopped(exit) ? "Detenido: \(short(command))" : "Ha fallado: \(short(command))"
        content.body = "\(session.displayFolder) · \(format(milliseconds))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            if authorized == true { try? await center.add(request) }
        }
    }

    static func format(_ ms: Int) -> String {
        if ms < 1_000 { return "\(ms) ms" }
        let s = Double(ms) / 1_000
        if s < 60 { return String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",") }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }

    private static func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }
}

extension TerminalSession {
    var displayFolder: String {
        cwd == NSHomeDirectory() ? "~" : (cwd as NSString).lastPathComponent
    }
}
