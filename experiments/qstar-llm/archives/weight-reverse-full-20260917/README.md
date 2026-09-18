# Qstar-LLM

[![CI](https://github.com/ostffleetadmiral/qstar-ecosystem/actions/workflows/ci.yml/badge.svg)](https://github.com/ostffleetadmiral/qstar-ecosystem/actions/workflows/ci.yml)

A lattice-native inference engine that replaces transformer-based LLMs with a 15³ grid of 421 E0 nodes × 8 channels (53,888-byte state). Core arithmetic is integer-only fixed-point in two tiers: the lattice state runs Q64.64 (i128 cells, i256 intermediates), while the metacognition/semantic layer runs Q128.128 (i256, i512 intermediates). Hardware auto-detection selects optimal precision tier at comptime; states are downscaled to Q32.32 (i64) for Maple/ESP32/WASM peripherals. Zero external dependencies in the core — ONNX Runtime and Vulkan are loaded dynamically via dlopen when present.

Includes self-training pipeline (Ollama or OpenAI teacher, plus hybrid mode), internet training (Wikipedia API, 1,345 article titles), dataset ingestion (Gov + AdmPaul), Turing test framework, 58-tool calling engine, native vision pipeline (face detection/recognition/tracking/gaze/anti-spoofing via ONNX Runtime), geoview subsystem (globe rendering, live feeds, HUD, voice commands), Ollama-compatible HTTP server with concurrent request handling, streaming responses, and tok/s generation metrics, CLI binary with speculative draft mode and ecosystem commands (mesh, transport, collapse), optional neural-LM hybrid path (Qwen3-0.6B ONNX) with confidence-routed llama-server streaming fallback (`/no_think` creative fast path), WASM exports, holographic projection (S0↔S7), TurboQuant compression, SAMC accelerated reasoning, vocab lattice scaling, integer-only prototypes, competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple), quine-style compressed corpus container (.qsc), natural language generation engine with GenerationMetrics (tok/s, TTFT, prompt eval timing), 8-dimensional sentience scoring (self-awareness, direct experience, metacognition, situational awareness, random thought), Matrix15 text-to-scalar-field bridge, Ollama streaming client with advanced options (think, max_tokens, top_p, num_threads, keep_alive), virtual mesh networking over TCP with 12 transport modes and civilization collapse simulation, control experiment framework (baseline vs constrained metacognitive reflection), **Metacognition Engine** (always-on introspection, mid-generation correction, dynamic parameter adjustment, Q128.128 scoring), **Trivium Architecture** (Grammar/Logic/Rhetoric pipeline), **Quadrivium Architecture** (Arithmetic/Geometry/Music/Astronomy mathematical manifold), **dimensional modules 0D–10D** (origin through gravity), and **Lattice-Native Voice Codec** (VQ codebooks, NCA wave propagation, HDC speaker binding) — a fully standalone LLM application.

## What This Is

Qstar-LLM is the standalone extraction of Qstar's agent intelligence layer. The lattice IS the model — no transformer attention, no MLP, just octonion channel routing on a 3D grid.

**Key numbers:**

| Metric | Value |
|--------|-------|
| Agent state size | 53,888 bytes (~53 KB, 421 × 8 × i128 Q64.64) |
| Downscaled state | 26,944 bytes (421 × 8 × i64 Q32.32 for peripherals) |
| Reference transformer | 75 MB (Qwen1.5-0.5B) |
| Size reduction | ~1,460× |
| E0 nodes | 421 |
| Channels | 8 (e0–e7; LLM interior = e1–e5, e0/e6/e7 reserved) |
| Lattice state arithmetic | i128 Q64.64 fixed-point (i256 intermediates) |
| Metacognition/semantic layer | i256 Q128.128 fixed-point (i512 intermediates) |
| External dependencies | 0 (core); ONNX Runtime + Vulkan via dlopen (optional) |
| Modules | 129 src + 12 vision + 16 geoview + 19 test suites |
| Tests | 2,610+ (src + vision + geoview + test files) |
| Built-in tools | 58 |
| Regression checks | 66 |
| Corpus | ~65.8M lines / 2.9 GB raw (`qstar_corpus_large.txt`), 551 MB `qstar_corpus_full.qsc` (default) |
| Training prompts | 300 prompts across 30 categories |
| Wikipedia article titles | 1,345 |
| Dataset files | 2,177 (1,091 Gov + 83 AdmPaul + 1,003 reference) |
| WASM compatible | Yes |

## Quick Start

```bash
# Clone
git clone https://github.com/ostffleetadmiral/qstar-ecosystem.git
cd qstar-ecosystem

# Build the example + CLI binary
zig build

# Run all 2,610+ unit tests (slow — for development, test modules individually
# with `zig test`; see AGENTS.md for per-module commands)
zig build test

# Run tool server integration tests (44)
zig build tool-test

# Run vision pipeline tests (25)
zig build vision-test

# Run geoview pipeline tests (30)
zig build geoview-test

# Run full regression harness (66 checks)
zig build regression

# Run the basic inference demo
zig build run

# Run chat mode with a prompt (defaults to full .qsc corpus)
zig build run -- chat "Hello, what are you?"

# Chat with raw text corpus instead of .qsc
zig build run -- chat --txt qstar_corpus.txt

# Chat with limited .qsc pages (faster startup)
zig build run -- chat --max-pages 100

# Run state persistence demo
zig build run -- persist

# Run distributed face sync demo
zig build run -- sync

# Run tool calling engine demo
zig build run -- tools

# Run self-training pipeline demo
zig build run -- train

# Run configuration & memory pool demo
zig build run -- config

# Run the CLI binary (chat, serve, train, turing-test, experiment, etc.)
zig build cli -- chat "Hello"
zig build cli -- run "Explain quantum computing"
zig build cli -- experiment --prompts 5
zig build cli -- version

# Train by fetching Wikipedia articles
zig build cli -- train-internet --offset 0 --no-ollama --corpus qstar_corpus.txt

# Ingest local datasets into corpus
zig build cli -- ingest-corpus datasets/Gov --corpus-file qstar_corpus.txt

# Run Turing test with Ollama judge
zig build cli -- turing-test --model qwen2.5:3b --verbose --num-prompts 50

# Start the HTTP API server (Ollama + OpenAI compatible)
zig build serve

# Run manual integration tests
zig build manual

# Run SAMC validation
zig build samc

# Run agent dual-mode audit
zig build audit

# Run head-to-head benchmark vs Ollama (requires Ollama running)
zig build ollama-bench

# Run competitive benchmark suite (Qstar vs Ollama vs OpenAI, all categories)
zig build competitive-bench -- qwen2.5:3b
zig build competitive-bench -- --fast --no-ollama  # quick Qstar-only run
zig build competitive-bench -- qwen2.5:3b --judge-host 127.0.0.1 --judge-port 11434  # separate judge Ollama
zig build competitive-bench -- --num-prompts 25 --judge  # 25 prompts with cross-judging

# Run speculative draft mode (Qstar generates, Ollama verifies)
zig build cli -- run "Explain photosynthesis" --draft-mode

# Build WASM module for browser embedding
zig build wasm

# Build compressed .qsc corpus container (quine-style self-mod)
zig build corpus

# Build self-contained universe.html (WASM + compressed corpus embedded as base64)
zig build html

# Corpus container operations
zig build cli -- corpus build qstar_corpus.txt corpus.qsc --page-size 65536
zig build cli -- corpus verify corpus.qsc
zig build cli -- corpus stream corpus.qsc --limit 10
zig build cli -- corpus stream corpus.qsc --out rebuilt.txt   # export full raw corpus
zig build cli -- corpus index qstar_corpus_full.qsc            # one-time word→page index
# The index lands at datasets/qsc_index.bin (override: second arg). Once built,
# chat/run/serve and the competitive bench page in keyword-matching sentences
# from the full .qsc container during retrieval — not just the bounded in-memory
# window. Without the index, retrieval still works over the in-memory window.

# Corpus persistence: training appends only the session-learned delta — the
# existing corpus file is never truncated. With a .qsc source the delta goes to
# a "<base>.learned.txt" sidecar that chat/run/serve auto-load.

# Train with OpenAI as teacher (requires OPENAI_API_KEY)
zig build cli -- train --teacher openai
zig build cli -- train --teacher ollama

# Hybrid training: OpenAI semantic for factual, Ollama corpus for creative
zig build cli -- train --hybrid

# Train on 300 prompts across 30 categories
zig build cli -- train --hybrid --corpus qstar_corpus_large.txt

# Master node: CI/CD gate — regression + build + publish quine payloads
zig build master

# Serve the master publish dir for quine autoupdates (HTTP channel)
zig build cli -- master-serve 11436

# Publish payloads into the qstar P2P mesh (mirror channel)
zig build cli -- master publish-p2p

# Metacognitive training: Ollama generates prompts, Qstar self-evaluates
zig build cli -- train-metacog --num-prompts 20

# Train on every corpus source (Wikipedia + datasets + prompts)
zig build cli -- train-all --corpus qstar_corpus.txt

# Train on the .txt/.qsc corpus directly
zig build cli -- train-corpus --corpus qstar_corpus.txt

# Semantic training (OpenAI-generated prompts + teacher responses)
zig build semantic-train

# Competitive training: 5-phase pipeline (curriculum → adversarial)
zig build competitive-train

# Training heartbeat: learn from JSON sources, compress corpus, push to Maple
zig build training-heartbeat

# Cognitive-lane metabench (deterministic, no external services)
zig build cognitive-metabench

# Metacognitive benchmark vs remote Ollama judge
zig build meta-bench

# Compress agent state to zig-out/qstar_seed.bin
zig build seed

# Benchmark CPU vs Vulkan GPU inference cycles
zig build vulkan-bench

# Maple device benchmark over LAN
zig build maple-bench

# Agent diagnostics: lattice state, corpus stats, route health
zig build cli -- diagnose

# Framework audit: verify dimensional/axiom chain integrity
zig build cli -- framework-audit

# Interactive 3D geoview (globe, live feeds, HUD — requires display)
zig build cli -- geoview

# Virtual mesh networking (12 transport modes, TCP)
zig build cli -- mesh          # prints subcommand usage: start|join|status|broadcast|relay
zig build cli -- transport     # prints subcommand usage: list|send|recv

# Civilization collapse resilience simulation
zig build cli -- collapse      # prints subcommand usage
```

## Documentation

Full documentation lives in [`docs/`](docs/):

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — System architecture: lattice state, arithmetic tiers, metacognition, Trivium/Quadrivium, voice codec
- [docs/API_REFERENCE.md](docs/API_REFERENCE.md) — Public API for all modules
- [docs/ANNOTATED_COMMANDS.md](docs/ANNOTATED_COMMANDS.md) — Every CLI command and flag, annotated
- [docs/CAPABILITIES.md](docs/CAPABILITIES.md) — Feature inventory and status
- [docs/COMPONENT_DOCUMENTATION.md](docs/COMPONENT_DOCUMENTATION.md) — Per-module documentation
- [docs/TRAINING_PIPELINE.md](docs/TRAINING_PIPELINE.md) — Training modes, teachers, corpus flow
- [docs/TESTING.md](docs/TESTING.md) — Test methodology and per-module commands
- [docs/TOOLS_REFERENCE.md](docs/TOOLS_REFERENCE.md) — All 58 built-in tools
- [docs/MESH_NETWORKING.md](docs/MESH_NETWORKING.md) — Mesh/transport/collapse systems
- [docs/TURBOQUANT_INTEGRATION.md](docs/TURBOQUANT_INTEGRATION.md) — TurboQuant compression
- [docs/GODS_EYE_VIEW.md](docs/GODS_EYE_VIEW.md) — Geoview subsystem
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — Development workflow
- [docs/DATASETS.md](docs/DATASETS.md) — Corpus and dataset inventory

## Usage as a Library

In your project's `build.zig`:

```zig
const llm_mod = b.addModule("qstar_llm", .{
    .root_source_file = b.path("libs/qstar-llm/src/agent.zig"),
    .target = target,
    .optimize = optimize,
});
// Wire sub-modules: bpe_tokenizer, sampling, state_store, face_sync,
// fixed_point, q128, fp_bridge, precision_scaler, knowledge_graph, memory,
// perception, ollama_client, openai_client, llama_server, neural_lm,
// doc_loader, training, turing_test, tools, server, config, memory_pool,
// external_db, continual_learner, holographic, metacognition_engine,
// dynamic_routes, dim_0d_origin … dim_10d_gravity, trivium, quadrivium
```

### Basic Inference

```zig
const agent = @import("qstar_llm");
const fp = @import("fixed_point");

var a = agent.Agent.init(allocator, 0, fp.ONE);
defer a.deinit();

try a.ingest("Hello world from the lattice");
try a.run(10);

const output = try a.decode(allocator);
defer allocator.free(output);
std.debug.print("{s}\n", .{output});
```

### Long-Form Generation

```zig
var a = agent.Agent.init(allocator, 0, fp.ONE);
defer a.deinit();

const response = try a.generateLongForm("Explain quantum computing", allocator);
defer allocator.free(response);
std.debug.print("{s}\n", .{response});
```

### State Persistence

```zig
const store = @import("state_store");

var a = agent.Agent.init(allocator, 0, fp.ONE);
defer a.deinit();
try a.ingest("Save this state");
try a.run(10);

var st = store.StateStore.init(allocator);
defer st.deinit();
try a.saveStateToVFS(&st);

// Later — create fresh agent and load
var b = agent.Agent.init(allocator, 0, fp.ONE);
defer b.deinit();
const loaded = try b.loadStateFromVFS(&st);
```

### Distributed Face Sync

```zig
const face = @import("face_sync");

// Peer A: run inference, export state as SharedFaces
var agent_a = agent.Agent.init(allocator, 0, fp.ONE);
defer agent_a.deinit();
try agent_a.ingest("distributed inference");
try agent_a.run(10);
var faces = try agent_a.agentToSharedFaces(allocator, "peer-a");

// Simulate network transfer: copy local → remote (one SharedFace per channel)
for (0..8) |ch| {
    for (0..225) |i| {
        faces[ch].remote_states[i] = faces[ch].local_states[i];
    }
}

// Peer B: load from SharedFaces
var agent_b = agent.Agent.init(allocator, 0, fp.ONE);
defer agent_b.deinit();
agent_b.sharedFacesToAgent(&faces);
```

### Metacognitive Introspection

```zig
const model = a.introspect();
std.debug.print("Entropy: {d:.4}\n", .{model.activation_entropy});
std.debug.print("Peak node: {d}\n", .{model.peak_node});
std.debug.print("Channel imbalance: {d:.4}\n", .{model.channel_imbalance});
```

### Knowledge Graph

```zig
try a.initKnowledgeGraph();
const count = try a.extractKnowledgeFromText("Paris is the capital of France. France borders Germany.");
const context = try a.getKnowledgeGraphContext("Paris", 5);
```

### Self-Training Pipeline

```zig
const training = @import("training");

var a = agent.Agent.init(allocator, 0, fp.ONE);
defer a.deinit();

const config = training.TrainingConfig{ .verbose = true };
const prompts = [_][]const u8{ "Explain gravity", "What is photosynthesis?" };
const result = try training.trainBatch(&a, &prompts, config, allocator);
std.debug.print("Learned {d} sentences\n", .{result.sentences_learned});
```

### Tool Calling

```zig
const tools = @import("tools");

var reg = tools.ToolRegistry.init(allocator);
defer reg.deinit();
try reg.register(tools.ToolDefinition{
    .name = "calculate",
    .description = "Arithmetic calculator",
    .parameters = &.{
        .{ .name = "operation", .param_type = .string, .description = "add/sub/mul/div" },
        .{ .name = "a", .param_type = .number, .description = "First operand" },
        .{ .name = "b", .param_type = .number, .description = "Second operand" },
    },
});

const result = try reg.execute(.{
    .id = "call1",
    .name = "calculate",
    .arguments_json = "{\"operation\":\"add\",\"a\":5,\"b\":3}",
});
defer allocator.free(result);
std.debug.print("{s}\n", .{result});
```

### HTTP Server

```zig
const server = @import("server");

var srv = server.QstarServer.init(allocator, .{ .port = 11435 });
defer srv.deinit();
srv.loadCorpusCache();
try srv.initKnowledgeGraph();
try srv.start();
```

## API Reference

### Agent (`agent.zig`)

| Function | Description |
|----------|-------------|
| `Agent.init(allocator, level, base_temp)` | Create new agent at lattice level (0 = 15³) |
| `agent.ingest(text)` | Tokenize text → map to E0 node activations |
| `agent.ingestTokens(token_ids)` | Ingest pre-tokenized input |
| `agent.run(num_cycles)` | Run inference cycles (E0 firing + routing + cooling) |
| `agent.step()` | Single inference cycle |
| `agent.decode(allocator)` | Decode current activations → text |
| `agent.generateLongForm(prompt, allocator)` | Generate long-form response |
| `agent.getMetrics()` | Get GenerationMetrics from last generateLongForm (tok/s, TTFT, timing) |
| `agent.getMetricsStr(buf)` | Get human-readable tok/s string |
| `agent.draftGenerate(prompt, allocator)` | Generate speculative draft with metadata (tokens, timing) |
| `agent.generateWithReflection(prompt, allocator)` | Generate with self-evaluation loop |
| `agent.readTopToken()` | Get highest-activation token ID |
| `agent.readOutputTokens()` | Get all output token IDs |
| `agent.activeNodeCount()` | Count nodes above firing threshold |
| `agent.stateSizeBytes()` | Get state size in bytes |
| `agent.introspect()` | Get SelfModel (entropy, peak node, channel balance) |
| `agent.evaluateResponse(prompt, response)` | Score response on 8 dimensions (relevance, coherence, specificity, naturalness, self-awareness, direct experience, metacognition, situational awareness) |
| `agent.saveStateToVFS(bridge)` | Save state to any store with saveAgentState |
| `agent.loadStateFromVFS(bridge)` | Load state from any store with loadAgentState |
| `agent.agentToSharedFaces(allocator, peer_id)` | Export activations as 8 SharedFaces (one per channel) |
| `agent.sharedFacesToAgent(faces)` | Import activations from SharedFaces |
| `agent.initKnowledgeGraph()` | Initialize knowledge graph |
| `agent.extractKnowledgeFromText(text)` | Extract triplets from text |
| `agent.getKnowledgeGraphContext(query, n)` | Get KG context for a query |
| `agent.buildBigramModel(corpus)` | Build bigram model from corpus |
| `agent.learnFromText(text)` | Add text to dynamic corpus |
| `agent.setLevel(level)` | Set lattice level (0-3) |
| `agent.reset()` | Clear all state |

### StateStore (`state_store.zig`)

| Function | Description |
|----------|-------------|
| `StateStore.init(allocator)` | Create in-memory state store |
| `store.saveAgentState(activations, cycle, temp, base_temp, tokens)` | Save agent state |
| `store.loadAgentState(out_activations)` | Load agent state (returns null if none) |
| `store.hasAgentState()` | Check if state exists |
| `store.clearAgentState()` | Remove saved state |

### FaceSync (`face_sync.zig`)

| Function | Description |
|----------|-------------|
| `SharedFace.init(peer_id, axis, edge)` | Create shared face |
| `face.setLocalStates(states)` | Set local activation states |
| `face.setRemoteStates(states)` | Set remote activation states |
| `face.computeDelta(indices, values)` | Compute changed state delta |
| `face.applyDelta(indices, values)` | Apply delta from peer |
| `face.serializeFull(out)` | Serialize to 1800 bytes |
| `face.deserializeFull(data)` | Deserialize from bytes |
| `face.mobiusCorrelation()` | Compute Möbius correlation |
| `face.isPhaseLocked(threshold)` | Check phase lock |

### BPE Tokenizer (`bpe_tokenizer.zig`)

| Function | Description |
|----------|-------------|
| `Tokenizer.init(allocator)` | Create tokenizer |
| `tok.encode(text)` | Encode text → token IDs |
| `tok.decode(token_ids)` | Decode token IDs → text |
| `tok.loadFromTxtFile(path, max)` | Load vocabulary from file |
| `tok.loadRamseyVocab(specifier, max)` | Load Ramsey vocabulary (128k, 256k, 512k, 1m) |

### Sampling (`sampling.zig`)

| Function | Description |
|----------|-------------|
| `SampleConfig{...}` | Configure sampling (strategy, temperature, top_k, top_p) |
| `sample(logits, config, rng)` | Sample token from logits |

### Memory (`memory.zig`)

| Function | Description |
|----------|-------------|
| `WorkingMemory.init(allocator)` | Create working memory (20 entries) |
| `EpisodicMemory.init(allocator, path)` | Create episodic memory (500 episodes) |
| `episodic.consolidate()` | Consolidate working → episodic |
| `episodic.retrieve(query, n)` | Retrieve similar episodes |

### Perception (`perception.zig`)

| Function | Description |
|----------|-------------|
| `detectActivations(activations)` | Detect activation clusters |
| `estimateAttention(activations)` | Estimate attention direction |
| `estimateOrientation(activations)` | Estimate orientation |
| `fingerprintState(activations)` | Generate state fingerprint |
| `checkLiveness(history)` | Check if state shows liveness |

### Knowledge Graph (`knowledge_graph.zig`)

| Function | Description |
|----------|-------------|
| `KnowledgeGraph.init(allocator)` | Create knowledge graph |
| `kg.addTriplet(subject, predicate, object)` | Add triplet |
| `kg.query(subject, predicate)` | Query triplets |
| `kg.bfs(start, max_hops)` | BFS traversal |
| `kg.save(path)` | Save to file |
| `kg.load(path)` | Load from file |

### Training (`training.zig`)

| Function | Description |
|----------|-------------|
| `TrainingConfig{...}` | Configure training (ollama, openai, teacher, verbose) |
| `resolveTeacher(config)` | Resolve teacher: explicit choice wins, auto = OpenAI if key present else Ollama |
| `trainOnPrompt(agent, prompt, config, allocator)` | Train on single prompt using resolved teacher |
| `trainBatch(agent, prompts, config, allocator)` | Train on batch of prompts |
| `trainDefault(agent, config, allocator)` | Train with 300 default prompts (30 categories) |
| `trainBatchHybrid(agent, config, allocator)` | Hybrid training: OpenAI semantic + Ollama corpus |
| `trainFromInternet(agent, config, corpus_path, limit, offset, use_ollama, allocator)` | Fetch and learn from Wikipedia articles |
| `fetchWikipediaArticle(allocator, title)` | Fetch plain-text article from Wikipedia API |
| `saveCorpusToFile(agent, path)` | Save agent corpus to file |
| `loadCorpusFromFile(agent, path)` | Load corpus from file |
| `ingestFromDirectory(agent, dir, ...)` | Ingest documents from directory |
| `enrichFromDirectory(agent, dir, ...)` | Enrich corpus from directory with Ollama |

### Turing Test (`turing_test.zig`)

| Function | Description |
|----------|-------------|
| `TuringTestConfig{...}` | Configure test (categories, rounds, judge model) |
| `runTuringTest(agent, config, allocator)` | Run full Turing test suite |
| `runTuringTestRound(agent, prompt, config, allocator)` | Run single test round |
| `runTuringTestBatch(agent, prompts, config, allocator)` | Run batch of test rounds |
| `TuringTestSummary` | Aggregated results across categories |

### Tools (`tools.zig`)

| Function | Description |
|----------|-------------|
| `ToolRegistry.init(allocator)` | Create tool registry |
| `reg.register(tool_def)` | Register a tool definition |
| `reg.execute(tool_call)` | Execute tool call, returns JSON result |
| `reg.attachKnowledgeGraph(kg)` | Attach KG for kg_query tool |
| `reg.attachExternalDb(db)` | Attach external DB for db_query tool |
| `parseToolCall(allocator, text)` | Parse tool call from LLM output text |

**58 built-in tools:** calculate, lattice_node, quantum_simulate, kg_query, db_query, external_search, file_read, file_write, file_list, http_fetch, shell_exec, time_now, uuid_generate, base64_encode, base64_decode, hash_compute, json_validate, json_format, string_replace, text_summarize, word_count, sentiment_analyze, ner_extract, text_classify, text_diff, language_detect, wikipedia_lookup, dictionary_lookup, law_lookup, rag_search, kg_add_triplet, kg_export, stats_compute, csv_parse, data_sort, data_filter, histogram_generate, correlation_compute, face_detect, face_recognize, face_analyze, face_track, gaze_estimate, emotion_detect, geo_distance, geo_convert, geo_mgrs, geo_bearing, geo_destination, globe_query, track_flight, track_vessel, track_satellite, earthquake_query, cctv_query, hud_control, scene_play, annotation_add.

### Server (`server.zig`)

| Function | Description |
|----------|-------------|
| `QstarServer.init(allocator, config)` | Create HTTP server |
| `server.loadCorpusCache()` | Load corpus from `qstar_corpus.txt` |
| `server.initKnowledgeGraph()` | Initialize KG from `qstar_kg.bin` |
| `server.initExternalDb()` | Initialize external DB |
| `server.start()` | Start listening (default port 11435) |

**Ollama-compatible endpoints:** `/api/generate`, `/api/chat`, `/api/tags`, `/api/version`, `/api/embeddings`, `/api/show`, `/api/pull`, `/api/push`, `/api/delete`, `/api/copy`, `/api/ps`, `/api/heartbeat`

**OpenAI-compatible endpoints:** `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`

**Ecosystem endpoints:** `/api/mesh/status`, `/api/transport/list`

All generation endpoints include tok/s metrics: `total_duration`, `prompt_eval_duration`, `eval_duration`, `prompt_eval_count`, `eval_count`.

### Ollama Client (`ollama_client.zig`)

| Function | Description |
|----------|-------------|
| `OllamaConfig{...}` | Configure Ollama connection (host, port, model) |
| `generate(allocator, config, prompt)` | Generate response from Ollama |
| `generateStreaming(allocator, config, request)` | Streaming generation with advanced options (think, max_tokens, top_p, num_threads, keep_alive) |
| `verifyDraft(allocator, config, prompt, draft)` | Verify speculative draft via Ollama, returns acceptance stats |
| `isAvailable(config)` | Check if Ollama is reachable |
| `OllamaResponse.deinit()` | Free response resources |

### Document Loader (`doc_loader.zig`)

| Function | Description |
|----------|-------------|
| `loadDocuments(allocator, dir, ...)` | Recursively load .md/.txt/.tex files |
| `extractSentences(text)` | Extract clean prose sentences |

### External DB (`external_db.zig`)

| Function | Description |
|----------|-------------|
| `ExternalDb.init(allocator)` | Create external DB connector |
| `db.query(key)` | Query key-value store |
| `db.searchJson(query)` | Search JSON records |
| `db.attachKnowledgeGraph(kg)` | Attach KG for grounded queries |

### Continual Learner (`continual_learner.zig`)

| Function | Description |
|----------|-------------|
| `ContinualLearner.init(allocator, config)` | Create background learner |
| `learner.start()` | Start heartbeat thread |
| `learner.stop()` | Stop heartbeat thread |
| `learner.tick()` | Single learning cycle |

### Config (`config.zig`)

| Function | Description |
|----------|-------------|
| `Config.default()` | Get default configuration |
| `Config.fromJson(allocator, json)` | Parse config from JSON |
| `config.toJson(allocator)` | Serialize config to JSON |

### Memory Pool (`memory_pool.zig`)

| Function | Description |
|----------|-------------|
| `BlockPool.init(allocator, block_size, capacity)` | Create block pool |
| `pool.alloc()` | Allocate a block |
| `pool.free(block)` | Free a block |
| `pool.reset()` | Reset pool |
| `BumpArena.init(allocator, size)` | Create bump arena |
| `arena.alloc(T, count)` | Allocate from arena |

### CLI (`main.zig`)

| Command | Description |
|---------|-------------|
| `qstar serve` | Start HTTP API server (Ollama + OpenAI compatible, port 11435) |
| `qstar run "prompt"` | Single-shot text completion (supports `--draft-mode`) |
| `qstar chat` | Interactive multi-turn chat (`--qsc`, `--txt`, `--corpus`, `--max-pages`) |
| `qstar call <tool> <args>` | Execute a tool directly |
| `qstar list` / `qstar models` | List available models (Ollama-style) |
| `qstar pull <model>` / `qstar push <model>` | Ollama-style model management |
| `qstar version` | Display version info |
| `qstar train` | Self-train (`--teacher <ollama|openai|auto>`, `--hybrid`) |
| `qstar train-metacog` | Metacognitive training — self-evaluated prompt batches |
| `qstar train-all` | Train on every corpus source (Wikipedia + datasets + prompts) |
| `qstar train-corpus` | Full pipeline: ingest + enrich all documents |
| `qstar train-internet` | Train by fetching Wikipedia articles (1,345 titles) |
| `qstar corpus build <raw> <out.qsc>` | Build compressed .qsc corpus container |
| `qstar corpus verify <corpus.qsc>` | Verify all pages (checksums + decompression) |
| `qstar corpus stream <corpus.qsc> [--out <file>]` | Stream lines from compressed corpus (optionally to a file) |
| `qstar convert-corpus` | Convert between corpus formats |
| `qstar ingest-corpus <dir>` | Directly ingest .md/.txt/.tex documents into corpus |
| `qstar enrich-corpus <dir>` | Ollama-enriched corpus from documents |
| `qstar turing-test` | Run automated Turing test with Ollama judge |
| `qstar experiment` | Run control experiment (baseline vs constrained metacognitive reflection) |
| `qstar diagnose` | Agent diagnostics: lattice state, corpus stats, route health |
| `qstar framework-audit` | Verify dimensional/axiom chain integrity |
| `qstar geoview <sub>` | Geospatial tools: distance, convert, mgrs, bearing, destination |
| `qstar kg query <entity>` | Query knowledge graph |
| `qstar start-heartbeat` | Start background continual learning |
| `qstar transport <list|send|recv>` | Virtual transport modes and message send/recv |
| `qstar mesh <start|join|status|broadcast|relay>` | Virtual mesh node operations |
| `qstar collapse <sub>` | Civilization collapse simulation |
| `qstar quine <sub>` | Quine edition build/push |
| `qstar master <sub>` | Master node operations (incl. `publish-p2p`) |
| `qstar master-serve <port>` | Serve master publish dir for quine autoupdates |
| `qstar dns-update` | ClouDNS dynamic DNS update |

### WASM Exports (`wasm_exports.zig`)

WASM-compatible bindings for agent inference, lattice queries, and tool execution. Build with `--target wasm32-wasi`.

## Architecture

```
Input: text → BPE tokenize → E0 node activation
  ↓
Trivium Stage 1: Grammar — parse, classify, route
  ↓
Inference: E0 firing + octonion routing + Fibonacci projection + φ-cooling
  ↓
Trivium Stage 2: Logic — validate lattice coherence, non-contradiction
  ↓
Quadrivium: Arithmetic/Geometry/Music/Astronomy manifold processing
  ↓
Metacognition: introspect → evaluate → mid-generation correction
  ↓
Trivium Stage 3: Rhetoric — format, clarity, persuasiveness
  ↓
Output: E0 activation decode → token IDs → text
```

### Cognitive Architecture

The agent uses a three-layer cognitive architecture inspired by the classical liberal arts:

**Metacognition Engine** (`metacognition_engine.zig`) — Always-on introspection layer that:
- Classifies prompts by complexity (trivial→deep) and domain
- Dynamically adjusts reflection depth (1-5 cycles) and quality threshold
- Detects when mid-response correction is warranted and appends natural correction phrases
- Suggests parameter adjustments (temperature, top-k, top-p) based on evaluation scores

**Trivium** (`trivium.zig`) — Language and reasoning pipeline:
- **Grammar**: Concept extraction, domain detection (14 domains), complexity classification, modality routing (text/audio), tone detection
- **Logic**: Coherence scoring, channel balance, non-contradiction checking, reasoning step counting
- **Rhetoric**: Format detection (plain_text/markdown/structured/code_block), clarity scoring, persuasiveness scoring

**Quadrivium** (`quadrivium.zig`) — Mathematical manifold processing:
- **Arithmetic**: Precision tracking, quantization-aware operations, discrete latent space mapping
- **Geometry**: Manifold distance, cosine similarity, volumetric hashing, spatial lookup, activation volume compression
- **Music**: Harmonic series, formant↔lattice mapping, resonance attenuation, beat frequency, prosody envelope, pitch contour
- **Astronomy**: State trajectory evolution, future prediction, orbital energy, stability metric (modulates evaluation confidence)

**Voice Codec** (`voice_codec.zig`) — Lattice-native audio processing:
- **VQ Codebook**: Lloyd-Max vector quantization for audio frame encode/decode (4096 entries, 12-bit codes)
- **NCA Wave Propagation**: Injects voice patterns at lattice boundaries, self-organizing relaxation converges to target formants
- **HDC Speaker Binding**: Hyperdimensional bipolar vectors (421×7=2947 dimensions) with XOR-like bind/unbind for speaker identity
- **Pipeline**: encode → lattice injection → NCA propagation → HDC binding → decode → voice cloning

### Core Source Modules (`src/`)

#### Inference core
| Module | Tests | Description |
|--------|-------|-------------|
| agent.zig | 173 | Core inference engine (E0, octonion, Fibonacci, φ-cooling, SAMC, Fano routing, creative routes, naturalness, retrieval, draft mode, 8-dim sentience scoring, Matrix15 bridge, control experiment framework, factual/short-prompt routes, E=mc² route) |
| agent_lite.zig | 55 | Lightweight agent for WASM/embedded inference |
| lattice.zig | 56 | Lattice axioms (A1-A7), Fano plane routing, e-value computation |
| bpe_tokenizer.zig | 14 | Qwen1.5-compatible tokenization + Ramsey vocab scaling |
| sampling.zig | 15 | Top-k, top-p, temperature sampling |
| main.zig | 29 | CLI binary (34 commands: serve, run, chat, train*, mesh, transport, collapse, corpus, geoview, master, diagnose, framework-audit, …) |
| server.zig | 19 | Ollama + OpenAI-compatible HTTP server (concurrent, streaming) |
| tools.zig | 66 | 58-tool calling engine |
| wasm_exports.zig | 1 | WASM export bindings |
| voice_codec.zig | 18 | Lattice-native voice codec: VQ codebooks, NCA wave propagation, HDC speaker binding |
| corpus_seed.zig | 7 | Corpus seed text for agent initialization |
| corpus_seed_lite.zig | 6 | Lightweight corpus seed for WASM/embedded contexts |

#### Fixed-point arithmetic tiers
| Module | Tests | Description |
|--------|-------|-------------|
| q128.zig | 35 | Q128.128 arithmetic — i256 values, i512 intermediates, RNE multiply |
| fixed_point.zig | 55 | Q64.64 arithmetic — i128 values, i256 intermediates (lattice state) |
| fixed_point32.zig | 10 | Q32.32 arithmetic — i64 values, i128 intermediates (peripherals) |
| fp_bridge.zig | 13 | Q64.64 → Q32.32 downscale bridge |
| precision_scaler.zig | 6 | Comptime precision-tier selection |
| hardware_detect.zig | 15 | Hardware capability detection for tier selection |

#### Algebra & math
| Module | Tests | Description |
|--------|-------|-------------|
| octonion_math.zig | 26 | Octonion multiplication, Fano structure |
| bi_complex.zig | 31 | Bi-complex numbers (5D language algebra) |
| jordan_algebra.zig | 22 | J₃(O) Jordan algebra (6D self-model) |
| so10.zig | 20 | SO(10) decomposition |
| e8_roots.zig | 16 | E8 root system |
| quantum.zig | 37 | Integer quantum simulation |
| entangle.zig | 33 | Entanglement/correlation primitives |
| codon.zig | 32 | 64-codon genetic-code routing |

#### Dimensional modules (0D–10D)
| Module | Tests | Description |
|--------|-------|-------------|
| dim_0d_origin.zig | 5 | Origin/seed state |
| dim_1d_time.zig | 5 | Temporal ordering |
| dim_2d_complex.zig | 9 | Complex-plane structure |
| dim_3d_space.zig | 6 | Spatial grid (15³) |
| dim_4d_rotation.zig | 11 | Quaternion rotation/orientation |
| dim_5d_language.zig | 15 | Bi-complex language/attention |
| dim_6d_consciousness.zig | 14 | Jordan self-model, metacognition |
| dim_7d_color.zig | 5 | Octonionic channel routing |
| dim_8d_frequency.zig | 10 | φ-cooling frequency scaling |
| dim_9d_chaos.zig | 9 | Stochastic perturbation |
| dim_10d_gravity.zig | 9 | Dual-bi-complex coupling closure |

#### Metacognition & cognition
| Module | Tests | Description |
|--------|-------|-------------|
| metacognition_engine.zig | 25 | Always-on introspection, background thread, mid-generation correction, dynamic thresholding |
| trivium.zig | 16 | Grammar/Logic/Rhetoric pipeline |
| quadrivium.zig | 18 | Arithmetic/Geometry/Music/Astronomy manifold |
| dynamic_routes.zig | 17 | Learned response routes with evaluation feedback |
| cognitive_lanes.zig | 5 | Explicit/implicit candidate promotion lanes |
| cognitive_cloud.zig | 11 | Distributed cognition primitives |
| routing_calibration.zig | 3 | Route confidence calibration |
| arithmetic_reasoner.zig | 3 | Integer arithmetic reasoning |
| knowledge_lookup.zig | 2 | Factual lookup layer |
| sentience_scorer.zig | 21 | 8-dimension sentience scoring |
| sentience_experiment.zig | 20 | Control experiment framework |

#### Memory & knowledge
| Module | Tests | Description |
|--------|-------|-------------|
| memory.zig | 5 | 3-layer cognitive memory (working/episodic/semantic) |
| knowledge_graph.zig | 7 | Triplet store with BFS traversal |
| perception.zig | 37 | Activation detection, attention, liveness, introspection |
| state_store.zig | 5 | In-memory state persistence |
| face_sync.zig | 8 | Peer face sync (8 SharedFaces, one per channel) |
| memory_pool.zig | 9 | Block pool + bump arena allocators |

#### Training & corpus
| Module | Tests | Description |
|--------|-------|-------------|
| training.zig | 26 | Self-training (Ollama/OpenAI/hybrid teachers), internet training, dataset ingestion |
| corpus_learner.zig | 9 | Corpus ingestion and learning |
| corpus_store.zig | 7 | Quine-style .qsc corpus container with LRU page cache |
| heartbeat.zig | 9 | Training heartbeat: corpus loading, memory/benchmark/Turing learning |
| prompt_generator.zig | 4 | Ollama-based random prompt generation |
| doc_loader.zig | 16 | Recursive document preprocessor |
| continual_learner.zig | 7 | Background continual learning heartbeat |
| env_loader.zig | 10 | .env file loader for API keys |

#### External model integration
| Module | Tests | Description |
|--------|-------|-------------|
| ollama_client.zig | 20 | Zero-dep Ollama HTTP client + draft verification + streaming |
| openai_client.zig | 13 | Zero-dep OpenAI HTTP client (TLS HTTPS) |
| llama_server.zig | 18 | llama-server streaming fallback client (`/no_think` fast path) |
| neural_lm.zig | 4 | Neural LM integration (Qwen3-0.6B ONNX) |
| llm_provider.zig | 7 | Provider abstraction over external LLMs |
| kimi_stream_adapter.zig | 3 | Kimi streaming API adapter |

#### Compression & holographic
| Module | Tests | Description |
|--------|-------|-------------|
| s0_projection.zig | 55 | S0→S7 holographic projection |
| s7_compression.zig | 45 | S7→S0 lattice compression |
| holographic.zig | 35 | S0↔S7 holographic projection/compression |
| holographic_memory.zig | 10 | Holographic memory encoding |
| holo_codec.zig | 16 | Holographic codec |
| turbo_quant.zig | 33 | TurboQuant vector quantization sidecar |
| compress.zig | 11 | Self-contained compressor (dedup + gzip + lattice + RMSY) |
| seed_compressor.zig | 8 | Agent-state seed compression (Q32.32 downscale option) |
| lattice_compressor.zig | 8 | Lattice activation compression |
| distillation_s0.zig | 9 | S0 corpus distillation |
| vocab_lattice_scaling.zig | 25 | Level-scaled token-to-node mapping |

#### Mesh, transport & resilience
| Module | Tests | Description |
|--------|-------|-------------|
| mesh.zig | 65 | Purified peer mesh — TransportMode, Location, ConnectionPool, OfflineTransportRouter |
| mesh_peer.zig | 7 | TCP mesh peer (XChaCha20-Poly1305) |
| virtual_transport.zig | 26 | Virtualized transport over TCP — 12 modes, store-and-forward, collapse simulation |
| transport_polyglot.zig | 24 | Multi-format polyglot file transport |
| transport_lora.zig | 24 | LoRa long-range radio transport |
| transport_p2p.zig | 8 | P2P packet transport (X25519, ChaCha20Poly1305) |
| transport_qr.zig | 8 | QR code portal transport |
| transport_paperback.zig | 8 | Paperback book format transport |
| transport_convert.zig | 8 | Transport format conversion |
| transport_optar.zig | 7 | Optical art encoding transport |
| transport_wifi.zig | 6 | WiFi CSI frame transport (ADR-018) |
| transport_stega.zig | 6 | LSB steganography (AES-GCM, PNG) |
| transport_video.zig | 6 | Video frame embedding transport |
| transport_quine.zig | 5 | Self-referential HTML quine transport |
| transport_audio.zig | 5 | Audio frequency encoding transport |
| transport_cassette.zig | 5 | Cassette tape audio transport |
| relay_router.zig | 25 | Multi-hop relay routing + rendezvous discovery |
| qr_nest.zig | 23 | Recursive QR nesting |
| p2p_types.zig | 40 | P2P protocol type definitions |
| nat.zig | 19 | NAT traversal (UDP hole punching, WebRTC signaling) |
| merge.zig | 14 | State merge/conflict resolution |
| sybil.zig | 14 | Sybil-resistance identity verification |
| webrtc.zig | 12 | WebRTC data channel protocol (SDP, ICE, DTLS, SCTP) |
| collapse.zig | 16 | Civilization collapse resilience — QR portal encoding |
| collapse_recover.zig | 9 | Post-collapse peer recovery |
| collapse_resilience.zig | 8 | State preservation through digital failure |
| master_server.zig | 8 | Master node HTTP server + WebRTC signaling/relay + dynamic DNS |
| dynamic_dns.zig | 20 | ClouDNS dynamic DNS updater |
| p2p_update.zig | 5 | P2P mirror publish (qstar-net bootstrap + qstar-vfs) |
| master_publish.zig | 2 | Master payload publisher |
| maple_client.zig | 2 | Maple protocol client |

#### Hardware & GPU
| Module | Tests | Description |
|--------|-------|-------------|
| vulkan_compute.zig | 9 | Dynamic Vulkan loader + compute dispatch (7-channel GPU prototype path) |
| c_ffi.zig | 11 | C FFI bridge for vision/geoview (dlopen/dlsym) |
| hw_bridge.zig | 22 | Hardware bridge layer |
| hw_jordan_algebra.zig | 23 | J₃(O) hardware implementation |
| hw_surface_computation.zig | 21 | Surface computation hardware path |
| hw_scaling_analysis.zig | 16 | Cubic scaling chain verification |
| hw_generative_chain.zig | 15 | 0^0=i generative bootstrap |
| hw_self_claims.zig | 15 | Self-claim verification |
| hw_elevation_paths.zig | 28 | Self-claim elevation paths |
| hw_literature_review.zig | 12 | Literature reference verification |
| hw_octonion.zig | 11 | Octonion hardware primitives |
| hw_e8_roots.zig | 11 | E8 roots hardware path |
| hw_electric_charges.zig | 10 | Octonion U(1) charges |
| hw_final_audit.zig | 9 | Final audit classification |
| hw_consciousness_audit.zig | 8 | Consciousness causal-chain audit |

#### Config & misc
| Module | Tests | Description |
|--------|-------|-------------|
| config.zig | 4 | Unified JSON configuration |
| external_db.zig | 3 | External database connector |
| build_html.zig | 3 | universe.html builder |

**Total: ~2,536 tests across 129 src modules + 12 vision + 16 geoview + 19 test suites**

### Vision Modules (`src/vision/`)

| Module | Tests | Description |
|--------|-------|-------------|
| image.zig | 20 | Image I/O, resize, color space |
| onnx_runtime.zig | 11 | Native ONNX model runtime |
| face_detect.zig | 16 | Face detection with NMS |
| face_landmark.zig | 19 | 68-point landmark detection |
| face_recognize.zig | 21 | Face recognition embeddings |
| face_analyzer.zig | 13 | Unified face analysis pipeline |
| face_track.zig | 16 | IoU-based face tracking |
| gaze_headpose.zig | 13 | Gaze + 6-DOF head pose |
| face_attributes.zig | 14 | Age/gender/emotion prediction |
| face_quality.zig | 12 | Face quality scoring |
| anti_spoofing.zig | 16 | Liveness/spoofing detection |
| face_parsing.zig | 13 | Face region segmentation |
| **Total** | **184** | **12 vision modules** |

### Geoview Modules (`src/geoview/`)

| Module | Tests | Description |
|--------|-------|-------------|
| globe_render.zig | 14 | Ellipsoid mesh generation |
| geo_math.zig | 16 | LLA/ECEF/ENU/MGRS transforms |
| camera.zig | 14 | Orbit/fly-to/inertial camera |
| live_feeds.zig | 10 | Feed manager lifecycle |
| feed_flights.zig | 9 | Flight tracking feed |
| feed_vessels.zig | 7 | Vessel AIS feed |
| feed_satellites.zig | 7 | Satellite TLE propagation |
| feed_earthquakes.zig | 4 | Earthquake feed |
| feed_traffic.zig | 6 | Traffic feed |
| feed_cctv.zig | 8 | CCTV feed |
| hud.zig | 10 | HUD compass/coordinates/alerts |
| annotation.zig | 8 | Map annotations |
| scene_director.zig | 10 | Scene orchestration |
| voice_command.zig | 12 | Voice command parsing |
| detection_overlay.zig | 8 | Detection overlay |
| styles.zig | 9 | Styling system |
| **Total** | **152** | **16 geoview modules** |

## Data Assets

| Asset | Size | Purpose |
|-------|------|---------|
| `models/qwen1.5-0.5b-chat/` | 471MB | BPE tokenizer model (config, vocab, merges, ONNX) |
| `.foundations/RamseyLLM/vocabs/` | 23MB | Level-scaled vocab files (128k, 256k, 512k, 1m) |
| `qstar_corpus_full.qsc` | 551 MB | Full compressed corpus container — **default** for `chat`, `run`, `serve` (65,787,307 sentences across 2,785 pages, 2.92 GB raw) |
| `qstar_corpus.qsc` | 49 MB | Compressed corpus subset (earlier build, 4,779 pages) |
| `qstar_corpus.txt` | ~723 KB | Working raw-text corpus in this checkout |
| `qstar_corpus_large.txt` | 2.9 GB | Full raw corpus (symlink → `basic/qstar-llm/qstar_corpus.txt`, 65,787,307 lines, rebuilt from `.qsc` 2026-09-16) |
| `qstar_memory.json` | 210KB | Trained memory state (facts, scores, insights) |
| `turing_results.json` | 19KB | Turing test results (pass rates, category scores) |
| `datasets/Gov/` | 9MB | Governance docs (1,091 .md files: legal, ethics, financial, onboarding) |
| `datasets/AdmPaul/` | 15MB | AdmPaul corpus (83 files: sci-fi, governance, technical architecture) |
| `datasets/webster_dictionary/` | 27MB | Webster's Dictionary (6 files) |
| `datasets/blacks_law/` | 28KB | Black's Law Dictionary (3 files) |
| `datasets/general_knowledge/` | 24KB | General knowledge reference (5 files) |
| `datasets/wikipedia/` | 16KB | Wikipedia article extracts (3 files) |

Data assets are not tracked in git (see `.gitignore`). Download separately or copy from Qstar.

## Build Targets

| Command | Description |
|---------|-------------|
| `zig build` | Build example + CLI + WASM |
| `zig build test` | Run all unit tests (slow; prefer per-module `zig test` in development) |
| `zig build test-agent` | Run only agent tests (173) |
| `zig build test-main` | Run only main CLI tests |
| `zig build test-turing` | Run only turing_test tests |
| `zig build run` | Run example application |
| `zig build cli` | Run CLI binary |
| `zig build serve` | Run HTTP API server |
| `zig build manual` | Run manual integration tests |
| `zig build samc` | Run SAMC validation |
| `zig build audit` | Run agent dual-mode audit |
| `zig build ollama-bench` | Run head-to-head benchmark vs Ollama |
| `zig build competitive-bench` | Competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple) |
| `zig build qstar-bench` | Qstar-only standard benchmark with cross-judging |
| `zig build semantic-train` | Semantic training: OpenAI prompts + teacher responses |
| `zig build competitive-train` | 5-phase competitive training pipeline |
| `zig build training-heartbeat` | Training heartbeat (learn from JSON, compress corpus, push to Maple) |
| `zig build cognitive-metabench` | Deterministic cognitive-lane/promotion/cache routing metabench |
| `zig build meta-bench` | Metacognitive benchmark vs remote Ollama judge |
| `zig build maple-bench` | Maple device benchmark over LAN |
| `zig build maple-standard-bench` | Maple-only standard benchmark with cross-judging |
| `zig build vulkan-bench` | CPU vs Vulkan GPU inference benchmark |
| `zig build shaders` | Build Vulkan shaders (requires glslc) |
| `zig build tool-test` | Tool server integration tests |
| `zig build vision-test` | Vision pipeline tests |
| `zig build geoview-test` | Geoview pipeline tests |
| `zig build regression` | Full regression harness |
| `zig build wasm` | Build WASM module for browser embedding |
| `zig build corpus` | Build compressed `.qsc` corpus container from `qstar_corpus.txt` |
| `zig build html` | Build self-contained `universe.html` (WASM + corpus embedded) |
| `zig build master` | CI/CD gate: regression + build + publish quine payloads to `zig-out/master/` |
| `zig build seed` | Compress agent state to `zig-out/qstar_seed.bin` |

## Master Node (Quine Autoupdate)

This dev directory is the master node — the authoritative seed for any quine
edition. `zig build master` is the CI/CD gate: it runs the full regression
harness, builds `universe.html` + `.qsc` + WASM, writes `seed_manifest.json`
(version + SHA-256 hashes), and publishes all payloads to `zig-out/master/`.

Deployed quines autoupdate from the master over three channels:

- **HTTP (primary):** `qstar master-serve` serves the publish dir; the quine
  fetches `seed_manifest.json` on load and pulls new corpus (`qstar_corpus_distilled.txt`)
  or a new `universe.html` (capabilities/tools ride in the WASM). Pass `--dyndns`
  to update the ClouDNS dynamic DNS record on startup.
- **P2P (mirror):** `qstar master publish-p2p` publishes payloads into the qstar
  mesh via `qstar-net` bootstrap + `qstar-vfs` distributed storage, writing
  `p2p_index.json` for peer routing.
- **Browser bridge (WebRTC signaling + relay):** `master_server.zig` also serves
  `/api/signaling/*` (register/peers/offer/answer/ICE) so browser quines can
  discover P2P mirror nodes and exchange SDP/ICE, plus `/api/relay/<name>`
  (store-and-forward payload cache). The quine's autoupdate JS retries manifest/
  corpus/html pulls via the relay when the direct HTTP path is unavailable.
- **Dynamic DNS:** `qstar dns-update` performs a one-shot ClouDNS dynamic DNS
  update. The `dynamic_dns.zig` module is importable by all qstar.mesh projects.
  Configuration via `.env` (`DYNAMIC_DNS_URL`, `DYNAMIC_DNS_TIMEOUT_MS`,
  `DYNAMIC_DNS_RETRY_COUNT`, `DYNAMIC_DNS_RETRY_DELAY_MS`) or CLI flags
  (`--url`, `--timeout`, `--retries`, `--delay`). Python fallback:
  `dynamic-url-python.py` for cron use.

Offline quines degrade gracefully to their embedded corpus.

## Virtual Mesh Networking

Qstar-LLM includes a full virtualized transport layer over TCP (`virtual_transport.zig`) that wraps all 12 physical transport modes as virtual channels:

**Transport modes:** p2p, wifi, video, qr, polyglot, audio, stega, paper, optar, paperback, cassette, quine

**Fallback chain:** p2p → wifi → video → qr → polyglot → audio → stega → paper → optar → paperback → cassette → quine

**Features:**
- `VirtualMeshNode`: headless mesh peer that listens on TCP (port 9000), speaks the mesh protocol
- `VirtualTransportRouter`: selects best available transport mode, routes data through virtual channels
- Store-and-forward queue for disconnected peers (collapse recovery simulation)
- TCP connect/disconnect/sendRaw for real networking
- `runCycle()` event loop: accept connections, flush pending, check dead peers
- Civilization collapse simulation: degrades to paper/cassette/quine only
- Encoded payload format: magic + mode + length + FNV-1a checksum + data

**CLI commands:**
```bash
qstar transport list     # List all 12 transport modes and status
qstar mesh status        # Show mesh node status (peers, transport, collapse)
qstar collapse status    # Show civilization collapse simulation state
qstar mesh start         # Start mesh node TCP server (default port 9000)
```

**API endpoints:**
- `GET /api/mesh/status` — mesh node JSON status
- `GET /api/transport/list` — transport modes and fallback level

## Git Sync Topology

- **Master:** 192.168.12.3 (`/home/admpaul/CascadeProjects/basic/qstar-llm`)
- **Backup:** sheraton (`/home/ADMPaul/qstar-llm`)
- **Shared upstream:** USB bare repo (`/run/media/admpaul/Qstar-LLM/qstar-llm.git` on 192.168.12.3)
- **Version tag:** `v0.0.2.0` — current version of the qstar system set

## Documentation

| Document | Description |
|----------|-------------|
| `docs/ARCHITECTURE.md` | System architecture, module inventory, build targets |
| `docs/COMPONENT_DOCUMENTATION.md` | Per-module component documentation with line/test counts |
| `docs/API_REFERENCE.md` | API reference: agent, tools, server, vision, geoview |
| `docs/TOOLS_REFERENCE.md` | 58-tool registry reference |
| `docs/TESTING.md` | Testing strategy and suite inventory |
| `docs/DEVELOPMENT.md` | Development workflow and conventions |
| `docs/CAPABILITIES.md` | Capability matrix with proof |
| `docs/USE_CASE_AUDIT_REPORT.md` | Use case audit (169 use cases, all verified) |
| `docs/E2E_AUDIT_RESULTS.md` | End-to-end audit results (1,136 checks) |
| `docs/OPTIMIZATION_SUMMARY.md` | WASM/corpus/network optimization summary |
| `docs/RETRO_DEV_AUDIT.md` | Retro-dev audit trail (68 modules) |
| `docs/TRAINING_PIPELINE.md` | Training pipeline documentation |
| `docs/GODS_EYE_VIEW.md` | Geoview subsystem documentation |
| `docs/AXIOMS.md` | Lattice axioms |
| `docs/DATASETS.md` | Dataset inventory |
| `docs/TURBOQUANT_INTEGRATION.md` | TurboQuant integration notes |
| `docs/AGENT_OLLAMA_BENCHMARK.md` | Agent vs Ollama benchmark results |
| `docs/EU_V11_SYNTHESIS.md` | EU v11 analysis synthesis |

## Contributing

```bash
# Fork & clone
git clone https://github.com/ostffleetadmiral/qstar-ecosystem.git
cd qstar-ecosystem

# Create a feature branch
git checkout -b feature/my-change

# Build & test
zig build
zig build test

# Push & open a PR
git push origin feature/my-change
```

CI runs 12 jobs on every push and PR: unit tests (debug + release-safe), manual integration, SAMC validation, tool server, agent audit, vision pipeline, geoview pipeline, full regression, OpenAI smoke, WASM build, HTML build, and master node gate.

Tag-based releases trigger automatic artifact publishing (`release.yml`): `universe.html`, `qstar_llm.wasm`, `qstar_corpus_distilled.txt`, `seed_manifest.json`, `p2p_index.json`.

### Vendored Dependencies

The `deps/` directory contains 8 qstar sub-projects (qstar-net, qstar-vfs, qstar-mesh, qstar-collapse, qstar-compress, qstar-quantum, qstar-render, qstar-transport). These are vendored directly — no submodules.

## Origin

Extracted from Qstar — a lattice-native computing system. Qstar-LLM is fully standalone and does not depend on Qstar at build time. Shared dependencies (`fixed_point.zig`, `lattice.zig`) are copied, not linked. Prototype modules, test suites, data assets, and docs are ported from Qstar to ensure full self-sufficiency.

## License

Same as Qstar.
