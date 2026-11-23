import FaroCore
import SwiftUI

/// Texto fantasma en la posición del cursor y lista de sugerencias justo debajo (o encima).
struct SuggestionOverlay: View {
    /// Dónde empieza la palabra que se está escribiendo (para alinear la lista con ella).
    private func promptStart(_ session: TerminalSession) -> Int {
        // Si las sugerencias son la línea entera («git status»), la lista empieza donde la línea.
        if let first = session.suggestions.first, first.title.hasPrefix(session.buffer) { return 0 }
        let upToCursor = session.buffer.prefix(session.cursor)
        guard let space = upToCursor.lastIndex(of: " ") else { return 0 }
        return upToCursor.distance(from: upToCursor.startIndex, to: space) + 1
    }

    let session: TerminalSession
    @Environment(\.palette) private var palette
    private var settings: FaroSettings { AppModel.shared.settings }

    var body: some View {
        GeometryReader { geo in
            let caret = session.caret
            ZStack(alignment: .topLeading) {
                if let ghost = session.ghost, caret.width > 0, session.atPrompt {
                    Text(ghost)
                        .font(Font(Fonts.terminal(name: settings.fontName, size: settings.fontSize)))
                        .foregroundStyle(palette.text.opacity(0.35))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: caret.height, alignment: .center)
                        .offset(x: caret.minX, y: caret.minY)
                        .allowsHitTesting(false)
                }
                if session.popupVisible, !session.suggestions.isEmpty, caret.width > 0 {
                    let width = min(460, geo.size.width - 8)
                    let height = CGFloat(min(session.suggestions.count, SuggestionList.maxRows)) * SuggestionList.rowHeight + 4
                    let below = caret.maxY + 6 + height < geo.size.height
                    let start = caret.minX - CGFloat(session.cursor - promptStart(session)) * caret.width
                    SuggestionList(session: session)
                        .offset(x: max(0, min(start - 4, geo.size.width - width)),
                                y: below ? caret.maxY + 2 : max(0, caret.minY - height - 2))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.08), value: session.popupVisible)
        }
    }
}

/// Lista de sugerencias: solo texto, en la tipografía de la interfaz, alineado justo debajo de
/// lo que escribes. Detrás lleva el mismo color del terminal, así que no se ve como un panel.
struct SuggestionList: View {
    static let maxRows = 6
    static let rowHeight: CGFloat = 22
    let session: TerminalSession
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.suggestions.prefix(Self.maxRows).enumerated()), id: \.element.id) { index, s in
                let selected = index == session.selectedIndex
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    highlighted(s.title, typed: typedPart(s), selected: selected)
                        .font(.ui(13.5, selected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(s.detail)
                        .font(.ui(12))
                        .foregroundStyle(palette.tertiaryText.opacity(selected ? 1 : 0.75))
                        .lineLimit(1)
                    if selected {
                        Text("tab")
                            .font(.ui(11))
                            .foregroundStyle(palette.tertiaryText.opacity(0.7))
                    }
                }
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    session.selectedIndex = index
                    session.accept(s)
                    session.window?.focusTerminal()
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .fixedSize()
        .background(palette.background)
    }

    private func typedPart(_ s: Suggestion) -> String {
        let buffer = session.buffer
        if s.title == s.replacement, s.title.hasPrefix(buffer) { return buffer }
        let word = Tokenizer(buffer).lastWordUnescaped
        let name = word.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? word
        return s.title.lowercased().hasPrefix(name.lowercased()) ? String(s.title.prefix(name.count)) : ""
    }

    private func highlighted(_ title: String, typed: String, selected: Bool) -> Text {
        let rest = String(title.dropFirst(typed.count))
        return Text(typed).foregroundStyle(selected ? palette.accent : palette.tertiaryText)
            + Text(rest).foregroundStyle(selected ? palette.text : palette.secondaryText)
    }
}
