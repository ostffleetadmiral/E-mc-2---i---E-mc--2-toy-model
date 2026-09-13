# 19. Component Reference

Developer-facing reference for every FANO-1 OS component. Each entry
covers purpose, location, key files, dependencies, and verification.

## OS Build System

### build-iso.sh

- **Purpose**: Master ISO build script. Orchestrates all packaging steps
  into the final FANO-1 Slacko64 ISO.
- **Location**: `os/build-iso.sh`
- **Key functions**:
  - `package_llama()` — cross-builds and packages llama.cpp binaries
  - `package_small_model()` — bundles the 0.5B GGUF model
  - `package_model_3b()` — bundles the 3B GGUF model
  - `package_agent_zero()` — vendored Agent Zero source + Python venv
  - `package_podman()` — Podman runtime + container deps
  - `package_fano_langs()` — Python, Node, JDK, .NET, Q# toolchains
  - `package_space_agent()` — Space Agent browser shell
- **Dependencies**: `rsync`, `curl`, `python3`, `zig` (for llama cross-build)
- **Verification**: `bash -n os/build-iso.sh`; `bash os/test-packaging.sh`
- **Env vars**: `SKIP_AGENT_ZERO=1`, `SKIP_PODMAN=1`, `SKIP_LLAMA=1`,
  `FANO_PYTHON=python3.11`

### init-fano

- **Purpose**: Boot-time init script. Starts all FANO-1 services.
- **Location**: `os/init-fano`
- **Key functions**:
  - `detect_vulkan()` — hardware-agnostic Vulkan ICD detection
  - `start_llama_server()` — primary 3B model on port 8081
  - `start_podman_socket()` — rootless Podman socket for containers
  - `start_agent_zero_llama()` — 0.5B model on port 8082
  - `start_agent_zero()` — Flask WebUI on port 8090
- **Verification**: `bash -n os/init-fano`; `bash os/test-iso.sh --auto`
- **Env vars**: See `docs/17-local-inference.md` env var table

### fetch-model.sh

- **Purpose**: Downloads and verifies pinned GGUF model files.
- **Location**: `os/fano-models/fetch-model.sh`
- **Targets**: `3b-q4_k_m`, `0.5b-q4_k_m`, `27b-iq2_m`, `27b-q4_k_m`,
  `35b-iq2_s`, `all`
- **Verification**: `bash os/fano-models/fetch-model.sh --verify-only 3b-q4_k_m`
- **Features**: Resumable downloads, SHA-256 + size verification,
  `--verify-only` mode

### audit-iso-size.sh

- **Purpose**: Audits ISO size against the 4 GB budget.
- **Location**: `os/audit-iso-size.sh`
- **Verification**: `bash os/audit-iso-size.sh`

### build-llama.sh

- **Purpose**: Cross-builds llama.cpp for Slacko64 glibc 2.23 target.
- **Location**: `os/build-llama.sh`
- **Build**: `zig cc` targeting `x86_64-linux-gnu.2.23`, Vulkan enabled

## Local Inference (llama.cpp)

### llama-server (primary)

- **Purpose**: Primary FANO-1 LLM inference server.
- **Port**: 8081
- **Model**: Qwen2.5-3B-Instruct Q4_K_M (1.93 GB)
- **Backend**: Vulkan GPU (`-ngl 99`) or CPU (`-ngl 0`), auto-detected
- **API**: OpenAI-compatible `/v1/chat/completions`, `/v1/embeddings`
- **Health**: `http://127.0.0.1:8081/health`
- **Location**: `/usr/lib/fano/llama/bin/llama-server`

### llama-server (agent-zero)

- **Purpose**: Agent Zero's dedicated LLM inference server.
- **Port**: 8082
- **Model**: Qwen2.5-0.5B-Instruct Q4_K_M (379 MB)
- **Backend**: Same Vulkan/CPU auto-detection as primary
- **API**: OpenAI-compatible
- **Health**: `http://127.0.0.1:8082/health`

### Vulkan Backend

- **Library**: `libggml-vulkan.so` (bundled)
- **Detection**: Hardware-agnostic; checks for Vulkan loader, ICD JSON
  files, rejects software-only ICDs (llvmpipe, lavapipe)
- **Tested on**: AMD RX 580 2048SP (RADV POLARIS10, Vulkan 1.3)
- **Benchmark**: See `os/fano-models/bench-results.md`

### Benchmark Results

| Model | Backend | pp128 (t/s) | tg16 (t/s) |
|-------|---------|-------------|------------|
| Qwen2.5-3B Q4_K_M | CPU | 17.84 | 9.20 |
| Qwen2.5-3B Q4_K_M | Vulkan | 364.23 | 58.49 |
| Qwen2.5-0.5B Q4_K_M | CPU | 779.51 | 41.74 |
| Qwen2.5-0.5B Q4_K_M | Vulkan | 1869.67 | 161.66 |

## Agent Zero

### Source

- **Location**: `os/agent-zero/` (vendored copy, Docker build files removed)
- **Size**: ~54 MB
- **Upstream**: https://github.com/agent0ai/agent-zero
- **Changes from upstream**:
  - Removed: `docker/`, `DockerfileLocal`, `.github/`, `tests/`
  - Patched: `helpers/docker.py` (Podman socket fallback)
  - Patched: `helpers/subagents.py`, `helpers/plugins.py` (Python 3.11 compat)
  - Added: `conf/fano_native_config.yaml`, `requirements-fano.txt`, `FANO-NATIVE.md`

### Configuration

- **Native config**: `os/agent-zero/conf/fano_native_config.yaml`
- **Model providers**: `os/agent-zero/conf/model_providers.yaml`
  (added `fano_local` provider)
- **Key settings**:
  - `ssh_enabled: false` — local TTY code execution
  - `container_runtime: podman` — Podman for container plugins
  - `plugins: {}` — all plugins enabled
  - `chat_provider: fano_local` — local llama-server on port 8082

### Python Venv

- **Location**: `/usr/lib/fano/agent-zero/venv/`
- **Requirements**: `os/agent-zero/requirements-fano.txt` (trimmed)
- **Size**: ~1.5 GB (stripped)
- **Key packages**: torch (CPU), torchvision (CPU), sentence-transformers,
  faiss-cpu, litellm, flask, python-socketio, docker, langchain-core
- **Deferred to post-install**: patchright (browser), openai-whisper (STT),
  kokoro (TTS), unstructured (document query), spacy, boto3
- **Post-install command**: `pip install -r requirements.txt`

### Plugins

| Plugin | In-ISO | Runtime | Post-install deps |
|--------|--------|---------|-------------------|
| _code_execution | Yes | Native local TTY | None |
| _memory | Yes | Native | None |
| _browser | No | Native | patchright (~139 MB) |
| _desktop | Yes | Podman container | None |
| _email_integration | Yes | Native | None |
| _telegram_integration | Yes | Native | None |
| _whatsapp_integration | Yes | Native | None |
| _oauth | Yes | Native | None |
| _document_query | Partial | Native | unstructured chain (~500 MB) |
| _whisper_stt | No | Native | openai-whisper (~800 MB) |
| _kokoro_tts | No | Native | kokoro |

### WebUI

- **Port**: 8090
- **Entry**: `run_ui.py`
- **Framework**: Flask + Alpine.js + Socket.IO
- **Health**: `http://127.0.0.1:8090/health`

## Podman

- **Purpose**: Daemonless, rootless container runtime for _desktop plugin
- **Location**: `/usr/bin/podman`, `/usr/bin/conmon`, `/usr/bin/crun`
- **Socket**: `/run/user/<uid>/podman/podman.sock`
- **Docker compat**: `docker` Python package connects via `DOCKER_HOST`
- **Size**: ~80 MB (podman + conmon + crun + CNI plugins)
- **Start**: `podman system service --timeout 0` (on-demand, no daemon)

## Space Agent

### agent_zero Module

- **Location**: `space-agent/app/L0/_all/mod/_core/agent_zero/`
- **Files**:
  - `request.js` — endpoint detection (`127.0.0.1:8090`), request shaping
  - `health.js` — `checkAgentZeroHealth(endpoint)` helper
  - `store.js` — Alpine store with health polling
  - `view.html` — routed `#/agent-zero` page (iframe embed)
  - `agent_zero.css` — page styling
  - `ext/panels/agent_zero.yaml` — dashboard panel manifest
  - `ext/html/_core/onscreen_menu/items/agent-zero.html` — menu item
  - `ext/js/.../agent-zero.js` — admin + onscreen API request hooks
- **Pattern**: Mirrors `_core/local_llama` and `_core/open_router`

### local_llama Module

- **Location**: `space-agent/app/L0/_all/mod/_core/local_llama/`
- **Purpose**: Detects `127.0.0.1:8081`, strips API key, health check

## Models

| Model | File | Size | SHA-256 | Port | Role |
|-------|------|------|---------|------|------|
| Qwen2.5-3B-Instruct Q4_K_M | `Qwen2.5-3B-Instruct-Q4_K_M.gguf` | 1.93 GB | `9c9f56a3...` | 8081 | Primary |
| Qwen2.5-0.5B-Instruct Q4_K_M | `Qwen2.5-0.5B-Instruct-Q4_K_M.gguf` | 379 MB | `6eb923e7...` | 8082 | Agent Zero |

- **Storage**: `/var/lib/fano/models/` (ISO) or external storage
- **Fetch**: `bash os/fano-models/fetch-model.sh <target>`

## ISO Layout and RAM Boot

FANO-1 uses Puppy Linux's SFS layer system for RAM-boot. The ISO
contains two SFS files:

| SFS file | Contents | Compressed size (est.) |
|----------|----------|----------------------|
| `puppy_slacko64_7.0.sfs` | Base Slacko64 + FANO binaries + Agent Zero source | ~350 MB |
| `adrv_slacko64_7.0.sfs` | 3B model + 0.5B model + Agent Zero venv + Podman | ~3.9 GB |

Puppy's initrd auto-detects available RAM and copies SFS files to tmpfs
(RAM) when there's space, otherwise mounts from disk via loopback.

| RAM | Base rootfs | ADRV | Behavior |
|-----|-------------|------|----------|
| 16 GB | In RAM | In RAM | Full RAM boot, all plugins |
| 8 GB | In RAM | In RAM | Full RAM boot, all plugins |
| 4 GB | In RAM | From disk | Base in RAM, models/venv from USB |
| 2 GB | From disk | From disk | Everything from disk (slow) |

Build options:
- Default: full `requirements.txt` (all plugins in ADRV)
- `SKIP_HEAVY_PLUGINS=1`: trimmed `requirements-fano.txt` (deferred plugins)

## ISO Budget

The ISO has no size cap — it is just the boot medium. The RAM budget
is what matters for RAM-boot:

| Component | Uncompressed | In SFS (compressed) |
|-----------|-------------|---------------------|
| Base Slacko64 + FANO binaries | ~1.0 GB | ~350 MB |
| 3B model (Q4_K_M) | 1.93 GB | 1.93 GB (no further compression) |
| 0.5B model (Q4_K_M) | 0.37 GB | 0.37 GB |
| Agent Zero source | 0.05 GB | ~0.03 GB |
| Agent Zero venv (full) | ~4.0 GB | ~2.5 GB |
| Podman + deps | 0.08 GB | ~0.05 GB |
| **Total ISO** | **~7.4 GB** | **~5.2 GB** |
| **RAM for full boot** | | **~5.2 GB + 1 GB overhead = ~6.2 GB** |

With squashfs compression, the venv .py files compress ~2x but .so files
(torch, faiss) and GGUF models don't compress further.

## Verification Commands

```bash
# Script syntax
bash -n os/build-iso.sh
bash -n os/init-fano
bash -n os/fano-models/fetch-model.sh

# Model verification
bash os/fano-models/fetch-model.sh --verify-only 3b-q4_k_m
bash os/fano-models/fetch-model.sh --verify-only 0.5b-q4_k_m

# Packaging tests
bash os/test-packaging.sh

# ISO size audit
bash os/audit-iso-size.sh

# Space Agent module JS syntax
node --check space-agent/app/L0/_all/mod/_core/agent_zero/request.js
node --check space-agent/app/L0/_all/mod/_core/agent_zero/health.js
node --check space-agent/app/L0/_all/mod/_core/agent_zero/store.js

# Agent Zero Python imports (requires venv)
cd os/agent-zero && venv/bin/python -c "import agent, models, initialize"

# Dual llama-server boot test
# (See docs/17-local-inference.md for the test procedure)

# Podman integration
podman --version
python3 -c "import docker; c=docker.DockerClient(base_url='unix:///run/user/$(id -u)/podman/podman.sock'); print(c.version())"
```
