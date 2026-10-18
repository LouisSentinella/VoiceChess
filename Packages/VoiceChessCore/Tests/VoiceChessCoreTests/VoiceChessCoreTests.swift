import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VoiceChessCore

private let stateJSON = """
{"id":"5pP1UBl9","player":"white","opponent":{"type":"maia","level":1500},
 "fen":"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1","turn":"black","your_turn":false,
 "moves":["e4"],"last_move":"e4","last_move_uci":"e2e4","legal_moves":["Nf6"],"legal_moves_uci":["g8f6"],
 "in_check":false,"game_over":false,"result":null,"termination":null,"spoken_result":null}
"""

private func moveJSON(san: String, spoken: String) -> String {
    """
    {"san":"\(san)","uci":"g1f3","piece":"knight","from":"g1","to":"f3","capture":false,
     "castle":null,"promotion":null,"check":false,"checkmate":false,"spoken":"\(spoken)"}
    """
}

private func decodeSay(_ json: String) throws -> SayResponse {
    try JSONDecoder().decode(SayResponse.self, from: Data(json.utf8))
}

final class ModelTests: XCTestCase {
    func testSayResponseStatuses() throws {
        let played = try decodeSay("""
        {"status":"played","player_move":\(moveJSON(san: "Nf3", spoken: "Knight to f3")),
         "bot_move":null,"state":\(stateJSON)}
        """)
        guard case let .played(result) = played else { return XCTFail("expected played, got \(played)") }
        XCTAssertEqual(result.playerMove.spoken, "Knight to f3")
        XCTAssertNil(result.botMove)
        XCTAssertEqual(result.state.id, "5pP1UBl9")
        XCTAssertEqual(result.state.legalMovesUci, ["g8f6"])
        XCTAssertEqual(result.state.opponent.level, 1500)
        XCTAssertNil(result.state.spokenResult)

        XCTAssertEqual(
            try decodeSay(#"{"status":"confirm","candidate":{"san":"Nf3","spoken":"Knight to f3"},"message":"Play knight to f3?"}"#),
            .confirm(candidate: MoveCandidate(san: "Nf3", spoken: "Knight to f3"), message: "Play knight to f3?"))

        XCTAssertEqual(
            try decodeSay(#"{"status":"ambiguous","message":"Did you mean knight to d2 or knight to f3?","candidates":[{"san":"Nbd2","spoken":"Knight b to d2"},{"san":"Nfd2","spoken":"Knight f to d2"}]}"#),
            .ambiguous(message: "Did you mean knight to d2 or knight to f3?", candidates: [
                MoveCandidate(san: "Nbd2", spoken: "Knight b to d2"),
                MoveCandidate(san: "Nfd2", spoken: "Knight f to d2"),
            ]))

        XCTAssertEqual(
            try decodeSay(#"{"status":"no_match","message":"I did not catch a legal move."}"#),
            .noMatch(message: "I did not catch a legal move."))

        XCTAssertThrowsError(try decodeSay(#"{"status":"bogus"}"#))
    }

    func testBoardReadAndHints() throws {
        let board = try JSONDecoder().decode(BoardRead.self, from: Data(
            #"{"player":"white","pieces":{"white":{"king":["e1"]},"black":{"king":["e8"]}},"spoken":{"white":"king e1","black":"king e8"}}"#.utf8))
        XCTAssertEqual(board.spoken["white"], "king e1")
        XCTAssertEqual(board.pieces["black"]?["king"], ["e8"])
        let hints = try JSONDecoder().decode(Hints.self, from: Data(#"{"phrases":["castle kingside"]}"#.utf8))
        XCTAssertEqual(hints.phrases, ["castle kingside"])
    }
}

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = StubProtocol.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "http://example.test")!, session: URLSession(configuration: config))
    }

    func testSuccessRequestShape() async throws {
        var seen: URLRequest?
        StubProtocol.handler = { request in
            seen = request
            return (200, Data(stateJSON.utf8))
        }
        let state = try await makeClient().state(gameID: "abc")
        XCTAssertEqual(seen?.httpMethod, "GET")
        XCTAssertEqual(seen?.url?.path, "/game/abc/state")
        XCTAssertEqual(state.turn, "black")
    }

    func testErrorsCarryServerDetail() async {
        let client = makeClient()

        StubProtocol.handler = { _ in (409, Data(#"{"detail":"Not your turn"}"#.utf8)) }
        do {
            _ = try await client.state(gameID: "abc")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 409, detail: "Not your turn"))
        }

        StubProtocol.handler = { _ in
            (422, Data(#"{"detail":{"error":"illegal","message":"Nf3 is illegal here","candidates":[]}}"#.utf8))
        }
        do {
            _ = try await client.move(gameID: "abc", move: "Nf3")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 422, detail: "Nf3 is illegal here"))
        }

        StubProtocol.handler = { _ in (204, Data()) }
        do {
            try await client.deleteGame(gameID: "abc")
        } catch {
            XCTFail("204 must succeed: \(error)")
        }
    }
}

final class PhraseTests: XCTestCase {
    func testYesNo() {
        for text in ["Yes", "yeah!", "Yep.", "correct", "Play it", "yes, play it", "confirm"] {
            XCTAssertEqual(YesNo.parse(text), .yes, text)
        }
        for text in ["No", "nope", "Cancel", "wrong", "negative", "that's not correct", "don't play it"] {
            XCTAssertEqual(YesNo.parse(text), .no, text)
        }
        XCTAssertNil(YesNo.parse("knight f three"))
        XCTAssertNil(YesNo.parse(""))
    }

    func testVoiceCommands() {
        XCTAssertEqual(VoiceCommand.parse("Read the board"), .readBoard)
        XCTAssertEqual(VoiceCommand.parse("read my pieces please"), .readMyPieces)
        XCTAssertEqual(VoiceCommand.parse("say that again"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("Repeat"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("new game"), .newGame)
        XCTAssertNil(VoiceCommand.parse("knight to f three"))
    }
}

final class BoardPositionTests: XCTestCase {
    private func square(_ name: String) -> Int { BoardPosition.squareIndex(name)! }

    func testStartPosition() throws {
        let board = try XCTUnwrap(BoardPosition(fen: BoardPosition.startFEN))
        XCTAssertEqual(board.squares.count, 64)
        XCTAssertEqual(board.sideToMove, .white)
        XCTAssertEqual(board.squares.compactMap { $0 }.count, 32)
        XCTAssertEqual(board.piece(at: square("a1")), Piece(kind: .rook, color: .white))
        XCTAssertEqual(board.piece(at: square("e1")), Piece(kind: .king, color: .white))
        XCTAssertEqual(board.piece(at: square("d1")), Piece(kind: .queen, color: .white))
        XCTAssertEqual(board.piece(at: square("e2")), Piece(kind: .pawn, color: .white))
        XCTAssertNil(board.piece(at: square("e4")))
        XCTAssertEqual(board.piece(at: square("b8")), Piece(kind: .knight, color: .black))
        XCTAssertEqual(board.piece(at: square("c8")), Piece(kind: .bishop, color: .black))
        XCTAssertEqual(board.piece(at: square("e8")), Piece(kind: .king, color: .black))
        XCTAssertEqual(board.piece(at: square("h7")), Piece(kind: .pawn, color: .black))
        XCTAssertNil(board.checkSquare)
        XCTAssertNil(board.lastMove)
        XCTAssertEqual(BoardPosition.start, board)
    }

    func testMidGamePositionWithCheckAndLastMove() throws {
        // 1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6 8. c3 O-O 9. h3 Nb8 10. Qh5 Nbd7 11. Qxf7+
        let fen = "r1bq1rk1/2pn1Qpp/p2p1n2/1p2p3/4P3/1BP2N1P/PP1P1PP1/RNB1R1K1 b - - 0 11"
        let board = try XCTUnwrap(BoardPosition(fen: fen, inCheck: false, lastMoveUci: "h5f7"))
        XCTAssertEqual(board.sideToMove, .black)
        XCTAssertEqual(board.piece(at: square("f7")), Piece(kind: .queen, color: .white))
        XCTAssertEqual(board.piece(at: square("g8")), Piece(kind: .king, color: .black))
        XCTAssertEqual(board.piece(at: square("g1")), Piece(kind: .king, color: .white))
        XCTAssertNil(board.piece(at: square("h5")))
        XCTAssertEqual(board.lastMove, LastMove(from: square("h5"), to: square("f7")))
        XCTAssertNil(board.checkSquare)

        // The in_check flag marks the side to move's king.
        let checked = try XCTUnwrap(BoardPosition(fen: fen, inCheck: true, lastMoveUci: "h5f7"))
        XCTAssertEqual(checked.checkSquare, square("g8"))
        let whiteChecked = try XCTUnwrap(BoardPosition(
            fen: "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1", inCheck: true))
        XCTAssertEqual(whiteChecked.checkSquare, square("e1"))
    }

    func testEnPassantCastlingAndCountersAreIgnoredSafely() throws {
        let withEP = try XCTUnwrap(BoardPosition(fen: "rnbqkbnr/pppp1ppp/8/4pP2/8/8/PPPPP1PP/RNBQKBNR w KQkq e6 0 3"))
        XCTAssertEqual(withEP.piece(at: square("e5")), Piece(kind: .pawn, color: .black))
        XCTAssertEqual(withEP.piece(at: square("f5")), Piece(kind: .pawn, color: .white))
        XCTAssertEqual(withEP.sideToMove, .white)

        let noRights = try XCTUnwrap(BoardPosition(fen: "4k3/8/8/8/8/8/8/4K2R b - - 12 40"))
        XCTAssertEqual(noRights.squares.compactMap { $0 }.count, 3)

        // Trailing fields are optional and garbage in them does not matter.
        let sparse = try XCTUnwrap(BoardPosition(fen: "4k3/8/8/8/8/8/8/4K3 w"))
        XCTAssertEqual(sparse.sideToMove, .white)
        XCTAssertNotNil(BoardPosition(fen: "4k3/8/8/8/8/8/8/4K3 w ??? ??? x y z"))
        XCTAssertNotNil(BoardPosition(fen: "  4k3/8/8/8/8/8/8/4K3   b  "))
    }

    func testMalformedFENIsNil() {
        let bad = [
            "",
            "garbage",
            "8/8/8/8/8/8/8 w - - 0 1",
            "8/8/8/8/8/8/8/8/8 w - - 0 1",
            "9/8/8/8/8/8/8/8 w - - 0 1",
            "ppppppppp/8/8/8/8/8/8/8 w - - 0 1",
            "7/8/8/8/8/8/8/8 w - - 0 1",
            "4k3/8/8/8/8/8/8/4X3 w - - 0 1",
            "4k3/8/8/8/8/8/8/4K3",
            "4k3/8/8/8/8/8/8/4K3 x - - 0 1",
            "4k3//8/8/8/8/8/4K3 w - - 0 1",
        ]
        for fen in bad {
            XCTAssertNil(BoardPosition(fen: fen), fen)
        }
    }

    func testLastMoveParsing() throws {
        let fen = "4k3/8/8/8/8/8/8/4K3 w - - 0 1"
        XCTAssertEqual(
            try XCTUnwrap(BoardPosition(fen: fen, lastMoveUci: "e7e8q")).lastMove,
            LastMove(from: square("e7"), to: square("e8")))
        XCTAssertEqual(
            try XCTUnwrap(BoardPosition(fen: fen, lastMoveUci: "e1g1")).lastMove,
            LastMove(from: square("e1"), to: square("g1")))
        for uci in ["0000", "", "e2", "z9e4", "e2e9", "e2e4qq"] {
            XCTAssertNil(BoardPosition(fen: fen, lastMoveUci: uci)?.lastMove, uci)
        }
        XCTAssertNil(BoardPosition(fen: fen, lastMoveUci: nil)?.lastMove)
    }

    func testPositionFromGameState() throws {
        let state = try JSONDecoder().decode(GameState.self, from: Data(stateJSON.utf8))
        let board = try XCTUnwrap(BoardPosition(state: state))
        XCTAssertEqual(board.sideToMove, .black)
        XCTAssertEqual(board.piece(at: square("e4")), Piece(kind: .pawn, color: .white))
        XCTAssertEqual(board.lastMove, LastMove(from: square("e2"), to: square("e4")))
        XCTAssertNil(board.checkSquare)
    }

    func testSquareIndex() {
        XCTAssertEqual(BoardPosition.squareIndex("a1"), 0)
        XCTAssertEqual(BoardPosition.squareIndex("h1"), 7)
        XCTAssertEqual(BoardPosition.squareIndex("a8"), 56)
        XCTAssertEqual(BoardPosition.squareIndex("h8"), 63)
        XCTAssertNil(BoardPosition.squareIndex("i1"))
        XCTAssertNil(BoardPosition.squareIndex("a9"))
        XCTAssertNil(BoardPosition.squareIndex("a"))
    }

    func testRecentMoveList() {
        XCTAssertEqual(MoveList.recent([]), "")
        XCTAssertEqual(MoveList.recent(["e4", "e5", "Nf3"]), "1. e4 e5 2. Nf3")
        let moves = ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"]
        XCTAssertEqual(MoveList.recent(moves, plies: 3), "… 2... Nc6 3. Bb5 a6")
        XCTAssertEqual(MoveList.recent(moves, plies: 4), "… 3. Bb5 a6")
        XCTAssertEqual(MoveList.recent(moves, plies: 6), "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")
    }
}

final class TTSClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "http://example.test")!, session: URLSession(configuration: config))
    }

    private func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testTTSRequestAndResponse() async throws {
        var seen: URLRequest?
        let wav = Data([0x52, 0x49, 0x46, 0x46, 1, 2, 3])
        StubProtocol.handler = { request in
            seen = request
            return (200, wav)
        }
        let data = try await makeClient().tts(text: "Knight to f3", voice: "af_heart")
        XCTAssertEqual(data, wav)
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.path, "/tts")
        XCTAssertEqual(seen?.timeoutInterval, 2.5)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Accept"), "audio/wav")
        let body = try XCTUnwrap(seen.flatMap(bodyData))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "Knight to f3")
        XCTAssertEqual(object["voice"] as? String, "af_heart")
        XCTAssertEqual(object["speed"] as? Double, 1.0)

        _ = try await makeClient().tts(text: "Hi", voice: nil)
        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen.flatMap(bodyData))) as? [String: Any])
        XCTAssertNil(bare["voice"])
    }

    func testTTSUnavailableAndVoices() async throws {
        StubProtocol.handler = { _ in (503, Data(#"{"detail":"TTS model not installed"}"#.utf8)) }
        do {
            _ = try await makeClient().tts(text: "Hi", voice: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 503, detail: "TTS model not installed"))
        }

        StubProtocol.handler = { _ in (200, Data(#"{"voices":["af_heart","bf_emma"],"default":"af_heart"}"#.utf8)) }
        let voices = try await makeClient().ttsVoices()
        XCTAssertEqual(voices, TTSVoices(voices: ["af_heart", "bf_emma"], defaultVoice: "af_heart"))
    }
}
