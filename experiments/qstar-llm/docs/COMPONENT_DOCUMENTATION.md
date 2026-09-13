# Qstar-LLM Component Documentation

**Version 3.4.0** | Zig 0.13.0+ | Zero external dependencies | 1,268 unit tests (647 src + 184 vision + 152 geoview + 211 prototype + 74 test-file) + 44 tool tests + 61 regression checks | Integer-only core state (i64 Q32.32)

## Overview

Qstar-LLM is a standalone lattice-native language model extracted from the Qstar computing system. It implements a 421-node × 7-channel octonion lattice as the core inference engine, with a 58-tool registry, native vision pipeline (12 modules), geoview subsystem (16 modules), self-training pipeline, and a zero-dependency HTTP server.

**Source map:** 39 core src files + 12 vision modules + 16 geoview modules + 13 prototype files + 15 test files → ~38,000 lines → 1,268 unit tests + 44 tool tests + 61 regression checks.

## Module Inventory

### Core Modules (`src/`)

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `agent.zig` | 8,742 | 167 | Lattice-native inference engine: E0 activation, trigram model, metacognition, memory, corpus, 8-dim sentience scoring, Matrix15 bridge, control experiment framework, hardcoded factual response routes for 30+ common topics, short-prompt routes, E=mc² mass-energy equivalence route |
| `lattice.zig` | 1,339 | 49 | 15³ lattice core: E0 node placement, octonion routing, φ-cooling, Ramsey scaling |
| `holographic.zig` | 1,128 | 34 | S0↔S7 holographic projection/compression, metasurface transform, RF fingerprint |
| `main.zig` | 1,798 | 0 | CLI entry point: run, chat, serve, train, experiment, geoview, ingest/enrich/train-corpus |
| `server.zig` | 1,642 | 19 | Zero-dependency HTTP API: Ollama/OpenAI-compatible endpoints, vision/geoview routes |
| `tools.zig` | 3,366 | 54 | 58-tool registry: math, lattice, quantum, KG, DB, file, HTTP, text, vision, geoview |
| `fixed_point.zig` | 714 | 27 | Q32.32 fixed-point math: φ-cooling, sigmoid table, SIMD mulVec4 |
| `bpe_tokenizer.zig` | 720 | 13 | BPE tokenizer with Ramsey vocab support (128k/256k/512k/1m) |
| `sampling.zig` | 475 | 11 | Token sampling: temperature, top-k, top-p, SAMC |
| `perception.zig` | 1,203 | 31 | Lattice-native perception: activation detection, attention, orientation, fingerprint |
| `memory.zig` | 402 | 4 | 3-layer cognitive memory: working, episodic, semantic |
| `knowledge_graph.zig` | 621 | 6 | Triple store: BFS, text extraction, persistence |
| `external_db.zig` | 142 | 2 | External DB connector: key-value, JSON, graph queries |
| `doc_loader.zig` | 440 | 6 | Document loading: text, markdown, JSON, code |
| `training.zig` | 1,234 | 11 | Self-training pipeline: Ollama/OpenAI teacher, Wikipedia fetch, corpus learning |
| `openai_client.zig` | 337 | 4 | Zero-dependency OpenAI HTTPS client (TLS, Chat Completions) |
| `env_loader.zig` | 104 | 3 | .env file loader for API keys (OPENAI_API_KEY, etc.) |
| `compress.zig` | 700 | 10 | Self-contained compressor: dedup + gzip + lattice transform + RMSY container |
| `corpus_store.zig` | 400 | 5 | Quine-style .qsc corpus container with LRU page cache |
| `turing_test.zig` | 717 | 6 | Turing test framework: 50 prompts, 7 categories, judge |
| `continual_learner.zig` | 351 | 5 | Background heartbeat, KG ingestion, continual learning |
| `ollama_client.zig` | 613 | 19 | Zero-dependency Ollama HTTP client with Content-Length parsing + streaming generation (think, max_tokens, top_p, num_threads, keep_alive) |
| `state_store.zig` | 221 | 4 | Agent state persistence |
| `face_sync.zig` | 279 | 7 | SharedFace sync bridge |
| `config.zig` | 88 | 3 | Unified configuration |
| `memory_pool.zig` | 218 | 8 | Arena-based memory pool with reset |
| `vulkan_compute.zig` | 958 | 6 | Dynamic Vulkan loader + compute dispatch (optional GPU) |
| `c_ffi.zig` | 202 | 10 | C FFI bridge for vision/geoview |
| `build_html.zig` | 110 | 0 | universe.html builder with embedded WASM |
| `wasm_exports.zig` | 247 | 0 | WASM export surface for browser embedding |
| `heartbeat.zig` | 680 | 4 | Training heartbeat: corpus loading, memory/benchmark/Turing learning, generated prompts |
| `prompt_generator.zig` | 160 | 2 | Ollama-based random prompt generation for training |
| `maple_client.zig` | 140 | 2 | Maple protocol client for distributed corpus publishing |
| `master_server.zig` | 649 | 7 | Master node HTTP server + WebRTC signaling/relay bridge |
| `master_publish.zig` | 81 | 1 | Master payload publisher (zig-out/ → zig-out/master/) |
| `p2p_update.zig` | 256 | 3 | P2P mirror publish (qstar-net bootstrap + qstar-vfs placement) |
| `corpus_seed.zig` | 120 | 2 | Corpus seed text for agent initialization |
| `corpus_seed_lite.zig` | 80 | 1 | Lightweight corpus seed for WASM/embedded contexts |
| `agent_lite.zig` | 200 | 3 | Lightweight agent for WASM/embedded inference |

### Vision Modules (`src/vision/`)

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `image.zig` | 743 | 20 | Image I/O, resize, color space, pixel ops |
| `onnx_runtime.zig` | 710 | 11 | ONNX model runtime (native, no external deps) |
| `face_track.zig` | 647 | 16 | Face tracking: IoU matching, ID persistence |
| `face_landmark.zig` | 597 | 19 | 68-point landmark detection |
| `face_analyzer.zig` | 558 | 13 | Unified face analysis pipeline |
| `face_detect.zig` | 552 | 16 | Face detection: NMS, confidence scoring |
| `face_recognize.zig` | 549 | 21 | Face recognition: embeddings, cosine similarity |
| `face_parsing.zig` | 402 | 13 | Face parsing: region segmentation |
| `anti_spoofing.zig` | 378 | 16 | Liveness/spoofing detection |
| `face_quality.zig` | 342 | 12 | Face quality scoring |
| `gaze_headpose.zig` | 330 | 13 | Gaze estimation + head pose (6-DOF) |
| `face_attributes.zig` | 323 | 14 | Attribute prediction: age, gender, emotion |

### Geoview Modules (`src/geoview/`)

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `globe_render.zig` | 699 | 14 | Ellipsoid mesh generation, globe rendering |
| `geo_math.zig` | 687 | 16 | LLA/ECEF/ENU/MGRS transforms, great-circle math |
| `camera.zig` | 584 | 14 | Camera controls: orbit, fly-to, inertial |
| `feed_satellites.zig` | 446 | 7 | Satellite TLE propagation feed |
| `feed_flights.zig` | 381 | 9 | Flight tracking feed |
| `detection_overlay.zig` | 387 | 8 | Detection overlay rendering |
| `feed_cctv.zig` | 300 | 8 | CCTV feed integration |
| `feed_earthquakes.zig` | 280 | 4 | Earthquake feed |
| `feed_vessels.zig` | 326 | 7 | Vessel AIS feed |
| `feed_traffic.zig` | 336 | 6 | Traffic feed |
| `live_feeds.zig` | 348 | 10 | Feed manager lifecycle |
| `hud.zig` | 466 | 10 | HUD: compass, coordinates, alerts |
| `annotation.zig` | 332 | 8 | Map annotations |
| `scene_director.zig` | 340 | 10 | Scene orchestration |
| `voice_command.zig` | 330 | 12 | Voice command parsing |
| `styles.zig` | 256 | 9 | Styling system |

### Prototype Modules (`prototype/`)

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `s0_projection.zig` | 2,318 | 55 | S0↔S7 projection with f64 sidecar precision |
| `s7_compression.zig` | 1,862 | 45 | S7→S0 lattice compression prototype |
| `turbo_quant.zig` | 1,175 | 30 | TurboQuant: rotation + Lloyd-Max quantization |
| `vocab_lattice_scaling.zig` | 920 | 25 | Ramsey vocab × lattice scaling |
| `quantum_int.zig` | 730 | 15 | Quantum gate model integration |
| `holographic_int.zig` | 567 | 8 | Holographic compute integration |
| `agent_int.zig` | 481 | 9 | Agent integration tests |
| `samc_lattice.zig` | 403 | 6 | SAMC lattice relaxation |
| `mesh_int.zig` | 292 | 10 | Mesh integration |
| `samc_agent.zig` | 262 | 2 | SAMC agent integration |
| `vocab_loader.zig` | 194 | 3 | Vocab file loader |
| `lattice_context.zig` | 139 | 2 | Lattice context |
| `discourse_agent.zig` | 120 | 1 | Discourse agent |

### Test Suites (`tests/`)

| Suite | Lines | Tests | Purpose |
|-------|------:|------:|---------|
| `competitive_bench.zig` | 1,146 | 18 | Competitive benchmark (Qstar vs Ollama vs OpenAI vs Maple) |
| `vision_test.zig` | 597 | 25 | Vision pipeline integration tests |
| `geoview_test.zig` | 589 | 30 | Geoview pipeline integration tests |
| `audit_agent.zig` | 488 | 0 | Agent dual-mode audit (manual) |
| `full_regression.zig` | 455 | 34 checks | Full regression harness (12 steps) |
| `ollama_benchmark.zig` | 484 | 0 | Ollama benchmark (manual) |
| `manual_s0_projection.zig` | 380 | 0 | S0 projection manual verification |
| `manual_s7_compression.zig` | 290 | 0 | S7 compression manual verification |
| `manual_agent.zig` | 193 | 0 | Agent manual verification |
| `prototype_samc_test.zig` | 194 | 0 | SAMC prototype validation |
| `manual_vocab_scaling.zig` | 146 | 0 | Vocab scaling manual verification |
| `tool_server_test.zig` | 120 | 44 tool tests | Tool server integration tests |
| `vulkan_benchmark.zig` | 119 | 0 | Vulkan benchmark (manual) |

---

## Core Component Details

### 1. `agent.zig` — Lattice-Native Inference Engine

**File:** `src/agent.zig` — 8,742 lines, 167 tests, imports `fixed_point`, `bpe_tokenizer`, `sampling`, `memory`, `knowledge_graph`

The agent is the lattice itself, not an external observer. Thought = E0 node firing (42 bits), memory = lattice activation, attention = 6D Jordan channel.

**Key structures:**
- `AgentState` — 421 E0 nodes × 7 channels of i64 Q32.32 activations (23,576 bytes)
- `Agent` — state + dynamic corpus + RNG + metacognition + working memory
- `Metacognition` — self-model, evaluation, reflection
- `WorkingMemory` — 20-entry working memory with key facts and context

**Key functions:**
- `init()` / `initDeterministic()` — agent construction (deterministic mode for testing)
- `ingest()` — tokenize + activate E0 nodes
- `step()` / `sampledStep()` — lattice evolution with φ-cooling
- `activationsToLogits()` — sparse logit projection (2,947 pairs, not 151,936 tokens)
- `learnFromText()` — corpus learning with dedup and 500MB guard
- `naturalizeText()` — contraction expansion post-processor
- `introspect()` / `evaluateResponse()` (8 dimensions) / `generateWithReflection()` — metacognition
- `scoreSelfAwareness()`, `scoreDirectExperience()`, `scoreMetacognition()`, `scoreSituationalAwareness()`, `scoreRandomThought()` — sentience scoring
- `Matrix15` / `encodeTextToMatrix()` / `matrixNorm()` / `matrixCosineSimilarity()` — text-to-scalar-field bridge
- `evaluateCondition()` / `compareConditions()` / `joinResponses()` — control experiment framework
- `setLevel()` / Autoscaler — Ramsey vocab × lattice scaling

**Test coverage (167 tests):** determinism, state size, BPE ingest, trigram model, topic categories, naturalness, metacognition, working memory, corpus learning, scaling, sentience scoring, Matrix15 bridge, control experiment framework.

### 2. `lattice.zig` — Core Lattice

**File:** `src/lattice.zig` — 1,339 lines, 49 tests, zero deps

**Key constants:**
- `BASE_EDGE = 15` — 15³ grid, 3,375 cells
- `E0_NODE_COUNT = 421` — E0 nodes where (x+y+z) % 3 == 0
- `CHANNEL_COUNT = 7` — octonion channels (e0-e6)
- Fano plane multiplication table

**Key functions:**
- `e0NodeIndex()` — (x·7 + y·11 + z·13) % 421 routing
- `computeEValue()` — octonion routing index
- `isBoundaryCoord()` — Möbius twist boundary detection
- `scaledNodeCount(level)` — 421 × 8^s qubit scaling
- `scaledTokenToNode()` / `scaledTokenToChannel()` — Ramsey vocab mapping

### 3. `fixed_point.zig` — Q32.32 Fixed-Point Math

**File:** `src/fixed_point.zig` — 714 lines, 27 tests, zero deps

- Q32.32 i64 arithmetic with i128 intermediates
- `phiCool()` — φ-cooling temperature schedule via lookup table
- `sigmoid()` — lookup table with saturation
- `mulVec4()` — SIMD 4-lane multiply matching scalar
- Trigonometric lookups, saturating arithmetic, Taylor/Padé exponential

### 4. `tools.zig` — 58-Tool Registry

**File:** `src/tools.zig` — 3,366 lines, 54 tests

**Tool categories:**
- **Core (37):** calculate, lattice_node, quantum_simulate, kg_query, db_query, external_search, file_read, file_write, file_list, http_fetch, shell_exec, time_now, uuid_generate, base64_encode, base64_decode, hash_compute, json_validate, json_format, string_replace, text_summarize, word_count, sentiment_analyze, ner_extract, text_classify, text_diff, language_detect, wikipedia_lookup, dictionary_lookup, law_lookup, rag_search, kg_add_triplet, kg_export, stats_compute, csv_parse, data_sort, data_filter, histogram_generate, correlation_compute
- **Vision (6):** face_detect, face_recognize, face_analyze, face_track, gaze_estimate, emotion_detect
- **Geoview (9):** geo_distance, geo_convert, geo_mgrs, geo_bearing, geo_destination, globe_query, track_flight, track_vessel, track_satellite
- **Geoview feeds (5):** earthquake_query, cctv_query, hud_control, scene_play, annotation_add

**Key functions:**
- `registerBuiltins()` — registers all 58 tools
- `execute()` — tool dispatch with JSON params
- `parseToolCall()` — XML tool_call markup parsing
- `attachKnowledgeGraph()` / `attachExternalDb()` — dependency injection

### 5. `server.zig` — HTTP API Server

**File:** `src/server.zig` — 1,642 lines, 19 tests

**Endpoints:**
- Ollama-compatible: `/api/generate`, `/api/chat`, `/api/tags`, `/api/version`, `/api/embeddings`
- OpenAI-compatible: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`
- Vision: `/api/vision`, `/api/vision/tools`
- Geoview: `/api/geoview`, `/api/geoview/tools`

**Features:** ArenaAllocator per-request, request batching, agent pool, speculative draft mode, tool calling.

### 6. `perception.zig` — Lattice-Native Perception

**File:** `src/perception.zig` — 1,203 lines, 31 tests

- `detectActivations()` — sliding-window activation detection with NMS
- `estimateAttention()` — 2-DOF attention angle from activation distribution
- `estimateOrientation()` — 3-DOF lattice rotation from E0 node distribution
- `fingerprintState()` — fixed-dim embedding from lattice state
- `livenessCheck()` — peer liveness verification

### 7. `holographic.zig` — Holographic Compute

**File:** `src/holographic.zig` — 1,128 lines, 34 tests

- `latticeFFT()` / `latticeIFFT()` — 3D FFT with e-value twiddle factors
- `latticeConvolution()` — frequency-domain convolution
- `holographicEncode()` / `holographicDecode()` — frequency-domain state storage
- `rfFingerprint()` — 128-dim L2-normalized fingerprint
- `metasurfaceTransform()` — programmable surface simulation

---

## Vision Pipeline

The vision pipeline implements lattice-native face analysis: detect → align → recognize → predict attributes, with spoofing resistance.

**Pipeline stages:**
1. `face_detect` — sliding-window detection with NMS
2. `face_landmark` — 68-point landmark extraction
3. `face_recognize` — 128-dim embedding + cosine similarity
4. `face_analyzer` — unified pipeline orchestration
5. `gaze_headpose` — attention direction + 6-DOF head pose
6. `face_attributes` — age/gender/emotion prediction
7. `face_quality` — image quality scoring
8. `anti_spoofing` — liveness detection
9. `face_track` — IoU-based multi-face tracking
10. `face_parsing` — region segmentation
11. `image` — image I/O and pixel ops
12. `onnx_runtime` — native ONNX model runtime

**Integration:** 6 vision tools registered in `tools.zig`; `/api/vision` endpoints in `server.zig`; `vision-test` suite (25 tests).

## Geoview Subsystem

The geoview subsystem provides real-time Earth observation: globe rendering, live feeds, coordinate transforms, and HUD.

**Components:**
1. `globe_render` — ellipsoid mesh generation
2. `geo_math` — LLA/ECEF/ENU/MGRS transforms
3. `camera` — orbit/fly-to/inertial camera
4. `live_feeds` — feed manager (flights, vessels, satellites, earthquakes, traffic, CCTV)
5. `hud` — compass, coordinates, alerts
6. `annotation` — map annotations
7. `scene_director` — scene orchestration
8. `voice_command` — voice command parsing
9. `detection_overlay` — detection rendering
10. `styles` — styling system

**Integration:** 14 geoview tools registered in `tools.zig`; `/api/geoview` endpoints in `server.zig`; `geoview-test` suite (30 tests).

## Prototype Modules

Prototype modules implement experimental algorithms with full test coverage:

- **`s0_projection.zig`** (55 tests) — S0↔S7 projection with f64 sidecar precision, fixing integer-truncation loss
- **`s7_compression.zig`** (45 tests) — S7→S0 lattice compression with seed extraction strategies
- **`turbo_quant.zig`** (30 tests) — TurboQuant rotation + Lloyd-Max quantization (2-bit/4-bit)
- **`vocab_lattice_scaling.zig`** (25 tests) — Ramsey vocab × lattice scaling
- **`quantum_int.zig`** (15 tests) — quantum gate model integration
- **`mesh_int.zig`** (10 tests) — mesh integration
- **`agent_int.zig`** (9 tests) — agent integration
- **`holographic_int.zig`** (8 tests) — holographic integration
- **`samc_lattice.zig`** (6 tests) — SAMC lattice relaxation
- **`vocab_loader.zig`** (3 tests) — vocab loading
- **`samc_agent.zig`** (2 tests) — SAMC agent
- **`lattice_context.zig`** (2 tests) — lattice context
- **`discourse_agent.zig`** (1 test) — discourse agent

## Test Coverage Summary

| Category | Tests |
|----------|------:|
| Core src modules | 647 |
| Vision modules | 184 |
| Geoview modules | 152 |
| Prototype modules | 211 |
| Test-file suites | 74 |
| **Unit test total** | **1,268** |
| Tool tests (`tool-test`) | 44 |
| Regression checks (`regression`) | 61 |
| **Total verification** | **1,373** |

## Build Targets

| Target | Purpose |
|--------|---------|
| `zig build` | Build native binary |
| `zig build test` | Run all unit tests (1,268) |
| `zig build tool-test` | Tool server integration tests (44) |
| `zig build vision-test` | Vision pipeline tests (25) |
| `zig build geoview-test` | Geoview pipeline tests (30) |
| `zig build regression` | Full regression harness (61 checks) |
| `zig build manual` | Manual verification suites |
| `zig build samc` | SAMC prototype validation |
| `zig build audit` | Agent dual-mode audit |
| `zig build wasm` | Build WASM module |
| `zig build html` | Build self-contained universe.html |
| `zig build cli` | CLI entry point |
| `zig build ollama-bench` | Ollama benchmark |
| `zig build competitive-bench` | Competitive benchmark (Qstar vs Ollama vs OpenAI vs Maple) |
