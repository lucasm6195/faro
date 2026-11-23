import AppKit
import CoreText
import FaroCore
import SwiftTerm
import SwiftUI

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: SwiftUI.Color { SwiftUI.Color(.sRGB, red: r, green: g, blue: b) }
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(r * 255), green8: UInt16(g * 255), blue8: UInt16(b * 255))
    }
}

/// Colores de la interfaz derivados del tema. La interfaz usa el mismo fondo que el terminal:
/// sin barras de otro color ni líneas, todo es una sola superficie.
struct Palette: Equatable {
    static func == (a: Palette, b: Palette) -> Bool { a.theme == b.theme }

    let theme: Theme
    let background: SwiftUI.Color
    let raised: SwiftUI.Color
    let hover: SwiftUI.Color
    let hairline: SwiftUI.Color
    let text: SwiftUI.Color
    let secondaryText: SwiftUI.Color
    let tertiaryText: SwiftUI.Color
    let accent: SwiftUI.Color
    let success: SwiftUI.Color
    let failure: SwiftUI.Color
    let nsBackground: NSColor
    let nsHairline: NSColor

    init(_ theme: Theme) {
        self.theme = theme
        let bg = RGB(hex: theme.background)
        let fg = RGB(hex: theme.foreground)
        background = bg.color
        nsBackground = bg.nsColor
        raised = bg.mixed(with: fg, theme.isDark ? 0.055 : 0.045).color
        hover = bg.mixed(with: fg, theme.isDark ? 0.08 : 0.07).color
        let line = bg.mixed(with: fg, theme.isDark ? 0.14 : 0.16)
        hairline = line.color
        nsHairline = line.nsColor
        text = fg.color
        secondaryText = bg.mixed(with: fg, 0.6).color
        tertiaryText = bg.mixed(with: fg, 0.38).color
        accent = RGB(hex: theme.accent).color
        success = RGB(hex: theme.ansi[2]).color
        failure = RGB(hex: theme.ansi[1]).color
    }
}

/// Tipografías incluidas en la app (Inter Display, Geist Mono y JetBrains Mono, licencia OFL).
enum Fonts {
    static let bundled = ["Geist Mono", "JetBrains Mono"]
    static let defaultTerminal = "Geist Mono"

    /// Las registra solo para este proceso: no se instala nada en el sistema.
    static func registerBundled() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let fonts = files.filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    static func terminal(name: String, size: Double) -> NSFont {
        if name == "system" { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        let family = name.isEmpty ? defaultTerminal : name
        if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return f }
        if let f = NSFont(name: family, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func monospacedFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard !bundled.contains(family), let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
        }
        return names.sorted()
    }
}

extension Font {
    /// Inter Display, la tipografía de la interfaz. Si faltara, la del sistema.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .semibold, .bold, .heavy, .black: "InterDisplay-SemiBold"
        case .medium: "InterDisplay-Medium"
        default: "InterDisplay-Regular"
        }
        return NSFont(name: name, size: size) != nil ? .custom(name, fixedSize: size) : .system(size: size, weight: weight)
    }

    static func code(_ size: CGFloat) -> Font {
        .custom(Fonts.defaultTerminal, fixedSize: size)
    }
}

/// Logos de las herramientas de IA, en SVG (de svgl.app), cargados una sola vez.
@MainActor
enum Logos {
    private static var cache: [String: NSImage] = [:]

    static func image(_ agent: AIAgent, dark: Bool) -> NSImage? {
        let file = dark ? agent.logo.dark : agent.logo.light
        if let cached = cache[file] { return cached }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Logos/\(file).svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[file] = image
        return image
    }
}

struct AgentLogo: View {
    let agent: AIAgent
    var size: CGFloat = 13
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = Logos.image(agent, dark: colorScheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle").font(.system(size: size * 0.85))
        }
    }
}

/// Programas disponibles en el PATH, para completar el nombre del comando.
enum Executables {
    static func scan(path: String) -> [String] {
        var names = Set<String>()
        let fm = FileManager.default
        for dir in path.split(separator: ":").map(String.init) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where !item.hasPrefix(".") && fm.isExecutableFile(atPath: dir + "/" + item) {
                names.insert(item)
            }
        }
        return Array(names)
    }

    /// PATH de una shell de login: al abrir desde el Finder la app solo recibe el PATH mínimo.
    static func loginPath() async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", "print -rn -- $PATH"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    cont.resume(returning: path.isEmpty ? (ProcessInfo.processInfo.environment["PATH"] ?? "") : path)
                } catch {
                    cont.resume(returning: ProcessInfo.processInfo.environment["PATH"] ?? "")
                }
            }
        }
    }
}
