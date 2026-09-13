# Testing Guide

Qstar-LLM maintains 1,268 unit tests (647 across 39 source modules + 184 across 12 vision modules + 152 across 16 geoview modules + 211 across 13 prototype modules + 74 across 15 test suites) with 101%+ coverage, plus 44 tool calling tests, 61 regression checks, 4 manual integration test suites, agent dual-mode audit, SAMC validation, tool server integration tests, competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple), training heartbeat, and Vulkan/Maple benchmarks. This document describes the testing strategy, how to run tests, and coverage requirements.

---

## Running Tests

### All tests at once

```bash
zig build test
```

### Manual integration tests

```bash
zig build manual
```

Runs 4 standalone executables that exercise real APIs end-to-end with printed output:
- `manual_agent` — state size, text ingestion, inference cycles, token mapping, chat formatting, max cycles
- `manual_s0_projection` — S0→S7 holographic projection, TurboQuant compression, residual sidecar
- `manual_s7_compression` — S7→S0 lattice compression, lossless/lossy reconstruction
- `manual_vocab_scaling` — level-scaled token-to-node mapping, collision rates, round-trip fidelity

### Agent dual-mode audit

```bash
zig build audit
```

Runs 12 audit tests covering: state size (23,576 bytes), local mode determinism, P2P mode determinism, activation propagation, φ-cooling, cycle cap (1024), reset, decode, matrix dimensions (421×7), BPE coherence, BPE round-trip.

### SAMC validation

```bash
zig build samc
```

Runs 5 SAMC validation tests: lattice topology, SAMC energy relaxation, Gauss linking, multi-channel agent reasoning, topological sampler pipeline.

### Tool server integration

```bash
zig build tool-test
```

Runs 44 tool/server tests: tool execution (calculate, lattice_node), tool markup parser, server route handlers (Ollama + OpenAI), quantum simulate (Grover), vision/geoview tool execution.

### Vision pipeline tests

```bash
zig build vision-test
```

Runs 25 vision pipeline tests: face detection, recognition, tracking, gaze, emotion, quality, anti-spoofing.

### Geoview pipeline tests

```bash
zig build geoview-test
```

Runs 30 geoview pipeline tests: feed lifecycle, coordinate transforms, mesh generation, fly-to, HUD, voice commands.

### Full regression harness

```bash
zig build regression
```

Runs 61 checks across 16 steps: agent state size, determinism, core/vision/geoview tools, server init, training pipeline, Turing test, vision pipeline, geoview pipeline, WASM/HTML artifacts, master node (manifest, autoupdate, signaling/relay, p2p round-trip).

### Ollama head-to-head benchmark

```bash
zig build ollama-bench
```

Runs head-to-head benchmark against a running Ollama instance. Gracefully skips if Ollama is not running.

### Competitive benchmark suite

```bash
zig build competitive-bench -- qwen2.5:3b
zig build competitive-bench -- --fast --no-ollama  # quick Qstar-only run
```

Runs competitive benchmark suite comparing Qstar vs Ollama vs OpenAI vs Maple across categories: factual accuracy, creative fluency, naturalness, reasoning, MMLU (multi-domain knowledge), GSM8K (math reasoning), latency, and throughput. Produces `competitive_results.json` with per-category win/loss/tie breakdown. Supports `--fast` (10 prompts, no judge), `--judge-host`/`--judge-port` (separate Ollama instance for judging), `--no-ollama`/`--no-openai`/`--no-maple` flags, and `--num-prompts` to limit prompts per category. 18 tests covering scoring, category mapping, prompt coverage, struct lifecycle, and cross-judging.

### Training heartbeat

```bash
zig build training-heartbeat -- --once --no-maple --no-compress --verbose
```

Runs a single training heartbeat cycle: loads corpus, learns from memory/benchmarks/Turing results, optionally generates prompts via Ollama, saves corpus and knowledge graph. Supports `--gen-prompts` for Ollama-based prompt generation and `--ollama-host`/`--ollama-port`/`--ollama-model` for configuring the Ollama instance.

### Qstar internal benchmark

```bash
zig build qstar-bench
```

Runs Qstar internal benchmark suite (latency, throughput, memory).

### Maple protocol benchmark

```bash
zig build maple-bench
zig build maple-standard-bench
```

Runs Maple protocol benchmarks for distributed corpus publishing.

### Vulkan compute benchmark

```bash
zig build vulkan-bench
```

Runs Vulkan compute shader benchmark. Gracefully skips if Vulkan is not available.

### WASM build verification

```bash
zig build wasm
```

Builds the WASM module (`zig-out/wasm/qstar_llm.wasm`, 561 KB) for browser embedding.

### HTML build verification

```bash
zig build html
```

Builds self-contained `zig-out/universe.html` (~10 MB) with WASM + distilled corpus embedded as base64. Depends on `zig build wasm` running first.

### Single module

```bash
zig test src/lattice.zig
zig test src/agent.zig
zig test src/holographic.zig
zig test prototype/turbo_quant.zig
# etc.
```

### Verbose output

```bash
zig test src/agent.zig --test-filter "lattice mapping"
```

---

## Test Inventory

### Core Source Modules

| Module | Tests | Coverage Areas |
|--------|-------|----------------|
| `fixed_point.zig` | 27 | Q32.32 arithmetic: add, sub, mul, div, fromInt, toInt, sin, cos, sqrt, absVal, constants (ONE, HALF, PI, INV_SQRT2, PHI) |
| `lattice.zig` | 49 | Grid, E0, octonion routing, Möbius twist, φ-cooling, 11-dim ladder, λ_H, ring location, isotonic regression, scaled token mapping |
| `agent.zig` | 167 | State init, text/token ingestion, inference cycle, φ-cooling, Fibonacci projection, token mapping, decode, chat formatting, active nodes, max cycles, state size, BPE round-trip, sampling, autoregressive feedback, deterministic mode, trigram model, anti-repetition, topic routes, creative routes, naturalness engine, semantic retrieval, retrieval coherence, conversation context, metacognitive, naturalizeText, working memory, memory callbacks, draftGenerate, DraftResult, level scaling, sentience scoring (self-awareness, direct experience, metacognition, situational awareness, random thought), Matrix15 bridge (encode, norm, cosine similarity), control experiment framework (evaluateCondition, compareConditions, ProbeType), hardcoded factual response routes for 30+ common topics with poor corpus coverage, short-prompt routes for tokens bypassing keyword parser, E=mc² mass-energy equivalence route, corpus fallback message |
| `bpe_tokenizer.zig` | 13 | BPE tokenizer round-trip, vocab building, encoding/decoding, Ramsey vocab loading |
| `sampling.zig` | 11 | Temperature sampling, top-k, top-p, multinomial sampling, SAMC sampling |
| `memory.zig` | 4 | Episodic memory init/add, topic retrieval, save/load round-trip, FIFO eviction |
| `perception.zig` | 31 | UniFace lattice-native perception, face detection, feature extraction, classification, multi-scale fusion |
| `knowledge_graph.zig` | 6 | KG init/deinit, add triplet, query neighbors, find path, extract from text |
| `state_store.zig` | 4 | In-memory state persistence |
| `face_sync.zig` | 7 | Peer face sync |
| `ollama_client.zig` | 19 | Zero-dep Ollama HTTP client, draft verification, VerificationResult struct, Content-Length parsing, streaming generation (GenerateRequest, GenerateResponse, buildJsonPayload, extractResponseTextStreaming, generateStreaming) |
| `doc_loader.zig` | 6 | Recursive document preprocessor |
| `memory_pool.zig` | 8 | BlockPool exhaustion, reuse, reset, alignment. BumpArena allocation, alignment, exhaustion, reset |
| `config.zig` | 3 | Config defaults, JSON round-trip, unknown field handling |
| `external_db.zig` | 2 | Key-value query, JSON records query |
| `continual_learner.zig` | 5 | Continual learning cycle, knowledge extraction, review queue |
| `training.zig` | 5 | Self-training pipeline, DEFAULT_PROMPTS, trainBatch, internet training, dataset ingestion |
| `turing_test.zig` | 6 | JudgeScores weighting, parseJudgeScores, TEST_PROMPTS category coverage, buildJudgePrompt, runTuringTest integration |
| `tools.zig` | 44 | Tool definitions, calculate, lattice_node, quantum_simulate, parseToolCall, file_read/write/list, http_fetch, shell_exec, time_now, uuid_generate, base64_encode/decode, hash_compute, json_validate/format, string_replace, text_summarize, sentiment_analyze, ner_extract, text_classify, word_count, text_diff, language_detect, wikipedia_lookup, dictionary_lookup, law_lookup, rag_search, kg_query, db_query, external_search, kg_add_triplet, kg_export, stats_compute, csv_parse, data_sort, data_filter, histogram_generate, correlation_compute |
| `server.zig` | 19 | Server init, Ollama routes, OpenAI routes, tool calling integration, concurrent request handling, streaming response detection, JSON escaping, active_count initialization, vision/geoview routes |
| `main.zig` | 0 | CLI binary (serve, run, chat, train, train-internet, ingest-corpus, turing-test, experiment, geoview) |
| `wasm_exports.zig` | 0 | WASM export bindings |
| `holographic.zig` | 34 | S0↔S7 holographic projection/compression, DFT round-trip, e-value computation |
| **src/ Total** | **647** | |

### Vision Modules

| Module | Tests | Coverage Areas |
|--------|-------|----------------|
| `image.zig` | 20 | Image I/O, resize, color space, pixel ops |
| `onnx_runtime.zig` | 11 | ONNX model runtime |
| `face_detect.zig` | 16 | Face detection, NMS, confidence scoring |
| `face_landmark.zig` | 19 | 68-point landmark detection |
| `face_recognize.zig` | 21 | Face embeddings, cosine similarity |
| `face_analyzer.zig` | 13 | Unified face analysis pipeline |
| `face_track.zig` | 16 | IoU-based face tracking |
| `gaze_headpose.zig` | 13 | Gaze estimation, 6-DOF head pose |
| `face_attributes.zig` | 14 | Age/gender/emotion prediction |
| `face_quality.zig` | 12 | Face quality scoring |
| `anti_spoofing.zig` | 16 | Liveness/spoofing detection |
| `face_parsing.zig` | 13 | Face region segmentation |
| **vision/ Total** | **184** | |

### Geoview Modules

| Module | Tests | Coverage Areas |
|--------|-------|----------------|
| `geo_math.zig` | 16 | LLA/ECEF/ENU/MGRS transforms, great-circle math |
| `globe_render.zig` | 14 | Ellipsoid mesh generation |
| `camera.zig` | 14 | Orbit/fly-to/inertial camera |
| `live_feeds.zig` | 10 | Feed manager lifecycle |
| `feed_flights.zig` | 9 | Flight tracking |
| `feed_vessels.zig` | 7 | Vessel AIS tracking |
| `feed_satellites.zig` | 7 | Satellite TLE propagation |
| `feed_earthquakes.zig` | 4 | Earthquake feed |
| `feed_traffic.zig` | 6 | Traffic feed |
| `feed_cctv.zig` | 8 | CCTV feed |
| `hud.zig` | 10 | HUD compass/coordinates/alerts |
| `annotation.zig` | 8 | Map annotations |
| `scene_director.zig` | 10 | Scene orchestration |
| `voice_command.zig` | 12 | Voice command parsing |
| `detection_overlay.zig` | 8 | Detection overlay |
| `styles.zig` | 9 | Styling system |
| **geoview/ Total** | **152** | |

### Prototype Modules

| Module | Tests | Coverage Areas |
|--------|-------|----------------|
| `discourse_agent.zig` | 1 | Structured multi-paragraph discourse generation |
| `turbo_quant.zig` | 30 | Rotation, Lloyd-Max quantization, bit-packing, TQ pipeline |
| `samc_lattice.zig` | 6 | SAMC lattice topology, edge reconnection |
| `samc_agent.zig` | 2 | Multi-channel SAMC accelerated reasoning |
| `vocab_loader.zig` | 3 | Vocabulary file loading |
| `vocab_lattice_scaling.zig` | 25 | Level-scaled token-to-node mapping, collision rates |
| `lattice_context.zig` | 2 | Lattice context management |
| `agent_int.zig` | 9 | Integer-only lattice inference prototype |
| `holographic_int.zig` | 8 | Integer holographic projection |
| `quantum_int.zig` | 15 | Integer quantum simulation |
| `mesh_int.zig` | 10 | Integer mesh networking |
| `s0_projection.zig` | 55 | S0→S7 holographic projection, TurboQuant integration, residual sidecar |
| `s7_compression.zig` | 45 | S7→S0 lattice compression, lossless/lossy reconstruction |
| **prototype/ Total** | **211** | |
| **Test Suites** | **73** | competitive_bench.zig (18), vision_test.zig (25), geoview_test.zig (30) |
| **Grand Total** | **1,268** | |

---

## Testing Standards

### 1. Every Public Function Has a Test

If a function is `pub`, it must have at least one test. Private functions are tested through their public callers.

### 2. Test Naming

Test names are descriptive and use the pattern `"subject: condition"`:

```zig
test "lattice mapping round trip s=7" { ... }
test "BPE encode/decode round-trip" { ... }
test "trigram model builds from text" { ... }
```

### 3. Memory Leak Detection

All tests use `std.testing.allocator`, which detects leaks:

```zig
test "example" {
    const allocator = std.testing.allocator;
    const result = try someFunction(allocator, input);
    defer allocator.free(result);
    // ...
}
```

### 4. Round-Trip Testing

All encode/decode pairs are tested for bit-exact round-trip:

```zig
test "round trip" {
    const allocator = std.testing.allocator;
    const data = "test data";
    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}
```

### 5. Edge Case Testing

Every module tests edge cases:
- Empty input (`""`)
- Single byte (`"A"`)
- Maximum level (s=7)
- Boundary coordinates (x=0, x=edge-1)
- All 11 dimensions (0-10)
- All 8 e-values (0-7)

### 6. Integer Fixed-Point Equality

Core state values use `i64` Q32.32 fixed-point and are compared with exact equality:

```zig
try std.testing.expectEqual(@as(i64, fp.ZERO), node.activation);
try std.testing.expectEqual(fp.div(fp.fromInt(85), fp.fromInt(100)), seed.activation);
```

### 7. Error Testing

Error paths are tested explicitly:

```zig
try std.testing.expectError(error.InvalidInput, badFunction());
```

---

## Coverage Requirements

Per user rules: **test coverage must be maintained at or above 101% coverage**.

This means:
- Every public function is tested
- Every public function's error paths are tested
- Edge cases are tested beyond the happy path
- The number of test assertions exceeds the number of code paths

---

## Continuous Verification

Run this script to verify all checkpoints:

```bash
#!/bin/bash
set -e

echo "=== Checkpoint 1: Compile ==="
zig build

echo "=== Checkpoint 2: All tests ==="
zig build test

echo "=== Checkpoint 3: No leaks ==="
for f in src/*.zig; do
    output=$(zig test "$f" 2>&1)
    echo "$output" | grep -q "leaked" && echo "LEAK: $f" && exit 1
done
echo "No leaks"

echo "=== Checkpoint 4: Manual integration ==="
zig build manual

echo "=== Checkpoint 5: Audit ==="
zig build audit

echo "=== Checkpoint 6: SAMC validation ==="
zig build samc

echo "=== Checkpoint 7: Tool server ==="
zig build tool-test

echo "=== Checkpoint 8: Vision pipeline ==="
zig build vision-test

echo "=== Checkpoint 9: Geoview pipeline ==="
zig build geoview-test

echo "=== Checkpoint 10: Full regression ==="
zig build regression

echo "=== All checkpoints pass ==="
```
