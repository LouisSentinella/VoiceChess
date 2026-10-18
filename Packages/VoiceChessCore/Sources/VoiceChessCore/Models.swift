import Foundation

/// One move in the short announcement form the server provides (docs/api.md `MoveInfo`).
public struct MoveInfo: Codable, Equatable, Sendable {
    public let san: String
    public let uci: String
    public let piece: String
    public let from: String
    public let to: String
    public let capture: Bool
    /// "kingside", "queenside" or nil.
    public let castle: String?
    public let promotion: String?
    public let check: Bool
    public let checkmate: Bool
    /// Spoken verbatim by the app, e.g. "Knight to f3".
    public let spoken: String
}

public struct Opponent: Codable, Equatable, Sendable {
    public let type: String
    public let level: Int?
}

public struct GameState: Codable, Equatable, Sendable {
    public let id: String
    public let player: String
    public let opponent: Opponent
    public let fen: String
    public let turn: String
    public let yourTurn: Bool
    public let moves: [String]
    public let lastMove: String?
    public let lastMoveUci: String?
    public let legalMoves: [String]
    public let legalMovesUci: [String]
    public let inCheck: Bool
    public let gameOver: Bool
    /// "1-0", "0-1", "1/2-1/2" or nil.
    public let result: String?
    public let termination: String?
    /// nil while the game runs, else a sentence to speak.
    public let spokenResult: String?

    enum CodingKeys: String, CodingKey {
        case id, player, opponent, fen, turn, moves, result, termination
        case yourTurn = "your_turn"
        case lastMove = "last_move"
        case lastMoveUci = "last_move_uci"
        case legalMoves = "legal_moves"
        case legalMovesUci = "legal_moves_uci"
        case inCheck = "in_check"
        case gameOver = "game_over"
        case spokenResult = "spoken_result"
    }
}

/// Response of `POST /game`.
public struct NewGameResult: Codable, Equatable, Sendable {
    public let botMove: MoveInfo?
    public let state: GameState

    enum CodingKeys: String, CodingKey {
        case botMove = "bot_move"
        case state
    }
}

/// Response of `POST /game/{id}/move` and the payload of a `played` say outcome.
public struct MoveResult: Codable, Equatable, Sendable {
    public let playerMove: MoveInfo
    public let botMove: MoveInfo?
    public let state: GameState

    enum CodingKeys: String, CodingKey {
        case playerMove = "player_move"
        case botMove = "bot_move"
        case state
    }
}

public struct MoveCandidate: Codable, Equatable, Sendable {
    public let san: String
    public let spoken: String
}

/// Outcome of `POST /game/{id}/say` (always HTTP 200, discriminated by `status`).
public enum SayResponse: Equatable, Sendable, Decodable {
    case played(MoveResult)
    case confirm(candidate: MoveCandidate, message: String)
    case ambiguous(message: String, candidates: [MoveCandidate])
    case noMatch(message: String)

    private enum CodingKeys: String, CodingKey {
        case status, message, candidate, candidates
        case playerMove = "player_move"
        case botMove = "bot_move"
        case state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "played":
            self = .played(MoveResult(
                playerMove: try c.decode(MoveInfo.self, forKey: .playerMove),
                botMove: try c.decodeIfPresent(MoveInfo.self, forKey: .botMove),
                state: try c.decode(GameState.self, forKey: .state)))
        case "confirm":
            self = .confirm(
                candidate: try c.decode(MoveCandidate.self, forKey: .candidate),
                message: try c.decode(String.self, forKey: .message))
        case "ambiguous":
            self = .ambiguous(
                message: try c.decode(String.self, forKey: .message),
                candidates: try c.decode([MoveCandidate].self, forKey: .candidates))
        case "no_match":
            self = .noMatch(message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status, in: c, debugDescription: "Unknown say status '\(status)'")
        }
    }
}

/// Response of `GET /game/{id}/hints`.
public struct Hints: Codable, Equatable, Sendable {
    public let phrases: [String]
}

/// Response of `GET /game/{id}/board/read`.
public struct BoardRead: Codable, Equatable, Sendable {
    public let player: String
    /// color -> piece name -> squares
    public let pieces: [String: [String: [String]]]
    /// color -> sentence listing that side's pieces
    public let spoken: [String: String]
}

/// Response of `GET /tts/voices`.
public struct TTSVoices: Codable, Equatable, Sendable {
    public let voices: [String]
    public let defaultVoice: String

    enum CodingKeys: String, CodingKey {
        case voices
        case defaultVoice = "default"
    }
}
