import Foundation

/// One of the listener's own moves that lost material (docs/api.md "Review").
public struct ReviewMoment: Codable, Equatable, Sendable {
    /// 1-based; ply 1 is White's first move.
    public let ply: Int
    public let moveNumber: Int
    public let san: String
    /// The move as spoken, e.g. "Queen takes f7, check".
    public let spoken: String
    public let bestSan: String
    public let bestSpoken: String
    public let lossPawns: Double
    /// e.g. "a blunder".
    public let label: String
    /// The position the move was played from; the app shows it with `uci` highlighted.
    public let fenBefore: String
    public let fenAfter: String
    public let uci: String

    enum CodingKeys: String, CodingKey {
        case ply, san, spoken, label, uci
        case moveNumber = "move_number"
        case bestSan = "best_san"
        case bestSpoken = "best_spoken"
        case lossPawns = "loss_pawns"
        case fenBefore = "fen_before"
        case fenAfter = "fen_after"
    }
}

/// Response of `GET /game/{id}/review`. `moments` is empty when there was nothing to go through.
public struct Review: Codable, Equatable, Sendable {
    public let summary: String
    public let moments: [ReviewMoment]
}

/// One logged slip: an illegal attempt or a board lookup.
public struct LogEntry: Codable, Equatable, Sendable {
    /// ISO 8601 timestamp.
    public let time: String
    /// "illegal_attempt" or "lookup".
    public let kind: String
    public let detail: String
    public let game: String?
}

/// Response of `GET /log/summary` (docs/api.md "Mistake log").
public struct LogSummary: Codable, Equatable, Sendable {
    public let illegalAttempts: Int
    public let lookups: Int
    public let byPiece: [String: Int]
    public let bySquare: [String: Int]
    /// A sentence the app can read aloud.
    public let spoken: String
    public let recent: [LogEntry]

    enum CodingKeys: String, CodingKey {
        case lookups, spoken, recent
        case illegalAttempts = "illegal_attempts"
        case byPiece = "by_piece"
        case bySquare = "by_square"
    }
}
