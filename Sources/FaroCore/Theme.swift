import Foundation

public struct Theme: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let background: String
    public let foreground: String
    public let cursor: String
    public let selection: String
    /// Color de acento para la interfaz (pestaña activa, ruta, botones).
    public let accent: String
    /// 8 colores normales + 8 brillantes.
    public let ansi: [String]

    public init(id: String, name: String, isDark: Bool, background: String, foreground: String,
                cursor: String, selection: String, accent: String, ansi: [String]) {
        precondition(ansi.count == 16)
        self.id = id; self.name = name; self.isDark = isDark
        self.background = background; self.foreground = foreground
        self.cursor = cursor; self.selection = selection; self.accent = accent; self.ansi = ansi
    }

    public static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? faroNoche
    }

    public static let faroNoche = Theme(
        id: "faro-noche", name: "Faro Noche", isDark: true,
        background: "#12131C", foreground: "#D5D8EA", cursor: "#F2B45A", selection: "#2A3150", accent: "#F2B45A",
        ansi: ["#1B1D2A", "#F2667A", "#8FD694", "#F2B45A", "#6FA3FF", "#B892FF", "#66D9E8", "#C8CCE0",
               "#4A4F6A", "#FF8597", "#A8F0AD", "#FFCB7D", "#93BBFF", "#CDB0FF", "#8CEBF5", "#F2F3FA"])

    public static let faroDia = Theme(
        id: "faro-dia", name: "Faro Día", isDark: false,
        background: "#FBF8F2", foreground: "#2B2A33", cursor: "#D9822B", selection: "#EADFC6", accent: "#D9822B",
        ansi: ["#2B2A33", "#C8364A", "#2E8B57", "#B7791F", "#2F6FD6", "#8A4FD6", "#1F8A9E", "#8C8A93",
               "#6B6A75", "#E0485D", "#3AA56A", "#D08F2A", "#4A86EA", "#A06BE6", "#2AA3B8", "#B8B5AE"])

    public static let all: [Theme] = [
        faroNoche, faroDia,
        Theme(id: "tokyo-night", name: "Tokyo Night", isDark: true,
              background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5", selection: "#33467C", accent: "#7AA2F7",
              ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                     "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]),
        Theme(id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
              background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC", selection: "#45475A", accent: "#CBA6F7",
              ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                     "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]),
        Theme(id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
              background: "#EFF1F5", foreground: "#4C4F69", cursor: "#DC8A78", selection: "#CCD0DA", accent: "#8839EF",
              ansi: ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
                     "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"]),
        Theme(id: "dracula", name: "Dracula", isDark: true,
              background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A", accent: "#BD93F9",
              ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                     "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        Theme(id: "nord", name: "Nord", isDark: true,
              background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E", accent: "#88C0D0",
              ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                     "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        Theme(id: "gruvbox-dark", name: "Gruvbox", isDark: true,
              background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945", accent: "#FABD2F",
              ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                     "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
        Theme(id: "one-dark", name: "One Dark", isDark: true,
              background: "#282C34", foreground: "#ABB2BF", cursor: "#528BFF", selection: "#3E4451", accent: "#61AFEF",
              ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                     "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"]),
        Theme(id: "rose-pine", name: "Rosé Pine", isDark: true,
              background: "#191724", foreground: "#E0DEF4", cursor: "#EBBCBA", selection: "#403D52", accent: "#EBBCBA",
              ansi: ["#26233A", "#EB6F92", "#31748F", "#F6C177", "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
                     "#6E6A86", "#EB6F92", "#31748F", "#F6C177", "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4"]),
        Theme(id: "github-dark", name: "GitHub Dark", isDark: true,
              background: "#0D1117", foreground: "#E6EDF3", cursor: "#2F81F7", selection: "#264F78", accent: "#2F81F7",
              ansi: ["#484F58", "#FF7B72", "#3FB950", "#D29922", "#58A6FF", "#BC8CFF", "#39C5CF", "#B1BAC4",
                     "#6E7681", "#FFA198", "#56D364", "#E3B341", "#79C0FF", "#D2A8FF", "#56D4DD", "#FFFFFF"]),
        Theme(id: "solarized-light", name: "Solarized Light", isDark: false,
              background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5", accent: "#268BD2",
              ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                     "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
    ]
}

public struct RGB: Sendable, Equatable {
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = Int(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    public func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
}
