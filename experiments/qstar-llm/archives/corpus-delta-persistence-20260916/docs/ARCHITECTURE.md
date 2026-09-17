# Qstar-LLM Architecture

**Version 3.5.0** | Zig 0.13.0+ | Zero external dependencies (core) | ~2,610 tests (2,536 src + 74 test files) | Integer-only state (Q64.64 lattice + Q128.128 semantic layer)

Qstar-LLM is a standalone lattice-native LLM inference engine, extracted from the Qstar project. The lattice is the primary intelligence — no transformer attention, no MLP. An optional neural-LM hybrid path (Qwen3-0.6B via ONNX Runtime) and a confidence-routed llama-server streaming fallback exist as sidecars; they are not required for core inference. Native vision (face analysis) and God's Eye View (geospatial intelligence) subsystems are integrated via C FFI (dlopen pattern) with pure Zig logic. Hardware auto-detection selects optimal precision tier at comptime; states are downscaled to Q32.32 for Maple/ESP32/WASM peripheral consumption via `fp_bridge`.

## Design Principles

1. **Purity** — Core `.zig` files import only `std`. External libraries (ONNX Runtime, libvulkan) are loaded dynamically via `dlopen` and are optional.
2. **First Principles** — Every function traces to a lattice axiom (A1-A7).
3. **Bit-Exact Determinism** — Same input + same seed = same output, always.
4. **Integer-Only State** — Lattice state is i128 Q64.64 fixed-point (i256 intermediates). The metacognition/semantic layer uses i256 Q128.128 fixed-point (i512 intermediates) via `q128.zig`. f64 is used only in sidecar math (logit projection for sampling, turbo_quant, evaluation scoring, vision/geoview coordinates) — never in lattice state paths. `hardware_detect.zig` selects the precision tier at comptime; `fp_bridge.zig` downscales Q64.64 → Q32.32 for peripheral/WASM consumption.
5. **Standalone** — Single `zig build` command compiles everything.
6. **Graceful Degradation** — Vision/geoview/neural-LM modules degrade to lattice-only operation when external libraries (ONNX Runtime, libvulkan) or services (Ollama, llama-server, OpenAI) are unavailable.

## Arithmetic Tiers

The project uses three fixed-point tiers plus the semantic-layer Q128.128:

| Tier | Type | Intermediates | Used by |
|------|------|---------------|---------|
| Q128.128 | `i256` (`q128.Fp`) | `i512` | Metacognition engine, dynamic routes, trivium/quadrivium, training, sampling config, memory scores, agent evaluation, turing test — the semantic/self-model layer |
| Q64.64 | `i128` (`fixed_point.Fp`) | `i256` | Lattice activations `[421][8]i128`, octonion routing, bi-complex, Jordan algebra, tools, mesh, holographic — the lattice state layer |
| Q32.32 | `i64` (`fixed_point32`) | `i128` | Maple/ESP32/WASM peripherals via `fp_bridge`/`precision_scaler` |
| f64 | sidecar only | — | Logit projection (`activationsToLogits`), evaluation scoring, turbo_quant, vision/geoview coordinates, display |

14 modules import `q128` (i256): agent, lattice, metacognition_engine, trivium, quadrivium, dynamic_routes, cognitive_lanes, routing_calibration, memory, sampling, training, doc_loader, turing_test, main. 34 modules use `fixed_point` (i128).

## Lattice State

- E0 node count: **421** (15³ grid topology)
- Channels: **8** (e0–e7 octonion dimensions)
  - e0 (index 0): origin/identity — reserved
  - e1–e5 (indices 1–5): LLM/language interior — `LLM_CHANNEL_OFFSET = 1`, `LLM_CHANNEL_COUNT = 5`
  - e6 (index 6): self-recognition — reserved
  - e7 (index 7): shadow/gravity — reserved
- State layout: `[421][8]i128` = **53,888 bytes** (~53 KB)
- Downscaled state: 421 × 8 × i64 = 26,944 bytes (Q32.32 for peripherals)
- Fano plane routing: `fanoRoute(a, b)` operates on channels 1–7 (e0 excluded); internal channel index = octonion index
- Vocab size: 151,936 (Qwen BPE); tokens map to (node = tid % 421, channel = 1 + (tid/421) % 5)
- Base lattice edge: 15 (s=0), doubling per level
- GPU path: `vulkan_compute.zig` + shaders implement a separate **7-channel** prototype layout — not the primary agent state

## Module Inventory

### Inference Core
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| agent.zig | 12,053 | 173 | Lattice inference engine (E0 firing, octonion routing, Fano cross-channel coupling, Fibonacci projection, φ-cooling, SAMC relaxation, long-form generation, metacognition integration, creative routes, naturalness, retrieval, speculative draft, level scaling, sentience scoring, Matrix15 bridge, tool-call processing) |
| agent_lite.zig | 1,449 | 55 | Lightweight agent for WASM/embedded inference |
| lattice.zig | 1,448 | 56 | Lattice axioms (A1-A7), Fano plane routing, e-values |
| bpe_tokenizer.zig | 746 | 14 | BPE tokenizer + Ramsey vocab scaling |
| sampling.zig | 547 | 15 | Temperature, top-k, top-p, multinomial |
| main.zig | 3,281 | 29 | CLI binary (34 commands) |
| server.zig | 1,932 | 19 | Ollama + OpenAI-compatible HTTP server (concurrent, streaming) |
| tools.zig | 3,681 | 66 | 58-tool calling engine |
| wasm_exports.zig | 290 | 1 | WASM export bindings |
| voice_codec.zig | 855 | 18 | Lattice-native voice codec (VQ codebooks, NCA wave, HDC speaker binding — internal 7-channel representation) |
| corpus_seed.zig | 767 | 7 | Corpus seed text for agent initialization |
| corpus_seed_lite.zig | 136 | 6 | Lightweight corpus seed for WASM/embedded |

### Fixed-Point Arithmetic
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| q128.zig | 1,030 | 35 | Q128.128 arithmetic (i256, i512 intermediates, RNE multiply) |
| fixed_point.zig | 1,121 | 55 | Q64.64 arithmetic (i128, i256 intermediates) |
| fixed_point32.zig | 327 | 10 | Q32.32 arithmetic (i64, i128 intermediates) |
| fp_bridge.zig | 210 | 13 | Q64.64 → Q32.32 downscale bridge |
| precision_scaler.zig | 188 | 6 | Comptime precision-tier selection |
| hardware_detect.zig | 525 | 15 | Hardware capability detection |

### Algebra & Math
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| octonion_math.zig | 537 | 26 | Octonion multiplication, Fano structure |
| bi_complex.zig | 599 | 31 | Bi-complex numbers (5D language algebra) |
| jordan_algebra.zig | 507 | 22 | J₃(O) Jordan algebra (6D self-model) |
| so10.zig | 335 | 20 | SO(10) decomposition |
| e8_roots.zig | 355 | 16 | E8 root system |
| quantum.zig | 1,272 | 37 | Integer quantum simulation |
| entangle.zig | 1,253 | 33 | Entanglement/correlation primitives |
| codon.zig | 1,255 | 32 | 64-codon genetic-code routing |

### Dimensional Modules (0D–10D)
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| dim_0d_origin.zig | 89 | 5 | Origin/seed state |
| dim_1d_time.zig | 114 | 5 | Temporal ordering |
| dim_2d_complex.zig | 134 | 9 | Complex-plane structure |
| dim_3d_space.zig | 120 | 6 | Spatial grid (15³) |
| dim_4d_rotation.zig | 166 | 11 | Quaternion rotation/orientation |
| dim_5d_language.zig | 368 | 15 | Bi-complex language/attention |
| dim_6d_consciousness.zig | 466 | 14 | Jordan self-model, metacognition |
| dim_7d_color.zig | 105 | 5 | Octonionic channel routing |
| dim_8d_frequency.zig | 180 | 10 | φ-cooling frequency scaling |
| dim_9d_chaos.zig | 136 | 9 | Stochastic perturbation |
| dim_10d_gravity.zig | 182 | 9 | Dual-bi-complex coupling closure |

### Metacognition & Cognition
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| metacognition_engine.zig | 2,057 | 25 | Always-on introspection, background thread, mid-generation correction, dynamic thresholding |
| trivium.zig | 812 | 16 | Grammar/Logic/Rhetoric pipeline |
| quadrivium.zig | 542 | 18 | Arithmetic/Geometry/Music/Astronomy manifold |
| dynamic_routes.zig | 967 | 17 | Learned response routes with evaluation feedback |
| cognitive_lanes.zig | 280 | 5 | Explicit/implicit candidate promotion lanes |
| cognitive_cloud.zig | 544 | 11 | Distributed cognition primitives |
| routing_calibration.zig | 102 | 3 | Route confidence calibration |
| arithmetic_reasoner.zig | 103 | 3 | Integer arithmetic reasoning |
| knowledge_lookup.zig | 77 | 2 | Factual lookup layer |
| sentience_scorer.zig | 610 | 21 | 8-dimension sentience scoring |
| sentience_experiment.zig | 414 | 20 | Control experiment framework |

### Memory & Knowledge
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| memory.zig | 430 | 5 | 3-layer cognitive memory (working/episodic) |
| knowledge_graph.zig | 723 | 7 | Triplet store with BFS traversal |
| perception.zig | 1,277 | 37 | Activation detection, attention, liveness, introspection |
| state_store.zig | 247 | 5 | Agent state persistence |
| face_sync.zig | 305 | 8 | Peer face sync (8 SharedFaces, one per channel) |
| memory_pool.zig | 244 | 9 | Block pool + bump arena allocators |

### Training & Corpus
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| training.zig | 3,190 | 26 | Self-training (Ollama/OpenAI/hybrid teachers), internet training (Wikipedia), dataset ingestion, failure-window training |
| corpus_learner.zig | 563 | 9 | Corpus ingestion and learning |
| corpus_store.zig | 536 | 7 | Quine-style .qsc corpus container with LRU page cache |
| heartbeat.zig | 755 | 9 | Training heartbeat: corpus, memory, benchmark/Turing learning |
| prompt_generator.zig | 197 | 4 | Ollama-based prompt generation |
| doc_loader.zig | 790 | 16 | Recursive document preprocessor |
| continual_learner.zig | 448 | 7 | Background continual learning |
| env_loader.zig | 210 | 10 | .env loader for API keys |

### External Model Integration
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| ollama_client.zig | 664 | 20 | Zero-dep Ollama HTTP client + draft verification + streaming |
| openai_client.zig | 364 | 13 | Zero-dep OpenAI HTTP client (TLS HTTPS) |
| llama_server.zig | 683 | 18 | llama-server streaming fallback (`/no_think` creative fast path) |
| neural_lm.zig | 450 | 4 | Neural LM integration (Qwen3-0.6B ONNX) |
| llm_provider.zig | 251 | 7 | Provider abstraction over external LLMs |
| kimi_stream_adapter.zig | 162 | 3 | Kimi streaming API adapter |

### Compression & Holographic
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| s0_projection.zig | 2,348 | 55 | S0→S7 holographic projection |
| s7_compression.zig | 1,875 | 45 | S7→S0 lattice compression |
| holographic.zig | 1,154 | 35 | S0↔S7 holographic projection/compression |
| holo_codec.zig | 1,009 | 16 | Holographic codec |
| holographic_memory.zig | 596 | 10 | Holographic memory encoding |
| turbo_quant.zig | 1,327 | 33 | TurboQuant vector quantization sidecar |
| compress.zig | 688 | 11 | Compressor (dedup + gzip + lattice + RMSY) |
| seed_compressor.zig | 570 | 8 | Agent-state seed compression |
| lattice_compressor.zig | 393 | 8 | Lattice activation compression |
| distillation_s0.zig | 381 | 9 | S0 corpus distillation |
| vocab_lattice_scaling.zig | 920 | 25 | Level-scaled token-to-node mapping |

### Mesh, Transport & Resilience
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| mesh.zig | 2,090 | 65 | Peer mesh — TransportMode, ConnectionPool, OfflineTransportRouter |
| virtual_transport.zig | 1,000 | 26 | Virtualized transport over TCP — 12 modes, collapse simulation |
| mesh_peer.zig | 737 | 7 | TCP mesh peer (XChaCha20-Poly1305) |
| p2p_types.zig | 966 | 40 | P2P protocol type definitions |
| qr_nest.zig | 823 | 23 | Recursive QR nesting |
| relay_router.zig | 795 | 25 | Multi-hop relay + rendezvous discovery |
| nat.zig | 798 | 19 | NAT traversal (UDP hole punching, WebRTC signaling) |
| transport_lora.zig | 865 | 24 | LoRa long-range radio transport |
| transport_polyglot.zig | 600 | 24 | Multi-format polyglot file transport |
| collapse.zig | 608 | 16 | Collapse resilience — QR portal encoding |
| collapse_resilience.zig | 408 | 8 | State preservation through digital failure |
| collapse_recover.zig | 318 | 9 | Post-collapse peer recovery |
| merge.zig | 575 | 14 | State merge/conflict resolution |
| sybil.zig | 574 | 14 | Sybil-resistance identity verification |
| dynamic_dns.zig | 375 | 20 | ClouDNS dynamic DNS updater |
| webrtc.zig | 330 | 12 | WebRTC data channel protocol |
| master_server.zig | 686 | 8 | Master node HTTP + WebRTC signaling/relay |
| maple_client.zig | 310 | 2 | Maple protocol client |
| p2p_update.zig | 288 | 5 | P2P mirror publish |
| transport_paperback.zig | 258 | 8 | Paperback book format transport |
| transport_p2p.zig | 252 | 8 | P2P packet transport (X25519, ChaCha20Poly1305) |
| transport_convert.zig | 237 | 8 | Transport format conversion |
| transport_optar.zig | 233 | 7 | Optical art encoding transport |
| transport_qr.zig | 230 | 8 | QR code portal transport |
| transport_cassette.zig | 197 | 5 | Cassette tape audio transport |
| transport_audio.zig | 192 | 5 | Audio frequency encoding transport |
| transport_stega.zig | 192 | 6 | LSB steganography (AES-GCM, PNG) |
| transport_video.zig | 172 | 6 | Video frame embedding transport |
| transport_wifi.zig | 136 | 6 | WiFi CSI frame transport (ADR-018) |
| transport_quine.zig | 135 | 5 | Self-referential HTML quine transport |
| master_publish.zig | 107 | 2 | Master payload publisher |

### Hardware & GPU
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| vulkan_compute.zig | 1,217 | 9 | Dynamic Vulkan loader + compute dispatch (7-channel GPU prototype) |
| c_ffi.zig | 228 | 11 | C FFI bridge for vision/geoview (dlopen/dlsym) |
| hw_bridge.zig | 594 | 22 | Hardware bridge layer |
| hw_elevation_paths.zig | 801 | 28 | Self-claim elevation paths |
| hw_jordan_algebra.zig | 575 | 23 | J₃(O) hardware implementation |
| hw_surface_computation.zig | 393 | 21 | Surface computation hardware path |
| hw_scaling_analysis.zig | 487 | 16 | Cubic scaling chain verification |
| hw_generative_chain.zig | 374 | 15 | 0^0=i generative bootstrap |
| hw_self_claims.zig | 309 | 15 | Self-claim verification |
| hw_literature_review.zig | 260 | 12 | Literature reference verification |
| hw_e8_roots.zig | 289 | 11 | E8 roots hardware path |
| hw_octonion.zig | 210 | 11 | Octonion hardware primitives |
| hw_electric_charges.zig | 287 | 10 | Octonion U(1) charges |
| hw_consciousness_audit.zig | 313 | 8 | Consciousness causal-chain audit |
| hw_final_audit.zig | 281 | 9 | Final audit classification |

### Config & Misc
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| config.zig | 114 | 4 | Unified JSON configuration |
| external_db.zig | 168 | 3 | External database connector |
| build_html.zig | 474 | 3 | universe.html builder |
| turing_test.zig | 849 | 6 | Automated Turing test framework |

### Native Vision Modules (`src/vision/`, 12 modules, 184 tests)
| Module | Tests | Role |
|--------|-------|------|
| onnx_runtime.zig | 11 | ONNX Runtime C API bindings |
| image.zig | 20 | Image I/O & preprocessing |
| face_detect.zig | 16 | Face detection post-processing (NMS, anchors) |
| face_recognize.zig | 21 | Face recognition (ArcFace embeddings) |
| face_landmark.zig | 19 | Facial landmarks (PIPNet, FaceMesh) |
| face_track.zig | 16 | Multi-face tracking (IoU association) |
| gaze_headpose.zig | 13 | Gaze estimation & 6D head pose |
| face_attributes.zig | 14 | Demographics & emotion |
| face_parsing.zig | 13 | Face parsing/segmentation |
| face_quality.zig | 12 | Face quality assessment |
| anti_spoofing.zig | 16 | Anti-spoofing/liveness |
| face_analyzer.zig | 13 | Unified FaceAnalyzer pipeline |

### God's Eye View Modules (`src/geoview/`, 16 modules, 152 tests)
| Module | Tests | Role |
|--------|-------|------|
| geo_math.zig | 16 | Geospatial math (WGS84, LLA↔ECEF↔ENU, MGRS) |
| globe_render.zig | 14 | 3D globe renderer |
| camera.zig | 14 | Camera controllers (orbit, fly-to) |
| live_feeds.zig | 10 | Feed manager lifecycle |
| feed_flights.zig | 9 | OpenSky flight tracking |
| feed_vessels.zig | 7 | AIS vessel tracking |
| feed_satellites.zig | 7 | Satellite TLE/SGP4 propagation |
| feed_earthquakes.zig | 4 | USGS earthquake feed |
| feed_traffic.zig | 6 | Traffic feed |
| feed_cctv.zig | 8 | CCTV camera management |
| hud.zig | 10 | Intelligence HUD |
| detection_overlay.zig | 8 | Detection overlays |
| annotation.zig | 8 | Annotations engine |
| scene_director.zig | 10 | Scene director |
| styles.zig | 9 | Sensor style shaders |
| voice_command.zig | 12 | Voice command processing |

### Integration Test Suites (`tests/`, 19 files, 74 tests)
Includes `full_regression.zig` (66 checks), `manual_agent.zig`, `audit_agent.zig`, vision/geoview pipelines, benchmark harnesses, and competitive/meta benches.

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    CLI / HTTP Server                     │
│              (main.zig / server.zig)                     │
│         (concurrent, streaming, speculative draft)       │
│   vision: /api/vision, /api/vision/tools                 │
│   geoview: /api/geoview, /api/geoview/tools              │
│   mesh: /api/mesh/status, /api/mesh/join                 │
│   transport: /api/transport/list, /api/transport/send    │
├─────────────────────────────────────────────────────────┤
│              Virtual Transport & Mesh Layer              │
│           (virtual_transport.zig, mesh.zig)              │
│   VirtualMeshNode (TCP port 9000) — 12 transport modes   │
│   Store-and-forward, broadcast, relay routing            │
│   Collapse recovery: quine + paper + cassette fallback   │
├─────────────────────────────────────────────────────────┤
│                    Tool Calling Engine                    │
│                      (tools.zig)                         │
│   37 core + 6 vision + 9 geoview + 6 feed tools = 58     │
├─────────────────────────────────────────────────────────┤
│        Training / Internet Training / Turing Test / Experiment  │
│    (training.zig: self-train + Wikipedia API + datasets)        │
│    (turing_test.zig: automated evaluation framework)            │
│    (sentience_experiment.zig: control experiment framework)     │
├─────────────────────────────────────────────────────────┤
│           External Model Sidecars (optional)              │
│   neural_lm.zig (Qwen3-0.6B ONNX) — confidence-routed     │
│   llama_server.zig — streaming fallback, /no_think path   │
│   ollama_client / openai_client / kimi_stream_adapter     │
├─────────────────────────────────────────────────────────┤
│                  Lattice Agent                            │
│         (agent.zig — 421 E0 nodes × 8 channels)          │
│   E0 firing → octonion routing → Fano coupling →         │
│   Fibonacci projection → φ-cooling → SAMC → decode       │
│   Metacognition engine: introspect → evaluate → correct  │
├──────────────┬──────────────┬───────────────────────────┤
│  BPE Tokenizer│   Sampling   │  Knowledge Graph          │
│  + Ramsey Vocab│ (temp/top-k)│  + Memory + Perception    │
├──────────────┴──────────────┴───────────────────────────┤
│     Fixed-Point Math: Q64.64 lattice / Q128.128 semantic  │
│     Hardware Auto-Detection + Precision Scaling           │
│     Lattice Geometry (A1-A7) + Dimensional Modules 0D-10D │
├─────────────────────────────────────────────────────────┤
│    Holographic Projection / Compression (S0↔S7)          │
│    TurboQuant Sidecar / holo_codec / seed_compressor     │
├─────────────────────────────────────────────────────────┤
│  NATIVE VISION (src/vision/*)   GOD'S EYE VIEW (geoview) │
│  ONNX Runtime C FFI (c_ffi.zig) Live feeds (ADSB/AIS/    │
│  Face detect/recognize/landmark/ USGS/TLE) + geo_math    │
│  track/gaze/attributes/parsing/  Globe renderer + camera │
│  quality/anti-spoofing/analyzer  HUD + annotations +     │
│                                  scene director + voice  │
└─────────────────────────────────────────────────────────┘
```

## Build Targets

| Command | Description |
|---------|-------------|
| `zig build` | Build example + CLI + WASM |
| `zig build test` | Run all unit tests |
| `zig build test-agent` | Agent tests only (173) |
| `zig build test-main` | main CLI tests only |
| `zig build test-turing` | turing_test tests only |
| `zig build run` | Run example application |
| `zig build cli` | Run CLI binary |
| `zig build serve` | Run HTTP API server |
| `zig build manual` | Run manual integration tests |
| `zig build samc` | Run SAMC validation |
| `zig build audit` | Run agent dual-mode audit |
| `zig build ollama-bench` | Head-to-head benchmark vs Ollama |
| `zig build competitive-bench` | Competitive benchmark (Qstar vs Ollama vs OpenAI vs Maple) |
| `zig build qstar-bench` | Qstar-only benchmark with cross-judging |
| `zig build semantic-train` | Semantic training (OpenAI prompts + teacher) |
| `zig build competitive-train` | 5-phase competitive training pipeline |
| `zig build training-heartbeat` | Training heartbeat cycle |
| `zig build cognitive-metabench` | Deterministic cognitive-lane metabench |
| `zig build meta-bench` | Metacognitive benchmark vs Ollama judge |
| `zig build maple-bench` | Maple device benchmark over LAN |
| `zig build maple-standard-bench` | Maple-only standard benchmark |
| `zig build vulkan-bench` | CPU vs Vulkan GPU benchmark |
| `zig build shaders` | Build Vulkan shaders (requires glslc) |
| `zig build tool-test` | Tool server integration tests |
| `zig build vision-test` | Vision pipeline tests |
| `zig build geoview-test` | Geoview pipeline tests |
| `zig build regression` | Full regression harness |
| `zig build wasm` | Build WASM module |
| `zig build corpus` | Build .qsc corpus container |
| `zig build html` | Build self-contained universe.html |
| `zig build seed` | Compress agent state to `zig-out/qstar_seed.bin` |
| `zig build master` | CI/CD gate: regression + build + publish |

### Mesh & Transport CLI Commands

| Command | Description |
|---------|-------------|
| `qstar mesh start [port]` | Start virtual mesh node (default: 9000) |
| `qstar mesh join <host:port>` | Join existing mesh network |
| `qstar mesh status` | Show mesh topology, peer count, transport modes |
| `qstar mesh broadcast <msg>` | Broadcast message to all connected peers |
| `qstar mesh relay <peer> <msg>` | Multi-hop relay to specific peer |
| `qstar transport list` | List available virtual transport modes |
| `qstar transport send <mode> <file>` | Send file via specific transport mode |
| `qstar transport recv` | Listen for incoming transport payloads |
| `qstar quine build` | Build self-contained universe.html quine edition |
| `qstar quine publish` | Publish quine + payloads |
| `qstar collapse simulate` | Simulate civilization collapse (degrade transports) |
| `qstar collapse status` | Show current transport fallback level |
| `qstar collapse recover` | Restore all transport modes from collapse |

## Data Assets

| Asset | Size | Purpose |
|-------|------|---------|
| models/qwen1.5-0.5b-chat/ | 471MB | BPE tokenizer model |
| .foundations/RamseyLLM/vocabs/ | 23MB | Level-scaled vocab files (128k-1m) |
| qstar_corpus_full.qsc | 526 MB | Full compressed corpus — default for chat/run/serve |
| qstar_corpus.qsc | 49 MB | Compressed corpus subset (earlier build) |
| qstar_corpus.txt | ~723 KB | Working raw-text corpus in this checkout |
| qstar_corpus_large.txt | 2.9 GB | Full raw corpus (symlink, 65.8M lines) |
| qstar_memory.json | 210KB | Trained memory state |
| turing_results.json | 19KB | Turing test results |
| datasets/Gov/ | 9MB | Governance docs (1,091 .md files) |
| datasets/AdmPaul/ | 15MB | AdmPaul corpus (83 files) |
| datasets/webster_dictionary/ | 27MB | Webster's Dictionary (6 files) |
| datasets/blacks_law/ | 28KB | Black's Law Dictionary (3 files) |
| datasets/general_knowledge/ | 24KB | General knowledge reference (5 files) |
| datasets/wikipedia/ | 16KB | Wikipedia article extracts (3 files) |

## Performance vs Ollama

Historical benchmark (see `docs/AGENT_OLLAMA_BENCHMARK.md` for latest runs — 86 Qstar wins vs 54 opponent wins, MMLU 0.81, GSM8K 1.00):

| Metric | Qstar-LLM | Ollama (qwen2.5:3b) | Advantage |
|--------|-----------|----------------------|-----------|
| TTFT | 0.199ms | 2,240ms | ~11,000x faster |
| Tokens/sec | 67,012 | 5.76 | ~11,600x faster |
| Memory | ~53.9KB state | 986MB | ~18,000x smaller |
| Output format | Structured | Free-form | Template-matched |
