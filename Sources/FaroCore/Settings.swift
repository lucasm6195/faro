import Foundation

public struct FaroSettings: Codable, Sendable, Equatable {
    public enum CursorShape: String, Codable, Sendable, CaseIterable { case bar, block, underline }

    public var themeID = Theme.faroNoche.id
    public var followSystemAppearance = true
    public var lightThemeID = Theme.faroDia.id
    public var darkThemeID = Theme.faroNoche.id
    public var fontName = ""
    public var fontSize = 13.0
    public var padding = 12.0
    public var backgroundOpacity = 1.0
    public var cursorShape = CursorShape.bar
    public var cursorBlink = true
    public var shell = ""
    public var scrollback = 10_000
    public var optionAsMeta = false
    public var minimalPrompt = true
    public var suggestions = true
    public var ghostText = true
    public var gpuRendering = false
    public var trimMemoryWhenIdle = true
    public var notifyLongCommands = true
    /// Pestañas en una barra lateral a la izquierda en lugar de arriba.
    public var tabsInSidebar = false
    public var sidebarWidth = 230.0
    /// Isla en el notch con lo que hacen las IAs mientras no las miras.
    public var activityIsland = true
    public var islandSound = true
    /// Al abrir Faro, recuperar las pestañas, paneles y conversaciones de Claude de la última vez.
    public var restoreSession = true
    /// Editor para ⌘+clic en archivos: un `CodeEditor`, "" (el primero instalado) o "system" (la app por defecto).
    public var editor = ""
    /// Terminal desplegable desde arriba con un atajo global (como las de estilo Quake).
    public var dropdownEnabled = true
    public var dropdownShortcut = "control-option-space"
    /// Alto, en fracción de la pantalla.
    public var dropdownHeight = 0.45
    /// Se esconde sola al pasar a otra app.
    public var dropdownHideOnBlur = true
    /// Resaltar el comando y su salida al pasar el ratón, con acciones (copiar, Claude, repetir).
    public var commandBlocks = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FaroSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        themeID = v(.themeID, d.themeID)
        followSystemAppearance = v(.followSystemAppearance, d.followSystemAppearance)
        lightThemeID = v(.lightThemeID, d.lightThemeID)
        darkThemeID = v(.darkThemeID, d.darkThemeID)
        fontName = v(.fontName, d.fontName)
        fontSize = v(.fontSize, d.fontSize)
        padding = v(.padding, d.padding)
        backgroundOpacity = v(.backgroundOpacity, d.backgroundOpacity)
        cursorShape = v(.cursorShape, d.cursorShape)
        cursorBlink = v(.cursorBlink, d.cursorBlink)
        shell = v(.shell, d.shell)
        scrollback = v(.scrollback, d.scrollback)
        optionAsMeta = v(.optionAsMeta, d.optionAsMeta)
        minimalPrompt = v(.minimalPrompt, d.minimalPrompt)
        suggestions = v(.suggestions, d.suggestions)
        ghostText = v(.ghostText, d.ghostText)
        gpuRendering = v(.gpuRendering, d.gpuRendering)
        trimMemoryWhenIdle = v(.trimMemoryWhenIdle, d.trimMemoryWhenIdle)
        notifyLongCommands = v(.notifyLongCommands, d.notifyLongCommands)
        tabsInSidebar = v(.tabsInSidebar, d.tabsInSidebar)
        sidebarWidth = v(.sidebarWidth, d.sidebarWidth)
        activityIsland = v(.activityIsland, d.activityIsland)
        islandSound = v(.islandSound, d.islandSound)
        restoreSession = v(.restoreSession, d.restoreSession)
        editor = v(.editor, d.editor)
        dropdownEnabled = v(.dropdownEnabled, d.dropdownEnabled)
        dropdownShortcut = v(.dropdownShortcut, d.dropdownShortcut)
        dropdownHeight = v(.dropdownHeight, d.dropdownHeight)
        dropdownHideOnBlur = v(.dropdownHideOnBlur, d.dropdownHideOnBlur)
        commandBlocks = v(.commandBlocks, d.commandBlocks)
    }

    public static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Faro", isDirectory: true)
    public static let file = directory.appendingPathComponent("settings.json")

    public static func load() -> FaroSettings {
        guard let data = try? Data(contentsOf: file) else { return FaroSettings() }
        return (try? JSONDecoder().decode(FaroSettings.self, from: data)) ?? FaroSettings()
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    public func theme(systemIsDark: Bool) -> Theme {
        guard followSystemAppearance else { return Theme.named(themeID) }
        return Theme.named(systemIsDark ? darkThemeID : lightThemeID)
    }
}
