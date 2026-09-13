# Qstar-Compress

Lattice compression library with TurboQuant — gzip + self-similarity dedup + lattice transform + RMSY container, 62× expansion. TurboQuant 4-bit/2-bit residual sidecar with lossless recovery.

## Quick Start

```bash
zig build test          # 76 tests
zig build run           # gzip + dedup + full pipeline demo
```

## Usage

```zig
const compress = @import("compress");

// Gzip
const gz = try compress.gzipCompress(allocator, data);
const restored = try compress.gzipDecompress(allocator, gz);

// Full pipeline
const container = try compress.compress(allocator, data, .{
    .use_gzip = true,
    .use_dedup = true,
    .use_lattice = false,
    .use_tq = false,
});
const result = try compress.decompress(allocator, container);
```

## API Reference

| Function | Description |
|----------|-------------|
| `gzipCompress(allocator, data)` | Gzip compress |
| `gzipDecompress(allocator, data)` | Gzip decompress |
| `deduplicate(allocator, data)` | Self-similarity dedup |
| `findSelfSimilarPatterns(allocator, data)` | Find repeating patterns |
| `compress(allocator, data, config)` | Full compression pipeline |
| `decompress(allocator, container)` | Full decompression |
| `extractE0SeedBuffer(allocator, data)` | Extract E0 seed buffer |

## Modules

| Module | Lines | Tests |
|--------|-------|-------|
| compress.zig | 1,413 | 19 |
| turbo_quant.zig | ~400 | ~30 |
| fixed_point.zig | 677 | 27 |

**Total: ~2,490 lines, 76 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
