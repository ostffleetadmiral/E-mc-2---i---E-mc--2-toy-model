# 06 — Air-Gap Transport (`transport/`)

## Architecture Overview

### Purpose

The transport module implements omni-channel data transfer for FANO-1 OS, enabling state synchronization across air-gapped environments. It provides four independent transport mechanisms: polyglot file wrappers, FSK audio modem, optical QR tokens, and LSB steganography.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `polyglot.zig` | 360 | Multi-format binaries: PNG+ZIP, HTML+ZIP polyglots |
| `fsk_modem.zig` | 292 | Frequency-shift keying audio modem for cassette/RF |
| `optical_token.zig` | 360 | <100 byte URL-less routing tokens with QR rendering |
| `steganography.zig` | 300 | Multi-image LSB steganography for payload hiding |
| `build.zig` | 53 | Build system: test targets |

### Dependencies

- **Internal**: `q128_128` module (from `../zig/q128_128.zig`) — used by FSK modem and optical token
- **External**: None (pure Zig; uses `std.crypto.hash.blake2`, `std.hash.Crc32`, `std.hash.Wyhash`)

### Transport Channels

```
┌─────────────────────────────────────────────────────┐
│                  FANO-1 State Vector                │
└──────────┬──────────┬──────────┬──────────┬─────────┘
           ↓          ↓          ↓          ↓
     ┌──────────┐ ┌────────┐ ┌────────┐ ┌──────────┐
     │ Polyglot │ │  FSK   │ │ Optical│ │  LSB     │
     │  Files   │ │ Modem  │ │ Tokens │ │  Stego   │
     │PNG+ZIP   │ │Audio   │ │QR Code │ │Images    │
     └──────────┘ └────────┘ └────────┘ └──────────┘
           ↓          ↓          ↓          ↓
     File system  Cassette/RF  Paper/QR   Cover images
```

---

## API Reference

### `polyglot.zig`

#### Types

```zig
pub const PolyglotConfig = struct {
    include_png: bool = true,
    include_zip: bool = true,
    include_html: bool = false,
    include_pdf: bool = false,
};

pub const FormatSet = struct {
    png: bool = false,
    zip: bool = false,
    html: bool = false,
    pdf: bool = false,
};
```

#### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `PNG_SIGNATURE` | `89 50 4E 47 0D 0A 1A 0A` | 8-byte PNG header |
| `ZIP_EOCD_SIGNATURE` | `50 4B 05 06` | ZIP End of Central Directory |
| `ZIP_LOCAL_HEADER` | `50 4B 03 04` | ZIP Local File Header |
| `HTML_PREFIX` | `<!DOCTYPE html>` | HTML doctype |
| `PDF_PREFIX` | `%PDF-1.4` | PDF header |

#### Key Functions

```zig
pub fn buildPngZipPolyglot(alloc: Allocator, payload: []const u8, width: u32, height: u32) ![]u8
pub fn extractPngZipPayload(data: []const u8) ![]const u8
pub fn buildHtmlZipPolyglot(alloc: Allocator, payload: []const u8, html_content: []const u8) ![]u8
pub fn isPng(data: []const u8) bool
pub fn isZip(data: []const u8) bool
pub fn isHtml(data: []const u8) bool
pub fn isPdf(data: []const u8) bool
pub fn detectFormats(data: []const u8) FormatSet
```

#### Polyglot Construction

**PNG+ZIP**: PNG signature + IHDR chunk at start (PNG parser reads from front). ZIP local file header + payload embedded in IDAT chunk. ZIP EOCD appended at end (ZIP parser reads from EOF). Result: valid PNG image AND valid ZIP archive simultaneously.

**HTML+ZIP**: HTML doctype + `<!--` comment containing ZIP data + `-->` + HTML content. ZIP EOCD at end.

#### Test Coverage (10 tests)

| Test | Description |
|------|-------------|
| `isPng` | PNG signature detection |
| `isZip` | ZIP local header detection |
| `isHtml` | HTML doctype detection |
| `isPdf` | PDF header detection |
| `buildPngZipPolyglot round-trip` | Build + extract payload |
| `PNG structure valid` | Correct signature + IHDR |
| `detectFormats on polyglot` | PNG+ZIP both detected |
| `detectFormats on plain data` | No formats detected |
| `buildHtmlZipPolyglot` | HTML+ZIP both detected |
| `large payload` | 1000-byte payload round-trip |

---

### `fsk_modem.zig`

#### Types

```zig
pub const FskConfig = struct {
    sample_rate: u32 = 44100,
    baud_rate: u32 = 1200,
    mark_freq: f64 = 1200.0,   // Logic 1
    space_freq: f64 = 600.0,   // Logic 0
    amplitude: f64 = 0.8,
};

pub const FskModem = struct {
    config: FskConfig,
    phase: f64 = 0.0,
    samples_per_bit: u32,
    // Methods: init(), encodeBit(), encodeByte(), encodeData(),
    //          detectFrequency(), decodeBit(), decodeByte(), decodeData()
};
```

#### Key Functions

```zig
pub fn encodeQ128(alloc: Allocator, modem: *FskModem, v: q128) ![]f32
pub fn decodeQ128(modem: *const FskModem, samples: []const f32) q128
pub fn generatePreamble(alloc: Allocator, modem: *FskModem, bits: u32) ![]f32
pub fn throughput(config: FskConfig) f64
pub fn estimateSnr(samples: []const f32) f64
```

#### Modulation

- **Encoding**: Each bit → `samples_per_bit` audio samples at mark (1) or space (0) frequency
- **Decoding**: Zero-crossing counting detects dominant frequency per bit window
- **Threshold**: `(mark_freq + space_freq) / 2` — above = 1, below = 0
- **Q128.128 transmission**: 32 bytes → 256 bits → 256 × `samples_per_bit` audio samples
- **Preamble**: Alternating 1-0 pattern for clock synchronization
- **Throughput**: 1200 baud default (1.2 kbps), configurable up to 9600

#### Test Coverage (10 tests)

| Test | Description |
|------|-------------|
| `FskModem init` | Config + samples_per_bit calculation |
| `encodeBit` | Non-zero samples produced |
| `encode/decode byte` | 0x42 round-trip |
| `encode/decode data` | Multi-byte array round-trip |
| `detectFrequency` | Mark > space frequency |
| `encodeQ128/decodeQ128` | Q128.128 value round-trip |
| `generatePreamble` | Alternating pattern, correct length |
| `throughput` | Baud rate = throughput |
| `estimateSnr` | Positive SNR for clean signal |
| `multiple bytes` | "Hello, FANO-1!" round-trip |
| `higher baud rate` | 9600 baud with 0xDEADBEEF |

---

### `optical_token.zig`

#### Types

```zig
pub const TokenType = enum(u4) {
    boot = 0, sync = 1, contract = 2, message = 3, payment = 4,
};

pub const SerializedToken = struct {
    data: [100]u8 = [_]u8{0} ** 100,
    len: usize = 0,
    // Method: slice() -> []const u8
};

pub const OpticalToken = struct {
    version: u4 = 1,
    token_type: TokenType,
    flags: u4 = 0,
    timestamp: u32,
    payload_hash: [16]u8,    // Blake2b-128
    payload: []const u8,     // Max 78 bytes after 22-byte header
    // Methods: serialize(), deserialize(), hash(), verify()
};
```

#### Token Format (22-byte header + ≤78-byte payload = ≤100 bytes total)

```
Offset  Size  Field
0       1     Version (4 bits) | TokenType (4 bits)
1       1     Flags
2       4     Timestamp (u32 LE)
6       16    Payload hash (Blake2b-128)
22      ≤78   Compressed payload
```

#### Key Functions

```zig
pub fn createBootToken(node_id: *const [16]u8, timestamp: u32) OpticalToken
pub fn createSyncToken(state_hash: *const [16]u8, timestamp: u32) OpticalToken
pub fn encodeQ128Payload(v: q128) [32]u8
pub fn decodeQ128Payload(payload: []const u8) !q128
pub fn compressPayload(alloc: Allocator, data: []const u8) ![]u8   // RLE zero compression
pub fn decompressPayload(alloc: Allocator, data: []const u8) ![]u8
pub fn renderQrMatrix(token: OpticalToken) [441]u8  // 21×21 QR grid
```

#### Features

- **Integrity**: Blake2b-128 payload hash, verified on deserialize
- **Compression**: RLE encoding of zero runs for sparse payloads
- **QR rendering**: Simplified 21×21 matrix with finder patterns (not a full QR encoder)
- **Q128.128 encoding**: 32-byte fixed-point values as token payloads

#### Test Coverage (14 tests)

| Test | Description |
|------|-------------|
| `serialize/deserialize round-trip` | Token round-trip with all fields |
| `verify` | Payload integrity check passes |
| `verify rejects tampered` | Modified payload fails verification |
| `createBootToken` | Boot token creation + verify |
| `createSyncToken` | Sync token creation + verify |
| `encodeQ128Payload/decodeQ128Payload` | Q128.128 round-trip |
| `compress/decompress round-trip` | RLE compression round-trip |
| `compress reduces size` | Sparse data compresses |
| `compress no zeros` | Non-zero data unchanged |
| `deserialize rejects short` | <22 bytes → error |
| `deserialize rejects long` | >100 bytes → error |
| `hash deterministic` | Same token → same hash |
| `renderQrMatrix` | 21×21 grid with finder patterns |
| `max size 100 bytes` | Maximum payload fits in 100 bytes |

---

### `steganography.zig`

#### Types

```zig
pub const LsbStego = struct {
    // Methods: init(), capacity(), embed(), extract(), splitPayload(), reassemblePayload()
};

pub const CoverImage = struct {
    width: u32,
    height: u32,
    channels: u3,   // 3 = RGB, 4 = RGBA
    pixels: []u8,
    // Methods: capacity(), embed(), extract()
};
```

#### Key Functions

```zig
pub fn createCoverImage(alloc: Allocator, width: u32, height: u32, channels: u3) !CoverImage
```

#### LSB Encoding

- **Capacity**: `(width × height × channels) / 8` bytes (1 bit per channel)
- **Header**: First 32 bits (4 bytes) store payload length in little-endian
- **Embedding**: Each payload bit replaces LSB of next pixel channel byte
- **Extraction**: Read 32-bit length header, then extract `length × 8` bits as payload
- **1920×1080 RGB capacity**: ~6.2 MB

#### Test Coverage (11 tests)

| Test | Description |
|------|-------------|
| `capacity 10×10 RGB` | 37 bytes |
| `capacity 100×100 RGB` | 3750 bytes |
| `embed/extract round-trip` | Text payload |
| `embed/extract binary` | Binary data round-trip |
| `rejects too large` | PayloadTooLarge error |
| `empty payload` | Zero-length handling |
| `preserves dimensions` | Image size unchanged |
| `splitPayload/reassemble` | Multi-chunk round-trip |
| `split exact division` | Even chunk sizes |
| `split single chunk` | Small data = 1 chunk |
| `CoverImage capacity` | Delegated capacity calculation |
| `larger image round-trip` | 64×64 image |

---

## Build Configuration (`build.zig`)

### Test Targets

| Name | Source | Q128 dep | Description |
|------|--------|----------|-------------|
| `test-fsk-modem` | `fsk_modem.zig` | Yes | FSK audio modem |
| `test-optical-token` | `optical_token.zig` | Yes | QR tokens |
| `test-steganography` | `steganography.zig` | No | LSB stego |
| `test-polyglot` | `polyglot.zig` | No | Polyglot files |

### Build Commands

```bash
cd transport/ && zig build test
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Fixed-point values encoded for FSK and optical tokens
- **Blockchain** (`blockchain/`): Transactions transported via polyglots, FSK, QR tokens
- **ISG Transcoder** (`isg/`): RGB video frames as polyglot payloads
- **VFS Interceptor** (`vfs/`): Folded models transported via steganography
- **Quine HTML** (`quine.html/`): HTML+ZIP polyglots for browser delivery
- **Space Agent** (`space-agent/`): Optical tokens for zero-config node bootstrapping
