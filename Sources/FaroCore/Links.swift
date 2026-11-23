import Foundation

/// A dónde lleva un enlace de la salida del terminal (⌘+clic).
public enum LinkTarget: Equatable, Sendable {
    /// http, https, mailto…
    case web(URL)
    /// Un archivo, con la línea y la columna si las trae (`src/app/page.tsx:42:7`).
    case file(path: String, line: Int?, column: Int?)
    case directory(String)
    /// Otro esquema (`slack://…`): lo abre SwiftTerm, que pide confirmación.
    case other(String)

    static let webSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// Interpreta el texto del enlace. Las rutas relativas se buscan en `directory` y luego
    /// en `roots` (por ejemplo la raíz del proyecto).
    public static func resolve(_ raw: String, directory: String, roots: [String] = [],
                               exists: (String) -> (exists: Bool, isDirectory: Bool) = LinkTarget.fileExists) -> LinkTarget? {
        var link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        link = String(link.drop { "([{<'\"`".contains($0) })
        while let last = link.last, ".,;)]}>'\"`".contains(last) {
            // Un «)» que cierra un «(» del propio enlace (`a.ts(12,3)`) se queda.
            if last == ")" && link.filter({ $0 == "(" }).count >= link.filter({ $0 == ")" }).count { break }
            link.removeLast()
        }
        guard !link.isEmpty else { return nil }

        if let scheme = scheme(of: link) {
            if scheme == "file", let url = URL(string: link) {
                var line: Int?
                if let fragment = url.fragment, fragment.hasPrefix("L") { line = Int(fragment.dropFirst().prefix { $0.isNumber }) }
                return locate(url.path, line: line, column: nil, directory: directory, roots: [], exists: exists)
            }
            if webSchemes.contains(scheme), let url = URL(string: link) { return .web(url) }
            return .other(link)
        }
        if link.range(of: #"^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil,
           let url = URL(string: "http://" + link) {
            return .web(url)
        }
        if link.range(of: #"^www\.[^\s/]+\.[a-z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let url = URL(string: "https://" + link) {
            return .web(url)
        }

        let (path, line, column) = splitLocation(link)
        return locate(path, line: line, column: column, directory: directory, roots: roots, exists: exists)
    }

    /// `a.swift:12:4` → (a.swift, 12, 4); `a.swift(12,4)` → igual; `a.swift#L12` → (a.swift, 12, nil).
    static func splitLocation(_ link: String) -> (String, Int?, Int?) {
        let patterns = [#"^(.+?):(\d+)(?::(\d+))?:?$"#, #"^(.+?)\((\d+)(?:,\s*(\d+))?\)$"#, #"^(.+?)#L(\d+)(?:C(\d+))?$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)) else { continue }
            func group(_ i: Int) -> String? {
                Range(match.range(at: i), in: link).map { String(link[$0]) }
            }
            if let path = group(1) { return (path, group(2).flatMap(Int.init), group(3).flatMap(Int.init)) }
        }
        return (link, nil, nil)
    }

    private static func locate(_ path: String, line: Int?, column: Int?, directory: String, roots: [String],
                               exists: (String) -> (exists: Bool, isDirectory: Bool)) -> LinkTarget? {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates: [String]
        if expanded.hasPrefix("/") {
            candidates = [expanded]
        } else {
            var bases = [directory] + roots
            // `a/b/c.swift` de un diff de git (`a/` y `b/`): prueba también sin ese prefijo.
            var names = [expanded]
            if expanded.hasPrefix("a/") || expanded.hasPrefix("b/") { names.append(String(expanded.dropFirst(2))) }
            bases = bases.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            candidates = bases.flatMap { base in names.map { ((base as NSString).appendingPathComponent($0) as NSString).standardizingPath } }
        }
        for candidate in candidates {
            let info = exists(candidate)
            guard info.exists else { continue }
            return info.isDirectory ? .directory(candidate) : .file(path: candidate, line: line, column: column)
        }
        return nil
    }

    static func scheme(of link: String) -> String? {
        guard let range = link.range(of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*:"#, options: .regularExpression) else { return nil }
        let scheme = link[range].dropLast().lowercased()
        // «main.swift:12» no es un esquema; «mailto:x@y» sí.
        let rest = link[range.upperBound...]
        if rest.hasPrefix("//") || webSchemes.contains(scheme) || scheme == "file" { return scheme }
        if rest.first?.isNumber == true || scheme.contains(".") { return nil }
        return rest.isEmpty ? nil : scheme
    }

    public static func fileExists(_ path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return (exists, isDir.boolValue)
    }
}

/// Editores de código a los que Faro sabe mandar un archivo en una línea concreta.
public enum CodeEditor: String, CaseIterable, Codable, Sendable, Identifiable {
    case cursor, vscode, zed, antigravity, windsurf, xcode, sublime

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .cursor: "Cursor"
        case .vscode: "Visual Studio Code"
        case .zed: "Zed"
        case .antigravity: "Antigravity"
        case .windsurf: "Windsurf"
        case .xcode: "Xcode"
        case .sublime: "Sublime Text"
        }
    }

    public var bundleID: String {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .vscode: "com.microsoft.VSCode"
        case .zed: "dev.zed.Zed"
        case .antigravity: "com.google.antigravity"
        case .windsurf: "com.exafunction.windsurf"
        case .xcode: "com.apple.dt.Xcode"
        case .sublime: "com.sublimetext.4"
        }
    }

    /// Programa de línea de comandos dentro de la app y sus argumentos para abrir en una línea.
    /// Es lo más fiable: abre directamente el archivo, sin el aviso de seguridad que muestran
    /// algunos editores con los enlaces `cursor://`.
    public func command(path: String, line: Int?, column: Int?) -> (relativePath: String, arguments: [String])? {
        var location = path
        if let line {
            location += ":\(line)"
            if let column { location += ":\(column)" }
        }
        switch self {
        case .cursor: return ("Contents/Resources/app/bin/cursor", ["--goto", location])
        case .vscode: return ("Contents/Resources/app/bin/code", ["--goto", location])
        case .windsurf: return ("Contents/Resources/app/bin/windsurf", ["--goto", location])
        case .zed: return ("Contents/MacOS/cli", [location])
        case .sublime: return ("Contents/SharedSupport/bin/subl", [location])
        case .antigravity, .xcode: return nil
        }
    }

    /// `cursor://file/Users/me/app/page.tsx:42:7`
    public func url(path: String, line: Int?, column: Int?) -> URL? {
        let scheme: String
        switch self {
        case .cursor: scheme = "cursor"
        case .vscode: scheme = "vscode"
        case .zed: scheme = "zed"
        case .antigravity: scheme = "antigravity"
        case .windsurf: scheme = "windsurf"
        case .sublime: scheme = "subl"
        case .xcode: return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        if self == .sublime {
            components.host = "open"
            var items = [URLQueryItem(name: "url", value: URL(fileURLWithPath: path).absoluteString)]
            if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
            if let column { items.append(URLQueryItem(name: "column", value: String(column))) }
            components.queryItems = items
            return components.url
        }
        components.host = "file"
        var location = path
        if let line {
            location += ":\(line)"
            if let column { location += ":\(column)" }
        }
        components.path = location
        return components.url
    }
}
