# Maple — Physical Quine Prototype

The Maple is a pocket AI device built on the Maypole hardware (ESP32-PICO-D4 USB pen
drive). This is **Stage 1 (prototype)**: the existing Arduino v1.4 firmware is the
immutable base layer; Qstar capabilities are added on top via a hybrid architecture.
Stage 2 (fresh firmware via reverse engineering + Retro-Dev) is unlocked by Stage 1
success.

## Architecture (Hybrid)

| Channel | Mechanism | Status |
|---|---|---|
| USB storage | GL823K bridge (existing) | baseline |
| Browser AI | `universe.html` quine served from SD | planned |
| On-device AI | wasm3 + `qstar_llm_esp32.wasm` in SPIFFS | wired; full agent exceeds device RAM (see Phase 3) |
| Updates | OTA ↔ `seed_manifest.json` autoupdate | planned |

## Layout

```
prototype/Maple/
├── docs/
│   └── BASELINE.md        # Phase 1: partition table, pin map, mode-switch timing
├── scripts/
│   ├── flash_factory.sh   # serial factory reset (esptool, 6-pin header UART)
│   └── flash_ota_factory.sh # OTA factory reset via web UI
├── tools/
│   └── wasm3/             # vendored wasm3 v0.5.0 interpreter
└── firmware/
    └── Maple_V1_5/        # Phase 2: Arduino v1.5 base layer
        ├── Maple_V1_5.ino # v1.4 + Qstar routes (/api/agent, /chat, /quine)
        ├── partitions.csv # byte-identical to v1.4 baseline
        ├── libraries/     # vendored SimpleTimer + ESP32WebServer
        ├── data/          # SPIFFS web assets
        ├── build.sh       # reproducible firmware + SPIFFS build
        └── build/         # artifacts (.ino.bin, .spiffs.bin, partitions.bin)
```

## Phase Status

| # | Phase | Status |
|---|---|---|
| 1 | Baseline verification (factory reset + docs) | docs done; **device verified live** (v1.4 → v1.5 OTA) |
| 2 | Base layer v1.5 (Arduino) | **flashed + verified on device** — partitions byte-identical to v1.4 |
| 3 | wasm3 on-device inference | **wired + verified on device** — wasm3 loads `qstar_llm.wasm` from SPIFFS, reports precise RAM diagnostic (needs ~703 KB vs ~171 KB free heap); device-lite wasm is the documented fallback (see docs/MAPLE.md) |
| 4 | Quine serving from SD | **verified on device (32 GB SD)** — `/quine` streams `universe.html` byte-identical (10,149,664 B); payload uploaded via `/upload` |
| 5 | Corpus on SD | **verified on device** — `qstar_corpus_distilled.txt` (7 MB) + `seed_manifest.json` on SD; agent corpus loading pending device-lite wasm |
| 6 | Quine autoupdate | manifest flow documented (docs/MAPLE.md); device-side fetch/apply pending |
| 7 | Test & docs | **docs/MAPLE.md written** (OTA protocol, WASM↔HTTP bridge, partition reality, device-lite spike) |

## On-Device Fixes Applied (2026-09-01)

1. **SPIFFS mount fallback** — `SPIFFS.begin()` failed on the factory partition; added format+remount in setup
2. **OTA filesystem update** — unmount SPIFFS before `Update.begin(U_SPIFFS)`; image built at `-s 0x160000` to match the device's ACTUAL partition (1,441,792 B — the archived v1.4 bin says 0x170000, but the device differs!)
3. **Update diagnostics** — `/api/agent` reports `update_error` (Update.getError() code) + progress/size; `/api/diag` reports partition erase/write `esp_err_t`

## Quick Start (device in hand)

```bash
# 1. Factory reset via serial (6-pin header UART)
./scripts/flash_factory.sh /dev/ttyUSB0

# or via OTA (device on network)
./scripts/flash_ota_factory.sh 192.168.4.1

# 2. Verify baseline (see docs/BASELINE.md checklist)
```

## Build v1.5 (no device needed)

```bash
cd firmware/Maple_V1_5
./build.sh            # firmware + SPIFFS (web assets only)
./build.sh --with-wasm # + embed qstar_llm_esp32.wasm (342 KB) into SPIFFS
```

Artifacts in `build/`: `Maple_V1_5.ino.bin` (1.17 MB, 89% of app slot),
`Maple_V1_5.spiffs.bin` (1.47 MB), `Maple_V1_5.ino.partitions.bin` (MD5
`b3a1040c…` — identical to v1.4).

## v1.5 New Routes (Qstar)

| Route | Purpose |
|---|---|
| `/api/agent` | JSON device/agent status (version, SD, WiFi, agent state, wasm3 status/version, corpus count, free heap) |
| `/api/agent/generate` | POST prompt → wasm3 on-device inference (503 with diagnostic if wasm3 not ready) |
| `/chat` | Chat UI (POSTs to `/api/agent/generate`) |
| `/quine` | Streams `universe.html` from SD card |

## Phase 3 — Measured Memory Constraint

The full-agent wasm (`qstar_llm_esp32.wasm`, 342 KB) cannot run on the
ESP32-PICO-D4 (520 KB SRAM, ~276 KB free heap):

- wasm binary must persist in RAM for the module lifetime (wasm3 requirement): **342 KB**
- wasm linear memory (5 pages, data 184 KB + stack 4 KB + heap 32 KB): **320 KB**
- wasm3 runtime + 32 KB call stack: **~40 KB**
- **Total: ~700 KB vs ~276 KB free heap**

The firmware wires the full wasm3 pipeline (load → parse → `qstar_init` →
`/api/agent/generate`) and reports a precise diagnostic via `/api/agent` when the
load cannot fit. The documented fallback is a **device-lite wasm build** (reduced
response-template corpus, keeping the retrieval-based generation path) — a
deliberate capability trade-off to be decided when the device is in hand.

Plan: `/home/admpaul/.windsurf/plans/maple-physical-quine-4708f0.md`
