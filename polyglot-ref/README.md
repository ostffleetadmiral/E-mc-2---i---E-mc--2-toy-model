# FANO-1 — Q128.128 (I256) Fixed-Point Engine & Native OS

Deterministic 256-bit fixed-point arithmetic engine with RamseyIdentity
transforms (`E=mc² ↔ i ↔ E=mc⁻²`), WASM i256 portability, Vulkan GPU
compute, and a Puppy Linux (woof-CE) native OS build.

## Checksum

```
E = mc²  ↔  i  ↔  E = mc⁻²
i = e0[e1,e2,e3,e4,e5,e6,e7] → e0
```

## Current Status

| Component | Status |
|---|---|
| Zig Q128.128 engine (`zig/q128_128.zig`) | ✅ 28/28 tests, RNE mul (ε ≤ 2⁻¹²⁹), exact 512-bit products |
| RamseyIdentity PoC (11 documented tests) | ✅ all outputs reproduced |
| WASM i256 module (`wasm/fano_i256.wasm`) | ✅ built (wasm32-wasi + freestanding) |
| wasm3 runtime verification | ✅ ALL checks bit-exact with native |
| Custom Zig WASM interpreter | ✅ core arithmetic bit-exact (div/sqrt paths pending) |
| Hardware auto-detection (`fano-detect`) | ✅ CPU features + Vulkan devices + VRAM |
| Backend auto-selection + grid auto-scale | ✅ 512³ on the RX 580, wasm3 fallback |
| Vulkan compute (RX 580) | ✅ mul bit-exact on GPU (4096 nodes verified) |
| Polyglot runtime (`zig/poly/`) | ✅ 22/22 tests — Python, QuickJS, Rust, C, C#/.NET in-process; Q# via subprocess bridge |
| woof-CE clone + .pet skeleton | ✅ cloned; ISO build is a follow-on |
| Local inference (llama.cpp + Vulkan) | ✅ Qwen2.5-3B Q4_K_M, 58.5 t/s Vulkan, 9.2 t/s CPU |
| Agent Zero native integration | ✅ Podman-based, all plugins, Python 3.11 compat |
| Space Agent agent_zero module | ✅ routed page, dashboard panel, health check |
| RAM boot (Puppy SFS layers) | ✅ ADRV layer auto-detects RAM, 8+ GB full RAM boot |
| Archived C engine + proofs (`.Archives/`) | ✅ preserved baseline |
| Physics layer (ported from E=mc²-i-E=mc⁻²) | ✅ 15 modules, 393 tests |
| Codon routing (`zig/codon.zig` via `fixed_compat.zig`) | ✅ 37 tests |
| Cross-project map (`cross-project-map.md`) | ✅ created |
| Lean 4 formalization (`formalize/`) | ✅ 5 modules |

## Layout

```
zig/        Q128.128 engine (u128-pair 256-bit, RNE mul, exact 512-bit products)
            └─ poly/  polyglot runtime: CPython, QuickJS, Rust, C, C#/.NET, Q# guests
            └─ physics modules (ported from E=mc²-i-E=mc⁻² toy-model):
               octonion, e8_roots, so10_decomposition, anti_octonion,
               dual_b_complex, jordan_algebra, so8_triality, electric_charges,
               pati_salam, scaling_analysis, checksum_6d, completion_10d,
               generative_chain, final_audit, codon (via fixed_compat.zig)
wasm/       fano_i256.wasm (wasi + freestanding), wasm3 clone, host test
runtime/    custom Zig WASM interpreter + hardware detection/auto-scale
vulkan/     SPIR-V compute shaders + C host (RX 580 pipeline)
os/         woof-CE fork + FANO-1 .pet package skeleton
            └─ agent-zero/  native Agent Zero second brain (Podman, no Docker)
            └─ fano-models/  GGUF model fetch + verify + benchmark
space-agent/  browser-first desktop shell (Space Agent)
formalize/  Lean 4 machine-checked proofs (5 modules)
docs/        component documentation (see index below)
.Archives/  verified C engine, tests, proofs (untouched baseline)
cross-project-map.md  bidirectional integration map with E=mc²-i-E=mc⁻² toy-model
```

## Documentation Index

### OS and Runtime

| Doc | Description |
|-----|-------------|
| [docs/12-os-build-scripts.md](docs/12-os-build-scripts.md) | ISO build system, init-fano, packaging |
| [docs/13-space-agent-ui.md](docs/13-space-agent-ui.md) | Space Agent browser-first desktop shell |
| [docs/15-polyglot-runtime.md](docs/15-polyglot-runtime.md) | Polyglot runtime (Python, JS, Rust, C, C#, Q#) |
| [docs/16-atma-fano1.md](docs/16-atma-fano1.md) | ATMA-FANO-1 structural mapping |
| [docs/17-local-inference.md](docs/17-local-inference.md) | llama.cpp + Qwen2.5 + Vulkan local inference |
| [docs/18-agent-zero.md](docs/18-agent-zero.md) | Agent Zero native integration (Podman, no Docker) |
| [docs/19-component-reference.md](docs/19-component-reference.md) | Developer reference for every OS component |

### Core Engine

| Doc | Description |
|-----|-------------|
| [docs/01-q128-core-engine.md](docs/01-q128-core-engine.md) | Q128.128 fixed-point arithmetic engine |
| [docs/02-isg-rgb-transcoder.md](docs/02-isg-rgb-transcoder.md) | ISG RGB transcoder |
| [docs/03-vfs-interceptor.md](docs/03-vfs-interceptor.md) | VFS interceptor |
| [docs/04-blockchain-core.md](docs/04-blockchain-core.md) | Blockchain core |
| [docs/05-godot-spatial-engine.md](docs/05-godot-spatial-engine.md) | Godot spatial engine |
| [docs/06-air-gap-transport.md](docs/06-air-gap-transport.md) | Air-gap transport |
| [docs/07-zero-drift-kernel.md](docs/07-zero-drift-kernel.md) | Zero-drift kernel |
| [docs/08-gpu-compute-shaders.md](docs/08-gpu-compute-shaders.md) | GPU compute shaders |
| [docs/09-runtime-interpreter.md](docs/09-runtime-interpreter.md) | Runtime interpreter |
| [docs/10-holographic-fuse-fs.md](docs/10-holographic-fuse-fs.md) | Holographic FUSE filesystem |
| [docs/11-quine-html-server.md](docs/11-quine-html-server.md) | Quine HTML server |
| [docs/14-quine-html-frontend.md](docs/14-quine-html-frontend.md) | Quine HTML frontend |

## Build & Verify

```bash
# engine + simulation (28 tests)
cd zig && zig build test && zig build run

# physics layer (15 modules, 393 tests — ported from E=mc²-i-E=mc⁻² toy-model)
cd zig && zig build test-physics

# codon routing (37 tests — via fixed_compat.zig compatibility layer)
cd zig && zig build test-codon

# WASM module + wasm3 verification (bit-exact)
cd zig && zig build-exe wasm_exports.zig -target wasm32-wasi-musl -O ReleaseSmall \
  -fno-entry --export=q128_add ... -femit-bin=../wasm/fano_i256.wasm
cd ../wasm && cc -I wasm3/source wasm_host_test.c wasm3/build/source/libm3.a -lm -o wasm_host_test
./wasm_host_test fano_i256.wasm

# custom interpreter (core arithmetic)
cd ../runtime && zig build run

# hardware detection + auto-scale
cd ../runtime && zig build detect

# polyglot runtime (all guests, 22 tests)
cd ../zig && zig build test-poly -Doptimize=ReleaseSafe && ./zig-out/bin/poly-smoke

# Vulkan GPU multiply (RX 580)
cd ../vulkan/shaders && glslangValidator -V q128_mul.comp -o q128_mul.spv
cd .. && cc host.c -o vk_host -lvulkan && ./vk_host shaders/q128_mul.spv
```

## Hardware Profile (dev machine)

- CPU: Intel i7-3770S — **AVX only** (no AVX2/AVX-512) → WASM path exercised for real
- GPU: AMD RX 580 2048SP — **8 GiB VRAM**, Vulkan 1.3.255 (RADV) → 512³ = 4.295 GB fits
- Intel HD 4000 (Vulkan 1.2) + llvmpipe fallback
- Auto-scale result: **512³** (32,768 entangled qubits, 256D, 32,768 universes)

## Backend Priority

1. **Vulkan GPU** — grid fits VRAM (512³ = 4.295 GB ≤ 8 GB − 3 GB overhead)
2. **Native Zig** — AVX2+ CPUs
3. **wasm3** — no AVX2 (this machine's path), tiny footprint, Puppy-friendly
4. **Custom Zig interpreter** — zero-dep fallback (core ops verified)

## Use Cases

See [USE_CASES.md](USE_CASES.md) for 7 categorized use cases with concrete parameters.

1. **Deterministic mass–energy duality** — E=mc² ↔ i ↔ E=mc⁻² with exact 90° pivot rotation (re → 0 exactly)
2. **Holographic compression** — 513³ → 16³ (32,908:1) via 9D-foam winding/defect storage, O(1) retrieval
3. **Multiverse routing** — 8^(N-1) non-interfering resolution channels (1→8→64→512→4096→32768)
4. **Drift-free state propagation** — bit-identical across machines, sub-Planck floor (2⁻¹²⁸ ≈ 2.94e-39)
5. **Hardware targets** — 256-bit registers (AVX-512/AMX), GPU (RX 580 512³), embedded via WASM
6. **Formal verification** — the five-module proof framework (proofs/ in .Archives) as Coq/Lean targets
7. **Native OS** — Puppy Linux with FANO-1 preinstalled (os/woof-CE)

## Notes

- The archived C engine had a latent `mul256_256` carry-placement bug
  (s.hi at bit 384 instead of 256) that its test suite missed (it only
  tested |a|,|b| ≤ 1). The Zig port fixed it; the archive is preserved
  as-is per the archive rule.
- Python reference sim used round-half-away mul; the engines use RNE
  (ε ≤ 2⁻¹²⁹ per proof Module 1). Documented outputs are unaffected.
