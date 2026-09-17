#!/usr/bin/env bash
# prepare_sd.sh — Assemble the Maple SD card payload (Phase 4/5/6 prep)
#
# Creates a directory (or mounts an SD image) containing the quine + corpus +
# manifest payloads the Maple serves from SD in SD mode:
#   /universe.html               — 10 MB browser quine (served via /quine)
#   /qstar_corpus_distilled.txt  — 7 MB distilled corpus (agent learning)
#   /seed_manifest.json          — update manifest (Phase 6 autoupdate)
#   /qstar_llm.wasm              — browser wasm (quine's embedded copy is authoritative)
#
# Usage:
#   ./prepare_sd.sh [OUT_DIR]    # default: ./sd_card
#
# The device's /quine route streams /universe.html from SD; the agent reads
# corpus pages on demand. Copy the OUT_DIR contents to a FAT32 microSD card.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
QSTAR_ROOT="$(cd "$HERE/../../.." && pwd)"
OUT_DIR="${1:-$HERE/../sd_card}"

mkdir -p "$OUT_DIR"

# ── payload sources (zig-out/master is the authoritative publish dir) ─────────
MASTER_DIR="$QSTAR_ROOT/zig-out/master"
declare -A PAYLOADS=(
  [universe.html]="$MASTER_DIR/universe.html"
  [qstar_corpus_distilled.txt]="$MASTER_DIR/qstar_corpus_distilled.txt"
  [seed_manifest.json]="$MASTER_DIR/seed_manifest.json"
  [qstar_llm.wasm]="$MASTER_DIR/qstar_llm.wasm"
)

for name in "${!PAYLOADS[@]}"; do
  src="${PAYLOADS[$name]}"
  if [[ -f "$src" ]]; then
    cp "$src" "$OUT_DIR/$name"
    echo "  + $name ($(stat -c%s "$src") bytes)"
  else
    echo "  !! $name MISSING at $src (run 'zig build master' first)"
  fi
done

echo
echo "==> SD payload ready in $OUT_DIR"
du -sh "$OUT_DIR"
echo "Copy contents to a FAT32 microSD card, insert into the Maple,"
echo "then switch to SD mode (homepage → 'Switch to SD Mode')."
echo "Quine: http://192.168.4.1/quine"
