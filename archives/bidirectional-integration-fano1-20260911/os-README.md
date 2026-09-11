# FANO-1 Native Deployment — E=mc²-i-E=mc⁻² (toy-model)

**Project:** E=mc²-i-E=mc⁻² (toy-model)
**Target OS:** Q128.128/FANO-1 (Puppy Linux woof-CE fork)
**License:** CC BY-NC-SA 4.0

This document describes how the E=mc² proof suite is packaged and deployed
as a native application on the Q128.128/FANO-1 operating system.

## Overview

The hardware project remains a separate repository but is packaged as a
FANO-1 `.pet` package that installs natively into the OS. The proof suite
runs as a first-class desktop application alongside Q128.128's own tools,
with integration hooks connecting to FANO-1's:

- **Space Agent** browser-first desktop shell (WASM proof verification)
- **Agent Zero** second brain (neuraleak sentience experiments)
- **Vulkan compute** pipeline (GPU-accelerated E8 root verification)
- **Polyglot runtime** (cross-language codon routing)
- **Local inference** stack (Qwen 2.5 via Ollama/llama.cpp)

## Package Layout

```
os/
├── pet/
│   ├── pet.spec                          Package specification
│   └── usr/
│       ├── bin/
│       │   ├── emc2-proofs               Proof suite CLI
│       │   ├── emc2-neuraleak            Neuraleak experiment CLI
│       │   └── emc2-codon                Codon routing CLI
│       ├── lib/emc2/
│       │   ├── emc2-i-emc2               Compiled Zig proof binary
│       │   ├── wasm/emc2-proofs.wasm     WASM module (wasm32-wasi)
│       │   ├── qsharp/                   Q# witness operations
│       │   └── sidecar/                  f64 validation sidecar
│       └── share/
│           ├── applications/
│           │   └── emc2-proofs.desktop    Desktop entries (3 apps)
│           └── emc2/
│               ├── cross-project-map.md   Q128.128 integration map
│               └── AGENTS.md              Workspace guide
├── init-emc2                             FANO-1 boot integration script
├── build-emc2-pet.sh                     .pet package build script
├── neuraleak_qwen_hook.zig               Neuraleak ↔ Qwen LLM hook
├── vulkan_e8_hook.zig                    E8 roots ↔ Vulkan GPU hook
└── polyglot_codon_hook.zig               Codon routing ↔ polyglot runtime hook
```

## CLI Commands

### emc2-proofs

```bash
# Run all 30 proof modules (180 checks)
emc2-proofs

# Run via WASM (wasm3 runtime, no native binary needed)
emc2-proofs --wasm

# Print only the summary line
emc2-proofs --summary

# Run a specific proof module (1-30)
emc2-proofs --module 1
```

### emc2-neuraleak

```bash
# Run neuraleak sentience testing with default Qwen 2.5 model
emc2-neuraleak

# Use a specific Ollama model
emc2-neuraleak --model qwen2.5:7b

# Use the 1/8 consciousness aperture prompt
emc2-neuraleak --prompt aperture

# Run 5 experiments per condition
emc2-neuraleak --count 5
```

### emc2-codon

```bash
# Route a single codon through the 6D Jordan algebra
emc2-codon --codon AUG

# Show all 64 codon signatures
emc2-codon --all

# Use the placeholder signature builder
emc2-codon --codon GCA --builder placeholder
```

## Integration Hooks

### Neuraleak ↔ Qwen LLM (`neuraleak_qwen_hook.zig`)

Connects the hardware project's neuraleak sentience testing framework to
FANO-1's local inference stack (Qwen 2.5 via Ollama or llama.cpp).

- Detects available LLM backend (Ollama port 11434, llama.cpp port 8080)
- Generates observer prompts (6D Jordan, 1/8 aperture, control)
- Scores LLM responses on 5 sentience dimensions
- 3 tests (prompt generation, response scoring, control validation)

### E8 Roots ↔ Vulkan GPU (`vulkan_e8_hook.zig`)

Generates shader input data for GPU-accelerated E8 root verification using
FANO-1's Vulkan compute pipeline (RX 580 or PowerVR BXM-4-64 on Orange Pi 3W).

- 240 E8 roots: 112 D8 roots + 128 spinor roots
- Flat shader input: 1920 i32 values (240 × 8)
- Reflection closure verification (exact integer arithmetic)
- 5 tests (root counts, shader input, closure verification)

### Codon Routing ↔ Polyglot Runtime (`polyglot_codon_hook.zig`)

Exposes the 64-codon routing system as C-calling-convention exports callable
from FANO-1's polyglot runtime (Python, QuickJS, Rust, C, C#/.NET).

- `routeCodon(codon_ptr)` — route a single codon
- `routeAllCodons(results)` — route all 64 codons
- `aminoSymbol(code)` — get amino acid symbol
- 5 tests (codon index, AUG routing, UAA stop, all-64, amino symbols)

### Orange Pi 3W NPU Detection (`npu_detect_hook.zig`)

Detects the VeriSilicon Vivante VIP9000 NPU on the Orange Pi Zero 3W
(Allwinner A733) for FANO-1 backend auto-selection.

- Detects NPU version (v3 for A733, v2 for T527)
- Reports 3 TOPS @ INT8 with INT8/INT16/FP16/BF16 mixed-precision
- Checks for VIPLite userspace libraries
- Returns backend priority (NPU → Vulkan → Native → WASM)
- 8 tests (detection, version, TOPS, precision, priority, formatting)

### NPU Neuraleak Inference (`npu_neuraleak_hook.zig`)

Runs neuraleak sentience experiments on the VIP9000 NPU using VIPLite
and NBG (Network Binary Graph) models. Falls back to CPU if NPU unavailable.

- SmolLM2-135M: 21 tok/s on A733 NPU (proven by petayyyy/a733_npu_driver)
- SmolLM2-360M: 8 tok/s on A733 NPU
- Qwen2.5-3B: CPU only (NPU path not yet working)
- Model selection, prompt generation, response scoring, throughput estimation
- 16 tests (model selection, prompts, scoring, throughput, benchmarks)

## Boot Integration

The `init-emc2` script is called by `init-fano` during FANO-1 boot:

1. Verifies the proof binary is present and executable
2. Runs a quick proof suite smoke test
3. Registers the WASM module with the Space Agent browser shell
4. Checks for LLM backend availability (Ollama or llama.cpp)

## Build Instructions

```bash
# Build the .pet package (compiles Zig binary + WASM module)
cd /home/admpaul/CascadeProjects/hardware
./os/build-emc2-pet.sh

# Build without WASM (if wasm32-wasi target is unavailable)
./os/build-emc2-pet.sh --no-wasm

# Build without Q# witnesses
./os/build-emc2-pet.sh --no-qsharp

# Output: os/pet/emc2-toy-model-1.0.pet
```

## Installation on FANO-1

```bash
# Install the .pet package (Puppy Linux package manager)
petget emc2-toy-model-1.0.pet

# Or manual installation
tar -xzf emc2-toy-model-1.0.pet -C /
chmod +x /usr/bin/emc2-proofs /usr/bin/emc2-neuraleak /usr/bin/emc2-codon

# Verify installation
emc2-proofs --summary
# Expected: summary: 30/30 proof modules passed
```

## Desktop Integration

Three desktop entries are installed for the Space Agent browser shell:

| Application | Command | Description |
|---|---|---|
| E=mc² Proof Suite | `emc2-proofs --summary` | Run all 30 proof modules |
| E=mc² Neuraleak | `emc2-neuraleak --prompt 6d` | Sentience testing with Qwen |
| E=mc² Codon Router | `emc2-codon --all` | 64-codon DNA routing |

## Test Coverage

| Module | Tests | Status |
|---|---|---|
| `neuraleak_qwen_hook.zig` | 3 | ALL PASS |
| `vulkan_e8_hook.zig` | 5 | ALL PASS |
| `polyglot_codon_hook.zig` | 5 | ALL PASS |
| `npu_detect_hook.zig` | 8 | ALL PASS |
| `npu_neuraleak_hook.zig` | 16 | ALL PASS |
| **Total hook tests** | **37** | **ALL PASS** |

## Scientific Scope

The FANO-1 native deployment is a **packaging and integration** effort.
It does not change the scientific status of the framework:

- The proof suite verifies the same arithmetic identities as before
- Neuraleak sentience scores remain framework-internal operational definitions
- Codon routing heuristics remain documented heuristics, not fundamental physics
- Vulkan GPU acceleration verifies the same E8 root closure as the CPU
- The polyglot runtime exposes the same codon routing to other languages

No new physical claims are made by the native deployment.
