# Qstar-LLM Architecture

**Version 3.5.0** | Zig 0.13.0+ | Zero external dependencies | 1,268 tests + 44 tool tests + 61 regression checks | Integer-only core state (i128 Q64.64)

Qstar-LLM is a standalone lattice-native LLM inference engine, extracted from the Qstar project. It uses no foreign models — all inference is performed by the lattice agent with Q64.64 fixed-point integer arithmetic (i128 storage, i256 intermediates). Native vision (face analysis) and God's Eye View (geospatial intelligence) subsystems are integrated via C FFI (dlopen pattern) with pure Zig logic. Hardware auto-detection selects optimal precision tier at comptime; Q64.64 states are downscaled to Q32.32 for Maple/ESP32/WASM peripheral consumption via the fp_bridge.

## Design Principles

1. **Purity** — Core `.zig` files import only `std`. No external dependencies.
2. **First Principles** — Every function traces to a lattice axiom (A1-A7).
3. **Bit-Exact Determinism** — Same input + same seed = same output, always.
4. **Integer-Only Core State** — All lattice state is i128 Q64.64 fixed-point (i256 intermediates for mul). f64 is used only in sidecar math (turbo_quant, holographic projection, vision/geoview coordinates). Hardware auto-detection (`hardware_detect.zig`) selects precision tier at comptime; `fp_bridge.zig` downscales Q64.64 → Q32.32 for peripheral/WASM consumption.
5. **Standalone** — Single `zig build` command compiles and tests everything.
6. **Graceful Degradation** — Vision/geoview modules degrade to lattice-only operation when external libraries (ONNX Runtime, libvulkan) are unavailable.

## Module Inventory

### Core Source Modules (44)
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| fixed_point.zig | 714 | 27 | Q64.64 fixed-point arithmetic (i128, i256 intermediates) |
| hardware_detect.zig | 120 | 4 | Comptime + runtime CPU detection, precision tier, SIMD width |
| fixed_point32.zig | 280 | 12 | Q32.32 (i64) module for Maple/ESP32/WASM peripherals |
| fp_bridge.zig | 200 | 10 | Q64.64 → Q32.32 downscale with rounding + overflow protection |
| precision_scaler.zig | 150 | 8 | Hardware-agnostic precision scaling orchestrator |
| lattice.zig | 1,339 | 49 | E0 node placement, lattice geometry, scaled token mapping |
| bpe_tokenizer.zig | 720 | 13 | BPE tokenizer + Ramsey vocab scaling |
| sampling.zig | 475 | 11 | Temperature, top-k, top-p, multinomial |
| agent.zig | 8,742 | 167 | Lattice inference engine (E0 firing, octonion routing, Fibonacci projection, φ-cooling, SAMC relaxation, long-form generation, metacognition, creative routes, naturalness engine, semantic retrieval, speculative draft mode, level scaling, 8-dim sentience scoring, Matrix15 text-to-scalar-field bridge, control experiment framework, hardcoded factual response routes for 30+ common topics, short-prompt routes, E=mc² mass-energy equivalence route) |
| memory.zig | 402 | 4 | 3-layer cognitive memory (working + episodic + callbacks) |
| perception.zig | 1,203 | 31 | Perception pipeline, activation detection, liveness, introspection |
| knowledge_graph.zig | 621 | 6 | Knowledge graph with entity/relation extraction |
| state_store.zig | 221 | 4 | Agent state persistence |
| face_sync.zig | 279 | 7 | Face synchronization |
| ollama_client.zig | 613 | 19 | Zero-dep Ollama HTTP client + draft verification + Content-Length parsing + streaming generation with advanced options (think, max_tokens, top_p, num_threads, keep_alive) |
| doc_loader.zig | 441 | 6 | Recursive document preprocessor |
| memory_pool.zig | 218 | 8 | Block pool + bump arena allocators |
| config.zig | 88 | 3 | Unified JSON configuration |
| external_db.zig | 142 | 2 | External database connector |
| continual_learner.zig | 351 | 5 | Background continual learning heartbeat |
| training.zig | 1,234 | 5 | Self-training + internet training (Wikipedia API) + dataset ingestion |
| turing_test.zig | 717 | 6 | Automated Turing test framework |
| tools.zig | 3,366 | 54 | 58-tool calling engine |
| server.zig | 1,642 | 19 | Ollama + OpenAI-compatible HTTP server (concurrent, streaming, vision/geoview routes) |
| main.zig | 1,798 | 0 | CLI binary (serve, run, chat, train, train-internet, ingest-corpus, turing-test, experiment, draft-mode, master-serve, publish-p2p) |
| wasm_exports.zig | 265 | 0 | WASM export bindings (Q64.64 → Q32.32 downscale via fp_bridge) |
| holographic.zig | 1,128 | 34 | S0↔S7 holographic projection/compression |
| master_server.zig | 649 | 7 | Master node HTTP server + WebRTC signaling/relay bridge (browser P2P mirror) |
| master_publish.zig | 81 | 1 | Master payload publisher (zig-out/ → zig-out/master/) |
| p2p_update.zig | 256 | 3 | P2P mirror publish (qstar-net bootstrap + qstar-vfs placement) → p2p_index.json |
| dynamic_dns.zig | 230 | 16 | ClouDNS dynamic DNS updater (HTTPS, retry, env config) |
| build_html.zig | 449 | 2 | universe.html builder (WASM + distilled corpus + compressed seed embed, seed manifest) |
| env_loader.zig | 95 | 3 | .env file loader for API keys and configuration |
| openai_client.zig | 281 | 4 | Zero-dep OpenAI HTTP client (TLS HTTPS) |
| compress.zig | 350 | 10 | Self-contained compressor (dedup + gzip + lattice + RMSY) |
| corpus_store.zig | 280 | 5 | Quine-style .qsc corpus container with LRU page cache |
| corpus_seed.zig | 120 | 2 | Corpus seed text for agent initialization |
| corpus_seed_lite.zig | 80 | 1 | Lightweight corpus seed for WASM/embedded contexts |
| agent_lite.zig | 200 | 3 | Lightweight agent for WASM/embedded inference |
| heartbeat.zig | 680 | 4 | Training heartbeat: corpus loading, memory/benchmark/Turing learning, generated prompts |
| prompt_generator.zig | 160 | 2 | Ollama-based random prompt generation for training |
| maple_client.zig | 140 | 2 | Maple protocol client for distributed corpus publishing |
| vulkan_compute.zig | 180 | 3 | Vulkan compute shader FFI loader (dlopen pattern) |
| c_ffi.zig | 95 | 10 | Unified C FFI loader (dlopen/dlsym pattern) |

### Mesh & Transport Modules (22)
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| virtual_transport.zig | 968 | 12 | Virtualized transport layer over TCP, VirtualMeshNode, VirtualTransportRouter, store-and-forward, collapse mode |
| mesh.zig | 2,100 | 18 | ConnectionManager, TransportRouter, OfflineTransportRouter, LatticeCell |
| mesh_peer.zig | 820 | 10 | TCP mesh peer with XChaCha20-Poly1305 encryption |
| p2p_types.zig | 900 | 14 | PeerId, Location, Peer, PeerManager, MessageType |
| relay_router.zig | 800 | 8 | Multi-hop relay routing, rendezvous discovery |
| nat.zig | 740 | 12 | NAT traversal (UDP hole punching, STUN, QR relay fallback) |
| webrtc.zig | 310 | 4 | WebRTC data channel protocol logic (SDP, ICE, DTLS, SCTP) |
| collapse.zig | 620 | 8 | QR portal encoding for physical transport (virtualized) |
| qr_nest.zig | 850 | 10 | Recursive QR nesting for multi-layer data transport |
| transport_p2p.zig | 220 | 5 | X25519 + ChaCha20Poly1305 packet transport |
| transport_wifi.zig | 88 | 3 | WiFi CSI frame transport (virtualized) |
| transport_quine.zig | 86 | 3 | Self-referential HTML quine transport |
| transport_polyglot.zig | 700 | 8 | Multi-format polyglot file transport |
| transport_stega.zig | 146 | 3 | LSB steganography transport (virtualized) |
| transport_qr.zig | 180 | 4 | QR code transport |
| transport_audio.zig | 120 | 3 | Audio frame transport |
| transport_cassette.zig | 160 | 3 | Cassette tape transport |
| transport_convert.zig | 200 | 4 | Format conversion utilities |
| transport_lora.zig | 800 | 8 | LoRa frame transport |
| transport_optar.zig | 180 | 3 | Optical art transport |
| transport_paperback.zig | 185 | 3 | Paperback book transport |
| transport_video.zig | 128 | 3 | Video frame transport |

### Prototype Modules (13)
| Module | Lines | Tests | Role |
|--------|-------|-------|------|
| discourse_agent.zig | 120 | 1 | Structured multi-paragraph discourse generation |
| turbo_quant.zig | 1,175 | 30 | TurboQuant vector quantization sidecar |
| samc_lattice.zig | 403 | 6 | SAMC lattice topology |
| samc_agent.zig | 262 | 2 | Multi-channel SAMC accelerated reasoning |
| vocab_loader.zig | 194 | 3 | Vocabulary file loader |
| vocab_lattice_scaling.zig | 920 | 25 | Level-scaled token-to-node mapping |
| lattice_context.zig | 139 | 2 | Lattice context management |
| agent_int.zig | 481 | 9 | Integer-only lattice inference prototype |
| holographic_int.zig | 567 | 8 | Integer holographic projection |
| quantum_int.zig | 730 | 15 | Integer quantum simulation |
| mesh_int.zig | 292 | 10 | Integer mesh networking |
| s0_projection.zig | 2,318 | 55 | S0→S7 holographic projection prototype |
| s7_compression.zig | 1,862 | 45 | S7→S0 lattice compression prototype |

### Native Vision Modules (13)
| Module | Tests | Role |
|--------|-------|------|
| c_ffi.zig | 10 | Unified C FFI loader (dlopen/dlsym pattern from vulkan_compute.zig) |
| vision/onnx_runtime.zig | 11 | ONNX Runtime C API bindings (OrtApi, session lifecycle, tensor management) |
| vision/image.zig | 20 | Image I/O & preprocessing (stb_image FFI, resize, color conversion, NCHW tensor) |
| vision/face_detect.zig | 16 | Face detection post-processing (SCRFD/RetinaFace/BlazeFace, NMS, anchor decoding) |
| vision/face_recognize.zig | 21 | Face recognition (ArcFace alignment, embedding extraction, cosine similarity) |
| vision/face_landmark.zig | 19 | Facial landmarks (PIPNet 98/68, FaceMesh 468/478, meanface templates) |
| vision/face_track.zig | 16 | Multi-face tracking (BYTETracker, Kalman filter, IoU association) |
| vision/gaze_headpose.zig | 13 | Gaze estimation & 6D head pose (pitch/yaw/roll) |
| vision/face_attributes.zig | 14 | Demographics & emotion (gender, age, race, 8-class emotion, face state) |
| vision/face_parsing.zig | 13 | Face parsing/segmentation (BiSeNet 19-class, XSeg masking) |
| vision/face_quality.zig | 12 | Face quality assessment (eDifFIQA, blur/illumination/occlusion heuristics) |
| vision/anti_spoofing.zig | 16 | Anti-spoofing/liveness (MiniFASNet, print/replay/photo detection) |
| vision/face_analyzer.zig | 13 | Unified FaceAnalyzer pipeline (detect → align → recognize → predict) |

### God's Eye View Modules (16)
| Module | Tests | Role |
|--------|-------|------|
| geoview/geo_math.zig | 16 | Geospatial math (WGS84, LLA↔ECEF↔ENU, MGRS, great-circle, bearing) |
| geoview/globe_render.zig | 14 | 3D globe renderer (ellipsoid mesh, frustum culling, billboards, entities) |
| geoview/camera.zig | 14 | Camera controllers (flyTo, orbit, tracked entity, easing, dead-reckoning) |
| geoview/live_feeds.zig | 10 | Feed manager (layer registration, lifecycle, state machine) |
| geoview/feed_flights.zig | 9 | OpenSky flight tracking (aircraft state, classification, dead-reckoning) |
| geoview/feed_vessels.zig | 7 | AIS vessel tracking (vessel state, type classification, nav status) |
| geoview/feed_satellites.zig | 7 | Satellite tracking (TLE parsing, SGP4 propagation, Celestrak) |
| geoview/feed_earthquakes.zig | 4 | USGS earthquake feed (GeoJSON parsing, magnitude filtering) |
| geoview/feed_traffic.zig | 6 | TomTom traffic feed (flow segments, incidents, congestion) |
| geoview/feed_cctv.zig | 8 | CCTV camera management (registry, snapshots, viewshed) |
| geoview/hud.zig | 10 | Intelligence HUD (compass, scale bar, MGRS readout, alerts) |
| geoview/detection_overlay.zig | 8 | Detection overlays (screen projection, bounding boxes, labels) |
| geoview/annotation.zig | 8 | Annotations engine (pins, routes, measurements, GeoJSON export) |
| geoview/scene_director.zig | 10 | Scene director (focus queue, storyboards, playback) |
| geoview/styles.zig | 9 | Sensor style shaders (thermal, NVG, FLIR, CRT, noir, snow) |
| geoview/voice_command.zig | 12 | Voice command processing (intent parsing, action registry) |

### Integration Test Suites (3)
| Suite | Tests | Coverage |
|-------|-------|----------|
| tests/vision_test.zig | 25 | End-to-end vision pipeline (detect → recognize → track → analyze) |
| tests/geoview_test.zig | 30 | End-to-end geoview pipeline (feeds → globe → camera → HUD → voice) |
| tests/full_regression.zig | 61 checks | Full regression harness (16 steps: agent, tools, server, training, Turing, vision, geoview, WASM/HTML, master node) |

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
│   37 core + 6 vision + 9 geoview + 5 feeds = 58 tools    │
├─────────────────────────────────────────────────────────┤
│        Training / Internet Training / Turing Test / Experiment  │
│    (training.zig: self-train + Wikipedia API + datasets)        │
│    (turing_test.zig: automated evaluation framework)            │
│    (agent.zig: control experiment + sentience scoring)          │
├─────────────────────────────────────────────────────────┤
│                  Lattice Agent                            │
│              (agent.zig — 421 E0 nodes)                   │
│   E0 firing → octonion routing → Fibonacci projection    │
│   → φ-cooling → SAMC relaxation → decode                 │
├──────────────┬──────────────┬───────────────────────────┤
│  BPE Tokenizer│   Sampling   │  Knowledge Graph          │
│  + Ramsey Vocab│ (temp/top-k)│  + Memory + Perception    │
├──────────────┴──────────────┴───────────────────────────┤
│              Fixed-Point Math (Q64.64 / i128)             │
│              Hardware Auto-Detection + Precision Scaling  │
│              Lattice Geometry (A1-A7)                     │
├─────────────────────────────────────────────────────────┤
│    Holographic Projection / Compression (S0↔S7)          │
│    TurboQuant Sidecar / SAMC Lattice                     │
├─────────────────────────────────────────────────────────┤
│  NATIVE VISION (src/vision/*)   GOD'S EYE VIEW (geoview) │
│  ONNX Runtime C FFI (c_ffi.zig) Live feeds (ADSB/AIS/    │
│  Face detect/recognize/landmark/ USGS/TLE) + geo_math    │
│  track/gaze/attributes/parsing/  Globe renderer + camera │
│  quality/anti-spoofing/analyzer  HUD + annotations +     │
│                                  scene director + voice  │
└─────────────────────────────────────────────────────────┘
```

## Lattice Constants

- E0 node count: 421
- Reasoning channels: 7
- Active state size: 47 KB (421 × 7 × 16 bytes, Q64.64 i128)
- Downscaled state: 23.5 KB (421 × 7 × 8 bytes, Q32.32 i64 for peripherals)
- Vocab size: 151,936 (Qwen BPE)
- Base lattice edge: 15 (s=0), doubling to 1920 (s=7)
- Compression ratio: 262,688:1 (S7 full → S0 seed)

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
| `zig build tool-test` | Run tool server integration tests (44) |
| `zig build vision-test` | Run vision pipeline integration tests (25 tests) |
| `zig build geoview-test` | Run geoview integration tests (30 tests) |
| `zig build regression` | Run full regression harness (all 61 checks) |
| `zig build wasm` | Build WASM module for browser embedding |
| `zig build html` | Build self-contained `universe.html` with embedded WASM + compressed seed |
| `zig build seed` | Compress agent state to `zig-out/seed/qstar_seed.bin` |
| `zig build corpus` | Build compressed `.qsc` corpus container from `qstar_corpus.txt` |
| `zig build training-heartbeat` | Run training heartbeat cycle (corpus learning, memory, benchmarks, generated prompts) |
| `zig build qstar-bench` | Run Qstar internal benchmark suite |
| `zig build maple-bench` | Run Maple protocol benchmark |
| `zig build maple-standard-bench` | Run Maple standard benchmark |
| `zig build vulkan-bench` | Run Vulkan compute benchmark |
| `zig build shaders` | Build Vulkan shaders |
| `zig build master` | CI/CD gate: regression + build + publish quine payloads to `zig-out/master/` |

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
| `qstar quine publish` | Publish quine + payloads to GitHub Pages branch |
| `qstar collapse simulate` | Simulate civilization collapse (degrade transports) |
| `qstar collapse status` | Show current transport fallback level |
| `qstar collapse recover` | Restore all transport modes from collapse |

## Data Assets

| Asset | Size | Purpose |
|-------|------|---------|
| models/qwen1.5-0.5b-chat/ | 471MB | BPE tokenizer model |
| .foundations/RamseyLLM/vocabs/ | 23MB | Level-scaled vocab files (128k-1m) |
| qstar_corpus.txt | 327 MB | Trained corpus (3,999,383 sentences, 1,155 Wikipedia articles + dataset ingestion + OpenAI teacher) |
| qstar_memory.json | 210KB | Trained memory state |
| turing_results.json | 19KB | Turing test results |
| datasets/Gov/ | 9MB | Governance docs (1,091 .md files: legal, ethics, financial, onboarding) |
| datasets/AdmPaul/ | 15MB | AdmPaul corpus (83 files: sci-fi, governance, technical architecture) |
| datasets/webster_dictionary/ | 27MB | Webster's Dictionary (6 files) |
| datasets/blacks_law/ | 28KB | Black's Law Dictionary (3 files) |
| datasets/general_knowledge/ | 24KB | General knowledge reference (5 files) |
| datasets/wikipedia/ | 16KB | Wikipedia article extracts (3 files) |

## Performance vs Ollama

| Metric | Qstar-LLM | Ollama (qwen2.5:3b) | Advantage |
|--------|-----------|----------------------|-----------|
| TTFT | 0.199ms | 2,240ms | 11,279x faster |
| Tokens/sec | 67,012 | 5.76 | 11,632x faster |
| Memory | 48.7KB | 986MB | 20,741x smaller |
| Output format | Structured | Free-form | Template-matched |
