import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failure of an API call. `server` carries the HTTP status and the server's `detail` message.
public enum APIError: Error, Equatable, LocalizedError {
    case server(status: Int, detail: String)
    case unreachable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .server(status, detail): return "Server error \(status): \(detail)"
        case let .unreachable(reason): return "Cannot reach the server: \(reason)"
        case let .invalidResponse(reason): return "Unexpected server response: \(reason)"
        }
    }
}

public enum SidePreference: String, Codable, Sendable, CaseIterable {
    case white, black, random
}

public struct APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let log: (@Sendable (String) -> Void)?

    /// `log` receives one line per HTTP call (method, path, status, latency).
    public init(baseURL: URL, session: URLSession = .shared, log: (@Sendable (String) -> Void)? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.log = log
    }

    // MARK: Endpoints

    public func newGame(side: SidePreference = .random, opponent: String = "maia", level: Int? = nil) async throws -> NewGameResult {
        struct Body: Encodable { let side: String; let opponent: String; let level: Int? }
        let body = try JSONEncoder().encode(Body(side: side.rawValue, opponent: opponent, level: level))
        return try await request("POST", "game", body: body)
    }

    public func say(gameID: String, transcript: String, confirm: Bool) async throws -> SayResponse {
        struct Body: Encodable { let transcript: String; let confirm: Bool }
        let body = try JSONEncoder().encode(Body(transcript: transcript, confirm: confirm))
        return try await request("POST", "game/\(gameID)/say", body: body)
    }

    /// `move` is SAN or UCI.
    public func move(gameID: String, move: String) async throws -> MoveResult {
        struct Body: Encodable { let move: String }
        let body = try JSONEncoder().encode(Body(move: move))
        return try await request("POST", "game/\(gameID)/move", body: body)
    }

    public func state(gameID: String) async throws -> GameState {
        try await request("GET", "game/\(gameID)/state")
    }

    public func hints(gameID: String) async throws -> Hints {
        try await request("GET", "game/\(gameID)/hints")
    }

    public func boardRead(gameID: String) async throws -> BoardRead {
        try await request("GET", "game/\(gameID)/board/read")
    }

    public func deleteGame(gameID: String) async throws {
        _ = try await perform("DELETE", "game/\(gameID)", body: nil)
    }

    /// Synthesizes `text` on the server; returns WAV bytes. `voice` nil means the server default.
    /// `timeout` bounds the wait for the server to respond.
    public func tts(text: String, voice: String?, speed: Double = 1.0, timeout: TimeInterval = 2.5) async throws -> Data {
        struct Body: Encodable { let text: String; let voice: String?; let speed: Double }
        let body = try JSONEncoder().encode(Body(text: text, voice: voice, speed: speed))
        return try await perform("POST", "tts", body: body, accept: "audio/wav", timeout: timeout)
    }

    public func ttsVoices() async throws -> TTSVoices {
        try await request("GET", "tts/voices")
    }

    /// Streams the coach's answer to `question` (docs/api.md "/ask stream"). The stream finishes after
    /// `.done` or `.error`, and throws if the request fails or the connection ends before either.
    /// Terminating the stream cancels the request. Logs the start, the first-sentence latency and the total.
    public func ask(gameID: String, question: String) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamAsk(gameID: gameID, question: question) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transport

    private func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        let data = try await perform(method, path, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log?("\(method) /\(path) decode failed: \(error)")
            throw APIError.invalidResponse(String(describing: error))
        }
    }

    private func perform(
        _ method: String, _ path: String, body: Data?,
        accept: String = "application/json", timeout: TimeInterval = 30
    ) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue(accept, forHTTPHeaderField: "Accept")

        let started = Date()
        func elapsed() -> String { "\(Int(Date().timeIntervalSince(started) * 1000)) ms" }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await fetch(req)
        } catch {
            log?("\(method) /\(path) failed after \(elapsed()): \(error.localizedDescription)")
            if let apiError = error as? APIError { throw apiError }
            throw APIError.unreachable(error.localizedDescription)
        }
        log?("\(method) /\(path) -> \(http.statusCode) in \(elapsed())")
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, detail: Self.detail(from: data, status: http.statusCode))
        }
        return data
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: APIError.invalidResponse("not an HTTP response"))
                }
            }.resume()
        }
    }

    /// Extracts a human-readable message from FastAPI's `{"detail": ...}` error bodies.
    static func detail(from data: Data, status: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] else {
            return "HTTP \(status)"
        }
        if let text = detail as? String { return text }
        if let dict = detail as? [String: Any], let message = dict["message"] as? String { return message }
        if let raw = try? JSONSerialization.data(withJSONObject: detail), let text = String(data: raw, encoding: .utf8) {
            return text
        }
        return "HTTP \(status)"
    }

    private func streamAsk(gameID: String, question: String, emit: (AskEvent) -> Void) async throws {
        struct Body: Encodable { let question: String }
        let path = "game/\(gameID)/ask"
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpBody = try JSONEncoder().encode(Body(question: question))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")

        let started = Date()
        func elapsed() -> String { "\(Int(Date().timeIntervalSince(started) * 1000)) ms" }
        var sentences = 0
        var finished = false
        func handle(_ line: String) throws {
            guard !finished, let event = try AskEventDecoder.decode(line: line) else { return }
            switch event {
            case .sentence:
                sentences += 1
                if sentences == 1 { log?("POST /\(path) first sentence after \(elapsed())") }
            case .done, .error:
                finished = true
            }
            emit(event)
        }

        log?("POST /\(path) started (\(question.count) characters)")
        do {
            #if canImport(FoundationNetworking)
            // No streaming URLSession API on Linux: read the whole body, then split it into lines.
            let (data, http) = try await fetch(req)
            log?("POST /\(path) -> \(http.statusCode) after \(elapsed())")
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server(status: http.statusCode, detail: Self.detail(from: data, status: http.statusCode))
            }
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                try handle(String(line))
            }
            #else
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse("not an HTTP response") }
            log?("POST /\(path) -> \(http.statusCode) after \(elapsed())")
            guard (200..<300).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 4096 { break }
                }
                throw APIError.server(status: http.statusCode, detail: Self.detail(from: body, status: http.statusCode))
            }
            for try await line in bytes.lines {
                try handle(line)
                if finished { break }
            }
            #endif
            guard finished else { throw APIError.invalidResponse("stream ended before done") }
        } catch {
            if error is CancellationError || Task.isCancelled {
                log?("POST /\(path) cancelled after \(elapsed()) (\(sentences) sentences)")
                throw CancellationError()
            }
            log?("POST /\(path) failed after \(elapsed()) (\(sentences) sentences): \(error.localizedDescription)")
            if let apiError = error as? APIError { throw apiError }
            throw APIError.unreachable(error.localizedDescription)
        }
        log?("POST /\(path) finished: \(sentences) sentences in \(elapsed())")
    }
}
