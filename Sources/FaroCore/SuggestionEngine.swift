import Foundation

public struct Suggestion: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case history, prediction, project, path, directory, command
    }

    public var kind: Kind
    /// Línea completa que quedará en la shell al aceptar.
    public var replacement: String
    /// Texto corto que se muestra en la lista.
    public var title: String
    public var detail: String
    public var score: Double
    public var isDirectory = false

    public var id: String { replacement }

    public init(kind: Kind, replacement: String, title: String, detail: String, score: Double, isDirectory: Bool = false) {
        self.kind = kind
        self.replacement = replacement
        self.title = title
        self.detail = detail
        self.score = score
        self.isDirectory = isDirectory
    }
}

public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Lista ordenada con búsqueda por prefijo en O(log n).
public struct PrefixIndex: Sendable {
    public let items: [String]

    public init<S: Sequence>(_ items: S) where S.Element == String {
        self.items = Array(Set(items)).sorted()
    }

    public func matches(prefix: String, limit: Int) -> ArraySlice<String> {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < items.count, end - lo < limit, items[end].hasPrefix(prefix) { end += 1 }
        return items[lo..<end]
    }
}

/// Motor de sugerencias local: combina historial (frecuencia, recencia, carpeta y éxito),
/// predicción del siguiente comando, comandos del proyecto, rutas y comandos conocidos.
/// No usa red: responde en microsegundos en cada pulsación.
public struct SuggestionEngine: Sendable {
    public var history: HistoryIndex
    public var directories: DirectoryIndex
    public var context: ProjectContext
    public var executables: PrefixIndex
    public var listDirectory: @Sendable (String) -> [DirectoryEntry]
    public var directoryExists: @Sendable (String) -> Bool = { path in
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    /// Carpetas conocidas aunque aún no se hayan visitado (las de casa y sus subcarpetas).
    public var places: [String] = []
    private let historyIndex: PrefixIndex

    public init(history: HistoryIndex, directories: DirectoryIndex, context: ProjectContext,
                executables: PrefixIndex, listDirectory: @escaping @Sendable (String) -> [DirectoryEntry] = SuggestionEngine.readDirectory) {
        self.history = history
        self.directories = directories
        self.context = context
        self.executables = executables
        self.listDirectory = listDirectory
        self.historyIndex = PrefixIndex(history.stats.keys)
    }

    // MARK: Mientras se escribe

    public func suggestions(buffer: String, cwd: String, home: String = NSHomeDirectory(), limit: Int = 7) -> [Suggestion] {
        if buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            return predictions(cwd: cwd, limit: limit)
        }
        let now = Date()
        let line = Tokenizer(buffer)
        var found: [String: Suggestion] = [:]
        func add(_ s: Suggestion) {
            guard s.replacement != buffer else { return }
            if let existing = found[s.replacement], existing.score >= s.score { return }
            found[s.replacement] = s
        }

        let predicted = Dictionary(history.next(after: history.lastCommand ?? "").prefix(10).map { ($0.command, $0.probability) },
                                   uniquingKeysWith: { a, _ in a })

        for command in historyIndex.matches(prefix: buffer, limit: 400) where isPlausible(command, cwd: cwd, home: home) {
            add(Suggestion(kind: .history, replacement: command, title: command, detail: historyDetail(command),
                           score: historyScore(command, cwd: cwd, now: now) + 3 + (predicted[command] ?? 0) * 2))
        }
        if buffer.count >= 3 && found.count < limit {
            for (command, _) in history.stats where command.contains(buffer) && !command.hasPrefix(buffer) && isPlausible(command, cwd: cwd, home: home) {
                add(Suggestion(kind: .history, replacement: command, title: command, detail: historyDetail(command),
                               score: historyScore(command, cwd: cwd, now: now) + 0.5))
            }
        }

        for pc in context.commands {
            if let s = Fuzzy.score(buffer, in: pc.command), s >= 0.5 {
                add(Suggestion(kind: .project, replacement: pc.command, title: pc.command, detail: pc.detail, score: 2 + s))
            }
        }

        if let first = line.words.first {
            if line.isTypingFirstWord {
                for name in executables.matches(prefix: first, limit: 12) {
                    let known = CommandSpecs.descriptions[name]
                    add(Suggestion(kind: .command, replacement: name + " ", title: name,
                                   detail: known ?? "programa", score: (known == nil ? 1.0 : 1.6) + log1p(commandUse(name))))
                }
            } else if let subs = CommandSpecs.subcommands[first] {
                for sub in subs where sub.command.hasPrefix(buffer) {
                    add(Suggestion(kind: .command, replacement: sub.command, title: sub.command, detail: sub.detail, score: 1.8))
                }
            }

            let wantsPath = !line.isTypingFirstWord && CommandSpecs.takesPath.contains(first)
            let looksLikePath = line.lastWord.hasPrefix("/") || line.lastWord.hasPrefix("~") || line.lastWord.hasPrefix("./")
                || line.lastWord.hasPrefix("../") || line.lastWord.contains("/")
            if wantsPath || (looksLikePath && !line.isTypingFirstWord) {
                let directoriesOnly = CommandSpecs.takesDirectoryOnly.contains(first)
                for s in pathSuggestions(line: line, cwd: cwd, home: home, directoriesOnly: directoriesOnly) { add(s) }
                if directoriesOnly && !line.lastWord.isEmpty && !line.lastWord.contains("/") {
                    for s in jumpSuggestions(query: line.lastWord, prefix: line.head, cwd: cwd, home: home, now: now) { add(s) }
                }
            }
        }

        return Array(found.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.replacement < $1.replacement }.prefix(limit))
    }

    /// Texto fantasma: lo que falta para completar la mejor sugerencia que empieza igual.
    public func ghost(buffer: String, cwd: String, home: String = NSHomeDirectory()) -> String? {
        guard !buffer.isEmpty, !buffer.hasSuffix("\n") else { return nil }
        let candidates = suggestions(buffer: buffer, cwd: cwd, home: home, limit: 5)
        guard let best = candidates.first(where: { $0.replacement.hasPrefix(buffer) && $0.replacement.count > buffer.count }) else {
            return nil
        }
        return String(best.replacement.dropFirst(buffer.count))
    }

    // MARK: Con la línea vacía

    /// Predicción del siguiente comando a partir del anterior, la carpeta y el proyecto.
    public func predictions(cwd: String, limit: Int = 4) -> [Suggestion] {
        let now = Date()
        var found: [String: Suggestion] = [:]
        func add(_ s: Suggestion) {
            if let existing = found[s.replacement], existing.score >= s.score { return }
            found[s.replacement] = s
        }
        if let last = history.lastCommand {
            for (command, p) in history.next(after: last).prefix(10) where isPlausible(command, cwd: cwd, home: NSHomeDirectory()) {
                add(Suggestion(kind: .prediction, replacement: command, title: command,
                               detail: "lo sueles poner después de \(Self.shorten(last))",
                               score: 2 + p * 3 + history.successRate(command)))
            }
        }
        let local = history.stats.filter { ($0.value.directories[cwd] ?? 0) > 0 }
        for (command, _) in local.filter({ isPlausible($0.key, cwd: cwd, home: NSHomeDirectory()) }).sorted(by: { localWeight($0.key, cwd: cwd, now: now) > localWeight($1.key, cwd: cwd, now: now) }).prefix(6) {
            add(Suggestion(kind: .prediction, replacement: command, title: command, detail: "lo usas mucho aquí",
                           score: 1 + log1p(localWeight(command, cwd: cwd, now: now))))
        }
        for pc in context.commands.prefix(4) {
            add(Suggestion(kind: .project, replacement: pc.command, title: pc.command, detail: pc.detail, score: 0.9))
        }
        return Array(found.values.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: Rutas

    func pathSuggestions(line: Tokenizer, cwd: String, home: String, directoriesOnly: Bool) -> [Suggestion] {
        let word = line.lastWordUnescaped
        let slash = word.lastIndex(of: "/")
        let dirPart = slash.map { String(word[...$0]) } ?? ""
        let namePrefix = slash.map { String(word[word.index(after: $0)...]) } ?? word
        let base: String
        if dirPart.hasPrefix("/") { base = dirPart }
        else if dirPart.hasPrefix("~") { base = home + dirPart.dropFirst() }
        else { base = (cwd as NSString).appendingPathComponent(dirPart) }

        let showHidden = namePrefix.hasPrefix(".")
        let lowered = namePrefix.lowercased()
        let entries = listDirectory(base)
            .filter { (showHidden || !$0.name.hasPrefix(".")) && (!directoriesOnly || $0.isDirectory) }
            .filter { lowered.isEmpty || $0.name.lowercased().hasPrefix(lowered) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
            .prefix(40)

        return entries.map { e in
            let path = dirPart + e.name + (e.isDirectory ? "/" : "")
            let exact = e.name.hasPrefix(namePrefix) ? 0.2 : 0
            return Suggestion(kind: .path, replacement: line.head + Tokenizer.escape(path), title: e.name + (e.isDirectory ? "/" : ""),
                              detail: e.isDirectory ? "carpeta" : "archivo",
                              score: (e.isDirectory ? 2.6 : 2.2) + exact, isDirectory: e.isDirectory)
        }
    }

    /// Un `cd` a una ruta relativa que no existe aquí no tiene sentido sugerirlo.
    func isPlausible(_ command: String, cwd: String, home: String) -> Bool {
        guard command.hasPrefix("cd ") else { return true }
        let target = Tokenizer(command).lastWordUnescaped
        guard !target.isEmpty, target != "-" else { return true }
        let path: String
        if target.hasPrefix("/") { path = target }
        else if target.hasPrefix("~") { path = home + target.dropFirst() }
        else { path = (cwd as NSString).appendingPathComponent(target) }
        let normalized = (path as NSString).standardizingPath
        return normalized != cwd && directoryExists(normalized)
    }

    /// Saltos a carpetas por nombre, como `cd proy` → `cd ~/Proyectos`: primero las frecuentes,
    /// después las conocidas aunque aún no se hayan visitado.
    func jumpSuggestions(query: String, prefix: String, cwd: String, home: String, now: Date) -> [Suggestion] {
        let frequent = directories.top(300, now: now)
        let known = Set(frequent)
        return (frequent + places.filter { !known.contains($0) }).compactMap { path -> Suggestion? in
            guard path != cwd, directoryExists(path) else { return nil }
            let name = (path as NSString).lastPathComponent
            guard let s = Fuzzy.score(query, in: name), s >= 0.5 else { return nil }
            let shown = Self.abbreviate(path, home: home)
            return Suggestion(kind: .directory, replacement: prefix + Tokenizer.escape(shown), title: shown,
                              detail: known.contains(path) ? "vas a menudo" : "carpeta",
                              score: 1.6 + s * 0.5 + log1p(directories.score(path, now: now)) * 0.3,
                              isDirectory: true)
        }
    }

    // MARK: Puntuación

    func historyScore(_ command: String, cwd: String, now: Date) -> Double {
        log1p(history.frecency(command, now: now)) + history.directoryAffinity(command, directory: cwd) * 1.5
            + (history.successRate(command) - 1) * 2
    }

    func localWeight(_ command: String, cwd: String, now: Date) -> Double {
        history.frecency(command, now: now) * history.directoryAffinity(command, directory: cwd)
    }

    func commandUse(_ name: String) -> Double {
        var total = 0.0
        for command in historyIndex.matches(prefix: name, limit: 200) where command == name || command.hasPrefix(name + " ") {
            total += Double(history.stats[command]?.count ?? 0)
        }
        return total
    }

    func historyDetail(_ command: String) -> String {
        guard let s = history.stats[command] else { return "ya lo usaste" }
        if s.failures > 0 && s.failures == s.count { return "la última vez falló" }
        return s.count == 1 ? "1 vez" : "\(s.count) veces"
    }

    // MARK: Utilidades

    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func shorten(_ s: String) -> String {
        s.count > 28 ? String(s.prefix(27)) + "…" : s
    }

    public static let readDirectory: @Sendable (String) -> [DirectoryEntry] = { path in
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return items.map { item in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return DirectoryEntry(name: item.lastPathComponent, isDirectory: isDir)
        }
    }
}

/// Divide la línea en palabras como lo haría la shell, de forma simplificada
/// (comillas y espacios escapados).
public struct Tokenizer: Sendable {
    public let words: [String]
    public let lastWord: String
    /// Todo lo anterior a la última palabra, incluido el espacio.
    public let head: String
    public let isTypingFirstWord: Bool

    public init(_ line: String) {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var lastStart = line.startIndex
        for i in line.indices {
            let ch = line[i]
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == " " {
                if !current.isEmpty { words.append(current); current = "" }
                lastStart = line.index(after: i)
                continue
            }
            current.append(ch)
        }
        let endsWithSpace = line.last == " " && !escaped && quote == nil
        if !current.isEmpty { words.append(current) }
        self.words = words
        self.lastWord = endsWithSpace ? "" : current
        self.head = endsWithSpace ? line : String(line[..<lastStart])
        self.isTypingFirstWord = words.count <= 1 && !endsWithSpace
    }

    public var lastWordUnescaped: String {
        var out = ""
        var escaped = false
        for ch in lastWord {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch != "\"" && ch != "'" { out.append(ch) }
        }
        return out
    }

    public static func escape(_ path: String) -> String {
        let special: Set<Character> = [" ", "'", "\"", "(", ")", "&", ";", "|", "<", ">", "$", "`", "!", "*", "?", "[", "]", "{", "}", "#"]
        var out = ""
        for (i, ch) in path.enumerated() {
            if special.contains(ch) && !(i == 0 && ch == "~") { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
