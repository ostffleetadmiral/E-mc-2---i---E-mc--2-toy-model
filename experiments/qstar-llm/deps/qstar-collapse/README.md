# Qstar-Collapse

Civilization collapse resilience library — cell atomization into 20,250 QR portals + recursive QR nesting for exponential data capacity in finite physical space.

## Quick Start

```bash
zig build test          # 36 tests
zig build run           # atomization + QR nesting demo
```

## What This Is

When civilization collapses, digital storage degrades. Qstar-Collapse encodes lattice data into 20,250 printable QR codes (15³ cells × 6 faces), with recursive nesting for exponential capacity.

## Usage

```zig
const collapse = @import("qstar-collapse");

// Cell atomization
var atomizer = collapse.CellAtomizer.init(allocator);
defer atomizer.deinit();
try atomizer.atomizeCell(0, 0, 0, "critical data");
var buf: [256]u8 = undefined;
const recovered = try atomizer.reassembleCell(0, 0, 0, &buf);

// Recursive QR nesting
var tree = collapse.qr_nest.NestTree.init(allocator);
defer tree.deinit();
try tree.build(large_data);
const extracted = try tree.extract(allocator);
```

## API Reference

### CellAtomizer (`collapse.zig`)

| Function | Description |
|----------|-------------|
| `CellAtomizer.init(allocator)` | Create atomizer |
| `atomizer.atomizeCell(x, y, z, data)` | Encode cell data into QR portals |
| `atomizer.atomizeLattice(data)` | Atomize entire 15³ lattice |
| `atomizer.reassembleCell(x, y, z, out)` | Reconstruct cell data |
| `atomizer.validateAll()` | Count valid portals |

### NestTree (`qr_nest.zig`)

| Function | Description |
|----------|-------------|
| `NestTree.init(allocator)` | Create nest tree |
| `tree.build(data)` | Build recursive QR nest from data |
| `tree.extract(allocator)` | Extract original data from nest |
| `tree.nodeCount()` | Get total node count |
| `tree.leafCount()` | Get leaf (QR code) count |

## Capacity

| Nesting Depth | Capacity |
|---------------|----------|
| 1 | ~241 bytes |
| 2 | ~5.8 KB |
| 3 | ~140 KB |
| 5 | ~810 MB |
| 8 | ~28 TB |

## Modules

| Module | Lines | Tests |
|--------|-------|-------|
| collapse.zig | 580 | 15 |
| qr_nest.zig | 793 | 21 |

**Total: 1,373 lines, 36 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
