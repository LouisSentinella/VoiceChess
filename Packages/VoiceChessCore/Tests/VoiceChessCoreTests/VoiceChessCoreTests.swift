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
