# 02 — ISG RGB Transcoder (`isg/`)

## Architecture Overview

### Purpose

The ISG (Infinite Storage Glitch) module implements a 2D holographic boundary surface for FANO-1's e9 quantum foam compression. It converts dense binary state data into flat 2D RGB video frames and back, with Q128.128-based error correction for lossy compression resilience.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `main.zig` | 307 | CLI: `pack`, `unpack`, `info` commands |
| `rgb_packer.zig` | 286 | Pack binary data → RGB video frames with block scaling |
| `rgb_unpacker.zig` | 305 | Unpack RGB frames → binary data with majority vote |
| `q128_error_correct.zig` | 371 | Q128.128 checksums, CRC32 header, majority vote, corruption stats |
| `video_io.zig` | 191 | Raw RGB frame file I/O (read/write single/multiple frames) |
| `build.zig` | 80 | Build system: executable + test targets |

### Dependencies

- **Internal**: `q128_128` module (from `../zig/q128_128.zig`)
- **External**: None (pure Zig)

### Data Flow

```
Binary data → rgb_packer → RGB video frames (raw) → [lossy channel] → rgb_unpacker → Binary data
                    ↓                                                      ↑
            q128_error_correct (checksum) ──── verification ──── q128_error_correct (verify + majority vote)
```

### Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Frame width | 1920 | Pixels per frame row |
| Frame height | 1080 | Pixels per frame column |
| Block scale | 4 | NxN pixel block per data byte |
| Magic header | `"FANOISG1"` | 8-byte file identification |
| Header size | 64 bytes | Embedded in first frame |
| Pixel encoding | R=G=B=byte | 3 bytes/pixel, 24-bit RGB |

### Capacity

- **Raw capacity per frame**: 1920×1080×3 = 6,220,800 bytes (~6.22 MB)
- **Effective capacity (4×4 blocks)**: 6,220,800 / 16 = 388,800 bytes/frame (~389 KB)
- **At 60fps**: ~23.3 MB/sec error-corrected throughput

---

## API Reference

### `main.zig` — CLI Interface

#### Commands

```
isg-rgb pack   <input> <output> [--width 1920] [--height 1080] [--block-scale 4]
isg-rgb unpack <input> <output> [--width 1920] [--height 1080] [--block-scale 4]
isg-rgb info   <input> [--width 1920] [--height 1080] [--block-scale 4]
```

#### `pack` Command

Reads input file, packs into RGB video frames using `rgb_packer.pack()`, writes raw frame data to output file. Embeds 64-byte header in first frame with magic, dimensions, block scale, data length, and Q128.128 checksum.

#### `unpack` Command

Reads RGB video frames, extracts header from first frame, unpacks data using `rgb_unpacker.unpack()` with majority vote error correction. Verifies Q128.128 checksum and reports corruption statistics.

#### `info` Command

Auto-detects frame dimensions and block scale from file size and header. Prints:
- Magic string validation
- Frame dimensions (width × height)
- Block scale
- Total frames
- Data length
- Q128.128 checksum (hex)
- Header CRC32 status

---

### `rgb_packer.zig`

#### Types

```zig
pub const PackConfig = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    block_scale: u32 = 4,
};
```

#### Key Functions

```zig
pub fn dataCapacityPerFrame(cfg: PackConfig) u64
pub fn totalFramesNeeded(data_len: u64, cfg: PackConfig) u64
pub fn pack(alloc: Allocator, data: []const u8, cfg: PackConfig) ![]u8
```

- **dataCapacityPerFrame**: Returns `(width × height × 3) / (block_scale²)` — bytes of data per frame after block scaling
- **totalFramesNeeded**: Computes frames required including header frame
- **pack**: Core packing function. Embeds 64-byte header in first frame, then writes each data byte as a `block_scale × block_scale` pixel block with R=G=B=byte_value

#### Packing Algorithm

1. Calculate total frames needed (data + header)
2. Allocate frame buffer: `frames × width × height × 3` bytes
3. Write header into first frame (64 bytes at top-left, block-scaled)
4. For each data byte `b` at index `i`:
   - Calculate frame index, pixel position within frame
   - Write `block_scale × block_scale` block of pixels with R=G=B=`b`
5. Return frame buffer

#### Test Coverage

| Test | Description |
|------|-------------|
| `capacity calculation` | Correct bytes per frame for various configs |
| `frame count` | Correct frame count for various data sizes |
| `small data round-trip` | Pack + unpack small payload |
| `multi-frame` | Data spanning multiple frames |
| `block scaling` | Verify block pixel replication |

---

### `rgb_unpacker.zig`

#### Types

```zig
pub const UnpackResult = struct {
    data: []u8,
    header: Header,
    corrupted_blocks: u64,
    total_blocks: u64,
    checksum_valid: bool,
};
```

#### Key Functions

```zig
pub fn unpack(alloc: Allocator, frames: []const u8, cfg: PackConfig) !UnpackResult
pub fn roundTripTest(alloc: Allocator, data: []const u8, cfg: PackConfig) !bool
```

#### Unpacking Algorithm

1. Read header from first frame (reverse of packing)
2. Extract `data_len`, `block_scale`, `checksum` from header
3. For each data byte position:
   - Read `block_scale × block_scale` pixel block
   - Apply `majorityVoteBlock()` to determine byte value
   - Write to output buffer
4. Compute Q128.128 checksum of recovered data
5. Compare with header checksum
6. Count corrupted blocks via `countCorruptedBlocks()`
7. Return `UnpackResult` with data and statistics

#### Test Coverage

| Test | Description |
|------|-------------|
| `round-trip exact` | Pack → unpack → byte-identical data |
| `corruption recovery` | Inject pixel errors, verify majority vote recovers |
| `checksum verification` | Valid and invalid checksum detection |
| `corruption statistics` | Correct corrupted/total block counts |
| `empty data` | Zero-length data handling |

---

### `q128_error_correct.zig`

#### Types

```zig
pub const Header = struct {
    magic: [8]u8,        // "FANOISG1"
    width: u32,
    height: u32,
    block_scale: u32,
    data_len: u64,
    checksum: u128,      // Q128.128 checksum (lower 128 bits)
    crc32: u32,          // Header integrity
    reserved: [20]u8,    // Padding to 64 bytes
};
```

#### Key Functions

```zig
pub fn computeChecksum(data: []const u8) u128
pub fn serializeHeader(hdr: Header) [64]u8
pub fn deserializeHeader(buf: []const u8) !Header
pub fn computeHeaderCRC32(hdr: Header) u32
pub fn verifyHeaderCRC32(hdr: Header) bool
pub fn majorityVoteBlock(pixels: []const u8, block_scale: u32) u8
pub fn countCorruptedBlocks(frames: []const u8, cfg: PackConfig) u64
```

#### Checksum Algorithm

Q128.128 checksum computed as a polynomial hash over data bytes using Q128.128 fixed-point arithmetic:

1. Initialize accumulator to Q128.128 zero
2. For each byte `b` at index `i`:
   - Multiply accumulator by prime constant (Q128.128)
   - Add `b` as Q128.128 integer
3. Return lower 128 bits of accumulator

This provides ~10^-39 precision error detection, far exceeding CRC32 or SHA-256 collision resistance for the ISG use case.

#### Majority Vote Error Correction

For each `block_scale × block_scale` pixel block:
1. Collect all `block_scale²` pixel values (R channel; R=G=B by construction)
2. Count occurrences of each byte value
3. Return the byte value with highest count
4. If all pixels agree → no corruption
5. If pixels disagree → corruption detected, majority value used

#### Test Coverage

| Test | Description |
|------|-------------|
| `checksum determinism` | Same data → same checksum |
| `checksum sensitivity` | 1-bit change → different checksum |
| `header serialize/deserialize` | Round-trip header |
| `CRC32` | Header integrity validation |
| `majority vote` | Correct recovery from corrupted blocks |
| `corruption counting` | Accurate corrupted block count |

---

### `video_io.zig`

#### Key Functions

```zig
pub fn writeFrames(path: []const u8, frames: []const u8, width: u32, height: u32) !void
pub fn readFrames(path: []const u8, width: u32, height: u32) ![]u8
pub fn countFrames(path: []const u8, width: u32, height: u32) !u64
pub fn writeSingleImage(path: []const u8, data: []const u8, width: u32, height: u32) !void
pub fn readSingleImage(path: []const u8, width: u32, height: u32) ![]u8
```

- **writeFrames**: Writes raw RGB frame data to file (no container format, just raw bytes)
- **readFrames**: Reads raw RGB frame data from file
- **countFrames**: Auto-detects frame count from file size / frame size
- **writeSingleImage / readSingleImage**: Debug utilities for single frame I/O

#### Test Coverage

| Test | Description |
|------|-------------|
| `write/read round-trip` | Frames written and read back identically |
| `frame count` | Auto-detection from file size |
| `single image` | Single frame I/O |

---

## Build Configuration (`build.zig`)

### Executable

| Name | Root Source | Description |
|------|-------------|-------------|
| `isg-rgb` | `main.zig` | ISG RGB transcoder CLI |

### Test Targets

| Name | Source | Description |
|------|--------|-------------|
| `test-error-correct` | `q128_error_correct.zig` | Checksum, CRC, majority vote |
| `test-packer` | `rgb_packer.zig` | Packing algorithm |
| `test-unpacker` | `rgb_unpacker.zig` | Unpacking + round-trip |
| `test-video-io` | `video_io.zig` | Frame file I/O |

### Build Commands

```bash
# Build ISG CLI
cd isg/ && zig build

# Run all tests
cd isg/ && zig build test

# Run specific test
cd isg/ && zig build test-error-correct
```

---

## Integration Points

- **VFS Interceptor** (`vfs/`): Uses ISG packing for model weight storage in RGB video format
- **Blockchain** (`blockchain/`): Uses ISG for chain history storage on public video platforms
- **Transport** (`transport/`): Uses ISG for polyglot file wrapping and air-gapped data transfer
- **Q128.128 Core** (`zig/`): Provides fixed-point arithmetic for checksum computation
