import AppKit
import AVFoundation
import FaroCore
import QuartzCore
import SwiftTerm

/// Graba las ventanas de Faro dibujando sus propias capas en cada fotograma: no necesita el
/// permiso de grabación de pantalla y solo sale Faro, nada más de la pantalla. Solo se usa en
/// el modo demo (para el vídeo de presentación).
@MainActor
final class DemoRecorder: NSObject, DemoCapture {
    var info: [String: Any] { ["mode": "window"] }
    let window: NSWindow
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pixelSize: CGSize
    private let scale: CGFloat
    private var link: CADisplayLink?
    private(set) var startTime: CFTimeInterval = 0
    /// Momento de inicio en el reloj de pared, para alinear el guion con el vídeo.
    private(set) var startDate = Date()
    private var frames = 0
    private var slowFrames = 0
    private var renderTime: CFTimeInterval = 0
    nonisolated(unsafe) static var layerTime: CFTimeInterval = 0
    nonisolated(unsafe) static var terminalTime: CFTimeInterval = 0

    init(window: NSWindow, url: URL, bitrate: Int = 60_000_000) throws {
        self.window = window
        scale = window.backingScaleFactor
        let size = window.frame.size
        pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height),
        ])
        writer.add(input)
        super.init()
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        startTime = CACurrentMediaTime()
        startDate = Date()
        guard let view = window.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Segundos desde el inicio de la grabación.
    var elapsed: Double { CACurrentMediaTime() - startTime }

    @objc private func tick(_ link: CADisplayLink) {
        let t = CACurrentMediaTime() - startTime
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { slowFrames += 1; return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let began = CACurrentMediaTime()
        render(into: buffer)
        renderTime += CACurrentMediaTime() - began
        let time = CMTime(seconds: t, preferredTimescale: 60_000)
        if adaptor.append(buffer, withPresentationTime: time) { frames += 1 }

    }

    private func render(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(pixelSize.width), height: Int(pixelSize.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        Self.draw(window: window, in: context, scale: scale, size: pixelSize, cacheChrome: true)
    }

    /// Dibujar la interfaz cuesta ~30 ms: si nada ha cambiado (ni el terminal ni la interfaz, que
    /// el guion avisa cuando toca), se reutiliza el fotograma anterior.
    nonisolated(unsafe) static var chromeActiveUntil: CFTimeInterval = 0
    nonisolated(unsafe) private static var lastFrame: (image: CGImage, key: Int, time: CFTimeInterval, size: CGSize)?
    static func activity(_ seconds: Double = 0.8) {
        chromeActiveUntil = max(chromeActiveUntil, CACurrentMediaTime() + seconds)
    }

    /// Dibuja la ventana y las ventanas de Faro que hay encima (paneles emergentes) en el contexto.
    static func draw(window: NSWindow, in context: CGContext, scale: CGFloat, size: CGSize, cacheChrome: Bool = false) {
        context.clear(CGRect(origin: .zero, size: size))
        let now = CACurrentMediaTime()
        let t1 = CACurrentMediaTime()
        let views = window.contentView.map { terminals(in: $0) } ?? []
        var hasher = Hasher()
        var images: [(view: FaroTerminalView, image: CGImage)] = []
        for view in views {
            guard let (image, key) = terminalImage(view) else { continue }
            images.append((view, image))
            hasher.combine(key)
        }
        terminalTime += CACurrentMediaTime() - t1
        let key = hasher.finalize()
        if cacheChrome, let last = lastFrame, last.key == key, last.size == size, now >= chromeActiveUntil, now - last.time < 0.5 {
            context.draw(last.image, in: CGRect(origin: .zero, size: size))
            return
        }
        let t0 = CACurrentMediaTime()
        guard let image = renderTree(window: window, terminals: images, scale: scale, size: size) else { return }
        layerTime += CACurrentMediaTime() - t0
        lastFrame = (image, key, now, size)
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }

    /// Dibuja el árbol de capas de las ventanas. Las vistas del terminal no dejan su texto en la
    /// capa, así que, solo durante este dibujo, se les pone como contenido la imagen pintada:
    /// todo lo que flota encima (paleta, paneles, texto fantasma) queda en su sitio. Son cambios
    /// que no se confirman, así que en pantalla no se nota nada.
    private static func renderTree(window: NSWindow, terminals: [(view: FaroTerminalView, image: CGImage)], scale: CGFloat, size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let origin = window.frame.origin
        let stack = [window] + NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.frame.intersects(window.frame)
                && ($0.level.rawValue >= window.level.rawValue || $0.parent === window)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // La capa de la vista del terminal siempre le pide a la vista que se dibuje (y su dibujo
        // no trae el fondo): la imagen pintada va como subcapa encima, por debajo de lo que la
        // vista lleva dentro (resaltado de bloques). La subcapa de AppKit con lo dibujado se oculta.
        var added: [CALayer] = []
        var covered: [CALayer] = []
        for (view, image) in terminals {
            guard let layer = view.layer else { continue }
            for sub in layer.sublayers ?? [] where !sub.isHidden && String(describing: type(of: sub)) == "ContentLayer" {
                sub.isHidden = true
                covered.append(sub)
            }
            let painted = CALayer()
            painted.frame = layer.bounds
            painted.contents = image
            painted.contentsScale = scale
            painted.contentsGravity = .resize
            layer.insertSublayer(painted, at: 0)
            added.append(painted)
        }
        for w in stack {
            guard let root = w.contentView, let layer = root.layer else { continue }
            context.saveGState()
            context.translateBy(x: w.frame.minX - origin.x, y: w.frame.minY - origin.y)
            // Sin la máscara de las esquinas: las redondea el montaje (y así cuesta la mitad).
            let masked = layer.masksToBounds
            layer.masksToBounds = false
            layer.render(in: context)
            layer.masksToBounds = masked
            context.restoreGState()
        }
        for layer in covered { layer.isHidden = false }
        for layer in added { layer.removeFromSuperlayer() }
        CATransaction.commit()
        return context.makeImage()
    }

    private static func terminals(in view: NSView) -> [FaroTerminalView] {
        if let terminal = view as? FaroTerminalView { return terminal.isHiddenOrHasHiddenAncestor ? [] : [terminal] }
        return view.subviews.flatMap { terminals(in: $0) }
    }

    /// Última imagen pintada de cada terminal: casi siempre la pantalla no cambia entre fotogramas.
    nonisolated(unsafe) private static var terminalCache: [ObjectIdentifier: (key: Int, image: CGImage)] = [:]

    /// Imagen del texto del terminal (pintada a partir de la copia de su pantalla, con la misma
    /// fuente y tamaño de celda) y una clave que cambia cuando cambia lo que se ve.
    private static func terminalImage(_ view: FaroTerminalView) -> (CGImage, Int)? {
        guard let snapshot = view.terminalContentSnapshot(region: .viewport) else { return nil }
        let cell = view.caretFrame.size
        guard cell.width > 0, cell.height > 0 else { return nil }
        let bounds = view.bounds
        let focused = view.window?.firstResponder === view
        let theme = AppModel.shared.theme
        let caret = view.caretFrame

        var hasher = Hasher()
        hasher.combine(theme.id)
        hasher.combine(focused)
        hasher.combine(bounds.width); hasher.combine(bounds.height)
        hasher.combine(caret.minX); hasher.combine(caret.minY)
        for row in snapshot.rows {
            for item in row.cells {
                hasher.combine(item.text)
                hasher.combine(item.attribute)
            }
            hasher.combine(-1)
        }
        let key = hasher.finalize()
        let id = ObjectIdentifier(view)
        if let cached = terminalCache[id], cached.key == key { return (cached.image, key) }
        guard let painted = paintTerminal(snapshot: snapshot, cell: cell, size: bounds.size, caret: caret, focused: focused,
                                          scale: view.window?.backingScaleFactor ?? 2) else { return nil }
        terminalCache[id] = (key, painted)
        return (painted, key)
    }

    private static func paintTerminal(snapshot: TerminalContentSnapshot, cell: CGSize, size: CGSize, caret: CGRect,
                                      focused: Bool, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let theme = AppModel.shared.theme
        let settings = AppModel.shared.settings
        let regular = Fonts.terminal(name: settings.fontName, size: settings.fontSize)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let foreground = RGB(hex: theme.foreground).nsColor
        let background = RGB(hex: theme.background).nsColor
        let ansi = theme.ansi.map { RGB(hex: $0).nsColor }
        var glyph = CGGlyph(0)
        var mChar: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(regular, &mChar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        let kern = cell.width - advance.width

        func color(_ value: Attribute.Color, isForeground: Bool) -> NSColor {
            switch value {
            case .defaultColor: return isForeground ? foreground : background
            case .defaultInvertedColor: return background
            case .trueColor(let r, let g, let b):
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            case .ansi256(let code):
                let c = Int(code)
                if c < ansi.count { return ansi[c] }
                if c < 232 {
                    let i = c - 16
                    let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
                    return NSColor(srgbRed: steps[i / 36] / 255, green: steps[(i / 6) % 6] / 255, blue: steps[i % 6] / 255, alpha: 1)
                }
                let gray = CGFloat(8 + (c - 232) * 10) / 255
                return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
            }
        }

        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let ascent = regular.ascender, descent = -regular.descender
        let baselineInset = (cell.height - (ascent + descent)) / 2 + descent

        struct Style: Equatable { let fg: NSColor; let bg: NSColor?; let bold: Bool; let underline: Bool }
        for (rowIndex, row) in snapshot.rows.enumerated() {
            let bottom = size.height - CGFloat(rowIndex + 1) * cell.height
            var column = 0
            var runStart = 0
            var runText = ""
            var runStyle: Style?

            func flush() {
                guard let style = runStyle, !runText.isEmpty else { return }
                let x = CGFloat(runStart) * cell.width
                if let bg = style.bg {
                    context.setFillColor(bg.cgColor)
                    context.fill(CGRect(x: x, y: bottom, width: CGFloat(runText.count) * cell.width, height: cell.height))
                }
                guard runText.contains(where: { $0 != " " }) else { return }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: runText, attributes: [
                    .font: style.bold ? bold : regular, .foregroundColor: style.fg, .kern: kern,
                    .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0,
                ]))
                context.textPosition = CGPoint(x: x, y: bottom + baselineInset)
                CTLineDraw(line, context)
            }

            for item in row.cells {
                let attribute = item.attribute
                var fg = color(attribute.fg, isForeground: true)
                var bg: NSColor? = attribute.bg == .defaultInvertedColor ? nil : color(attribute.bg, isForeground: false)
                if attribute.style.contains(.inverse) {
                    let swapped = bg ?? background
                    bg = fg
                    fg = swapped
                }
                if attribute.style.contains(.bold), case .ansi256(let code) = attribute.fg, code < 8, Int(code) + 8 < ansi.count {
                    fg = ansi[Int(code) + 8]
                }
                if attribute.style.contains(.dim) { fg = fg.withAlphaComponent(0.6) }
                let style = Style(fg: fg, bg: bg, bold: attribute.style.contains(.bold), underline: attribute.style.contains(.underline))
                let width = max(1, item.width)
                let text = item.isBlank || attribute.style.contains(.invisible) ? " " : item.text
                // Los caracteres anchos (emoji, CJK) van sueltos para no descuadrar la rejilla.
                if style != runStyle || width > 1 || item.width == 0 {
                    flush()
                    runStart = column
                    runText = ""
                    runStyle = style
                }
                if item.width > 0 { runText += text }
                if width > 1 {
                    flush()
                    runText = ""
                    runStyle = nil
                }
                column += width
                if width > 1 { runStart = column }
            }
            flush()
        }
        if focused {
            context.setFillColor(RGB(hex: theme.cursor).nsColor.cgColor)
            switch settings.cursorShape {
            case .bar: context.fill(CGRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height))
            case .block: context.fill(caret)
            case .underline: context.fill(CGRect(x: caret.minX, y: caret.minY, width: caret.width, height: 2))
            }
        }
        return context.makeImage()
    }

    /// Termina y cierra el archivo. Devuelve un resumen (fotogramas, tiempo medio de dibujo).
    func stop() async -> String {
        link?.invalidate()
        link = nil
        input.markAsFinished()
        await writer.finishWriting()
        let average = frames > 0 ? renderTime / Double(frames) * 1000 : 0
        let n = Double(max(frames, 1))
        return "fotogramas=\(frames) perdidos=\(slowFrames) dibujo=\(String(format: "%.1f", average)) ms capas=\(String(format: "%.1f", Self.layerTime / n * 1000)) terminal=\(String(format: "%.1f", Self.terminalTime / n * 1000)) estado=\(writer.status.rawValue) \(writer.error.map { "\($0)" } ?? "")"
    }

    /// Una captura fija en PNG (para revisar la calidad).
    static func snapshot(of window: NSWindow, to url: URL) {
        let scale = window.backingScaleFactor
        let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        draw(window: window, in: context, scale: scale, size: size)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
