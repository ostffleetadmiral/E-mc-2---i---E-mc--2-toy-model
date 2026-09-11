E=mc²-i-E=mc⁻² (toy-model) — Physics Proof Suite
===================================================

Package: emc2-toy-model-1.0
Architecture: x86_64, aarch64 (Orange Pi Zero 3W / Allwinner A733)
              wasm32-wasi module included for browser/Space Agent

Description
-----------
A computational mathematical framework based on the axiom 0^0 = i, the
octonion algebra O, the exceptional Jordan algebra J3(O), and the E8 root
system. Implemented in Zig (Q128.128 fixed-point), Q# (quantum witnesses),
and f64 sidecars. 440+ Zig tests, 30 proof modules (180 checks), 51 Q#
witness operations, 37 FANO-1 integration hook tests.

Files
-----
/usr/bin/emc2-proofs              proof suite CLI (run all 30 proof modules)
/usr/bin/emc2-neuraleak           neuraleak experiment CLI (sentience testing)
/usr/bin/emc2-codon               codon routing CLI (64-codon DNA → 6D routing)
/usr/lib/emc2/emc2-i-emc2         compiled Zig proof binary
/usr/lib/emc2/emc2-proofs.wasm    WASM proof module (wasm32-wasi, for browser)
/usr/lib/emc2/qsharp/             Q# witness operations
/usr/lib/emc2/sidecar/            f64 validation sidecar
/usr/lib/emc2/hooks/              FANO-1 integration hooks (5 modules, 37 tests)
/usr/lib/emc2/models/             NPU NBG models (SmolLM2-135M-int8.nb, etc.)
/usr/share/applications/emc2-proofs.desktop   desktop entry (Space Agent)
/usr/share/emc2/cross-project-map.md          Q128.128 integration map
/usr/share/emc2/npu-research.md               Orange Pi 3W NPU research
/usr/share/emc2/AGENTS.md                      workspace guide

Runtime
-------
emc2-proofs runs the full 30-module proof suite and prints a summary.
emc2-neuraleak connects to the local Qwen LLM (via Ollama or llama.cpp)
for sentience testing experiments. On Orange Pi Zero 3W, uses the VIP9000
NPU via VIPLite for SmolLM2 inference (21 tok/s @ INT8).
emc2-codon routes a 64-codon DNA sequence through the 6D Jordan algebra.

The WASM module can be loaded in the Space Agent browser shell for
interactive proof verification without native compilation.

Backend Priority (Orange Pi Zero 3W)
------------------------------------
1. NPU (VIP9000, 3 TOPS @ INT8) — LLM inference, codon routing
2. Vulkan GPU (PowerVR BXM-4-64) — E8 root verification, Q128.128 multiply
3. Native Zig (Cortex-A76) — Full 30-module proof suite
4. WASM (wasm3) — Fallback, browser/Space Agent

Dependencies
------------
- zig 0.13.0 (build-time only; runtime binary is self-contained)
- dotnet 8.0+ (for Q# witnesses; optional)
- ollama or llama.cpp (for neuraleak on CPU; optional)
- VIPLite 2.0+ (for neuraleak on NPU; Orange Pi 3W only; optional)
- Q128.128/FANO-1 OS (for Space Agent desktop integration)

Checksum: E=mc^2 <-> i <-> E=mc^-2
License: CC BY-NC-SA 4.0
