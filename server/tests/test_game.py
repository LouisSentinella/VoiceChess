import chess
import pytest
from fastapi.testclient import TestClient

from voicechess_server.engines import EngineError
from voicechess_server.game import Game, MoveError, OpponentSpec
from voicechess_server.main import app

SPEC = OpponentSpec("maia", 1500)


def game_from(fen: str | None = None, moves: str = "") -> Game:
    g = Game("t", chess.WHITE, SPEC)
    if fen:
        g.board = chess.Board(fen)
    for m in moves.split():
        g.board.push_san(m)
    return g


def test_ambiguous_knight_move_lists_both_candidates():
    # Knights on b1 and f3 can both reach d2.
    g = game_from("rnbqkbnr/pppppppp/8/8/8/5N2/PPP1PPPP/RNBQKB1R w KQkq - 0 1")
    with pytest.raises(MoveError) as e:
        g.resolve_move("Nd2")
    assert e.value.kind == "ambiguous"
    assert sorted(e.value.candidates) == ["Nbd2", "Nfd2"]


def test_uci_promotion_without_piece_asks_which_piece():
    g = game_from("8/4P3/8/8/8/8/k7/4K3 w - - 0 1")
    with pytest.raises(MoveError) as e:
        g.resolve_move("e7e8")
    assert e.value.kind == "ambiguous"
    assert sorted(c.rstrip("+#") for c in e.value.candidates) == ["e8=B", "e8=N", "e8=Q", "e8=R"]
    assert g.resolve_move("e7e8n") == chess.Move.from_uci("e7e8n")


def test_illegal_and_invalid_are_distinguished():
    g = game_from()
    with pytest.raises(MoveError) as e:
        g.resolve_move("e5")  # well-formed, but no pawn can reach e5
    assert e.value.kind == "illegal"
    with pytest.raises(MoveError) as e:
        g.resolve_move("banana")
    assert e.value.kind == "invalid"
    with pytest.raises(MoveError) as e:
        g.resolve_move("a1a1")
    assert e.value.kind == "invalid"


def test_castling_accepts_zeros_and_letters():
    g = game_from(moves="e4 e5 Nf3 Nc6 Bc4 Bc5")
    assert g.resolve_move("0-0") == g.resolve_move("O-O") == chess.Move.from_uci("e1g1")


def test_threefold_repetition_ends_the_game_without_a_claim():
    g = game_from(moves="Nf3 Nf6 Ng1 Ng8 Nf3 Nf6 Ng1 Ng8")
    assert g.is_over()
    assert g.state()["result"] == "1/2-1/2"


def test_board_read_pluralises_and_orders_pieces():
    spoken = game_from().board_read()["spoken"]["white"]
    assert spoken == (
        "king e1, queen d1, rooks a1 and h1, bishops c1 and f1, "
        "knights b1 and g1, pawns a2, b2, c2, d2, e2, f2, g2 and h2"
    )


def test_describe_move_flags_capture_check_and_castle():
    g = game_from("4k3/8/8/8/8/8/4R3/4K2R w K - 0 1")
    assert g.describe_move(chess.Move.from_uci("e1g1"))["castle"] == "kingside"
    d = g.describe_move(chess.Move.from_uci("e2e7"))
    assert (d["check"], d["checkmate"], d["capture"]) == (True, False, False)


class FakePool:
    """Replies with the first legal move, or fails on demand."""

    def __init__(self):
        self.fail = False

    async def prepare(self, spec):
        if spec.level == 9999:
            raise EngineError("bad level")

    async def choose_move(self, spec, board):
        if self.fail:
            raise EngineError("engine died")
        return next(iter(board.legal_moves))

    async def close(self):
        pass


@pytest.fixture
def client():
    with TestClient(app) as c:
        app.state.pool = FakePool()
        yield c


def test_move_round_trip_and_error_shape(client):
    gid = client.post("/game", json={"side": "white"}).json()["state"]["id"]
    r = client.post(f"/game/{gid}/move", json={"move": "e4"})
    assert r.status_code == 200
    body = r.json()
    assert body["player_move"]["san"] == "e4"
    assert body["bot_move"] is not None
    assert body["state"]["your_turn"] is True

    r = client.post(f"/game/{gid}/move", json={"move": "Ke5"})
    assert r.status_code == 422
    assert r.json()["detail"]["error"] == "illegal"


def test_playing_black_makes_the_bot_open(client):
    r = client.post("/game", json={"side": "black"}).json()
    assert r["bot_move"] is not None
    assert r["state"]["your_turn"] is True
    assert len(r["state"]["moves"]) == 1


def test_engine_failure_rolls_back_the_players_move(client):
    gid = client.post("/game", json={}).json()["state"]["id"]
    app.state.pool.fail = True
    r = client.post(f"/game/{gid}/move", json={"move": "e4"})
    assert r.status_code == 502
    state = client.get(f"/game/{gid}/state").json()
    assert state["moves"] == []
    assert state["your_turn"] is True


def test_bad_opponent_is_rejected_at_creation(client):
    r = client.post("/game", json={"level": 9999})
    assert r.status_code == 422
