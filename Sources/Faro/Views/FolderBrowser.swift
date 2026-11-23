import AppKit
import FaroCore
import SwiftUI

/// Explorador de carpetas: moverse por ellas sin escribir `cd`. Cada clic en una carpeta
/// mueve también la shell; un clic en un archivo lo escribe en la línea.
struct FolderBrowser: View {
    let session: TerminalSession
    let dismiss: () -> Void
    @Environment(\.palette) private var palette
    @State private var path = ""
    @State private var entries: [DirectoryEntry] = []
    @State private var filter = ""
    @State private var showHidden = false
    @FocusState private var filterFocused: Bool

    private var visible: [DirectoryEntry] {
        entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .filter { filter.isEmpty || Fuzzy.score(filter, in: $0.name) != nil }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    private var recents: [String] {
        AppModel.shared.directories.top(8).filter { $0 != path && FileManager.default.fileExists(atPath: $0) }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { go(to: (path as NSString).deletingLastPathComponent) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(HoverStyle())
                .disabled(path == "/")
                .help("Carpeta superior")
                Text(SuggestionEngine.abbreviate(path))
                    .font(.ui(13, .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button { showHidden.toggle() } label: {
                    Image(systemName: showHidden ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(showHidden ? palette.accent : palette.tertiaryText)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(HoverStyle())
                .help("Mostrar archivos ocultos")
            }
            .padding(8)

            TextField("Filtrar…", text: $filter)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.raised))
                .focused($filterFocused)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .onSubmit {
                    if let first = visible.first { open(first) }
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filter.isEmpty && !recents.isEmpty {
                        SectionHeader(title: "Recientes")
                        ForEach(recents, id: \.self) { dir in
                            Row(icon: "clock.arrow.circlepath", name: SuggestionEngine.abbreviate(dir), dim: false) { go(to: dir) }
                        }
                        SectionHeader(title: "En esta carpeta")
                    }
                    ForEach(visible, id: \.name) { entry in
                        Row(icon: entry.isDirectory ? "folder.fill" : icon(for: entry.name),
                            name: entry.name, dim: !entry.isDirectory, accent: entry.isDirectory) { open(entry) }
                            .contextMenu { contextMenu(for: entry) }
                    }
                    if visible.isEmpty {
                        Text(filter.isEmpty ? "Carpeta vacía" : "Nada coincide con «\(filter)»")
                            .foregroundStyle(palette.tertiaryText)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 320)

            palette.hairline.frame(height: 0.5)
            HStack(spacing: 12) {
                Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Nueva pestaña aquí") { session.window?.newTab(directory: path); dismiss() }
                Button("Claude aquí") { session.window?.newTab(directory: path, kind: .agent(.claude)); dismiss() }
                Spacer()
                Button("Copiar ruta") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            .buttonStyle(.plain)
            .font(.ui(11.5, .medium))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 330)
        .onAppear {
            path = session.cwd
            load()
            filterFocused = true
        }
    }

    private func go(to dir: String) {
        path = dir
        filter = ""
        load()
        session.navigate(to: dir)
    }

    private func open(_ entry: DirectoryEntry) {
        let full = (path as NSString).appendingPathComponent(entry.name)
        if entry.isDirectory {
            go(to: full)
        } else {
            let relative = full.hasPrefix(session.cwd + "/") ? String(full.dropFirst(session.cwd.count + 1)) : full
            let separator = session.buffer.isEmpty || session.buffer.hasSuffix(" ") ? "" : " "
            session.setBuffer(session.buffer + separator + Tokenizer.escape(relative))
            dismiss()
            session.window?.focusTerminal()
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: DirectoryEntry) -> some View {
        let full = (path as NSString).appendingPathComponent(entry.name)
        Button("Abrir con la app predeterminada") { NSWorkspace.shared.open(URL(fileURLWithPath: full)) }
        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)]) }
        if entry.isDirectory {
            Button("Abrir en pestaña nueva") { session.window?.newTab(directory: full); dismiss() }
        }
        Button("Copiar ruta") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(full, forType: .string)
        }
    }

    private func load() {
        let dir = path
        Task {
            let list = await Task.detached(priority: .userInitiated) { SuggestionEngine.readDirectory(dir) }.value
            if path == dir { entries = list }
        }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "rs", "go", "rb", "c", "cpp", "h", "java", "kt", "lua", "sh", "zsh": "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml": "curlybraces"
        case "md", "txt", "rtf": "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": "photo"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "rar", "7z": "archivebox"
        case "mp4", "mov", "mp3", "wav": "play.rectangle"
        default: "doc"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(title)
            .font(.ui(11, .medium))
            .foregroundStyle(palette.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct Row: View {
    let icon: String
    let name: String
    var dim = false
    var accent = false
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(accent ? palette.accent : palette.secondaryText)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(dim ? palette.secondaryText : palette.text)
            Spacer()
        }
        .font(.ui(13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? palette.hover : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
