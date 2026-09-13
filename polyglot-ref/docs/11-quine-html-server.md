# 11 — Quine HTML Server (`quine-server/`)

## Architecture Overview

### Purpose

The quine-server module implements a standalone HTTP server that serves a self-contained TaskPaper editor page (the "quine"). It replaces browser-based saving mechanisms (TiddlyFox/mozillaSaveFile) with server-side file persistence. The server runs on port 8080 and provides REST endpoints for document load/save, version info, and system status.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `server.zig` | 429 | HTTP server: request parsing, routing, document persistence |
| `quine_page.zig` | 83 | Embedded HTML/CSS/JS page template (the quine) |
| `build.zig` | 32 | Build system: executable + tests |

### Dependencies

- **External**: None (pure Zig; uses `std.net.Server`)
- **Internal**: None

---

## HTTP Server (`server.zig`)

### Configuration

| Constant | Value | Description |
|----------|-------|-------------|
| `PORT` | 8080 | Default listen port |
| `VERSION` | `"FANO-1 Quine Server v1.0"` | Server version string |
| `DOC_PATH_DEFAULT` | `"fano-doc.taskpaper"` | Default document filename |

### Endpoints

| Method | Path | Response | Description |
|--------|------|----------|-------------|
| `GET` | `/` | HTML | Serve the quine editor page |
| `GET` | `/api/doc` | JSON | Return current document content |
| `POST` | `/api/doc` | JSON | Save document content from JSON body |
| `GET` | `/api/version` | JSON | Server version + port info |
| `GET` | `/api/status` | JSON | Document stats, uptime, save count |

### Server State

```zig
const Server = struct {
    alloc: Allocator,
    doc_path: []const u8,
    port: u16,
    doc_content: ArrayList(u8),
    mutex: Thread.Mutex,    // Thread-safe document access
    start_time: i64,
    save_count: u64,
};
```

### Document Lifecycle

1. **Initialization**: Try to load existing document from `doc_path`. If not found, use default TaskPaper content.
2. **Read**: `GET /api/doc` returns `{"content": "..."}` JSON
3. **Write**: `POST /api/doc` with `{"content": "..."}` body → saves to memory + disk
4. **Persistence**: Each save writes the full document to `doc_path` on disk

### Request Handling

- Single-threaded connection handler (one connection at a time)
- 16 KB read buffer for HTTP requests
- Manual HTTP method/path parsing (no HTTP library)
- JSON responses built with manual string formatting

### Usage

```bash
quine-server [doc-path] [port]
# Example: quine-server /mnt/holo-fs/fano-doc.taskpaper 8080
```

---

## Quine Page (`quine_page.zig`)

### Purpose

Embedded HTML page served at `GET /`. A self-contained TaskPaper editor that loads and saves via the `/api/doc` endpoint.

### Page Structure

```html
<!DOCTYPE html>
<html>
<head>
  <title>FANO-1 Quine</title>
  <style>
    /* Dark theme: #1a1a2e background, #e94560 accent */
    body { font-family: monospace; }
    #editor { width: 100%; height: 70vh; }
    #toolbar { display: flex; gap: 8px; }
    button { background: #e94560; color: white; }
  </style>
</head>
<body>
  <h1>FANO-1 Quine Server</h1>
  <div id="toolbar">
    <button onclick="saveDoc()">Save</button>
    <button onclick="reloadDoc()">Reload</button>
    <span id="status">Ready</span>
  </div>
  <textarea id="editor" spellcheck="false"></textarea>
  <script>
    // fetch('/api/doc') to load
    // fetch('/api/doc', {method:'POST', body:JSON.stringify({content:...})}) to save
  </script>
</body>
</html>
```

### Default Document

```
FANO-1 Document:
    @created: 2026-09-08
    @type: taskpaper

Tasks:
    - [ ] Boot FANO-1 ISO in QEMU
    - [ ] Mount holo-fs filesystem
    - [ ] Start quine server
    - [ ] Verify holographic compression round-trip
    - [ ] Run RamseyIdentity 11-test suite

Notes:
    This document is served by the FANO-1 Quine Server.
    Edits are saved to disk via POST /api/doc.
```

---

## Build Configuration (`build.zig`)

### Targets

| Target | Type | Description |
|--------|------|-------------|
| `quine-server` | Executable | HTTP server binary |
| `test` | Test step | Server unit tests |
| `run` | Run step | Build + run server |

### Build Commands

```bash
cd quine-server/ && zig build         # Build server
cd quine-server/ && zig build test     # Run tests
cd quine-server/ && zig build run       # Build + run
```

---

## Integration Points

- **OS Build** (`os/`): quine-server started at boot via `init-fano` on port 8080
- **Holo-FS** (`holo-fs/`): Document persisted on holographic FUSE mount
- **Quine HTML** (`quine.html/`): Upstream self-modifying HTML concept
- **Space Agent** (`space-agent/`): Browser connects to quine-server for UI
- **Kernel** (`kernel/`): Kernel shell can invoke quine-server
