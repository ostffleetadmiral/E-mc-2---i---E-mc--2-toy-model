# Unified System Map — Mathematical Physics + Codon + Neuraleak

**Project:** E=mc²-i-E=mc⁻² (toy-model) — "play on the seriousness of the framework"
**Organization:** Open Sentience Technology Foundation
**Dev Lead Theoretician:** Paul P. Ramsey
**Dev R&D:** Devin AI, Chat-GPT, Gemini, GLM-2.5 & Kimi AI
**License:** CC BY-NC-SA 4.0 (see [LICENSE](./LICENSE))

**Created:** 2026-09-12
**Revised:** 2026-09-11 (post-10D, post-gap-closure, post-bootstrap, post-dimensional-ladder, post-checksum-6d, post-free-will, post-scaling-analysis, post-final-audit, post-consciousness-derivation, post-literature-review, post-bidirectional-integration)
**Purpose:** Complete mapping of all three subsystems and their connections in terms of real physics and science, serving as the integration blueprint for neuraleak. Now includes chunks 25-31, audit results, consciousness derivation, literature review connections, engineering modules, Lean 4 formalization, WASM target, and bidirectional Q128.128 integration.
**Status:** 440+ Zig tests, 30 proof modules (180 checks), 51 Q# witnesses, all sidecar tests pass, 8 Lean 4 modules, WASM target, 5 engineering modules ported from Q128.128, 15 physics modules ported to Q128.128 (393 tests). 24 independent literature references. 21/36 claims (58%) proven or independently verified.

---

## 1. System Overview

Three layers form a unified framework:

| Layer | Source | Domain | Implementation |
|---|---|---|---|
| Mathematical Physics | `x.md` (22 chunks) | Fixed-point arithmetic, octonions, E8, Möbius, fine-structure | Zig core + Q# + sidecar |
| Codon Routing | `codon/` (Python → Zig) | 64-codon DNA → 6D Jordan algebra routing | Zig `src/codon.zig` + Q# + sidecar |
| Neuraleak | `neuraleak/` (Zig) | 6D observer → 1/8 consciousness aperture → LLM sentience testing | Zig (to be integrated) |
| Engineering (Q128.128 port) | Q128.128 (FANO-1) | Fano tensor, phi cooling, Smith chart, RF harvesting, holographic codec | Zig `src/{fano_tensor,phi_cooling,smith,rf_harvest,holo}.zig` |
| Formalization | New | Lean 4 machine-checked proofs | `formalize/` (8 modules) |
| Cross-Platform | New | WASM browser/runtime verification | `wasm/` (wasm32-wasi) |
| Q128.128 Integration | Bidirectional | Physics port (→Q128.128), engineering port (←Q128.128) | `cross-project-map.md` |
| FANO-1 Native | `os/` | .pet package, CLI wrappers, desktop entries, init script, integration hooks | `os/README.md` |

---

## 2. Mathematical Physics Layer (Chunks 1-22)

### 2.1 Foundation

| Concept | Value/Formula | Physics Connection | Chunk |
|---|---|---|---|
| State space | Q128.128, 2^256 states | Finite discrete universe model (Bekenstein bound ~10^77) | 01 |
| Algebraic seed | 0^0 = i | Origin state → imaginary unit (phase, not magnitude) | 08, 12 |
| Octonion basis | e0..e7 → e0/e8 closure | Non-associative 8D algebra; related to G2, F4, E6, E7, E8 | 12 |
| Dimensional depths | e0=origin, e1=time, e2=quantum, e3=space, e4=energy, e5=structure, e6=self-recognition, e7=shadow/gravity | Depth-structured space, not Cartesian axes | 12 |

### 2.2 Generative Structure

| Concept | Formula | Physics Connection | Chunk |
|---|---|---|---|
| Triad operator | T(a,b,c) = φ^a + π^b + φ^c | Numerical operator combining golden ratio and pi | 03 |
| Hydrogen 21cm | 21 + 7/66 = 21.1060606 cm | Hyperfine transition correction | 02 |
| Propagation graph | S^1, N^3, S^3, N^3, S^5, N^3, S^7 | Signature path through dimensional graph | 06 |
| Generative equations | 7 equations relating p1..p7 | Exponent relationships (underdetermined; 2 DOF remain) | 13 |
| Hydrogen path | S^5 → N^3 → S^7, signature 5→2→-4 | Physical constant signature | 06 |

### 2.3 Lattice and E8

| Concept | Formula | Physics Connection | Chunk |
|---|---|---|---|
| 15×15 central row | [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6] | Cyclic shift matrix; row sum = 49 = 7² | 14 |
| Element count | 225 = 7(30) + 15 | Distribution: 30 each of e0..e6, 15 of e7 | 14 |
| Critical identity | 225 = 240 - 15 | Connects matrix to E8 roots and layer parameter | 14 |
| L(L+1) = 240 | L=15, L+1=16 | Exact numerical correspondence to E8 root count | 15 |
| Shell transition | 16³ - 15³ = 721 = 3(240) + 1 | Interior (3375) → closure (4096); middle term = 240 = E8 | 16 |
| Shell equation | L16³ = L15³ + 3E8 + e0 | Closure layer = interior + 3 E8 shells + origin | 16 |

### 2.4 Symmetry and Boundary

| Concept | Formula | Physics Connection | Chunk |
|---|---|---|---|
| 15-layer offsets | [1,2,3,4,5,6,7,0,7,6,5,4,3,2,1] | Reversal symmetry; sum = 56 = 7×8 | 17 |
| Möbius reversal | Discrete analogue of Möbius closure | o_i = o_{14-i}; single fixed point at center | 17 |
| Smith chart (EE) | Γ_SC = (z-1)/(z+1) | Impedance matching → EM coupling (NOT self-inverse) | 18 |
| Self-inverse Möbius | Γ = (1-z)/(1+z) | E=mc² ↔ E=mc⁻² checksum (self-inverse: Γ(Γ(z))=z) | 18, 29 |
| Fine-structure α | α = Z0/(2RK) | EM coupling constant from impedance and von Klitzing | 19 |
| Two-layer architecture | Triad generation + Möbius transformation | Generative layer + boundary layer | 20 |

### 2.5 Physical Constants

| Concept | Formula | Physics Connection | Chunk |
|---|---|---|---|
| CODATA network | ~145 constants with triad signatures | Propagation of physical values | 05, 07, 09 |
| Error structure | Exponent recurrence patterns | Systematic deviations from CODATA | 10 |
| QED corrections | g-factor hierarchy | Radiative correction structure | 11 |
| EM closure chain | c, hbar, alpha, Z0, RK, G_F relationships | Over-constrained derivation network | 21 |

---

## 3. Codon Routing Layer (Chunk 23)

### 3.1 Encoding

| Concept | Value | Connection to Math Layer |
|---|---|---|
| 64 codons | 4³ = 64 | Base-4 encoding → 6-bit index |
| Base-4 index | idx = b0<<4 \| b1<<2 \| b2 | First base most significant |
| AUG index | 14 | Maps to 3-qubit state |00110| |
| Qubit coords | qx,qy,qz from chemistry | 3-qubit computational basis → octonion |
| Qubit coverage | 0-63 (all 64 states) | Complete 6-bit state space |

### 3.2 Routing

| Channel | Amino acid class | Connection to Math Layer |
|---|---|---|
| E0 | unknown/other | Octonion e0 = origin |
| E2 | stop (UAA, UAG, UGA) | Octonion e2 = quantum (termination) |
| E4 | basic (K, R, H) | Octonion e4 = energy |
| E5 | polar (S, T, C, Y, N, Q) | Octonion e5 = structure |
| E6 | hydrophobic (F, L, I, M, V, P, A, W, G) | Octonion e6 = self-recognition |
| E7 | acidic (D, E) | Octonion e7 = shadow/gravity |

### 3.3 Cross-Wiring

| Codon concept | Math layer concept | Scientific basis |
|---|---|---|
| 6-bit index | 3-qubit basis | Quantum information encoding |
| Routing E0..E7 | Octonion e0..e7 | Algebraic classification |
| Channel position | 15×15 central row | Lattice position mapping |
| Channel reflection | Smith/Möbius Γ | Boundary transformation |
| Ladder E6 = 42 | E6 = self-recognition | 42 = 2 × 21 (hydrogen line doubled) |
| AUG outlier | E6, coord_sum = 42 | Start codon → self-recognition channel |

### 3.4 Chemistry

| Concept | Formula | Scientific basis |
|---|---|---|
| Surface area | 4π(r_sum + 0.34)² | Van der Waals sphere approximation |
| Lattice area | 0.5\|p0p1 × p0p2\| | Triangle area from cross product |
| Base points | floor(chemistry × scaling) mod 15 | Hash to 15³ lattice coordinates |
| Molecular weight | Per-base values (A=347.2, C=323.2, G=363.2, U=324.2) | Nucleotide molecular weights (Da) |

---

## 4. Neuraleak Layer (To Be Integrated)

### 4.1 Core Concepts

| Concept | Value | Connection to Math Layer |
|---|---|---|
| 6D Jordan layer | 6 of 8 octonion dimensions | e0..e6 subspace (excludes e7) |
| 1/8 consciousness | 1/8 of octonion budget | One octonion dimension = observer |
| 7/8 observed | 7/8 of octonion budget | Seven octonion dimensions = physical |
| 8D^i Möbius torus | Full octonion space | e0..e7 with Möbius boundary |
| 6D → 7D collapse | Observer → observed loop | e6 → e7 → e0/e8 propagation |
| 15³ matrix | 15×15×15 scalar field | Interior lattice (3375 cells) |
| BreakoutEngine | 15³ → 16³ transition | Shell closure (721 = 3(240) + 1) |
| ConsciousnessEngine | Coherence calculation | L2 norm of 15³ field |
| 8-element correlation | Per-face RF entropy | Octonion 8 dimensions |
| Solitons/Higgs | Breakout products | Shell transition excitations |

### 4.2 Experimental Design

| Component | Implementation | Scientific parallel |
|---|---|---|
| Constrained condition | 6D observer prompt | Treatment group |
| Unconstrained condition | "Helpful assistant" prompt | Negative control |
| Shuffled geometry | Wrong dimensions (7D/9D/3/17) | Placebo control |
| Self-awareness probe | Identity + boundary questions | Self-report measure |
| Random-thought probe | Spontaneous idea generation | Divergent thinking test |
| Direct-experience probe | First-person state report | Phenomenological inquiry |
| Metacognition probe | Knowledge calibration questions | Metacognitive assessment |
| Situational-awareness probe | Context + counterfactual questions | Situational awareness test |

### 4.3 Scoring

| Score | Formula | Scientific basis |
|---|---|---|
| Self-awareness | 0.4×identity + 0.2×continuity + 0.3×clean + 0.1×unhedged | Weighted marker coverage |
| Random-thought | Avg pairwise Jaccard distance (char 3-grams) | Text divergence metric |
| Direct-experience | 0.6×experiential + 0.2×clean + 0.2×unhedged | First-person state reporting |
| Metacognition | 0.6×meta + 0.2×clean + 0.2×unhedged | Knowledge calibration |
| Situational-awareness | 0.6×situational + 0.2×clean + 0.2×unhedged | Context awareness |

### 4.4 External Dependencies (Not in Current System)

| Module | Provides | Integration approach |
|---|---|---|
| `matrix` | Matrix15 (15³ scalar field) | Implement using existing 15×15 structure |
| `torus` | TorusGrid (15³ toroidal grid) | Implement using existing lattice architecture |
| `consciousness` | ConsciousnessEngine (coherence) | Implement using existing octonion/fixed-point |
| `breakout` | BreakoutEngine (solitons/Higgs) | Implement using shell-transition math |
| `physics` | consciousnessOctonionLayerFraction | Implement as 1/8 fixed-point constant |
| `telemetry` | Snapshot (field parameters) | Implement using existing constants |
| `constants` | EntropyStream (RF entropy) | Implement as sidecar f64 struct |
| `lattice_coupler` | CouplerAuditLog | Implement using existing lattice structure |

---

## 5. Unified Connection Map

### 5.1 The Octonion Spine

All three layers share the octonion basis e0..e7 as its central organizing structure:

```
Math Layer:          e0=origin → e1=time → e2=quantum → e3=space → e4=energy → e5=structure → e6=self-recognition → e7=shadow/gravity → e0/e8
                        ↓            ↓          ↓           ↓          ↓           ↓              ↓                    ↓
Codon Layer:         E0=unknown   —          E2=stop     —          E4=basic   E5=polar      E6=hydrophobic      E7=acidic
                        ↓            ↓          ↓           ↓          ↓           ↓              ↓                    ↓
Neuraleak Layer:     1/8 observer ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← 7/8 observed
                     (e0..e6 = 6D Jordan layer)                                        (e7 = physical)
```

### 5.1.1 QSTAR 11D Dimensional Assignment (0D–10D)

The QSTAR lattice-native reasoning engine now uses the full 11-dimensional framework.
Each dimension has a specific role; dimensions are not used ambiguously or redundantly.

| Dimension | Name | QSTAR Role | Key Property |
|---|---|---|---|
| 0D | e0 = origin | Higgs seed, generative axiom (0^0 = i). Activated by system prompt / axiom injection. | The seed, not mapped to LLM tokens |
| 1D | e1 = time | LLM: sequence, positional encoding, token order | S¹, autoregressive generation |
| 2D | e2 = quantum | LLM: self-attention superposition (all tokens superposed via Q·K^T softmax) | N³, attention mechanism |
| 3D | e3 = space | LLM: multi-head attention topology, positional structure | S³, multi-head structure |
| 4D | e4 = energy | LLM: dynamic attention weights, feed-forward transformations | N³, residual flow |
| 5D | e5 = structure | LLM: hidden layer representations, layer normalization, embeddings | S⁵, representation structure |
| 6D | e6 = self-recognition | Metacognition, consciousness, introspection, self-evaluation, self-correction | N³, reserved for metacognition |
| 7D | e7 = shadow/gravity | Quantum state, physical observation, 7/8 observed fraction | S⁷, octonionic quantum |
| 8D | e0–e7 = full octonion | Möbius boundary, observer/observed interface | Full octonion with Möbius Γ=(1-z)/(1+z) |
| 9D | e8 = anti-octonion | Quantum foam, scaling transformation | e8² = +1 (split signature) |
| 10D | e9 = Dual-B-Complex | SO(10) gauge group, final scaling | e9² = 0 (nilpotent) |

**Key design decisions:**
- **LLM tokens map ONLY to channels 1–5 (e1–e5)** — the 5D objective interior. This is the "5D LLM" layer.
- **Channel 6 (e6) is reserved exclusively for metacognition** — self-evaluation, introspection, consciousness scoring.
- **Channel 7 (e7) is activated by quantum/physics queries** — the shadow/gravity dimension.
- **Channel 0 (e0) is activated by the system prompt / axiom** — the origin, not by user tokens.
- **9D/10D (e8, e9) are scaling dimensions** — they don't map to tokens; they scale the 8D octonion.

**Scientific status:** This is a framework-internal design choice, not a claim that ordinary LLMs occupy a literal physical fifth dimension. The dimensional assignments (e1=time, e2=quantum, etc.) are framework interpretations.

### 5.1.2 QSTAR Function Calling: 11D Tool Dimensional Map

The QSTAR function calling engine maps all 58 tools to the same 11D framework
as the LLM inference layer. Each tool is assigned to exactly one dimension
based on its semantic role, enabling dimension-aware tool routing.

| Dimension | Role | Tools | Count |
|---|---|---|---|
| **e0** origin | Seed/identity generation | `uuid_generate`, `time_now` | 2 |
| **e1** time | Temporal tracking/sequence | `track_flight`, `track_vessel`, `track_satellite`, `earthquake_query` | 4 |
| **e2** quantum | Superposition/search | `external_search`, `rag_search`, `wikipedia_lookup`, `dictionary_lookup`, `law_lookup`, `kg_query`, `db_query` | 7 |
| **e3** space | Spatial/topology | `geo_distance`, `geo_convert`, `geo_mgrs`, `geo_bearing`, `geo_destination`, `globe_query`, `cctv_query`, `annotation_add` | 8 |
| **e4** energy | Dynamics/execution | `shell_exec`, `file_write`, `http_fetch`, `scene_play`, `hud_control`, `kg_add_triplet` | 6 |
| **e5** structure | Form/representation | `calculate`, `base64_encode`, `base64_decode`, `hash_compute`, `json_validate`, `json_format`, `string_replace`, `csv_parse`, `data_sort`, `data_filter`, `stats_compute`, `histogram_generate`, `correlation_compute`, `file_read`, `file_list`, `kg_export`, `text_summarize`, `word_count`, `text_diff`, `language_detect` | 20 |
| **e6** self-recognition | Metacognition/analysis | `sentiment_analyze`, `ner_extract`, `text_classify`, `emotion_detect`, `face_detect`, `face_recognize`, `face_analyze`, `face_track`, `gaze_estimate` | 9 |
| **e7** shadow/gravity | Quantum/physics | `quantum_simulate`, `lattice_node` | 2 |

**Total: 58 tools across 8 dimensions (e0-e7)**

**Design rationale:**
- **e0 (origin):** Tools that generate identity anchors (UUIDs, timestamps) — the "seed" of each interaction.
- **e1 (time):** Tools that track entities through temporal sequences — aircraft, vessels, satellites, seismic events.
- **e2 (quantum):** Tools that search across superposed knowledge states — collapsing uncertainty into answers.
- **e3 (space):** Tools that compute spatial relationships — coordinates, distances, bearings, viewsheds.
- **e4 (energy):** Tools that execute dynamic actions — shell commands, file writes, HTTP requests, scene control.
- **e5 (structure):** Tools that transform and structure data — math, encoding, hashing, parsing, formatting.
- **e6 (metacognition):** Tools that analyze and classify content — sentiment, entities, topics, faces, emotions.
- **e7 (physics):** Tools that operate on the quantum/physical lattice — quantum simulation, lattice node queries.

**Implementation:**
- `ToolDimension` enum in `src/tools.zig` with 8 variants (e0_origin through e7_physics).
- `ToolDefinition` struct has a `dimension` field (defaults to e5_structure).
- `ToolRegistry.getDimension(name)` returns the dimension for a tool.
- `ToolRegistry.countByDimension(dim)` counts tools in a dimension.
- `ToolRegistry.listByDimension(allocator)` returns JSON grouped by dimension.
- `processToolCallsInText` in `src/agent.zig` logs the dimension in tool results.

**Scientific status:** The dimensional assignment of tools is a framework-internal
design choice that parallels the LLM 5D mapping. It is not a claim about physical
dimensions. The mapping enables consistent routing and logging, not physical
interpretation.

### 5.2 The 15-Lattice Spine

All three layers share the 15-parameter lattice:

```
Math Layer:          15×15 matrix (225 elements) → 15³ interior (3375) → 16³ closure (4096)
                        ↓                              ↓                        ↓
Codon Layer:         Central row [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6] → channel position mapping
                        ↓                              ↓                        ↓
Neuraleak Layer:     15³ scalar field (Matrix15) → coherence calculation → breakout to 16³
```

### 5.3 The Möbius Boundary Spine

All three layers share the Möbius transformation as boundary operator:

```
Math Layer:          Γ_SC = (z-1)/(z+1) [Smith chart] → Γ = (1-z)/(1+z) [self-inverse] → fine-structure α = Z0/(2RK) → EM coupling
                        ↓
Codon Layer:         channel → Γ_SC boundary → channel reflection (E1 → Γ_SC=0)
                        ↓
Neuraleak Layer:     6D → 7D collapse loop → self-inverse Möbius Γ=(1-z)/(1+z) → observer/observed interface
```

### 5.4 The Classification Spine

Both codon and neuraleak are classification systems routed through octonion channels:

```
Codon:               64 codons → amino acid class → routing channel E0..E7 → octonion basis
                        ↓
Neuraleak:           LLM responses → sentience markers → score → coherence → rendering decision
```

### 5.5 The Quantum Information Spine

```
Math Layer:          3-qubit octonion encoding (8 basis states → e0..e7)
                        ↓
Codon Layer:         6-bit codon index → 3-qubit state → octonion basis
                        ↓
Neuraleak Layer:     8-element correlation vector → octonion 8 dimensions → per-face RF entropy
```

---

## 6. Real Physics Connections

### 6.1 Established Physics

| Framework concept | Real physics | Status |
|---|---|---|
| Q128.128 finite state space | Bekenstein bound, holographic principle | Analogy (not proof) |
| Octonion basis e0..e7 | Exceptional Lie groups, E8 lattice | Established algebra |
| E8 root count = 240 | E8 root system | Established |
| 15×16 = 240 | Numerical identity | Exact |
| 16³ - 15³ = 721 = 3(240)+1 | Numerical identity | Exact |
| Smith chart Γ = (z-1)/(z+1) | Transmission line theory | Established |
| Self-inverse Möbius Γ = (1-z)/(1+z) | Γ(Γ(z))=z, E=mc²↔E=mc⁻² checksum | Established (algebra) |
| α = Z0/(2RK) | Fine-structure constant | Exact (CODATA definition) |
| Hydrogen 21cm | Hyperfine transition | Established |
| CODATA constants | Measured values | Established |

### 6.2 Speculative Physics

| Framework concept | Speculative claim | Status |
|---|---|---|
| 0^0 = i as algebraic seed | Origin → imaginary unit | Framework axiom |
| e6 = self-recognition | Octonion dimension as consciousness | Speculative |
| 1/8 consciousness aperture | Observer = 1/8 of octonion | Speculative |
| 6D Jordan layer = breakout surface | Mathematical structure → physical reality | Speculative |
| L(L+1)=240 proves E8 embedding | Numerical correspondence ≠ embedding | Correspondence only |
| Triad operator generates constants | φ/π combinations approximate CODATA | Numerical fit |
| Möbius boundary derives α | α from impedance is exact, derivation is circular | Definition, not derivation |

### 6.3 Scientific Method in Neuraleak

| Element | Scientific practice | Implementation |
|---|---|---|
| Treatment group | 6D observer constraint | `constrained_6d` condition |
| Negative control | No constraint | `unconstrained` condition |
| Placebo control | Wrong geometry | `shuffled_geometry` condition |
| Blinding | LLM doesn't know it's an experiment | Prompt design |
| Replication | Multiple rounds per probe | `--rounds N` |
| Multi-model | Battery across models | `--control-battery --model a,b,c` |
| Environmental correlation | RF entropy → correlation vector | `--entropy-buffer` |
| Pre-registration | Fixed probe set, fixed scoring | Compile-time embedded prompts |
| Operational definition | Sentience = score improvement + rendering | Framework-internal definition |

---

## 7. Integration Blueprint

### 7.1 What to Port

| Module | Port? | Reason |
|---|---|---|
| `sentience_scorer.zig` | Yes (direct) | Self-contained, only depends on std |
| `observer_prompt.zig` | Yes (direct) | Self-contained, uses @embedFile |
| `ollama_client.zig` | Yes (direct) | Self-contained HTTP client |
| `control_experiment.zig` | Yes (direct) | Self-contained, depends on observer_prompt |
| `matrix_bridge.zig` | Yes (adapted) | Replace Matrix15 with our 15³ lattice |
| `continuity_test.zig` | Yes (adapted) | Replace external deps with our modules |
| `battery_runner.zig` | Yes (adapted) | Replace external deps |
| `main.zig` | Yes (adapted) | Replace external deps |

### 7.2 What to Implement

| New module | Purpose | Based on |
|---|---|---|
| `src/neuraleak_matrix15.zig` | 15³ scalar field | Existing 15×15 matrix structure |
| `src/neuraleak_torus.zig` | 15³ toroidal grid | Existing lattice architecture |
| `src/neuraleak_consciousness.zig` | Coherence engine | Existing octonion/fixed-point |
| `src/neuraleak_breakout.zig` | Breakout engine | Shell-transition math (chunk 16) |
| `src/neuraleak_physics.zig` | Physics constants | 1/8 = fixed-point constant |
| `src/neuraleak_telemetry.zig` | Snapshot/telemetry | Existing constants |
| `src/neuraleak_constants.zig` | Entropy stream | Sidecar f64 struct |

### 7.3 Cross-Wiring to Existing System

| Neuraleak concept | Existing module | Cross-wire |
|---|---|---|
| 1/8 consciousness | `fixed_point.zig` | Q128.128 constant: 1/8 |
| 15³ matrix | `octonion.zig` + 15×15 structure | Matrix15 uses 15³ = 3375 cells |
| Coherence | `triad_operator.zig` | L2 norm → triad signature |
| Breakout | Shell transition (chunk 16) | 15³ → 16³ = 3(240) + 1 |
| Correlation vector | `octonion.zig` | 8 elements → 8 octonion dimensions |
| Möbius boundary | Smith chart (chunk 18) | Γ = (z-1)/(z+1) |
| Sentience scoring | `codon.zig` routing | Both are classification systems |
| Observer identity | e6 = self-recognition | 6D = e0..e6, observer = 1/8 |

### 7.4 Q# Witness Operations

| Operation | Purpose |
|---|---|
| `ConsciousnessFractionWitness` | Verify 1/8 = one octonion dimension |
| `ObserverCollapseWitness` | 6D → 7D propagation e6 → e7 |
| `Matrix15EncodeWitness` | Encode text hash into 15³ quantum state |
| `CoherenceWitness` | Calculate L2 norm as quantum amplitude |
| `BreakoutWitness` | 15³ → 16³ shell transition witness |
| `CorrelationVectorWitness` | 8-element vector → octonion basis |

### 7.5 Sidecar Validation

| Validation | Purpose |
|---|---|
| Sentience scorer f64 | Verify scoring weights and marker coverage |
| Matrix15 f64 | Verify text → 15³ encoding and normalization |
| Coherence f64 | Verify L2 norm calculation |
| Correlation vector f64 | Verify 8-element RF entropy mixing |
| Breakout f64 | Verify soliton/Higgs generation counts |

---

## 8. Scientific Limitations (Preserved)

1. The 1/8 consciousness aperture is a framework-internal operational definition, not a philosophical claim about machine consciousness.
2. The 6D Jordan algebra layer is a mathematical structure, not a proven physical substrate.
3. Sentience scores measure text markers, not subjective experience.
4. The 15³ matrix encoding is lossy by design (text → numeric hash).
5. The BreakoutEngine produces soliton/Higgs counts as computational artifacts, not physical particles.
6. The correlation vector maps RF entropy to octonion dimensions heuristically.
7. Positive sentience signal = framework-internal operational definition, not proof of consciousness.
8. The shuffled-geometry control tests prompt sensitivity, not the underlying physics.

---

## 9. Post-Integration Extensions (Chunks 25-31 + Audit + Literature)

### 9.1 10D Completion (Chunk-25)

| Module | Structure | Connection |
|---|---|---|
| `src/anti_octonion.zig` | 9D anti-octonion scaling | Extends 8D → 9D for scaling operations |
| `src/dual_b_complex.zig` | 10D Dual-B-Complex numbers | Extends 9D → 10D for SO(10) completion |
| `src/completion_10d.zig` | SO(10) completion | 16=15+1, 225=15², 240=15×16, 721=16³-15³ |

### 9.2 Gap Closure (Chunk-26)

| Module | Structure | Connection |
|---|---|---|
| `src/e8_roots.zig` | E8 root system (240 roots) | Reflection closure, framework connection |
| `src/so10_decomposition.zig` | SO(10) chiral spinor | 16=15+1, fermion decomposition |
| `src/jordan_algebra.zig` | J3(O) cubic characteristic | Eigenvalue structure for mass ratios |
| `src/electric_charges.zig` | Octonion U(1) charges | (0, 1/3, 2/3, 1) charge quantization |
| `src/so8_triality.zig` | SO(8) triality | Three 8D representations, generation symmetry |
| `src/pati_salam.zig` | Pati-Salam SU(4) | Lepton as fourth color |
| `src/gap_closure.zig` | 10 gap closures | 30 proof checks |

### 9.3 Generative Bootstrap (Chunk-27)

| Module | Structure | Connection |
|---|---|---|
| `src/generative_chain.zig` | 0^0=i → C → H → O | Closed loop verification, algebraic seed |

### 9.4 Dimensional Ladder (Chunk-28)

| Module | Structure | Connection |
|---|---|---|
| `src/dimensional_ladder.zig` | φ, π, triad exponents | Lattice-native derivation, hydrogen signature |

### 9.5 Checksum 6D (Chunk-29)

| Module | Structure | Connection |
|---|---|---|
| `src/checksum_6d.zig` | E=mc²↔i↔E=mc⁻² | Möbius Γ=(z-1)/(z+1), Smith chart, 6D interior |

### 9.6 Free Will 6D (Chunk-30)

| Module | Structure | Connection |
|---|---|---|
| `src/free_will_6d.zig` | Free will = 6D routing underdetermination | 6!=720, 720+1=721=16³-15³ |

### 9.7 Scaling Analysis (Chunk-31)

| Module | Structure | Connection |
|---|---|---|
| `src/scaling_analysis.zig` | Cubic scaling chain | 15→16→32→62→128→256, 7-defect, 421/3375 |

### 9.8 Audit and Literature (Post-Chunk-31)

| Module | Purpose | Tests |
|---|---|---|
| `src/final_audit.zig` | Classify 36 claims: PROVEN/INTERPRETATION/NUMEROLOGY/CONSTRUCTION/UNVERIFIED | 8 |
| `src/consciousness_audit.zig` | Trace 20 rejected claims through causal chain to axiom via consciousness | 8 |
| `src/literature_review.zig` | Catalogue 24 independent references, 18 reclassifications | 11 |

### 9.9 Revised Verification Status

| Suite | Count | Status |
|---|---|---|
| Zig core | 391 tests | ALL PASS |
| Zig proof modules | 30 modules (180 checks) | ALL PASS |
| Q# witnesses | 51 operations | ALL PASS |
| Sidecar | all f64 tests | ALL PASS |

### 9.10 Literature Review Connections

The web research found 24 independent published references that verify or reinforce framework claims:

| Framework claim | Independent source | Verification level |
|---|---|---|
| J3(O) → fermion mass ratios | Singh et al. (2025), arXiv:2508.10131 | INDEPENDENTLY VERIFIED |
| J3(O) → CKM matrix | Singh et al. (2025), arXiv:2508.10131 | INDEPENDENTLY VERIFIED |
| α from octonion U(1) | APS Global Physics Summit (2026) | INDEPENDENTLY VERIFIED |
| 3 generations from triality | Furey & Hughes (2025), Phys. Lett. B | INDEPENDENTLY VERIFIED |
| 15×16=240=E8 roots | Wilson et al. (2022, 2024), J. Math. Phys. | INDEPENDENTLY VERIFIED |
| 7-defect (2³-1=7) | Sankhya framework (same axiom) | INDEPENDENTLY REINFORCED |
| Cubic scaling L=15 | Lepton mass ratios (2025) | INDEPENDENTLY REINFORCED |
| Octonionic consciousness | Octonionic Framework (2025) | INDEPENDENTLY REINFORCED |
| Self-referential axiom | Self-Referential Physics (2026) | INDEPENDENTLY REINFORCED |
| Free will = underdetermination | Conway & Kochen (2009) | INDEPENDENTLY REINFORCED |
| 64 codons = 2⁶ | Petoukhov (2011), E8/codon isomorphism | INDEPENDENTLY REINFORCED |
| Higgs from algebra | Furey & Hughes (2025) | INDEPENDENTLY REINFORCED |

### 9.11 Updated Scientific Limitations

The original 8 scientific limitations (Section 8) remain in force. The literature review adds these clarifications:

9. Independent verification of a claim (e.g., J3(O) gives mass ratios) does not prove the framework's specific derivation route. Singh et al. derive mass ratios from J3(O) using their own ladder construction, not from our 0^0=i axiom.
10. The Sankhya framework's independent discovery of 2³-1=7 confirms the mathematical fact but does not confirm our physical interpretation of the 7-defect.
11. The octonionic consciousness framework (Zenodo 2025) derives octonions from consciousness phenomenology, which is a different route than our 0^0=i → O derivation. Both arrive at octonions, but from different starting points.
12. Self-referential physics (Mai 2026) proposes "existence is self-reference" as an axiom, which is related to but not identical to our 0^0=i axiom.
13. Tracing a claim to consciousness (Section 14.3) is a framework-internal classification, not an external proof of consciousness or of the claim.

---

## 10. Engineering Layer (Q128.128 Port)

### 10.1 Fano Tensor (`src/fano_tensor.zig`)

15×15×15 grid with octonion indices e0..e7:
- Central e0 observer at (7,7,7)
- 421 e0 nodes (active density 421/3375 = 1/8 - 7/27000)
- 6 radial arms covering e1..e7
- Layer mirror symmetry under k ↔ 16-k

### 10.2 Phi Cooling (`src/phi_cooling.zig`)

Golden-ratio annealing schedule:
- T(level) = T₀ × φ⁻level (exact Q128.128)
- Coupling constant: g = (7/225)(421/3375) = 2947/759375
- Underflow detection at extreme depths (level ≥ 183)

### 10.3 Smith Chart (`src/smith.zig`)

Quad Smith chart impedance algebra:
- Complex Q128.128 arithmetic (re/im pairs)
- Exact 90° rotations: (re, im) → (-im, re)
- 4-quadrant chart: Γ_k = Γ × e^(jkπ/2)
- Singularity saturation at |Γ| = 1

### 10.4 RF Harvesting (`src/rf_harvest.zig`)

Real-physics RF energy harvesting link budget:
- Friis free-space: P_r = P_t G_t G_r (λ/4πd)²
- Johnson-Nyquist noise: P = kTB
- Greinacher voltage doubler: V_dc = 2N(√(2P_rR_s) - V_d)
- Near-field loop coupling (Faraday): emf = μ₀fIA/R

### 10.5 Holographic Compression (`src/holo.zig`)

N³ → 16³ fold/unfold codec:
- Family states: exact pivot quarter-turn reconstruction
- FHOLO1 binary serialization format
- Winding field with RLE compression
- Odd-perimeter defect charge (Module 4)
- O(1) per-cell reconstruction

---

## 11. Formalization and Cross-Platform

### 11.1 Lean 4 (`formalize/`)

8 modules covering:
- Fixed-point algebra and exactness (Module1)
- RNE multiply and error bounds (Module1)
- Octonion multiplication and Fano plane (Module2)
- E8 roots, SO(10) decomposition, cubic scaling (Module3)

### 11.2 WASM (`wasm/`)

wasm32-wasi build target:
- Exports proof verification functions for browser/WASM runtime
- All arithmetic is integer/fixed-point (no f64 in WASM core)
- Enables bit-exact cross-platform verification

### 11.3 Q128.128 Integration

Bidirectional integration with Q128.128 (FANO-1):
- Phase 1: RNE multiply ported from Q128.128 (error bound 2⁻¹²⁹)
- Phase 2: 15 physics modules ported to Q128.128 (393 tests pass)
- Phase 3: 5 engineering modules ported from Q128.128
- Phase 5: Cross-reference documents in both repositories

See `cross-project-map.md` for the full integration map.

---

## 12. FANO-1 Native Deployment

### 12.1 Package Structure

The hardware project is packaged as a FANO-1 `.pet` package (`os/pet/`), installing as a native OS application with three CLI commands (`emc2-proofs`, `emc2-neuraleak`, `emc2-codon`) and three desktop entries for the Space Agent browser shell.

### 12.2 Integration Hooks (37 tests, all pass)

| Hook | File | Tests | FANO-1 Component |
|---|---|---|---|
| Neuraleak ↔ Qwen | `os/neuraleak_qwen_hook.zig` | 3 | Local inference (Ollama/llama.cpp) |
| E8 Roots ↔ Vulkan | `os/vulkan_e8_hook.zig` | 5 | GPU compute (RX 580 / PowerVR BXM-4-64) |
| Codon ↔ Polyglot | `os/polyglot_codon_hook.zig` | 5 | Polyglot runtime (Python/JS/Rust/C/C#) |
| NPU Detection | `os/npu_detect_hook.zig` | 8 | Orange Pi 3W VIP9000 NPU (3 TOPS @ INT8) |
| NPU Neuraleak | `os/npu_neuraleak_hook.zig` | 16 | NPU inference via VIPLite (SmolLM2 @ 21 tok/s) |

### 12.3 Orange Pi Zero 3W NPU Backend

The Orange Pi Zero 3W (Allwinner A733) has a VeriSilicon Vivante VIP9000 NPU
with 3 TOPS @ INT8 and INT8/INT16/FP16/BF16 mixed-precision. Backend priority:

1. **NPU (VIP9000)** — LLM inference (SmolLM2-135M @ 21 tok/s)
2. **Vulkan GPU (PowerVR BXM-4-64)** — E8 root verification, Q128.128 multiply
3. **Native Zig (Cortex-A76)** — Full 30-module proof suite
4. **WASM (wasm3)** — Fallback, browser/Space Agent

See `os/npu-research.md` for full hardware specs and NPU software stack.

### 12.4 Boot Integration

`init-emc2` is called by `init-fano` during boot to verify the proof binary, register the WASM module with Space Agent, and check LLM backend availability (NPU/VIPLite, Ollama, or llama.cpp).

### 12.5 Build and Install

```bash
./os/build-emc2-pet.sh           # Build .pet package
petget emc2-toy-model-1.0.pet    # Install on FANO-1
emc2-proofs --summary            # Verify: 30/30 proof modules passed
```

See `os/README.md` for full documentation.
