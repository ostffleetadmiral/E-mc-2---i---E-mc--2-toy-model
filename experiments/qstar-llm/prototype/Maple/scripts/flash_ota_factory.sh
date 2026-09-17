#!/usr/bin/env bash
# flash_ota_factory.sh — Maple factory reset via OTA (web UI)
#
# Serves the ORIGINAL Maypole v1.4 firmware over the device's own OTA endpoint.
# No serial cable needed — device must be reachable on the network.
#
# Usage:
#   ./flash_ota_factory.sh [DEVICE_IP]   # default: 192.168.4.1 (AP mode)
#
# The device web UI also supports manual upload:
#   http://<ip>/FirmwareUpdate  → firmware: Maypole_V1_4.ino.bin
#                              → filesystem: Maypole_V1_4.spiffs.bin
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)/Maypole_firmware/Maypole_V1_4/bin"
IP="${1:-192.168.4.1}"

for f in Maypole_V1_4.ino.bin Maypole_V1_4.spiffs.bin; do
  [[ -f "$BIN_DIR/$f" ]] || { echo "ERROR: missing $BIN_DIR/$f" >&2; exit 1; }
done

echo "Factory reset via OTA at http://$IP"
echo "  Firmware:   $BIN_DIR/Maypole_V1_4.ino.bin"
echo "  Filesystem: $BIN_DIR/Maypole_V1_4.spiffs.bin"
echo
echo "Manual steps (no curl multipart support needed):"
echo "  1. Connect to AP 'pen_drive' (pwd 12345678) or device STA network"
echo "  2. Open http://$IP/FirmwareUpdate"
echo "  3. Upload Maypole_V1_4.ino.bin as Firmware"
echo "  4. Upload Maypole_V1_4.spiffs.bin as FileSystem"
echo "  5. Device restarts into factory firmware (USB mode default)"
