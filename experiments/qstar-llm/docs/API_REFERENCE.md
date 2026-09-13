# API Reference

Complete CLI command and HTTP API reference for Qstar-LLM.

---

## CLI Commands

All commands run via `zig build cli -- <command> [options]`.

### `run`

Single-shot text completion. Generates a response to a prompt.

```bash
zig build cli -- run "Explain quantum computing"
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model for comparison/augmentation |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load |
| `--vocab <spec>` | auto | Ramsey vocab specifier (128k, 256k, 512k, 1m) |
| `--level <N>` | 0 | Lattice level (0-3) |
| `--autoscale` | off | Enable dynamic lattice auto-tuning |
| `--max-cycles <N>` | 1024 | Maximum inference cycles |
| `--draft-mode` | off | Enable speculative draft mode (Qstar generates, Ollama verifies) |
| `--draft-model <name>` | `qwen2.5:3b` | Ollama model for draft verification |

#### Speculative Draft Mode

In draft mode, Qstar generates a fast draft response using its lattice engine, then sends it to an external LLM (Ollama) for verification. The verifier corrects errors and returns a verified response with acceptance statistics.

```bash
zig build cli -- run "Explain photosynthesis" --draft-mode --draft-model qwen2.5:3b
```

Output includes:
- Draft response with token count, generation time, and tokens/sec
- Verified response with acceptance rate (accepted/rejected token counts)
- Falls back to draft response if Ollama is unavailable

### `chat`

Interactive multi-turn chat with the agent.

```bash
zig build cli -- chat
zig build cli -- chat "Hello, what are you?"
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load |
| `--vocab <spec>` | auto | Ramsey vocab specifier |
| `--level <N>` | 0 | Lattice level |
| `--autoscale` | off | Dynamic lattice auto-tuning |
| `--memory` | off | Enable memory callbacks |
| `--memory-file <path>` | `qstar_memory.json` | Episodic memory file |

### `serve`

Start the HTTP API server (Ollama + OpenAI compatible).

```bash
zig build cli -- serve
zig build cli -- serve --port 8080
```

| Flag | Default | Description |
|------|---------|-------------|
| `--port <N>` | 11435 | HTTP server port |

### `train`

Self-training using Ollama or OpenAI as teacher.

```bash
zig build cli -- train --model qwen2.5:3b --corpus qstar_corpus.txt
zig build cli -- train --teacher openai --openai-model gpt-4o --limit 3
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama teacher model |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file |
| `--prompts <path>` | built-in | Custom prompts file (one per line) |
| `--limit <N>` | all | Only process N prompts (quick smoke tests) |
| `--verbose` | off | Print per-prompt progress |
| `--teacher <name>` | `auto` | Teacher: `ollama`, `openai`, or `auto` (OpenAI if key present, else Ollama) |
| `--openai-model <name>` | `gpt-4o` | OpenAI teacher model |
| `--openai-key <key>` | `.env` | OpenAI API key (overrides `OPENAI_API_KEY` from `.env`) |

#### `.env` Setup

Create a `.env` file in the project root (never committed):

```bash
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o
OLLAMA_HOST=127.0.0.1
OLLAMA_PORT=11434
OLLAMA_MODEL=qwen2.5:3b
JUDGE_MODEL=qwen2.5:3b
JUDGE_HOST=127.0.0.1
JUDGE_PORT=11434
MAPLE_HOST=192.168.4.1
MAPLE_PORT=80
```

The loader checks real environment variables first, then `.env` entries. `JUDGE_HOST`/`JUDGE_PORT` direct judge traffic to a separate Ollama instance (avoids model-swap clashing in competitive benchmarks).

### `train-internet`

Fetch and learn from Wikipedia articles.

```bash
zig build cli -- train-internet --offset 0 --no-ollama --corpus qstar_corpus.txt
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model for augmentation |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file |
| `--offset N` | 0 | Skip first N articles (resumable) |
| `--limit N` | all | Only fetch N articles |
| `--no-ollama` | off | Disable Ollama augmentation |

### `ingest-corpus`

Directly ingest local documents into corpus (no Ollama needed).

```bash
zig build cli -- ingest-corpus datasets/Gov --corpus-file qstar_corpus.txt
```

| Flag | Default | Description |
|------|---------|-------------|
| `--corpus-file <path>` | `qstar_corpus.txt` | Corpus file to append to |

Positional argument: directory path to ingest.

### `enrich-corpus`

Ollama-enriched corpus ingestion from local documents.

```bash
zig build cli -- enrich-corpus datasets/AdmPaul --corpus-file qstar_corpus.txt
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model for enrichment |
| `--corpus-file <path>` | `qstar_corpus.txt` | Corpus file |

Positional argument: directory path to enrich.

### `train-corpus`

Full training pipeline: ingest + enrich from directories.

```bash
zig build cli -- train-corpus --ingest-dir datasets/Gov --enrich-dir datasets/AdmPaul
```

| Flag | Default | Description |
|------|---------|-------------|
| `--ingest-dir <path>` | required | Directory for direct ingestion |
| `--enrich-dir <path>` | required | Directory for Ollama enrichment |
| `--model <name>` | `qwen2.5:3b` | Ollama model |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file |

### `corpus`

Quine-style compressed corpus container (.qsc) operations.

```bash
zig build cli -- corpus build qstar_corpus.txt qstar_corpus.qsc --page-size 65536
zig build cli -- corpus verify qstar_corpus.qsc
zig build cli -- corpus info qstar_corpus.qsc
zig build cli -- corpus stream qstar_corpus.qsc --limit 10
```

| Subcommand | Description |
|------------|-------------|
| `build <raw.txt> <out.qsc> [--page-size N]` | Build .qsc container (gzip pages + CRC32 + page table) |
| `verify <corpus.qsc>` | Read every page, validate checksums + decompression |
| `info <corpus.qsc>` | Show magic, version, sizes, compression ratio, checksum status |
| `stream <corpus.qsc> [--limit N]` | Stream lines with on-demand page decompression |

The `.qsc` container stores the corpus as gzip-compressed pages with a self-describing header (magic `QSC1`, version, page table). Runtime decompresses pages on demand through an LRU cache, allowing a larger effective corpus within the 500 MB raw `learnFromText` cap. `loadCorpusFromFile` auto-detects `.qsc` containers by magic and streams pages lazily; raw `.txt` files load as before.

### `turing-test`

Run automated Turing test with Ollama judge.

```bash
zig build cli -- turing-test --model qwen2.5:3b --verbose --num-prompts 50
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama judge model |
| `--rounds N` | 1 | Number of test rounds |
| `--num-prompts N` | 50 | Prompts per round |
| `--verbose` | off | Print per-prompt details |
| `--no-reflection` | off | Disable reflection-based generation |
| `--skip-judge` | off | Skip Ollama judging (just generate) |
| `--category <name>` | all | Filter to specific category |
| `--memory` | off | Enable memory callbacks |
| `--memory-file <path>` | `qstar_memory.json` | Memory file |

### `kg`

Knowledge graph operations.

```bash
zig build cli -- kg query "Paris"
zig build cli -- kg add "Paris" "capital_of" "France"
zig build cli -- kg export
```

Subcommands: `query <entity>`, `add <subject> <predicate> <object>`, `export`

### `call`

Execute a tool directly.

```bash
zig build cli -- call calculate '{"op":"add","a":5,"b":3}'
zig build cli -- call lattice_node '{"x":3,"y":3,"z":3}'
```

### `start-heartbeat`

Start background continual learning heartbeat thread.

```bash
zig build cli -- start-heartbeat
```

### `training-heartbeat`

Run the training heartbeat cycle (loads corpus, learns from memory/benchmarks/Turing, saves state). Standalone executable — not a CLI subcommand.

```bash
# Single cycle (no Ollama, no Maple, no compression)
zig build training-heartbeat -- --once --no-maple --no-compress --verbose

# Single cycle with generated prompts (requires Ollama)
zig build training-heartbeat -- --once --gen-prompts --ollama-host 127.0.0.1 --ollama-port 11434 --ollama-model qwen2.5:3b

# Daemon mode (runs every --interval seconds)
zig build training-heartbeat -- --interval 77 --verbose
```

| Flag | Default | Description |
|------|---------|-------------|
| `--once` | off | Run a single cycle and exit (vs daemon mode) |
| `--interval <N>` | 77 | Cycle interval in seconds (daemon mode) |
| `--verbose` | off | Print per-step progress |
| `--no-memory` | off | Skip learning from `qstar_memory.json` |
| `--no-bench` | off | Skip learning from benchmark results |
| `--no-turing` | off | Skip learning from Turing test results |
| `--no-maple` | off | Skip Maple push |
| `--no-compress` | off | Skip corpus compression |
| `--gen-prompts` | off | Generate and learn from Ollama-generated prompts |
| `--gen-count <N>` | 5 | Number of prompts to generate (with `--gen-prompts`) |
| `--ollama-host <host>` | `127.0.0.1` | Ollama host for prompt generation |
| `--ollama-port <port>` | `11434` | Ollama port for prompt generation |
| `--ollama-model <name>` | `qwen2.5:3b` | Ollama model for prompt generation |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file path |

### `experiment`

Run control experiment comparing baseline vs constrained (metacognitive reflection) agent responses.

```bash
zig build cli -- experiment --prompts 5
zig build cli -- experiment --prompts 8 --level 2
```

| Flag | Default | Description |
|------|---------|-------------|
| `--level <N>` | 0 | Lattice level (0-7) |
| `--prompts <N>` | 5 | Number of probe prompts per condition (max 8) |

Generates baseline responses (standard agent) and constrained responses (with metacognitive reflection at confidence_threshold=0.5, reflection_depth=2), evaluates both conditions using 8-dimensional sentience scoring, and reports deltas for self-awareness, direct experience, metacognition, situational awareness, random thought, coherence, and matrix similarity.

---

### `version`

Display version information.

```bash
zig build cli -- version
```

Output: `Qstar v3.5.0 (Pure Zig, Q64.64 Fixed-Point, 421 E0 Nodes, 7 Channels)`

### `competitive-bench`

Run 3-way head-to-head competitive benchmark: Qstar vs Ollama vs OpenAI.

```bash
zig build competitive-bench -- qwen2.5:3b
zig build competitive-bench -- --openai --openai-model gpt-4o --openai-judge
zig build competitive-bench -- --no-ollama --no-openai   # offline smoke (Qstar only)
```

Runs competitive benchmark suite comparing Qstar vs Ollama vs OpenAI vs Maple across categories: factual accuracy, creative fluency, naturalness, reasoning, MMLU (multi-domain knowledge), GSM8K (math reasoning), latency, and throughput. Produces `competitive_results.json` with per-category win/loss/tie breakdown. OpenAI is auto-skipped when no `OPENAI_API_KEY` is present (graceful degradation). Maple is auto-skipped when no Maple host is reachable.

| Argument | Default | Description |
|----------|---------|-------------|
| `<model>` | `qwen2.5:3b` | Ollama model to benchmark against |
| `--no-ollama` | off | Skip Ollama opponent |
| `--no-openai` | off | Skip OpenAI opponent |
| `--no-maple` | off | Skip Maple opponent |
| `--openai-model <name>` | `gpt-4o` | OpenAI opponent model |
| `--openai-judge` | off | Use OpenAI as the response judge (frontier-quality) |
| `--openai-key <key>` | `.env` | OpenAI API key (overrides `OPENAI_API_KEY`) |
| `--fast` | off | Quick run: 10 prompts, no judge, no opponents (Qstar-only speed run) |
| `--judge-host <host>` | `.env` `JUDGE_HOST` | Separate Ollama host for judging (avoids model-swap clashing) |
| `--judge-port <port>` | `.env` `JUDGE_PORT` | Separate Ollama port for judging |
| `--num-prompts <N>` | 0 (all) | Limit number of prompts per category |
| `--seed <N>` | 0 | Random seed for prompt selection |
| `--conversation` | off | Multi-turn conversation mode |
| `--turns <N>` | 3 | Number of conversation turns |

#### Judge Host/Port Separation

When running competitive benchmarks with a local Ollama as both competitor and judge, model-swapping causes significant overhead. Use `--judge-host` and `--judge-port` to direct judge traffic to a separate Ollama instance:

```bash
# Remote Ollama as competitor, local Ollama as judge
zig build competitive-bench -- qwen2.5:3b --judge-host 127.0.0.1 --judge-port 11434

# Fast mode (no judge, no opponents, 10 prompts)
zig build competitive-bench -- --fast --no-ollama
```

---

## HTTP API Endpoints

The server (`zig build cli -- serve`) exposes both Ollama-compatible and OpenAI-compatible endpoints.

### Ollama-Compatible

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/generate` | POST | Generate text from prompt |
| `/api/chat` | POST | Chat completion with messages |
| `/api/tags` | GET | List available models |
| `/api/version` | GET | Server version |
| `/api/embeddings` | POST | Generate embeddings |

### OpenAI-Compatible

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion |
| `/v1/completions` | POST | Text completion |
| `/v1/models` | GET | List models |
| `/v1/embeddings` | POST | Generate embeddings |

### Request Format (Ollama)

```json
{
  "model": "qstar",
  "prompt": "Explain quantum computing",
  "stream": false
}
```

### Request Format (OpenAI)

```json
{
  "model": "qstar",
  "messages": [
    {"role": "user", "content": "Explain quantum computing"}
  ],
  "stream": false
}
```

### Response Format (Ollama)

```json
{
  "model": "qstar",
  "response": "Quantum computing uses quantum mechanical phenomena...",
  "done": true
}
```

### Streaming Response Format

When `"stream": true` is set in the request, the server responds with `Transfer-Encoding: chunked` and `Content-Type: application/x-ndjson`. Each chunk is a newline-delimited JSON object:

```
{"model":"qstar","response":"Quantum","done":false}
{"model":"qstar","response":" computing","done":false}
{"model":"qstar","response":" uses","done":false}
{"model":"qstar","response":"","done":true}
```

---

## Vision API

### `POST /api/vision`

Execute a vision tool with JSON arguments.

**Request:**
```json
{
  "tool": "face_detect",
  "arguments": {
    "scores": [0.9, 0.8],
    "boxes": [10, 20, 100, 120, 30, 40, 130, 150],
    "threshold": 0.5
  }
}
```

**Response:**
```json
{
  "tool": "face_detect",
  "result": {
    "faces": [
      {"x1": 10, "y1": 20, "x2": 100, "y2": 120, "confidence": 0.9}
    ]
  }
}
```

Available tools: `face_detect`, `face_recognize`, `face_analyze`, `face_track`, `gaze_estimate`, `emotion_detect`

### `GET /api/vision/tools`

Returns a list of available vision tools and their parameters.

---

## Geoview API

### `POST /api/geoview`

Execute a geoview tool with JSON arguments.

**Request:**
```json
{
  "tool": "geo_distance",
  "arguments": {
    "lat1": 40.7,
    "lon1": -74.0,
    "lat2": 51.5,
    "lon2": -0.1
  }
}
```

**Response:**
```json
{
  "tool": "geo_distance",
  "result": {
    "distance_m": 5570134.22,
    "distance_km": 5570.13,
    "bearing_deg": 51.21,
    "cardinal": "NE"
  }
}
```

Available tools: `geo_distance`, `geo_convert`, `geo_mgrs`, `geo_bearing`, `geo_destination`, `globe_query`, `track_flight`, `track_vessel`, `track_satellite`, `earthquake_query`, `cctv_query`, `hud_control`, `scene_play`, `annotation_add`

### `GET /api/geoview/tools`

Returns a list of available geoview tools and their parameters.

---

## Vision & Geoview Tool Definitions

### Vision Tools (6)

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `face_detect` | Detects and filters face bounding boxes by confidence threshold | `scores`, `boxes`, `threshold` |
| `face_recognize` | Computes cosine similarity between two face embeddings | `embedding_a`, `embedding_b` |
| `face_analyze` | Analyzes a face region: size ratio, aspect ratio, quality heuristics | `face_width`, `face_height`, `image_width`, `image_height` |
| `face_track` | Tracks faces across frames using IoU matching | `detections`, `previous_tracks` |
| `gaze_estimate` | Estimates gaze direction (pitch, yaw) from facial landmark coordinates | `landmarks` |
| `emotion_detect` | Classifies emotion from 8-class softmax scores | `scores` |

### Geoview Tools (9)

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `globe_query` | Queries the globe for entities within a radius of a point | `lat`, `lon`, `radius_km` |
| `track_flight` | Classifies an aircraft by callsign and computes dead-reckoned position | `callsign`, `lat`, `lon`, `heading`, `speed` |
| `track_vessel` | Classifies a vessel by AIS type code and computes dead-reckoned position | `mmsi`, `lat`, `lon`, `course`, `speed` |
| `track_satellite` | Parses TLE orbital elements for a satellite | `tle_line1`, `tle_line2` |
| `earthquake_query` | Queries earthquakes from USGS or parses provided GeoJSON | `min_magnitude`, `geojson`, `timeframe` |
| `cctv_query` | Calculates CCTV camera viewshed and checks target visibility | `cam_lat`, `cam_lon`, `heading`, `fov`, `target_lat`, `target_lon` |
| `hud_control` | Generates HUD overlay elements (compass, scale bar, coordinates, alerts) | `heading`, `lat`, `lon`, `altitude`, `alert` |
| `scene_play` | Controls the scene director: queue focus targets, storyboard playback | `action`, `lat`, `lon`, `entity_id` |
| `annotation_add` | Adds an annotation (pin or measurement) to the globe | `type`, `lat`, `lon`, `label` |

---

## Geoview CLI

```bash
qstar geoview distance <lat1> <lon1> <lat2> <lon2>  # Great-circle distance + bearing
qstar geoview convert <lat> <lon> [alt]               # LLA → ECEF + MGRS
qstar geoview mgrs <lat> <lon>                        # LLA → MGRS
qstar geoview bearing <lat1> <lon1> <lat2> <lon2>     # Bearing + cardinal direction
qstar geoview destination <lat> <lon> <brng> <dist>   # Destination point
```

---

## Master Node (Quine Autoupdate)

The dev directory is the master node: the authoritative source for any quine
edition (self-contained `universe.html`). CI/CD-gated builds publish payloads
that deployed quines pull automatically over HTTP (primary) and the qstar P2P
mesh (mirror).

### `zig build seed`

Compresses the current Q64.64 agent state into a portable seed file:

```bash
zig build seed
```

Output: `zig-out/seed/qstar_seed.bin`

The seed file contains the holographically-encoded, gzip-compressed, QR-nested
agent state. The full pipeline: Q64.64 state (47 KB) → holographic FFT encode →
gzip compress → QR portal pack. This seed can be embedded in `universe.html`
via `zig build html --seed` or transported via QR portals for collapse scenarios.

### `zig build master`

CI/CD gate: runs the full regression harness (51+ checks), builds WASM + corpus
+ `universe.html`, writes `zig-out/seed_manifest.json`, and publishes all
payloads to `zig-out/master/`:

| Payload | Description |
|---------|-------------|
| `seed_manifest.json` | Version + SHA-256 hashes (corpus, distilled corpus, wasm, html) |
| `universe.html` | Latest quine edition (WASM + distilled corpus embedded) |
| `qstar_corpus.qsc` | Full compressed corpus container |
| `qstar_corpus_distilled.txt` | Distilled text corpus (browser quine autoupdate payload) |
| `qstar_llm.wasm` | WASM binary (capabilities/tools ride in it) |

### `master-serve`

Serves the master publish directory over HTTP for quine autoupdates.

```bash
zig build cli -- master-serve [port] [--dir <path>]
# default port 11436, default dir zig-out/master
```

Routes: `/seed_manifest.json`, `/universe.html`, `/qstar_corpus.qsc`,
`/qstar_corpus_distilled.txt`, `/qstar_llm.wasm`.

### WebRTC signaling + relay (browser P2P mirror bridge)

The master server also brokers browser-to-browser P2P mirroring so quines can
pull updates that exist only in the mesh (HTTP remains the fallback):

| Method | Route | Description |
|--------|-------|-------------|
| `POST` | `/api/signaling/register` | Register this quine as a mirror node: `{"peer_id","payloads":[...]}` → `{"peer_id","peers"}` |
| `GET` | `/api/signaling/peers` | List registered mirror nodes + the payloads they hold |
| `POST` | `/api/signaling/offer` | Queue an SDP offer: `{"from","target","sdp"}` → `{"offer_id"}` (404 if target unknown) |
| `GET` | `/api/signaling/offers?target=X` | Pending SDP offers addressed to peer X |
| `POST` | `/api/signaling/answer` | Queue an SDP answer: `{"offer_id","from","sdp"}` (404 if offer unknown) |
| `GET` | `/api/signaling/answer?offer_id=N` | Fetch the SDP answer for offer N |
| `POST` | `/api/signaling/ice` | Queue an ICE candidate: `{"from","target","candidate"}` |
| `GET` | `/api/signaling/ice?target=X` | Pending ICE candidates for peer X |
| `POST` | `/api/relay/<name>` | Store a payload in the relay cache (store-and-forward mirror) |
| `GET` | `/api/relay/<name>` | Fetch a payload from the relay cache (404 if absent) |

Relay names are sanitized (no `/` or `..`); bodies are capped at
`max_relay_bytes` (default 64 MiB). All state is in-memory and thread-safe
(mutex-guarded, arena-owned for the server lifetime).

### `master publish-p2p`

Publishes the master payloads into the qstar P2P mesh (qstar-net bootstrap +
qstar-vfs distributed storage) and writes `p2p_index.json` — the routing table
quines use to pull payloads from peers.

```bash
zig build cli -- master publish-p2p [--dir <path>]
```

### `dns-update`

Performs a one-shot ClouDNS dynamic DNS update. Sends an HTTPS GET to the
ClouDNS dynamic URL to update the A record for the qstar.mesh domain.

```bash
zig build cli -- dns-update [--url <url>] [--timeout <ms>] [--retries <n>] [--delay <ms>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--url <url>` | ClouDNS default | Dynamic DNS update URL |
| `--timeout <ms>` | 10000 | HTTP timeout in milliseconds |
| `--retries <n>` | 3 | Number of retry attempts |
| `--delay <ms>` | 5000 | Delay between retries in milliseconds |

Configuration can also be set via `.env` file:

| Env Var | Default | Description |
|---------|---------|-------------|
| `DYNAMIC_DNS_URL` | ClouDNS default | Dynamic DNS update URL |
| `DYNAMIC_DNS_TIMEOUT_MS` | 10000 | HTTP timeout |
| `DYNAMIC_DNS_RETRY_COUNT` | 3 | Retry count |
| `DYNAMIC_DNS_RETRY_DELAY_MS` | 5000 | Retry delay |

The `dynamic_dns.zig` module is importable by all qstar.mesh projects
(qstar-net, qstar-mesh, qstar-vfs). Python fallback: `dynamic-url-python.py`
for standalone cron use.

### `master-serve --dyndns`

Pass `--dyndns` to `master-serve` to update the ClouDNS dynamic DNS record on
server startup. Uses the same `.env` configuration as `dns-update`.

```bash
zig build cli -- master-serve --dyndns [port] [--dir <path>]
```

### Quine autoupdate flow

1. `universe.html` embeds `SEED_VERSION`, `SEED_HASH`, `WASM_HASH` at build time.
2. On load, the page fetches `{MASTER_URL}/seed_manifest.json` (same-origin by
   default; override with `QSTAR_MASTER_URL` before the script runs). If the
   direct path fails, it retries `{MASTER_URL}/api/relay/seed_manifest.json`
   to pull a P2P-mirrored manifest.
3. If `wasm_sha256` differs → capabilities/tools changed → pulls the new
   `universe.html` (with relay fallback) and prompts a reload.
4. If `distilled_corpus_sha256` differs → pulls `qstar_corpus_distilled.txt`
   (with relay fallback) and learns from it (hash tracked in `localStorage`).
5. Offline quines degrade gracefully to the embedded corpus.

### Concurrent Serving

The server supports concurrent request handling with a thread-per-connection model. Up to 64 simultaneous connections are supported by default. Shared resources (knowledge graph, tool registry) are protected by mutexes. Each connection gets its own agent instance for isolated lattice state.

---

## Mesh & Transport Commands

### `mesh`

Virtual mesh networking over TCP. Start a mesh node, join an existing network, or inspect topology.

```bash
# Start a virtual mesh node (headless, listens on TCP port 9000)
qstar mesh start [port]

# Join an existing mesh network
qstar mesh join <host:port>

# Show mesh topology, peer count, transport modes
qstar mesh status

# Broadcast message to all connected peers
qstar mesh broadcast <msg>

# Multi-hop relay to specific peer
qstar mesh relay <peer> <msg>
```

### `transport`

Virtual transport layer with 12 modes (p2p, wifi, video, qr, polyglot, audio, stega, paper, optar, paperback, cassette, quine).

```bash
# List available virtual transport modes
qstar transport list

# Send file via specific transport mode
qstar transport send <mode> <file>

# Listen for incoming transport payloads
qstar transport recv
```

### `quine`

Self-contained quine edition builder and publisher.

```bash
# Build self-contained universe.html quine edition
qstar quine build

# Publish quine + payloads to GitHub Pages branch
qstar quine publish
```

### `collapse`

Civilizational collapse simulation and recovery.

```bash
# Simulate civilization collapse (degrade transports to quine + paper + cassette)
qstar collapse simulate

# Show current transport fallback level
qstar collapse status

# Restore all transport modes from collapse
qstar collapse recover
```

---

## Mesh & Transport HTTP API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/mesh/status` | Mesh topology JSON (peers, transport, fallback level) |
| POST | `/api/mesh/join` | Join mesh network (host, port in JSON body) |
| GET | `/api/transport/list` | List available transport modes |
| POST | `/api/transport/send` | Send payload via transport mode (mode, payload in JSON body) |

### GET /api/mesh/status

```bash
curl http://localhost:11435/api/mesh/status
```

```json
{
  "peer_id": "qstar-server",
  "listen_port": 9000,
  "peers": 0,
  "pending": 0,
  "transport": "p2p",
  "fallback_level": 0,
  "collapse_mode": false,
  "channels": [
    {"mode": "p2p", "active": true},
    {"mode": "wifi", "active": true},
    {"mode": "qr", "active": true},
    {"mode": "quine", "active": true},
    {"mode": "paper", "active": true},
    {"mode": "cassette", "active": true}
  ]
}
```

### POST /api/mesh/join

```bash
curl -X POST http://localhost:11435/api/mesh/join \
  -H "Content-Type: application/json" \
  -d '{"host": "192.168.1.50", "port": 9000}'
```

```json
{
  "status": "joined",
  "peer": "192.168.1.50:9000",
  "transport": "p2p",
  "fallback_level": 0
}
```

### GET /api/transport/list

```bash
curl http://localhost:11435/api/transport/list
```

```json
{
  "modes": ["qr", "video", "polyglot", "audio", "paper", "cassette", "wifi", "p2p", "stega", "quine", "optar", "paperback"],
  "selected": "p2p",
  "fallback_level": 0,
  "collapse_mode": false
}
```

### POST /api/transport/send

```bash
curl -X POST http://localhost:11435/api/transport/send \
  -H "Content-Type: application/json" \
  -d '{"mode": "qr", "payload": "SGVsbG8gV29ybGQ="}'
```

```json
{
  "status": "sent",
  "mode": "qr",
  "bytes": 16,
  "delivered": true
}
```
