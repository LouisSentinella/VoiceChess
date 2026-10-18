# Voice Chess Coach — Spec

Hands-free blindfold chess against a bot, plus a voice agent to discuss the position. Native iOS app built from Linux, backend on the home server over Tailscale. Draft, 18 Oct 2026.

## Goals

- Play a full game by voice only: speak a move, hear the reply, never look at the screen.
- Ask questions mid-game ("what's on e4?", "why was that a mistake?", "what should I be worried about?") and get spoken answers.
- Pull over and see the board when wanted; the same game state drives the visual.
- Double as blindfold training: adjustable help, from announcing every move and check up to nothing at all.
- Build and install without owning a Mac.

## Principle: the engine is the source of truth

Language models lose track of the board. ChessBench (July 2026) rates the best LLM it tested at about 1149 Elo and estimates up to 8.5% of its games end in an illegal move. ChessArena (ACL 2026) found no tested model beat Maia-1100. Other leaderboards put top reasoning models much higher (roughly 1850–2250 Elo), so estimates vary widely, but none are reliable enough to own the position.

So: `python-chess` owns the game state and validates every move. Engines choose moves and produce evaluations. The LLM only talks, using facts we hand it. It never decides a move and never has to remember the board.

## Architecture

- **iOS app (Swift/SwiftUI):** mic capture, speech-to-text, text-to-speech, board view, session UI. Thin client.
- **Server (home box, reached over Tailscale):** game state and move validation (`python-chess`), opponent engine, analysis engine, LLM calls, and optionally speech-to-text.
- **Transport:** WebSocket or simple HTTPS endpoints over the tailnet. The iOS Tailscale app handles connectivity, including on mobile data.
- **State queries answered without the LLM:** "read the board", "where's my knight", "what's attacking e5", "last five moves" are computed from the position directly, so they are always right.

## Models and engines

| Role | Choice | Notes |
| --- | --- | --- |
| Analysis | Stockfish 18 | Released Jan 2026, up to about 46 Elo over SF17. Runs on CPU. Gives evals and top lines for the explainer. |
| Human-like opponent | Maia via lc0 (1100–1900 weights; Maia-2 exists) | Plays the move a human at that rating would. Run with `go nodes 1` (no search), so it makes human-style tactical oversights. Weights are 1–10 MB, so CPU is fine. |
| Strong opponent (option) | Stockfish with limited strength | For when you want a stronger, less human-like game. |
| Explainer / chat | Hosted frontier LLM via API | Given FEN, legal moves, last moves, Stockfish top lines and evals. Strong at turning engine facts into spoken explanations. |
| Explainer, offline fallback | General 7–8B instruct model, 4-bit, on the 8 GB GPU | General knowledge: an 8B model at 4-bit fits in 8 GB with room for context. Fine for short spoken answers when fed engine output. Not verified against chess benchmarks. |

### Chess-specific language models worth knowing about

- **QUEEN** (Bhaskar, Cheng, Chen; arXiv, 2 Oct 2026): a 4B chess-language model that pairs an Lc0 encoder with an instruction-tuned LM. Reported at grandmaster-level play while explaining its moves. This is exactly the shape of the explainer we want, and the weights are now released as two checkpoints (\`queen\_pawn-8\` and \`queen\_hce-4\`). They need a custom CUDA 13 runner and were only tested on an H100 80 GB, so 8 GB is unproven. See Server handoff.
- **ChessArena's fine-tuned Qwen3-8B:** a baseline that approaches much larger reasoning models. Same caveat: confirm availability.
- **Community small models** (e.g. a 1.5B chess-tuned Qwen outputting a rationale plus a UCI move from a FEN and legal moves list): unvetted. Interesting for experiments, not for v1.
- **OpenRouter:** I did not find a chess-specific model there. Use a general model for commentary and keep the engine in charge of moves.

### GPU budget (8 GB, shared)

lc0 with Maia and Stockfish run fine on CPU. That leaves the GPU for either a local LLM or a local Whisper model, not necessarily both at once. Default: hosted LLM, local or on-device speech-to-text.

## Server handoff

For whoever builds this on the home server. Target: Linux with an NVIDIA RTX 3070 Ti (8 GB VRAM), per Louis. CPU, RAM, driver and CUDA versions are unknown: check `nvidia-smi` and `lscpu` before installing anything, and don't assume the GPU is idle (a desktop session may be using it).

### Build order

1. Install Stockfish 18, lc0 (CPU backend) and Maia weights (start with maia-1500), plus `python-chess`.
2. Wrap them in a small FastAPI service that holds one game per session. Suggested surface: `POST /game` (side, Maia level), `POST /move` (SAN or UCI, validated), `GET /state` (FEN, move list, legal moves), `GET /board/read` (piece locations computed from the position), `POST /ask` (question to the LLM with engine facts attached), and a WebSocket for streamed spoken replies.
3. Expose it only on the tailnet with `tailscale serve` so the iOS app gets HTTPS.
4. Put the LLM behind one interface with two backends, hosted API and local model, chosen by config.
5. Only then try QUEEN (next section). Nothing above depends on it.

### QUEEN trial (experiment, not a dependency)

Models: `princeton-nlp/queen_pawn-8` and `princeton-nlp/queen_hce-4`. Both are 3B-parameter BF16 checkpoints: a fine-tuned SmolLM3 decoder plus a Leela Chess Zero BT5 board encoder. The cards don't explain how the two differ, so run both.

What the cards require:

- Linux, an NVIDIA GPU with BF16 support, a CUDA 13-compatible driver, and `uv`.
- About 8.4 GiB of downloads plus the CUDA environment. CPU inference is not supported.
- Use the provided `infer.py`, not `AutoModelForCausalLM` alone, which omits board conditioning.
- Tested on an H100 80 GB only. Smaller GPUs are not validated.
- Defaults: temperature 0.6, `--gpu-memory-utilization` 0.72 (lower it when sharing a GPU, leaving room for the separately loaded encoder). Unparseable output falls back to a random legal move, labelled in `move_source`.

Run, from the card (repeat for `queen_hce-4`):

```bash
uv venv --python 3.12.12 queen_pawn-8/.venv
uv pip install --python queen_pawn-8/.venv/bin/python huggingface-hub==1.27.0
queen_pawn-8/.venv/bin/hf download princeton-nlp/queen_pawn-8 --local-dir queen_pawn-8
uv pip sync --python queen_pawn-8/.venv/bin/python queen_pawn-8/requirements-inference.txt
CUDA_VISIBLE_DEVICES=0 queen_pawn-8/.venv/bin/python queen_pawn-8/infer.py --fen 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'
```

A 3B model in BF16 is roughly 6 GB of weights before the encoder and cache, so expect out-of-memory errors at the default setting. Try different `--gpu-memory-utilization` values and record what loads.

Pass or fail, measured on about 20 varied positions (opening, middlegame, endgame):

- Loads and answers within 8 GB: yes or no.
- Time to answer: under about 5 seconds is workable for voice. Record the real number.
- Share of moves that are legal, and how often its move is in Stockfish's top 3.
- Spot-check explanations against Stockfish's lines. The cards warn explanations and variations may be wrong.

Decision: if it passes, use it as the explainer (Stockfish still supplies evals, `python-chess` still referees every move) and optionally as an opponent. If it fails, keep Maia, Stockfish and the hosted LLM; a rented GPU for an hour is a cheap way to confirm the model is worth the effort before buying hardware around it. If QUEEN holds the GPU, a local Whisper or local LLM can't share it at the same time.

Licence: the cards say no blanket licence is asserted for the combined release (SmolLM3 is Apache-2.0; the Lc0 encoder has its own upstream terms). Check before using beyond personal use.

## Voice layer

- **Speech-to-text (v1):** Apple's on-device speech recognition. Feed it the current legal moves (as spoken forms) as hints, then resolve the transcript to a legal move on the server. Accept both SAN ("knight f3") and phonetic file names ("echo four") to avoid b/d/e/c confusion.
- **Speech-to-text (alternative):** stream audio to Whisper on the server over Tailscale. Better accuracy, adds latency. Try if on-device is poor in the car.
- **Disambiguation:** if a transcript matches no legal move or several, the app asks ("Did you mean knight to d2 or knight to f3?") instead of guessing. Confirm-before-play is a setting.
- **Text-to-speech:** Apple's built-in synthesizer. Moves announced in a consistent short form.
- **Modes:** push-to-talk by default, or hands-free with a wake phrase later.

## Blindfold training features

- Help levels: announce every move and check, moves only, nothing.
- "Read the board" and "read my pieces" on demand.
- Optional hidden board with a reveal button (and a visible-board mode for pulling over).
- Mistake log: when you ask for a square or piece location and get it wrong in your own head, note it. Later: drills from the log.
- Post-game voice review: engine-flagged critical moments explained one at a time.

## Driving safety

Voice-only, short responses, no screen interaction needed to play. The deep analysis chat is the part most likely to distract, so keep spoken answers short by default and consider an "analysis only when parked" setting. Your call on how and when you use it.

## Building iOS from Linux

1. Write Swift/SwiftUI in any editor on Linux. Keep chess and networking logic in a plain Swift package that also builds and tests on Linux.
2. Push to GitHub. A GitHub Actions macOS runner runs `xcodebuild` with code signing disabled and packages an unsigned `.ipa` as a build artifact.
3. Download the `.ipa` and install it with SideStore (or AltStore) using a free Apple ID.

Known limits: no iOS simulator on Linux, so the loop is push, wait a few minutes, install, test; free Apple IDs expire sideloaded apps every 7 days and allow 3 active sideloaded apps; SideStore can refresh on the phone itself; private repos use a limited monthly macOS-minute allowance (macOS minutes cost 10x), public repos are free; no Xcode debugger, so log liberally.

## Milestones

1. **Pipeline hello-world:** a blank SwiftUI app builds in Actions and runs on the phone. Do this first; it de-risks everything.
2. **Server:** `python-chess` + Maia/lc0 + Stockfish behind an API; play a text game with `curl`.
3. **Voice play:** speech-to-text and text-to-speech in the app; full game by voice against Maia.
4. **Board view:** visual board synced with server state.
5. **Analysis agent:** LLM with engine context; "why" questions and position chat.
6. **Blindfold features:** help levels, read-the-board queries, mistake log.
7. **Car testing and polish:** noise, latency, mount/screen-awake behaviour, disambiguation.

## Risks and open questions

- **Background audio on iOS:** whether speech recognition keeps working with the screen locked or the app backgrounded, especially for a sideloaded app. Test early in milestone 3; the fallback is a mounted phone with the screen kept awake.
- **Recognition in a noisy car:** mitigated by legal-move hints and phonetic input; Whisper on the server is the fallback.
- **Latency over mobile data:** keep engine moves fast (Maia at 1 node is near-instant); stream LLM answers.
- **QUEEN / chess-tuned weights:** weights are released but unvalidated on 8 GB (see Server handoff).
- **7-day expiry:** set a weekly refresh habit, or make SideStore auto-refresh part of the setup.
- **Cost:** hosted LLM per-question cost is small, but cap tokens and cache the engine facts per position.

## Sources

- [Maia chess (GitHub)](https://github.com/csslab/maia-chess)
- [Stockfish 18 announcement](https://stockfishchess.org/blog/2026/stockfish-18/)
- [ChessArena (ACL 2026)](https://preview.aclanthology.org/ingest-acl/2026.acl-long.360/)
- [ChessBench summary (York University)](https://jso.eecs.yorku.ca/2026/07/)
- [QUEEN: Language Models that Play Chess and Explain Their Moves (arXiv 2610.03695)](https://arxiv.org/pdf/2610.03695)
- [Best AI to play chess against in 2026 (Chessiverse)](https://chessiverse.com/compare/best-ai-to-play-chess-against)
- [Verbal Chess (App Store)](https://apps.apple.com/us/app/-/id1602860192)

* [QUEEN models collection (Hugging Face)](https://huggingface.co/collections/princeton-nlp/queen-chess-models)
* [queen\_pawn-8 model card](https://huggingface.co/princeton-nlp/queen_pawn-8)
* [queen\_hce-4 model card](https://huggingface.co/princeton-nlp/queen_hce-4)
