import Foundation

public struct CommandRecord: Codable, Sendable, Equatable {
    public var command: String
    public var directory: String?
    public var date: Date
    public var exit: Int32?
    public var milliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case command = "c", directory = "d", date = "t", exit = "e", milliseconds = "ms"
    }

    public init(command: String, directory: String?, date: Date, exit: Int32? = nil, milliseconds: Int? = nil) {
        self.command = command
        self.directory = directory
        self.date = date
        self.exit = exit
        self.milliseconds = milliseconds
    }
}

public struct CommandStats: Sendable, Equatable {
    public var count = 0
    public var failures = 0
    public var lastUsed = Date.distantPast
    public var directories: [String: Int] = [:]
}

/// Índice en memoria del historial: frecuencia, recencia, carpetas y transiciones
/// entre comandos (qué se suele ejecutar después de qué). Es lo que permite
/// predecir el siguiente comando sin red ni modelos.
public struct HistoryIndex: Sendable {
    public private(set) var stats: [String: CommandStats] = [:]
    public private(set) var transitions: [String: [String: Int]] = [:]
    public private(set) var lastCommand: String?

    public init() {}

    public mutating func record(_ r: CommandRecord) {
        let command = Self.normalize(r.command)
        guard Self.shouldRemember(command) else { return }
        var s = stats[command, default: CommandStats()]
        s.count += 1
        if let exit = r.exit, exit != 0 { s.failures += 1 }
        s.lastUsed = max(s.lastUsed, r.date)
        if let dir = r.directory { s.directories[dir, default: 0] += 1 }
        stats[command] = s
        if let previous = lastCommand, previous != command {
            transitions[previous, default: [:]][command, default: 0] += 1
        }
        lastCommand = command
    }

    /// Marca el resultado de un comando ya registrado (llega después, al volver el prompt).
    public mutating func complete(command: String, exit: Int32) {
        let command = Self.normalize(command)
        guard exit != 0, var s = stats[command] else { return }
        s.failures += 1
        stats[command] = s
    }

    public func frecency(_ command: String, now: Date = Date()) -> Double {
        guard let s = stats[command] else { return 0 }
        return Double(s.count) * Self.recencyWeight(s.lastUsed, now: now)
    }

    public func successRate(_ command: String) -> Double {
        guard let s = stats[command], s.count > 0 else { return 1 }
        return 1 - Double(s.failures) / Double(s.count)
    }

    public func directoryAffinity(_ command: String, directory: String) -> Double {
        guard let s = stats[command], s.count > 0 else { return 0 }
        return Double(s.directories[directory] ?? 0) / Double(s.count)
    }

    /// Comandos que suelen seguir a `command`, con su probabilidad.
    public func next(after command: String) -> [(command: String, probability: Double)] {
        guard let row = transitions[Self.normalize(command)] else { return [] }
        let total = Double(row.values.reduce(0, +))
        return row.map { ($0.key, Double($0.value) / total) }.sorted { $0.probability > $1.probability }
    }

    static func recencyWeight(_ date: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(date)
        switch age {
        case ..<3_600: return 4
        case ..<86_400: return 2
        case ..<604_800: return 1
        case ..<2_592_000: return 0.5
        default: return 0.25
        }
    }

    static func normalize(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldRemember(_ command: String) -> Bool {
        guard !command.isEmpty, command.count < 500 else { return false }
        let lowered = command.lowercased()
        let secrets = ["password=", "passwd=", "token=", "secret=", "api_key=", "apikey="]
        return !secrets.contains { lowered.contains($0) }
    }
}

/// Frecencia de carpetas al estilo zoxide: cuantas más visitas recientes, más arriba.
public struct DirectoryIndex: Codable, Sendable {
    public struct Entry: Codable, Sendable { public var rank: Double; public var last: Date }
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public mutating func visit(_ path: String, date: Date = Date()) {
        var e = entries[path] ?? Entry(rank: 0, last: date)
        e.rank += 1
        e.last = date
        entries[path] = e
        if entries.count > 2_000 { age() }
    }

    public func score(_ path: String, now: Date = Date()) -> Double {
        guard let e = entries[path] else { return 0 }
        return e.rank * HistoryIndex.recencyWeight(e.last, now: now)
    }

    public func top(_ limit: Int, now: Date = Date()) -> [String] {
        entries.keys.sorted { score($0, now: now) > score($1, now: now) }.prefix(limit).map { $0 }
    }

    public mutating func remove(_ path: String) { entries[path] = nil }

    private mutating func age() {
        let keep = top(1_500)
        entries = entries.filter { keep.contains($0.key) }
    }
}

/// Lectura del historial de zsh (formato extendido `: inicio:duración;comando`,
/// con las líneas partidas con `\` y la codificación "meta" de zsh).
public enum ZshHistoryImporter {
    public static func load(from url: URL, limit: Int = 20_000) -> [CommandRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: unmetafy(data), as: UTF8.self)
        var records: [CommandRecord] = []
        var pending = ""
        var pendingDate = Date.distantPast
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if pending.isEmpty {
                if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                    let meta = line[line.index(line.startIndex, offsetBy: 2)..<semi]
                    let start = meta.split(separator: ":").first.flatMap { TimeInterval($0) }
                    pendingDate = start.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
                    line = String(line[line.index(after: semi)...])
                } else {
                    pendingDate = .distantPast
                }
            }
            if line.hasSuffix("\\") {
                pending += line.dropLast() + "\n"
                continue
            }
            let command = pending + line
            pending = ""
            if !command.trimmingCharacters(in: .whitespaces).isEmpty {
                records.append(CommandRecord(command: command, directory: nil, date: pendingDate))
            }
        }
        return Array(records.suffix(limit))
    }

    static func unmetafy(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta { out.append(byte ^ 32); meta = false }
            else if byte == 0x83 { meta = true }
            else { out.append(byte) }
        }
        return out
    }
}

/// Guarda el historial de Faro como JSON por líneas, en segundo plano.
public actor HistoryStore {
    public let url: URL
    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
        encoder.dateEncodingStrategy = .secondsSince1970
    }

    public func loadAll(limit: Int = 30_000) -> [CommandRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let records = lines.suffix(limit).compactMap { try? decoder.decode(CommandRecord.self, from: Data($0)) }
        if lines.count > limit * 2 { rewrite(records) }
        return records
    }

    public func append(_ record: CommandRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(UInt8(ascii: "\n"))
        if handle == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
    }

    private func rewrite(_ records: [CommandRecord]) {
        var data = Data()
        for r in records {
            if let line = try? encoder.encode(r) { data.append(line); data.append(UInt8(ascii: "\n")) }
        }
        try? data.write(to: url, options: .atomic)
        handle = nil
    }
}
