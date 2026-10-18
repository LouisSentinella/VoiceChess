import Foundation

public enum PieceColor: String, Sendable {
    case white, black
}

public enum PieceKind: Sendable {
    case king, queen, rook, bishop, knight, pawn
}

public struct Piece: Equatable, Sendable {
    public let kind: PieceKind
    public let color: PieceColor

    public init(kind: PieceKind, color: PieceColor) {
        self.kind = kind
        self.color = color
    }

    init?(fenCharacter character: Character) {
        let kind: PieceKind
        switch character.lowercased() {
        case "k": kind = .king
        case "q": kind = .queen
        case "r": kind = .rook
        case "b": kind = .bishop
        case "n": kind = .knight
        case "p": kind = .pawn
        default: return nil
        }
        self.init(kind: kind, color: character.isUppercase ? .white : .black)
    }
}

/// Origin and destination square indices of the last move played.
public struct LastMove: Equatable, Sendable {
    public let from: Int
    public let to: Int
}

/// A board position parsed from FEN, plus the display hints the server state provides
/// (side in check, last move). Square indices run a1 = 0, b1 = 1 ... h8 = 63 (`rank * 8 + file`).
public struct BoardPosition: Equatable, Sendable {
    public static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public static let start = BoardPosition(fen: startFEN)!

    public let squares: [Piece?]
    public let sideToMove: PieceColor
    /// Square of the king that is in check (the side to move's king), if the position is a check.
    public let checkSquare: Int?
    public let lastMove: LastMove?

    /// Parses the piece placement and side-to-move fields. Castling rights, en passant, and the
    /// move counters are not needed for display and are ignored. Returns nil for malformed FEN.
    /// `inCheck` is the server's flag; the king in check is the side to move's king.
    public init?(fen: String, inCheck: Bool = false, lastMoveUci: String? = nil) {
        let fields = fen.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else { return nil }

        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { return nil }
        var squares = [Piece?](repeating: nil, count: 64)
        for (row, rankText) in ranks.enumerated() {
            let rank = 7 - row
            var file = 0
            for character in rankText {
                if let ascii = character.asciiValue, (49...56).contains(ascii) {
                    file += Int(ascii) - 48
                } else if let piece = Piece(fenCharacter: character), file < 8 {
                    squares[rank * 8 + file] = piece
                    file += 1
                } else {
                    return nil
                }
                guard file <= 8 else { return nil }
            }
            guard file == 8 else { return nil }
        }

        switch fields[1] {
        case "w": sideToMove = .white
        case "b": sideToMove = .black
        default: return nil
        }
        self.squares = squares

        if inCheck {
            let king = Piece(kind: .king, color: sideToMove)
            checkSquare = squares.firstIndex { $0 == king }
        } else {
            checkSquare = nil
        }
        lastMove = lastMoveUci.flatMap(Self.parseUci)
    }

    public init?(state: GameState) {
        self.init(fen: state.fen, inCheck: state.inCheck, lastMoveUci: state.lastMoveUci)
    }

    public func piece(at index: Int) -> Piece? {
        squares[index]
    }

    /// "e4" -> 28; nil for anything that is not a square name.
    public static func squareIndex(_ name: String) -> Int? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 2,
              (97...104).contains(scalars[0].value),
              (49...56).contains(scalars[1].value) else { return nil }
        return Int(scalars[1].value - 49) * 8 + Int(scalars[0].value - 97)
    }

    /// "e2e4" or "e7e8q" -> squares; malformed input (including "0000") is nil.
    private static func parseUci(_ uci: String) -> LastMove? {
        guard uci.count == 4 || uci.count == 5,
              let from = squareIndex(String(uci.prefix(2))),
              let to = squareIndex(String(uci.dropFirst(2).prefix(2))) else { return nil }
        return LastMove(from: from, to: to)
    }
}

public enum MoveList {
    /// The last `plies` half-moves as numbered SAN, e.g. "1. e4 e5 2. Nf3" or "… 2... Nc6 3. Bb5".
    public static func recent(_ moves: [String], plies: Int = 8) -> String {
        guard !moves.isEmpty else { return "" }
        let start = max(0, moves.count - plies)
        var parts: [String] = []
        for index in start..<moves.count {
            let number = index / 2 + 1
            if index % 2 == 0 {
                parts.append("\(number).")
            } else if index == start {
                parts.append("\(number)...")
            }
            parts.append(moves[index])
        }
        return (start > 0 ? "… " : "") + parts.joined(separator: " ")
    }
}
