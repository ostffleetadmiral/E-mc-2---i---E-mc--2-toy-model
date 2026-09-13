# Qstar-Transport

14 independent modules for encoding data across physical media. Zero dependencies.

## Quick Start

```bash
zig build test          # 122 tests
zig build run           # QR + polyglot + LoRa demo
```

## What This Is

Multi-modal data transport — encode data as QR codes, audio, video, cassette tapes, polyglot executables, steganographic images, LoRa radio packets, and more.

## Usage

```zig
const qr = @import("transport_qr");
const polyglot = @import("transport_polyglot");
const lora = @import("transport_lora");

// QR encoding
const encoded = try qr.encode(allocator, "HELLO WORLD");
const decoded = try qr.decode(allocator, encoded);

// Polyglot container (PNG+ZIP+JAR+PYZ)
const jar = try polyglot.encode(allocator, payload, .jar);
const data = try polyglot.decode(allocator, jar, .jar);

// LoRa packet
const packet = try lora.encode(allocator, payload, sf, freq);
```

## Modules

| Module | Lines | Tests | Description |
|--------|-------|-------|-------------|
| transport_qr.zig | 199 | 6 | QR code encoding with Huffman compression |
| transport_optar.zig | 202 | 5 | High-density optical data storage |
| transport_paperback.zig | 227 | 6 | Printable book format for archiving |
| transport_audio.zig | 161 | 3 | Data encoded as audio signals |
| transport_cassette.zig | 166 | 3 | Cassette tape data encoding |
| transport_polyglot.zig | 569 | 22 | PNG+ZIP+JAR+PYZ executable containers |
| transport_convert.zig | 206 | 6 | Format conversion utilities |
| transport_video.zig | 141 | 4 | Data encoded in video frames |
| transport_quine.zig | 104 | 3 | Self-reproducing code containers |
| transport_stega.zig | 161 | 4 | Steganographic embedding in images |
| transport_wifi.zig | 105 | 4 | WiFi packet transport |
| transport_p2p.zig | 221 | 6 | Peer-to-peer transport |
| transport_lora.zig | 834 | 22 | Sub-GHz ISM radio with FEC + ACK |
| maypole_bridge.zig | 695 | 28 | ESP32 WiFi-to-LoRa bridge |

**Total: 3,991 lines, 122 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
