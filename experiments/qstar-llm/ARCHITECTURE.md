# Qstar-LLM Cognitive Architecture

## Overview

Qstar is a lattice-native inference engine that replaces transformer-based LLMs with a discrete E0 lattice of 421 nodes × 7 channels (~47 KB state). All core arithmetic uses i128 Q64.64 fixed-point (i256 intermediates) — no floating-point in state paths. The cognitive architecture is organized as a three-layer system inspired by the classical liberal arts: Metacognition Engine, Trivium, and Quadrivium.

## Lattice Foundation

### E0 Lattice
- **421 nodes** arranged in a 15³ grid topology
- **7 channels** per node representing octonionic reasoning dimensions
- **2947 total dimensions** (421 × 7) for hyperdimensional computing
- State: `[421][7]i128` — Q64.64 fixed-point activations
- Operations: E0 firing, octonion routing, Fibonacci projection, φ-cooling

### Fixed-Point Arithmetic
- Core type: `i128` in Q64.64 format (64 integer bits, 64 fractional bits)
- Intermediates: `i256` to prevent overflow during multiplication
- Downscaling: Q32.32 for Maple/ESP32/WASM peripherals
- Floating-point: f64 sidecars only for training, evaluation, and audio I/O

## Cognitive Architecture

### Layer 1: Metacognition Engine (`metacognition_engine.zig`)

The always-on introspection layer that monitors generation quality and self-corrects.

**Background Thread:**
- Spawned in `Agent.init()`, joined in `Agent.deinit()`
- Continuous loop: introspect → evaluate → adjust → sleep 50ms
- Uses `std.atomic.Value(bool)` for `stop_flag`, `correction_pending`, `generation_active`
- Mutex-protected shared state: channel imbalance, activation entropy, relevance score, token count

**Mid-Generation Correction Protocol:**
- During `generateWithReflection`, after each generation pass, checks `correction_pending`
- If triggered: injects natural correction phrase ("Let me reconsider — ") and continues
- Correction triggers:
  - Relevance score drops below 0.3 mid-stream
  - Activation entropy spikes abnormally (> 8.0 = lattice destabilization)
  - Channel imbalance exceeds 0.8 (one channel dominating = hallucination risk)
  - Output diverges from prompt semantic field after 16+ tokens
- Corrections are **additive** — they pivot, preserving what was good

**Dynamic Parameter Adjustment:**
- Low relevance → increase temperature +0.3 for diverse retrieval
- Low coherence → decrease temperature -0.3 for focused output
- Low specificity → increase top_k +2 for broader vocabulary
- Low naturalness → vary temperature for conversational tone
- High entropy + good relevance → maintain (sweet spot)

**Prompt Classification:**
- Small-talk detection: greetings, "how are you", "what's up" → 1 reflection cycle, relaxed mood
- Complex prompts: technical markers (explain, analyze, prove, quantum, etc.) → 4 reflection cycles, focused mood
- Standard prompts → 3 reflection cycles, curious mood

**Mood Tracking:**
- `focused`: high entropy, balanced channels
- `curious`: moderate entropy
- `relaxed`: low entropy or small-talk
- `uncertain`: high channel imbalance

**Self-Model:**
- Activation entropy (Shannon)
- Peak node and channel identification
- Channel imbalance ratio
- Vocabulary richness (unique/total token ratio)
- Consciousness bandwidth ratio (Jordan/Fold channel ratio)
- Output token count

### Layer 2: Trivium (`trivium.zig`)

The language and reasoning pipeline with three stages:

**Grammar Stage (Input Processing):**
- Concept extraction: identifies key concepts in prompt
- Domain detection: 14 domains (science, math, philosophy, technology, etc.)
- Complexity classification: trivial → simple → moderate → complex → deep
- Modality routing: text vs audio
- Tone detection: formal, casual, technical, conversational, creative
- Output: `ParsedInput` struct

**Logic Stage (Reasoning Validation):**
- Coherence scoring: adjacent activation consistency
- Channel balance: verifies no single channel dominates
- Non-contradiction checking: output vs input semantic alignment
- Reasoning step counting: tracks inference depth
- Output: `ValidatedState` struct with confidence score

**Rhetoric Stage (Output Planning):**
- Format detection: plain_text, markdown, structured, code_block
- Clarity scoring: sentence complexity and readability
- Persuasiveness scoring: argument strength assessment
- Output: `RhetoricOutput` with quality metadata

**Pipeline Integration:**
```
Grammar.parse(prompt) → generateLongForm → Logic.reason() →
  introspect → evaluate → Rhetoric.plan() → non-contradiction check →
  correction loop (if needed)
```

### Layer 3: Quadrivium (`quadrivium.zig`)

The mathematical manifold processing layer with four sub-layers:

**Arithmetic Layer:**
- Precision tracking: monitors accumulated Q64.64 rounding error
- Quantization-aware operations: INT4/INT8 simulation paths
- Discrete latent space mapping: projects continuous values to discrete bins
- Quantization/dequantization with error bounds

**Geometry Layer:**
- Manifold distance: non-Euclidean embedding metrics
- Cosine similarity: activation vector comparison
- Volumetric hashing: O(1) spatial lookups via hash-based position queries
- Spatial lookup: position-indexed activation retrieval
- Activation volume compression: geometric codec for state compression

**Music Layer:**
- Harmonic series: positional encoding via RoPE-like scheme
- Formant↔lattice mapping: F1 (200-1000 Hz), F2 (800-2500 Hz), F3 (1500-3500 Hz) in Q64.64
- Resonance/attenuation: frequency-domain attention modulation
- Beat frequency analysis: rhythmic pattern detection in activation sequences
- Prosody envelope: pitch contour, energy envelope, timing extraction
- Pitch contour: melodic trajectory from lattice state

**Astronomy Layer:**
- State trajectory evolution: models activation flow as orbital mechanics
- Future prediction: forecasts next lattice state
- Orbital energy: kinetic + potential energy of activation state
- Stability metric: [0, 1] — modulates evaluation confidence in `generateWithReflection`

**Pipeline Integration:**
- Called after Logic stage, before evaluation
- Stability score < 0.3 → evaluation confidence reduced by 20%

### Voice Codec (`voice_codec.zig`)

Lattice-native audio processing integrated with Trivium Grammar (audio input) and Quadrivium Music (formant/prosody output).

**VQ Codebook Layer:**
- Lloyd-Max vector quantization for audio frame encode/decode
- 4096 entries (12-bit codes), frame size = 256 samples
- `encodeAudioFrame(raw_samples: []const i16) -> []u12`
- `decodeAudioFrame(codes: []const u12) -> []i16`
- `trainCodebook(samples: []const []const i16) -> AudioCodebook`
- Codebook IDs map directly to E0 node indices (channel multiplexing)
- f64 sidecar for training only

**NCA Wave Propagation:**
- `VoiceCloneState`: target speaker's formant frequencies, pitch range, spectral envelope
- `propagateVoicePattern`: injects target voice at boundary nodes, lattice self-organizes via iterative relaxation
- Convergence: when max change per iteration < threshold
- `formantToLattice(f1, f2, f3) -> [7]i128`: maps formants to Q64.64 channel activations

**HDC Speaker Binding:**
- `SpeakerHypervector`: [421][7]i128 — 2947-dimensional bipolar vector
- `bindSpeaker`: element-wise XOR binding of acoustic features with speaker identity
- `unbindSpeaker`: XOR unbinding (self-inverse)
- `bundleSpeakers`: majority vote bundling for multi-speaker models
- `similarity`: sign-agreement cosine-like score in [-1, 1]

**Pipeline Paths:**
- **Encode**: raw audio → VQ encode → discrete codes → formantToLattice → lattice injection → NCA propagation → HDC binding
- **Decode**: lattice state → HDC unbinding → NCA resonance readout → VQ decode → raw audio
- **Clone**: reference audio → extract VoiceCloneState → propagateVoicePattern → new audio with target voice

## Inference Pipeline

```
Input: text → BPE tokenize → E0 node activation
  ↓
Trivium Stage 1: Grammar — parse, classify, route
  ↓
[Metacognition: setGenerationActive(true)]
  ↓
Inference: E0 firing + octonion routing + Fibonacci projection + φ-cooling
  ↓
[Metacognition: setGenerationActive(false)]
  ↓
Trivium Stage 2: Logic — validate lattice coherence, non-contradiction
  ↓
Quadrivium: Arithmetic/Geometry/Music/Astronomy manifold processing
  ↓
Metacognition: introspect → evaluate → mid-generation correction check
  ↓
Trivium Stage 3: Rhetoric — format, clarity, persuasiveness
  ↓
Output: E0 activation decode → token IDs → text
```

## Key Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `E0_NODE_COUNT` | 421 | Lattice nodes in 15³ grid |
| `CHANNEL_COUNT` | 7 | Octonionic reasoning channels |
| `FRAME_SIZE` | 256 | Audio frame samples |
| `CODEBOOK_BITS` | 12 | VQ codebook bit depth |
| `CODEBOOK_SIZE` | 4096 | VQ codebook entries |
| `MAX_HISTORY` | 100 | Metacognition evaluation history |
| `MAX_ADJUSTMENTS` | 50 | Parameter adjustment history |

## Module Dependencies

```
agent.zig
  ├── metacognition_engine.zig (standalone)
  ├── trivium.zig (standalone)
  ├── quadrivium.zig → fixed_point.zig
  └── voice_codec.zig → fixed_point.zig
```

All modules use only `std` — zero external dependencies.
