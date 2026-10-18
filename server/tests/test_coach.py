import json

import chess
import httpx
import pytest
from fastapi.testclient import TestClient

from voicechess_server import coach, qa
from voicechess_server.analysis import MATE_CP, Line
from voicechess_server.facts import build_facts, eval_words, move_label
from voicechess_server.game import Game, OpponentSpec
from voicechess_server.llm import Backend, LlmClient, LlmError, backends_from_env
from voicechess_server.main import app


def game(moves: str = "", player=chess.WHITE) -> Game:
    g = Game("t", player, OpponentSpec("maia", 1500))
    for m in moves.split():
        g.board.push_san(m)
    return g


@pytest.mark.parametrize(
    "text",
    ["what is on e4", "What's attacking e5?", "why was that a mistake", "should I castle", "tell me about it",
     "explain the position", "is my queen safe", "how am I doing", "where's my knight"],
)
def test_questions_are_recognised(text):
    assert qa.is_question(text)


@pytest.mark.parametrize("text", ["knight to f three", "e four", "castle kingside", "pawn takes d5", "bishop e2"])
def test_moves_are_not_questions(text):
    assert not qa.is_question(text)


def test_board_questions_are_answered_from_the_position():
    g = game("e4 e5 Nf3")
    assert qa.answer(g, "what is on e4") == "Your pawn on e4."
    assert qa.answer(g, "what's on e5") == "My pawn on e5."
    assert qa.answer(g, "what is on e3") == "e3 is empty."
    assert qa.answer(g, "where's my knight") == "Your knights are on b1 and f3."
    assert qa.answer(g, "where is your queen") == "My queen is on d8."
    assert qa.answer(g, "what's attacking e5") == "Your knight on f3 attacks e5."
    assert qa.answer(g, "what is defending e5") == "Nothing defends my pawn on e5."
    assert qa.answer(g, "what was the last move") == "The last move was knight to f3, played by you."
    assert qa.answer(g, "last two moves") == "The last moves were pawn to e5, knight to f3."


def test_owner_follows_the_players_colour():
    g = game("e4", player=chess.BLACK)
    assert qa.answer(g, "what is on e4") == "My pawn on e4."
    assert qa.answer(g, "where is my king") == "Your king is on e8."


def test_open_questions_go_to_the_model():
    assert qa.answer(game("e4 e5"), "why was that a mistake") is None
    assert qa.answer(game("e4 e5"), "what should I be worried about") is None


async def tokens(*chunks):
    for c in chunks:
        yield c


async def collect(gen):
    return [s async for s in gen]


async def test_sentences_stream_as_complete_and_speak_moves_in_words():
    out = await collect(coach.sentences(tokens(
        "You could play Nf3 ", "to develop. ", "That also hits e5! ", "Castle soon", " after.")))
    assert out == ["You could play knight to f3 to develop.", "That also hits e5!", "Castle soon after."]


async def test_sentences_do_not_split_on_decimals_or_short_fragments_and_strip_markdown():
    out = await collect(coach.sentences(tokens("**You** are up 1.5 pawns. 1. e4 was fine.")))
    assert out == ["You are up 1.5 pawns.", "1. e4 was fine."]


async def test_run_on_text_is_cut_into_speakable_pieces():
    long = ("word " * 30 + "end, ") * 3
    out = await collect(coach.sentences(tokens(long)))
    assert len(out) > 1 and all(len(s) <= coach.MAX_SENTENCE for s in out)


def test_eval_words_and_labels():
    assert eval_words(10) == "roughly equal (0.0)"
    assert eval_words(150) == "clearly better for you (+1.5)"
    assert eval_words(-900) == "winning for me (-9.0)"
    assert eval_words(MATE_CP - 3) == "a forced mate for you"
    assert [move_label(x) for x in (0, 40, 90, 250, 800)] == [
        "best or equal best", "good", "an inaccuracy", "a mistake", "a blunder"]


class FakeAnalyzer:
    """Prefers the move a scripted dict names; otherwise evaluates 0."""

    def __init__(self, scripted=None):
        self.scripted = scripted or {}
        self.asked = []

    def available(self):
        return True

    async def lines(self, board, multipv=1):
        self.asked.append(board.fen())
        if board.is_game_over(claim_draw=True):
            return []
        fen = board.fen()
        move, cp = self.scripted.get(fen, (next(iter(board.legal_moves)), 0))
        return [Line(cp=cp, mate=None, first=move, san=(board.san(move),))]

    async def close(self):
        pass


async def test_facts_flag_a_blunder_with_the_better_move():
    g = game("e4 e5 Qh5 Nc6")
    parent = g.board.copy()
    parent.pop()  # position before Black's ...Nc6, Black to move
    scripted = {
        parent.fen(): (chess.Move.from_uci("g8f6"), -20),  # Black's best (...Nf6) keeps Black +0.2
        g.board.fen(): (chess.Move.from_uci("h5f7"), 300),  # after ...Nc6 White is +3.0
    }
    facts = await build_facts(g, FakeAnalyzer(scripted))
    assert "I played Nc6: a blunder" in facts
    assert "The engine preferred Nf6" in facts
    assert "Moves so far: 1. e4 e5 2. Qh5 Nc6" in facts
    assert "Your pieces:" in facts and "My pieces:" in facts


async def test_facts_without_an_engine_still_describe_the_position():
    facts = await build_facts(game("e4 e5"), None)
    assert "The engine analysis is not available right now." in facts
    assert "Material is even." in facts


def sse(*chunks) -> str:
    lines = [f"data: {json.dumps({'choices': [{'delta': {'content': c}}]})}" for c in chunks]
    return "\n\n".join(lines + ["data: [DONE]", ""])


def client_for(handlers: dict) -> LlmClient:
    def handler(request: httpx.Request) -> httpx.Response:
        return handlers[request.url.host](request)

    return LlmClient(
        [Backend("hosted", "https://hosted.test/v1", "m", "KEY"), Backend("local", "http://local.test/v1", "l")],
        httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )


async def test_stream_parses_sse_and_sends_key_and_model():
    seen = {}

    def hosted(request):
        seen["auth"] = request.headers["authorization"]
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, text=sse("Hel", "lo."))

    llm = client_for({"hosted.test": hosted})
    assert "".join([c async for c in llm.stream([{"role": "user", "content": "hi"}])]) == "Hello."
    assert seen["auth"] == "Bearer KEY" and seen["body"]["model"] == "m" and seen["body"]["stream"] is True


async def test_falls_back_to_the_next_backend_before_the_first_token():
    llm = client_for({
        "hosted.test": lambda r: httpx.Response(503, text="overloaded"),
        "local.test": lambda r: httpx.Response(200, text=sse("from local")),
    })
    assert "".join([c async for c in llm.stream([])]) == "from local"


async def test_all_backends_failing_raises():
    def down(request):
        raise httpx.ConnectError("refused")

    llm = client_for({"hosted.test": down, "local.test": down})
    with pytest.raises(LlmError) as e:
        [c async for c in llm.stream([])]
    assert "hosted" in str(e.value) and "local" in str(e.value)


def test_backend_selection_from_env():
    assert [b.name for b in backends_from_env({})] == ["local"]
    names = [b.name for b in backends_from_env({"OPENROUTER_API_KEY": "k"})]
    assert names == ["openrouter", "local"]
    assert [b.name for b in backends_from_env({"VOICECHESS_LLM": "local,openrouter", "OPENROUTER_API_KEY": "k"})] == [
        "local", "openrouter"]
    assert [b.name for b in backends_from_env({"VOICECHESS_LLM": "openrouter"})] == []  # no key: skipped
    with pytest.raises(ValueError):
        backends_from_env({"VOICECHESS_LLM": "gpt"})


class FakePool:
    async def prepare(self, spec):
        pass

    async def choose_move(self, spec, board):
        return next(iter(board.legal_moves))

    async def close(self):
        pass


@pytest.fixture
def client():
    with TestClient(app) as c:
        app.state.pool = FakePool()
        app.state.analyzer = FakeAnalyzer()
        yield c


def ask(client, gid, question) -> list[dict]:
    r = client.post(f"/game/{gid}/ask", json={"question": question})
    assert r.status_code == 200 and r.headers["content-type"].startswith("application/x-ndjson")
    return [json.loads(line) for line in r.text.splitlines()]


def test_say_routes_questions_before_move_parsing(client):
    gid = client.post("/game", json={}).json()["state"]["id"]
    r = client.post(f"/game/{gid}/say", json={"transcript": "what is on e4"}).json()
    assert r == {"status": "question", "question": "what is on e4"}
    assert client.get(f"/game/{gid}/state").json()["moves"] == []  # nothing was played


def test_ask_answers_board_questions_instantly_without_a_model(client):
    gid = client.post("/game", json={}).json()["state"]["id"]
    app.state.llm.backends = []  # no model at all: board questions must still work
    assert ask(client, gid, "where is my king") == [
        {"type": "sentence", "text": "Your king is on e1."}, {"type": "done"}]


def test_ask_streams_model_sentences_and_remembers_the_exchange(client):
    gid = client.post("/game", json={}).json()["state"]["id"]
    prompts = []

    def hosted(request):
        prompts.append(json.loads(request.content)["messages"])
        return httpx.Response(200, text=sse("Develop your knight. ", "It controls the centre."))

    app.state.llm = client_for({"hosted.test": hosted})
    events = ask(client, gid, "what should I do")
    assert events == [
        {"type": "sentence", "text": "Develop your knight."},
        {"type": "sentence", "text": "It controls the centre."},
        {"type": "done"},
    ]
    assert "Position facts" in prompts[0][-1]["content"] and "what should I do" in prompts[0][-1]["content"]

    ask(client, gid, "why")
    history = prompts[1]
    assert history[1] == {"role": "user", "content": "what should I do"}
    assert history[2]["content"] == "Develop your knight. It controls the centre."


def test_ask_reports_a_dead_model_as_a_speakable_error(client):
    gid = client.post("/game", json={}).json()["state"]["id"]

    def down(request):
        raise httpx.ConnectError("refused")

    app.state.llm = client_for({"hosted.test": down, "local.test": down})
    events = ask(client, gid, "why did that lose")
    assert events == [{"type": "error", "message": "I can't reach the language model right now."}]


def test_ask_unknown_game_is_404(client):
    assert client.post("/game/nope/ask", json={"question": "hi"}).status_code == 404
