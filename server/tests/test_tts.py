import io
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voicechess_server.main import app
from voicechess_server.tts import TtsError, for_speech, to_wav


def test_squares_and_bare_file_letters_are_spelled_for_the_voice():
    assert for_speech("Knight to f3") == "Knight to eff three"
    assert for_speech("Pawn e takes d5, en passant") == "Pawn ee takes dee five, en passant"
    assert for_speech("Pawn a to a4") == "Pawn ay to ay four"
    # Ordinary words and a bare "a" outside the move forms are left alone.
    assert for_speech("Did you mean a draw?") == "Did you mean a draw?"


def test_wav_is_24khz_mono_16bit_and_clips_out_of_range_samples():
    data = to_wav(np.array([0.0, 0.5, 2.0, -2.0], dtype=np.float32), 24000)
    with wave.open(io.BytesIO(data)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 24000, 4)
        frames = np.frombuffer(w.readframes(4), dtype="<i2")
    assert list(frames) == [0, 16383, 32767, -32767]


class FakeTts:
    default_voice = "af_heart"

    def __init__(self):
        self.calls = []
        self.down = False

    async def voices(self):
        if self.down:
            raise TtsError("model missing")
        return ["af_heart", "bf_emma"]

    async def synthesize(self, text, voice, speed):
        if self.down:
            raise TtsError("model missing")
        if voice == "nope":
            raise ValueError("Unknown voice nope.")
        self.calls.append((text, voice, speed))
        return to_wav(np.zeros(240, dtype=np.float32), 24000)


@pytest.fixture
def client():
    with TestClient(app) as c:
        app.state.tts = FakeTts()
        yield c


def test_tts_returns_wav_and_lists_voices(client):
    r = client.post("/tts", json={"text": "Knight to f3", "voice": "bf_emma"})
    assert r.status_code == 200 and r.headers["content-type"] == "audio/wav"
    assert r.content[:4] == b"RIFF"
    assert client.get("/tts/voices").json() == {"voices": ["af_heart", "bf_emma"], "default": "af_heart"}


@pytest.mark.parametrize(
    "body",
    [{"text": ""}, {"text": "x" * 301}, {"text": "hi", "speed": 5}, {"text": "hi", "voice": "nope"}],
)
def test_tts_rejects_bad_requests(client, body):
    assert client.post("/tts", json=body).status_code == 422


def test_tts_unavailable_is_503_so_the_app_can_fall_back(client):
    app.state.tts.down = True
    assert client.post("/tts", json={"text": "hi"}).status_code == 503
    assert client.get("/tts/voices").status_code == 503
