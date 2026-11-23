import AppKit
import FaroCore
import UniformTypeIdentifiers

/// Abre los archivos de ⌘+clic en tu editor, en la línea que indica el enlace.
@MainActor
enum Editors {
    /// Orden de preferencia cuando no has elegido ninguno en Ajustes.
    static let order: [CodeEditor] = [.vscode, .cursor, .zed, .antigravity, .windsurf, .sublime, .xcode]

    static var installed: [CodeEditor] {
        order.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// El elegido en Ajustes, o el primero instalado. Nil = la app por defecto de cada archivo.
    static var preferred: CodeEditor? {
        let choice = AppModel.shared.settings.editor
        if choice == "system" { return nil }
        if let editor = CodeEditor(rawValue: choice), installed.contains(editor) { return editor }
        return installed.first
    }

    /// Nombre corto para menús: «VS Code», «Cursor»…
    static func shortName(_ editor: CodeEditor) -> String { editor == .vscode ? "VS Code" : editor.name }

    static func icon(_ editor: CodeEditor, size: CGFloat = 16) -> NSImage? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: size, height: size)
        return image
    }

    static func choose(_ editor: CodeEditor?) {
        AppModel.shared.settings.editor = editor?.rawValue ?? "system"
    }

    /// Abre una carpeta entera en el editor (como `code .`).
    static func openFolder(_ path: String) {
        let folder = URL(fileURLWithPath: path)
        guard let editor = preferred, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else {
            NSWorkspace.shared.open(folder)
            return
        }
        if editor == .xcode {
            launch(URL(fileURLWithPath: "/usr/bin/xed"), [path])
            return
        }
        if let (relative, _) = editor.command(path: path, line: nil, column: nil) {
            let cli = app.appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: cli.path), launch(cli, [path]) { return }
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @discardableResult
    private static func launch(_ executable: URL, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    static func open(path: String, line: Int?, column: Int?) {
        let file = URL(fileURLWithPath: path)
        guard let editor = preferred, line != nil || isCode(path) else {
            NSWorkspace.shared.open(file)
            return
        }
        if editor == .xcode {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = (line.map { ["-l", String($0)] } ?? []) + [path]
            if (try? process.run()) == nil { NSWorkspace.shared.open(file) }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else {
            NSWorkspace.shared.open(file)
            return
        }
        if let (relative, arguments) = editor.command(path: path, line: line, column: column) {
            let cli = app.appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                let process = Process()
                process.executableURL = cli
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { return }
            }
        }
        guard let url = editor.url(path: path, line: line, column: column) else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(file) } }
        }
    }

    /// Código y texto van al editor; imágenes, PDF, vídeos… a su app.
    static func isCode(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return true }
        guard let type = UTType(filenameExtension: ext) else { return true }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .propertyList) || type.conforms(to: .yaml)
    }
}

extension TerminalSession {
    /// ⌘+clic en un enlace de la salida. Devuelve false si debe abrirlo SwiftTerm (otros esquemas).
    func openLink(_ link: String) -> Bool {
        let roots = [context.root].compactMap { $0 }
        guard let target = LinkTarget.resolve(link, directory: cwd, roots: roots) else {
            NSSound.beep()
            return true
        }
        switch target {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .file(let path, let line, let column):
            Editors.open(path: path, line: line, column: column)
        case .directory(let path):
            if atPrompt && agent == nil {
                navigate(to: path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case .other:
            return false
        }
        return true
    }
}
