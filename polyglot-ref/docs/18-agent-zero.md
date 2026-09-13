# 18. Agent Zero Native Integration

## Quick Start (OS Users)

Agent Zero is disabled by default. To enable it at boot:

```bash
# Edit the boot config (or set in /etc/fano/fano.conf)
export FANO_AGENT_ZERO_ENABLED=1

# Reboot, or start manually:
/usr/lib/fano/agent-zero/venv/bin/python /usr/lib/fano/agent-zero/run_ui.py
```

Once running, open the Space Agent desktop shell and navigate to
`#/agent-zero`, or visit `http://127.0.0.1:8090` directly.

### RAM Boot and Plugin Availability

FANO-1 uses Puppy Linux's SFS layer system. The Agent Zero venv and
models live in the ADRV SFS layer (`adrv_slacko64_7.0.sfs`). On machines
with 8+ GB RAM, the ADRV is copied to RAM for full-speed operation. On
low-RAM machines, the ADRV mounts from disk (slower but functional).

All plugins are included in the ISO when built with the full
requirements (default). To build a minimal ISO that fits in 4 GB:

```bash
SKIP_HEAVY_PLUGINS=1 bash os/build-iso.sh
```

This uses `requirements-fano.txt` instead of the full `requirements.txt`,
deferring browser, whisper, kokoro, and unstructured plugins to
post-install:

```bash
# Install deferred plugins after first boot
/usr/lib/fano/agent-zero/venv/bin/pip install -r /usr/lib/fano/agent-zero/requirements.txt
```

## Overview

FANO-1 integrates [Agent Zero](https://github.com/agent0ai/agent-zero) as a native "second brain" agentic runtime. Agent Zero runs directly on the FANO-1 host OS, using a local TTY shell for code execution, connecting to a local llama-server instance for LLM inference, and using Podman (daemonless, rootless) for container-based plugins that need isolation.

## Architecture

```
FANO-1 boot (init-fano)
  |
  +-- start_llama_server()            # Primary: 3B model on port 8081 (Vulkan/CPU)
  |
  +-- start_agent_zero()
        |
        +-- start_podman_socket()      # Rootless Podman socket for _desktop
        +-- start_agent_zero_llama()   # Agent-zero: 0.5B model on port 8082
        |
        +-- run_ui.py                  # Flask WebUI on port 8090
              |
              +-- LiteLLM -> http://127.0.0.1:8082/v1
              +-- Local TTY shell (code execution)
              +-- Podman containers (_desktop Xpra/Xfce)
              +-- Vector memory (torch + sentence-transformers + faiss)
              +-- Browser (patchright/Playwright)
              +-- Speech (openai-whisper STT, kokoro TTS)
              +-- Email/Telegram/WhatsApp integrations
```

## Dual-Model Setup

FANO-1 bundles two models in the ISO:

| Model | Size | Purpose | Port |
|-------|------|---------|------|
| Qwen2.5-3B-Instruct Q4_K_M | 1.93 GB | Primary inference (Space Agent) | 8081 |
| Qwen2.5-0.5B-Instruct Q4_K_M | 379 MB | Agent Zero second brain | 8082 |

Both models run as separate llama-server instances to avoid model reload overhead. The 3B model serves the Space Agent onscreen/admin chat; the 0.5B model serves Agent Zero's autonomous agent loop.

## Container Runtime: Podman

FANO-1 uses Podman instead of Docker for container-based plugins:

- **Daemonless**: no background dockerd process; Podman activates on demand
- **Rootless**: runs as the current user, no root daemon
- **Docker-compatible**: the `docker` Python package talks to Podman via its Docker-compatible socket
- **Lighter**: ~80 MB vs ~200+ MB for Docker
- **All plugins enabled**: Podman provides container isolation for _desktop (Xpra/Xfce), while other plugins run natively

The `helpers/docker.py` module is patched to detect the Podman socket at `/run/user/<uid>/podman/podman.sock` as a fallback when the Docker daemon is unavailable. The `DOCKER_HOST` environment variable is set by `init-fano` to point at the Podman socket.

## Plugins

All Agent Zero plugins are enabled in native mode. The venv with all
plugin dependencies ships in the ADRV SFS layer:

| Plugin | Runtime | Notes |
|--------|---------|-------|
| _desktop | Podman container | Xpra/Xfce desktop for agent-isolated GUI |
| _browser | Native | Patchright/Playwright browser automation |
| _code_execution | Native local TTY | Direct shell execution on FANO-1 |
| _whisper_stt | Native | Speech-to-text via openai-whisper |
| _kokoro_tts | Native | Text-to-speech via kokoro |
| _email_integration | Native | IMAP/Exchange + SMTP |
| _telegram_integration | Native | Telegram bot API |
| _whatsapp_integration | Native | Baileys WhatsApp bridge |
| _oauth | Native | OAuth flow for account-backed providers |
| _document_query | Native | Document parsing via unstructured |
| _memory | Native | Vector memory via torch + sentence-transformers + faiss |

For minimal builds (SKIP_HEAVY_PLUGINS=1), browser/whisper/kokoro/
unstructured are deferred to post-install. See Quick Start above.

## Boot Integration

`init-fano` starts Agent Zero when `FANO_AGENT_ZERO_ENABLED=1`:

1. Starts Podman rootless socket (`podman system service`)
2. Starts a second llama-server on port 8082 with the 0.5B model
3. Waits for the llama-server health check (up to 30 seconds)
4. Sets `OPENAI_API_BASE`, `OPENAI_API_KEY`, `DOCKER_HOST` env vars
5. Launches `run_ui.py` on port 8090
6. Waits for the WebUI health check (up to 30 seconds)

## Space Agent Integration

Agent Zero is wired as a Space Agent module under `_core/agent_zero/`:

- **Routed page**: `#/agent-zero` embeds the Agent Zero WebUI in an iframe
- **Dashboard panel**: `Agent Zero` panel in the dashboard
- **Onscreen menu item**: `Agent Zero` action in the header dropdown
- **Request shaping**: Extension hooks for admin and onscreen chat that strip API-key requirements when targeting the Agent Zero endpoint
- **Health check**: `checkAgentZeroHealth()` helper probes the WebUI

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FANO_AGENT_ZERO_ENABLED` | `0` | Set to `1` to start Agent Zero at boot |
| `FANO_AGENT_ZERO_MODEL` | `/var/lib/fano/models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf` | Model file |
| `FANO_AGENT_ZERO_PORT` | `8090` | WebUI port |
| `FANO_AGENT_ZERO_LLAMA_PORT` | `8082` | Llama-server port |
| `FANO_AGENT_ZERO_NGL` | auto | GPU layers (auto = 99 if Vulkan, 0 if CPU) |
| `DOCKER_HOST` | `unix:///run/user/<uid>/podman/podman.sock` | Podman socket |

## ISO Budget

| Component | Size |
|-----------|------|
| Current ISO (pre-agent-zero) | 0.53 GB |
| 3B model | 1.93 GB |
| 0.5B model | 0.37 GB |
| Agent Zero source | 0.05 GB |
| Agent Zero venv (full deps) | ~0.6 GB |
| Podman + deps | 0.08 GB |
| **Estimated total** | **~3.56 GB** |

Within the 4 GB budget with ~0.44 GB headroom. If over budget, the heaviest optional deps (unstructured, openai-whisper) can be deferred to post-install.

## Security Considerations

- Code execution runs natively on FANO-1 via local TTY (no container isolation for code execution)
- The _desktop plugin uses Podman containers for Xpra/Xfce desktop isolation
- The agent has full host access for code execution, equivalent to running commands in a terminal
- Podman rootless mode limits container privileges to the user level
- This is acceptable for a single-user desktop OS where the user owns the system
- For multi-user or untrusted environments, additional native sandboxing (namespaces, seccomp, cgroups) would be needed

## Python Version

Agent Zero upstream targets Python 3.12+. FANO-1 bundles Python 3.11.9. The core dependencies (litellm, flask, langchain-core) support 3.11. If 3.12 is required at runtime, it will be bundled alongside 3.11 (similar to jdk-17 and node20).

## Files

- `os/agent-zero/` - vendored Agent Zero source (Docker build files removed)
- `os/agent-zero/FANO-NATIVE.md` - native integration notes
- `os/agent-zero/conf/fano_native_config.yaml` - native config override
- `os/agent-zero/conf/model_providers.yaml` - added `fano_local` provider
- `os/agent-zero/helpers/docker.py` - patched with Podman socket fallback
- `os/agent-zero/helpers/subagents.py` - patched for Python 3.11 compat (PEP 695)
- `os/agent-zero/helpers/plugins.py` - patched for Python 3.11 compat (PEP 695)
- `os/agent-zero/requirements-fano.txt` - trimmed requirements for ISO budget
- `os/build-iso.sh` - `package_agent_zero()` and `package_podman()` functions
- `os/init-fano` - `start_agent_zero()`, `start_agent_zero_llama()`, `start_podman_socket()` functions
- `space-agent/app/L0/_all/mod/_core/agent_zero/` - Space Agent module

## Developer Notes

### Python 3.11 Compatibility

Agent Zero upstream uses PEP 695 `type` statements (Python 3.12+). Two
files were patched to use `TypeAlias` instead:

- `helpers/subagents.py`: `type Origin = ...` -> `Origin: TypeAlias = ...`
- `helpers/plugins.py`: `type ToggleState = ...` -> `ToggleState: TypeAlias = ...`

If upstream adds more PEP 695 syntax, run:
```bash
python3 -m compileall -q os/agent-zero/ -x __pycache__
```
to find new syntax errors.

### Podman Integration

`helpers/docker.py` is patched with:
- Graceful `import docker` (try/except ImportError)
- `_find_podman_socket()` detects `/run/user/<uid>/podman/podman.sock`
- `init_docker()` falls back to Podman socket when Docker daemon is unavailable

The `DOCKER_HOST` env var is set by `init-fano` to the Podman socket path.

### ISO Budget Management

The full `requirements.txt` produces a ~4 GB venv. The trimmed
`requirements-fano.txt` produces a ~1.5 GB venv by deferring heavy
optional plugins. The stripped venv removes:
- `__pycache__/`, `*.pyc`, `*.pyo` — bytecode caches
- `*.a` — static libraries
- `torch/include/`, `*.h`, `*.hpp`, `*.cmake` — torch headers
- `README*`, `*.rst`, `*.md`, `LICENSE*` — documentation

Do NOT delete `torch/bin/` or files matching `*test*` in torch — these
are runtime dependencies despite their names.

### Adding New Plugins

1. Check if the plugin needs Docker/Podman or runs natively
2. Add any new Python deps to `requirements-fano.txt` if they fit the budget
3. If deps are heavy, document them as post-install in `requirements-fano.txt`
4. Test with: `cd os/agent-zero && venv/bin/python -c "import plugins.<name>..."`
