"""Text-to-speech with Kokoro (ONNX, CPU). Short phrases synthesise in about 0.4 s."""

from __future__ import annotations

import asyncio
import io
import re
import wave
from collections import OrderedDict
from pathlib import Path

import numpy as np

MAX_TEXT = 300
CACHE_SIZE = 512
ENGLISH_PREFIXES = ("af_", "am_", "bf_", "bm_")

FILE_SOUNDS = {"a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "eff", "g": "gee", "h": "aitch"}
RANK_WORDS = {"1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven", "8": "eight"}
PIECES = "Pawn|Knight|Bishop|Rook|Queen|King"


class TtsError(Exception):
    pass


def for_speech(text: str) -> str:
    """Spell chess squares so a speech model reads 'a4' and 'Pawn a takes' correctly."""
    text = re.sub(
        r"\b([a-h])([1-8])\b",
        lambda m: f"{FILE_SOUNDS[m.group(1)]} {RANK_WORDS[m.group(2)]}",
        text,
    )
    # A bare file letter after a piece name ("Pawn e takes", "Knight b to").
    return re.sub(rf"\b({PIECES}) ([a-h])\b", lambda m: f"{m.group(1)} {FILE_SOUNDS[m.group(2)]}", text)


def to_wav(samples: np.ndarray, sample_rate: int) -> bytes:
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


class Tts:
    def __init__(self, model: Path, voices: Path, default_voice: str):
        self.model, self.voices_path, self.default_voice = model, voices, default_voice
        self._kokoro = None
        self._lock = asyncio.Lock()  # the ONNX session is used one request at a time
        self._cache: OrderedDict[tuple[str, float, str], bytes] = OrderedDict()

    def available(self) -> bool:
        return self.model.exists() and self.voices_path.exists()

    def _load(self):
        if self._kokoro is None:
            from kokoro_onnx import Kokoro

            self._kokoro = Kokoro(str(self.model), str(self.voices_path))
        return self._kokoro

    async def warm(self) -> None:
        if self.available():
            await asyncio.to_thread(self._load)

    async def voices(self) -> list[str]:
        if not self.available():
            raise TtsError(f"Missing {self.model}. Run server/setup-engines.sh.")
        async with self._lock:
            kokoro = await asyncio.to_thread(self._load)
        return sorted(v for v in kokoro.get_voices() if v.startswith(ENGLISH_PREFIXES))

    async def synthesize(self, text: str, voice: str | None, speed: float) -> bytes:
        voice = voice or self.default_voice
        key = (voice, speed, text)
        if key in self._cache:
            self._cache.move_to_end(key)
            return self._cache[key]
        if voice not in await self.voices():
            raise ValueError(f"Unknown voice {voice}.")

        lang = "en-gb" if voice.startswith("b") else "en-us"
        async with self._lock:
            kokoro = await asyncio.to_thread(self._load)
            samples, rate = await asyncio.to_thread(
                kokoro.create, for_speech(text), voice=voice, speed=speed, lang=lang
            )
        wav = to_wav(samples, rate)
        self._cache[key] = wav
        if len(self._cache) > CACHE_SIZE:
            self._cache.popitem(last=False)
        return wav
