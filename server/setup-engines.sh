#!/usr/bin/env bash
# Installs Stockfish, lc0 (CPU, Eigen backend), Maia weights and Kokoro TTS into ./engines.
# Everything stays inside this directory; no root needed.
# Needs: gh (logged in), git, gcc/g++, ninja, uv.
set -euo pipefail

SF_TAG="${SF_TAG:-sf_19}"
LC0_TAG="${LC0_TAG:-v0.32.1}"
MAIA_TAG="v1.0"

root="$(cd "$(dirname "$0")" && pwd)/engines"
mkdir -p "$root/bin" "$root/weights" "$root/src"
cd "$root"

if [ ! -x bin/stockfish ]; then
  gh release download "$SF_TAG" -R official-stockfish/Stockfish \
    -p 'stockfish-linux-x86-64-universal.tar.gz' --clobber
  tar xzf stockfish-linux-x86-64-universal.tar.gz
  mv stockfish/stockfish-linux-x86-64-universal bin/stockfish
  chmod +x bin/stockfish
  cp stockfish/Copying.txt bin/stockfish-COPYING.txt
  rm -rf stockfish stockfish-linux-x86-64-universal.tar.gz
fi

for level in 1100 1200 1300 1400 1500 1600 1700 1800 1900; do
  [ -f "weights/maia-$level.pb.gz" ] || \
    gh release download "$MAIA_TAG" -R CSSLab/maia-chess -p "maia-$level.pb.gz" -D weights
done

# Kokoro TTS (CPU ONNX, int8 not used: fp32 sounds best and is fast enough).
mkdir -p tts
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [ -f "tts/$f" ] || gh release download model-files-v1.0 -R thewh1teagle/kokoro-onnx -p "$f" -D tts
done

if [ ! -x bin/lc0 ]; then
  # Release tarballs omit the proto submodule, so clone.
  [ -d src/lc0 ] || git clone -q --depth 1 --branch "$LC0_TAG" \
    --recurse-submodules --shallow-submodules https://github.com/LeelaChessZero/lc0.git src/lc0
  # Eigen backend, native CPU flags: rebuild on any machine with a different CPU.
  uvx --from meson meson setup src/lc0/build/release src/lc0 --buildtype release -Db_lto=true \
    -Dgtest=false -Dblas=true -Dopenblas=false -Dmkl=false -Ddnnl=false \
    -Dcudnn=false -Dplain_cuda=false -Dopencl=false -Donnx=false -Dxla=false
  ninja -C src/lc0/build/release
  cp src/lc0/build/release/lc0 bin/lc0
fi

echo "engines ready:"
ls -la bin weights
