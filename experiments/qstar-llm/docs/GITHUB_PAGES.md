# GitHub Pages & Quine Hosting

Qstar-LLM publishes a self-contained quine edition and mesh status dashboard to GitHub Pages via CI/CD. The quine edition is a single `universe.html` file with embedded WASM that runs the full lattice inference engine in any browser — no server required.

---

## Architecture

```
┌──────────────────────────────────────────────┐
│              GitHub Pages (gh-pages)           │
├──────────────────────────────────────────────┤
│  universe.html       — Self-contained quine   │
│  qstar_llm.wasm      — Lattice WASM module    │
│  qstar_corpus_distilled.txt — Distilled corpus│
│  mesh_dashboard.html — Mesh topology dashboard│
│  index.html          — Documentation landing  │
└──────────────────────────────────────────────┘
         ▲
         │ CI/CD
┌──────────────────────────────────────────────┐
│         .github/workflows/pages.yml           │
│  1. Build WASM (zig build wasm)               │
│  2. Build quine (zig build html)              │
│  3. Deploy to gh-pages branch                 │
└──────────────────────────────────────────────┘
```

## CI/CD Workflow

File: `.github/workflows/pages.yml`

### Triggers
- Push to `main` branch
- Tag pushes (releases)

### Build Steps
1. **Setup Zig** — Installs Zig 0.13.0
2. **Build WASM** — `zig build wasm` produces `zig-out/lib/qstar_llm.wasm`
3. **Build HTML** — `zig build html` produces `zig-out/universe.html` with embedded WASM + distilled corpus
4. **Deploy to Pages** — Uses `actions/deploy-pages@v4` to publish to GitHub Pages

### Manual Build

```bash
# Build WASM module
zig build wasm

# Build self-contained universe.html quine
zig build html

# Output: zig-out/universe.html (single file, ~700KB)
```

### CLI Commands

```bash
# Build quine edition
qstar quine build

# Publish quine + payloads to GitHub Pages branch
qstar quine publish
```

## Quine Edition (`universe.html`)

The quine is a self-referential HTML file that:

1. **Embeds WASM** — The full lattice inference engine compiled to WebAssembly
2. **Embeds distilled corpus** — Compressed corpus text for retrieval-based responses
3. **Self-updates** — Checks master server for newer versions (SEED_VERSION, WASM_HASH)
4. **Works offline** — Degrades gracefully to embedded corpus when no network
5. **Zero dependencies** — No external JS libraries, CDNs, or API keys required

### Quine Autoupdate Flow

1. `universe.html` embeds `SEED_VERSION`, `SEED_HASH`, `WASM_HASH` at build time
2. On load, fetches `{MASTER_URL}/seed_manifest.json` (same-origin by default)
3. If `wasm_sha256` differs → pulls new `universe.html` and prompts reload
4. If `distilled_corpus_sha256` differs → pulls `qstar_corpus_distilled.txt` and learns
5. Offline quines degrade to embedded corpus

### Build Template

File: `src/universe_template.html`

The template is processed by `src/build_html.zig` which:
- Reads the WASM module and base64-encodes it
- Reads the distilled corpus and compresses it
- Injects both into the HTML template as JavaScript constants
- Writes the final `universe.html` to `zig-out/`

## Mesh Status Dashboard

File: `mesh_dashboard.html`

A static HTML page that visualizes:
- **Mesh topology** — Peer nodes, connections, transport modes
- **Live status** — Fetches `/api/mesh/status` from master server (if reachable)
- **Fallback snapshot** — Static snapshot from latest CI build when server is offline
- **Transport modes** — 12 modes with availability indicators and fallback chain
- **Collapse simulation** — Status indicator for civilization collapse mode
- **Embedded quine** — `universe.html` loaded as iframe

## Documentation Site

File: `docs/index.html`

GitHub Pages landing page with:
- Quick start guide
- CLI reference
- API reference
- Architecture overview (lattice, E0 nodes, channels)
- Ecosystem family tree (Abby/zotron/Qstar → qstar-llm → future children)
- Links to quine edition, mesh dashboard, releases
- Civilizational collapse recovery mission statement

## GitHub Pages URL Structure

| Path | Content |
|------|---------|
| `/` | Documentation landing page (`docs/index.html`) |
| `/universe.html` | Self-contained quine edition |
| `/qstar_llm.wasm` | Raw WASM module (for manual embedding) |
| `/qstar_corpus_distilled.txt` | Distilled corpus for quine autoupdate |
| `/mesh_dashboard.html` | Mesh topology dashboard |

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Pages branch | `gh-pages` | Branch for GitHub Pages content |
| Pages action | `actions/deploy-pages@v4` | Deployment action |
| Zig version | 0.13.0 | Zig compiler version for CI |
| WASM output | `zig-out/lib/qstar_llm.wasm` | WASM module path |
| HTML output | `zig-out/universe.html` | Quine edition path |
| Corpus output | `zig-out/qstar_corpus_distilled.txt` | Distilled corpus path |
