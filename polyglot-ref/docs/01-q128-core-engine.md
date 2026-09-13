# 01 — Q128.128 Core Engine (`zig/`)

## Architecture Overview

### Purpose

The `zig/` directory contains the foundational Q128.128 fixed-point arithmetic engine and all core mathematical modules for the FANO-1 OS. It provides deterministic, bit-identical 256-bit signed fixed-point math (128 integer + 128 fractional bits) with a precision floor of 2^-128 ≈ 2.94×10^-39, replacing all IEEE 754 floating-point operations.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `q128_128.zig` | 544 | Core 256-bit fixed-point type `q128`, arithmetic, constants, conversions |
| `holo.zig` | 904 | Holographic compression codec: fold/unfold 3D grids, RLE, serialization |
| `fano_sh.zig` | 519 | FANO-sh polyglot shell language: lexer, parser, evaluator, AST |
| `fano_tensor.zig` | 209 | 15×15×15 Fano tensor generator (octonion indices e0–e7) |
| `ramsey_identity.zig` | 232 | Ramsey identity physics: E=mc² transforms, pivot rotation, verification |
| `scale_table.zig` | 269 | Grid scale/expansion calculator: nodes, memory, qubits, dimensions |
| `wasm_exports.zig` | 111 | WebAssembly bindings for Q128.128 arithmetic and Ramsey identity |
| `main.zig` | 100 | CLI simulation: runs 11-test Ramsey identity suite |
| `build.zig` | 157 | Build system: modules, executables, test targets |

### Dependencies

- **External**: None (pure Zig, no external libraries)
- **Internal**: `holo.zig` imports `q128_128`; `ramsey_identity.zig` imports `q128_128`; `fano_sh.zig` imports `q128_128` and `holo`; `wasm_exports.zig` imports `q128_128` and `ramsey_identity`; `main.zig` imports `q128_128` and `ramsey_identity`

### Design Decisions

1. **Fixed-point over floating-point**: All arithmetic uses 256-bit unsigned integer primitives (`u128` pairs). No IEEE 754 operations anywhere in the computation path, ensuring bit-identical results across heterogeneous hardware.
2. **Round-half-away rounding**: Multiplication uses round-half-away-from-zero (vs. the C implementation's round-to-nearest-even), with maximum roundoff ε ≤ 2^-129.
3. **512-bit intermediate products**: Multiplication computes full 512-bit products before right-shifting by 128 bits, preventing intermediate overflow.
4. **Newton-Raphson sqrt**: Square root uses up to 256 iterations of Newton-Raphson with Q128.128 fixed-point, converging to exact integer bounds.

---

## API Reference

### `q128_128.zig`

#### Types

```zig
pub const U256 = struct { hi: u128, lo: u128 };
pub const q128 = U256;  // Signed 256-bit fixed-point (128.128 format)
```

#### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `Q_ZERO` | `{0, 0}` | Zero |
| `Q_ONE` | `2^128` | Unity (1.0 in Q128.128) |
| `Q_C2` | `299792458 << 128` | Speed of light squared (c²) |
| `PI_RAW` | `int(π × 2^128)` | Pi to 38 decimal digits |
| `PHI_RAW` | `int(φ × 2^128)` | Golden ratio to 38 digits |
| `Q_TOLERANCE` | `1 << 68` | Comparison tolerance |

#### Core Arithmetic Functions

```zig
pub fn q128Add(a: q128, b: q128) q128
pub fn q128Sub(a: q128, b: q128) q128
pub fn q128Mul(a: q128, b: q128) struct { v: q128, overflow: bool }
pub fn q128Div(a: q128, b: q128) struct { v: q128, overflow: bool }
pub fn q128Sqrt(a: q128) q128
pub fn q128Neg(a: q128) q128
pub fn q128Abs(a: q128) q128
pub fn q128Eq(a: q128, b: q128) bool
pub fn q128Cmp(a: q128, b: q128) i32  // -1, 0, 1
pub fn q128IsNeg(a: q128) bool
pub fn q128Mag(a: q128) U256  // magnitude (unsigned)
```

#### 256-bit / 512-bit Helpers

```zig
pub fn add256(a: U256, b: U256) struct { v: U256, carry: u1 }
pub fn sub256(a: U256, b: U256) struct { v: U256, borrow: u1 }
pub fn mul256_256(a: U256, b: U256) struct { hi: U256, lo: U256 }  // 512-bit product
pub fn cmp256(a: U256, b: U256) i32
pub fn shl256(a: U256, n: u8) U256
pub fn shr256(a: U256, n: u8) U256
```

#### Conversion Functions

```zig
pub fn fromF64(x: f64) q128
pub fn toF64(q: q128) f64
pub fn fromI64(x: i64) q128
pub fn toI64(q: q128) i64
```

#### Test Coverage (q128_128.zig)

| Test | Description |
|------|-------------|
| `addition exactness` | a+b matches expected integer result |
| `subtraction exactness` | a-b matches expected |
| `multiplication exactness` | a*b within ε ≤ 2^-129 |
| `division exactness` | a/b within tolerance |
| `floor invariance` | floor(a) << 128 == a truncated |
| `inner product` | Re(<u,v>) = 0 for orthogonal vectors |
| `rotation` | 90° rotation preserves magnitude |
| `comparison` | cmp returns correct -1/0/1 |
| `saturation` | overflow handled correctly |
| `constants` | PI_RAW, PHI_RAW match expected float values |

---

### `holo.zig`

#### Types

```zig
pub const Cx = struct { re: q128, im: q128 };  // Complex Q128.128
pub const Grid = struct {
    n: u32,            // Grid side length
    data: []Cx,        // n³ complex cells
    alloc: std.mem.Allocator,
};
pub const Hologram = struct {
    core: []Cx,        // 16³ core nodes
    windings: []i64,   // RLE-encoded winding stream
    n: u32,            // Original grid side
    // ...
};
```

#### Key Functions

```zig
pub fn fold(alloc: Allocator, grid: *Grid) !Hologram
pub fn unfold(alloc: Allocator, h: *Hologram) !Grid
pub fn serialize(alloc: Allocator, h: *Hologram) ![]u8
pub fn deserialize(alloc: Allocator, data: []const u8) !Hologram
pub fn generateFamily(alloc: Allocator, h: *Hologram) ![]Hologram
```

- **fold**: Compresses N³ grid → 16³ core + winding stream via quarter-turn rotations
- **unfold**: Reconstructs N³ grid from 16³ core + windings (O(1) retrieval)
- **serialize/deserialize**: FHOLO1 binary format
- **generateFamily**: Produces all FANO-1 representable states from a hologram

#### Test Coverage

| Test | Description |
|------|-------------|
| `fold/unfold round-trip` | Grid → Hologram → Grid byte-identical |
| `partial unfold` | Unfold subset of layers |
| `residual mode fallback` | Fallback for non-power-of-2 grids |
| `serialize/deserialize` | FHOLO1 format round-trip |
| `family generation` | Generated states are valid holograms |

---

### `fano_sh.zig`

#### Types

```zig
pub const Value = union(enum) { q: q128, holo_id: u32 };
pub const TokenKind = enum { num, ident, op, lparen, rparen, ... };
pub const Token = struct { kind: TokenKind, text: []const u8 };
pub const Expr = union(enum) { num: q128, var_ref: []const u8, binop: ... };
pub const Stmt = union(enum) { expr: Expr, print: Expr, fold: ..., unfold: ..., emit: ... };
pub const Env = struct { vars: std.StringHashMap(Value), ... };
```

#### Key Functions

```zig
pub fn lex(alloc: Allocator, src: []const u8) ![]Token
pub fn parse(alloc: Allocator, tokens: []Token) ![]Stmt
pub fn eval(alloc: Allocator, env: *Env, stmts: []Stmt) !void
pub const Polyglot = struct {
    pub fn split(src: []const u8) struct { shell: []const u8, fano_sh: []const u8, holo: []const u8 }
};
```

#### Test Coverage

| Test | Description |
|------|-------------|
| `lex basic tokens` | Numbers, operators, identifiers |
| `parse arithmetic` | AST structure for `3 + 4 * 2` |
| `eval arithmetic` | Q128.128 evaluation correctness |
| `polyglot split` | Shell/FANO-sh/holo payload extraction |

---

### `fano_tensor.zig`

#### Types

```zig
pub const FanoTensor = struct {
    grid: [15][15][15]u8,  // Octonion indices e0–e7
};
```

#### Key Functions

```zig
pub fn init() FanoTensor
pub fn get(t: *const FanoTensor, x: u8, y: u8, z: u8) u8
pub fn set(t: *FanoTensor, x: u8, y: u8, z: u8, v: u8) void
pub fn layerPivot(t: *const FanoTensor, layer: u8) u8
pub fn countE0(t: *const FanoTensor) u32
pub fn checkMirrorSymmetry(t: *const FanoTensor) bool
pub fn checkArms(t: *const FanoTensor) bool
```

#### Test Coverage

| Test | Description |
|------|-------------|
| `structure` | 15³ grid, entries e0–e7 only |
| `central node` | Position (8,8,8) = e0 |
| `mirror symmetry` | Layer k mirrors layer 16-k |
| `e0 node count` | ~421 e0 observer nodes |
| `arm structure` | 6 symmetric e1–e7 radial arms |

---

### `ramsey_identity.zig`

#### Types

```zig
pub const ComplexQ128 = struct { re: q128, im: q128 };
pub const RamseyIdentity = struct {
    mass: q128,
    energy_forward: ComplexQ128,   // m·c² (real)
    energy_inverse: ComplexQ128,  // m·c⁻² (real)
    information_pivot: ComplexQ128, // (0, m) — pure imaginary
};
```

#### Key Functions

```zig
pub fn init(mass: q128) RamseyIdentity
pub fn transformThroughPivot(ri: *const RamseyIdentity, e: ComplexQ128) ComplexQ128
pub fn verifyConservation(ri: *const RamseyIdentity) bool
pub fn verifyConservationComplex(ri: *const RamseyIdentity) bool
pub fn isReversible(ri: *const RamseyIdentity) bool
pub fn applyPhiScaling(ri: *const RamseyIdentity) ComplexQ128
pub fn complexAdd(a: ComplexQ128, b: ComplexQ128) ComplexQ128
pub fn complexSub(a: ComplexQ128, b: ComplexQ128) ComplexQ128
pub fn complexMul(a: ComplexQ128, b: ComplexQ128) ComplexQ128
pub fn complexDiv(a: ComplexQ128, b: ComplexQ128) ComplexQ128
pub fn complexConj(a: ComplexQ128) ComplexQ128
```

#### Physics

- **Forward transform**: E_f = m·c² (real axis)
- **Inverse transform**: E_i = m·c⁻² (real axis)
- **Information pivot**: (0, m) — pure imaginary; multiplying energy by pivot performs exact 90° orthogonal rotation (re → 0, im → |E|)
- **Conservation**: |E·conj(E)| = m²·c⁴ within Q_TOLERANCE
- **Reversibility**: E_f / c² = m within tolerance

#### Test Coverage (11 tests, all PASS)

| Test | Description |
|------|-------------|
| T1 | mass=1: E_f=8.988×10¹⁶ J, pivot=(0,1), conservation PASS |
| T2 | mass=2: E_f=1.798×10¹⁷ |
| T3 | ratio E_f/E_i = c⁴ exactly |
| T4 | pivot rotation: (c²,0) → (0, c²); 90° confirmed |
| T5 | reversibility: forward energy reversible; arbitrary energy rejected |
| T6 | phi scaling ratio = 1.618033988750 matches φ |
| T7 | zero mass → all zero |
| T8 | negative mass → negative energies |
| T9 | complex conservation PASS |
| T10 | arithmetic: 3+2=5, 3-2=1, 3×2=6, 3/2=1.5, √4=2, √2=1.414… |
| T11 | phase of (c², c²) = 45° = π/4 rad |

---

### `scale_table.zig`

#### Types

```zig
pub const Entry = struct {
    grid_side: u32,
    nodes: u64,
    memory_bytes: u64,
    qubits: u64,
    dimensions: u32,
    universes: u64,
};
```

#### Key Functions

```zig
pub fn computeEntry(grid_side: u32, base: u32) Entry
pub fn formatBytes(bytes: u64) []const u8
pub fn printTable(entries: []const Entry) void
```

#### Test Coverage

| Test | Description |
|------|-------------|
| `binary sequence` | 16→32→64→128→256→512 correct nodes/memory/qubits |
| `Fano sequence` | 15→30→60→120→240→320 correct values |
| `formatBytes` | Human-readable byte formatting |

---

### `wasm_exports.zig`

#### WASM Interop Helpers

```zig
pub fn loadQ128(ptr: [*]u64) q128   // Load 4×u64 → q128
pub fn storeQ128(ptr: [*]u64, v: q128) void  // Store q128 → 4×u64
```

#### Exported Functions

| Export | Signature | Description |
|--------|-----------|-------------|
| `q128_add` | `(a_ptr, b_ptr, out_ptr)` | Addition |
| `q128_sub` | `(a_ptr, b_ptr, out_ptr)` | Subtraction |
| `q128_mul` | `(a_ptr, b_ptr, out_ptr)` | Multiplication |
| `q128_div` | `(a_ptr, b_ptr, out_ptr)` | Division |
| `q128_sqrt` | `(a_ptr, out_ptr)` | Square root |
| `q128_inner` | `(a_ptr, b_ptr, out_ptr)` | Inner product |
| `q128_rot90` | `(a_ptr, out_ptr)` | 90° rotation |
| `fano_constants` | `(out_ptr)` | Write PI, PHI, C² constants |
| `fano_ramsey_identity` | `(mass_ptr, out_ptr)` | Full Ramsey identity transform |
| `fano_rotate` | `(mass_ptr, energy_ptr, out_ptr)` | Pivot rotation |

---

### `main.zig`

CLI entry point. Prints system architecture parameters, physical constants, runs pivot rotation test, then executes the 11-test Ramsey identity suite. Output formatted via `q.toF64` for readability.

---

## Build Configuration (`build.zig`)

### Executables

| Name | Root Source | Description |
|------|-------------|-------------|
| `fano` | `main.zig` | Ramsey identity simulation CLI |
| `fano-codec` | `holo.zig` | Holographic codec CLI |
| `fano-sh` | `fano_sh.zig` | FANO-sh shell interpreter |
| `fano-scale` | `scale_table.zig` | Scale table printer |

### Test Targets

| Name | Source | Modules |
|------|--------|---------|
| `test-q128` | `q128_128.zig` | — |
| `test-ramsey` | `ramsey_identity.zig` | `q128_128` |
| `test-holo` | `holo.zig` | `q128_128` |
| `test-fano-sh` | `fano_sh.zig` | `q128_128`, `holo` |
| `test-fano-tensor` | `fano_tensor.zig` | — |
| `test-scale` | `scale_table.zig` | — |

### Build Commands

```bash
# Build all executables
cd zig/ && zig build

# Run all tests
cd zig/ && zig build test

# Run specific test
cd zig/ && zig build test-q128
```

**ATMA mapping:** Law of the Seed (Karma) — every operation is a deterministic tensor state transition with no random noise (see docs/16-atma-fano1.md).
