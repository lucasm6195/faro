import AppKit
import Carbon

/// Atajo de teclado global (funciona aunque Faro no esté delante). Usa Carbon
/// (`RegisterEventHotKey`), que no necesita permiso de accesibilidad.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    struct Shortcut: Identifiable, Equatable {
        let id: String
        let label: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static let shortcuts: [Shortcut] = [
        Shortcut(id: "control-option-space", label: "⌃⌥ Espacio", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        Shortcut(id: "option-space", label: "⌥ Espacio", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        Shortcut(id: "shift-option-space", label: "⇧⌥ Espacio", keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | optionKey)),
        Shortcut(id: "control-option-t", label: "⌃⌥ T", keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)),
    ]

    static func shortcut(_ id: String) -> Shortcut { shortcuts.first { $0.id == id } ?? shortcuts[0] }

    var action: (() -> Void)?
    private(set) var registered: Shortcut?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// Devuelve false si el sistema no deja registrarlo (lo tiene otra app en exclusiva).
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if registered == shortcut, ref != nil { return true }
        unregister()
        installHandler()
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4641_524F), id: 1) // 'FARO'
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &newRef) == noErr else {
            return false
        }
        ref = newRef
        registered = shortcut
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// La app de ChatGPT usa ⌥Espacio para su lanzador: si coincide, se abrirían las dos.
    static func conflict(for shortcut: Shortcut) -> String? {
        guard let raw = UserDefaults(suiteName: "com.openai.chat")?.string(forKey: "KeyboardShortcuts_toggleLauncher"),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              json["carbonKeyCode"].map(UInt32.init) == shortcut.keyCode,
              json["carbonModifiers"].map(UInt32.init) == shortcut.modifiers else { return nil }
        return "ChatGPT usa este mismo atajo para su lanzador: al pulsarlo se abrirían los dos."
    }
}
