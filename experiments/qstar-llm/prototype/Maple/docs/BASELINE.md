# Maple — Baseline Verification (Phase 1)

Hardware bring-up baseline for the Maple (Maypole ESP32-PICO-D4) prototype.
Source: `prototype/Maypole_firmware/` — firmware v1.4, PCB project PRJ_T3.

## Hardware Summary

| Component | Part | Role |
|---|---|---|
| MCU | ESP32-PICO-D4 | Dual-core Xtensa LX6 @ 240 MHz, 520 KB SRAM, 4 MB flash |
| USB-SD bridge | GL823K | Presents SD card as USB mass storage (USB flash drive mode) |
| SPI buffer | 74ABT125 | Switches SPI bus between ESP32 and GL823K |
| Charger | BQ24040 | Li-ion battery charging |
| Power mux | TPS2113 | Auto-switch USB 5V ↔ battery |
| LDO | 3.3V | ESP32 + logic supply |
| Storage | microSD slot (DM3AT) | Shared between GL823K (USB mode) and ESP32 (SD mode) |
| Connector | USB-A male | Host connection (powers device + GL823K bus) |
| Programming | 6-pin header | UART for ESP32 flashing (ESP32 is NOT on the USB-A bus) |

## GPIO Map (from Maypole_V1_4.ino)

| Pin | Direction | Function | Active |
|---|---|---|---|
| 25 | OUT | Buffer select: LOW = ESP owns SD/SPI, HIGH = GL823K owns SD | — |
| 26 | OUT | SD chip detect (to GL823K) | LOW = card present |
| 4 | OUT | microSD power MOSFET | HIGH = powered |
| 27 | OUT | SD RESET | — |
| SPI (VSPI) | — | SD data bus (SCK=18, MISO=19, MOSI=23, CS=5) | — |

## Mode-Switch Sequences (timing from .ino)

### USB mode (default at boot) — `change_to_usb_mode()`
1. `SD.end()` + `SPI.end()`
2. `pin4 = LOW` (SD power off)
3. **t+500 ms:** `pin27 = HIGH` (SD reset), `pin4 = HIGH` (SD power on)
4. **t+100 ms:** `pin25 = HIGH` (buffer → GL823K), `pin26 = LOW` (card detect → GL823K sees card)
5. Host PC enumerates SD as USB mass storage

### SD mode — `change_to_sd_mode()`
1. `pin25 = LOW` (buffer → ESP), `pin4 = LOW` (SD power off)
2. **t+100 ms:** `pin4 = HIGH` (SD power on), `pin27 = LOW` (SD reset), `pin26 = HIGH`
3. `delay(20)`, `pin25 = LOW` (buffer → ESP)
4. `while(!SD.begin())` retry loop → `SD_present = true`

## Flash Layout (parsed from partitions.bin)

| Region | Offset | Size | Purpose |
|---|---|---|---|
| bootloader | 0x1000 | 64 KB | Second-stage bootloader |
| partitions | 0x8000 | 4 KB | Partition table |
| nvs | 0x9000 | 20 KB | Non-volatile storage (WiFi creds etc.) |
| otadata | 0xe000 | 8 KB | OTA selection data |
| app0 | 0x10000 | 1,280 KB | Firmware slot A (factory) |
| app1 | 0x150000 | 1,280 KB | Firmware slot B (OTA target) |
| spiffs | 0x290000 | 1,472 KB (bin) / **1,408 KB (measured on device)** | Web assets (HTML/PNG/JSON) |

> **⚠️ Measured discrepancy (2026-09-01):** the live device reports its spiffs
> partition as **0x160000 (1,441,792 B)** via `/api/diag`, NOT the 0x170000
> parsed from the v1.4 bin's partitions.bin. SPIFFS images must be built at
> `-s 0x160000` (build.sh does this). Verify the device's real partition table
> with `esptool read_flash 0x8000 0x1000` before Stage 2.

**Implications:**
- Dual OTA slots — `Update.h` writes to the inactive slot; rollback possible via otadata
- App slot 1.25 MB fits firmware + 561 KB `qstar_llm.wasm`
- SPIFFS 1.44 MB is too small for the 10 MB `universe.html` → SD card serving required

## Factory-Reset Binaries (original firmware, `Maypole_V1_4/bin/`)

| File | Offset | Size | MD5 |
|---|---|---|---|
| boot_app0.bin | 0xe000 | 8 KB | `e6327541e2dc394ca2c3b3280ac0f39f` |
| Maypole_V1_4.ino.bootloader.bin | 0x1000 | 18 KB | `1e9d15ffe040efc9c3415a2b6f345fba` |
| Maypole_V1_4.ino.partitions.bin | 0x8000 | 3 KB | `b3a1040c8763614dc1f6386bd9d0f0be` |
| Maypole_V1_4.ino.bin | 0x10000 | 849 KB | `2c16e7554dbbab00e8bf83cebb3752e4` |
| Maypole_V1_4.spiffs.bin | 0x290000 | 1.5 MB | `cc6e33ea531dbb6d78c111d0988f1bf9` |

## Factory Reset Paths

1. **Serial (esptool)** — `scripts/flash_factory.sh` (6-pin header UART, baud 921600)
2. **OTA (web UI)** — upload `Maypole_V1_4.ino.bin` via `/FirmwareUpdate` (firmware) + `Maypole_V1_4.spiffs.bin` via filesystem form; device restarts into factory firmware

## Baseline Checklist (requires physical device)

- [ ] Device connected via 6-pin header UART (`/dev/ttyUSB*`)
- [ ] `scripts/flash_factory.sh` completes with exit 0
- [ ] Boot log on serial @ 115200 shows "USB mode Initialized"
- [ ] Plugged into PC → enumerates as USB mass storage
- [ ] AP `pen_drive` / `12345678` reachable; `192.168.4.1` serves homepage
- [ ] SD mode switch works; file upload/download/delete OK
- [ ] OTA update + restart works
- [ ] Factory reset via OTA original firmware verified
