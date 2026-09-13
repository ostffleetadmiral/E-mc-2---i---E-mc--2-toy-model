# 08 — GPU Compute Shaders (`vulkan/`)

## Architecture Overview

### Purpose

The Vulkan module provides GPU-accelerated Q128.128 fixed-point arithmetic via SPIR-V compute shaders. It enables bit-exact 256-bit math on discrete GPUs (e.g., AMD RX 580), offloading bulk tensor operations from the CPU. The shaders implement the same rounding semantics as the native C engine (round-to-nearest-even), ensuring deterministic results across CPU and GPU.

### Module Structure

| File | Size | Purpose |
|------|------|---------|
| `shaders/q128_add.comp` | 799 B | GLSL source: 256-bit two's-complement add |
| `shaders/q128_add.spv` | 2.7 KB | Compiled SPIR-V binary for q128_add |
| `shaders/q128_mul.comp` | 3.4 KB | GLSL source: Q128.128 fixed-point multiply with RNE |
| `shaders/q128_mul.spv` | 12.6 KB | Compiled SPIR-V binary for q128_mul |
| `host.c` | 325 lines | C Vulkan host: pipeline creation, dispatch, verification |

### Dependencies

- **External**: Vulkan SDK (libvulkan), SPIR-V compiler (glslangValidator or glslc)
- **Internal**: None (shaders are standalone GLSL; host.c links against libvulkan)

---

## Shader Reference

### `q128_add.comp`

**Operation**: 256-bit two's-complement addition with carry propagation across 8 × 32-bit limbs.

```glsl
layout(local_size_x = 64) in;
layout(std430, binding = 0) readonly buffer InA { uint a_limbs[]; };
layout(std430, binding = 1) readonly buffer InB { uint b_limbs[]; };
layout(std430, binding = 2) writeonly buffer OutR { uint r_limbs[]; };
```

**Algorithm**:
1. Each invocation reads 8 consecutive `uint` values from `a_limbs` and `b_limbs`
2. Iterates limb-by-limb (little-endian), adding with carry
3. Carry detection: `s < x` after addition indicates unsigned overflow
4. Carry propagated across all 8 limbs (256 bits)
5. Result written to `r_limbs` at the same offset

**No rounding needed** — addition is exact in two's complement.

---

### `q128_mul.comp`

**Operation**: Q128.128 fixed-point multiply with round-to-nearest-even (RNE) and overflow saturation.

```glsl
layout(local_size_x = 64) in;
layout(std430, binding = 0) readonly buffer InA { uint a_limbs[]; };
layout(std430, binding = 1) readonly buffer InB { uint b_limbs[]; };
layout(std430, binding = 2) writeonly buffer OutR { uint r_limbs[]; };
layout(std430, binding = 3) buffer Ovf { uint ovf[]; };
```

**Algorithm**:

1. **Sign handling**: Check bit 31 of limb[7] for both operands. If negative, compute two's complement negation (`neg256`). Track result sign as XOR of operand signs.

2. **512-bit schoolbook multiply**: 8×8 limb multiplication using `mulu()` — a 32×32 → 64-bit multiply helper that splits each `uint` into two 16-bit halves to avoid GLSL's 32-bit multiplication limitation:
   ```glsl
   uvec2 mulu(uint a, uint b) {
       uint a0 = a & 0xFFFFu, a1 = a >> 16;
       uint b0 = b & 0xFFFFu, b1 = b >> 16;
       uint p0 = a0 * b0;
       uint m1 = a0 * b1;
       uint m2 = a1 * b0;
       uint m = m1 + m2;
       uint lo = p0 + (m << 16);
       uint hi = a1 * b1 + (m >> 16) + ...;
       return uvec2(lo, hi);
   }
   ```
   Products accumulate into a 16-limb (512-bit) array `p[16]` with carry propagation.

3. **Round-to-nearest-even at bit 128**:
   - `round_bit = p[3] >> 31` (bit 127 of the 512-bit product)
   - `sticky = (p[0] | p[1] | p[2]) != 0` (any bits below 127)
   - `lsb = p[4] & 1` (bit 128, the LSB of the result)
   - Round up if `round_bit & (sticky | lsb)` — this is IEEE 754 round-to-nearest-even

4. **Overflow detection**: If any of `p[12..15]` are nonzero, or if the result's sign bit is wrong, saturate:
   - Positive overflow → `0x7FFFFFFF FFFFFFFF ...` (max positive)
   - Negative overflow → `0x80000000 00000000 ...` (max negative)

5. **Sign restoration**: If result should be negative, negate the magnitude.

6. **Output**: 8 limbs to `r_limbs`, 1-bit overflow flag to `ovf[]`.

---

## Vulkan Host (`host.c`)

### Purpose

C program that creates a Vulkan compute pipeline from a SPIR-V shader, dispatches it over the GPU, and verifies bit-exactness against known Q128.128 results.

### Build

```bash
cc vulkan/host.c -o vulkan/vk_host -lvulkan
```

### Execution

```bash
vulkan/vk_host vulkan/shaders/q128_mul.spv
```

### Pipeline

1. **Instance + device**: Create Vulkan instance, select first discrete GPU, find compute queue family
2. **Shader module**: Load SPIR-V binary from file
3. **Descriptor set layout**: 4 storage buffer bindings (a, b, result, overflow)
4. **Compute pipeline**: Create pipeline with shader stage
5. **Buffers**: Allocate 4 host-visible buffers:
   - `a[COUNT × 32]` — input A (4096 × 32 bytes = 128 KB)
   - `b[COUNT × 32]` — input B
   - `r[COUNT × 32]` — result
   - `ovf[COUNT × 4]` — overflow flags
6. **Fill inputs**: All 4096 elements set to `a = 3.0`, `b = 2.0` (Q128.128: hi=3/hi=2, lo=0)
7. **Dispatch**: `COUNT / 64` work groups (64 invocations each = 4096 total)
8. **Verify**: Read back result, check `3 × 2 = 6` (hi=6, lo=0, no overflow)

### Verification Output

```
VULKAN MUL BIT-EXACT: 4096 nodes verified on GPU
```

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `COUNT` | 4096 | 16³ nodes — one holographic grid |
| Buffer size | 32 bytes per node | 4 × u64 (hi_hi, hi_lo, lo_hi, lo_lo) |

---

## Compilation

### GLSL → SPIR-V

```bash
glslangValidator -V vulkan/shaders/q128_add.comp -o vulkan/shaders/q128_add.spv
glslangValidator -V vulkan/shaders/q128_mul.comp -o vulkan/shaders/q128_mul.spv
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Shaders implement the same arithmetic as the native engine
- **Runtime** (`runtime/`): `detect.zig` selects Vulkan GPU backend when VRAM is sufficient
- **Holographic Codec** (`zig/holo.zig`): 16³ grid operations dispatched to GPU
- **VFS Interceptor** (`vfs/`): GPU reads folded model slices via SPIR-V shaders
- **ISG Transcoder** (`isg/`): RGB pixel matrix operations offloaded to compute shaders
