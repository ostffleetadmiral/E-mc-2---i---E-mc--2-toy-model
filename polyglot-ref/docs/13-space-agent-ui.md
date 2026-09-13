# 13 — Space Agent UI (`space-agent/`)

## Architecture Overview

### Purpose

Space Agent is a browser-first AI agent runtime with a thin Node.js server bridge. It provides the primary user interface for FANO-1 OS — a self-modifying HTML application that runs in the browser and communicates with FANO-1 backend services via WebSockets and HTTP. The agent logic lives entirely in the browser; the server handles only fetch proxying, local infrastructure, and multi-user isolation.

### Module Structure

| Path | Type | Purpose |
|------|------|---------|
| `space` | Script | CLI entry point (shell script → node) |
| `space.js` | 100 lines | CLI command loader and dispatcher |
| `app/` | dir | Primary Space Agent runtime (browser-side) |
| `commands/` | dir | CLI command modules |
| `server/` | dir | Thin local infrastructure runtime |
| `packaging/` | dir | Native app hosts (Electron desktop packaging) |
| `tests/` | dir | Verification harnesses and evaluation fixtures |
| `package.json` | 101 lines | NPM package definition + Electron build config |

### Dependencies

- **External**: Node.js ≥ 20, Electron (desktop packaging), `archiver`, `electron-updater`, `isomorphic-git`
- **Internal**: Connects to FANO-1 quine-server (port 8080), holo-fs, Godot scene bridge

---

## CLI Architecture (`space.js`)

### Command System

```
node space <command> [args...]
```

Commands are auto-discovered from the `commands/` directory:
1. Read all `.js` files from `commands/`
2. Normalize command name (lowercase, validate against `^[a-z][a-z0-9-]*$`)
3. Dynamic `import()` the command module
4. Call `module.execute({ args, commandName, commandsDir, ... })`
5. Exit code from return value

### Aliases

| Alias | Command |
|-------|---------|
| `--help` | `help` |
| `--version` | `version` |

### Environment

- Loads `.env` files from project root via `server/lib/utils/env_files.js`
- Preserves original `process.env` before loading

---

## Browser Runtime (`app/`)

The `app/` directory contains the primary Space Agent runtime — all agent logic runs in the browser. Key characteristics:

- **Browser-first**: Maximum logic in the frontend; backend is minimal
- **Self-modifying HTML**: UI is generated and modified dynamically via `document.documentElement.outerHTML`
- **WebSocket connectivity**: Real-time communication with FANO-1 services
- **Scene bridge integration**: Sends JSON commands to Godot scene tree via `scene_bridge.zig` protocol

### DOX Framework

The `space-agent/` directory follows the DOX (DOcument eXecutable) framework:
- `AGENTS.md` files define binding work contracts for each subtree
- Hierarchy: root → app/ → commands/ → server/ → packaging/ → tests/
- Each AGENTS.md documents purpose, ownership, local contracts, work guidance, and verification

---

## Server Bridge (`server/`)

The server is intentionally thin — it handles only:
- **Fetch proxying**: CORS-bypass proxy for external API calls
- **Local infrastructure**: File system access, process management
- **Multi-user isolation**: Session separation for concurrent users
- **Runtime stability**: Process supervision, health checks

No agent logic resides in the server. All AI reasoning, tool use, and UI generation happen in the browser.

---

## Desktop Packaging (`packaging/`)

### Supported Platforms

| Platform | Target | Architecture |
|----------|--------|--------------|
| macOS | DMG + ZIP | x64, arm64 |
| Windows | NSIS installer | x64, arm64 |
| Linux | AppImage | x64, arm64 |

### Build Commands

```bash
npm run desktop:dev          # Dev mode
npm run desktop:pack         # Unpacked directory
npm run desktop:dist         # Distributable package
npm run desktop:dist:all     # All architectures
npm run package:desktop:linux  # Linux AppImage
```

### Electron Configuration

- App ID: `com.spaceagent.desktop`
- Product name: Space Agent
- Auto-update via `electron-updater` (GitHub releases)
- Hardened runtime on macOS with entitlements

---

## NPM Configuration (`package.json`)

| Field | Value |
|-------|-------|
| Name | `space-agent` |
| Version | `0.36.0` |
| Main | `packaging/desktop/main.js` |
| Node engine | `>= 20` |
| Dependencies | `archiver`, `electron-updater`, `isomorphic-git` |

---

## Integration Points

- **Quine Server** (`quine-server/`): HTTP API at port 8080 for document persistence
- **Godot Scene Bridge** (`godot/scene_bridge.zig`): JSON command protocol for scene modification
- **Quine HTML** (`quine.html/`): Self-modifying HTML foundation
- **OS Build** (`os/`): Space Agent is the FANO-1 ISO desktop shell — served by its own Node server on port 3000 (single-user mode) and displayed by a kiosk browser at `/#desktop`; the narrow OS bridge (`os_launch`/`os_window_list`/`os_power`) provides launch/window-list/power, and JWM stays invisible underneath (see `docs/12-os-build-scripts.md`)
- **Local LLM** (`os/llama.cpp/`): the headless `_core/local_llama/` module connects the onscreen and admin agents to the local llama-server OpenAI-compatible endpoint (port 8081); mirrors the `_core/open_router/` pattern; strips API-key requirement; provides health-check fallback (see `docs/17-local-inference.md`)
- **Blockchain** (`blockchain/`): Future P2P contract execution via browser WASM

**ATMA mapping:** the desktop surface where the node operates; Space Agent is the shell of the Atman (see docs/16-atma-fano1.md).
