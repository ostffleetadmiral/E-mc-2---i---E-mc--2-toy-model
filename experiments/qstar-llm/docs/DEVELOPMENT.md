# Development Guide

Coding standards, contribution guide, and development workflow for Qstar-LLM.

---

## Prerequisites

- **Zig 0.13.0+** — Install from [ziglang.org](https://ziglang.org)
- No other dependencies required

## Build Commands

```bash
zig build              # Compile all modules + CLI + WASM
zig build test         # Run all 1,268 unit tests (647 src + 184 vision + 152 geoview + 211 prototype + 74 test-file)
zig build tool-test    # Run tool calling + server integration tests (44)
zig build vision-test  # Run vision pipeline tests (25)
zig build geoview-test # Run geoview pipeline tests (30)
zig build regression   # Run full regression harness (61 checks)
zig build manual       # Run 4 manual integration test suites
zig build audit        # Run agent dual-mode audit (12 tests)
zig build samc         # Run SAMC validation (5 tests)
zig build ollama-bench # Run head-to-head benchmark vs Ollama
zig build competitive-bench # Run competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple)
zig build training-heartbeat # Run training heartbeat cycle (corpus learning, generated prompts)
zig build qstar-bench # Run Qstar internal benchmark suite
zig build maple-bench # Run Maple protocol benchmark
zig build vulkan-bench # Run Vulkan compute benchmark
zig build shaders     # Build Vulkan shaders
zig build wasm         # Build WASM module for browser embedding
zig build html         # Build self-contained universe.html with embedded WASM
zig build corpus       # Build compressed .qsc corpus container
zig build master       # CI/CD gate: regression + build + publish quine payloads to zig-out/master/
zig build run          # Run example application
zig build cli          # Run CLI binary
zig build serve        # Run HTTP API server
zig test src/foo.zig   # Test a single module
```

## Coding Standards

### 1. Self-Contained Core, Modular Higher Layers

Core lattice modules (`lattice.zig`, `fixed_point.zig`) import only `std` and are fully self-contained. Higher-level modules (agent, tools, server, etc.) import dependencies via the Zig build system module system (`build.zig`), not via relative file paths.

```zig
// CORRECT — core module (lattice.zig, fixed_point.zig)
const std = @import("std");

// CORRECT — higher-level module using build.zig module imports
const fp = @import("fixed_point");
const bpe = @import("bpe_tokenizer");

// WRONG — direct file path imports
const lattice = @import("lattice.zig");
```

### 2. No Stubs, Mocks, Placeholders, or TODOs

All code must be real business logic. No stub functions, no mock implementations, no placeholder values, no TODO comments.

### 3. Memory Safety

- Use `errdefer` for all allocations
- Use `defer` for cleanup
- Tests must not leak memory (verified by `std.testing.allocator`)
- No undefined behavior

```zig
var out = try allocator.alloc(u8, n);
errdefer allocator.free(out);
// ... use out ...
return out;  // caller owns
```

### 4. Error Handling

- Use Zig error unions (`!T`) for all fallible operations
- Errors must be descriptive: `error.InvalidMagic`, not `error.Failed`
- Never discard errors with `catch unreachable` unless truly impossible

### 5. Naming Conventions

| Category | Convention | Example |
|----------|-----------|---------|
| Types (structs, enums) | PascalCase | `Agent`, `ToolDefinition` |
| Functions | camelCase | `latticeEdge`, `runInference` |
| Constants | UPPER_SNAKE | `BASE_EDGE`, `E0_NODE_COUNT` |
| Variables | camelCase | `chunk_idx`, `is_boundary` |
| Files | snake_case | `bpe_tokenizer.zig` |

### 6. Comments

- Module-level: `//!` doc comment at top of file
- Public items: `///` doc comments
- Section separators: `// ===...` dividers
- No inline comments explaining obvious code
- Keep documentation up to date

### 7. Testing

- Every public function must have at least one test
- Test names are descriptive: `test "BPE encode/decode round-trip"`
- Use `std.testing.allocator` for all tests
- Test edge cases: empty input, max level, boundary conditions
- Maintain 101%+ test coverage

### 8. Const Correctness

- Use `const` for all immutable variables
- Use `var` only when mutation is required
- Use `comptime` where possible

### 9. Integer Safety

- Use `@intCast` for narrowing conversions
- Use `@intCast` for shift amounts
- Use wrapping arithmetic (`+%`, `-%`, `*%`) where overflow is expected
- Use `@min`/`@max` for clamping

### 10. No External Dependencies

- `build.zig.zon` must have `.dependencies = .{}`
- Only `std` library functions
- No `@cImport`, no `@cInclude`
- No system libraries

### 11. SIMD and Vector Operations

Use `@Vector` for batch operations on homogeneous data:

```zig
// 4-lane SIMD multiply for fixed-point
pub fn mulVec4(a: @Vector(4, i64), b: @Vector(4, i64)) @Vector(4, i64) {
    const wide_a: @Vector(4, i128) = @intCast(a);
    const wide_b: @Vector(4, i128) = @intCast(b);
    const product = wide_a * wide_b;
    const shifted = product >> @as(@Vector(4, u7), @splat(FRAC_BITS));
    return @intCast(shifted);
}
```

---

## File Organization

Each source file follows this structure:

```zig
//! module.zig — Brief description.
//!
//! Extracted from Qstar.
//! [Key algorithm or concept].

const std = @import("std");

// =============================================================================
// Section 1: [Name]
// =============================================================================

/// Doc comment for public item.
pub const Foo = struct { ... };

/// Doc comment for public function.
pub fn bar(...) !... { ... }

// =============================================================================
// Tests
// =============================================================================

test "descriptive test name" {
    const allocator = std.testing.allocator;
    // ...
}
```

---

## Adding a New Source Module

1. Create `src/<module_name>.zig` with `//!` doc comment
2. Implement all functions with `std`-only imports (or build.zig module imports)
3. Write comprehensive tests (target: 10+ tests per module)
4. Add module to `build.zig`:
   - Add module definition with `b.addModule(...)`
   - Wire any imports (e.g., `mod.addImport("fixed_point", fixed_point_mod)`)
   - Add test spec to `test_specs` array
5. Run `zig build test` to verify
6. Update `README.md` and `docs/ARCHITECTURE.md`

## Adding a New Prototype Module

1. Create `prototype/<module_name>.zig`
2. Implement and write tests
3. Add module definition to `build.zig` prototype section
4. Add test spec to `test_specs` array
5. If it has a manual test, add executable to the `manual` step
6. Run `zig build test` to verify

---

## Verification Checklist

Before committing, verify all checkpoints:

```bash
# 1. Compile with zero warnings
zig build

# 2. All tests pass
zig build test

# 3. No memory leaks
for f in src/*.zig; do zig test "$f" 2>&1 | grep -q "leaked" && echo "LEAK: $f"; done

# 4. Core module self-containment
for f in src/lattice.zig src/fixed_point.zig; do
    imports=$(grep -E '^const .* = @import\(' "$f" | grep -v '"std"' | grep -v '"builtin"' | head -5)
    [ -n "$imports" ] && echo "FAIL: $f"
done

# 5. Manual integration
zig build manual

# 6. Audit
zig build audit

# 7. SAMC validation
zig build samc

# 8. Tool server
zig build tool-test

# 9. Vision pipeline
zig build vision-test

# 10. Geoview pipeline
zig build geoview-test

# 11. Full regression
zig build regression
```

---

## Archive Rules

- Never delete anything that has passed testing
- Keep tested code in `/home/ADMPaul/Desktop/PJ/.archives`
- Archive before major refactors
- Archive after each completed phase

---

## Training Workflows

### Self-Training (Ollama Teacher)

```bash
# Train with Ollama as teacher (140 default prompts)
zig build cli -- train --model qwen2.5:3b --corpus qstar_corpus.txt
```

### Internet Training (Wikipedia API)

```bash
# Fetch and learn from Wikipedia articles
zig build cli -- train-internet --offset 0 --no-ollama --corpus qstar_corpus.txt

# With Ollama augmentation
zig build cli -- train-internet --offset 0 --corpus qstar_corpus.txt

# Resume from specific article index
zig build cli -- train-internet --offset 744 --no-ollama --corpus qstar_corpus.txt
```

Key flags:
- `--offset N` — Skip first N articles (for resuming)
- `--no-ollama` — Disable Ollama augmentation (use when Ollama hangs)
- `--corpus <path>` — Corpus file path (default: qstar_corpus.txt)
- `--limit N` — Only fetch N articles

### Dataset Ingestion

```bash
# Direct ingestion (no Ollama needed)
zig build cli -- ingest-corpus datasets/Gov --corpus-file qstar_corpus.txt
zig build cli -- ingest-corpus datasets/AdmPaul --corpus-file qstar_corpus.txt

# Ollama-enriched ingestion
zig build cli -- enrich-corpus datasets/Gov --corpus-file qstar_corpus.txt

# Full pipeline (ingest + enrich)
zig build cli -- train-corpus --ingest-dir datasets/Gov --enrich-dir datasets/AdmPaul
```

### Turing Test

```bash
# Run Turing test with Ollama judge
zig build cli -- turing-test --model qwen2.5:3b --verbose --num-prompts 50

# With memory and reflection
zig build cli -- turing-test --model qwen2.5:3b --memory --verbose

# Skip judge (just generate responses)
zig build cli -- turing-test --skip-judge --verbose
```
