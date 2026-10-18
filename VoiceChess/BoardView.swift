import SwiftUI
import VoiceChessCore

/// An 8x8 board that fills the width it is given. `flipped` puts black at the bottom.
struct BoardView: View {
    let position: BoardPosition
    let flipped: Bool

    private static let lightSquare = Color(red: 0.53, green: 0.58, blue: 0.65)
    private static let darkSquare = Color(red: 0.29, green: 0.34, blue: 0.42)
    private static let files = ["a", "b", "c", "d", "e", "f", "g", "h"]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { column in
                            square(row: row, column: column, size: side / 8)
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func square(row: Int, column: Int, size: CGFloat) -> some View {
        let rank = flipped ? row : 7 - row
        let file = flipped ? 7 - column : column
        let index = rank * 8 + file
        let isLight = (rank + file) % 2 == 1
        let labelColor = (isLight ? Self.darkSquare : Self.lightSquare).opacity(0.95)
        let labelFont = Font.system(size: max(8, size * 0.2), weight: .bold)
        return ZStack {
            Rectangle().fill(isLight ? Self.lightSquare : Self.darkSquare)
            if let last = position.lastMove, index == last.from || index == last.to {
                Rectangle().fill(Color.yellow.opacity(0.38))
            }
            if position.checkSquare == index {
                Rectangle().fill(RadialGradient(
                    colors: [Color.red.opacity(0.9), Color.red.opacity(0.35)],
                    center: .center, startRadius: 0, endRadius: size * 0.75))
            }
            if let piece = position.piece(at: index) {
                PieceGlyph(piece: piece, size: size)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if column == 0 {
                Text("\(rank + 1)").font(labelFont).foregroundStyle(labelColor).padding(.leading, 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if row == 7 {
                Text(Self.files[file]).font(labelFont).foregroundStyle(labelColor).padding(.trailing, 2)
            }
        }
    }
}

/// A piece drawn with the solid Unicode glyph for both colours, tinted white or near-black
/// with a thin contrasting outline so either side reads on either square colour.
private struct PieceGlyph: View {
    let piece: Piece
    let size: CGFloat

    var body: some View {
        let isWhite = piece.color == .white
        let fill = isWhite ? Color.white : Color(white: 0.08)
        let outline = isWhite ? Color(white: 0.05) : Color(white: 0.92)
        let offset = max(0.8, size * 0.022)
        Text(glyph)
            .font(.system(size: size * 0.8))
            .lineLimit(1)
            .foregroundStyle(fill)
            .shadow(color: outline, radius: 0, x: offset, y: 0)
            .shadow(color: outline, radius: 0, x: -offset, y: 0)
            .shadow(color: outline, radius: 0, x: 0, y: offset)
            .shadow(color: outline, radius: 0, x: 0, y: -offset)
            .accessibilityHidden(true)
    }

    private var glyph: String {
        switch piece.kind {
        case .king: return "\u{265A}"
        case .queen: return "\u{265B}"
        case .rook: return "\u{265C}"
        case .bishop: return "\u{265D}"
        case .knight: return "\u{265E}"
        // U+FE0E forces text presentation so the pawn never renders as an emoji.
        case .pawn: return "\u{265F}\u{FE0E}"
        }
    }
}
