// Monta el vídeo de presentación a partir de la grabación del modo demo.
// Fondo de escritorio de macOS, ventana con sombra, zooms suaves, cursor animado, clics,
// rótulos, una entrada con el haz de un faro y un cierre con avisos. 2560×1440 a 60 fps.
//
// swiftc -O scripts/demo/Compose.swift -o /tmp/compose
// /tmp/compose <carpeta con raw.mov y timeline.json> <salida.mp4> <carpeta del proyecto> [alto: 1440|1080]

import AVFoundation
import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("uso: compose <carpeta-grabación> <salida.mp4> <carpeta-del-proyecto> [alto]")
    exit(1)
}
let input = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let project = URL(fileURLWithPath: args[3])
let outHeight = args.count > 4 ? Double(args[4]) ?? 1440 : 1440

// Todo se calcula en un lienzo lógico de 1920×1080 y se dibuja a la resolución de salida.
let canvas = CGSize(width: 1920, height: 1080)
let R = outHeight / 1080
let outSize = CGSize(width: (canvas.width * R).rounded(), height: (canvas.height * R).rounded())
let fps = 60.0

// MARK: Recursos

for name in ["InterDisplay-Regular.otf", "InterDisplay-Medium.otf", "InterDisplay-SemiBold.otf"] {
    CTFontManagerRegisterFontsForURL(project.appendingPathComponent("Resources/Fonts/\(name)") as CFURL, .process, nil)
}
func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size * R, nil) }
let iconImage: CGImage? = {
    guard let src = CGImageSourceCreateWithURL(project.appendingPathComponent("Resources/icon-1024.png") as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}()
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Contexto en píxeles de salida para un tamaño lógico (dibuja en coordenadas lógicas).
func makeContext(_ size: CGSize) -> CGContext {
    let ctx = CGContext(data: nil, width: Int((size.width * R).rounded(.up)), height: Int((size.height * R).rounded(.up)),
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: R, y: R)
    return ctx
}
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
/// Una imagen dibujada a la resolución de salida, colocada en el lienzo lógico (origen arriba).
func place(_ image: CGImage, x: CGFloat, y: CGFloat, scale: CGFloat = 1, alpha: Double = 1) -> CIImage {
    let w = CGFloat(image.width) / R * scale, h = CGFloat(image.height) / R * scale
    var ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale / R, y: scale / R))
    ci = ci.transformed(by: CGAffineTransform(translationX: x, y: canvas.height - y - h))
    _ = w
    return alpha < 1 ? withAlpha(ci, alpha) : ci
}
func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
    image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, min(1, alpha))))])
}
func easeInOut(_ x: Double) -> Double {
    let p = min(max(x, 0), 1)
    return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
}
func easeOut(_ x: Double) -> Double { let p = min(max(x, 0), 1); return 1 - pow(1 - p, 3) }
/// Muelle con un pequeño rebote, de 0 a 1.
func spring(_ x: Double) -> Double {
    let p = min(max(x, 0), 1)
    return 1 - exp(-6.5 * p) * cos(9.5 * p)
}
func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func textWidth(_ text: String, _ f: CTFont) -> CGFloat {
    CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f])), nil, nil, nil) / R
}
func drawText(_ ctx: CGContext, _ text: String, font f: CTFont, color: CGColor, x: CGFloat, baseline: CGFloat) {
    // El contexto está escalado por R y la fuente también: se dibuja en un estado sin escala.
    ctx.saveGState()
    ctx.scaleBy(x: 1 / R, y: 1 / R)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color]))
    ctx.textPosition = CGPoint(x: x * R, y: baseline * R)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: Guion de la grabación

struct Event {
    let t: Double
    let kind: String
    let x: Double, y: Double, dur: Double, scale: Double
    let title: String, subtitle: String
    /// Zoom que puede salirse de la ventana (por ejemplo, al notch).
    let free: Bool
}
let timeline = try JSONSerialization.jsonObject(with: Data(contentsOf: input.appendingPathComponent("timeline.json"))) as! [String: Any]
let windowInfo = timeline["window"] as! [String: Double]
let W = windowInfo["width"]!, H = windowInfo["height"]!, S = windowInfo["scale"]!
let recordingDuration = timeline["duration"] as! Double
let events: [Event] = (timeline["events"] as! [[String: Any]]).map {
    Event(t: $0["t"] as? Double ?? 0, kind: $0["kind"] as? String ?? "",
          x: $0["x"] as? Double ?? 0, y: $0["y"] as? Double ?? 0, dur: $0["dur"] as? Double ?? 0,
          scale: $0["scale"] as? Double ?? 1, title: $0["title"] as? String ?? "", subtitle: $0["subtitle"] as? String ?? "",
          free: $0["free"] as? Bool ?? false)
}.sorted { $0.t < $1.t }

let introDuration = 3.9
let outroDuration = 8.4

/// Tramos acelerados (mientras Claude trabaja): de tiempo del vídeo a tiempo de la grabación.
struct SpeedSegment { let rec: Double; let out: Double; let factor: Double }
let speedSegments: [SpeedSegment] = {
    var segments = [SpeedSegment(rec: 0, out: 0, factor: 1)]
    for e in events where e.kind == "speed" {
        let last = segments[segments.count - 1]
        segments.append(SpeedSegment(rec: e.t, out: last.out + (e.t - last.rec) / last.factor, factor: max(1, e.scale)))
    }
    return segments
}()
let recordingOut: Double = {
    let last = speedSegments[speedSegments.count - 1]
    return last.out + (recordingDuration - last.rec) / last.factor
}()
func recordingTime(_ out: Double) -> Double {
    let s = speedSegments.last { $0.out <= out } ?? speedSegments[0]
    return min(recordingDuration, s.rec + (out - s.out) * s.factor)
}
func speedFactor(at rec: Double) -> Double { (speedSegments.last { $0.rec <= rec } ?? speedSegments[0]).factor }
let total = introDuration + recordingOut + outroDuration

// Qué se grabó: la pantalla entera (ventanas de Faro sobre transparente) o solo la ventana.
let capture = timeline["capture"] as? [String: Any] ?? [:]
let screenCapture = capture["mode"] as? String == "screen"
let captureHeight = capture["height"] as? Double ?? H * S
let captureWidth = capture["width"] as? Double ?? W * S
let windowOrigin = CGPoint(x: capture["windowX"] as? Double ?? 0, y: capture["windowY"] as? Double ?? 0)
let notchSize = CGSize(width: capture["notchWidth"] as? Double ?? 185, height: capture["notchHeight"] as? Double ?? 32)

/// Ventana sin zoom: 860 de alto, centrada, con sitio abajo para los rótulos.
let k = 860.0 / H
let windowCanvas = CGRect(x: (canvas.width - W * k) / 2, y: 52, width: W * k, height: H * k)
let stageCenter = CGPoint(x: canvas.width / 2, y: windowCanvas.midY)

// MARK: Cámara

struct Camera { var zoom: Double; var cx: Double; var cy: Double }
let zoomEvents = events.filter { $0.kind == "zoom" }
let zoomDuration = 0.9
func clampCamera(_ c: Camera, free: Bool = false) -> Camera {
    var c = c
    if free {
        // Lo que se ve no sale del escritorio (el lienzo), aunque sí de la ventana.
        let z = k * c.zoom
        let minX = stageCenter.x / z - windowCanvas.minX / k, maxX = (canvas.width - windowCanvas.minX) / k - (canvas.width - stageCenter.x) / z
        let minY = stageCenter.y / z - windowCanvas.minY / k, maxY = (canvas.height - windowCanvas.minY) / k - (canvas.height - stageCenter.y) / z
        c.cx = minX <= maxX ? min(max(c.cx, minX), maxX) : (minX + maxX) / 2
        c.cy = minY <= maxY ? min(max(c.cy, minY), maxY) : (minY + maxY) / 2
        return c
    }
    let halfW = canvas.width / 2 / (k * c.zoom), halfH = windowCanvas.height / 2 / (k * c.zoom)
    c.cx = W > 2 * halfW ? min(max(c.cx, halfW), W - halfW) : W / 2
    c.cy = H > 2 * halfH ? min(max(c.cy, halfH), H - halfH) : H / 2
    return c
}
func interpolate(_ from: Camera, _ e: Event, _ t: Double) -> Camera {
    let target = clampCamera(Camera(zoom: e.scale, cx: e.x, cy: e.y), free: e.free)
    let p = easeInOut((t - e.t) / zoomDuration)
    let mid = Camera(zoom: exp(log(from.zoom) + (log(target.zoom) - log(from.zoom)) * p),
                     cx: from.cx + (target.cx - from.cx) * p, cy: from.cy + (target.cy - from.cy) * p)
    return p >= 1 ? target : clampCamera(mid, free: true)
}
var cameraStarts: [Camera] = []
do {
    var state = Camera(zoom: 1, cx: W / 2, cy: H / 2)
    for (i, e) in zoomEvents.enumerated() {
        if i > 0 { state = interpolate(cameraStarts[i - 1], zoomEvents[i - 1], e.t) }
        cameraStarts.append(state)
    }
}
func camera(at t: Double) -> Camera {
    guard let i = zoomEvents.lastIndex(where: { $0.t <= t }) else { return Camera(zoom: 1, cx: W / 2, cy: H / 2) }
    return interpolate(cameraStarts[i], zoomEvents[i], t)
}
func toCanvas(_ x: Double, _ y: Double, _ c: Camera) -> CGPoint {
    CGPoint(x: stageCenter.x + (x - c.cx) * k * c.zoom, y: stageCenter.y + (y - c.cy) * k * c.zoom)
}

// Cursor y clics
let cursorEvents = events.filter { $0.kind == "cursor" }
func cursor(at t: Double) -> CGPoint {
    var pos = CGPoint(x: cursorEvents.first?.x ?? W / 2, y: cursorEvents.first?.y ?? H / 2)
    for e in cursorEvents where e.t <= t {
        let p = e.dur > 0 ? easeInOut((t - e.t) / e.dur) : 1
        pos = CGPoint(x: pos.x + (e.x - pos.x) * p, y: pos.y + (e.y - pos.y) * p)
    }
    return pos
}
let clicks = events.filter { $0.kind == "click" }

// MARK: Fondo de escritorio

/// Sonoma (la versión oscura) a pantalla completa.
func loadWallpaper() -> CGImage {
    let path = "/System/Library/Desktop Pictures/Sonoma.heic"
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let index = CGImageSourceGetCount(src) > 1 ? 1 : 0
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int(outSize.width * 1.6),
                                 kCGImageSourceCreateThumbnailWithTransform: true]
    let image = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)!
    let ctx = makeContext(canvas)
    let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
    let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
    // Un velo suave para que la ventana destaque.
    ctx.setFillColor(rgb(0x05060C, 0.18))
    ctx.fill(CGRect(origin: .zero, size: canvas))
    return ctx.makeImage()!
}
let wallpaper = CIImage(cgImage: loadWallpaper()).transformed(by: CGAffineTransform(scaleX: 1 / R, y: 1 / R))
/// De noche: el mismo escritorio muy oscuro (lo ilumina el haz del faro).
let night = wallpaper.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.32, kCIInputSaturationKey: 0.55])
    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2.6])

/// Sombra de la ventana en su sitio sin zoom.
func makeShadow() -> CIImage {
    let ctx = makeContext(canvas)
    let rect = CGRect(x: windowCanvas.minX, y: canvas.height - windowCanvas.maxY, width: windowCanvas.width, height: windowCanvas.height)
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 80, color: rgb(0x000000, 0.7))
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 6, dy: 6), cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(rgb(0x000000, 0.9))
    ctx.fillPath()
    return CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(scaleX: 1 / R, y: 1 / R))
}
let shadowImage = makeShadow()

// MARK: Barra de menús y notch

/// La barra de menús de macOS con Faro delante, y el notch en el centro.
func makeMenuBar() -> CIImage {
    let height = notchSize.height * k
    let size = CGSize(width: canvas.width, height: height)
    let ctx = makeContext(size)
    ctx.setFillColor(rgb(0x000000, 0.22))
    ctx.fill(CGRect(origin: .zero, size: size))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    func symbol(_ name: String, x: CGFloat, size points: CGFloat, weight: NSFont.Weight = .medium) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: points * k, weight: weight).applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return 0 }
        image.draw(in: CGRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height))
        return image.size.width
    }
    let regular = NSFont.systemFont(ofSize: 13.5 * k * R, weight: .regular) as CTFont
    let bold = NSFont.systemFont(ofSize: 13.5 * k * R, weight: .bold) as CTFont
    let baseline = height / 2 - 5.2 * k
    var x: CGFloat = 20 * k
    x += symbol("applelogo", x: x, size: 15) + 22 * k
    for (i, item) in ["Faro", "Archivo", "Edición", "Ver", "Ventana", "Ayuda"].enumerated() {
        let f = i == 0 ? bold : regular
        drawText(ctx, item, font: f, color: rgb(0xFFFFFF, 0.95), x: x, baseline: baseline)
        x += textWidth(item, f) + 20 * k
    }
    let clockFormat = DateFormatter()
    clockFormat.locale = Locale(identifier: "es_ES")
    clockFormat.dateFormat = "EEE d MMM  H:mm"
    let clock = clockFormat.string(from: Date()).replacingOccurrences(of: ".", with: "")
    var right = canvas.width - 18 * k - textWidth(clock, regular)
    drawText(ctx, clock, font: regular, color: rgb(0xFFFFFF, 0.95), x: right, baseline: baseline)
    for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] {
        let width = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14 * k, weight: .medium))?.size.width ?? 16
        right -= width + 18 * k
        _ = symbol(name, x: right, size: 14)
    }
    NSGraphicsContext.restoreGraphicsState()
    // El notch.
    let notch = CGRect(x: (canvas.width - notchSize.width * k) / 2, y: 0, width: notchSize.width * k, height: height)
    let path = CGMutablePath()
    let r = 9 * k
    path.move(to: CGPoint(x: notch.minX - 6 * k, y: height))
    path.addQuadCurve(to: CGPoint(x: notch.minX, y: height - 6 * k), control: CGPoint(x: notch.minX, y: height))
    path.addLine(to: CGPoint(x: notch.minX, y: r))
    path.addQuadCurve(to: CGPoint(x: notch.minX + r, y: 0), control: CGPoint(x: notch.minX, y: 0))
    path.addLine(to: CGPoint(x: notch.maxX - r, y: 0))
    path.addQuadCurve(to: CGPoint(x: notch.maxX, y: r), control: CGPoint(x: notch.maxX, y: 0))
    path.addLine(to: CGPoint(x: notch.maxX, y: height - 6 * k))
    path.addQuadCurve(to: CGPoint(x: notch.maxX + 6 * k, y: height), control: CGPoint(x: notch.maxX, y: height))
    path.closeSubpath()
    ctx.setBlendMode(.copy)
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    let image = CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(scaleX: 1 / R, y: 1 / R))
    return image.transformed(by: CGAffineTransform(translationX: 0, y: canvas.height - height))
}
let menuBar = makeMenuBar()

/// La isla del notch tal como la pintó Faro (zona de arriba en el centro de la pantalla grabada),
/// colocada sobre el notch del lienzo sin zoom.
let islandSize = CGSize(width: 640, height: max(40, min(200, windowOrigin.y - 4)))
func island(_ raw: CIImage) -> CIImage? {
    guard screenCapture else { return nil }
    let rect = CGRect(x: captureWidth / 2 - islandSize.width / 2 * S, y: captureHeight - islandSize.height * S,
                      width: islandSize.width * S, height: islandSize.height * S)
    let a = k / S
    return raw.cropped(to: rect)
        .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        .transformed(by: CGAffineTransform(scaleX: a, y: a))
        .transformed(by: CGAffineTransform(translationX: (canvas.width - islandSize.width * k) / 2, y: canvas.height - islandSize.height * k))
}

/// Indicador de cámara rápida.
let fastImages: [Int: CGImage] = {
    var images: [Int: CGImage] = [:]
    for factor in Set(events.filter { $0.kind == "speed" && $0.scale > 1 }.map { Int($0.scale) }) {
        let f = font("InterDisplay-SemiBold", 20)
        let text = "×\(factor)"
        let size = CGSize(width: textWidth(text, f) + 62, height: 40)
        let ctx = makeContext(size)
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(rgb(0x0E1018, 0.8))
        ctx.fillPath()
        // Dos triángulos de avance rápido.
        for dx in [16.0, 28.0] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: dx, y: 12)); p.addLine(to: CGPoint(x: dx + 12, y: 20)); p.addLine(to: CGPoint(x: dx, y: 28)); p.closeSubpath()
            ctx.addPath(p)
        }
        ctx.setFillColor(rgb(0xFFFFFF, 0.9))
        ctx.fillPath()
        drawText(ctx, text, font: f, color: rgb(0xFFFFFF, 0.92), x: 48, baseline: 13)
        images[factor] = ctx.makeImage()
    }
    return images
}()

// MARK: Rótulos, teclas y cursor

struct Caption { let start: Double; let end: Double; let image: CGImage?; let width: CGFloat }
let captionEvents = events.filter { $0.kind == "caption" }
let captions: [Caption] = captionEvents.enumerated().map { i, e in
    let end = i + 1 < captionEvents.count ? captionEvents[i + 1].t : recordingDuration
    guard !e.title.isEmpty else { return Caption(start: e.t, end: end, image: nil, width: 0) }
    let titleFont = font("InterDisplay-SemiBold", 30), subFont = font("InterDisplay-Regular", 20)
    let width = max(textWidth(e.title, titleFont), textWidth(e.subtitle, subFont)) + 56
    let size = CGSize(width: width, height: 92)
    let ctx = makeContext(size)
    let rect = CGRect(origin: .zero, size: size)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(rgb(0x0E1018, 0.84))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(1)
    ctx.strokePath()
    drawText(ctx, e.title, font: titleFont, color: rgb(0xFFFFFF), x: (width - textWidth(e.title, titleFont)) / 2, baseline: 49)
    drawText(ctx, e.subtitle, font: subFont, color: rgb(0xFFFFFF, 0.66), x: (width - textWidth(e.subtitle, subFont)) / 2, baseline: 20)
    return Caption(start: e.t + 0.15, end: end, image: ctx.makeImage(), width: width)
}

let keyEvents = events.filter { $0.kind == "keys" }
var keyImages: [String: CGImage] = [:]
for e in keyEvents where keyImages[e.title] == nil {
    let f = font("InterDisplay-SemiBold", 26)
    let width = max(56, textWidth(e.title, f) + 32)
    let size = CGSize(width: width, height: 54)
    let ctx = makeContext(size)
    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.setFillColor(rgb(0x14161F, 0.9))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.2))
    ctx.setLineWidth(1)
    ctx.strokePath()
    drawText(ctx, e.title, font: f, color: rgb(0xFFFFFF, 0.92), x: (width - textWidth(e.title, f)) / 2, baseline: 18)
    keyImages[e.title] = ctx.makeImage()
}

/// Cursor de macOS (flecha blanca con borde negro y sombra), a 4× para que no pierda nitidez.
func makeCursor() -> CGImage {
    let scale: CGFloat = 4
    let ctx = CGContext(data: nil, width: Int(28 * scale), height: Int(36 * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 4, y: 34)
    ctx.scaleBy(x: 1, y: -1)
    let outer = CGMutablePath()
    for (i, p) in [(0, 0), (0, 21), (5, 16.5), (8.6, 24.5), (12, 23), (8.5, 15.4), (15, 15.4)].enumerated() {
        let point = CGPoint(x: p.0, y: p.1)
        if i == 0 { outer.move(to: point) } else { outer.addLine(to: point) }
    }
    outer.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: rgb(0x000000, 0.45))
    ctx.addPath(outer)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let inner = CGMutablePath()
    for (i, p) in [(1.6, 3.6), (1.6, 17.2), (5.4, 13.8), (9.3, 22.4), (10.1, 22.0), (6.2, 13.6), (11.4, 13.6)].enumerated() {
        let point = CGPoint(x: p.0, y: p.1)
        if i == 0 { inner.move(to: point) } else { inner.addLine(to: point) }
    }
    inner.closeSubpath()
    ctx.addPath(inner)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    return ctx.makeImage()!
}
let cursorImage = CIImage(cgImage: makeCursor())

// MARK: Marca: icono, «Faro» escrito letra a letra, haz del faro

let iconSize: CGFloat = 168
let wordFont = font("InterDisplay-SemiBold", 150)
let wordWidth = textWidth("Faro", wordFont)
let brandGap: CGFloat = 40
let brandWidth = iconSize + brandGap + wordWidth + 60
let iconRect = CGRect(x: (canvas.width - brandWidth) / 2, y: (canvas.height - iconSize) / 2, width: iconSize, height: iconSize)
let wordX = iconRect.maxX + brandGap
/// Línea base de «Faro» (origen arriba), centrada con el icono, y borde superior de su imagen.
let wordBaselineTL = iconRect.midY + 54
let wordTop = wordBaselineTL - 152

let iconCI: CIImage? = iconImage.map { img in
    let s = iconSize / CGFloat(img.width)
    return CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: s, y: s))
}
func iconAt(_ rect: CGRect, alpha: Double) -> CIImage? {
    guard let iconCI, let img = iconImage else { return nil }
    let s = rect.width / iconSize
    _ = img
    return withAlpha(iconCI.transformed(by: CGAffineTransform(scaleX: s, y: s))
        .transformed(by: CGAffineTransform(translationX: rect.minX, y: canvas.height - rect.maxY)), alpha)
}
/// «F», «Fa», «Far», «Faro» y el cursor de bloque ámbar.
let wordImages: [CGImage] = (1...4).map { n in
    let text = String("Faro".prefix(n))
    let size = CGSize(width: wordWidth + 80, height: 200)
    let ctx = makeContext(size)
    drawText(ctx, text, font: wordFont, color: rgb(0xFFFFFF), x: 0, baseline: 48)
    return ctx.makeImage()!
}
func wordCI(_ letters: Int, caret: Bool, alpha: Double) -> CIImage {
    var image = CIImage.empty()
    if letters > 0 { image = place(wordImages[min(letters, 4) - 1], x: wordX, y: wordTop, alpha: alpha) }
    if caret {
        let typed = letters > 0 ? textWidth(String("Faro".prefix(letters)), wordFont) : 0
        let caretTop = wordBaselineTL - 110
        let caretRect = CGRect(x: wordX + typed + 10, y: canvas.height - (caretTop + 116), width: 16, height: 116)
        let block = CIImage(color: CIColor(red: 0.95, green: 0.71, blue: 0.35, alpha: alpha)).cropped(to: caretRect)
        image = block.composited(over: image)
    }
    return image
}
/// Punto de donde sale la luz: el cursor ámbar del icono.
func beamOrigin(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * 0.61, y: rect.minY + rect.height * 0.70)
}
/// El haz: una cuña de luz que gira desde el icono y se apaga con la distancia.
func beam(origin: CGPoint, angle: Double, width: Double, intensity: Double) -> CIImage {
    let ctx = makeContext(canvas)
    let o = CGPoint(x: origin.x, y: canvas.height - origin.y)
    let reach: CGFloat = 2600
    for (spread, alpha) in [(width * 2.2, 0.12), (width * 1.2, 0.26), (width * 0.5, 0.34)] {
        ctx.saveGState()
        let path = CGMutablePath()
        path.move(to: o)
        path.addArc(center: o, radius: reach, startAngle: angle - spread / 2, endAngle: angle + spread / 2, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFFF4E2, alpha * intensity), rgb(0xFFE2B8, alpha * intensity * 0.5), rgb(0xFFE2B8, 0)] as CFArray,
                                  locations: [0, 0.4, 1])!
        ctx.drawRadialGradient(gradient, startCenter: o, startRadius: 0, endCenter: o, endRadius: reach, options: [])
        ctx.restoreGState()
    }
    // Resplandor en el foco.
    let glow = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFFD9A0, 0.75 * intensity), rgb(0xF2B45A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: o, startRadius: 0, endCenter: o, endRadius: 120, options: [])
    return CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(scaleX: 1 / R, y: 1 / R))
        .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5]).cropped(to: CGRect(origin: .zero, size: canvas))
}
/// Escritorio de noche, iluminado donde pasa el haz y cada vez más a medida que amanece.
func litBackground(beamImage: CIImage?, dawn: Double) -> CIImage {
    var mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(dawn))).cropped(to: CGRect(origin: .zero, size: canvas))
    if let beamImage {
        // Donde pasa la luz se ve el escritorio, sin pasar nunca de opaco.
        mask = beamImage.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.3)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .composited(over: mask)
    }
    let lit = wallpaper.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: night, kCIInputMaskImageKey: mask])
    guard let beamImage else { return lit }
    // Al sumar la luz la opacidad pasaría de 1 y dejaría ver lo de detrás.
    return beamImage.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lit])
        .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
}

// MARK: Avisos del cierre

struct Notice { let title: String; let body: String }
let notices = [
    Notice(title: "50 MB de memoria", body: "Con diez pestañas abiertas. Warp usa 235 MB con una."),
    Notice(title: "0 % de CPU en reposo", body: "Si no pasa nada, Faro no hace nada."),
    Notice(title: "Claude ha terminado", body: "Te avisa la isla del notch, sin mirar la terminal."),
    Notice(title: "Puerto :3000 liberado", body: "El servidor que alguien olvidó, cerrado de un clic."),
    Notice(title: "Sesión recuperada", body: "Pestañas, paneles y tus conversaciones de Claude."),
]
let noticeSize = CGSize(width: 520, height: 96)
let noticeImages: [CGImage] = notices.map { n in
    let ctx = makeContext(noticeSize)
    let rect = CGRect(origin: .zero, size: noticeSize)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(rgb(0x171922, 0.92))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.13))
    ctx.setLineWidth(1)
    ctx.strokePath()
    if let iconImage { ctx.draw(iconImage, in: CGRect(x: 16, y: (noticeSize.height - 52) / 2, width: 52, height: 52)) }
    drawText(ctx, "FARO", font: font("InterDisplay-Medium", 12), color: rgb(0xFFFFFF, 0.45), x: 84, baseline: 69)
    drawText(ctx, "ahora", font: font("InterDisplay-Regular", 13), color: rgb(0xFFFFFF, 0.38), x: noticeSize.width - 56, baseline: 69)
    drawText(ctx, n.title, font: font("InterDisplay-SemiBold", 19.5), color: rgb(0xFFFFFF), x: 84, baseline: 43)
    drawText(ctx, n.body, font: font("InterDisplay-Regular", 15.5), color: rgb(0xFFFFFF, 0.68), x: 84, baseline: 19)
    return ctx.makeImage()!
}

// MARK: Grabación

let asset = AVURLAsset(url: input.appendingPathComponent("raw.mov"))
let track = try await asset.loadTracks(withMediaType: .video).first!
let reader = try AVAssetReader(asset: asset)
let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
readerOutput.alwaysCopiesSampleData = false
reader.add(readerOutput)
reader.startReading()
var currentFrame: CIImage?
var nextSample: CMSampleBuffer? = readerOutput.copyNextSampleBuffer()
func sourceFrame(at t: Double) -> CIImage? {
    while let sample = nextSample, CMSampleBufferGetPresentationTimeStamp(sample).seconds <= t {
        if let buffer = CMSampleBufferGetImageBuffer(sample) { currentFrame = CIImage(cvPixelBuffer: buffer) }
        nextSample = readerOutput.copyNextSampleBuffer()
    }
    if currentFrame == nil, let sample = nextSample, let buffer = CMSampleBufferGetImageBuffer(sample) {
        currentFrame = CIImage(cvPixelBuffer: buffer)
    }
    return currentFrame
}
let sourceSize = CGSize(width: W * S, height: H * S)
let windowMask: CIImage = {
    let ctx = CGContext(data: nil, width: Int(sourceSize.width), height: Int(sourceSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: sourceSize), cornerWidth: 10 * S, cornerHeight: 10 * S, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    return CIImage(cgImage: ctx.makeImage()!)
}()
/// La ventana de la grabación, con el origen en su esquina.
func windowPart(_ raw: CIImage) -> CIImage {
    guard screenCapture else { return raw }
    let rect = CGRect(x: windowOrigin.x * S, y: captureHeight - (windowOrigin.y + H) * S, width: W * S, height: H * S)
    return raw.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
}
func maskedWindow(_ frame: CIImage) -> CIImage {
    windowPart(frame).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: windowMask])
}

/// Transformación de la ventana para la cámara.
func windowTransform(_ cam: Camera) -> CGAffineTransform {
    let a = k * cam.zoom / S
    return CGAffineTransform(a: a, b: 0, c: 0, d: a, tx: stageCenter.x - cam.cx * k * cam.zoom,
                             ty: canvas.height - (stageCenter.y + (H - cam.cy) * k * cam.zoom))
}
/// Transformación del fondo y la sombra (lienzo sin zoom → lienzo con la cámara).
func stageTransform(_ cam: Camera) -> CGAffineTransform {
    let z = cam.zoom
    return CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: stageCenter.x - z * (windowCanvas.minX + cam.cx * k),
                             ty: canvas.height - canvas.height * z - stageCenter.y + z * (windowCanvas.minY + cam.cy * k))
}
/// La ventana encogida dentro de un rectángulo (para la entrada y el cierre).
func windowInRect(_ frame: CIImage, rect: CGRect) -> CIImage {
    let a = rect.width / sourceSize.width
    return maskedWindow(frame).transformed(by: CGAffineTransform(a: a, b: 0, c: 0, d: a, tx: rect.minX, ty: canvas.height - rect.maxY))
}
func shadowInRect(_ rect: CGRect) -> CIImage {
    let s = rect.width / windowCanvas.width
    return shadowImage.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                         tx: rect.minX - windowCanvas.minX * s,
                                                         ty: (canvas.height - rect.maxY) - (canvas.height - windowCanvas.maxY) * s))
}

/// La escena grabada en el instante `t` (sin rótulos si `chrome` es false).
func scene(at t: Double, overlays: Bool = true) -> CIImage {
    let cam = camera(at: t)
    let stage = stageTransform(cam)
    var image = shadowImage.transformed(by: stage).composited(over: menuBar.transformed(by: stage).composited(over: wallpaper.transformed(by: stage)))
    if let frame = sourceFrame(at: t) {
        image = maskedWindow(frame).transformed(by: windowTransform(cam)).composited(over: image)
        if let island = island(frame) { image = island.transformed(by: stage).composited(over: image) }
    }
    for click in clicks where t >= click.t && t < click.t + 0.5 {
        let p = (t - click.t) / 0.5
        let center = toCanvas(click.x, click.y, cam)
        let radius = (6 + 22 * easeInOut(p)) * k * cam.zoom
        let ring = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: canvas.height - center.y),
            "inputRadius0": radius * 0.62, "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.55 * (1 - p)),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])!.outputImage!.cropped(to: CGRect(x: center.x - radius, y: canvas.height - center.y - radius, width: radius * 2, height: radius * 2))
        image = ring.composited(over: image)
    }
    if overlays {
        let position = cursor(at: t)
        var press = 1.0
        for click in clicks where t >= click.t - 0.05 && t < click.t + 0.25 { press = 0.86 }
        let cs = k * min(cam.zoom, 1.6) * 0.9 * press / 4
        let tip = toCanvas(position.x, position.y, cam)
        let cursorAlpha = clamp01(t / 0.5)
        image = withAlpha(cursorImage, cursorAlpha).transformed(by: CGAffineTransform(a: cs, b: 0, c: 0, d: cs,
                                                                                     tx: tip.x - 4 * 4 * cs,
                                                                                     ty: canvas.height - tip.y - (36 - 2) * 4 * cs)).composited(over: image)
        for e in keyEvents where t >= e.t && t < e.t + 1.0 {
            guard let cg = keyImages[e.title] else { continue }
            let alpha = min(1, (t - e.t) / 0.12, (e.t + 1.0 - t) / 0.25)
            image = place(cg, x: canvas.width - CGFloat(cg.width) / R - 56, y: canvas.height - 100, alpha: alpha).composited(over: image)
        }
        let factor = Int(speedFactor(at: t))
        if factor > 1, let cg = fastImages[factor] {
            image = place(cg, x: canvas.width - CGFloat(cg.width) / R - 40, y: 66).composited(over: image)
        }
        for caption in captions where t >= caption.start && t < caption.end {
            guard let cg = caption.image else { continue }
            let alpha = min(1, (t - caption.start) / 0.3, (caption.end - t) / 0.3)
            let rise = (1 - easeOut((t - caption.start) / 0.4)) * 10
            image = place(cg, x: (canvas.width - caption.width) / 2, y: canvas.height - 120 + rise, alpha: alpha).composited(over: image)
        }
    }
    return image
}

// MARK: Entrada y cierre

/// Entrada: de noche, el icono se enciende, el haz del faro barre el escritorio, «Faro» se
/// escribe con su cursor y el icono se despliega hasta convertirse en la ventana.
func intro(at t: Double) -> CIImage {
    let iconIn = spring((t - 0.15) / 0.9)
    let sweep = easeInOut((t - 0.35) / 2.3)
    let unfold = easeInOut((t - 2.65) / 1.15)
    let angle = Double.pi * (1.15 - 2.25 * sweep)
    let intensity = clamp01((t - 0.3) / 0.5) * (1 - unfold)
    let beamImage = intensity > 0.01 ? beam(origin: beamOrigin(iconRect), angle: angle, width: 0.34, intensity: intensity) : nil
    var image = litBackground(beamImage: beamImage, dawn: easeInOut((t - 1.9) / 1.6))

    // Icono: aparece con un pequeño rebote y se encoge al desplegarse.
    let iconScale = (0.55 + 0.45 * iconIn) * (1 - 0.35 * unfold)
    let center = CGPoint(x: iconRect.midX + (canvas.width / 2 - iconRect.midX) * unfold, y: iconRect.midY + (windowCanvas.midY - iconRect.midY) * unfold)
    let rect = CGRect(x: center.x - iconSize * iconScale / 2, y: center.y - iconSize * iconScale / 2, width: iconSize * iconScale, height: iconSize * iconScale)

    // «Faro» letra a letra con el cursor de bloque parpadeando.
    let letters = Int(clamp01((t - 1.05) / 0.62) * 4.999)
    let caretOn = t < 1.05 || t > 1.67 ? Int(t / 0.42) % 2 == 0 : true
    let wordAlpha = clamp01((t - 0.95) / 0.15) * (1 - easeInOut((t - 2.55) / 0.45))
    image = wordCI(letters, caret: caretOn && wordAlpha > 0.05, alpha: wordAlpha).composited(over: image)

    if unfold > 0 { image = withAlpha(menuBar, unfold).composited(over: image) }
    // La ventana crece desde el icono.
    if unfold > 0, let frame = sourceFrame(at: 0) {
        let w = rect.width + (windowCanvas.width - rect.width) * unfold
        let h = w * H / W
        let windowRect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let alpha = clamp01(unfold / 0.35)
        image = withAlpha(shadowInRect(windowRect), alpha).composited(over: image)
        image = withAlpha(windowInRect(frame, rect: windowRect), alpha).composited(over: image)
    }
    if let icon = iconAt(rect, alpha: clamp01((t - 0.1) / 0.25) * (1 - clamp01(unfold / 0.45))) { image = icon.composited(over: image) }
    return image.cropped(to: CGRect(origin: .zero, size: canvas))
}

/// Cierre: llegan avisos con lo que importa, la ventana se recoge en el icono y vuelve el faro.
func outro(at t: Double) -> CIImage {
    let last = recordingDuration
    // Fondo: la última escena, desenfocada y algo más oscura mientras llegan los avisos.
    let focus = easeInOut(t / 0.8) * (1 - easeInOut((t - 4.4) / 0.6))
    var base = scene(at: last, overlays: false)
    if focus > 0.01 {
        base = base.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9 * focus])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.7 * focus])
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }
    var image = base

    // Avisos: entran desde la derecha con un rebote y se apilan.
    let start = 0.5, step = 0.62
    let leave = easeInOut((t - 4.6) / 0.55)
    for (i, notice) in noticeImages.enumerated() {
        let appear = t - (start + Double(i) * step)
        guard appear > 0 else { continue }
        let slide = spring(appear / 0.75)
        let x = canvas.width - noticeSize.width - 34 + (1 - slide) * (noticeSize.width + 60)
        let y = 30 + CGFloat(i) * (noticeSize.height + 12) - leave * (200 + CGFloat(i) * 40)
        let alpha = clamp01(appear / 0.2) * (1 - leave)
        image = place(notice, x: x, y: y, alpha: alpha).composited(over: image)
    }

    // La ventana vuelve al icono y el faro barre una última vez.
    let fold = easeInOut((t - 5.0) / 1.1)
    if fold > 0 {
        let night = easeInOut((t - 5.2) / 1.2)
        let sweep = easeInOut((t - 5.7) / 2.2)
        let intensity = clamp01((t - 5.6) / 0.4) * (1 - clamp01((t - 7.6) / 0.6))
        let beamImage = intensity > 0.01 ? beam(origin: beamOrigin(iconRect), angle: Double.pi * (-0.2 + 1.6 * sweep), width: 0.34, intensity: intensity) : nil
        var stage = litBackground(beamImage: beamImage, dawn: 1 - night * 0.85)
        stage = withAlpha(menuBar, 1 - fold).composited(over: stage)
        let iconScale = 0.65 + 0.35 * fold
        let center = CGPoint(x: canvas.width / 2 + (iconRect.midX - canvas.width / 2) * fold, y: windowCanvas.midY + (iconRect.midY - windowCanvas.midY) * fold)
        let iconW = iconSize * iconScale
        if fold < 1, let frame = sourceFrame(at: last) {
            let w = windowCanvas.width + (iconW - windowCanvas.width) * fold
            let h = w * H / W
            let windowRect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            let alpha = 1 - clamp01((fold - 0.6) / 0.4)
            stage = withAlpha(shadowInRect(windowRect), alpha).composited(over: stage)
            stage = withAlpha(windowInRect(frame, rect: windowRect), alpha).composited(over: stage)
        }
        let rect = CGRect(x: center.x - iconW / 2, y: center.y - iconW / 2, width: iconW, height: iconW)
        if let icon = iconAt(rect, alpha: clamp01((fold - 0.55) / 0.35)) { stage = icon.composited(over: stage) }
        let letters = Int(clamp01((t - 6.2) / 0.55) * 4.999)
        let caretOn = Int(t / 0.42) % 2 == 0 || (t > 6.2 && t < 6.75)
        let wordAlpha = clamp01((t - 6.1) / 0.15)
        stage = wordCI(letters, caret: caretOn && wordAlpha > 0.05, alpha: wordAlpha).composited(over: stage)
        image = stage
    }
    // Fundido a negro al final.
    let fade = clamp01((t - (outroDuration - 0.7)) / 0.7)
    if fade > 0 { image = withAlpha(CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas)), fade).composited(over: image) }
    return image.cropped(to: CGRect(origin: .zero, size: canvas))
}

// MARK: Escritura

try? FileManager.default.removeItem(at: outputURL)
let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(outSize.width),
    AVVideoHeightKey: Int(outSize.height),
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Int(18_000_000 * R * R / 1.78),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: 60,
        AVVideoMaxKeyFrameIntervalKey: 120,
        AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
    ],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
videoInput.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(outSize.width),
    kCVPixelBufferHeightKey as String: Int(outSize.height),
])
writer.add(videoInput)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let ciContext = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
let outRect = CGRect(origin: .zero, size: outSize)
let frameCount = Int(total * fps)
let started = Date()
var written = 0
let crossfade = 0.0
for i in 0..<frameCount {
    let t = Double(i) / fps
    var image: CIImage
    if t < introDuration {
        image = intro(at: t)
    } else if t < introDuration + recordingOut {
        image = scene(at: recordingTime(t - introDuration))
    } else {
        image = outro(at: t - introDuration - recordingOut)
    }
    // Entrada de la escena: el cursor y los rótulos aparecen poco a poco al terminar el despliegue.
    image = image.transformed(by: CGAffineTransform(scaleX: R, y: R)).cropped(to: outRect)
    while !videoInput.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { continue }
    ciContext.render(image, to: buffer, bounds: outRect, colorSpace: colorSpace)
    if adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 60)) { written += 1 }
    if i % 900 == 0 { print("\(i)/\(frameCount) fotogramas") }
}
_ = crossfade
videoInput.markAsFinished()
await writer.finishWriting()
print("listo: \(written) fotogramas, \(String(format: "%.1f", total)) s, \(Int(outSize.width))×\(Int(outSize.height)) en \(Int(Date().timeIntervalSince(started))) s → \(outputURL.path) estado=\(writer.status.rawValue) \(writer.error.map { "\($0)" } ?? "")")
