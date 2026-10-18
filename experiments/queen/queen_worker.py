"""Long-lived QUEEN runner: load the model once, answer many FENs.

infer.py loads the whole model for every call (it is a one-shot CLI), so a cold start
is paid per position. This worker repeats infer.py's setup and per-position logic
verbatim (same env vars, same ChessFlamingoGenerator arguments, same request seed
derivation, same choose_move) but constructs the generator once, so load time and
per-answer time can be measured separately.

Run it with the model's own venv python (it imports vLLM/torch from there):

    queen_pawn-8/.venv/bin/python queen_worker.py --model-dir queen_pawn-8 \
        --positions positions.json --out rows.jsonl --gpu-memory-utilization 0.6

It appends one JSON object per line to --out (flushed immediately):
    {"event": "loaded", "load_s": ..., "cuda_free_mib": ..., "cuda_total_mib": ...}
    {"event": "answer", "id": ..., "gen_s": ..., "text": ..., "raw_text": ...,
     "best_move_uci": ..., "move_source": ..., ...}
    {"event": "error", "id": ..., "error": ...}
A failure while loading raises (non-zero exit, traceback in the log); run_trial.py
reads the log to record the OOM text.
"""
import argparse
import hashlib
import json
import os
import sys
import time
import traceback
from pathlib import Path


def emit(path, obj):
    with open(path, 'a', encoding='utf-8') as fh:
        fh.write(json.dumps(obj, ensure_ascii=False) + '\n')
        fh.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, required=True)
    parser.add_argument('--positions', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--max-tokens', type=int, default=2048)
    parser.add_argument('--temperature', type=float, default=0.6)
    parser.add_argument('--seed', type=int, default=20260823)
    parser.add_argument('--game-id', type=int, default=0)
    parser.add_argument('--gpu-memory-utilization', type=float, default=0.72)
    parser.add_argument('--dtype', choices=['bfloat16', 'float16'], default='bfloat16')
    args = parser.parse_args()
    model_dir = args.model_dir.resolve()
    settings = json.loads((model_dir / 'inference_config.json').read_text())
    prompt = settings['prompt']
    positions = json.loads(args.positions.read_text())

    # Same preamble as infer.py; must precede the vLLM import.
    sys.path.insert(0, str(model_dir))
    os.environ['PYTHONPATH'] = str(model_dir)
    os.environ['VLLM_ENABLE_V1_MULTIPROCESSING'] = '0'
    os.environ['VLLM_USE_FLASHINFER_SAMPLER'] = '0'
    os.environ['VLLM_DISABLE_REQUEST_ID_RANDOMIZATION'] = '1'
    os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
    os.environ.setdefault('OMP_NUM_THREADS', '1')
    os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
    import chess
    import torch
    if not torch.cuda.is_available():
        raise SystemExit('CUDA is unavailable.')
    if args.dtype == 'bfloat16' and not torch.cuda.is_bf16_supported():
        raise SystemExit('GPU does not support BF16.')
    from models.vllm.flamingo_generate import ChessFlamingoGenerator
    from utils.translate_helpers import Translator
    from utils.eval_policy import choose_move

    t0 = time.perf_counter()
    generator = ChessFlamingoGenerator(
        model_dir, model_dir / 'lc0', dtype=args.dtype,
        gpu_memory_utilization=args.gpu_memory_utilization,
        max_model_len=args.max_tokens + 256, max_num_seqs=32, seed=args.seed,
        enforce_eager=True, use_v1_vllm=True)
    load_s = time.perf_counter() - t0
    free, total = torch.cuda.mem_get_info()
    emit(args.out, {'event': 'loaded', 'load_s': load_s,
                    'cuda_free_mib': free // 2**20, 'cuda_total_mib': total // 2**20,
                    'torch_allocated_mib': torch.cuda.memory_allocated() // 2**20,
                    'torch_max_allocated_mib': torch.cuda.max_memory_allocated() // 2**20})

    for pos in positions:
        try:
            board = chess.Board(pos['fen'])
            digest = hashlib.blake2b(f'{args.seed}|{args.game_id}|{board.ply()}'.encode(),
                                     digest_size=8).digest()
            request_seed = int.from_bytes(digest, 'big') % (2**31 - 1)
            t = time.perf_counter()
            result = generator.generate(
                [board.fen()], [prompt], [[]], max_tokens=args.max_tokens,
                temperature=args.temperature, top_k=20, top_p=0.95,
                repetition_penalty=1.0, seeds=[request_seed])[0]
            gen_s = time.perf_counter() - t
            raw = result['text']
            best, source, critical = choose_move(board.fen(), raw, request_seed,
                                                 settings['move_policy'])
            legal_best = best if best is not None and best in board.legal_moves else None
            free, _ = torch.cuda.mem_get_info()
            emit(args.out, {
                'event': 'answer', 'id': pos['id'], 'fen': board.fen(), 'gen_s': gen_s,
                'text': Translator(board.turn).decode_absolute(raw), 'raw_text': raw,
                'best_move_uci': legal_best.uci() if legal_best else None,
                'move_source': source, 'critical_line': critical,
                'finish_reason': result.get('finish_reason'),
                'generated_tokens': len(result['token_ids']),
                'cuda_free_mib_after': free // 2**20,
                'torch_max_allocated_mib': torch.cuda.max_memory_allocated() // 2**20})
        except Exception:
            emit(args.out, {'event': 'error', 'id': pos['id'], 'error': traceback.format_exc()})


if __name__ == '__main__':
    main()
