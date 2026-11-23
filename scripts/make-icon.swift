// Genera el icono de Faro (1024×1024 PNG).
// Uso: swift scripts/make-icon.swift salida.png
//
// Placa blanca con la forma estándar de macOS y, dentro, la ventana de Faro: oscura, con
// esquinas pequeñas, su pestaña, una pestaña ámbar (la luz del faro), el «›» plegado en dos
// tonos y el cursor «_» en ámbar.
import AppKit

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
             blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func shadowed(_ color: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: -y)   // contexto girado: y positiva = hacia abajo
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Pastilla de longitud `length` y grosor `thickness`, centrada y girada `angle` grados.
func pill(center: NSPoint, length: CGFloat, thickness: CGFloat, angle: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: NSRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness),
                            xRadius: thickness / 2, yRadius: thickness / 2)
    var t = AffineTransform()
    t.translate(x: center.x, y: center.y)
    t.rotate(byDegrees: angle)
    path.transform(using: t)
    return path
}

let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
    // Placa (forma estándar de macOS): blanco roto con un degradado muy leve.
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    shadowed(hex(0x000000, 0.22), blur: 22, y: 10) { hex(0xF3F3F5).setFill(); plate.fill() }
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(starting: hex(0xFFFFFF), ending: hex(0xE4E5EA))!.draw(in: plate, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let radius: CGFloat = 34

    // Pestaña ámbar, detrás de la ventana.
    let amber = NSBezierPath(roundedRect: NSRect(x: 486, y: 236, width: 226, height: 100), xRadius: 26, yRadius: 26)
    NSGradient(starting: hex(0xFFC870), ending: hex(0xE8962E))!.draw(in: amber, angle: 90)

    // Ventana: cuerpo + pestaña activa, un solo color.
    let body = NSBezierPath(roundedRect: NSRect(x: 172, y: 300, width: 680, height: 520), xRadius: radius, yRadius: radius)
    let tab = NSBezierPath(roundedRect: NSRect(x: 172, y: 222, width: 300, height: 140), xRadius: radius, yRadius: radius)
    let window = NSBezierPath()
    window.append(body)
    window.append(tab)
    window.windingRule = .nonZero
    shadowed(hex(0x0B0C14, 0.45), blur: 34, y: 20) { hex(0x161824).setFill(); window.fill() }
    NSGraphicsContext.saveGraphicsState()
    window.addClip()
    NSGradient(starting: hex(0x262A3B), ending: hex(0x11121A))!.draw(in: NSRect(x: 172, y: 222, width: 680, height: 598), angle: 90)
    // Sombra de la pestaña activa sobre la ámbar (pliegue, como en una carpeta).
    NSGradient(starting: hex(0x000000, 0.35), ending: hex(0x000000, 0))!
        .draw(in: NSRect(x: 472, y: 236, width: 40, height: 64), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    // Brillo fino en el borde superior de la pestaña y del cuerpo, como luz cenital.
    NSGraphicsContext.saveGraphicsState()
    window.addClip()
    hex(0xFFFFFF, 0.10).setFill()
    NSRect(x: 172 + radius, y: 222, width: 300 - 2 * radius, height: 2).fill()
    NSRect(x: 472, y: 300, width: 380 - radius, height: 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    // «›» plegado: el brazo de abajo, más apagado, queda bajo la sombra del de arriba.
    let vertex = NSPoint(x: 492, y: 540)
    let reach: CGFloat = 138
    let thickness: CGFloat = 90
    let armLength = reach * sqrt(2) + thickness
    let lower = pill(center: NSPoint(x: vertex.x - reach / 2, y: vertex.y + reach / 2), length: armLength, thickness: thickness, angle: -45)
    let upper = pill(center: NSPoint(x: vertex.x - reach / 2, y: vertex.y - reach / 2), length: armLength, thickness: thickness, angle: 45)
    shadowed(hex(0x000000, 0.4), blur: 20, y: 10) { hex(0xB9BFD3).setFill(); lower.fill() }
    NSGraphicsContext.saveGraphicsState()
    lower.addClip()
    NSGradient(starting: hex(0xD4D8E6), ending: hex(0xA9B0C7))!.draw(in: lower, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    shadowed(hex(0x000000, 0.55), blur: 26, y: 14) { hex(0xFFFFFF).setFill(); upper.fill() }

    // Cursor «_» en ámbar, con un halo suave: la luz del faro.
    let cursor = NSBezierPath(roundedRect: NSRect(x: 560, y: 682, width: 196, height: 74), xRadius: 26, yRadius: 26)
    shadowed(hex(0xF2A33A, 0.55), blur: 40, y: 0) { hex(0xF2B45A).setFill(); cursor.fill() }
    NSGraphicsContext.saveGraphicsState()
    cursor.addClip()
    NSGradient(starting: hex(0xFFD27F), ending: hex(0xEE9A2E))!.draw(in: cursor, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Icono: \(out)")
