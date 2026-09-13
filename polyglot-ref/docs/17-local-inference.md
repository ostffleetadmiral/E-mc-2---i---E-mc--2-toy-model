# 17. Local Inference (llama.cpp + Qwen2.5 + Vulkan)

## Quick Start (OS Users)

Local inference is disabled by default. To enable at boot:

```bash
# Enable the primary llama-server (3B model on port 8081)
export FANO_LLAMA_ENABLED=1

# Optionally enable Agent Zero second brain (0.5B on port 8082 + WebUI on 8090)
export FANO_AGENT_ZERO_ENABLED=1

# Reboot or run init-fano manually
```

Once running, the OpenAI-compatible API is at `http://127.0.0.1:8081/v1`.
Use `curl` to test:

```bash
curl http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

Vulkan GPU acceleration is auto-detected. To force CPU mode:
```bash
export FANO_LLAMA_N_GPU_LAYERS=0
```

## Overview

FANO-1 ships [llama.cpp](https://github.com/ggml-org/llama.cpp) v0.4.0-dev (commit `5266f24`) as its local inference runtime, cross-built for Slacko64's glibc 2.23 target. The OS includes `llama-server`, `llama-bench`, and `llama-cli` binaries plus the Vulkan GPU backend (`libggml-vulkan.so`). Models live in external storage or the in-ISO fallback, and are loaded at boot via an opt-in `init-fano` step.

The primary in-ISO model is **Qwen2.5-3B-Instruct** (Q4_K_M, ~1.93 GB), which ships in the ISO for Vulkan GPU offload and CPU fallback. A smaller **Qwen2.5-0.5B-Instruct** (Q4_K_M, ~379 MB) is also bundled for the Agent Zero second brain runtime. For capable hosts, **Qwen3.6-27B dense** (IQ2_M, ~11.1 GB) and **Qwen3.6-35B-A3B MoE** (IQ2_S, ~11.9 GB) remain available as external-storage models.

## llama.cpp Build

### Cross-build for glibc 2.23

The cross-build uses `zig cc` as the C/C++ compiler targeting `x86_64-linux-gnu.2.23`:

```bash
CC="zig cc -target x86_64-linux-gnu.2.23" \
CXX="zig c++ -target x86_64-linux-gnu.2.23" \
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF \
    -DGGML_SSE42=ON -DGGML_AVX=ON \
    -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_BMI2=OFF -DGGML_F16C=OFF \
    -DGGML_VULKAN=ON -DGGML_CUDA=OFF -DGGML_BLAS=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=ON -DLLAMA_CURL=OFF
```

- **CPU features**: SSE4.2 + AVX (compatible with the i7-3770S Ivy Bridge target and later).
- **Vulkan enabled**: the build produces `libggml-vulkan.so` with embedded SPIR-V shaders for all generic operations (matmul, dequantization, attention, RMS norm, etc.). The Vulkan backend is hardware-agnostic: it works with any Vulkan 1.2+ ICD (AMD RADV, Intel ANV, NVIDIA, etc.).
- **CUDA/BLAS disabled**: Vulkan is the GPU acceleration path; CUDA and BLAS are not used.
- **Shared libraries**: the build produces thin executables plus shared libraries (`libllama.so`, `libggml.so`, `libggml-cpu.so`, `libggml-vulkan.so`, `libggml-base.so`). These are packaged in `/usr/lib/fano/llama/bin/` with `LD_LIBRARY_PATH` set in `/etc/profile.d/fano.sh`. The Vulkan loader `libvulkan.so.1` is also bundled.
- **Known issue**: `llama-cli` and `llama-server` crash under the zig cc cross-build (a C++ ABI issue in zig 0.13.0's libc++ static initialization). This affects both CPU and Vulkan paths and is pre-existing. The native gcc build works correctly and is used for benchmarking. Fixing the zig cc crash requires either a newer zig version, a gcc cross-compile with a glibc 2.23 sysroot, or a workaround for the C++ static initializer issue.

### Vulkan shader coverage

The vendored llama.cpp Vulkan backend includes SPIR-V shaders for:
- Matrix multiplication (`mul_mat_vec`, `mul_mm`, `mul_mmq`) including Q4_K dequantization
- RMS normalization, attention (`flash_attn`), RoPE, softmax
- Gated DeltaNet (`gated_delta_net.comp`) - present but untested for Qwen3.6
- All standard quantization formats (Q4_0 through Q6_K, IQ1-IQ4)

### Build script

`os/build-llama.sh` automates the cross-build and packaging. It accepts `GGML_VULKAN=ON|OFF` (default ON) and handles Vulkan SDK path detection for the cross-compile. `os/build-iso.sh` calls `package_llama()` and `package_small_model()` to include the binaries and fallback model in the ISO.

### Qwen3.6 support

The vendored llama.cpp includes model loaders for:
- `qwen3.cpp`, `qwen35.cpp`, `qwen35moe.cpp`, `qwen3next.cpp`, `qwen3moe.cpp`
- Gated DeltaNet (GDN) architecture support

## Model Pipeline

### fetch-model.sh

`os/fano-models/fetch-model.sh` downloads and verifies pinned GGUF quants:

| Model | Quant | Size | SHA-256 | Vulkan |
|-------|-------|------|---------|--------|
| Qwen2.5-3B-Instruct | Q4_K_M | 1,929,903,264 | `9c9f56a3...` | Yes (in-ISO primary) |
| Qwen2.5-0.5B-Instruct | Q4_K_M | 397,808,192 | `6eb923e7...` | Yes (in-ISO agent-zero) |
| Qwen3.6-27B | IQ2_M | 11,085,693,440 | `df70ee8d...` | CPU-only (GDN) |
| Qwen3.6-27B | Q4_K_M | 17,984,872,960 | `8739a0cb...` | CPU-only (GDN) |
| Qwen3.6-35B-A3B | IQ2_S | 11,907,962,496 | `52ac86b6...` | CPU-only (GDN) |

- Resumable downloads with `curl -C -`.
- SHA-256 + size verification.
- `--verify-only` mode for checksum re-verification.
- Models stored in `$FANO_MODELS_DIR` (default: repo-local `os/fano-models/models/`; OS override: `/var/lib/fano/models/`).

### qstar-pack.zig

`os/fano-models/qstar-pack.zig` is a chunked model archive tool using the qstar-compress pipeline (dedup + gzip + lattice transform + RMSY container).

**Archive format (QSAR1)**:
- Magic: `QSAR1`
- Version: 1
- TQ bits: 0 (off), 2, or 4
- Chunk count, raw total, chunk size
- Index: per-chunk {raw_len, container_len, checksum}
- Containers: per-chunk RMSY bytes

**Key findings**:
- **High-entropy quantized weights do not compress losslessly.** The qstar lossless mode stores a full residual sidecar, so the packed archive is *larger* than the original GGUF.
- Full 27B IQ2_M pack: 11.09 GB raw -> 11.68 GB packed (0.949x ratio - expansion).
- The tool uses bounded 64 MB chunks, so RAM stays ~64 MB + index overhead (not 11 GB).
- Bit-exact round-trip verified on synthetic data and the full 11 GB model.

**Honest assessment**: qstar-pack is an archival/transport format, not a compression win for model weights. The "62x" lattice reconstruction ratio refers to lattice expansion semantics, not arbitrary-data compression.

## Benchmark Results

See `os/fano-models/bench-results.md` for the full benchmark table.

Key results (Qwen2.5-0.5B Q4_K_M, native gcc build):

| Backend | pp128 (t/s) | tg16 (t/s) | tg128 (t/s) |
|---------|-------------|------------|-------------|
| CPU (ngl=0) | 780 | 42 | 42 |
| Vulkan GPU (ngl=99) | 1870 | 162 | 163 |

Vulkan GPU offload provides **2.4x** faster prompt processing and **3.9x** faster token generation on the RX 580.

Key expectations:
- **ext4/mmap**: baseline - fastest model loading.
- **SquashFS**: may reduce disk reads via compression but adds decompression overhead.
- **holo-fs**: userspace FUSE - adds overhead, cannot provide hardware DMA. Expected to be *slower* than direct ext4 mmap for incompressible model weights.
- **Vulkan (small model)**: 2-4x speedup for Qwen2.5-0.5B. Validated on RX 580 via RADV.
- **Vulkan (27B model)**: not benchmarked - Qwen3.6 GDN shader is present but untested. CPU is the safe default for the 27B model.
- **mlock**: risky on 15 GB RAM hosts with 11 GB models (leaves only ~4 GB for OS + server).

Run benchmarks with:
```bash
os/fano-models/bench-model.sh [model-path] [output-md]
```

## Boot Integration

`os/init-fano` includes an optional `start_llama_server()` step with Vulkan auto-detection:

| Env var | Default | Description |
|--------|---------|-------------|
| `FANO_LLAMA_ENABLED` | `0` | Opt-in; boot does not fail if unset |
| `FANO_LLAMA_MODEL` | bundled 3B model | Model file path (falls back to 0.5B if absent) |
| `FANO_LLAMA_PORT` | `8081` | Server port (distinct from quine-server 8080) |
| `FANO_LLAMA_CTX` | `4096` | Context window size |
| `FANO_LLAMA_N_GPU_LAYERS` | auto | GPU layers (auto-detected: 99 if Vulkan GPU, 0 if CPU) |
| `FANO_AGENT_ZERO_ENABLED` | `0` | Set to `1` to start Agent Zero second brain |
| `FANO_AGENT_ZERO_MODEL` | bundled 0.5B model | Agent Zero model file path |
| `FANO_AGENT_ZERO_PORT` | `8090` | Agent Zero WebUI port |
| `FANO_AGENT_ZERO_LLAMA_PORT` | `8082` | Agent Zero llama-server port |
| `FANO_AGENT_ZERO_NGL` | auto | GPU layers for agent-zero model |
| `DOCKER_HOST` | `unix:///run/user/<uid>/podman/podman.sock` | Podman Docker-compatible socket |

## RAM Boot

FANO-1 uses Puppy Linux's SFS layer system for RAM-boot. The ISO contains
two SFS files:

| SFS file | Contents | Compressed size (est.) |
|----------|----------|----------------------|
| `puppy_slacko64_7.0.sfs` | Base Slacko64 + FANO binaries + Agent Zero source | ~350 MB |
| `adrv_slacko64_7.0.sfs` | 3B model + 0.5B model + Agent Zero venv + Podman | ~3.9 GB |

Puppy's initrd auto-detects available RAM and copies SFS files to tmpfs
(RAM) when there's space, otherwise mounts them from disk via loopback.

| RAM | Base rootfs | ADRV (models + venv) | Behavior |
|-----|-------------|---------------------|----------|
| 16 GB | In RAM | In RAM | Full RAM boot, all plugins |
| 8 GB | In RAM | In RAM | Full RAM boot, all plugins |
| 4 GB | In RAM | From disk | Base in RAM, models/venv from USB |
| 2 GB | From disk | From disk | Everything from disk (slow) |

If the ADRV layer is not loaded (insufficient RAM), `init-fano` logs a
warning and falls back to system Python. Models and venv will not be
available. This is expected on low-RAM machines.

To force RAM boot: add `pfix=ram` to the kernel boot parameters.
To force copy-to-RAM: add `pfix=copy` to the kernel boot parameters.
To disable copy-to-RAM: add `pfix=nocopy` to the kernel boot parameters.

### Vulkan detection

`detect_vulkan()` in `init-fano` checks for:
1. The Vulkan loader (`libvulkan.so.1`) - bundled or system.
2. ICD JSON files under `/usr/share/vulkan/icd.d/` or `/etc/vulkan/icd.d/`.
3. At least one non-software ICD (excludes llvmpipe/lavapipe).

If a hardware Vulkan device is found, the server starts with `-ngl 99` (all layers offloaded to GPU). If only software Vulkan or no Vulkan is present, the server starts with `-ngl 0` (CPU inference). `FANO_LLAMA_N_GPU_LAYERS` overrides auto-detection.

This detection is hardware-agnostic: it does not check vendor names or device IDs. Any compliant Vulkan 1.2+ ICD (AMD RADV, Intel ANV, NVIDIA proprietary, etc.) triggers GPU offload.

- Default model: the bundled Qwen2.5-3B Q4_K_M (works on both CPU and Vulkan GPU).
- Agent Zero model: the bundled Qwen2.5-0.5B Q4_K_M on a separate llama-server (port 8082).
- Health probe: `http://127.0.0.1:8081/health` (bounded 60s wait).
- State transitions recorded in the Karma journal.
- `os/test-iso.sh --auto` includes an optional llama-server health probe when `FANO_LLAMA_TEST=1`.

## Space Agent Wiring

Space Agent connects to the local llama-server via a new headless `_core/local_llama/` module that mirrors the existing `_core/open_router/` pattern.

### Architecture

- **`_core/local_llama/request.js`**: detects `127.0.0.1:8081` / `localhost:8081` endpoints; strips the API-key requirement (sets `Authorization: Bearer no-key`).
- **`_core/local_llama/health.js`**: `checkLocalLlamaHealth(endpoint)` probes `/health` on the local server.
- **`_core/local_llama/ext/js/...`**: extension hooks for `prepareOnscreenAgentApiRequest/end` and `prepareAdminAgentApiRequest/end`.
- **`onscreen_agent/config.js`**: `ONSCREEN_AGENT_LOCAL_PROVIDER.LOCAL_LLAMA` enum + `localLlamaEndpoint` / `localLlamaModel` defaults.
- **`onscreen_agent/api.js`**: `OnscreenAgentLocalLlamaLlmClient` subclass - OpenAI-compatible fetch + streaming, no API key required.
- **`onscreen_agent/store.js`**: client selection for `local_llama` provider; skips browser model loading (model is external).

### Configuration

Set in `~/conf/onscreen-agent.yaml`:
```yaml
provider: local
localProvider: local_llama
localLlamaEndpoint: http://127.0.0.1:8081/v1/chat/completions
localLlamaModel: qwen2.5-0.5b
```

When `FANO_LLAMA_ENABLED=1`, `init-fano` writes a default config pointing at the local server (if no user config exists).

### Fallback

If `checkLocalLlamaHealth` returns not-ok, the desktop shell surfaces a "Local model unavailable" state. The user can switch `localProvider` back to `huggingface` or `provider` back to `api` (OpenRouter).

## D-IMC, DMA, and Compute-Near-Memory

### Why true Digital In-Memory Compute is not implemented

Digital In-Memory Compute (D-IMC) is a hardware architecture where compute logic is integrated directly into memory arrays (SRAM, HBM-PIM, ReRAM, etc.). Examples include d-Matrix DIMC chips and academic SRAM-PIM designs. True D-IMC requires custom silicon: the memory arrays themselves perform analog or digital matrix operations.

FANO-1 runs on commodity x86_64 hardware (Slacko64 Puppy Linux). There is no way to implement D-IMC purely in software on a standard CPU. Any "in-memory compute" claim that does not involve custom silicon is a software abstraction, not hardware D-IMC.

### Why holo-fs is not a DMA compute path

`holo-fs` is a userspace FUSE filesystem. It provides a holographic storage abstraction (lattice-based reconstruction for archival data), but:
- It introduces kernel/userspace context-switch overhead on every read.
- It does not provide direct memory access (DMA) from storage to a compute engine.
- It does not perform computation on data in-place within the storage layer.
- The model weights are high-entropy quantized data, so holographic storage offers no compression benefit.

`mmap` is the closest software analogue to keeping model weights near computation, and llama.cpp already uses mmap-based loading. Benchmarks showed mmap, mlock, and no-mmap performance were similar, confirming that CPU compute (not I/O) is the bottleneck.

### Vulkan as the practical compute-near-memory path

Vulkan provides the closest available hardware-agnostic compute-near-memory analogue on commodity GPUs:
- GPU VRAM is dedicated memory physically near the GPU compute units.
- Vulkan compute shaders execute directly on the GPU, reading weights from VRAM without CPU round-trips.
- The Vulkan backend in llama.cpp offloads model weights to GPU VRAM and runs all inference operations (matmul, dequant, attention, norm) as Vulkan compute shaders.
- This is hardware-agnostic: any Vulkan 1.2+ GPU (AMD, Intel, NVIDIA) can be used.

The 2-4x speedup measured on the RX 580 (Polaris 20, Vulkan 1.3 via RADV) confirms that Vulkan GPU offload is a real, measurable compute-near-memory acceleration path - not a simulation.

## Constraints

- **4 GB ISO budget**: 27B/35B models cannot fit in the ISO. The 3B primary model (~1.93 GB) and 0.5B agent-zero model (~379 MB) both fit. The ISO ships the runtime + both models + agent-zero runtime (~3.2 GB total); larger models live in external storage (`/var/lib/fano/models/`, USB, or loopback).
- **15 GB RAM**: mlock on 11 GB model leaves ~4 GB for OS + server. Default is mmap (no mlock).
- **Vulkan for small/medium models**: validated for Qwen2.5-0.5B (standard transformer). The 3B model (also standard transformer) should work on Vulkan but benchmark is pending. The 27B Qwen3.6 model uses Gated DeltaNet; its Vulkan shader exists but is untested, so CPU is the safe default for the 27B model.
- **No DMA through holo-fs**: holo-fs is userspace FUSE. It adds overhead, not hardware acceleration.
- **No D-IMC in software**: true in-memory compute requires custom silicon. Vulkan GPU offload is the practical alternative.
- **No lossless compression of high-entropy weights**: qstar-pack expands quantized GGUF data. It is an archival format, not a compression win.
- **zig cc crash**: the cross-built llama-server/llama-cli crash due to a C++ ABI issue in zig 0.13.0. The native gcc build works. This is a pre-existing issue that needs a separate fix (newer zig, gcc cross-compile, or C++ initializer workaround).
