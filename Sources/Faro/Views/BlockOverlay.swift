import AppKit
import FaroCore
import SwiftUI

/// Resalta el bloque (comando + salida) bajo el ratón, con una franja a la izquierda según cómo
/// acabó y una barra pequeña de acciones. Solo la barra recibe clics: el resto del terminal se
/// sigue usando igual (seleccionar, desplazar…).
final class BlockOverlay: NSView {
    private let box = NSView()
    private let stripe = NSView()
    private var toolbar: NSHostingView<BlockToolbar>?
    private(set) var blockID: Int?
    /// Dónde está la barra de botones del bloque (en esta vista), si se ve.
    var toolbarFrame: NSRect? { toolbar.flatMap { isHidden || $0.isHidden ? nil : $0.frame } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 0.5
        stripe.wantsLayer = true
        stripe.layer?.cornerRadius = 1
        addSubview(box)
        addSubview(stripe)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let toolbar, !toolbar.isHidden else { return nil }
        let local = convert(point, from: superview)
        return toolbar.frame.contains(local) ? toolbar.hitTest(convert(local, to: toolbar.superview)) : nil
    }

    @MainActor
    func show(_ block: CommandBlock, in rect: NSRect, session: TerminalSession) {
        let palette = AppModel.shared.palette
        let tint = block.exit.map { $0 == 0 || TerminalSession.wasStopped($0) ? palette.success : palette.failure } ?? palette.accent
        box.frame = rect.insetBy(dx: -2, dy: -1)
        box.layer?.backgroundColor = NSColor(palette.text).withAlphaComponent(0.035).cgColor
        box.layer?.borderColor = NSColor(palette.text).withAlphaComponent(0.10).cgColor
        stripe.frame = NSRect(x: max(0, rect.minX - 2), y: rect.minY + 2, width: 2, height: max(2, rect.height - 4))
        stripe.layer?.backgroundColor = NSColor(tint).withAlphaComponent(block.exit == 0 ? 0.55 : 0.85).cgColor

        let content = BlockToolbar(block: block, session: session, palette: palette)
        if let toolbar {
            toolbar.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            addSubview(host)
            toolbar = host
        }
        if let toolbar {
            let size = toolbar.fittingSize
            // Arriba a la derecha del bloque (el origen está abajo), sin salirse de la vista.
            let y = min(max(rect.maxY - size.height - 2, 2), max(2, bounds.height - size.height - 2))
            toolbar.frame = NSRect(x: max(4, rect.maxX - size.width - 6), y: y, width: size.width, height: size.height)
            toolbar.isHidden = false
        }
        blockID = block.id
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        blockID = nil
    }
}

struct BlockToolbar: View {
    let block: CommandBlock
    let session: TerminalSession
    let palette: Palette

    var body: some View {
        HStack(spacing: 1) {
            status
                .padding(.horizontal, 7)
            Rectangle().fill(palette.hairline).frame(width: 0.5, height: 14)
            button("doc.on.doc", "Copiar la salida") { session.copyOutput(of: block) }
            button("text.alignleft", "Copiar el comando") { session.copyCommand(of: block) }
            if AppModel.shared.installedAgents.contains(.claude) {
                Button { session.askClaude(about: block) } label: {
                    AgentLogo(agent: .claude, size: 11).frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle())
                .help((block.exit ?? 0) != 0 ? "Preguntar a Claude por este error" : "Preguntar a Claude por esta salida")
            }
            if !block.isRunning && session.atPrompt {
                button("arrow.clockwise", "Volver a ejecutar") { session.rerun(block) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.hairline, lineWidth: 0.5))
        .environment(\.palette, palette)
        .environment(\.colorScheme, palette.theme.isDark ? .dark : .light)
        .fixedSize()
    }

    @ViewBuilder private var status: some View {
        if block.isRunning {
            HStack(spacing: 4) {
                Circle().fill(palette.accent).frame(width: 5, height: 5)
                Text("En marcha").font(.ui(11, .medium)).foregroundStyle(palette.secondaryText)
            }
        } else if let exit = block.exit {
            HStack(spacing: 4) {
                Image(systemName: exit == 0 ? "checkmark" : TerminalSession.wasStopped(exit) ? "stop.fill" : "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(exit == 0 ? palette.success : TerminalSession.wasStopped(exit) ? palette.tertiaryText : palette.failure)
                Text(exit == 0 ? Notifier.format(block.milliseconds ?? 0) : "\(exit) · \(Notifier.format(block.milliseconds ?? 0))")
                    .font(.ui(11, .medium)).monospacedDigit().foregroundStyle(palette.secondaryText)
            }
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}
