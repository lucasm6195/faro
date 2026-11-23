import Foundation

/// Un comando y su salida en el terminal, como un bloque de Warp. Las filas son absolutas
/// (no cambian aunque el historial se recorte por arriba).
public struct CommandBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let command: String
    public let directory: String
    /// Fila donde se escribió el comando (con el prompt).
    public let startRow: Int
    /// Última fila de su salida; nil mientras sigue en marcha.
    public var endRow: Int?
    public var exit: Int32?
    public var milliseconds: Int?

    public init(id: Int, command: String, directory: String, startRow: Int, endRow: Int? = nil, exit: Int32? = nil, milliseconds: Int? = nil) {
        self.id = id
        self.command = command
        self.directory = directory
        self.startRow = startRow
        self.endRow = endRow
        self.exit = exit
        self.milliseconds = milliseconds
    }

    public var isRunning: Bool { endRow == nil }

    public func contains(row: Int, cursorRow: Int) -> Bool {
        row >= startRow && row <= (endRow ?? cursorRow)
    }
}

/// Los bloques de una terminal, del más antiguo al más reciente.
public struct CommandBlocks: Sendable {
    public private(set) var all: [CommandBlock] = []
    private var nextID = 1
    let limit: Int

    public init(limit: Int = 300) { self.limit = limit }

    public var last: CommandBlock? { all.last }

    public mutating func begin(command: String, directory: String, row: Int) {
        // Un comando que no llegó a cerrarse (la shell se reinició) acaba donde empieza el nuevo.
        if let i = all.indices.last, all[i].endRow == nil { all[i].endRow = max(all[i].startRow, row - 1) }
        all.append(CommandBlock(id: nextID, command: command, directory: directory, startRow: row))
        nextID += 1
        if all.count > limit { all.removeFirst(all.count - limit) }
    }

    /// Ha vuelto el prompt en `promptRow`: la salida del último acaba justo encima.
    public mutating func end(promptRow: Int) {
        guard let i = all.indices.last, all[i].endRow == nil else { return }
        all[i].endRow = max(all[i].startRow, promptRow - 1)
    }

    public mutating func finish(exit: Int32, milliseconds: Int) {
        guard let i = all.indices.last, all[i].exit == nil else { return }
        all[i].exit = exit
        all[i].milliseconds = milliseconds
    }

    /// Olvida los bloques cuyas filas ya no existen (historial borrado con `clear` o ⌘K).
    public mutating func drop(before row: Int) {
        all.removeAll { ($0.endRow ?? Int.max) < row }
    }

    public func block(at row: Int, cursorRow: Int) -> CommandBlock? {
        all.last { $0.contains(row: row, cursorRow: cursorRow) }
    }

    // MARK: Leer el terminal

    /// La fila donde se escribió el comando: buscando hacia arriba desde el cursor la que
    /// contiene su principio (el prompt va delante).
    public static func commandRow(in rows: [(row: Int, text: String)], command: String) -> Int? {
        let firstLine = command.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? command
        let probe = String(firstLine.prefix(24)).trimmingCharacters(in: .whitespaces)
        guard !probe.isEmpty else { return nil }
        return rows.reversed().first { $0.text.contains(probe) }?.row
    }

    /// Texto de varias filas, uniendo las que son continuación de la anterior (líneas largas
    /// partidas por el ancho) y quitando las líneas vacías del final.
    public static func text(of rows: [(text: String, isWrapped: Bool)]) -> String {
        var lines: [String] = []
        for row in rows {
            let text = row.text.replacingOccurrences(of: "\u{0}", with: " ")
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
        }
        lines = lines.map { String($0.reversed().drop { $0 == " " }.reversed()) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}
