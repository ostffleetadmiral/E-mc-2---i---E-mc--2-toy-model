# Dependency Map & Wiring Audit (2026-09-16)

Baseline: `corpus-delta-persistence-20260916`. 157 `.zig` files (129 src + 12 vision + 16 geoview), 32 build steps.

> **2026-09-18 update:** file count is now 165 `.zig` (137 top-level src/ + 28 vision/+geoview/) — +8 multimodal modules (corpus_index, creative_composer, longcat_port, modality, model_registry, safetensors, splat_render, weight_distill). Sweep-S1 wiring records (27 core-math modules, per-module import/importee graph) live in `RETRO_DEV_AUDIT.md` §3. S1 orphan inventory: precision_scaler, so10, codon, e8_roots, turbo_quant, lattice_compressor, holographic_memory, holo_codec, s0_projection, s7_compression, distillation_s0.
>
> **S2 update (2026-09-18):** dimensional-stack wiring recorded in `RETRO_DEV_AUDIT.md` §3 Sweep S2 (39 modules). S2 orphan inventory: dim_0d_origin, dim_1d_time, dim_3d_space, dim_10d_gravity, routing_calibration (harness-only via tests/cognitive_metabench), memory_pool, cognitive_cloud (dead `addImport` into agent_mod — never `@import`'ed), sentience_experiment. S2 blocked (parent-repo deps absent): hw_elevation_paths, hw_final_audit, hw_generative_chain, hw_self_claims. `agent_lite` is wired as the esp32 device-lite wasm root (aliased as `agent`); dim_2d/4d/7d/8d/9d reach production via `main`→`longcat_port`.
>
> **S3 update (2026-09-18):** data/training wiring recorded in `RETRO_DEV_AUDIT.md` §3 Sweep S3 (18 modules, 17 WIRED). S3 orphan inventory: `vocab_lattice_scaling` (dead `addImport` into agent_mod/cli_mod, never `@import`'ed). `heartbeat` wires via the `training-heartbeat` build step; `corpus_seed_lite` via esp32-lite alias; `seed_compressor` via collapse_resilience (exe step lacks `main` — documented build gap). `training`/`neural_lm` sweep fails are the onnx_runtime dep-resolution gap, not module failures.
>
> **S4 update (2026-09-18):** serving/client wiring recorded in `RETRO_DEV_AUDIT.md` §3 Sweep S4 (15 modules, 13 WIRED). S4 orphan inventory: `config` (dead `addImport` on exe root, never `@import`'ed), `kimi_stream_adapter` (harness-only via cognitive_metabench exe + dead addImport into agent_mod). Sweep gaps are harness wiring, not module failures: server/wasm_exports (onnx_runtime/build_options), c_ffi (`-ldl`), tools (geo_math vision wiring).
>
> **S5 update (2026-09-18):** multimodal/weights + vision/geoview wiring recorded in `RETRO_DEV_AUDIT.md` §3 Sweep S5 (35 modules). All 7 top-level multimodal modules WIRED (weight_distill→main/longcat_port/model_registry; safetensors; model_registry; modality; longcat_port→main; splat_render; voice_codec→agent). Vision subsystem (12): harness-wired via `vision-test`+`regression` steps through `face_analyzer` — no production src importer (orphan-from-runtime, retained under regression); `onnx_runtime` additionally WIRED via neural_lm. Geoview (16): 10 WIRED via tools/main (geo_math, annotation, feed_cctv/earthquakes/flights/satellites/vessels, hud, scene_director); 6 ORPHAN (camera→globe_render dead chain, detection_overlay, feed_traffic, live_feeds, styles, voice_command).
>
> **S6 update (2026-09-18):** transport/mesh/resilience wiring recorded in `RETRO_DEV_AUDIT.md` §3 Sweep S6 (31 modules). Major finding: **all 13 `transport_*` codecs are dead wiring** — `addImport`'d onto cli_exe/main_tests but never `@import`'ed (virtual_transport routes only `mesh`). Orphan inventory: transport_×13, mesh_peer→relay_router→p2p_types chain (3), nat, webrtc, master_publish, collapse_recover, hardware_detect (orphan via precision_scaler). WIRED: virtual_transport, qr_nest, mesh, sybil, master_server, dynamic_dns, collapse, collapse_resilience, vulkan_compute, p2p_update (sweep blocked on absent `vfs_distributed`).
>
> **S7 update (2026-09-18):** harness + prototype inventory recorded in `RETRO_DEV_AUDIT.md` §3 Sweep S7 (19 harnesses, 14 prototype files, 1 example). Prototype→src duplicates flagged for next cycle: s0_projection, s7_compression, turbo_quant, vocab_lattice_scaling (both copies under test — no deletion per archive policy).

## Reachability summary

| Class | Count | Meaning |
|-------|-------|---------|
| Reachable from executables | 116 | Production/test binary wiring via `addImport` |
| Test-target-only (prototypes) | 31 | Standalone `zig build test-*` / manual `zig test` roots — intentional prototypes, never imported by production code |
| **Unwired (pre-audit)** | **29** | Built, tested standalone, **reachable from nothing** |

## Phase 2 wiring progress (2026-09-16)

| Cluster | Status |
|---------|--------|
| Collapse data pipeline | **WIRED** — `qstar collapse persist <file>` runs RS→Shamir→QR→media pipeline; `collapse.zig` fixed (`qr_nest.zig` path-import → module import); `collapse_resilience`/`collapse_recover` registered as test targets (8+9 tests pass) |
| hw_* proof ports (8 self-contained) | **WIRED** — `framework-audit` now runs 13 real proof checks (all pass); fixed `PROVEN_CLAIMS`→`DETERMINED_CLAIMS` port bug in hw_surface_computation, duplicate `verifyF4Dimension` in hw_jordan_algebra, `octonion.zig`→`octonion_math` repoint ×2 |
| hw_* heavy-dep (4) | **BLOCKED** — `hw_generative_chain`, `hw_final_audit`, `hw_self_claims`, `hw_elevation_paths` path-import ~14 modules that only exist in parent `hardware/` repo (octonion, so10_decomposition, electric_charges, so8_triality, pati_salam, scaling_analysis, checksum_6d, anti_octonion, dual_b_complex, consciousness_audit, literature_review, surface_computation, generative_chain, final_audit). Phase 4 candidate |
| dim_* modules (9 unwired) | Test targets registered in build.zig (all pass: 5/5/9/6/11/5/10/9/9); deeper agent integration deferred — needs operational-role design |
| quantum/entangle/merge/sybil | Test targets registered (33/14/14 pass); `quantum` is already in agent_mod's import table but never `@import`ed — CLI integration deferred |
| lattice_compressor/distillation_s0 | Test targets registered (8/9 pass); self-consistent 7-channel/i64 prototypes |
| ONNX Runtime | **FIXED** — `Int64` test expected 9 (BOOL); corrected to 7. Teardown segfault eliminated: `dlclose` on libonnxruntime 1.23 crashes in global destructors; `deinit` now releases env without unloading |
| Metacognition monitor | **FIXED** — race: bg thread evaluated zero-initialized shared state (coherence=0) between `setGenerationActive(true)` and first `updateSharedState`, triggering spurious corrections via `shouldSelfCorrectF64`. `shared_state_valid` atomic now gates evaluation; cleared on generation stop |

## Truly unwired modules (the plumbing gaps — baseline findings, pre-Phase-2)

### Dimensional modules — documented as agent-composed, only 5D+6D wired *(partially resolved: build test targets registered)*
`agent.zig` imports `dim_5d_language` + `dim_6d_consciousness` only. Unwired:
`dim_0d_origin`, `dim_1d_time`, `dim_2d_complex`, `dim_3d_space`, `dim_4d_rotation`, `dim_7d_color`, `dim_8d_frequency`, `dim_9d_chaos`, `dim_10d_gravity` — tested via ad-hoc `zig test` (AGENTS.md), no build.zig target, no production import.

### Hardware proof ports (`hw_*` ×11) *(partially resolved: 8 wired into `framework-audit`, 4 blocked on parent-repo deps)*
`hw_consciousness_audit`, `hw_e8_roots`, `hw_electric_charges`, `hw_elevation_paths`, `hw_final_audit`, `hw_generative_chain`, `hw_jordan_algebra`, `hw_literature_review`, `hw_octonion`, `hw_scaling_analysis`, `hw_self_claims`, `hw_surface_computation`.
`agent.zig` imports `hw_bridge` (a constants/verification shim) — it does NOT re-export or invoke the hw_* modules.

### Collapse resilience — data side unwired *(resolved: `qstar collapse persist` wires the full pipeline; `collapse` test spec now carries `qr_nest` dep)*
`collapse_resilience.zig` (orchestrator: compress → error-correct → secret-share → QR/physical), `collapse_recover.zig` (recovery side), `collapse.zig`. The CLI `collapse` command drives only `virtual_transport`'s router (`simulateCollapse`/`isCivilizationCollapse`) — the knowledge-preservation pipeline is never invoked.

### Other unwired *(partially resolved: `qstar quantum` CLI added; test targets registered for quantum/entangle/merge/sybil/lattice_compressor/distillation_s0)*
`quantum.zig` (1,272 LOC gate model), `entangle.zig` (1,253 LOC entanglement/ECC/stega), `merge.zig` (Möbius CRDT), `sybil.zig` (proof-of-lattice-work), `lattice_compressor.zig` (S7↔S0 TurboQuant — note: stale 7-channel comment), `distillation_s0.zig`, `sentience_experiment.zig`, `tests/meta_bench.zig` (step exists, file not reached by other targets — verify).

## Duplicate / overlap clusters (Phase 2 consolidation candidates)

| Cluster | Modules | Note |
|---------|---------|------|
| Compression | `s7_compression`, `compress`, `lattice_compressor`, `holo_codec`, `turbo_quant`, `holographic` | 6 implementations; pick canonical per use-case |
| LLM clients | `ollama_client`, `openai_client`, `llama_server`, `maple_client`, `kimi_stream_adapter`, `neuraleak_ollama_client` | `llm_provider` unifies text completions (`complete`/`judgeComplete`); bench opponent/judge backends remain per-provider by design |
| Generative video | `splat_render` (3DGS rasterizer), `longcat_port` (11D analogs), `safetensors` (weight container), `weight_distill` (tensor→seed), `holo_codec`, `transport_video`, `vision/*`, `face_sync` | LongCat-Video-Avatar-1.5 reverse map — see `docs/LONGCAT-REVERSE-MAP.md` |
| Multimodel coverage | `modality` (modality→11D routes), `model_registry` (32-component sweep table), `weight_distill` (`detectFamily`/`dominantFamily`), `safetensors`, `weights/registry.json` (digest sidecar) | All-of-AI lattice-native sweep — see `docs/MULTIMODAL-MAP.md` |
| Corpus | `corpus_store` (.qsc), `corpus_index` (word→page inverted index, `datasets/qsc_index.bin`), `corpus_learner`, `corpus_seed`, `corpus_seed_lite`, `loadCorpus*` in agent | One ingestion contract needed |
| Transports | `transport_{audio,cassette,convert,lora,optar,p2p,paperback,polyglot,qr,quine,stega,video,wifi}` + `virtual_transport` | 13 transport impls; CLI wires only virtual_transport's router |
| hw_* ports | see above | Partial duplicate of hardware/ parent proof modules |

## Hot modules (most depended-on)
`fixed_point` (34 importers), `q128` (14), `agent`, `ollama_client`, `knowledge_graph` (6 each), `dynamic_routes`, `jordan_algebra` (5), `lattice`, `corpus_store`, `tools`, `env_loader` (4).

`agent.zig` has 30 module imports; `main.zig` 28 — the two wiring hubs.

## Build graph notes
- Module specs are declared per-executable; test specs must mirror production imports or fail to compile (the `test-agent`/`test-main` drift fixed 2026-09-16).
- `meta-bench` build step exists; verify `tests/meta_bench.zig` is reachable from it.
