# 03 — VFS Interceptor (`vfs/`)

## Architecture Overview

### Purpose

The VFS (Virtual File System) interceptor module intercepts model file reads and transparently folds large model weights through the FANO-1 holographic compression pipeline. It serves folded/unfolded data on demand, enabling 120B+ models to run in constrained memory by streaming only active slices.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `intercept.zig` | 329 | Core interceptor: FD tracking, model detection, read/seek redirection |
| `fold_pipeline.zig` | 238 | Folding pipeline: raw bytes → holo.Grid → fold → serialize |
| `model_proxy.zig` | 331 | HTTP server: serves folded model slices to Ollama on-demand |
| `build.zig` | 65 | Build system: test targets |

### Dependencies

- **Internal**: `q128_128` module (from `../zig/q128_128.zig`), `holo` module (from `../zig/holo.zig`)
- **External**: None (pure Zig; HTTP server uses `std.http.Server`)

### Data Flow

```
Application opens model file
        ↓
intercept.zig: shouldIntercept() → detects .gguf/.bin/.safetensors
        ↓
fold_pipeline.zig: rawBytesToGrid() → holo.fold() → serialize folded model
        ↓
intercept.zig: serves unfolded data on read() calls
        ↓
model_proxy.zig: HTTP endpoint → unfold slice → return raw bytes to Ollama
```

### Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| HTTP port | 9471 | Model proxy server port |
| Folded file magic | `"FANOFLD1"` | 8-byte identification for folded models |
| Intercepted extensions | `.gguf`, `.bin`, `.safetensors`, `.pt`, `.ckpt` | Model file types |
| Max grid side | 513 | Maximum model grid dimension (512+1 perimeter) |

### Compression Ratios

- **120B model (~120GB FP16)**: Folds to ~15GB folded state
- **513³ → 16³ compression**: 134M nodes → 4,096 nodes (32,908:1)
- **Fits in 12GB RAM** via mmap streaming of folded slices

---

## API Reference

### `intercept.zig`

#### Types

```zig
pub const InterceptedFD = struct {
    fd: i32,
    folded_data: []const u8,    // Serialized folded model
    holo: holo.Hologram,        // Deserialized hologram
    offset: u64,                // Current read offset
    total_size: u64,            // Original (unfolded) file size
    path: []const u8,           // Original file path
};

pub const InterceptConfig = struct {
    extensions: []const []const u8 = &.{ ".gguf", ".bin", ".safetensors", ".pt", ".ckpt" },
    auto_fold: bool = true,
    cache_folded: bool = true,
};
```

#### Key Functions

```zig
pub fn shouldIntercept(path: []const u8, cfg: InterceptConfig) bool
pub fn registerFD(fd: i32, path: []const u8, cfg: InterceptConfig) !void
pub fn unregisterFD(fd: i32) void
pub fn readIntercepted(fd: i32, buf: []u8) !usize
pub fn seekIntercepted(fd: i32, offset: u64, whence: u32) !u64
pub fn getInterceptedSize(fd: i32) ?u64
pub fn loadAndFold(path: []const u8, alloc: Allocator) !InterceptedFD
```

#### Interception Logic

1. **`shouldIntercept`**: Checks file extension against configured list via `fold_pipeline.isModelFile()`
2. **`registerFD`**: Called when application opens a file. If `shouldIntercept` returns true:
   - Load file data
   - Call `fold_pipeline.foldModel()` to fold model weights
   - Store `InterceptedFD` in global registry
3. **`readIntercepted`**: Serves unfolded data:
   - Check if FD is in registry
   - Unfold requested portion via `fold_pipeline.unfoldSlice()`
   - Copy data into caller's buffer
   - Advance offset
4. **`seekIntercepted`**: Updates read offset for intercepted FDs
5. **`unregisterFD`**: Called on close(); frees `InterceptedFD`

#### Test Coverage

| Test | Description |
|------|-------------|
| `shouldIntercept` | Extension matching for model files |
| `register/unregister` | FD lifecycle management |
| `read folded` | Unfolded data matches original |
| `seek` | Seek to various offsets, read correct data |
| `non-model passthrough` | Non-model files not intercepted |
| `large model` | Multi-GB model folding + partial read |

---

### `fold_pipeline.zig`

#### Types

```zig
pub const FoldedModel = struct {
    hologram: holo.Hologram,
    original_size: u64,
    original_hash: u128,    // Q128.128 hash of original data
    fold_ratio: f64,        // Compression ratio
};

pub const ModelFormat = enum { gguf, safetensors, pickle, unknown };
```

#### Key Functions

```zig
pub fn isModelFile(path: []const u8) bool
pub fn detectFormat(path: []const u8) ModelFormat
pub fn rawBytesToGrid(alloc: Allocator, data: []const u8) !holo.Grid
pub fn foldModel(alloc: Allocator, data: []const u8) !FoldedModel
pub fn unfoldModel(alloc: Allocator, folded: *const FoldedModel) ![]u8
pub fn unfoldSlice(alloc: Allocator, folded: *const FoldedModel, offset: u64, len: usize) ![]u8
pub fn serializeFolded(alloc: Allocator, folded: *const FoldedModel) ![]u8
pub fn deserializeFolded(alloc: Allocator, data: []const u8) !FoldedModel
```

#### Folding Pipeline

1. **`isModelFile`**: Checks path for known model extensions (`.gguf`, `.bin`, `.safetensors`, `.pt`, `.ckpt`)
2. **`rawBytesToGrid`**: Converts raw byte stream to `holo.Grid`:
   - Calculate grid side: `ceil(cbrt(data_len / 32))` (32 bytes per complex node)
   - Allocate N³ complex Q128.128 cells
   - Copy bytes into grid data, zero-pad remainder
3. **`foldModel`**: Full pipeline:
   - `rawBytesToGrid()` → `holo.fold()` → compute hash → compute ratio
   - Return `FoldedModel` with hologram + metadata
4. **`unfoldModel`**: Full reconstruction:
   - `holo.unfold()` → copy grid data back to bytes
5. **`unfoldSlice`**: Partial unfold for on-demand serving:
   - Unfold only layers containing requested byte range
   - Extract and return requested bytes
6. **`serializeFolded` / `deserializeFolded`**: FANOFLD1 binary format

#### Serialized Format (FANOFLD1)

```
Offset  Size  Field
0       8     Magic: "FANOFLD1"
8       8     Original size (u64)
16      16    Original hash (u128)
32      8     Grid side N (u64)
40      ...   Hologram data (holo.serialize format)
```

#### Test Coverage

| Test | Description |
|------|-------------|
| `isModelFile` | Extension detection |
| `fold/unfold round-trip` | Raw bytes → folded → unfolded = original |
| `slice unfold` | Partial unfold matches full unfold at same offsets |
| `serialize/deserialize` | FANOFLD1 format round-trip |
| `compression ratio` | Folded size < original size for large data |
| `small data` | Sub-grid data handled correctly |

---

### `model_proxy.zig`

#### Types

```zig
pub const ProxyConfig = struct {
    port: u16 = 9471,
    folded_path: []const u8,    // Path to folded model file
    cache_size: usize = 256 * 1024 * 1024,  // 256MB LRU cache
};

pub const ModelInfo = struct {
    name: []const u8,
    original_size: u64,
    folded_size: u64,
    fold_ratio: f64,
    format: fold_pipeline.ModelFormat,
    hash: u128,
};
```

#### Key Functions

```zig
pub fn startServer(alloc: Allocator, cfg: ProxyConfig) !void
pub fn handleRequest(alloc: Allocator, conn: *std.http.Server.Connection, folded: *fold_pipeline.FoldedModel) !void
```

#### HTTP API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/info` | Model metadata (name, sizes, ratio, format, hash) |
| `GET` | `/size` | Original (unfolded) model size in bytes |
| `GET` | `/data?offset=0&length=4096` | Unfolded data slice at `[offset, offset+length)` |
| `GET` | `/health` | Server health check |

#### Request Handling

1. Parse HTTP request (method, path, query params)
2. Route to appropriate handler
3. For `/data` endpoint:
   - Parse `offset` and `length` query parameters
   - Call `fold_pipeline.unfoldSlice()` to get requested bytes
   - Write HTTP response with raw bytes as body
   - Set `Content-Type: application/octet-stream`
   - Set `Content-Length` to actual slice length
4. For `/info` and `/size`: return JSON metadata

#### Integration with Ollama

Ollama is configured to load models from `http://localhost:9471/data?offset=...&length=...` instead of direct file access. The proxy transparently serves unfolded model weights on-demand, with only active slices loaded into memory.

#### Test Coverage

| Test | Description |
|------|-------------|
| `server start/stop` | HTTP server lifecycle |
| `/info` endpoint | Correct model metadata |
| `/size` endpoint | Correct original size |
| `/data` endpoint | Correct slice data at various offsets |
| `/health` endpoint | Health check response |
| `large slice` | Multi-MB slice serving |
| `cache hit` | Repeated slice requests served from cache |

---

## Build Configuration (`build.zig`)

### Test Targets

| Name | Source | Modules | Description |
|------|--------|---------|-------------|
| `test-fold-pipeline` | `fold_pipeline.zig` | `q128_128`, `holo` | Folding pipeline |
| `test-model-proxy` | `model_proxy.zig` | `q128_128`, `holo` | HTTP proxy |
| `test-intercept` | `intercept.zig` | `q128_128`, `holo` | FD interception |

### Build Commands

```bash
# Run all VFS tests
cd vfs/ && zig build test

# Run specific test
cd vfs/ && zig build test-fold-pipeline
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Provides fixed-point arithmetic for holographic folding
- **Holographic Codec** (`zig/holo.zig`): Core fold/unfold operations
- **ISG Transcoder** (`isg/`): Optional RGB video encoding of folded models
- **Blockchain** (`blockchain/`): Folded models can be stored as chain data
- **Runtime** (`runtime/`): Hardware detection for auto-scaling fold parameters
- **Holo-FS** (`holo-fs/`): FUSE filesystem for persistent folded storage

**ATMA mapping:** Law of Assimilation — folded models execute live through the interceptor (see docs/16-atma-fano1.md).
