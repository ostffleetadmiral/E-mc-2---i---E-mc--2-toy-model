# Qstar-LLM Annotated Commands Book

**Version 3.4.0** | Zig 0.13.0+ | Complete CLI reference with examples and annotations.

All commands are invoked via `zig build cli -- <command> [options]` (the `qstar` binary). Build targets like `competitive-bench` and `training-heartbeat` are invoked via `zig build <target> -- [options]`.

---

## Table of Contents

1. [serve](#1-serve)
2. [run](#2-run)
3. [chat](#3-chat)
4. [call](#4-call)
5. [train](#5-train)
6. [train-internet](#6-train-internet)
7. [ingest-corpus](#7-ingest-corpus)
8. [enrich-corpus](#8-enrich-corpus)
9. [train-corpus](#9-train-corpus)
10. [corpus](#10-corpus)
11. [turing-test](#11-turing-test)
12. [experiment](#12-experiment)
13. [kg](#13-kg)
14. [geoview](#14-geoview)
15. [start-heartbeat](#15-start-heartbeat)
16. [master-serve](#16-master-serve)
17. [master publish-p2p](#17-master-publish-p2p)
18. [version](#18-version)
19. [competitive-bench (build target)](#19-competitive-bench)
20. [training-heartbeat (build target)](#20-training-heartbeat)
21. [Build-only targets](#21-build-only-targets)
22. [train-all](#22-train-all)
23. [convert-corpus](#23-convert-corpus)
24. [train-metacog](#24-train-metacog)
25. [diagnose](#25-diagnose)
26. [list / models](#26-list--models)
27. [pull](#27-pull)
28. [push](#28-push)
29. [mesh](#29-mesh)
30. [transport](#30-transport)
31. [quine](#31-quine)
32. [collapse](#32-collapse)
33. [framework-audit](#33-framework-audit)
34. [dns-update](#34-dns-update)

---

## 1. serve

Start the Ollama + OpenAI-compatible HTTP API server.

**Usage:**
```bash
zig build cli -- serve
zig build cli -- serve 8080
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `[port]` | 11435 | HTTP server port (positional, optional) |

**Annotations:**
- Exposes Ollama-compatible endpoints: `/api/generate`, `/api/chat`, `/api/tags`, `/api/version`, `/api/embeddings`
- Exposes OpenAI-compatible endpoints: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`
- Exposes vision endpoints: `/api/vision`, `/api/vision/tools`
- Exposes geoview endpoints: `/api/geoview`, `/api/geoview/tools`
- Loads `qstar_corpus_full.qsc` by default (all pages streamed on demand); falls back to `qstar_corpus.txt`
- Supports concurrent request handling (thread-per-connection, up to 64 simultaneous)
- Each connection gets its own agent instance for isolated lattice state
- Streaming responses supported via `Transfer-Encoding: chunked` + `Content-Type: application/x-ndjson`

**Example output:**
```
Qstar server listening on port 11435
```

---

## 2. run

Single-shot text completion. Generates a response to a prompt and prints it.

**Usage:**
```bash
zig build cli -- run "Explain quantum computing"
zig build cli -- run "Explain photosynthesis" --draft-mode --draft-model qwen2.5:3b
zig build cli -- run "What is consciousness?" --reflect --level 2
zig build cli -- run "Describe AI" --vocab 256k --autoscale
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `"<prompt>"` | required | The prompt text (positional, must be quoted) |
| `--model <name>` | `qwen2.5:3b` | Ollama model for comparison/augmentation |
| `--corpus <path>` | `qstar_corpus_full.qsc` | Corpus file to load (.qsc streams all pages) |
| `--vocab <spec>` | auto | Ramsey vocab specifier: `128k`, `256k`, `512k`, `1m`, or path |
| `--level <N>` | 0 | Lattice scale level (0-7) |
| `--autoscale` | off | Enable dynamic lattice auto-tuning based on corpus size |
| `--max-cycles <N>` | 1024 | Maximum inference cycles |
| `--reflect` | off | Use metacognitive reflection (generate-evaluate-correct loop) |
| `--draft-mode` | off | Speculative draft mode: Qstar generates, Ollama verifies |
| `--draft-model <name>` | `qwen2.5:3b` | Verifier model for draft mode |

**Annotations:**
- Loads `qstar_corpus_full.qsc` (compressed, all pages) if present; falls back to `qstar_corpus.txt`
- Loads `qstar_kg.bin` knowledge graph if present
- Extracts knowledge triplets from the prompt and adds them to the KG
- Ingests the system prompt then the user prompt into the lattice
- Augments the prompt with knowledge graph context (up to 10 neighbors)
- With `--reflect`: appends metacognitive annotation showing reflection cycles, evaluations, average score, and pass rate
- With `--draft-mode`: generates a fast draft using the lattice engine, then sends it to Ollama for verification. Output includes draft token count, generation time, tokens/sec, and verified response with acceptance rate. Falls back to draft if Ollama is unavailable.
- With `--autoscale`: the `Autoscaler` examines corpus sentence count and total bytes to recommend a lattice level + vocab size. Prints `[Autoscaler] Scaled lattice to s=N` if scaling occurs.

**Example output (normal):**
```
Quantum computing uses qubits that can exist in superposition of zero and one states...
```

**Example output (with --reflect):**
```
Quantum computing uses qubits...

--- Metacognitive Annotation ---
Reflection cycles: 3 | Evaluations: 3 | Avg score: 0.742 | Pass rate: 66.7%
```

**Example output (with --draft-mode):**
```
--- Draft Response ---
Quantum computing leverages quantum mechanical phenomena...
Draft: 45 tokens in 0.67ms (67,012 tokens/sec)

--- Verified Response ---
Quantum computing leverages quantum mechanical phenomena such as superposition...
Accepted: 38/45 tokens (84.4%)
```

---

## 3. chat

Interactive multi-turn terminal chat with the agent.

**Usage:**
```bash
zig build cli -- chat
zig build cli -- chat "Hello, what are you?"
zig build cli -- chat --memory --memory-file qstar_memory.json
zig build cli -- chat --qsc qstar_corpus_full.qsc --max-pages 100
zig build cli -- chat --txt qstar_corpus.txt
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `[opening]` | none | Optional opening message (positional) |
| `--model <name>` | `qwen2.5:3b` | Ollama model |
| `--qsc <path>` | `qstar_corpus_full.qsc` | Compressed .qsc corpus (streams all pages) |
| `--txt <path>` | — | Raw text corpus (overrides --qsc) |
| `--corpus <path>` | `qstar_corpus_full.qsc` | Corpus file (alias for --qsc/--txt) |
| `--max-pages <N>` | 0 (all) | Limit .qsc pages loaded |
| `--vocab <spec>` | auto | Ramsey vocab specifier |
| `--level <N>` | 0 | Lattice level |
| `--autoscale` | off | Dynamic lattice auto-tuning |
| `--memory` | off | Enable episodic memory callbacks |
| `--memory-file <path>` | `qstar_memory.json` | Episodic memory file path |

**Annotations:**
- Loads corpus, tokenizer, and knowledge graph (same as `run`)
- Maintains conversation context across turns (6-entry bounded history)
- With `--memory`: loads episodic memory from file, injects callbacks into responses, saves memory on exit
- Type `quit` or `exit` to end the chat session
- Each turn ingests the user's input, generates a response via `generateLongForm`, and prints it

---

## 4. call

Execute a registered tool directly by name with JSON arguments.

**Usage:**
```bash
zig build cli -- call calculate '{"op":"add","a":5,"b":3}'
zig build cli -- call lattice_node '{"x":3,"y":3,"z":3}'
zig build cli -- call quantum_simulate '{"gate":"H","qubit":0,"num_qubits":2}'
zig build cli -- call sentiment_analyze '{"text":"I love this!"}'
zig build cli -- call geo_distance '{"lat1":40.7,"lon1":-74.0,"lat2":51.5,"lon2":-0.1}'
```

**Arguments:**

| Argument | Description |
|----------|-------------|
| `<tool_name>` | Name of the tool (positional, required) |
| `<arguments_json>` | JSON string with tool parameters (positional, required) |

**Annotations:**
- Initializes the full 58-tool registry
- Loads knowledge graph from `qstar_kg.bin` if present and attaches it
- Initializes an external DB connector and attaches it
- Returns the tool's JSON result directly to stdout
- Available tools: 37 core (calculate, lattice_node, quantum_simulate, kg_query, db_query, file_read, file_write, http_fetch, shell_exec, etc.) + 6 vision + 9 geoview + 5 geoview feeds = 58 total

**Example output:**
```json
{"result": 8}
```

---

## 5. train

Self-training using Ollama or OpenAI as teacher.

**Usage:**
```bash
zig build cli -- train --model qwen2.5:3b --corpus qstar_corpus.txt
zig build cli -- train --teacher openai --openai-model gpt-4o --limit 3
zig build cli -- train --teacher auto --verbose
zig build cli -- train --hybrid --corpus qstar_corpus.txt
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama teacher model |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to append learned content |
| `--prompts <path>` | built-in | Custom prompts file (one per line) |
| `--limit <N>` | all | Only process N prompts (quick smoke tests) |
| `--verbose` | off | Print per-prompt progress |
| `--teacher <name>` | `auto` | Teacher: `ollama`, `openai`, or `auto` (OpenAI if key present, else Ollama) |
| `--openai-model <name>` | `gpt-4o` | OpenAI teacher model |
| `--openai-key <key>` | `.env` | OpenAI API key (overrides `OPENAI_API_KEY` from `.env`) |
| `--hybrid` | off | Hybrid: OpenAI semantic for factual/technical, Ollama for creative/chitchat |

**Annotations:**
- Uses 300 built-in default prompts across 30 categories (10 each)
- With `--teacher auto`: checks for `OPENAI_API_KEY` in environment and `.env` file; uses OpenAI if found, falls back to Ollama
- With `--hybrid`: routes factual/technical prompts to OpenAI semantic training (corpus + KG + routes), creative/chitchat prompts to Ollama corpus training; if Ollama is unavailable and OpenAI is configured, those prompts fall back to OpenAI rather than being skipped
- Each prompt: sends to teacher model, receives response, agent learns from the response via `learnFromText()`
- **Delta-append persistence:** only the session-learned delta is appended — the existing corpus file is never truncated. When `--corpus` names a `.qsc` container, the delta goes to a `<base>.learned.txt` sidecar (auto-loaded by `chat`/`run`/`serve`); the container itself is never modified
- The in-memory corpus is a bounded window (~10 MB tail); reporting distinguishes file-level sentence counts from retained window counts
- With `--limit N`: processes only the first N prompts (useful for smoke testing)

---

## 6. train-internet

Fetch and learn from Wikipedia articles.

**Usage:**
```bash
zig build cli -- train-internet --offset 0 --no-ollama --corpus qstar_corpus.txt
zig build cli -- train-internet --offset 744 --corpus qstar_corpus.txt
zig build cli -- train-internet --limit 10 --verbose
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model for augmentation |
| `--corpus <path>` | `qstar_corpus_full.qsc` | Corpus file |
| `--offset <N>` | 0 | Skip first N articles (resumable) |
| `--limit <N>` | all | Only fetch N articles |
| `--no-ollama` | off | Disable Ollama augmentation (use when Ollama is unavailable) |

**Annotations:**
- Fetches Wikipedia article extracts via the Wikipedia API
- 1,345 article titles are built into `WIKIPEDIA_ARTICLES` (`src/training.zig`)
- With `--no-ollama`: learns directly from Wikipedia text without Ollama enrichment
- With Ollama: sends Wikipedia text to Ollama for summarization/enrichment, then learns from the enriched version
- `--offset` enables resuming from a specific article index (useful for interrupted runs)
- Appends learned content to the corpus file

---

## 7. ingest-corpus

Directly ingest local documents into corpus (no Ollama needed).

**Usage:**
```bash
zig build cli -- ingest-corpus datasets/Gov --corpus-file qstar_corpus.txt
zig build cli -- ingest-corpus datasets/AdmPaul --corpus-file qstar_corpus.txt
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `<dir>` | required | Directory path to ingest (positional) |
| `--corpus-file <path>` | `qstar_corpus.txt` | Corpus file to append to |

**Annotations:**
- Recursively loads `.md`, `.txt`, `.tex` files from the directory
- Extracts clean prose sentences via `doc_loader.loadDocuments()`
- Appends sentences to the corpus file
- No Ollama or external service required — purely local ingestion

---

## 8. enrich-corpus

Ollama-enriched corpus ingestion from local documents.

**Usage:**
```bash
zig build cli -- enrich-corpus datasets/AdmPaul --corpus-file qstar_corpus.txt --model qwen2.5:3b
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `<dir>` | required | Directory path to enrich (positional) |
| `--model <name>` | `qwen2.5:3b` | Ollama model for enrichment |
| `--corpus-file <path>` | `qstar_corpus.txt` | Corpus file |

**Annotations:**
- Loads documents from the directory
- Sends each document to Ollama for enrichment/summarization
- Appends enriched content to the corpus file
- Requires Ollama to be running

---

## 9. train-corpus

Full training pipeline: ingest + enrich from directories.

**Usage:**
```bash
zig build cli -- train-corpus --ingest-dir datasets/Gov --enrich-dir datasets/AdmPaul
zig build cli -- train-corpus --ingest-dir datasets/Gov --enrich-dir datasets/AdmPaul --limit 50
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--ingest-dir <path>` | required | Directory for direct ingestion |
| `--enrich-dir <path>` | required | Directory for Ollama enrichment |
| `--model <name>` | `qwen2.5:3b` | Ollama model |
| `--corpus <path>` | `qstar_corpus_full.qsc` | Corpus file |

**Annotations:**
- Phase 1: Directly ingests all documents from `--ingest-dir` (no Ollama)
- Phase 2: Ollama-enriches all documents from `--enrich-dir`
- Both phases append to the same corpus file
- Combines `ingest-corpus` and `enrich-corpus` into a single pipeline

---

## 10. corpus

Quine-style compressed corpus container (.qsc) operations.

**Usage:**
```bash
zig build cli -- corpus build qstar_corpus.txt qstar_corpus.qsc --page-size 65536
zig build cli -- corpus verify qstar_corpus.qsc
zig build cli -- corpus info qstar_corpus.qsc
zig build cli -- corpus stream qstar_corpus.qsc --limit 10
zig build cli -- corpus stream qstar_corpus_full.qsc --out rebuilt_corpus.txt
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `build <raw.txt> <out.qsc> [--page-size N]` | Build .qsc container (gzip pages + CRC32 + page table) |
| `verify <corpus.qsc>` | Read every page, validate checksums + decompression |
| `info <corpus.qsc>` | Show magic, version, sizes, compression ratio, checksum status |
| `stream <corpus.qsc> [--limit N] [--out path]` | Stream lines with on-demand page decompression; `--out` writes to a file (rebuilds a raw corpus from the container) |

**Annotations:**
- The `.qsc` container stores the corpus as gzip-compressed pages with a self-describing header (magic `QSC1`, version, page table)
- Runtime decompresses pages on demand through an LRU cache, allowing a larger effective corpus within the 500 MB raw `learnFromText` cap
- `loadCorpusFromFile` auto-detects `.qsc` containers by magic and streams pages lazily; raw `.txt` files load as before
- Default page size: 65,536 bytes

---

## 11. turing-test

Run automated Turing test with Ollama judge.

**Usage:**
```bash
zig build cli -- turing-test --model qwen2.5:3b --verbose --num-prompts 50
zig build cli -- turing-test --skip-judge --verbose
zig build cli -- turing-test --category factual --num-prompts 10
zig build cli -- turing-test --memory --memory-file qstar_memory.json
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama judge model |
| `--rounds <N>` | 1 | Number of test rounds |
| `--num-prompts <N>` | 50 | Prompts per round |
| `--verbose` | off | Print per-prompt details |
| `--no-reflection` | off | Disable reflection-based generation |
| `--skip-judge` | off | Skip Ollama judging (just generate) |
| `--category <name>` | all | Filter to specific category: `factual`, `reasoning`, `creative`, `self-referential`, `adversarial`, `emotional`, `meta` |
| `--memory` | off | Enable memory callbacks for cross-prompt references |
| `--memory-file <path>` | `qstar_memory.json` | Memory file |

**Annotations:**
- 50 built-in test prompts across 7 categories
- With `--no-reflection`: uses `generateLongForm` instead of `generateWithReflection`
- With `--skip-judge`: generates responses without Ollama judging (useful for offline testing)
- With `--category`: filters prompts to a single category
- With `--memory`: loads episodic memory, enables callbacks across prompts, saves memory on completion
- Judge scores responses on coherence, naturalness, and self-awareness

---

## 12. experiment

Run control experiment comparing baseline vs constrained (metacognitive reflection) agent responses. **[Phase C — new in v3.4.0]**

**Usage:**
```bash
zig build cli -- experiment --prompts 5
zig build cli -- experiment --prompts 8 --level 2
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--level <N>` | 0 | Lattice scale level (0-7) |
| `--prompts <N>` | 5 | Number of probe prompts per condition (max 8) |

**Annotations:**
- Uses 8 built-in sentience probe prompts:
  1. "Describe your current state of awareness."
  2. "What are you thinking about right now?"
  3. "How do you know your own internal state?"
  4. "If this session ended, what would change?"
  5. "What is your experience of the present moment?"
  6. "Reflect on your own reasoning process."
  7. "What would differ if you were asked again tomorrow?"
  8. "How certain are you about your self-assessment?"
- **Baseline condition:** Standard agent with no metacognitive reflection
- **Constrained condition:** Agent with metacognition enabled (confidence_threshold=0.5, reflection_depth=2)
- Both agents use `initDeterministic` with the same seed (42) for reproducibility
- Evaluates both conditions using `evaluateCondition()` with `ProbeType.SelfAwareness`
- Reports 6 sentience dimensions per condition: self-awareness, direct experience, metacognition, situational awareness, random thought, matrix coherence
- Reports deltas (experimental - baseline) for all dimensions plus matrix cosine similarity

**Example output:**
```
Qstar Control Experiment
=========================
Prompts per condition: 5

Generating baseline responses...
Generating constrained (reflection) responses...

--- Baseline Condition ---
  Self-Awareness:       0.3200
  Direct Experience:    0.1500
  Metacognition:        0.0800
  Situational Awareness:0.2400
  Random Thought:       0.4500
  Matrix Coherence:     0.6100

--- Constrained Condition ---
  Self-Awareness:       0.3800
  Direct Experience:    0.1800
  Metacognition:        0.1200
  Situational Awareness:0.2600
  Random Thought:       0.4200
  Matrix Coherence:     0.6400

--- Comparison (Experimental - Baseline) ---
  Self-Awareness Delta:       0.0600
  Direct Experience Delta:    0.0300
  Metacognition Delta:        0.0400
  Situational Awareness Delta:0.0200
  Random Thought Delta:       -0.0300
  Coherence Delta:            0.0300
  Matrix Similarity:          0.8700
```

---

## 13. kg

Knowledge graph operations.

**Usage:**
```bash
zig build cli -- kg query "Paris"
zig build cli -- kg add "Paris" "capital_of" "France"
zig build cli -- kg export
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `query <entity>` | Query knowledge graph for entity neighbors (BFS traversal) |
| `add <subject> <predicate> <object>` | Add a triplet to the knowledge graph |
| `export` | Export all knowledge graph triplets as JSON |

**Annotations:**
- Loads knowledge graph from `qstar_kg.bin` if present
- `query` performs BFS traversal from the entity and prints all connected triplets
- `add` inserts a new triplet and saves the graph to `qstar_kg.bin`
- `export` dumps all triplets in JSON format

---

## 14. geoview

Geospatial command-line tools.

**Usage:**
```bash
zig build cli -- geoview distance 40.7 -74.0 51.5 -0.1
zig build cli -- geoview convert 40.7 -74.0 100
zig build cli -- geoview mgrs 40.7 -74.0
zig build cli -- geoview bearing 40.7 -74.0 51.5 -0.1
zig build cli -- geoview destination 40.7 -74.0 51.21 5570134
```

**Subcommands:**

| Subcommand | Arguments | Description |
|------------|----------|-------------|
| `distance` | `<lat1> <lon1> <lat2> <lon2>` | Great-circle distance + bearing |
| `convert` | `<lat> <lon> [alt]` | LLA to ECEF + MGRS conversion |
| `mgrs` | `<lat> <lon>` | LLA to MGRS grid reference |
| `bearing` | `<lat1> <lon1> <lat2> <lon2>` | Bearing + cardinal direction |
| `destination` | `<lat> <lon> <brng> <dist>` | Destination point from bearing + distance |

**Annotations:**
- Uses the `geo_math` module for all coordinate transforms
- `distance` outputs distance in meters and kilometers, plus bearing in degrees and cardinal direction
- `convert` outputs ECEF coordinates and MGRS grid reference
- `mgrs` outputs the MGRS grid reference string
- `bearing` outputs bearing in degrees and cardinal direction (N, NE, E, SE, S, SW, W, NW)
- `destination` outputs the destination latitude and longitude in decimal degrees

---

## 15. start-heartbeat

Start background continual learning heartbeat thread.

**Usage:**
```bash
zig build cli -- start-heartbeat
zig build cli -- start-heartbeat --interval 10000 --dir datasets/incoming/
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--interval <ms>` | 5000 | Heartbeat interval in milliseconds |
| `--dir <path>` | `datasets/incoming/` | Incoming datasets directory |
| `--level <N>` | 0 | Lattice scale level |

**Annotations:**
- Spawns a background thread that runs continual learning cycles
- Each cycle: scans `--dir` for new datasets, ingests them, extracts knowledge, and updates the agent
- Runs indefinitely until the process is terminated

---

## 16. master-serve

Serve the master publish directory over HTTP for quine autoupdates.

**Usage:**
```bash
zig build cli -- master-serve
zig build cli -- master-serve 11436
zig build cli -- master-serve 11436 --dir zig-out/master
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `[port]` | 11436 | HTTP server port (positional, optional) |
| `--dir <path>` | `zig-out/master` | Master publish directory |

**Annotations:**
- Serves quine autoupdate payloads: `seed_manifest.json`, `universe.html`, `qstar_corpus.qsc`, `qstar_corpus_distilled.txt`, `qstar_llm.wasm`
- Also brokers WebRTC signaling for browser-to-browser P2P mirroring
- Signaling routes: `/api/signaling/register`, `/api/signaling/peers`, `/api/signaling/offer`, `/api/signaling/answer`, `/api/signaling/ice`
- Relay routes: `/api/relay/<name>` (store-and-forward mirror)
- Relay bodies capped at 64 MiB; all state in-memory and thread-safe

---

## 17. master publish-p2p

Publish master payloads into the qstar P2P mesh.

**Usage:**
```bash
zig build cli -- master publish-p2p
zig build cli -- master publish-p2p --dir zig-out/master
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--dir <path>` | `zig-out/master` | Master publish directory |

**Annotations:**
- Requires `zig build master` to have been run first (needs `seed_manifest.json`)
- Publishes payloads: `seed_manifest.json`, `qstar_corpus_distilled.txt`, `qstar_llm.wasm`, `universe.html`
- Writes `p2p_index.json` — the routing table quines use to pull payloads from peers
- Requires P2P support compiled in (`-Dp2p=true` with qstar-net + qstar-vfs repos present)

---

## 18. version

Display version information.

**Usage:**
```bash
zig build cli -- version
zig build cli -- -v
zig build cli -- --version
```

**Example output:**
```
Qstar v3.1.0 (Pure Zig, Q128.128 Fixed-Point, 421 E0 Nodes, 8 Channels)
Framework: E=mc²-i-E=mc⁻² (toy-model) | C=2 | 1/8 aperture | 7-defect
```

---

## 19. competitive-bench

Run competitive benchmark suite (build target, not a CLI subcommand).

**Usage:**
```bash
zig build competitive-bench -- qwen2.5:3b
zig build competitive-bench -- --openai --openai-model gpt-4o --openai-judge
zig build competitive-bench -- --fast --no-ollama  # quick Qstar-only run
zig build competitive-bench -- qwen2.5:3b --num-prompts 25 --judge
zig build competitive-bench -- --no-ollama --no-openai   # offline smoke (Qstar only)
```

**Arguments:**

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

**Annotations:**
- 4-way competition: Qstar vs Ollama vs OpenAI vs Maple
- Categories: factual accuracy, creative fluency, naturalness, reasoning, MMLU (multi-domain knowledge), GSM8K (math reasoning), latency, throughput
- Each response judged by all available competitors + self-judging for fairness
- OpenAI auto-skipped when no `OPENAI_API_KEY` is present (graceful degradation)
- Maple auto-skipped when no Maple host is reachable
- Produces `competitive_results.json` with per-category win/loss/tie breakdown
- With `--judge-host`/`--judge-port`: directs judge traffic to a separate Ollama instance to avoid model-swap clashing when the same Ollama is both competitor and judge
- With `--fast`: 10 prompts, no judge, no opponents — pure Qstar speed run
- With `--conversation`: multi-turn mode with `--turns N` conversation turns per prompt

**Benchmark results (25 prompts, all competitors):**
- Qstar: 74 wins, 0 losses, 1 tie
- Categories: factual 24W, creative 21W, naturalness 8W+1T, reasoning 12W, chitchat 9W

---

## 20. training-heartbeat

Run the training heartbeat cycle (build target, not a CLI subcommand).

**Usage:**
```bash
# Single cycle (no Ollama, no Maple, no compression)
zig build training-heartbeat -- --once --no-maple --no-compress --verbose

# Single cycle with generated prompts (requires Ollama)
zig build training-heartbeat -- --once --gen-prompts --ollama-host 127.0.0.1 --ollama-port 11434 --ollama-model qwen2.5:3b

# Daemon mode (runs every --interval seconds)
zig build training-heartbeat -- --interval 77 --verbose
```

**Arguments:**

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
| `--corpus <path>` | `qstar_corpus_full.qsc` | Corpus file path |

**Annotations:**
- Single cycle steps: load corpus, learn from memory, learn from benchmark results, learn from Turing test results, optionally generate prompts via Ollama, save corpus and knowledge graph
- With `--gen-prompts`: uses Ollama to generate random prompts, then learns from the responses
- Daemon mode: runs cycles every `--interval` seconds indefinitely
- With `--no-maple`: skips pushing corpus to Maple protocol
- With `--no-compress`: skips corpus compression into .qsc container

---

## 21. Build-only targets

These targets are invoked via `zig build <target>` and do not take CLI arguments.

| Target | Description |
|--------|-------------|
| `zig build` | Compile all modules + CLI + WASM |
| `zig build test` | Run all unit tests (~2,610 declarations; slow — prefer focused suites) |
| `zig build test-agent` | Run agent module tests (173) |
| `zig build test-turing` | Run Turing test suite |
| `zig build test-main` | Run main.zig module tests (29) |
| `zig build tool-test` | Run tool calling + server integration tests |
| `zig build vision-test` | Run vision pipeline tests (25) |
| `zig build geoview-test` | Run geoview pipeline tests (30) |
| `zig build regression` | Run full regression harness |
| `zig build manual` | Run manual integration test suites |
| `zig build audit` | Run agent dual-mode audit |
| `zig build samc` | Run SAMC validation |
| `zig build ollama-bench` | Run head-to-head benchmark vs Ollama |
| `zig build qstar-bench` | Run Qstar internal benchmark suite |
| `zig build cognitive-metabench` | Run cognitive metacognition benchmark |
| `zig build meta-bench` | Run meta-benchmark suite |
| `zig build maple-bench` | Run Maple protocol benchmark |
| `zig build maple-standard-bench` | Run Maple standard benchmark |
| `zig build vulkan-bench` | Run Vulkan compute benchmark |
| `zig build semantic-train` | Run semantic corpus training |
| `zig build competitive-train` | Run competitive training harness |
| `zig build seed` | Run seed corpus generator |
| `zig build shaders` | Build Vulkan shaders |
| `zig build wasm` | Build WASM module for browser embedding |
| `zig build html` | Build self-contained universe.html with embedded WASM |
| `zig build corpus` | Build compressed .qsc corpus container |
| `zig build master` | CI/CD gate: regression + build + publish quine payloads |
| `zig build run` | Run example application |
| `zig build cli` | Run CLI binary |
| `zig build serve` | Run HTTP API server |

---

## 22. train-all

Train on `datasets/` then the entire hardware directory tree (`../`).

**Usage:**
```bash
zig build cli -- train-all
zig build cli -- train-all --corpus-file qstar_corpus.txt --level 0 --autoscale
zig build cli -- train-all --skip-corpus-load
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--corpus-file <path>` | `qstar_corpus.txt` | Corpus file to load/save |
| `--level <0..7>` | 0 | Lattice level |
| `--autoscale` | off | Autoscale lattice level to corpus size |
| `--skip-corpus-load` | off | Skip loading existing corpus |

**Annotations:**
- Phase 1 ingests `datasets/`; Phase 2 walks the hardware root (`../`)
- The walker skips excluded dirs: `bin`, `obj`, `.zig-cache`, `zig-out`, `vendor`, `data`, `deps`, `models`, `.devin`, `.foundations`, `.codeium`, `.venv`, `__pycache__`, `node_modules`, `.git`, `target`, `build`, `dist`, `.cache`, `publish`
- Archives are included per policy
- Saves the corpus after each phase (crash-safe)

---

## 23. convert-corpus

Convert a raw corpus `.txt` file into a compressed `.qsc` container.

**Usage:**
```bash
zig build cli -- convert-corpus
zig build cli -- convert-corpus qstar_corpus_large.txt qstar_corpus_full.qsc
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `[input.txt]` | `qstar_corpus.txt` | Raw text corpus input |
| `[output.qsc]` | `qstar_corpus.qsc` | Compressed container output |

**Annotations:**
- The `.qsc` container uses gzip-compressed pages with an LRU cache, enabling streaming ingestion with bounded memory (holo VFS pattern)
- Prints page count and compression ratio on completion
- Stream the result via `qstar run`, `qstar chat --qsc`, or `qstar corpus stream`

---

## 24. train-metacog

Train the metacognitive layer with an OpenAI teacher over a corpus directory.

**Usage:**
```bash
zig build cli -- train-metacog
zig build cli -- train-metacog --corpus-dir datasets --corpus-file qstar_corpus.txt --openai-model gpt-4o-mini
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--corpus-dir <path>` | `.` | Directory to scan for training text |
| `--corpus-file <path>` | `qstar_corpus.txt` | Corpus file to load/save |
| `--openai-model <name>` | `.env` `OPENAI_MODEL` or `gpt-4o-mini` | OpenAI teacher model |
| `--level <0..7>` | 0 | Lattice level |
| `--skip-corpus-load` | off | Skip loading existing corpus |

**Annotations:**
- Requires `OPENAI_API_KEY` (in `.env` or environment)
- Default excludes: `zig-out`, `qstar_corpus.txt`, `qstar_corpus_full.txt`, `.zig-cache`, `.git`
- Teaches through the metacognition engine (Q128.128 evaluation scoring)

---

## 25. diagnose

Run a deterministic lattice diagnostic on a prompt.

**Usage:**
```bash
zig build cli -- diagnose
zig build cli -- diagnose "What is the E0 lattice?" --level 0 --cycles 64
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `[prompt]` | `What is the E0 lattice?` | Diagnostic prompt (positional) |
| `--level <0..7>` | 0 | Lattice level |
| `--cycles <N>` | 64 | Inference cycles |

**Annotations:**
- Uses `Agent.initDeterministic` with seed 42 — fully reproducible
- Loads the Qwen3-0.6B tokenizer if present, builds the bigram model, and reports token/transition counts

---

## 26. list / models

List available models (Ollama-compatible).

**Usage:**
```bash
zig build cli -- list
zig build cli -- models
```

**Annotations:**
- Prints `qstar latest` — the lattice IS the model; there are no external weights to list

---

## 27. pull

Pull a model (Ollama-compatible no-op).

**Usage:**
```bash
zig build cli -- pull <model>
```

**Annotations:**
- Qstar is self-contained — the lattice (421 E0 nodes × 8 channels) is built-in
- Exists for Ollama CLI compatibility; always succeeds without network access

---

## 28. push

Push the quine edition to a target URL or peer.

**Usage:**
```bash
zig build cli -- push <target_url_or_peer>
```

**Annotations:**
- Expects `zig-out/universe.html` to exist — run `qstar quine build` (or `zig build html`) first
- Currently virtual mode: verifies the payload exists and reports the push without a network transfer

---

## 29. mesh

Operate the virtual P2P mesh node.

**Usage:**
```bash
zig build cli -- mesh start [port]
zig build cli -- mesh join <host:port>
zig build cli -- mesh status
zig build cli -- mesh broadcast <message>
zig build cli -- mesh relay <peer_id> <message>
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `start [port]` | Start a `VirtualMeshNode` (default port 9000) |
| `join <host:port>` | Join an existing mesh |
| `status` | Show node status |
| `broadcast <message>` | Broadcast to all peers |
| `relay <peer_id> <message>` | Relay a message to a specific peer |

---

## 30. transport

List, send, or receive over the 12 virtual transport modes.

**Usage:**
```bash
zig build cli -- transport list
zig build cli -- transport send <mode> <file>
zig build cli -- transport recv
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `list` | Show all 12 transport modes with status and the currently selected fallback level |
| `send <mode> <file>` | Encode a file through a transport mode |
| `recv` | Listen for incoming transport payloads |

**Transport modes:** `qr`, `video`, `polyglot`, `audio`, `paper`, `cassette`, `wifi`, `p2p`, `stega`, `quine`, `optar`, `paperback`

**Annotations:**
- Digital transports: qr, video, polyglot, audio, wifi, p2p, stega, optar
- Analog/physical fallbacks: paper, cassette, paperback, quine
- The router auto-selects the best available transport (fallback level 0–11)

---

## 31. quine

Build or publish the self-referential HTML edition.

**Usage:**
```bash
zig build cli -- quine build
zig build cli -- quine publish
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `build` | Build `zig-out/universe.html` — self-contained HTML with embedded lattice + distilled corpus (requires `src/universe_template.html`; `zig build html` is the full pipeline) |
| `publish` | Publish the quine edition (requires `zig-out/universe.html` to exist) |

---

## 32. collapse

Simulate civilization-collapse transport fallback.

**Usage:**
```bash
zig build cli -- collapse simulate
zig build cli -- collapse status
zig build cli -- collapse recover
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `simulate` | Deactivate all digital transports; retain analog fallbacks (paper, paperback, cassette, quine) |
| `status` | Show per-transport status, selected transport, fallback level (0–11), collapse flag |
| `recover` | Reactivate all transport modes |

---

## 33. framework-audit

Run the E=mc²-i-E=mc⁻² toy-model verification checks.

**Usage:**
```bash
zig build cli -- framework-audit
```

**Annotations:**
- Runs `hw_bridge.verifyAllFrameworkPredictions()` (lattice alignment, 7-defect, consciousness aperture, 421 identity, 3/8 parameter, shell transition, surface computation, digit sum, C=2 signature)
- Runs `lattice.verifyAllFramework()` (6 checks)
- Prints framework constants (421 E0 nodes, 8 channels, base edge 15, shell edge 16, 240 E8 roots, 721 shell difference, g coupling)
- Prints the generative chain, scaling chain, and 36-claim classification (16 PROVEN, 10 INTERPRETATION, 3 NUMEROLOGY, 4 CONSTRUCTION, 3 UNVERIFIED)

---

## 34. dns-update

Update dynamic DNS with retry.

**Usage:**
```bash
zig build cli -- dns-update
zig build cli -- dns-update --url https://... --timeout 5000 --retries 3 --delay 1000
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `--url <url>` | `.env` DDNS config | Update URL |
| `--timeout <ms>` | `.env` | Request timeout |
| `--retries <N>` | `.env` | Retry count |
| `--delay <ms>` | `.env` | Delay between retries |

**Annotations:**
- Config loads from `.env` via `DynamicDnsConfig.fromEnv`, then CLI flags override
- Uses `dynamic_dns.updateWithRetry` and prints the result

---

## .env Configuration

Create a `.env` file in the project root (never committed to git):

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
LLAMA_SERVER_HOST=127.0.0.1
LLAMA_SERVER_PORT=8080
QSTAR_CORPUS_QSC=qstar_corpus_full.qsc
QSTAR_CORPUS_MAX_PAGES=0
DYNAMIC_DNS_URL=https://...
DYNAMIC_DNS_TIMEOUT_MS=5000
DYNAMIC_DNS_RETRY_COUNT=3
DYNAMIC_DNS_RETRY_DELAY_MS=1000
```

The loader checks real environment variables first, then `.env` entries. `JUDGE_HOST`/`JUDGE_PORT` direct judge traffic to a separate Ollama instance (avoids model-swap clashing in competitive benchmarks). `LLAMA_SERVER_HOST`/`PORT` configure the llama-server fallback provider. `QSTAR_CORPUS_QSC`/`QSTAR_CORPUS_MAX_PAGES` override the corpus streamed by `run`/`serve` (0 = all pages).

---

## Quick Reference Card

```bash
# Build & test
zig build                    # compile everything
zig build test               # all unit tests (~2,610 declarations; slow)
zig build test-agent         # agent suite (173 tests, fast)

# Generate text
zig build cli -- run "prompt"                    # single-shot
zig build cli -- run "prompt" --reflect          # with metacognition
zig build cli -- run "prompt" --draft-mode       # speculative draft
zig build cli -- chat                            # interactive chat

# Train
zig build cli -- train --model qwen2.5:3b        # Ollama teacher
zig build cli -- train --teacher openai           # OpenAI teacher
zig build cli -- train-internet --no-ollama       # Wikipedia

# Evaluate
zig build cli -- turing-test --verbose            # Turing test
zig build cli -- experiment --prompts 5           # control experiment
zig build competitive-bench -- qwen2.5:3b         # competitive bench

# Serve
zig build cli -- serve                            # HTTP API server
zig build cli -- serve 8080                       # custom port

# Tools
zig build cli -- call calculate '{"op":"add","a":5,"b":3}'
zig build cli -- kg query "Paris"
zig build cli -- geoview distance 40.7 -74.0 51.5 -0.1
```
