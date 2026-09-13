# 14 — Quine HTML Frontend (`quine.html/`)

## Architecture Overview

### Purpose

The `quine.html/` directory is a **vendored upstream reference project** that
demonstrates the self-saving HTML quine concept. It is **not** part of the
FANO-1 production build. The production quine rendering surface is split
between:

- `quine-server/quine_page.zig` — the embedded quine page served by
  quine-server on port 8080.
- `space-agent/server/pages/fano_quine.html` — the Space Agent quine page
  served by the Space Agent backend.

The vendored `quine.html/` project is archived and kept only as a reference
for the quine concept and TaskPaper data format.

### Module Structure

| File | Size | Purpose |
|------|------|---------|
| `quine.html` | 168 KB | The complete self-contained quine application (reference) |
| `src/` | dir | Source files for build (reference) |
| `lib/` | dir | Library dependencies (reference) |
| `Gruntfile.coffee` | 2.3 KB | Grunt build configuration (reference) |
| `package.json` | 11 lines | NPM dev dependencies (reference) |

### Dependencies

- **External**: Grunt (build only), TiddlyWiki Firefox add-on (optional for saving)
- **Runtime**: Any web browser (Firefox preferred)

> **Note**: These dependencies are for the vendored reference project only.
> The production FANO-1 quine surface has no Grunt or TiddlyWiki dependency.

---

## Quine Concept

### What is a Quine?

A quine is a self-referential program that outputs its own source code. The
quine.html file:

1. **Contains both data and logic** — the HTML file stores its content as
   TaskPaper-formatted text within the page itself
2. **Can save itself** — JavaScript reads `document.documentElement.outerHTML`
   and writes it back to disk
3. **Works offline** — no server required; opens directly in a browser
4. **Persists changes** — via TiddlyWiki Firefox add-on (saves to filesystem)
   or browser localStorage (fallback)

### TaskPaper Format

The internal data format is TaskPaper — a plain-text outline format:

```
Project:
    - [ ] Task with @tag
    - [x] Completed task
    Notes indented under tasks
```

This provides:
- Human-readable plain text (editable in any editor)
- Machine-parseable structure (projects, tasks, tags, notes)
- Hierarchical organization via indentation

---

## Build System (Reference Only)

The Grunt build pipeline compiles source files into the final `quine.html`:

1. **CoffeeScript** -> JavaScript (via `grunt-contrib-coffee`)
2. **CSS minification** (via `grunt-contrib-cssmin`)
3. **JavaScript minification** (via `grunt-contrib-uglify`)
4. **Inline assets** (via `grunt-inline`) — embeds CSS and JS into the HTML

> **Note**: This build system is not invoked by the FANO-1 build graph.
> The vendored `quine.html/` is kept as-is for reference.

---

## FANO-1 Production Quine Surface

The production FANO-1 quine rendering is split across two components:

### 1. Quine Server Embedded Page (`quine-server/quine_page.zig`)

- Served at `http://127.0.0.1:8080/` by quine-server.
- Embedded as a Zig string literal in `quine_page.zig`.
- Provides the quine document editing surface with server-side persistence.
- Persistence via `POST /api/doc` to quine-server, which writes to disk or
  holo-fs.

### 2. Space Agent Quine Page (`space-agent/server/pages/fano_quine.html`)

- Served by the Space Agent backend.
- Integrates the quine concept into the Space Agent desktop shell.
- Part of the browser-first desktop at `http://127.0.0.1:3000/#desktop`.

### Data Flow (Production)

```
User edits in browser (quine-server or Space Agent)
    |
    v
JavaScript reads content
    |
    v
POST /api/doc (to quine-server on port 8080)
    |
    v
quine-server writes to disk (or holo-fs at /mnt/holo-fs/)
    |
    v
GET /api/doc reloads content
```

### Comparison: Vendored vs Production

| Feature | quine.html (vendored) | quine-server (production) | Space Agent (production) |
|---------|----------------------|---------------------------|--------------------------|
| Saving | TiddlyWiki add-on | HTTP POST to server | HTTP POST to server |
| Persistence | Browser filesystem | Disk / holo-fs | Disk / holo-fs |
| Server required | No | Yes (port 8080) | Yes (port 3000) |
| FANO-1 integration | Reference only | Production | Production |
| Build dependency | Grunt, npm | Zig build | Node.js build |

---

## Inspiration & Lineage

The quine.html project draws from:

- **TiddlyWiki**: Self-contained wiki that saves itself to disk
- **Todo.txt**: Plain-text todo management
- **TaskPaper**: Plain-text outliner with projects, tasks, and tags

The key innovation is combining the self-saving quine property with
TaskPaper's structured plain text, creating a file that is both
human-editable and machine-processable.

---

## Integration Points

- **Quine Server** (`quine-server/`): Production quine page embedded in
  `quine_page.zig`, served on port 8080
- **Space Agent** (`space-agent/`): Production quine page at
  `server/pages/fano_quine.html`, integrated into the desktop shell
- **OS Build** (`os/`): quine-server started at boot by `init-fano`
- **Holo-FS** (`holo-fs/`): Document storage on holographic FUSE filesystem
