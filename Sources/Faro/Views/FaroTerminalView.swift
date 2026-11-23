import AppKit
import FaroCore
import SwiftTerm

final class FaroTerminalView: LocalProcessTerminalView {
    weak var session: TerminalSession?
    private var applied: (settings: FaroSettings, theme: Theme)?

    func apply(settings: FaroSettings, theme: Theme) {
        let old = applied
        applied = (settings, theme)

        if old?.settings.fontName != settings.fontName || old?.settings.fontSize != settings.fontSize {
            font = Fonts.terminal(name: settings.fontName, size: settings.fontSize)
        }
        if old?.theme != theme || old?.settings.backgroundOpacity != settings.backgroundOpacity {
            let bg = RGB(hex: theme.background).nsColor
            nativeBackgroundColor = bg.withAlphaComponent(settings.backgroundOpacity)
            nativeForegroundColor = RGB(hex: theme.foreground).nsColor
            caretColor = RGB(hex: theme.cursor).nsColor
            selectedTextBackgroundColor = RGB(hex: theme.selection).nsColor
            installColors(theme.ansi.map { RGB(hex: $0).terminalColor })
        }
        // Con teclado español, Opción escribe @ # | [ ] { }: por defecto no actúa como Meta.
        optionAsMetaKey = settings.optionAsMeta
        if old?.settings.cursorShape != settings.cursorShape || old?.settings.cursorBlink != settings.cursorBlink {
            setCursorStyle(Self.cursorStyle(settings.cursorShape, blink: settings.cursorBlink))
        }
        if old?.settings.gpuRendering != settings.gpuRendering {
            try? setUseMetal(settings.gpuRendering && settings.backgroundOpacity >= 1)
        }
        if old?.settings.scrollback != settings.scrollback {
            changeScrollback(settings.scrollback)
        }
        bellStyle = .none
    }

    static func cursorStyle(_ shape: FaroSettings.CursorShape, blink: Bool) -> CursorStyle {
        switch (shape, blink) {
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    /// ⌘+clic en una ruta o URL: el archivo se abre en tu editor en su línea, la URL en el navegador.
    /// En la demo la ventana se graba en segundo plano: el cursor se dibuja como si estuviera activa.
    override var hasFocus: Bool {
        get { DemoMode.enabled ? window?.firstResponder === self : super.hasFocus }
        set { super.hasFocus = newValue }
    }

    override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if let session, session.openLink(request.link) { return }
        super.requestOpenLink(source: source, request: request)
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        session?.viewportDirty.withLock { $0 = true }
        session?.hideBlock()
        session?.updateCaret()
    }
}
