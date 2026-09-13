# Qstar-LLM API Reference

## Metacognition Engine (`metacognition_engine.zig`)

### Constants

| Constant | Type | Value | Description |
|----------|------|-------|-------------|
| `MAX_HISTORY` | `usize` | 100 | Max evaluation history entries |
| `MAX_ADJUSTMENTS` | `usize` | 50 | Max parameter adjustment records |
| `SMALL_TALK_CYCLES` | `u8` | 1 | Reflection cycles for small-talk |
| `STANDARD_CYCLES` | `u8` | 3 | Reflection cycles for standard prompts |
| `DEEP_CYCLES` | `u8` | 4 | Reflection cycles for complex prompts |
| `CORRECTION_PHRASES` | `[6][]const u8` | — | Self-correction phrases |
| `HESITATION_PHRASES` | `[3][]const u8` | — | Conversational fillers |

### Types

#### `Mood`
```zig
pub const Mood = enum { focused, curious, relaxed, uncertain };
```

#### `EvaluationResult`
```zig
pub const EvaluationResult = struct {
    scores: [8]f64,  // relevance, coherence, specificity, naturalness,
                     // self_awareness, direct_experience, metacognition,
                     // situational_awareness
    overall: f64,
    passed: bool,
};
```

#### `SelfModel`
```zig
pub const SelfModel = struct {
    activation_entropy: f64,
    peak_node: usize,
    peak_channel: u3,
    channel_imbalance: f64,
    temperature: i128,
    output_token_count: usize,
    vocabulary_richness: f64,
    consciousness_bandwidth_ratio: f64,
    mood: Mood,
    description: [256]u8,
    description_len: usize,
};
```

#### `ParameterAdjustment`
```zig
pub const ParameterAdjustment = struct {
    cycle: u8,
    dimension: []const u8,
    old_value: f64,
    new_value: f64,
    reason: []const u8,
};
```

#### `CorrectionEvent`
```zig
pub const CorrectionEvent = struct {
    cycle: u8,
    phrase: []const u8,
    corrected_text: []const u8,
    reason: []const u8,
};
```

### `MetacognitionEngine`

#### Fields
| Field | Type | Description |
|-------|------|-------------|
| `self_model` | `SelfModel` | Current introspected state |
| `evaluation_history` | `ArrayList(EvaluationResult)` | Past evaluations |
| `adjustment_history` | `ArrayList(ParameterAdjustment)` | Parameter changes |
| `correction_history` | `ArrayList(CorrectionEvent)` | Mid-response corrections |
| `confidence_threshold` | `f64` | Base quality threshold (0.5) |
| `reflection_depth` | `u8` | Current cycle count (1-4) |
| `mood` | `Mood` | Current emotional model |
| `stop_flag` | `atomic.Value(bool)` | Thread stop signal |
| `correction_pending` | `atomic.Value(bool)` | Mid-gen correction flag |
| `generation_active` | `atomic.Value(bool)` | Generation in progress |
| `bg_thread` | `?std.Thread` | Background introspection thread |
| `state_mutex` | `Thread.Mutex` | Protects shared state |
| `shared_channel_imbalance` | `f64` | Thread-shared imbalance |
| `shared_activation_entropy` | `f64` | Thread-shared entropy |
| `shared_relevance_score` | `f64` | Thread-shared relevance |
| `shared_token_count` | `usize` | Thread-shared token count |

#### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `(allocator) MetacognitionEngine` | Create engine with defaults |
| `deinit` | `(self) void` | Stop thread, free resources |
| `startThread` | `(self) !void` | Start background introspection |
| `stopThread` | `(self) void` | Stop and join background thread |
| `updateSharedState` | `(self, imbalance, entropy, relevance, tokens) void` | Update thread-visible state |
| `setGenerationActive` | `(self, active: bool) void` | Mark generation start/stop |
| `checkCorrectionPending` | `(self) ?[]const u8` | Check & clear correction flag |
| `recordEvaluation` | `(self, result) !void` | Add evaluation to history |
| `averageScore` | `(self) f64` | Mean overall score |
| `passRate` | `(self) f64` | Fraction of passing evaluations |
| `dynamicThreshold` | `(self) f64` | Calibrated threshold (0.3-0.8) |
| `classifyPrompt` | `(self, prompt) void` | Set depth/mood from prompt |
| `updateSelfModel` | `(self, ...) void` | Update from introspection |
| `shouldCorrect` | `(self, prev, curr) ?[]const u8` | Check if correction warranted |
| `recordCorrection` | `(self, cycle, phrase, text, reason) !void` | Log correction event |
| `storePartialResponse` | `(self, response) !void` | Save partial for correction |
| `buildCorrectedResponse` | `(self, allocator, phrase, new) ![]u8` | Stitch correction |
| `suggestAdjustment` | `(self, eval, temp, top_k, cycle) ?ParameterAdjustment` | Suggest parameter change |
| `hesitationPhrase` | `(self) ?[]const u8` | Get mood-based filler |
| `isCasualMode` | `(self) bool` | Check if casual response style |
| `statusString` | `(self, buf) []const u8` | Debug status summary |

---

## Trivium (`trivium.zig`)

### Types

#### `ParsedInput`
```zig
pub const ParsedInput = struct {
    concepts: [][]const u8,
    domain: Domain,
    complexity: Complexity,
    modality: Modality,  // .text or .audio
    tone: Tone,
};
```

#### `Domain` (enum)
`science, mathematics, philosophy, technology, history, literature, art, music, language, medicine, law, business, general, unknown`

#### `Complexity` (enum)
`trivial, simple, moderate, complex, deep`

#### `Modality` (enum)
`text, audio`

#### `Tone` (enum)
`formal, casual, technical, conversational, creative`

#### `ValidatedState`
```zig
pub const ValidatedState = struct {
    confidence: f64,
    coherence_score: f64,
    channel_balance: f64,
    non_contradiction: bool,
    reasoning_steps: usize,
};
```

#### `RhetoricOutput`
```zig
pub const RhetoricOutput = struct {
    format: OutputFormat,
    clarity_score: f64,
    persuasiveness_score: f64,
};
```

#### `OutputFormat` (enum)
`plain_text, markdown, structured, code_block`

### Pipeline

#### `TriviumPipeline`
```zig
pub const TriviumPipeline = struct {
    grammar: GrammarStage = .{},
    logic: LogicStage = .{},
    rhetoric: RhetoricStage = .{},

    pub fn runGrammar(self, prompt) ParsedInput;
    pub fn runLogic(self, activations) ValidatedState;
    pub fn runRhetoric(self, response) RhetoricOutput;
};
```

---

## Quadrivium (`quadrivium.zig`)

### Types

#### `ArithmeticLayer`
```zig
pub const ArithmeticLayer = struct {
    precision_error: f64 = 0.0,
    quantization_levels: u8 = 8,

    pub fn quantize(self, value: i128) i128;
    pub fn dequantize(self, value: i128) i128;
    pub fn projectDiscrete(self, value: i128, bins: usize) usize;
};
```

#### `GeometryLayer`
```zig
pub const GeometryLayer = struct {
    pub fn manifoldDistance(a, b) i128;
    pub fn cosineSimilarity(a, b) f64;
    pub fn volumetricHash(activations) u64;
    pub fn spatialLookup(activations, position) ?i128;
    pub fn compressVolume(activations) [E0_NODE_COUNT]i128;
};
```

#### `MusicLayer`
```zig
pub const MusicLayer = struct {
    sample_rate: i128,  // Q64.64

    pub fn harmonicSeries(self, fundamental: i128, n: usize) [7]i128;
    pub fn formantToLattice(self, f1: i128, f2: i128, f3: i128) [7]i128;
    pub fn resonanceAttenuate(self, activations, freq: i128) void;
    pub fn beatFrequency(self, f1: i128, f2: i128) i128;
    pub fn prosodyEnvelope(self, activations) [7]f64;
    pub fn pitchContour(self, activations) []f64;
};
```

#### `AstronomyLayer`
```zig
pub const AstronomyLayer = struct {
    trajectory: [7][7]f64 = ...,

    pub fn evolveState(self, activations) void;
    pub fn predictNext(self, activations) [E0_NODE_COUNT][7]i128;
    pub fn orbitalEnergy(self, activations) f64;
    pub fn stabilityMetric(self, activations) f64;
};
```

### Pipeline

#### `QuadriviumPipeline`
```zig
pub const QuadriviumPipeline = struct {
    arithmetic: ArithmeticLayer = .{},
    geometry: GeometryLayer = .{},
    music: MusicLayer,
    astronomy: AstronomyLayer = .{},

    pub fn init(sample_rate: i128) QuadriviumPipeline;
    pub fn processState(self, activations) void;
    pub fn stabilityScore(self, activations) f64;
};
```

---

## Voice Codec (`voice_codec.zig`)

### Constants

| Constant | Type | Value | Description |
|----------|------|-------|-------------|
| `FRAME_SIZE` | `usize` | 256 | Audio frame samples |
| `CODEBOOK_BITS` | `u8` | 12 | Codebook index bit depth |
| `CODEBOOK_SIZE` | `usize` | 4096 | Codebook entries |
| `E0_NODE_COUNT` | `usize` | 421 | Lattice nodes |
| `CHANNEL_COUNT` | `usize` | 7 | Channels per node |

### Types

#### `AudioCodebook`
```zig
pub const AudioCodebook = struct {
    entries: [CODEBOOK_SIZE][FRAME_SIZE]f64,
    entry_count: usize,

    pub fn init() AudioCodebook;
    pub fn encodeAudioFrame(self, samples: []const i16) [FRAME_SIZE / 16]u12;
    pub fn decodeAudioFrame(self, codes: []const u12) [FRAME_SIZE]i16;
    pub fn trainCodebook(self, samples: []const []const i16) void;
    pub fn computeSNR(self, original, reconstructed) f64;
};
```

#### `VoiceCloneState`
```zig
pub const VoiceCloneState = struct {
    f1: i128,  // Q64.64 formant frequency
    f2: i128,
    f3: i128,
    pitch_range_low: i128,
    pitch_range_high: i128,
    spectral_envelope: [7]i128,
    convergence_threshold: i128,

    pub fn init(f1: i128, f2: i128, f3: i128) VoiceCloneState;
};
```

#### `SpeakerHypervector`
```zig
pub const SpeakerHypervector = struct {
    data: [421][7]i128,

    pub fn initRandom(rng) SpeakerHypervector;
    pub fn bindSpeaker(base, id) SpeakerHypervector;    // XOR bind
    pub fn unbindSpeaker(bound, id) SpeakerHypervector;  // XOR unbind
    pub fn bundleSpeakers(speakers) SpeakerHypervector;  // Majority vote
    pub fn similarity(a, b) f64;                         // [-1, 1]
};
```

#### `VoiceCodecPipeline`
```zig
pub const VoiceCodecPipeline = struct {
    codebook: AudioCodebook,
    speaker_id: ?SpeakerHypervector,

    pub fn init() VoiceCodecPipeline;
    pub fn deinit(self) void;
    pub fn encode(self, samples) []u12;
    pub fn decode(self, codes) []i16;
    pub fn cloneVoice(self, reference, target_state) VoiceCloneResult;
};
```

#### `VoiceCloneResult`
```zig
pub const VoiceCloneResult = struct {
    iterations: usize,
    converged: bool,
    final_formant_pattern: [7]i128,
};
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `formantToLattice` | `(f1, f2, f3: i128) [7]i128` | Map formants to Q64.64 channel activations |
| `propagateVoicePattern` | `(activations, target, max_iter) VoiceCloneResult` | NCA wave propagation on lattice |
| `extractFormantPattern` | `(activations) [7]i128` | Extract formant pattern from lattice state |
| `spectralSimilarity` | `(a, b: [7]i128) f64` | Cosine similarity on channel activations |

---

## Agent Integration (`agent.zig`)

### Agent Fields (Cognitive Architecture)

| Field | Type | Description |
|-------|------|-------------|
| `metacognition` | `MetacognitionEngine` | Always-on introspection (thread started in init) |
| `trivium_pipeline` | `TriviumPipeline` | Grammar/Logic/Rhetoric stages |
| `quadrivium_pipeline` | `QuadriviumPipeline` | Arithmetic/Geometry/Music/Astronomy |
| `voice_codec_pipeline` | `?VoiceCodecPipeline` | Optional voice codec |

### `generateWithReflection` Flow

1. `metacognition.classifyPrompt(prompt)` — set depth and mood
2. For each reflection cycle (1-4):
   a. `metacognition.setGenerationActive(true)`
   b. `generateLongForm(prompt)` — lattice inference
   c. `metacognition.setGenerationActive(false)`
   d. `metacognition.checkCorrectionPending()` — inject correction if needed
   e. `trivium_pipeline.runLogic(activations)` — validate lattice
   f. `quadrivium_pipeline.processState(activations)` — manifold processing
   g. `introspect()` — update self-model and shared state
   h. `evaluateResponse(prompt, response)` — 8-dimensional scoring
   i. `quadrivium_pipeline.stabilityScore()` — modulate confidence
   j. `metacognition.shouldCorrect()` — check for correction between cycles
   k. `metacognition.suggestAdjustment()` — tune parameters
   l. `trivium_pipeline.runRhetoric(response)` — plan output format
3. Return best-scoring response

### CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--no-reflect` | off | Disable metacognitive reflection (opt-out) |
| `--vocab <size>` | 128k | Vocabulary size |
| `--level <0-7>` | 3 | Lattice level |
| `--autoscale` | off | Auto-detect optimal precision |
| `--draft-mode` | off | Speculative draft mode |

### Server API

The HTTP server (`server.zig`) defaults `use_reflection = true`. Clients can toggle via JSON payload field `"reflect": false`.
