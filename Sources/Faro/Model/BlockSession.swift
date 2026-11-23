import AppKit
import FaroCore
import SwiftTerm

/// Lo que se ve en pantalla, guardado hasta que llega salida nueva o se desplaza.
struct ViewportCache {
    let top: Int
    let rows: [Int: String]
    let cursorRow: Int
    let isAlternate: Bool
    let rowCount: Int
}

extension TerminalSession {
    // MARK: Registrar bloques

    private var terminalCursor: (row: Int, column: Int)? {
        guard let snapshot = view.terminalContentSnapshot(region: .rows(0..<0), buffer: .normal) else { return nil }
        return (snapshot.cursorRow, snapshot.cursorColumn)
    }

    func blockStarted(_ command: String) {
        guard let cursor = terminalCursor else { return }
        let from = max(0, cursor.row - 200)
        let rows = view.terminalContentSnapshot(region: .rows(from..<(cursor.row + 1)), buffer: .normal)?
            .rows.map { (row: $0.absoluteRow, text: $0.text) } ?? []
        let row = CommandBlocks.commandRow(in: rows, command: command) ?? max(0, cursor.row - 1)
        blocks.begin(command: command, directory: cwd, row: row)
    }

    func blockPromptShown() {
        guard let cursor = terminalCursor, blocks.last?.isRunning == true else { return }
        blocks.end(promptRow: cursor.row)
        // Lo de antes del principio del historial ya no existe (por ejemplo tras `clear`).
        if let top = view.terminalContentSnapshot(region: .rows(0..<1), buffer: .normal)?.capturedRange.lowerBound {
            blocks.drop(before: top)
        }
    }

    // MARK: Pasar el ratón

    private func viewport() -> ViewportCache? {
        let dirty = viewportDirty.withLock { value -> Bool in
            defer { value = false }
            return value
        }
        if !dirty, let viewportCache { return viewportCache }
        guard let snapshot = view.terminalContentSnapshot(region: .viewport) else { return nil }
        var rows: [Int: String] = [:]
        for row in snapshot.rows { rows[row.absoluteRow] = row.text }
        let cache = ViewportCache(top: snapshot.capturedRange.lowerBound, rows: rows, cursorRow: snapshot.cursorRow,
                                  isAlternate: snapshot.bufferKind == .alt, rowCount: snapshot.rows.count)
        viewportCache = cache
        return cache
    }

    /// El ratón está en `point` (coordenadas de la vista del terminal).
    func hoverBlock(at point: NSPoint) {
        guard view.bounds.contains(point), let screen = viewport(), !screen.isAlternate else { return hideBlock() }
        let height = view.caretFrame.height
        guard height > 0 else { return hideBlock() }
        // La vista del terminal tiene el origen abajo: la fila 0 de la pantalla es la de arriba.
        let topEdge = view.caretFrame.maxY + CGFloat(screen.cursorRow - screen.top) * height
        let row = screen.top + Int(floor((topEdge - point.y) / height))
        guard let block = blocks.block(at: row, cursorRow: screen.cursorRow),
              AIAgent.detect(command: block.command) == nil else { return hideBlock() }
        // Si la fila del comando está a la vista y ya no lo contiene, el bloque es de antes de un `clear`.
        if let text = screen.rows[block.startRow],
           !text.contains(String(block.command.prefix(24)).trimmingCharacters(in: .whitespaces)) { return hideBlock() }
        let first = max(block.startRow, screen.top)
        let last = min(block.endRow ?? screen.cursorRow, screen.top + screen.rowCount - 1)
        guard last >= first else { return hideBlock() }
        let rect = NSRect(x: 0, y: topEdge - CGFloat(last - screen.top + 1) * height,
                          width: view.bounds.width, height: CGFloat(last - first + 1) * height)
        let overlay = blockOverlay ?? makeOverlay()
        overlay.show(block, in: rect, session: self)
    }

    func hideBlock() {
        blockOverlay?.hide()
    }

    private func makeOverlay() -> BlockOverlay {
        let overlay = BlockOverlay(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        blockOverlay = overlay
        return overlay
    }

    // MARK: Acciones

    func output(of block: CommandBlock) -> String {
        let end = block.endRow ?? (terminalCursor?.row ?? block.startRow)
        guard end > block.startRow,
              let snapshot = view.terminalContentSnapshot(region: .rows((block.startRow + 1)..<(end + 1)), buffer: .normal) else { return "" }
        // Las primeras filas pueden ser la continuación de un comando largo.
        let rows = snapshot.rows.drop { $0.isWrapped }.map { (text: $0.text, isWrapped: $0.isWrapped) }
        return CommandBlocks.text(of: Array(rows))
    }

    func copyOutput(of block: CommandBlock) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output(of: block), forType: .string)
    }

    func copyCommand(of block: CommandBlock) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.command, forType: .string)
    }

    func askClaude(about block: CommandBlock) {
        askClaude(command: block.command, exit: block.exit, output: String(output(of: block).suffix(12_000)), directory: block.directory)
    }

    func rerun(_ block: CommandBlock) {
        guard atPrompt else { return }
        run(block.directory == cwd ? block.command : "cd \(Tokenizer.escape(block.directory)) && \(block.command)")
    }

    /// Edición → Copiar salida del último comando (⌥⌘C).
    func copyLastOutput() {
        guard let block = blocks.all.last(where: { !$0.isRunning }) ?? blocks.last else { return }
        copyOutput(of: block)
    }
}
