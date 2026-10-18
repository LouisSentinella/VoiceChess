import json
from pathlib import Path

import chess
import httpx
import pytest
from fastapi.testclient import TestClient

from test_coach import FakeAnalyzer, FakePool, client_for, sse
from voicechess_server import review
from voicechess_server.analysis import MATE_CP
from voicechess_server.game import Game, OpponentSpec
from voicechess_server.main import app
from voicechess_server.mistakes import MistakeLog


def game_with(moves: str, player=chess.WHITE) -> Game:
    g = Game("g1", player, OpponentSpec("maia", 1500))
    for m in moves.split():
        g.board.push_san(m)
    return g


def test_log_summary_counts_and_speaks_the_main_weakness(tmp_path: Path):
    log = MistakeLog(tmp_path / "m.db")
    assert log.summary()["spoken"] == "Your mistake log is empty."
    log.record("lookup", "g", 4, "where is knight", piece=chess.KNIGHT)
    log.record("lookup", "g", 6, "what is on e5", square=chess.E5)
    log.record("illegal_attempt", "g", 8, "knight to e five", piece=chess.KNIGHT, square=chess.E5)
    s = log.summary()
    assert (s["illegal_attempts"], s["lookups"]) == (1, 2)
    assert s["by_piece"] == {"knight": 2} and s["by_square"] == {"e5": 2}
    assert s["spoken"] == "You asked about the board 2 times and tried 1 illegal move. The piece you lose track of most is the knight."
    assert s["recent"][0]["kind"] == "illegal_attempt"  # newest first


def test_log_survives_a_restart(tmp_path: Path):
    MistakeLog(tmp_path / "m.db").record("lookup", "g", 1, "where is king", piece=chess.KING)
    assert MistakeLog(tmp_path / "m.db").summary()["lookups"] == 1


@pytest.fixture
def client():
    with TestClient(app) as c:
        app.state.pool = FakePool()
        app.state.analyzer = FakeAnalyzer()
        app.state.llm.backends = []
        yield c


def new_game(client) -> str:
    return client.post("/game", json={}).json()["state"]["id"]


def ask(client, gid, question) -> list[dict]:
    r = client.post(f"/game/{gid}/ask", json={"question": question})
    return [json.loads(line) for line in r.text.splitlines()]


def test_only_clear_illegal_piece_moves_are_logged_not_noise(client):
    gid = new_game(client)
    say = lambda t: client.post(f"/game/{gid}/say", json={"transcript": t}).json()["status"]  # noqa: E731
    assert say("knight to e five") == "no_match"  # names a piece and a square, impossible here
    assert say("uh what was that") == "no_match"  # recogniser noise: no piece, no square
    assert say("e five") == "no_match"  # no piece word: too ambiguous to blame the listener
    summary = client.get("/log/summary").json()
    assert summary["illegal_attempts"] == 1
    assert summary["by_piece"] == {"knight": 1} and summary["by_square"] == {"e5": 1}


def test_board_lookups_are_logged_and_the_log_can_be_asked_about(client):
    gid = new_game(client)
    ask(client, gid, "where is my knight")
    ask(client, gid, "what is on e2")
    ask(client, gid, "what is the last move")  # not a lookup of the board: not logged
    assert client.get("/log/summary").json()["lookups"] == 2
    events = ask(client, gid, "what are my common mistakes")
    assert events[0]["text"] == "You asked about the board 2 times. The piece you lose track of most is the knight."
    assert client.get("/log/summary").json()["lookups"] == 2  # asking about the log is not a mistake


async def test_review_lists_the_worst_moves_first_with_the_better_move():
    g = game_with("e4 e5 Qh5 Nc6 Qxf7+ Kxf7")
    before = g.board.copy()
    before.pop(), before.pop()  # position before 3.Qxf7+
    analyzer = FakeAnalyzer({
        before.fen(): (chess.Move.from_uci("f1c4"), 0),  # best was Bc4, level
        g.board.copy().fen(): (chess.Move.from_uci("a2a3"), 0),
    })
    # After 3.Qxf7+ (Black to move) White is down a queen: -900 for White.
    after_qxf7 = before.copy()
    after_qxf7.push_san("Qxf7+")
    analyzer.scripted[after_qxf7.fen()] = (chess.Move.from_uci("e8f7"), -900)

    r = await review.review(g, analyzer)
    assert [m["ply"] for m in r["moments"]] == [5]
    m = r["moments"][0]
    assert (m["move_number"], m["san"], m["best_san"], m["loss_pawns"], m["label"]) == (
        3, "Qxf7+", "Bc4", 9.0, "a blunder")
    assert m["spoken"] == "Queen takes f7, check" and m["best_spoken"] == "Bishop to c4"
    assert chess.Board(m["fen_before"]).turn == chess.WHITE and m["uci"] == "h5f7"
    assert r["summary"] == "You played 3 moves: 1 blunder. Let's go through them."


async def test_review_with_no_mistakes_says_so():
    r = await review.review(game_with("e4 e5"), FakeAnalyzer())
    assert r["moments"] == []
    assert r["summary"] == "You played 1 move and I found no mistakes worth reviewing."


async def test_review_covers_only_the_listeners_moves_when_playing_black():
    g = game_with("e4 e5 Nf3", player=chess.BLACK)
    assert review.listener_plies(g) == [2]
    assert review.listener_plies(game_with("e4 e5 Nf3")) == [1, 3]


def test_mate_score_loss_is_capped_in_the_report():
    assert MATE_CP == 100_000  # review caps losses at MATE_CP so loss_pawns stays a sane number


def test_explain_streams_the_model_answer_for_the_chosen_move(client):
    gid = new_game(client)
    game = app.state.games.get(gid)
    for san in "e4 e5 Qh5 Nc6 Qxf7+ Kxf7".split():
        game.board.push_san(san)
    prompts = []

    def hosted(request):
        prompts.append(json.loads(request.content)["messages"][-1]["content"])
        return httpx.Response(200, text=sse("You lost your queen for a pawn."))

    app.state.llm = client_for({"hosted.test": hosted})
    r = client.post(f"/game/{gid}/review/5/explain")
    events = [json.loads(line) for line in r.text.splitlines()]
    assert events[0] == {"type": "sentence", "text": "You lost your queen for a pawn."}
    assert events[-1] == {"type": "done"}
    # The model sees the game as it stood right after ply 5, not the final position.
    assert "Moves so far: 1. e4 e5 2. Qh5 Nc6 3. Qxf7+" in prompts[0]
    assert "Kxf7" not in prompts[0].split("Moves so far:")[1].split("\n")[0]
    assert "queen takes f7, check was a mistake" in prompts[0].lower()


def test_explain_rejects_plies_that_are_not_the_listeners_moves(client):
    gid = new_game(client)
    app.state.games.get(gid).board.push_san("e4")
    app.state.games.get(gid).board.push_san("e5")
    assert client.post(f"/game/{gid}/review/2/explain").status_code == 404  # Black's move
    assert client.post(f"/game/{gid}/review/9/explain").status_code == 404  # not played yet
    assert client.post("/game/nope/review/1/explain").status_code == 404


def test_review_endpoint_returns_summary_and_moments(client):
    gid = new_game(client)
    game = app.state.games.get(gid)
    game.board.push_san("e4")
    body = client.get(f"/game/{gid}/review").json()
    assert set(body) == {"summary", "moments"} and body["moments"] == []
