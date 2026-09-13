# Qstar-LLM

[![CI](https://github.com/ostffleetadmiral/qstar-ecosystem/actions/workflows/ci.yml/badge.svg)](https://github.com/ostffleetadmiral/qstar-ecosystem/actions/workflows/ci.yml)

A lattice-native inference engine that replaces transformer-based LLMs with a 15³ grid of 421 E0 nodes × 7 channels (~47 KB state). All core arithmetic uses i128 Q64.64 fixed-point (i256 intermediates) — no floating-point in state paths. Hardware auto-detection selects optimal precision tier at comptime; Q64.64 states are downscaled to Q32.32 for Maple/ESP32/WASM peripherals. Zero external dependencies.

Includes self-training pipeline (Ollama or OpenAI teacher), internet training (Wikipedia API, 1,259 articles), dataset ingestion (Gov + AdmPaul), Turing test framework, 58-tool calling engine, native vision pipeline (face detection/recognition/tracking/gaze/anti-spoofing), geoview subsystem (globe rendering, live feeds, HUD, voice commands), Ollama-compatible HTTP server with concurrent request handling, streaming responses, and tok/s generation metrics, CLI binary with speculative draft mode and ecosystem commands (mesh, transport, collapse), WASM exports, holographic projection (S0↔S7), TurboQuant compression, SAMC accelerated reasoning, vocab lattice scaling, integer-only prototypes, competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple), quine-style compressed corpus container (.qsc), natural language generation engine with GenerationMetrics (tok/s, TTFT, prompt eval timing), 8-dimensional sentience scoring (self-awareness, direct experience, metacognition, situational awareness, random thought), Matrix15 text-to-scalar-field bridge, Ollama streaming client with advanced options (think, max_tokens, top_p, num_threads, keep_alive), virtual mesh networking over TCP with 12 transport modes and civilization collapse simulation, control experiment framework (baseline vs constrained metacognitive reflection), **Metacognition Engine** (always-on introspection, mid-generation correction, dynamic parameter adjustment), **Trivium Architecture** (Grammar/Logic/Rhetoric pipeline), **Quadrivium Architecture** (Arithmetic/Geometry/Music/Astronomy mathematical manifold), and **Lattice-Native Voice Codec** (VQ codebooks, NCA wave propagation, HDC speaker binding) — a fully standalone LLM application.

## What This Is

Qstar-LLM is the standalone extraction of Qstar's agent intelligence layer. The lattice IS the model — no transformer attention, no MLP, just octonion channel routing on a 3D grid.

**Key numbers:**

| Metric | Value |
|--------|-------|
| Agent state size | 47,152 bytes (47 KB, Q64.64) |
| Downscaled state | 23,576 bytes (23 KB, Q32.32 for peripherals) |
| Reference transformer | 75 MB (Qwen1.5-0.5B) |
| Size reduction | 3,243× |
| E0 nodes | 421 |
| Channels | 7 |
| Core arithmetic | i128 Q64.64 fixed-point (i256 intermediates) |
| External dependencies | 0 |
| Modules | 48 src + 12 vision + 16 geoview + 13 prototype |
| Tests | 1,720+ (src + vision + geoview + prototype + test-file) |
| Tool tests | 44 |
| Regression checks | 61 |
| Corpus | 327 MB raw, 3,999,383 sentences (110 MB .qsc) |
| Wikipedia articles | 1,259 titles across 13 batches |
| Dataset files | 2,177 (1,091 Gov + 83 AdmPaul + 1,003 reference) |
| WASM compatible | Yes |

## Quick Start

```bash
# Clone
git clone https://github.com/ostffleetadmiral/qstar-ecosystem.git
cd qstar-ecosystem

# Build the example + CLI binary
zig build

# Run all 1,720+ unit tests
zig build test

# Run tool server integration tests (44)
zig build tool-test

# Run vision pipeline tests (25)
zig build vision-test

# Run geoview pipeline tests (30)
zig build geoview-test

# Run full regression harness (61 checks)
zig build regression

# Run the basic inference demo
zig build run

# Run chat mode with a prompt
zig build run -- chat "Hello, what are you?"

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

# Train with OpenAI as teacher (requires OPENAI_API_KEY)
zig build cli -- train --teacher openai
zig build cli -- train --teacher ollama

# Master node: CI/CD gate — regression + build + publish quine payloads
zig build master

# Serve the master publish dir for quine autoupdates (HTTP channel)
zig build cli -- master-serve 11436

# Publish payloads into the qstar P2P mesh (mirror channel)
zig build cli -- master publish-p2p
```

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — Cognitive architecture overview (Metacognition Engine, Trivium, Quadrivium, Voice Codec)
- [API_REFERENCE.md](API_REFERENCE.md) — API reference for all new modules

## Usage as a Library

In your project's `build.zig`:

```zig
const llm_mod = b.addModule("qstar_llm", .{
    .root_source_file = b.path("libs/qstar-llm/src/agent.zig"),
    .target = target,
    .optimize = optimize,
});
// Wire sub-modules: bpe_tokenizer, sampling, state_store, face_sync,
// fixed_point, knowledge_graph, memory, perception, ollama_client,
// doc_loader, training, turing_test, tools, server, config, memory_pool,
// external_db, continual_learner, holographic
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

// Simulate network transfer: copy local → remote
for (0..7) |ch| {
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
| `agent.agentToSharedFaces(allocator, peer_id)` | Export activations as 7 SharedFaces |
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
| `trainDefault(agent, config, allocator)` | Train with 140 default prompts |
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
| `qstar chat` | Interactive multi-turn chat |
| `qstar call <tool> <args>` | Execute a tool directly |
| `qstar list` | List available models (Ollama-style) |
| `qstar show <model>` | Show model details (Ollama-style) |
| `qstar version` | Display version info |
| `qstar train` | Self-train using Ollama or OpenAI teacher (`--teacher <ollama|openai|auto>`) |
| `qstar train-internet` | Train by fetching Wikipedia articles |
| `qstar corpus build <raw> <out.qsc>` | Build compressed .qsc corpus container |
| `qstar corpus verify <corpus.qsc>` | Verify all pages (checksums + decompression) |
| `qstar corpus stream <corpus.qsc>` | Stream lines from compressed corpus |
| `qstar ingest-corpus <dir>` | Directly ingest .md/.txt/.tex documents into corpus |
| `qstar enrich-corpus <dir>` | Ollama-enriched corpus from documents |
| `qstar train-corpus` | Full pipeline: ingest + enrich all documents |
| `qstar turing-test` | Run automated Turing test with Ollama judge |
| `qstar experiment` | Run control experiment (baseline vs constrained metacognitive reflection) |
| `qstar kg query <entity>` | Query knowledge graph |
| `qstar start-heartbeat` | Start background continual learning |
| `qstar transport list` | List all 12 virtual transport modes and their status |
| `qstar mesh status` | Show virtual mesh node status (peers, transport, collapse) |
| `qstar collapse status` | Show civilization collapse simulation state |
| `qstar mesh-serve` | Start mesh node TCP server (port 9000) |

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

### Core Source Modules

| Module | Tests | Description |
|--------|-------|-------------|
| agent.zig | 167 | Core inference engine (E0, octonion, Fibonacci, φ-cooling, SAMC, creative routes, naturalness, retrieval, draft mode, 8-dim sentience scoring, Matrix15 bridge, control experiment framework, hardcoded factual response routes for 30+ common topics with poor corpus coverage, short-prompt routes for tokens bypassing keyword parser, E=mc² mass-energy equivalence route) |
| bpe_tokenizer.zig | 13 | Qwen1.5-compatible tokenization + Ramsey vocab scaling |
| sampling.zig | 11 | Top-k, top-p, temperature sampling |
| memory.zig | 4 | 3-layer cognitive memory |
| perception.zig | 31 | Activation detection, attention, liveness, introspection |
| knowledge_graph.zig | 6 | Triplet store with BFS traversal |
| state_store.zig | 4 | In-memory state persistence |
| face_sync.zig | 7 | Peer face sync |
| fixed_point.zig | 27 | Q32.32 integer arithmetic |
| lattice.zig | 49 | Lattice axioms (A1-A7) |
| ollama_client.zig | 19 | Zero-dep Ollama HTTP client + draft verification + streaming generation with advanced options |
| doc_loader.zig | 6 | Recursive document preprocessor |
| memory_pool.zig | 8 | Block pool + bump arena allocators |
| config.zig | 3 | Unified JSON configuration |
| external_db.zig | 2 | External database connector |
| continual_learner.zig | 5 | Background continual learning heartbeat |
| training.zig | 11 | Self-training (Ollama/OpenAI teacher) + internet training + dataset ingestion |
| openai_client.zig | 4 | Zero-dep OpenAI HTTP client (TLS HTTPS) |
| env_loader.zig | 3 | .env file loader for API keys |
| compress.zig | 10 | Self-contained compressor (dedup + gzip + lattice + RMSY) |
| corpus_store.zig | 5 | Quine-style .qsc corpus container with LRU page cache |
| turing_test.zig | 6 | Automated Turing test framework |
| tools.zig | 54 | 58-tool calling engine |
| server.zig | 19 | Ollama + OpenAI-compatible HTTP server (concurrent, streaming) |
| main.zig | 0 | CLI binary (serve, run, chat, train, experiment, transport, mesh, collapse, master-serve, publish-p2p) |
| wasm_exports.zig | 0 | WASM export bindings |
| holographic.zig | 34 | S0↔S7 holographic projection/compression |
| master_server.zig | 7 | Master node HTTP server + WebRTC signaling/relay bridge + dynamic DNS |
| master_publish.zig | 1 | Master payload publisher (zig-out/ → zig-out/master/) |
| p2p_update.zig | 3 | P2P mirror publish (qstar-net bootstrap + qstar-vfs placement) |
| dynamic_dns.zig | 16 | ClouDNS dynamic DNS updater (HTTPS, retry, env config) |
| build_html.zig | 2 | universe.html builder (WASM + distilled corpus embed, manifest) |
| virtual_transport.zig | 20 | Virtualized transport layer over TCP — 12 transport modes, mesh node, store-and-forward, collapse simulation |
| mesh.zig | 10 | Purified peer mesh — TransportMode enum, Location, ConnectionPool, OfflineTransportRouter |
| mesh_peer.zig | 4 | TCP-based mesh peer for Docker testing (XChaCha20-Poly1305 encryption) |
| collapse.zig | 3 | Civilization collapse resilience — QR portal encoding for physical transport |
| transport_p2p.zig | 2 | P2P packet transport (X25519 key exchange, ChaCha20Poly1305 encryption) |
| transport_wifi.zig | 3 | WiFi CSI frame transport (ADR-018 binary frame format) |
| transport_quine.zig | 2 | Self-referential HTML quine transport (base64 payload embedding) |
| transport_stega.zig | 3 | LSB steganography transport (AES-GCM encryption, PNG container) |
| transport_polyglot.zig | 2 | Multi-format polyglot file transport |
| transport_qr.zig | 2 | QR code portal transport |
| transport_audio.zig | 2 | Audio frequency encoding transport |
| transport_cassette.zig | 2 | Cassette tape audio transport |
| transport_video.zig | 2 | Video frame embedding transport |
| transport_paper.zig | 2 | Printed paper text/QR transport |
| transport_optar.zig | 2 | Optical art encoding transport |
| transport_paperback.zig | 2 | Paperback book format transport |
| transport_lora.zig | 2 | LoRa long-range radio transport |
| transport_convert.zig | 2 | Transport format conversion utilities |
| relay_router.zig | 2 | Multi-hop relay routing + rendezvous discovery |
| nat.zig | 2 | NAT traversal (UDP hole punching, WebRTC signaling, QR relay fallback) |
| webrtc.zig | 2 | WebRTC data channel protocol logic (SDP, ICE, DTLS, SCTP) |
| qr_nest.zig | 2 | Recursive QR nesting for multi-layer data transport |
| p2p_types.zig | 2 | P2P protocol type definitions |
| heartbeat.zig | 4 | Training heartbeat: corpus loading, memory/benchmark/Turing learning, generated prompts |
| prompt_generator.zig | 2 | Ollama-based random prompt generation for training |
| maple_client.zig | 2 | Maple protocol client for distributed corpus publishing |
| vulkan_compute.zig | 6 | Dynamic Vulkan loader + compute dispatch (optional GPU) |
| c_ffi.zig | 10 | C FFI bridge for vision/geoview (dlopen/dlsym pattern) |
| corpus_seed.zig | 2 | Corpus seed text for agent initialization (expanded with DS&A, primes, Orch Or, Trivium/Quadrivium) |
| corpus_seed_lite.zig | 1 | Lightweight corpus seed for WASM/embedded contexts |
| agent_lite.zig | 3 | Lightweight agent for WASM/embedded inference |
| metacognition_engine.zig | 19 | Always-on introspection, background thread, mid-generation correction, dynamic thresholding, parameter adjustment |
| trivium.zig | 15 | Grammar/Logic/Rhetoric pipeline — input parsing, lattice validation, output planning |
| quadrivium.zig | 17 | Arithmetic/Geometry/Music/Astronomy mathematical manifold processing |
| voice_codec.zig | 17 | Lattice-native voice codec: VQ codebooks, NCA wave propagation, HDC speaker binding, voice cloning pipeline |

### Prototype Modules

| Module | Tests | Description |
|--------|-------|-------------|
| discourse_agent.zig | 1 | Structured multi-paragraph discourse generation |
| turbo_quant.zig | 30 | TurboQuant vector quantization sidecar |
| samc_lattice.zig | 6 | SAMC lattice topology |
| samc_agent.zig | 2 | Multi-channel SAMC accelerated reasoning |
| vocab_loader.zig | 3 | Vocabulary file loader |
| vocab_lattice_scaling.zig | 25 | Level-scaled token-to-node mapping |
| lattice_context.zig | 2 | Lattice context management |
| agent_int.zig | 9 | Integer-only lattice inference prototype |
| holographic_int.zig | 8 | Integer holographic projection |
| quantum_int.zig | 15 | Integer quantum simulation |
| mesh_int.zig | 10 | Integer mesh networking |
| s0_projection.zig | 55 | S0→S7 holographic projection prototype |
| s7_compression.zig | 45 | S7→S0 lattice compression prototype |
| **Total** | **1,350+** | **60+ src + 12 vision + 16 geoview + 13 prototype modules + 15 test suites** |

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
| `qstar_corpus.txt` | 327 MB | Trained corpus (3,999,383 sentences, 1,155 Wikipedia articles + dataset ingestion + OpenAI teacher) |
| `zig-out/qstar_corpus.qsc` | 110 MB | Compressed quine-style corpus container (4,779 pages) |
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
| `zig build test` | Run all 1,268 unit tests |
| `zig build` | Build example + CLI + WASM |
| `zig build run` | Run example application |
| `zig build cli` | Run CLI binary |
| `zig build serve` | Run HTTP API server |
| `zig build manual` | Run manual integration tests |
| `zig build samc` | Run SAMC validation |
| `zig build audit` | Run agent dual-mode audit |
| `zig build ollama-bench` | Run head-to-head benchmark vs Ollama |
| `zig build competitive-bench` | Run competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple, all categories) |
| `zig build training-heartbeat` | Run training heartbeat cycle (corpus learning, memory, generated prompts) |
| `zig build qstar-bench` | Run Qstar internal benchmark suite |
| `zig build maple-bench` | Run Maple protocol benchmark |
| `zig build maple-standard-bench` | Run Maple standard benchmark |
| `zig build vulkan-bench` | Run Vulkan compute benchmark |
| `zig build shaders` | Build Vulkan shaders |
| `zig build tool-test` | Run tool server integration tests (44) |
| `zig build vision-test` | Run vision pipeline tests (25) |
| `zig build geoview-test` | Run geoview pipeline tests (30) |
| `zig build regression` | Run full regression harness (61 checks) |
| `zig build wasm` | Build WASM module for browser embedding |
| `zig build corpus` | Build compressed `.qsc` corpus container from `qstar_corpus.txt` |
| `zig build html` | Build self-contained `universe.html` with embedded WASM + corpus |
| `zig build master` | CI/CD gate: regression + build + publish quine payloads to `zig-out/master/` |

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
qstar mesh-serve         # Start mesh node TCP server
```

**API endpoints:**
- `GET /api/mesh/status` — mesh node JSON status
- `GET /api/transport/list` — transport modes and fallback level

## Git Sync Topology

- **Master:** 192.168.12.3 (`/home/admpaul/CascadeProjects/basic/qstar-llm`)
- **Backup:** sheraton (`/home/ADMPaul/qstar-llm`)
- **Shared upstream:** USB bare repo (`/run/media/admpaul/Qstar-LLM/qstar-llm.git` on 192.168.12.3)
- **Version tag:** `v0.0.0.1` — starting point of new qstar system set

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
