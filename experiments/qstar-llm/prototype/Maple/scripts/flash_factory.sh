#!/usr/bin/env bash
# flash_factory.sh — Maple factory reset via serial (esptool)
#
# Flashes the ORIGINAL Maypole v1.4 firmware from Maypole_firmware/Maypole_V1_4/bin/
# to the ESP32-PICO-D4 via the 6-pin header UART.
#
# Usage:
#   ./flash_factory.sh [PORT]     # e.g. /dev/ttyUSB0 (auto-detected if omitted)
#
# Requirements: esptool (pip install esptool) or esptool.py on PATH.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)/Maypole_firmware/Maypole_V1_4/bin"
BAUD=921600

if [[ ! -d "$BIN_DIR" ]]; then
  echo "ERROR: bin dir not found: $BIN_DIR" >&2
  exit 1
fi

# ── locate esptool ────────────────────────────────────────────────────────────
ESPT=""
for cand in esptool.py esptool; do
  if command -v "$cand" >/dev/null 2>&1; then ESPT="$cand"; break; fi
done
if [[ -z "$ESPT" ]] && python3 -c "import esptool" 2>/dev/null; then
  ESPT="python3 -m esptool"
fi
if [[ -z "$ESPT" ]]; then
  echo "ERROR: esptool not found. Install with: pip install esptool" >&2
  exit 1
fi

# ── locate serial port ────────────────────────────────────────────────────────
PORT="${1:-}"
if [[ -z "$PORT" ]]; then
  PORT="$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1 || true)"
fi
if [[ -z "$PORT" ]]; then
  echo "ERROR: no serial port found. Pass one explicitly: $0 /dev/ttyUSB0" >&2
  exit 1
fi
echo "Using port: $PORT"

# ── flash all regions ─────────────────────────────────────────────────────────
echo "Flashing factory firmware (baud $BAUD)..."
"$ESPT" --chip esp32 --port "$PORT" --baud "$BAUD" \
  --before default_reset --after hard_reset write_flash -z \
  --flash_mode dio --flash_freq 40m --flash_size detect \
  0x1000  "$BIN_DIR/Maypole_V1_4.ino.bootloader.bin" \
  0x8000  "$BIN_DIR/Maypole_V1_4.ino.partitions.bin" \
  0xe000  "$BIN_DIR/boot_app0.bin" \
  0x10000 "$BIN_DIR/Maypole_V1_4.ino.bin" \
  0x290000 "$BIN_DIR/Maypole_V1_4.spiffs.bin"

echo "OK — factory firmware flashed. Device will reboot into USB mode."
echo "Verify: serial @115200 shows 'USB mode Initialized'; plug into PC → USB mass storage."
