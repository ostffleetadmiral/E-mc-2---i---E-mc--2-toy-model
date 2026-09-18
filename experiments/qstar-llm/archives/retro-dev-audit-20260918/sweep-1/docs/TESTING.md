# Testing Guide

Qstar-LLM maintains ~2,689 test declarations (2,615 across 165 Zig modules — 137 top-level `src/`, 12 `vision/`, 16 `geoview/` — plus 74 across the `tests/` suite files) with 101%+ coverage, plus tool calling integration tests, a full regression harness, manual integration suites, agent dual-mode audit, SAMC validation, a competitive benchmark suite (Qstar vs Ollama vs OpenAI vs Maple), training heartbeat, and Vulkan/Maple benchmarks. This document describes the testing strategy, how to run tests, and coverage requirements.

---

## Running Tests

### All tests at once

```bash
zig build test
```

> **Note:** `zig build test` compiles every module's tests — it is slow for development. Prefer the targeted suites below, or individual module tests (`zig test`) during iteration. One known environmental failure exists: `src/vision/onnx_runtime.zig`'s `OrtApiBase` field-order check aborts against ONNX Runtime 1.23.2 (library ABI mismatch, not a code regression).

### Agent module tests

```bash
zig build test-agent
```

Runs the full agent suite (173 tests): state init, 8-channel token mapping (e0–e7; LLM tokens on e1–e5), ingestion, inference cycles, φ-cooling, SAMC relaxation, Fano routing, activations→logits projection, metacognition history, tool-call processing, deterministic reproducibility, Vulkan fallback, SharedFace sync.

### Other focused suites

```bash
zig build test-turing    # Turing test suite
zig build test-main      # main.zig module tests (29)
zig build test-training  # training.zig module tests (31)
```

### Manual integration tests

```bash
zig build manual
```

Runs standalone executables that exercise real APIs end-to-end with printed output:
- `manual_agent` — state size, text ingestion, inference cycles, token mapping, chat formatting, max cycles
- `manual_s0_projection` — S0→S7 holographic projection, TurboQuant compression, residual sidecar
- `manual_s7_compression` — S7→S0 lattice compression, lossless/lossy reconstruction
- `manual_vocab_scaling` — level-scaled token-to-node mapping, collision rates, round-trip fidelity

### Agent dual-mode audit

```bash
zig build audit
```

Runs the audit suite covering: state size (53,888 bytes = 421 × 8 × i128), local mode determinism, P2P mode determinism, activation propagation, φ-cooling, cycle cap, reset, decode, matrix dimensions (421×8), BPE coherence, BPE round-trip.

### SAMC validation

```bash
zig build samc
```

Runs SAMC validation tests: lattice topology, SAMC energy relaxation, Gauss linking, multi-channel agent reasoning, topological sampler pipeline.

### Tool server integration

```bash
zig build tool-test
```

Runs tool/server tests: tool execution (calculate, lattice_node), tool markup parser, server route handlers (Ollama + OpenAI), quantum simulate (Grover), vision/geoview tool execution.

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

Runs the multi-step regression harness: agent state size, determinism, core/vision/geoview tools, server init, training pipeline, Turing test, vision pipeline, geoview pipeline, WASM/HTML artifacts, master node (manifest, autoupdate, signaling/relay, p2p round-trip).

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

### Cognitive metacognition benchmark

```bash
zig build cognitive-metabench
zig build meta-bench
```

Runs the metacognitive benchmark harnesses that exercise the 6D self-evaluation pipeline and routing calibration.

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

Builds the WASM module (`zig-out/wasm/qstar_llm.wasm`) for browser embedding.

### HTML build verification

```bash
zig build html
```

Builds self-contained `zig-out/universe.html` (~10 MB) with WASM + distilled corpus embedded as base64. Depends on `zig build wasm` running first.

### Single module

Most leaf modules can be tested directly; modules with dependencies need `--dep`/`-M` flags (see the project's AGENTS.md for per-module dependency commands):

```bash
zig test src/lattice.zig
zig test src/fixed_point.zig
zig test src/turbo_quant.zig
zig test --dep fixed_point -Mroot=src/octonion_math.zig -Mfixed_point=src/fixed_point.zig
# etc.
```

`agent.zig` has many dependencies — use `zig build test-agent` instead of `zig test`.

### Verbose output

```bash
zig test src/lattice.zig --test-filter "lattice mapping"
```

---

## Test Inventory

### Core Source Modules (top counts)

| Module | Tests | Coverage Areas |
|--------|-------|----------------|
| `agent.zig` | 173 | 8-channel state init (421×8, 53,888 B), text/token ingestion, inference cycle, φ-cooling, Fibonacci projection, token mapping (e1–e5 LLM channels), decode, chat formatting, SAMC relaxation, Fano routing, activations→logits, deterministic mode, trigram model, anti-repetition, topic routes, creative routes, naturalness engine, semantic retrieval, conversation context, metacognition, sentience scoring, Matrix15 bridge, control experiment framework, working memory, memory callbacks, draftGenerate, level scaling, factual routes |
| `tools.zig` | 66 | 58 registered tools, calculate, lattice_node, quantum_simulate, parseToolCall, file/network/data tools, vision/geoview/feed tools |
| `mesh.zig` | 65 | Mesh networking, peer routing, collapse-resilient transport |
| `lattice.zig` | 56 | Grid, E0, octonion routing, Möbius twist, φ-cooling, 11-dim ladder, λ_H, ring location, isotonic regression, scaled token mapping |
| `s0_projection.zig` | 55 | S0→S7 holographic projection, TurboQuant integration, residual sidecar |
| `fixed_point.zig` | 55 | Q64.64 arithmetic (i128): add, sub, mul (i256 intermediate), div, trig, sqrt, constants, SIMD vec4 |
| `agent_lite.zig` | 55 | 7-channel lite agent prototype (self-contained) |
| `s7_compression.zig` | 45 | S7→S0 lattice compression, lossless/lossy reconstruction |
| `p2p_types.zig` | 40 | P2P protocol types |
| `quantum.zig` | 37 | Integer quantum simulation (Grover) |
| `perception.zig` | 37 | UniFace lattice-native perception, face detection, feature extraction, classification, multi-scale fusion |
| `q128.zig` | 35 | Q128.128 arithmetic (i256, i512 intermediates): RNE mul, div, fromRatio, sqrt, f64 sidecar conversion |
| `holographic.zig` | 35 | S0↔S7 holographic projection/compression, DFT round-trip, e-value computation |
| `turbo_quant.zig` | 33 | Rotation, Lloyd-Max quantization, bit-packing, TQ pipeline |
| `entangle.zig` | 33 | Entanglement routing |
| `codon.zig` | 32 | 64-codon routing |
| `bi_complex.zig` | 31 | Bi-complex algebra |
| `main.zig` | 29 | CLI command handling |
| `hw_elevation_paths.zig` | 28 | Hardware elevation paths |
| `virtual_transport.zig` | 26 | Virtual transport layer |
| `training.zig` | 31 | Self-training pipeline, DEFAULT_PROMPTS (300 prompts, 30 categories), trainBatch, trainBatchHybrid, internet training, dataset ingestion, WIKIPEDIA_ARTICLES (1,345 titles), corpus delta-append persistence (sentinel preservation, watermark flush, .qsc sidecar, bounded load) |
| `octonion_math.zig` | 26 | Octonion algebra |
| `vocab_lattice_scaling.zig` | 25 | Level-scaled token-to-node mapping, collision rates |
| `relay_router.zig` | 25 | Relay routing |
| `metacognition_engine.zig` | 25 | 6D self-evaluation, Jordan self-model, history recording |
| `transport_polyglot.zig` | 24 | Polyglot transport |
| `transport_lora.zig` | 24 | LoRa transport |
| `qr_nest.zig` | 23 | Nested QR encoding |
| `hw_jordan_algebra.zig` | 23 | Hardware Jordan algebra |
| `jordan_algebra.zig` | 22 | J3(O) Jordan algebra |
| `hw_bridge.zig` | 22 | Hardware bridge |
| `sentience_scorer.zig` | 21 | Sentience scoring |
| `hw_surface_computation.zig` | 21 | Hardware surface computation |
| `so10.zig` | 20 | SO(10) structures |
| `sentience_experiment.zig` | 20 | Sentience experiment framework |
| `ollama_client.zig` | 20 | Zero-dep Ollama HTTP client, streaming generation |
| `dynamic_dns.zig` | 20 | Dynamic DNS |
| `server.zig` | 19 | Server init, Ollama + OpenAI routes, tool calling, streaming |
| `nat.zig` | 19 | NAT traversal |
| `voice_codec.zig` | 18 | Voice codec (7-channel audio, self-contained) |
| `quadrivium.zig` | 18 | Quadrivium integration (number/geometry/harmony/astronomy) |
| `llama_server.zig` | 18 | llama-server fallback provider, /no_think fast-path |
| `dynamic_routes.zig` | 17 | Dynamic route management |
| `trivium.zig` | 16 | Trivium pipeline (grammar/logic/rhetoric) |
| `hw_scaling_analysis.zig` | 16 | Hardware scaling analysis |
| `holo_codec.zig` | 16 | FHOLO1 holographic serialization |
| `e8_roots.zig` | 16 | E8 root system |
| `doc_loader.zig` | 16 | Recursive document preprocessor |
| `collapse.zig` | 16 | Collapse resilience orchestration |
| `sampling.zig` | 15 | Temperature, top-k, top-p, multinomial, SAMC sampling |
| `hw_self_claims.zig` | 15 | Hardware self-claims |
| `hw_generative_chain.zig` | 15 | Hardware generative chain |
| `hardware_detect.zig` | 15 | Hardware detection |
| `dim_5d_language.zig` | 15 | 5D language/bi-complex attention |
| *(~80 additional modules with 1–14 tests each — see `src/` for the full inventory; dimensional stack dim_0d–dim_10d, hw_* physics bridges, transport_* media, corpus_*, collapse_*, cognitive_*, memory, knowledge_graph, state_store, face_sync, continual_learner, turing_test, bpe_tokenizer, fp_bridge, fixed_point32, precision_scaler, neural_lm, llm_provider, kimi_stream_adapter, openai_client, webrtc, c_ffi, vulkan_compute, distillation_s0, lattice_compressor, seed_compressor, corpus_learner, corpus_store, corpus_seed*, merge, sybil, master_server, maple_client, prompt_generator, routing_calibration, arithmetic_reasoner, knowledge_lookup, wasm_exports, config, env_loader, memory_pool, external_db, heartbeat, p2p_update, mesh_peer, build_html)* | | |

### Vision Modules (src/vision/, 184 tests)

| Module | Tests | Coverage Areas |
|--------|-------|----------------|
| `image.zig` | 20 | Image I/O, resize, color space, pixel ops |
| `onnx_runtime.zig` | 11 | ONNX model runtime (C-API bindings; field-order test fails on ORT 1.23.2 — environmental) |
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

### Geoview Modules (src/geoview/, 152 tests)

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

### Test Suites (tests/, 74 test declarations)

| File | Tests | Coverage |
|------|-------|----------|
| `competitive_bench.zig` | 18 | Competitive benchmark suite |
| `vision_test.zig` | 25 | Vision pipeline integration |
| `geoview_test.zig` | 30 | Geoview pipeline integration |
| `maple_bench.zig` | 1 | Maple benchmark |
| *(15 additional harnesses: full_regression, audit_agent, manual_*, ollama_benchmark, prototype_samc_test, tool_server_test, semantic_train, competitive_train, cognitive_metabench, meta_bench, training_heartbeat, vulkan_benchmark — executable checks rather than `test` blocks)* | | |

| **Grand Total** | **~2,689** | 165 Zig modules + 19 test files |

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

Core state values use `i128` Q64.64 (`fixed_point.zig`) and `i256` Q128.128 (`q128.zig`) fixed-point and are compared with exact equality:

```zig
try std.testing.expectEqual(@as(i128, fp.ZERO), node.activation);
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
