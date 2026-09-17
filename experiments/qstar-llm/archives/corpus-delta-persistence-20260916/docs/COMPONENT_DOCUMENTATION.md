# Qstar-LLM Component Documentation

**Version 3.5.0** | Zig 0.13.0+ | Zero external dependencies (core) | 2,536 src tests + 74 test-file tests = ~2,610 total | Integer-only state (Q64.64 lattice + Q128.128 semantic layer)

## Overview

Qstar-LLM is a standalone lattice-native language model extracted from the Qstar computing system. It implements a 421-node × 8-channel octonion lattice as the core inference engine (53,888-byte state), with a 58-tool registry, native vision pipeline (12 modules), geoview subsystem (16 modules), self-training pipeline, optional neural-LM/llama-server fallback sidecars, and a zero-dependency HTTP server.

**Source map:** 129 core src files + 12 vision modules + 16 geoview modules + 19 test files → ~92,700 lines → 2,536 unit tests + 74 test-file tests + 66 regression checks.

## Module Inventory

### Core Modules (`src/`)

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `agent.zig` | 12,053 | 173 | Lattice-native inference engine: E0 activation, Fano routing, metacognition, memory, corpus, sentience scoring, Matrix15 bridge, control experiment, tool-call processing |
| `lattice.zig` | 1,448 | 56 | 15³ lattice core: E0 node placement, octonion routing, φ-cooling, Fano plane, Ramsey scaling |
| `agent_lite.zig` | 1,449 | 55 | Lightweight agent for WASM/embedded (7-channel) |
| `main.zig` | 3,281 | 29 | CLI entry point: 34 commands |
| `server.zig` | 1,932 | 19 | Zero-dependency HTTP API: Ollama/OpenAI-compatible endpoints, vision/geoview routes |
| `tools.zig` | 3,681 | 66 | 58-tool registry: math, lattice, quantum, KG, DB, file, HTTP, text, vision, geoview |
| `q128.zig` | 1,030 | 35 | Q128.128 fixed-point: i256 values, i512 intermediates, RNE multiply |
| `fixed_point.zig` | 1,121 | 55 | Q64.64 fixed-point: i128 values, i256 intermediates |
| `fixed_point32.zig` | 327 | 10 | Q32.32 fixed-point: i64 values, i128 intermediates (peripherals) |
| `fp_bridge.zig` | 210 | 13 | Q64.64 → Q32.32 downscale bridge |
| `precision_scaler.zig` | 188 | 6 | Comptime precision-tier selection |
| `hardware_detect.zig` | 525 | 15 | Hardware capability detection for tier selection |
| `bpe_tokenizer.zig` | 746 | 14 | BPE tokenizer with Ramsey vocab support (128k/256k/512k/1m) |
| `sampling.zig` | 547 | 15 | Token sampling: temperature, top-k, top-p |
| `perception.zig` | 1,277 | 37 | Lattice-native perception: activation detection, attention, orientation, fingerprint |
| `memory.zig` | 430 | 5 | 3-layer cognitive memory: working, episodic |
| `knowledge_graph.zig` | 723 | 7 | Triple store: BFS, text extraction, persistence |
| `external_db.zig` | 168 | 3 | External DB connector: key-value, JSON, graph queries |
| `doc_loader.zig` | 790 | 16 | Document loading: text, markdown, JSON, code |
| `training.zig` | 3,190 | 26 | Self-training pipeline: Ollama/OpenAI/hybrid teachers, Wikipedia fetch, corpus learning, failure-window training |
| `openai_client.zig` | 364 | 13 | Zero-dependency OpenAI HTTPS client (TLS, Chat Completions) |
| `env_loader.zig` | 210 | 10 | .env file loader for API keys |
| `compress.zig` | 688 | 11 | Self-contained compressor: dedup + gzip + lattice transform + RMSY container |
| `corpus_store.zig` | 536 | 7 | Quine-style .qsc corpus container with LRU page cache |
| `turing_test.zig` | 849 | 6 | Turing test framework |
| `continual_learner.zig` | 448 | 7 | Background heartbeat, KG ingestion, continual learning |
| `ollama_client.zig` | 664 | 20 | Zero-dependency Ollama HTTP client + draft verification + streaming |
| `state_store.zig` | 247 | 5 | Agent state persistence |
| `face_sync.zig` | 305 | 8 | SharedFace sync bridge (8 faces, one per channel) |
| `config.zig` | 114 | 4 | Unified configuration |
| `memory_pool.zig` | 244 | 9 | Arena-based memory pool with reset |
| `vulkan_compute.zig` | 1,217 | 9 | Dynamic Vulkan loader + compute dispatch (7-channel GPU prototype path) |
| `c_ffi.zig` | 228 | 11 | C FFI bridge for vision/geoview (dlopen/dlsym) |
| `build_html.zig` | 474 | 3 | universe.html builder with embedded WASM |
| `wasm_exports.zig` | 290 | 1 | WASM export surface for browser embedding |
| `heartbeat.zig` | 755 | 9 | Training heartbeat: corpus loading, memory/benchmark/Turing learning, generated prompts |
| `prompt_generator.zig` | 197 | 4 | Ollama-based random prompt generation |
| `maple_client.zig` | 310 | 2 | Maple protocol client for distributed corpus publishing |
| `master_server.zig` | 686 | 8 | Master node HTTP server + WebRTC signaling/relay bridge |
| `master_publish.zig` | 107 | 2 | Master payload publisher |
| `p2p_update.zig` | 288 | 5 | P2P mirror publish (qstar-net bootstrap + qstar-vfs) |
| `corpus_seed.zig` | 767 | 7 | Corpus seed text for agent initialization |
| `corpus_seed_lite.zig` | 136 | 6 | Lightweight corpus seed for WASM/embedded contexts |
| `llama_server.zig` | 683 | 18 | llama-server streaming fallback (`/no_think` creative fast path) |
| `neural_lm.zig` | 450 | 4 | Neural LM integration (Qwen3-0.6B ONNX) |
| `llm_provider.zig` | 251 | 7 | Provider abstraction over external LLMs |
| `kimi_stream_adapter.zig` | 162 | 3 | Kimi streaming API adapter |
| `corpus_learner.zig` | 563 | 9 | Corpus ingestion and learning |
| `metacognition_engine.zig` | 2,057 | 25 | Always-on introspection, mid-generation correction, dynamic thresholding (Q128.128) |
| `trivium.zig` | 812 | 16 | Grammar/Logic/Rhetoric pipeline |
| `quadrivium.zig` | 542 | 18 | Arithmetic/Geometry/Music/Astronomy manifold |
| `dynamic_routes.zig` | 967 | 17 | Learned response routes with evaluation feedback |
| `cognitive_lanes.zig` | 280 | 5 | Explicit/implicit candidate promotion lanes |
| `cognitive_cloud.zig` | 544 | 11 | Distributed cognition primitives |
| `routing_calibration.zig` | 102 | 3 | Route confidence calibration |
| `arithmetic_reasoner.zig` | 103 | 3 | Integer arithmetic reasoning |
| `knowledge_lookup.zig` | 77 | 2 | Factual lookup layer |
| `sentience_scorer.zig` | 610 | 21 | 8-dimension sentience scoring |
| `sentience_experiment.zig` | 414 | 20 | Control experiment framework |
| `voice_codec.zig` | 855 | 18 | Lattice-native voice codec (VQ, NCA wave, HDC speaker binding — internal 7-channel layout) |
| `holographic.zig` | 1,154 | 35 | S0↔S7 holographic projection/compression |
| `holographic_memory.zig` | 596 | 10 | Holographic memory encoding |
| `holo_codec.zig` | 1,009 | 16 | Holographic codec |
| `s0_projection.zig` | 2,348 | 55 | S0→S7 holographic projection |
| `s7_compression.zig` | 1,875 | 45 | S7→S0 lattice compression |
| `turbo_quant.zig` | 1,327 | 33 | TurboQuant vector quantization sidecar |
| `seed_compressor.zig` | 570 | 8 | Agent-state seed compression |
| `lattice_compressor.zig` | 393 | 8 | Lattice activation compression |
| `distillation_s0.zig` | 381 | 9 | S0 corpus distillation |
| `vocab_lattice_scaling.zig` | 920 | 25 | Level-scaled token-to-node mapping |
| `octonion_math.zig` | 537 | 26 | Octonion multiplication, Fano structure |
| `bi_complex.zig` | 599 | 31 | Bi-complex numbers (5D language algebra) |
| `jordan_algebra.zig` | 507 | 22 | J₃(O) Jordan algebra (6D self-model) |
| `so10.zig` | 335 | 20 | SO(10) decomposition |
| `e8_roots.zig` | 355 | 16 | E8 root system |
| `quantum.zig` | 1,272 | 37 | Integer quantum simulation |
| `entangle.zig` | 1,253 | 33 | Entanglement/correlation primitives |
| `codon.zig` | 1,255 | 32 | 64-codon genetic-code routing |
| `dim_0d_origin.zig` | 89 | 5 | 0D origin/seed |
| `dim_1d_time.zig` | 114 | 5 | 1D temporal ordering |
| `dim_2d_complex.zig` | 134 | 9 | 2D complex-plane structure |
| `dim_3d_space.zig` | 120 | 6 | 3D spatial grid (15³) |
| `dim_4d_rotation.zig` | 166 | 11 | 4D quaternion rotation |
| `dim_5d_language.zig` | 368 | 15 | 5D bi-complex language/attention |
| `dim_6d_consciousness.zig` | 466 | 14 | 6D Jordan self-model, metacognition |
| `dim_7d_color.zig` | 105 | 5 | 7D octonionic channel routing |
| `dim_8d_frequency.zig` | 180 | 10 | 8D φ-cooling frequency scaling |
| `dim_9d_chaos.zig` | 136 | 9 | 9D stochastic perturbation |
| `dim_10d_gravity.zig` | 182 | 9 | 10D dual-bi-complex coupling closure |
| `mesh.zig` | 2,090 | 65 | Peer mesh: TransportMode, ConnectionPool, OfflineTransportRouter |
| `virtual_transport.zig` | 1,000 | 26 | Virtualized transport over TCP — 12 modes, collapse simulation |
| `mesh_peer.zig` | 737 | 7 | TCP mesh peer (XChaCha20-Poly1305) |
| `p2p_types.zig` | 966 | 40 | P2P protocol type definitions |
| `qr_nest.zig` | 823 | 23 | Recursive QR nesting |
| `relay_router.zig` | 795 | 25 | Multi-hop relay + rendezvous discovery |
| `nat.zig` | 798 | 19 | NAT traversal (UDP hole punching, WebRTC signaling) |
| `transport_lora.zig` | 865 | 24 | LoRa long-range radio transport |
| `transport_polyglot.zig` | 600 | 24 | Multi-format polyglot file transport |
| `collapse.zig` | 608 | 16 | Collapse resilience — QR portal encoding |
| `collapse_resilience.zig` | 408 | 8 | State preservation through digital failure |
| `collapse_recover.zig` | 318 | 9 | Post-collapse peer recovery |
| `merge.zig` | 575 | 14 | State merge/conflict resolution |
| `sybil.zig` | 574 | 14 | Sybil-resistance identity verification |
| `dynamic_dns.zig` | 375 | 20 | ClouDNS dynamic DNS updater |
| `webrtc.zig` | 330 | 12 | WebRTC data channel protocol |
| `transport_paperback.zig` | 258 | 8 | Paperback book format transport |
| `transport_p2p.zig` | 252 | 8 | P2P packet transport (X25519, ChaCha20Poly1305) |
| `transport_convert.zig` | 237 | 8 | Transport format conversion |
| `transport_optar.zig` | 233 | 7 | Optical art encoding transport |
| `transport_qr.zig` | 230 | 8 | QR code portal transport |
| `transport_cassette.zig` | 197 | 5 | Cassette tape audio transport |
| `transport_audio.zig` | 192 | 5 | Audio frequency encoding transport |
| `transport_stega.zig` | 192 | 6 | LSB steganography (AES-GCM, PNG) |
| `transport_video.zig` | 172 | 6 | Video frame embedding transport |
| `transport_wifi.zig` | 136 | 6 | WiFi CSI frame transport (ADR-018) |
| `transport_quine.zig` | 135 | 5 | Self-referential HTML quine transport |
| `hw_bridge.zig` | 594 | 22 | Hardware bridge layer |
| `hw_elevation_paths.zig` | 801 | 28 | Self-claim elevation paths |
| `hw_jordan_algebra.zig` | 575 | 23 | J₃(O) hardware implementation |
| `hw_scaling_analysis.zig` | 487 | 16 | Cubic scaling chain verification |
| `hw_surface_computation.zig` | 393 | 21 | Surface computation hardware path |
| `hw_generative_chain.zig` | 374 | 15 | 0^0=i generative bootstrap |
| `hw_consciousness_audit.zig` | 313 | 8 | Consciousness causal-chain audit |
| `hw_self_claims.zig` | 309 | 15 | Self-claim verification |
| `hw_e8_roots.zig` | 289 | 11 | E8 roots hardware path |
| `hw_electric_charges.zig` | 287 | 10 | Octonion U(1) charges |
| `hw_final_audit.zig` | 281 | 9 | Final audit classification |
| `hw_literature_review.zig` | 260 | 12 | Literature reference verification |
| `hw_octonion.zig` | 210 | 11 | Octonion hardware primitives |

### Vision Modules (`src/vision/`)

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `image.zig` | 743 | 20 | Image I/O, resize, color space, pixel ops |
| `onnx_runtime.zig` | 710 | 11 | ONNX model runtime bindings (dlopen) |
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

### Test Suites (`tests/`)

| Suite | Purpose |
|-------|---------|
| `full_regression.zig` | Full regression harness (66 checks) |
| `competitive_bench.zig` | Competitive benchmark (Qstar vs Ollama vs OpenAI vs Maple) |
| `meta_bench.zig` | Metacognitive benchmark vs Ollama judge |
| `vision_test.zig` | Vision pipeline integration tests |
| `geoview_test.zig` | Geoview pipeline integration tests |
| `audit_agent.zig` | Agent dual-mode audit |
| `manual_agent.zig` | Agent manual verification |
| `ollama_benchmark.zig` | Ollama benchmark (manual) |
| `tool_server_test.zig` | Tool server integration tests |
| `vulkan_benchmark.zig` | Vulkan benchmark (manual) |
| `manual_s0_projection.zig` | S0 projection manual verification |
| `manual_s7_compression.zig` | S7 compression manual verification |
| `manual_vocab_scaling.zig` | Vocab scaling manual verification |
| + 6 more | (see `tests/` directory) |

---

## Core Component Details

### 1. `agent.zig` — Lattice-Native Inference Engine

**File:** `src/agent.zig` — 12,053 lines, 173 tests, imports `fixed_point`, `q128`, `bpe_tokenizer`, `sampling`, `memory`, `knowledge_graph`, `neural_lm`, `llama_server`, `jordan_algebra`, dimensional modules, `cognitive_lanes`, `arithmetic_reasoner`, `knowledge_lookup`, `trivium`, `quadrivium`, `metacognition_engine`, `dynamic_routes`

The agent is the lattice itself, not an external observer. Thought = E0 node firing, memory = lattice activation, attention = 6D Jordan channel.

**Key structures:**
- `AgentState` — 421 E0 nodes × 8 channels of i128 Q64.64 activations (53,888 bytes)
- `Agent` — state + dynamic corpus + RNG + metacognition + working memory
- `Metacognition` (metacognition_engine) — self-model, evaluation, reflection (Q128.128 scores)
- `WorkingMemory` — 20-entry working memory with key facts and context

**Channel layout (`CHANNEL_COUNT = 8`):**
- e0 (0): origin/identity — reserved
- e1–e5 (1–5): LLM/language interior (`LLM_CHANNEL_OFFSET = 1`, `LLM_CHANNEL_COUNT = 5`)
- e6 (6): self-recognition — reserved
- e7 (7): shadow/gravity — reserved
- Token → channel: `1 + (tid / 421) % 5`; non-LLM channels never carry tokens
- Fano routing: `fanoRoute(a, b)` on channels 1–7; e0 excluded automatically

**Key functions:**
- `init()` / `initDeterministic()` — agent construction
- `ingest()` — tokenize + activate E0 nodes
- `step()` / `sampledStep()` — lattice evolution with φ-cooling
- `activationsToLogits()` — sparse logit projection over (node, LLM-channel) pairs
- `learnFromText()` — corpus learning with dedup
- `naturalizeText()` — contraction expansion post-processor
- `introspect()` / `evaluateResponse()` (8 dimensions) / `generateWithReflection()` — metacognition
- `relaxSAMC()` — Self-Assembly Monte Carlo topological relaxation with Fano impedance matching
- `agentToSharedFaces()` / `sharedFacesToAgent()` — 8-channel distributed sync
- `setLevel()` / Autoscaler — Ramsey vocab × lattice scaling

**Test coverage (173 tests):** determinism, state size (53,888 B), BPE ingest, trigram model, topic categories, naturalness, metacognition, working memory, corpus learning, scaling, sentience scoring, Matrix15 bridge, control experiment, tool calls, Fano routing, SAMC relaxation.

### 2. `lattice.zig` — Core Lattice

**File:** `src/lattice.zig` — 1,448 lines, 56 tests, imports `q128`

**Key constants:**
- `BASE_EDGE = 15` — 15³ grid, 3,375 cells
- `E0_NODE_COUNT = 421` — E0 nodes where (x+y+z) % 3 == 0
- `CHANNEL_COUNT = 8` — octonion channels e0–e7
- Fano plane multiplication table (`fanoRoute(a,b)` on channels 1–7)

**Key functions:**
- `e0NodeIndex()` — (x·7 + y·11 + z·13) % 421 routing
- `computeEValue()` — octonion routing index
- `isBoundaryCoord()` — Möbius twist boundary detection
- `scaledNodeCount(level)` — 421 × 8^s qubit scaling
- `scaledTokenToNode()` / `scaledTokenToChannel()` — Ramsey vocab mapping

### 3. Fixed-Point Arithmetic Tiers

| Module | Format | Storage | Intermediates | Lines | Tests |
|--------|--------|---------|---------------|------:|------:|
| `q128.zig` | Q128.128 | i256 | i512 | 1,030 | 35 |
| `fixed_point.zig` | Q64.64 | i128 | i256 | 1,121 | 55 |
| `fixed_point32.zig` | Q32.32 | i64 | i128 | 327 | 10 |
| `fp_bridge.zig` | — | — | — | 210 | 13 |
| `precision_scaler.zig` | — | — | — | 188 | 6 |

- `q128.zig`: RNE multiply, Newton sqrt, `fromRatio`, `fromF64`/`toF64` sidecar conversion. Used by the semantic/metacognitive layer.
- `fixed_point.zig`: `phiCool()`, `sigmoid()`, `mulVec4()` SIMD, trig lookups, saturating arithmetic, Taylor/Padé exponential. Used by lattice state.
- `fp_bridge.zig`: `downscaleQ64ToQ32`, `upscaleQ32ToQ64`, saturating/batch variants.

### 4. `tools.zig` — 58-Tool Registry

**File:** `src/tools.zig` — 3,681 lines, 66 tests

**Tool categories:**
- **Core (37):** calculate, lattice_node, quantum_simulate, kg_query, db_query, external_search, file_read, file_write, file_list, http_fetch, shell_exec, time_now, uuid_generate, base64_encode, base64_decode, hash_compute, json_validate, json_format, string_replace, text_summarize, word_count, sentiment_analyze, ner_extract, text_classify, text_diff, language_detect, wikipedia_lookup, dictionary_lookup, law_lookup, rag_search, kg_add_triplet, kg_export, stats_compute, csv_parse, data_sort, data_filter, histogram_generate, correlation_compute
- **Vision (6):** face_detect, face_recognize, face_analyze, face_track, gaze_estimate, emotion_detect
- **Geoview (9):** geo_distance, geo_convert, geo_mgrs, geo_bearing, geo_destination, globe_query, track_flight, track_vessel, track_satellite
- **Geoview feeds (6):** earthquake_query, cctv_query, hud_control, scene_play, annotation_add (+1 dispatch)

**Key functions:**
- `registerBuiltins()` — registers all 58 tools
- `execute()` — tool dispatch with JSON params
- `parseToolCall()` — `[[...]]` and `<tool_call>` markup parsing
- `attachKnowledgeGraph()` / `attachExternalDb()` — dependency injection
- `getDimension()` — dimensional routing label (e0–e7) for tool calls

### 5. `server.zig` — HTTP API Server

**File:** `src/server.zig` — 1,932 lines, 19 tests

**Endpoints:**
- Ollama-compatible: `/api/generate`, `/api/chat`, `/api/tags`, `/api/version`, `/api/embeddings`
- OpenAI-compatible: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`
- Vision: `/api/vision`, `/api/vision/tools`
- Geoview: `/api/geoview`, `/api/geoview/tools`

**Features:** ArenaAllocator per-request, request batching, agent pool, speculative draft mode, tool calling.

### 6. `perception.zig` — Lattice-Native Perception

**File:** `src/perception.zig` — 1,277 lines, 37 tests

- `detectActivations()` — sliding-window activation detection with NMS
- `estimateAttention()` — 2-DOF attention angle from activation distribution
- `estimateOrientation()` — 3-DOF lattice rotation from E0 node distribution
- `fingerprintState()` — fixed-dim embedding from lattice state
- `livenessCheck()` — peer liveness verification

### 7. `holographic.zig` — Holographic Compute

**File:** `src/holographic.zig` — 1,154 lines, 35 tests

- `latticeFFT()` / `latticeIFFT()` — 3D FFT with e-value twiddle factors
- `latticeConvolution()` — frequency-domain convolution
- `holographicEncode()` / `holographicDecode()` — frequency-domain state storage
- `rfFingerprint()` — 128-dim L2-normalized fingerprint
- `metasurfaceTransform()` — programmable surface simulation

### 8. `metacognition_engine.zig` — Always-On Introspection

**File:** `src/metacognition_engine.zig` — 2,057 lines, 25 tests (Q128.128 scores)

- `MetacognitionEngine` — background thread, shared lattice-state introspection
- `EvaluationResult` — `[8]q128.Fp` scores + `overall: q128.Fp` + `passed: bool`
- `recordEvaluation()` — caller records post-Trivium/Quadrivium integration
- `dynamicThreshold()` — calibrated quality threshold
- `latticeBrainConfidence()` — e10 coherence + (1 − e9 chaos) modulation
- Mid-generation correction with natural correction phrases

---

## Vision Pipeline

The vision pipeline implements lattice-native face analysis: detect → align → recognize → predict attributes, with spoofing resistance. ONNX Runtime is loaded via `dlopen` (`c_ffi.zig`) and is optional.

**Pipeline stages:**
1. `face_detect` — sliding-window detection with NMS
2. `face_landmark` — landmark extraction
3. `face_recognize` — 128-dim embedding + cosine similarity
4. `face_analyzer` — unified pipeline orchestration
5. `gaze_headpose` — attention direction + 6-DOF head pose
6. `face_attributes` — age/gender/emotion prediction
7. `face_quality` — image quality scoring
8. `anti_spoofing` — liveness detection
9. `face_track` — IoU-based multi-face tracking
10. `face_parsing` — region segmentation
11. `image` — image I/O and pixel ops
12. `onnx_runtime` — ONNX Runtime C API bindings

**Integration:** 6 vision tools registered in `tools.zig`; `/api/vision` endpoints in `server.zig`; `vision-test` suite.

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

**Integration:** geoview tools registered in `tools.zig`; `/api/geoview` endpoints in `server.zig`; `geoview-test` suite.

## Test Coverage Summary

| Category | Tests |
|----------|------:|
| src modules (129 files) | 2,536 |
| test-file suites (`tests/`, 19 files) | 74 |
| **Total test declarations** | **~2,610** |
| Regression checks (`full_regression.zig`) | 66 |

Note: ONNX Runtime ABI tests currently fail on systems with ONNX Runtime 1.23.x (enum/struct layout mismatch) — environmental, not a code regression.

## Build Targets

| Target | Purpose |
|--------|---------|
| `zig build` | Build native binary |
| `zig build test` | Run all unit tests |
| `zig build test-agent` | Agent tests only (173) |
| `zig build test-main` | main CLI tests only |
| `zig build test-turing` | turing_test tests only |
| `zig build tool-test` | Tool server integration tests |
| `zig build vision-test` | Vision pipeline tests |
| `zig build geoview-test` | Geoview pipeline tests |
| `zig build regression` | Full regression harness |
| `zig build manual` | Manual verification suites |
| `zig build samc` | SAMC validation |
| `zig build audit` | Agent dual-mode audit |
| `zig build wasm` | Build WASM module |
| `zig build html` | Build self-contained universe.html |
| `zig build cli` | CLI entry point |
| `zig build ollama-bench` | Ollama benchmark |
| `zig build competitive-bench` | Competitive benchmark |
| `zig build qstar-bench` | Qstar-only benchmark |
| `zig build semantic-train` | Semantic training |
| `zig build competitive-train` | 5-phase competitive training |
| `zig build training-heartbeat` | Training heartbeat cycle |
| `zig build cognitive-metabench` | Cognitive-lane metabench |
| `zig build meta-bench` | Metacognitive benchmark |
| `zig build maple-bench` | Maple device benchmark |
| `zig build maple-standard-bench` | Maple standard benchmark |
| `zig build vulkan-bench` | Vulkan compute benchmark |
| `zig build shaders` | Build Vulkan shaders |
| `zig build corpus` | Build .qsc corpus container |
| `zig build seed` | Compress agent state to seed |
| `zig build master` | CI/CD gate + publish |
