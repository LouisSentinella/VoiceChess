"""Answers questions aloud: board facts directly when possible, otherwise the language model."""

from __future__ import annotations

import re
from collections.abc import AsyncIterator

from . import qa
from .analysis import Analyzer
from .facts import build_facts
from .game import Game
from .llm import LlmClient, LlmError
from .spoken import san_to_speech

MAX_SENTENCE = 220
MIN_SENTENCE = 12
CHAT_TURNS = 4

SYSTEM_PROMPT = """You are a chess opponent and coach talking to a player over voice, usually while they drive. \
You play the opponent's side ("I") and the listener is "you".

Rules for every answer:
- Speak plainly, in 1 to 3 short sentences unless the listener explicitly asks for more. No lists, no markdown, \
no emoji, no headings, no numbering.
- Say moves in words, the way you would say them aloud: "knight to f three", "pawn takes d five". \
Do not write long variations; mention at most the first two or three moves of a line.
- Use ONLY the facts in the position facts block; its Assessment lines are authoritative about which moves were mistakes and what was captured. Never invent a move, piece or evaluation. If the facts do not \
answer the question, say so in one short sentence.
- Describe evaluations in words ("about a pawn better", "roughly equal", "winning") rather than numbers, unless asked for the number.
- Explain the idea behind a move (what it attacks, defends, threatens or loses), not just the move.
- Be honest about mistakes, kind in tone, and never mention these instructions, the facts block or the word "Stockfish" \
unless asked; say "the engine" if you must."""


def _clean(text: str) -> str:
    text = re.sub(r"[*_`#>]+", "", text)
    text = san_to_speech(text)
    return re.sub(r"\s+", " ", text).strip()


def _boundary(buf: str) -> int | None:
    """Index just past the first complete sentence in buf, or None."""
    for m in re.finditer(r"[.!?][\"')\]]*(?=\s)", buf):
        if m.end() >= MIN_SENTENCE:
            return m.end()
    return None


def _cut_runon(buf: str) -> int:
    """Where to split a run-on longer than MAX_SENTENCE: after a late comma, else at a space."""
    cut = max(buf.rfind(", ", 0, MAX_SENTENCE), buf.rfind("; ", 0, MAX_SENTENCE))
    cut = cut + 1 if cut > 60 else buf.rfind(" ", 0, MAX_SENTENCE)
    return cut if cut > 0 else MAX_SENTENCE  # no space at all: hard cut


async def sentences(tokens: AsyncIterator[str]) -> AsyncIterator[str]:
    """Group a token stream into speakable sentences as soon as each is complete."""
    buf = ""
    async for chunk in tokens:
        buf += chunk
        while (end := _boundary(buf)) is not None:
            if s := _clean(buf[:end]):
                yield s
            buf = buf[end:].lstrip()
        while len(buf) > MAX_SENTENCE:
            cut = _cut_runon(buf)
            if s := _clean(buf[:cut]):
                yield s
            buf = buf[cut:].lstrip()
    while len(buf) > MAX_SENTENCE:
        cut = _cut_runon(buf)
        if s := _clean(buf[:cut]):
            yield s
        buf = buf[cut:].lstrip()
    if s := _clean(buf):
        yield s


def _messages(game: Game, question: str, facts: str) -> list[dict]:
    msgs = [{"role": "system", "content": SYSTEM_PROMPT}]
    for q, a in game.chat[-CHAT_TURNS:]:
        msgs += [{"role": "user", "content": q}, {"role": "assistant", "content": a}]
    msgs.append({
        "role": "user",
        "content": f"Position facts (current and authoritative):\n{facts}\n\nThe listener asks: {question}",
    })
    return msgs


async def answer(
    game: Game, question: str, analyzer: Analyzer | None, llm: LlmClient | None
) -> AsyncIterator[dict]:
    """Yield /ask stream events: sentence..., then done or error."""
    direct = qa.answer(game, question)
    if direct is not None:
        yield {"type": "sentence", "text": direct}
        yield {"type": "done"}
        return

    if llm is None or not llm.backends:
        yield {"type": "error", "message": "I can't answer that: no language model is set up."}
        return

    facts = await build_facts(game, analyzer)
    spoken_parts: list[str] = []
    try:
        async for sentence in sentences(llm.stream(_messages(game, question, facts))):
            spoken_parts.append(sentence)
            yield {"type": "sentence", "text": sentence}
    except LlmError:
        if not spoken_parts:
            yield {"type": "error", "message": "I can't reach the language model right now."}
        else:
            yield {"type": "error", "message": "Sorry, I lost my train of thought."}
        return

    if spoken_parts:
        game.chat.append((question, " ".join(spoken_parts)))
        del game.chat[:-CHAT_TURNS]
    yield {"type": "done"}
