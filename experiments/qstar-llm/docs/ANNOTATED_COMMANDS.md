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
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load before generation |
| `--vocab <spec>` | auto | Ramsey vocab specifier: `128k`, `256k`, `512k`, `1m`, or path |
| `--level <N>` | 0 | Lattice scale level (0-7) |
| `--autoscale` | off | Enable dynamic lattice auto-tuning based on corpus size |
| `--max-cycles <N>` | 1024 | Maximum inference cycles |
| `--reflect` | off | Use metacognitive reflection (generate-evaluate-correct loop) |
| `--draft-mode` | off | Speculative draft mode: Qstar generates, Ollama verifies |
| `--draft-model <name>` | `qwen2.5:3b` | Verifier model for draft mode |

**Annotations:**
- Loads `qstar_corpus.txt` if present in the working directory
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
```

**Arguments:**

| Flag | Default | Description |
|------|---------|-------------|
| `[opening]` | none | Optional opening message (positional) |
| `--model <name>` | `qwen2.5:3b` | Ollama model |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load |
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

**Annotations:**
- Uses 140 built-in default prompts covering diverse topics
- With `--teacher auto`: checks for `OPENAI_API_KEY` in environment and `.env` file; uses OpenAI if found, falls back to Ollama
- Each prompt: sends to teacher model, receives response, agent learns from the response via `learnFromText()`
- Appends learned content to the corpus file
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
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file |
| `--offset <N>` | 0 | Skip first N articles (resumable) |
| `--limit <N>` | all | Only fetch N articles |
| `--no-ollama` | off | Disable Ollama augmentation (use when Ollama is unavailable) |

**Annotations:**
- Fetches Wikipedia article extracts via the Wikipedia API
- 1,155 article titles across 7 batches are built-in
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
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file |

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
```

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `build <raw.txt> <out.qsc> [--page-size N]` | Build .qsc container (gzip pages + CRC32 + page table) |
| `verify <corpus.qsc>` | Read every page, validate checksums + decompression |
| `info <corpus.qsc>` | Show magic, version, sizes, compression ratio, checksum status |
| `stream <corpus.qsc> [--limit N]` | Stream lines with on-demand page decompression |

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
Qstar v3.0.0 (Pure Zig, Q32.32 Fixed-Point, 421 E0 Nodes, 7 Channels)
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
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file path |

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
| `zig build test` | Run all 1,268 unit tests |
| `zig build tool-test` | Run tool calling + server integration tests (44) |
| `zig build vision-test` | Run vision pipeline tests (25) |
| `zig build geoview-test` | Run geoview pipeline tests (30) |
| `zig build regression` | Run full regression harness (61 checks) |
| `zig build manual` | Run 4 manual integration test suites |
| `zig build audit` | Run agent dual-mode audit (12 tests) |
| `zig build samc` | Run SAMC validation (5 tests) |
| `zig build ollama-bench` | Run head-to-head benchmark vs Ollama |
| `zig build qstar-bench` | Run Qstar internal benchmark suite |
| `zig build maple-bench` | Run Maple protocol benchmark |
| `zig build maple-standard-bench` | Run Maple standard benchmark |
| `zig build vulkan-bench` | Run Vulkan compute benchmark |
| `zig build shaders` | Build Vulkan shaders |
| `zig build wasm` | Build WASM module for browser embedding |
| `zig build html` | Build self-contained universe.html with embedded WASM |
| `zig build corpus` | Build compressed .qsc corpus container |
| `zig build master` | CI/CD gate: regression + build + publish quine payloads |
| `zig build run` | Run example application |
| `zig build cli` | Run CLI binary |
| `zig build serve` | Run HTTP API server |

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
```

The loader checks real environment variables first, then `.env` entries. `JUDGE_HOST`/`JUDGE_PORT` direct judge traffic to a separate Ollama instance (avoids model-swap clashing in competitive benchmarks).

---

## Quick Reference Card

```bash
# Build & test
zig build                    # compile everything
zig build test               # 1,268 unit tests

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
