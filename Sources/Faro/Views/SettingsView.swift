import AppKit
import FaroCore
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: String) {
        SettingsNavigation.shared.tab = tab
        show()
    }

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Ajustes de Faro"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // Al cerrarla se destruye: la ventana de ajustes no ocupa memoria mientras no se usa.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    SettingsWindow.window?.contentViewController = nil
                    SettingsWindow.window = nil
                    MemoryMonitor.shared.trim()
                }
            }
        }
        if AppModel.testMode {
            window?.level = .floating
            window?.orderFrontRegardless()
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab = "appearance"
}

struct SettingsView: View {
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            AppearanceSettings().tabItem { Label("Apariencia", systemImage: "paintpalette") }.tag("appearance")
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }.tag("terminal")
            ProjectSettings().tabItem { Label("Proyectos", systemImage: "square.grid.2x2") }.tag("projects")
            IntelligenceSettings().tabItem { Label("Inteligencia", systemImage: "wand.and.sparkles") }.tag("intelligence")
            PerformanceSettings().tabItem { Label("Rendimiento", systemImage: "gauge.with.dots.needle.33percent") }.tag("performance")
        }
        .frame(width: 640, height: 560)
    }
}

private struct AppearanceSettings: View {
    @Bindable private var app = AppModel.shared
    @State private var fonts: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle("Cambiar con el modo claro u oscuro del Mac", isOn: $app.settings.followSystemAppearance)
                if app.settings.followSystemAppearance {
                    Picker("Tema claro", selection: $app.settings.lightThemeID) {
                        ForEach(Theme.all) { Text($0.name).tag($0.id) }
                    }
                    Picker("Tema oscuro", selection: $app.settings.darkThemeID) {
                        ForEach(Theme.all) { Text($0.name).tag($0.id) }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                    ForEach(Theme.all) { theme in
                        ThemeCard(theme: theme, selected: theme.id == app.theme.id) { pick(theme) }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Tema")
            }

            Section("Texto") {
                Picker("Fuente", selection: $app.settings.fontName) {
                    Text("Geist Mono").tag("")
                    Text("JetBrains Mono").tag("JetBrains Mono")
                    Text("SF Mono (sistema)").tag("system")
                    if !fonts.isEmpty {
                        Divider()
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                }
                LabeledContent("Tamaño") {
                    HStack {
                        Slider(value: $app.settings.fontSize, in: 9...24, step: 1)
                        Text("\(Int(app.settings.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Cursor", selection: $app.settings.cursorShape) {
                    Text("Barra").tag(FaroSettings.CursorShape.bar)
                    Text("Bloque").tag(FaroSettings.CursorShape.block)
                    Text("Subrayado").tag(FaroSettings.CursorShape.underline)
                }
                .pickerStyle(.segmented)
                Toggle("Cursor parpadeante", isOn: $app.settings.cursorBlink)
            }

            Section("Ventana") {
                Picker("Pestañas", selection: $app.settings.tabsInSidebar) {
                    Text("Arriba").tag(false)
                    Text("Barra lateral").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("Margen") {
                    HStack {
                        Slider(value: $app.settings.padding, in: 0...32, step: 2)
                        Text("\(Int(app.settings.padding)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Opacidad") {
                    HStack {
                        Slider(value: $app.settings.backgroundOpacity, in: 0.6...1, step: 0.05)
                        Text("\(Int(app.settings.backgroundOpacity * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if app.settings.backgroundOpacity < 1 {
                    Text("Con transparencia el fondo se desenfoca y se dibuja con la CPU en lugar de la GPU.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .font(.ui(13))
        .task { fonts = Fonts.monospacedFamilies() }
    }

    private func pick(_ theme: Theme) {
        if app.settings.followSystemAppearance {
            if theme.isDark { app.settings.darkThemeID = theme.id } else { app.settings.lightThemeID = theme.id }
            if theme.isDark != app.systemIsDark { app.settings.followSystemAppearance = false; app.settings.themeID = theme.id }
        } else {
            app.settings.themeID = theme.id
        }
    }
}

private struct ThemeCard: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let c = { (i: Int) in RGB(hex: theme.ansi[i]).color }
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("❯").foregroundStyle(RGB(hex: theme.accent).color)
                        Text("git").foregroundStyle(c(2))
                        Text("status").foregroundStyle(RGB(hex: theme.foreground).color)
                    }
                    HStack(spacing: 4) {
                        Text("main").foregroundStyle(c(5))
                        Text("+3").foregroundStyle(c(2))
                        Text("-1").foregroundStyle(c(1))
                    }
                    HStack(spacing: 3) {
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(c(i)).frame(width: 12, height: 6)
                        }
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RGB(hex: theme.background).color))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                HStack {
                    Text(theme.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    Spacer()
                    Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalSettings: View {
    @Bindable private var app = AppModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Terminal desplegable (\(GlobalHotKey.shortcut(app.settings.dropdownShortcut).label) desde cualquier app)", isOn: $app.settings.dropdownEnabled)
                if app.settings.dropdownEnabled {
                    Picker("Atajo", selection: $app.settings.dropdownShortcut) {
                        ForEach(GlobalHotKey.shortcuts) { shortcut in Text(shortcut.label).tag(shortcut.id) }
                    }
                    if let warning = GlobalHotKey.conflict(for: GlobalHotKey.shortcut(app.settings.dropdownShortcut)) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    } else if Dropdown.shared.hotKeyFailed {
                        Label("Otra app tiene este atajo reservado. Elige otro.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    Picker("Alto", selection: $app.settings.dropdownHeight) {
                        Text("Un tercio").tag(0.33)
                        Text("La mitad").tag(0.45)
                        Text("Dos tercios").tag(0.66)
                        Text("Casi toda").tag(0.85)
                    }
                    Toggle("Esconderla al pasar a otra app", isOn: $app.settings.dropdownHideOnBlur)
                }
            } header: {
                Text("Terminal desplegable")
            } footer: {
                Text("Baja desde arriba encima de cualquier app (también a pantalla completa) y con el mismo atajo se esconde y vuelves a donde estabas. Sus pestañas siguen vivas mientras está escondida. Funciona mientras Faro esté abierto, aunque no tenga ventanas.")
            }
            Section {
                Toggle("Resaltar cada comando y su salida al pasar el ratón", isOn: $app.settings.commandBlocks)
            } header: {
                Text("Bloques de comandos")
            } footer: {
                Text("Como en Warp: el comando y su salida se marcan como un bloque, con una franja verde o roja según cómo acabó, y una barra para copiar la salida o el comando, preguntar a Claude o volver a ejecutarlo. ⌥⌘C copia la salida del último comando.")
            }
            Section("Shell") {
                TextField("Programa", text: $app.settings.shell, prompt: Text(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"))
                Toggle("Prompt minimalista (❯) si usas el de macOS por defecto", isOn: $app.settings.minimalPrompt)
                Text("Las funciones inteligentes (ruta, sugerencias, saltos de carpeta) necesitan zsh. Faro no modifica tus archivos de configuración.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Recuperar pestañas, paneles y carpetas al abrir Faro", isOn: $app.settings.restoreSession)
            } header: {
                Text("Al abrir")
            } footer: {
                Text("Cada pestaña vuelve a su carpeta y las de Claude Code retoman su conversación (claude --resume). Las demás IAs se abren de nuevo. La salida de los terminales no se guarda.")
            }
            Section {
                Picker("Abrir archivos en", selection: $app.settings.editor) {
                    Text("Automático" + (Editors.installed.first.map { " (\(Editors.shortName($0)))" } ?? "")).tag("")
                    ForEach(Editors.installed) { editor in
                        Label {
                            Text(editor.name)
                        } icon: {
                            if let icon = Editors.icon(editor) { Image(nsImage: icon) }
                        }
                        .tag(editor.rawValue)
                    }
                    Text("La app por defecto de cada archivo").tag("system")
                }
            } header: {
                Text("Enlaces")
            } footer: {
                Text("⌘ + clic en una ruta de la salida (src/app/page.tsx:42) la abre en ese editor y en esa línea; en una URL o en localhost:3000, en el navegador; en una carpeta, te lleva a ella.")
            }
            Section("Teclado") {
                Toggle("Usar Opción como tecla Meta", isOn: $app.settings.optionAsMeta)
                Text("Desactivado, Opción escribe @ # | [ ] { } con el teclado español. Actívalo solo si usas atajos de Emacs o similares.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Historial de pantalla") {
                Picker("Líneas guardadas", selection: $app.settings.scrollback) {
                    Text("1.000").tag(1_000)
                    Text("5.000").tag(5_000)
                    Text("10.000").tag(10_000)
                    Text("50.000").tag(50_000)
                    Text("100.000").tag(100_000)
                }
            }
            Section {
                Button("Abrir «Acceso total al disco»…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            } header: {
                Text("Permisos")
            } footer: {
                Text("macOS pide permiso la primera vez que un programa de la terminal entra en Escritorio, Documentos o Descargas, y lo recuerda. Si prefieres no verlo nunca, añade Faro en «Acceso total al disco», como se suele hacer con las terminales.")
            }
            Section("Avisos") {
                Toggle("Isla en el notch mientras una IA trabaja y no la estás mirando", isOn: $app.settings.activityIsland)
                Toggle("Sonido cuando una IA termina", isOn: $app.settings.islandSound)
                Toggle("Notificar cuando termina un comando de más de 10 s que no estás viendo", isOn: $app.settings.notifyLongCommands)
            }
        }
        .formStyle(.grouped)
        .font(.ui(13))
    }
}

private struct IntelligenceSettings: View {
    @Bindable private var app = AppModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Sugerencias mientras escribes", isOn: $app.settings.suggestions)
                Toggle("Texto fantasma (→ para completar)", isOn: $app.settings.ghostText)
            } footer: {
                Text("Todo se calcula en tu Mac, sin conexión: tu historial, la carpeta en la que estás, el proyecto (package.json, Package.swift, Cargo, Makefile, Docker, git…) y qué comando sueles ejecutar después de cada uno.")
            }
            Section {
                Toggle("Isla en el notch", isOn: $app.settings.activityIsland)
                Toggle("Sonido cuando una IA termina", isOn: $app.settings.islandSound)
                    .disabled(!app.settings.activityIsland)
            } header: {
                Text("Isla de actividad")
            } footer: {
                Text("Mientras una IA trabaja y no la estás mirando, el notch muestra su logo y el progreso de su lista de tareas, si te espera o si ha terminado. Al entrar en su pestaña desaparece. También con ⌃⌘I.")
            }
            Section("Lo que Faro ha aprendido") {
                LabeledContent("Comandos distintos", value: "\(app.history.stats.count.formatted())")
                LabeledContent("Carpetas visitadas", value: "\(app.directories.entries.count.formatted())")
                LabeledContent("Archivo", value: "~/Library/Application Support/Faro")
            }
            Section {
                ForEach(AIAgent.allCases) { agent in
                    let installed = app.installedAgents.contains(agent)
                    HStack(spacing: 10) {
                        AgentLogo(agent: agent, size: 16)
                        Text(agent.name)
                        Spacer()
                        Text(installed ? agent.executables[0] : "No instalada")
                            .font(installed ? .code(11.5) : .ui(12))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(installed ? 1 : 0.45)
                }
            } header: {
                Text("Herramientas de IA")
            } footer: {
                Text("Las instaladas aparecen junto al «+» y en Shell → Nueva sesión de IA. Al ejecutarlas, la pestaña muestra su logo. ⇧⌘C abre Claude Code y, si un comando falla, «Explicar error» se lo pasa con su salida.")
            }
        }
        .formStyle(.grouped)
        .font(.ui(13))
        .id(app.historyVersion)
    }
}

private struct PerformanceSettings: View {
    @Bindable private var app = AppModel.shared

    var body: some View {
        Form {
            Section("Consumo ahora") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let footprint = MemoryMonitor.footprint()
                    LabeledContent("Memoria", value: ByteCountFormatter.string(fromByteCount: Int64(footprint), countStyle: .memory))
                    LabeledContent("Pestañas abiertas", value: "\(app.sessionCount)")
                    LabeledContent("CPU usada desde que se abrió", value: Notifier.format(MemoryMonitor.cpuMilliseconds()))
                }
                Button("Liberar memoria ahora") { MemoryMonitor.shared.trim() }
            }
            Section {
                Toggle("Dibujar con la GPU (Metal)", isOn: $app.settings.gpuRendering)
                Text("Solo compensa con salidas enormes y continuas. Usa unos 110 MB más, y ~30 MB por pestaña.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Devolver memoria al sistema cuando una terminal queda en reposo", isOn: $app.settings.trimMemoryWhenIdle)
            } header: {
                Text("Optimización")
            } footer: {
                Text("Las pestañas que no ves no se dibujan: cada pestaña extra ocupa menos de 1 MB. Sin actividad, Faro no usa CPU.")
            }
        }
        .formStyle(.grouped)
        .font(.ui(13))
    }
}
