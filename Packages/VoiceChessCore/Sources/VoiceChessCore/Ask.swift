import Foundation

/// One event of the `POST /game/{id}/ask` NDJSON stream (docs/api.md "/ask stream").
public enum AskEvent: Equatable, Sendable {
    /// A plain-text sentence to speak.
    case sentence(String)
    /// The answer is complete.
    case done
    /// User-readable failure that replaces `done`; speak it and stop.
    case error(String)
}

/// Decodes one line of the `/ask` stream at a time.
public enum AskEventDecoder {
    private struct Wire: Decodable {
        let type: String
        let text: String?
        let message: String?
    }

    /// Returns nil for lines that carry no event: blank lines, unknown `type` values (so the server
    /// can add event types later) and sentences without speakable text.
    /// Throws `APIError.invalidResponse` when the line is not a valid event object.
    public static func decode(line: String) throws -> AskEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8))
        } catch {
            throw APIError.invalidResponse("bad ask stream line: \(trimmed.prefix(120))")
        }
        switch wire.type {
        case "sentence":
            guard let text = wire.text else { throw APIError.invalidResponse("sentence without text") }
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return spoken.isEmpty ? nil : .sentence(spoken)
        case "done":
            return .done
        case "error":
            guard let message = wire.message else { throw APIError.invalidResponse("error without message") }
            return .error(message)
        default:
            return nil
        }
    }
}
