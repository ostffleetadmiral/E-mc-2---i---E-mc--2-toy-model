# 09 — Runtime Interpreter (`runtime/`)

## Architecture Overview

### Purpose

The runtime module provides a zero-dependency WASM interpreter and hardware auto-detection for FANO-1 OS. It enables Q128.128 arithmetic to execute on any platform — from AVX-512 workstations to embedded ARM — by compiling the core engine to `wasm32-freestanding` and interpreting the bytecode in pure Zig. The hardware detection layer selects the optimal execution backend (Vulkan GPU → native Zig → wasm3 → custom interpreter) and auto-scales the holographic grid to fit the available memory budget.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `interpret.zig` | 859 | Zero-dep WASM parser + executor (core instruction subset) |
| `detect.zig` | 356 | CPU/GPU detection, backend selection, grid auto-scaling |
| `core_ops.zig` | 173 | Minimal i64-pair Q128 ops compiled to wasm32-freestanding |
| `main.zig` | 110 | Test harness: loads WASM, calls exports, verifies bit-exactness |
| `build.zig` | 72 | Build system: interpreter tests, detection tests, CLI tools |

### Dependencies

- **Internal**: `q128_128` module, `ramsey_identity` module (from `../zig/`)
- **External**: None (pure Zig; uses `std.fs`, `std.os.linux`, inline `cpuid`)

---

## WASM Interpreter (`interpret.zig`)

### Supported WASM Sections

| Section ID | Name | Parser Support |
|------------|------|----------------|
| 1 | Type | Function signatures (params, results) |
| 3 | Function | Type index mapping |
| 5 | Memory | Initial page count (64 KiB pages) |
| 6 | Global | i32/i64 globals, mutable/immutable |
| 7 | Export | Name → kind + index mapping |
| 10 | Code | Function bodies (locals + bytecode) |
| Other | — | Skipped (custom, data, etc.) |

### Supported Opcodes

| Category | Opcodes |
|----------|---------|
| **Constants** | `i32.const` (0x41), `i64.const` (0x42) |
| **i32 arithmetic** | `i32.add` (0x6A), `i32.sub` (0x6B), `i32.mul` (0x6C) |
| **i64 arithmetic** | `i64.add` (0x7C), `i64.sub` (0x7D), `i64.mul` (0x7E) |
| **Comparisons** | `i32.eq`, `i32.ne`, `i32.lt_s`, `i32.lt_u`, `i32.gt_s`, `i32.gt_u`, `i64.eq`, `i64.ne`, `i64.lt_s`, `i64.lt_u`, `i64.gt_s`, `i64.gt_u` |
| **Conversions** | `i32.wrap_i64` (0xA7) |
| **Memory** | `i32.load` (0x28), `i64.load` (0x29), `i32.store` (0x36), `i64.store` (0x37) |
| **Locals/Globals** | `local.get` (0x20), `local.set` (0x21), `local.tee` (0x22), `global.get` (0x23), `global.set` (0x24) |
| **Control flow** | `block` (0x02), `loop` (0x03), `if` (0x04), `else` (0x05), `end` (0x0B), `br` (0x0C), `br_if` (0x0D), `return` (0x0F), `call` (0x10) |
| **Parametric** | `drop` (0x1A), `select` (0x1B) |

### Runtime Types

```zig
pub const Value = union(enum) { i32: i32, i64: i64 };
pub const Module = struct { types, func_types, funcs, globals, exports, memory, memory_pages };
pub const Runtime = struct { stack, frames, controls, call_depth };
```

### Execution Model

- **Value stack**: Operand stack for all computations
- **Frame stack**: Call frames with function index, PC, and locals
- **Control stack**: Block/loop/if entries with start/end PC and stack height snapshots
- **Branch semantics**: `br` to a `loop` jumps to loop start; `br` to a `block`/`if` jumps to block end
- **Call depth**: Limited to prevent infinite recursion

### Key Functions

```zig
pub fn parse(alloc: Allocator, data: []const u8) ParseError!Module
pub fn Runtime.init(alloc: Allocator, module: *Module) Runtime
pub fn Runtime.callExport(self: *Runtime, name: []const u8, args: []const Value) !Value
```

### Known Limitations

- **Division/sqrt**: Deeply nested multi-level `br` control flow (5-deep blocks) in division loops is still being hardened; `wasm3` is the reference runtime for those paths
- **No floating-point**: Only i32/i64 opcodes (Q128.128 uses integer arithmetic exclusively)
- **No `br_table`**: Not yet implemented (used in switch-like patterns)

---

## Core Operations (`core_ops.zig`)

### Purpose

Minimal Q128.128 arithmetic functions compiled to `wasm32-freestanding` for execution by the custom interpreter. Each q128 value is stored as 4 × `u64` (little-endian limbs: `[hi>>64, hi&mask, lo>>64, lo&mask]`).

### Exports

| Function | Signature | Description |
|----------|-----------|-------------|
| `qadd` | `(out, a, b) → void` | 256-bit addition with carry propagation |
| `qneg` | `(out, a) → void` | 256-bit two's complement negation |
| `qsub` | `(out, a, b) → void` | Subtraction via `qadd(a, qneg(b))` |
| `qrot90` | `(rx, ry, x, y) → void` | 90° rotation: `rx = -y, ry = x` (RamseyIdentity pivot) |
| `qmul` | `(out, a, b) → void` | Schoolbook 256-bit multiply, result >> 128 (truncating) |

### Build

```bash
zig build-lib runtime/core_ops.zig -target wasm32-freestanding -O ReleaseSmall
```

---

## Hardware Detection (`detect.zig`)

### CPU Detection

```zig
pub const CpuFeature = enum { avx512, avx2, avx, none };
pub const CpuInfo = struct { model: [64]u8, model_len, feature: CpuFeature, cores: u32 };
```

**Detection method**:
1. Read model name from `/proc/cpuinfo`
2. CPU count via `std.Thread.getCpuCount()`
3. `cpuid` leaf 1: check OSXSAVE (ecx[27]), AVX (ecx[28])
4. `cpuid` leaf 7, subleaf 0: check AVX2 (ebx[5]), AVX-512 (ebx[16])
5. `xgetbv` (XCR0): verify OS enables XMM+YMM (bits 1:2) and ZMM (bits 5:7)
6. Feature hierarchy: AVX-512 > AVX2 > AVX > none

### GPU Detection

```zig
pub const GpuDevice = struct { name: [128]u8, name_len, is_discrete: bool, vram_bytes: u64 };
pub const GpuInfo = struct { devices: [4]GpuDevice, device_count, vulkan_available: bool };
```

**Detection method**:
1. Check `vulkaninfo` availability via `command -v vulkaninfo`
2. Enumerate `/sys/class/drm/card*` entries
3. Read vendor ID: `0x1002` = AMD (discrete), `0x8086` = Intel (integrated)
4. Read VRAM from `device/mem_info_vram_total`
5. Read product name from `device/product_name`

### Backend Selection

```zig
pub const Backend = enum { vulkan_gpu, native_zig, wasm3 };
```

**Priority**:
1. **Vulkan GPU**: Discrete GPU with VRAM > `nodes × 32 + 3 GiB` overhead
2. **Native Zig**: CPU with AVX2 or AVX-512
3. **wasm3**: Fallback for CPUs without AVX2

### Grid Auto-Scaling

```zig
pub fn autoScaleGrid(backend: Backend) u64  // Returns grid side length (16..512)
```

**Algorithm**:
1. Determine memory budget: VRAM for GPU, RAM otherwise
2. Apply 75% safety margin (`budget × 3/4`)
3. Double grid from 16 until `grid³ × 32 > budget` or grid reaches 512
4. Result: largest power-of-two grid that fits

**Example**: 8 GB VRAM RX 580 → budget = 6 GB → 512³ (4.295 GB) fits, 1024³ (34.36 GB) does not.

### Test Coverage (5 tests)

| Test | Description |
|------|-------------|
| `cpu detection returns a feature` | Model name + core count |
| `gpu detection enumerates devices` | RX 580 detected as discrete |
| `backend selection prefers GPU` | 134M nodes → vulkan_gpu; 1B nodes → native_zig |
| `backend falls back to wasm3` | AVX-only CPU → wasm3 |
| `auto-scale caps at 512` | 8 GB GPU → grid = 512 |

---

## Test Harness (`main.zig`)

### Purpose

Loads `fano_i256_freestanding.wasm` into the custom interpreter, calls Q128.128 exports, and verifies bit-exact results against the native Zig engine.

### Test Cases

| Test | Expression | Expected |
|------|------------|----------|
| add | `3 + 2` | 5 |
| sub | `3 - 2` | 1 |
| mul | `3 × 2` | 6 |
| mul fractional | `0.5 × 0.5` | 0.25 |
| rot90 | `rotate90(7, 3)` | `(-3, 7)` |

### Memory Layout

```
Offset  Size  Field
0       32    OUT (result)
32      32    A (operand 1)
64      32    B (operand 2)
96      32    C (scratch)
128     32    D (rot90 rx)
160     32    E (rot90 ry)
```

### Build & Run

```bash
cd runtime/ && zig build run
```

---

## Build Configuration (`build.zig`)

### Targets

| Target | Type | Description |
|--------|------|-------------|
| `interp_test` | Executable | Interpreter test harness |
| `fano-detect` | Executable | Hardware detection CLI |
| `test` | Test step | Interpreter + detection unit tests |

### Build Commands

```bash
cd runtime/ && zig build test      # Run unit tests
cd runtime/ && zig build run        # Run interpreter test harness
cd runtime/ && zig build detect     # Run hardware detection
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Native engine for comparison and AVX2+ backend
- **Vulkan Shaders** (`vulkan/`): GPU backend selected by detect.zig
- **OS Build** (`os/`): `fano-detect` binary built from `runtime/` and packaged via PET into the FANO runtime
- **Kernel** (`kernel/`): Hardware detection available via `runtime/` build
- **Holographic Codec** (`zig/holo.zig`): Grid size auto-scaled to hardware
