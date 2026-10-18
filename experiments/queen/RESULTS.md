# QUEEN trial (experiment, not a dependency)

Spec: "Server handoff > QUEEN trial" in `Voice Chess Coach — Spec.md`. Nothing under `server/` is touched or imported by this experiment. **Personal-use trial only.**

**Status: both phases done. Result: neither checkpoint loads on the 8 GB RTX 3070 Ti (OOM / startup memory check at every `--gpu-memory-utilization` tried, 0.72 down to 0.50). See Results.**

## Licence

The model cards assert no blanket licence for the combined release: SmolLM3-3B is Apache-2.0; the Lc0 encoder (BT5-1024x15x32h-rpe-swa-3700000) carries its own upstream terms. Check both before any use beyond personal experimentation.

## Phase 1: what was installed

Machine: Louis's desktop, RTX 3070 Ti 8 GB (shared with the desktop session), driver 615.78.08 (`nvidia-smi`: CUDA UMD 13.4), 16 threads, 31 GB RAM.

| item | value |
|---|---|
| Python | CPython 3.12.12 (the exact version the cards ask for; uv fetched it) |
| uv | 0.13.1 |
| huggingface-hub | 1.27.0 (as in the card) |
| torch | 2.13.0+cu130 (`torch.version.cuda` = 13.0) |
| vLLM | 0.27.1 |
| transformers | 5.15.0 |
| python-chess | 1.11.2 (`chess`; the pin file also lists a `python-chess==1.999` package) |
| Environment | `uv pip sync requirements-inference.txt` (198 packages), `uv pip check`: compatible |
| Driver check | cu130 wheels need a driver supporting CUDA 13.0; driver reports 13.4. `torch.cuda.is_available()` = True, 1 device (cuInit only, no allocation). BF16 is supported on Ampere (sm_86). |
| Imports | `torch`, `transformers`, `vllm`, `models.vllm.flamingo_generate`, `utils.translate_helpers`, `utils.eval_policy` import cleanly in both venvs (run with `CUDA_VISIBLE_DEVICES=` empty, so no GPU use). |
| Checksums | `queen_hce-4`: xattn.pt, model.safetensors, lc0/model.safetensors match `release.json`. `queen_pawn-8` checked by `hf download` only. |

Layout (all under `experiments/queen/`, all git-ignored except the scripts/positions/this file):

```
queen_pawn-8/   HF repo + .venv        queen_hce-4/   HF repo + .venv
positions.json  run_trial.py  queen_worker.py  RESULTS.md
stockfish-cache.json  logs/  results-<model>-<util>.json   (local only)
```

### Disk used

| path | size |
|---|---|
| `queen_pawn-8/` (weights 8.5 GB + `.venv` 7.6 GB) | 16 GB |
| `queen_hce-4/` (weights 8.5 GB + `.venv` 7.6 GB) | 16 GB |
| `experiments/queen/` total | 32 GB |
| shared uv wheel cache `~/.cache/uv` (reclaim with `uv cache clean`) | 7.8 GB |

To delete the experiment completely: `rm -rf experiments/queen/queen_*` and `uv cache clean`.

## What the two checkpoints are (per the cards)

Both: SmolLM3-3B decoder fine-tuned with 16 cross-attention layers reading a Leela Chess Zero BT5 encoder (`xattn.pt` + `lc0/`), BF16, same `infer.py` (byte-identical), same `requirements-inference.txt`, same sampling defaults (temperature 0.6, top-k 20, top-p 0.95, 2048 output tokens), same move policy (`structured`: `BEST_MOVE`, else first legal critical-line move, else a promising/analysis move, else a seeded random legal move labelled in `move_source`).

The cards do not say what `pawn-8` and `hce-4` mean or how they were trained. The differences visible in the repos:

| | queen_pawn-8 | queen_hce-4 |
|---|---|---|
| Evaluation prompt (`inference_config.json`) | "Analyze the position carefully and find the best move for player." | "Analyze the given chess position, identify the best move, give the critical line assuming best play, list promising moves for deeper investigation, and evaluate the position." |
| Decoder weights | two shards (4.97 GB + 1.18 GB) | single `model.safetensors` (6.15 GB), `tie_word_embeddings: true` |
| Exported with | transformers 4.57.6 | transformers 5.9.0 |
| Recorded Elo-eval positions checked | 1461 | 1544 |
| Validation sample answer length (H100, initial position) | 755 / 645 tokens | 403 / 838 tokens |

[INFERENCE] The prompts suggest `hce-4` is trained to emit the full structured analysis (best move, critical line, promising moves, evaluation) and `pawn-8` a free-form analysis ending in a best move; the shared parser reads the same fields from both. Not stated on the cards.

## How the harness works

* `positions.json`: 21 FENs. 6 opening, 2 middlegame + 1 quiet/positional, 4 tactics (Qxf7#, ...Qh4#, Nxh4 winning the queen, Nc7+ fork), 1 forced mate in 2 (K+R vs K), 3 opponent-threat positions (Qxf7# threat, pawn attacking Nf6, a2 passed pawn), 4 endgames (Lucena, K+P, bishop vs knight, rook endgame). All validated with python-chess and eyeballed against Stockfish.
* `queen_worker.py` (runs in the model's venv): `infer.py` is a one-shot CLI that reloads the model on every call, so the worker repeats `infer.py`'s setup verbatim (env vars, `ChessFlamingoGenerator` args, request-seed derivation, `choose_move`) but loads **once** and then answers every position. That gives separate numbers for load time and per-answer time. The first answer includes CUDA warm-up, so the median excluding it is reported as well.
* `run_trial.py`: computes Stockfish (CPU, `server/engines/bin/stockfish` 19, 1 s per position, MultiPV 5, cached in `stockfish-cache.json`; "top 3" is the first three lines), runs the model (`--mode persistent`, default; or `--mode cli` = unmodified `infer.py` once per position, whole-process time), scores everything, writes `results-<model>-<util>.json`. Recorded per position: loaded ok / error text (OOM excerpt from the log), answer time, returned move, legal?, top-1/3/5, `move_source`, the model's own `BEST_MOVE` as written (before the random fallback), explanation text, raw text, and the sanity check below.
* Sanity checker (crude, automatic): decodes every POV move token in the raw output and flags `BEST_MOVE` / `PROMISING_MOVES` entries that are illegal or outside Stockfish's top 5, a `CRITICAL_LINE` that hits an illegal move when replayed (or whose first move is outside the top 5), missing fields, and outputs with no parseable move tokens. Moves mentioned in `ANALYSIS` prose are only counted (they can belong to hypothetical lines). It does **not** judge whether the explanation is true; the human spot-check does that.

Dry run: `run_trial.py --fake` replaces the model with synthetic output (best move, third-best, illegal move, legal-but-outside-top-5, unparseable text). On the 21 positions it produced exactly the expected counts: 3 illegal `BEST_MOVE`s, 3 not-in-top-5, 3 empty outputs with random-fallback moves, 6 missing critical lines, and clean results for the others, including black-to-move positions (POV flip). No GPU or model weights were involved.

## VRAM math (why OOM is expected)

Weights that must sit in VRAM (BF16): decoder 6.15 GB (5.73 GiB) + cross-attention layers `xattn.pt` 1.88 GB on disk (0.9-1.75 GiB on GPU, depending on stored dtype) + Lc0 encoder 0.95 GB (0.89 GiB, loaded separately outside vLLM's budget) = roughly 7.5-8.4 GiB, before the KV cache, activations and CUDA contexts.

Available: 8192 MiB total, about 2.1 GiB used by Hyprland/Firefox/Steam/etc. (measured: 5978 MiB used with `voicechess-llm` holding 3802 MiB, so ~2176 MiB desktop) leaves about 5.9 GiB once `voicechess-llm` is stopped. With the coach LLM still running, only about 2 GiB is free.

So the decoder alone (5.73 GiB) barely fits and everything else does not: `--gpu-memory-utilization` is a fraction of total VRAM that vLLM may use (0.72 x 8 GiB = 5.76 GiB, 0.70 = 5.6 GiB, below the decoder weights alone), and the encoder and x-attn layers sit on top. I expect a load failure at every value. Decode speed is also a problem if it did fit: [INFERENCE] 6.15 GB of weights per token at the 3070 Ti's ~608 GB/s is at most ~100 tokens/s, and the cards' own validation answers are 400-850 tokens, so >= 4-8 s per answer even in the best case, over the 5 s voice budget.

Values to try (descending, per model, stop descending for that model once it loads): **0.72 (card default), 0.70, 0.65, 0.60, 0.50**. A failure at load is quick (the load stage fails before any generation), so all 10 runs are cheap. Record the OOM text each time.

## Phase 2 (needs the GPU; only when told it is safe to stop `voicechess-llm`)

```bash
systemctl --user stop voicechess-llm            # frees ~3.7 GB; the coach falls back while stopped
cd /home/louis/code/VoiceChess/experiments/queen
nvidia-smi --query-gpu=memory.used,memory.total --format=csv    # expect ~2.1 GiB used by the desktop
for m in queen_hce-4 queen_pawn-8; do
  for u in 0.72 0.70 0.65 0.60 0.50; do
    $m/.venv/bin/python run_trial.py --model-dir $m --util $u    # writes results-$m-$u.json
  done
done
systemctl --user start voicechess-llm           # restore the coach
```

Per-position timeout defaults: 900 s without progress while loading, 300 s per answer (`--load-timeout`, `--answer-timeout`). For the card-literal single-shot behaviour (cold start per question, whole-process time) add `--mode cli` for one model/util that loaded.

Pass/fail criteria (from the spec): loads and answers within 8 GB; answer time under about 5 s; share of legal moves and share in Stockfish's top 3; spot-check explanations against Stockfish's lines (manual, use the `explanation` and `stockfish_top` fields plus the checker's flags).

## Results (phase 2, run 2026-10-18)

**Neither checkpoint loads on this 8 GB GPU at any `--gpu-memory-utilization` tried. No position was answered, so there are no legal-move, top-3, timing or explanation numbers.**

Setup for every run: `voicechess-llm` stopped; desktop using about 2.0-2.2 GiB (`nvidia-smi` just before each run: 2029-2208 MiB used of 8192). torch/vLLM see 7.69 GiB total, 5.42 GiB free at startup. `voicechess-llm` was restarted afterwards (`active`).

| model | util | loaded? | error (from `logs/<model>-<util>.log`) |
|---|---|---|---|
| queen_hce-4 | 0.72 | no | vLLM startup check: `ValueError: Free memory on device cuda:0 (5.42/7.69 GiB) on startup is less than desired GPU memory utilization (0.72, 5.53 GiB).` |
| queen_hce-4 | 0.70 | no | `torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 502.00 MiB. GPU 0 has a total capacity of 7.69 GiB of which 165.81 MiB is free. ... this process has 5.52 GiB memory in use.` (while loading weights; "Failed to load model - not enough GPU memory") |
| queen_hce-4 | 0.65 | no | same failure while loading weights, `CUDACachingAllocator` OOM (free ~87-102 MB) |
| queen_hce-4 | 0.60 | no | same |
| queen_hce-4 | 0.50 | no | `CUDA out of memory. Tried to allocate 44.00 MiB. ... 84.12 MiB is free. ... this process has 5.48 GiB memory in use. Of the allocated memory 5.26 GiB is allocated by PyTorch` |
| queen_pawn-8 | 0.72 | no | same startup check as hce-4: `Free memory ... (5.42/7.69 GiB) ... less than desired GPU memory utilization (0.72, 5.53 GiB)` |
| queen_pawn-8 | 0.70 | no | `CUDA out of memory` while loading weights (same pattern) |
| queen_pawn-8 | 0.65 | no | same |
| queen_pawn-8 | 0.60 | no | same |
| queen_pawn-8 | 0.50 | no | `CUDA out of memory. Tried to allocate 502.00 MiB. ... 119.62 MiB is free. ... this process has 5.52 GiB memory in use. Of the allocated memory 5.31 GiB is allocated by PyTorch` |

Notes:

* 0.72 (the card default) is rejected before loading because it asks for 5.53 GiB and only 5.42 GiB is free once the desktop's share is subtracted.
* Below that the failure is the same at every value: `--gpu-memory-utilization` does not cap how much the weights occupy. vLLM allocates the decoder (about 5.3 GiB already allocated when it dies) and the free 5.4 GiB runs out before the model finishes loading, with the cross-attention layers and the separately loaded Lc0 encoder (about 0.9 GiB) still to come. Lowering the value therefore cannot help.
* Stopping the desktop session is not an option here, and the card's `infer.py` offers no quantisation or CPU-offload switch, so no workaround was tried.
* `results-<model>-<util>.json` and `logs/` hold the raw records (local only, git-ignored).

### Human spot-check of explanations

Not possible: no model produced output.

### Decision

**Fail** on the first spec criterion (loads and answers within 8 GB: no). Keep Maia + Stockfish + the hosted LLM (and the local llama.cpp coach fallback). [INFERENCE] QUEEN would need a GPU with roughly 12 GB or more free for the BF16 decoder (5.73 GiB), cross-attention layers, encoder, activations and KV cache; a rented GPU for an hour, as the spec suggests, is the cheap way to judge whether its move quality and explanations are worth building around. The answer-time criterion could not be measured; the memory-bandwidth estimate above says it would be at best 4-8 s on a 3070 Ti anyway.
