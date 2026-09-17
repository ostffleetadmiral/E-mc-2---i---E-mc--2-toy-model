#!/usr/bin/env bash
# Build Maple v1.5 firmware + SPIFFS image (Phase 2 base layer)
# Usage: ./build.sh [--with-wasm]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/bin:$PATH"

FQBN="esp32:esp32:pico32"
LIB_FLAGS=(--library "$HERE/libraries/SimpleTimer" --library "$HERE/libraries/ESP32WebServer")

echo "==> Compiling firmware (v1.5, default partition)"
arduino-cli compile --fqbn "$FQBN" \
  "${LIB_FLAGS[@]}" \
  --output-dir "$HERE/build/"

echo "==> Building SPIFFS image (1,408 KB, matches default partition 0x290000)"
MKSPIFFS="$HOME/.arduino15/packages/esp32/tools/mkspiffs/0.2.3/mkspiffs"
DATA_DIR="$HERE/data"

# Optionally embed qstar wasm into the SPIFFS image (Phase 3 — device-lite)
if [[ "${1:-}" == "--with-wasm" ]]; then
  QSTAR_ROOT="$(cd "$HERE/../../../.." && pwd)"
  TMP_DATA="$(mktemp -d)"
  cp -r "$DATA_DIR"/. "$TMP_DATA"/
  DATA_DIR="$TMP_DATA"

  # Prefer device-lite wasm; also include full wasm if available
  WASM_LITE="${QSTAR_WASM_LITE:-$QSTAR_ROOT/zig-out/wasm/qstar_llm_esp32_lite.wasm}"
  WASM_FULL="${QSTAR_WASM_FULL:-$QSTAR_ROOT/zig-out/wasm/qstar_llm_esp32.wasm}"

  if [[ -f "$WASM_LITE" ]]; then
    echo "==> Embedding qstar_llm_lite.wasm ($(stat -c%s "$WASM_LITE") bytes)"
    cp "$WASM_LITE" "$TMP_DATA/qstar_llm_lite.wasm"
  else
    echo "!! qstar_llm_esp32_lite.wasm not found at $WASM_LITE"
  fi

  if [[ -f "$WASM_FULL" ]]; then
    echo "==> Embedding qstar_llm.wasm ($(stat -c%s "$WASM_FULL") bytes)"
    cp "$WASM_FULL" "$TMP_DATA/qstar_llm.wasm"
  else
    echo "!! qstar_llm_esp32.wasm not found at $WASM_FULL"
  fi

  if [[ ! -f "$WASM_LITE" && ! -f "$WASM_FULL" ]]; then
    echo "!! No wasm found in $QSTAR_ROOT/zig-out/wasm/ — building SPIFFS without wasm"
  fi
fi

"$MKSPIFFS" -c "$DATA_DIR" -p 256 -b 4096 -s 0x160000 "$HERE/build/Maple_V1_5.spiffs.bin"

echo "==> Artifacts:"
ls -la "$HERE/build/"*.bin
echo "==> Done."
