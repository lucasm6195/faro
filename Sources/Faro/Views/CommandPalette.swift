import AppKit
import FaroCore
import SwiftUI

struct PaletteItem: Identifiable {
    enum Section: String {
        case projects = "Mis proyectos", actions = "Acciones", folders = "Carpetas", project = "Proyecto", history = "Historial", themes = "Temas"
    }
    let id: String
    let section: Section
    let icon: String
    let title: String
    var subtitle = ""
    var shortcut = ""
    var score = 0.0
    var agent: AIAgent?
    let run: @MainActor () -> Void
}

/// Paleta de comandos (⌘P): acciones, saltos a carpetas, scripts del proyecto, historial y temas.
struct CommandPalette: View {
    let controller: TerminalWindowController
    @Bindable var model: WindowModel
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let items = results()
        ZStack(alignment: .top) {
            Color.black.opacity(palette.theme.isDark ? 0.28 : 0.12)
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(palette.tertiaryText)
                    TextField("Ir a una carpeta, ejecutar, abrir una IA, cambiar de tema…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.ui(16))
                        .focused($focused)
                        .onSubmit { run(items[safe: selection]) }
                        .onChange(of: model.demoQuery) { _, text in if let text { query = text } }
                        .onChange(of: model.demoSubmit) { _, _ in run(results()[safe: selection]) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                palette.hairline.frame(height: 0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].section != item.section {
                                    Text(item.section.rawValue)
                                        .font(.ui(11, .medium))
                                        .foregroundStyle(palette.tertiaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 10)
                                        .padding(.bottom, 3)
                                }
                                row(item, selected: index == selection)
                                    .id(item.id)
                                    .onTapGesture { run(item) }
                            }
                            if items.isEmpty {
                                Text("Sin resultados").foregroundStyle(palette.tertiaryText).padding(16)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: selection) { _, new in
                        if let id = items[safe: new]?.id { proxy.scrollTo(id) }
                    }
                }
            }
            .frame(width: 600)
            .floatingPanel(palette, radius: 14)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Group {
                if let agent = item.agent {
                    AgentLogo(agent: agent, size: 14)
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 12.5))
                        .foregroundStyle(selected ? palette.accent : palette.tertiaryText)
                }
            }
            .frame(width: 18)
            Text(item.title).foregroundStyle(palette.text).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.ui(12)).foregroundStyle(palette.tertiaryText).lineLimit(1)
            }
            Spacer()
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(.ui(11.5)).foregroundStyle(palette.tertiaryText)
            }
        }
        .font(.ui(13.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? palette.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func close() {
        model.paletteVisible = false
        controller.focusTerminal()
    }

    private func run(_ item: PaletteItem?) {
        guard let item else { return }
        close()
        item.run()
    }

    private func results() -> [PaletteItem] {
        guard let session = model.selected else { return [] }
        let app = AppModel.shared
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [PaletteItem] = []

        let actions: [PaletteItem] = [
            PaletteItem(id: "a-tab", section: .actions, icon: "plus.square", title: "Nueva pestaña", shortcut: "⌘T") { controller.newTab() },
            PaletteItem(id: "a-sidebar", section: .actions, icon: "sidebar.left",
                        title: AppModel.shared.settings.tabsInSidebar ? "Pestañas arriba" : "Pestañas en la barra lateral", shortcut: "⌃⌘S") {
                AppModel.shared.settings.tabsInSidebar.toggle()
            },
            PaletteItem(id: "a-island", section: .actions, icon: "capsule.tophalf.filled",
                        title: AppModel.shared.settings.activityIsland ? "Desactivar la isla del notch" : "Activar la isla del notch",
                        shortcut: "⌃⌘I") {
                AppModel.shared.settings.activityIsland.toggle()
            },
            PaletteItem(id: "a-split-r", section: .actions, icon: "rectangle.split.2x1", title: "Dividir a la derecha", shortcut: "⌘D") {
                controller.split(.horizontal)
            },
            PaletteItem(id: "a-split-d", section: .actions, icon: "rectangle.split.1x2", title: "Dividir hacia abajo", shortcut: "⇧⌘D") {
                controller.split(.vertical)
            },
            PaletteItem(id: "a-claude-split", section: .actions, icon: "sparkle", title: "Claude Code en un panel al lado", agent: .claude) {
                controller.split(.horizontal, kind: .agent(.claude))
            },
            PaletteItem(id: "a-claude-continue", section: .actions, icon: "sparkles", title: "Continuar la última sesión de Claude",
                        agent: .claude) {
                controller.newTab(kind: .agent(.claude), startupCommand: "claude --continue")
            },
            PaletteItem(id: "a-folders", section: .actions, icon: "folder", title: "Explorar carpetas", shortcut: "⌘O") {
                model.folderBrowserVisible = true
            },
            PaletteItem(id: "a-editor-folder", section: .actions, icon: "chevron.left.forwardslash.chevron.right",
                        title: "Abrir esta carpeta en \(Editors.preferred.map(Editors.shortName) ?? "el Finder")") {
                Editors.openFolder(session.cwd)
            },
            PaletteItem(id: "a-dropdown", section: .actions, icon: "rectangle.topthird.inset.filled",
                        title: AppModel.shared.settings.dropdownEnabled ? "Desactivar la terminal desplegable" : "Activar la terminal desplegable",
                        shortcut: GlobalHotKey.shortcut(AppModel.shared.settings.dropdownShortcut).label) {
                AppModel.shared.settings.dropdownEnabled.toggle()
            },
            PaletteItem(id: "a-ports", section: .actions, icon: "powerplug.portrait", title: "Puertos abiertos (localhost)", shortcut: "⌃⌘P") {
                model.portsVisible = true
            },
            PaletteItem(id: "a-finder", section: .actions, icon: "macwindow", title: "Abrir esta carpeta en Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
            },
            PaletteItem(id: "a-copy", section: .actions, icon: "doc.on.doc", title: "Copiar la ruta actual") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            },
            PaletteItem(id: "a-clear", section: .actions, icon: "eraser", title: "Limpiar la pantalla", shortcut: "⌘K") {
                session.view.send(txt: "\u{0c}")
            },
            PaletteItem(id: "a-settings", section: .actions, icon: "slider.horizontal.3", title: "Ajustes", shortcut: "⌘,") { SettingsWindow.show() },
            PaletteItem(id: "a-memory", section: .actions, icon: "memorychip", title: "Liberar memoria ahora") { MemoryMonitor.shared.trim() },
            PaletteItem(id: "a-window", section: .actions, icon: "macwindow.badge.plus", title: "Nueva ventana", shortcut: "⌘N") {
                AppModel.shared.newWindow(directory: session.cwd)
            },
        ]
        let agentItems = app.installedAgents.map { agent in
            PaletteItem(id: "ai-" + agent.rawValue, section: .actions, icon: "sparkle", title: "Nueva sesión de \(agent.name)",
                        shortcut: agent == .claude ? "⇧⌘C" : "", agent: agent) {
                controller.newTab(kind: .agent(agent))
            }
        }
        let current = Editors.preferred
        let editorItems = Editors.installed.filter { $0 != current }.map { editor in
            PaletteItem(id: "ed-" + editor.rawValue, section: .actions, icon: "arrow.triangle.swap",
                        title: "Abrir archivos en \(Editors.shortName(editor))") {
                Editors.choose(editor)
            }
        }
        let projectActions = [
            PaletteItem(id: "a-project-new", section: .actions, icon: "square.grid.2x2", title: "Crear proyecto para esta carpeta") {
                Projects.shared.createForFolder(of: session)
            },
            PaletteItem(id: "a-project-save", section: .actions, icon: "square.and.arrow.down", title: "Guardar esta pestaña como proyecto") {
                if let tab = model.tab(containing: session) { Projects.shared.saveTab(tab) }
            },
        ]
        for (i, project) in Projects.shared.recent.enumerated() {
            let score = q.isEmpty ? 20 - Double(i) * 0.1 : (Fuzzy.score(q, in: project.name) ?? Fuzzy.score(q, in: "abrir " + project.name)).map { 20 + $0 }
            if let score {
                items.append(PaletteItem(id: "p-" + project.id.uuidString, section: .projects, icon: "square.grid.2x2.fill",
                                         title: "Abrir " + project.name, subtitle: project.summary, score: score) {
                    Projects.shared.open(project)
                })
            }
        }
        for var a in agentItems + actions + editorItems + projectActions {
            if let s = Fuzzy.score(q, in: a.title) { a.score = 10 + s; items.append(a) }
        }

        if !q.isEmpty {
            let frequent = app.directories.top(200)
            let known = Set(frequent)
            for dir in frequent + app.places.filter({ !known.contains($0) }) where dir != session.cwd {
                let shown = SuggestionEngine.abbreviate(dir)
                if let s = Fuzzy.score(q, in: (dir as NSString).lastPathComponent) ?? Fuzzy.score(q, in: shown).map({ $0 * 0.6 }),
                   s >= 0.4, FileManager.default.fileExists(atPath: dir) {
                    items.append(PaletteItem(id: "d-" + dir, section: .folders, icon: "folder.fill", title: shown,
                                             subtitle: known.contains(dir) ? "Carpeta frecuente" : "Ir a esta carpeta",
                                             score: 8 + s + (known.contains(dir) ? 0.3 : 0)) { session.navigate(to: dir) })
                }
            }
        }

        for pc in session.context.commands {
            if let s = Fuzzy.score(q, in: pc.command), q.isEmpty || s >= 0.4 {
                items.append(PaletteItem(id: "p-" + pc.command, section: .project, icon: "hammer", title: pc.command,
                                         subtitle: pc.detail, score: 6 + s) { session.run(pc.command) })
            }
        }

        if !q.isEmpty {
            let history = app.history.stats.keys.compactMap { c -> (String, Double)? in
                guard let s = Fuzzy.score(q, in: c), s >= 0.4 else { return nil }
                return (c, s + log1p(app.history.frecency(c)) * 0.2)
            }
            for (c, s) in history.sorted(by: { $0.1 > $1.1 }).prefix(8) {
                items.append(PaletteItem(id: "h-" + c, section: .history, icon: "clock.arrow.circlepath", title: c,
                                         subtitle: "Ejecutar", score: 4 + s) { session.run(c) })
            }
            for theme in Theme.all {
                if let s = Fuzzy.score(q, in: "tema " + theme.name), s >= 0.4 {
                    items.append(PaletteItem(id: "t-" + theme.id, section: .themes, icon: "paintpalette", title: "Tema: \(theme.name)",
                                             subtitle: theme.isDark ? "Oscuro" : "Claro", score: 3 + s) {
                        AppModel.shared.settings.followSystemAppearance = false
                        AppModel.shared.settings.themeID = theme.id
                    })
                }
            }
        }

        let order: [PaletteItem.Section] = [.projects, .actions, .folders, .project, .history, .themes]
        let grouped = Dictionary(grouping: items, by: \.section)
        let best = Dictionary(uniqueKeysWithValues: grouped.map { ($0.key, $0.value.map(\.score).max() ?? 0) })
        let sections = q.isEmpty ? order : order.sorted { (best[$0] ?? -1) > (best[$1] ?? -1) }
        return sections.flatMap { section in
            (grouped[section] ?? []).sorted { $0.score > $1.score }.prefix(section == .actions && q.isEmpty ? 12 : 8)
        }
    }
}
