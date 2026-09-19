//! dim_6d_consciousness.zig — 6D Consciousness Engine (Consciousness/Peak dimension).
//!
//! The 6D dimension uses the exceptional Jordan algebra J₃(O) (27 real dimensions)
//! for metacognition, self-evaluation, and consciousness-related processing.
//!
//! Key principle: This module is PURE 6D — metacognition, sentience, self-evaluation,
//! self-awareness. NO language generation, NO token routing, NO corpus retrieval.
//! Those belong to 5D (dim_5d_language.zig).
//!
//! The 6D consciousness engine operates ON the 5D language engine's output:
//!   1. 5D: language.generate() produces raw text
//!   2. 6D: consciousness.evaluate() scores it using Jordan algebra
//!   3. 6D: consciousness.selfCorrect() adjusts if below threshold
//!   4. 5D: language.regenerate() with adjusted parameters
//!   5. Repeat up to 3 cycles
//!
//! The Jordan product X ∘ Y = (XY + YX)/2 is the self-evaluation operator:
//!   - X = current evaluation state, Y = accumulated self-model
//!   - X ∘ Y = the self-referential evaluation (commutative, non-associative)
//!
//! The Jordan trace tr(X) = α + β + γ is the consciousness measure (scalar summary).
//! The Jordan determinant det(X) is the self-consistency measure.
//! The characteristic polynomial λ³ - tr(X)λ² + s(X)λ - det(X) = 0
//!   is the self-model eigenvalue equation.
//!
//! All arithmetic is integer-only (i32 octonion coefficients). No floating-point
//! in core paths. f64 is used only as a display sidecar for EvaluationResult.
//!
//! Scientific scope: The 6D consciousness engine implements genuine metacognitive
//! computation (self-evaluation, self-correction, self-modeling). It does NOT claim
//! phenomenal consciousness or subjective experience. The Jordan algebra provides
//! a formal mathematical framework for self-referential computation, not a proof
//! of consciousness.
//!
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const jordan = @import("jordan_algebra");

// =============================================================================
// Local types (to avoid cross-module dependency on metacognition_engine)
// =============================================================================

/// Evaluation result with 8 dimensions (matching the metacognition engine).
/// f64 is used as a display sidecar only; the Jordan algebra uses integer scores.
pub const EvaluationResult = struct {
    scores: [8]f64 = [_]f64{0} ** 8,
    overall: f64 = 0,
    passed: bool = false,
};

/// Scale factor: f64 scores [0,1] → i32 integers.
/// We use 100 as the scale (2 decimal places of precision).
/// This prevents i32 overflow in the Jordan product (100*100=10000, well within i32 range).
const SCORE_SCALE: i32 = 100;

/// Jordan self-model: maps 8 evaluation dimensions into J₃(O).
/// The 3 diagonal entries capture the 3 primary evaluation axes:
///   α = relevance, β = coherence, γ = specificity
/// The 3 off-diagonal octonionic entries capture the remaining 5 axes:
///   o1 = (naturalness, self-awareness, 0, 0, 0, 0, 0, 0)
///   o2 = (direct-experience, metacognition, 0, 0, 0, 0, 0, 0)
///   o3 = (situational-awareness, 0, 0, 0, 0, 0, 0, 0)
pub const JordanSelfModel = struct {
    element: jordan.J3Element,

    /// Creates a Jordan self-model from an evaluation result.
    pub fn fromEvaluation(eval: EvaluationResult) JordanSelfModel {
        const s = SCORE_SCALE;
        var o1: jordan.IntOct = .{ .c = .{0} ** 8 };
        o1.c[0] = @intFromFloat(eval.scores[3] * @as(f64, @floatFromInt(s)));
        o1.c[1] = @intFromFloat(eval.scores[4] * @as(f64, @floatFromInt(s)));
        var o2: jordan.IntOct = .{ .c = .{0} ** 8 };
        o2.c[0] = @intFromFloat(eval.scores[5] * @as(f64, @floatFromInt(s)));
        o2.c[1] = @intFromFloat(eval.scores[6] * @as(f64, @floatFromInt(s)));
        var o3: jordan.IntOct = .{ .c = .{0} ** 8 };
        o3.c[0] = @intFromFloat(eval.scores[7] * @as(f64, @floatFromInt(s)));
        return .{
            .element = jordan.J3Element{
                .alpha = @intFromFloat(eval.scores[0] * @as(f64, @floatFromInt(s))),
                .beta = @intFromFloat(eval.scores[1] * @as(f64, @floatFromInt(s))),
                .gamma = @intFromFloat(eval.scores[2] * @as(f64, @floatFromInt(s))),
                .o1 = o1,
                .o2 = o2,
                .o3 = o3,
            },
        };
    }

    /// Converts the Jordan self-model back to an evaluation result.
    pub fn toEvaluation(self: JordanSelfModel) EvaluationResult {
        const s = SCORE_SCALE;
        var scores: [8]f64 = [_]f64{0} ** 8;
        scores[0] = @as(f64, @floatFromInt(self.element.alpha)) / @as(f64, @floatFromInt(s));
        scores[1] = @as(f64, @floatFromInt(self.element.beta)) / @as(f64, @floatFromInt(s));
        scores[2] = @as(f64, @floatFromInt(self.element.gamma)) / @as(f64, @floatFromInt(s));
        scores[3] = @as(f64, @floatFromInt(self.element.o1.c[0])) / @as(f64, @floatFromInt(s));
        scores[4] = @as(f64, @floatFromInt(self.element.o1.c[1])) / @as(f64, @floatFromInt(s));
        scores[5] = @as(f64, @floatFromInt(self.element.o2.c[0])) / @as(f64, @floatFromInt(s));
        scores[6] = @as(f64, @floatFromInt(self.element.o2.c[1])) / @as(f64, @floatFromInt(s));
        scores[7] = @as(f64, @floatFromInt(self.element.o3.c[0])) / @as(f64, @floatFromInt(s));
        var overall: f64 = 0;
        for (scores) |sc| overall += sc;
        overall /= 8.0;
        return .{
            .scores = scores,
            .overall = overall,
            .passed = overall >= 0.5,
        };
    }

    /// The consciousness measure: trace of the Jordan self-model.
    /// tr(X) = α + β + γ — the scalar summary of the self-state.
    pub fn consciousnessMeasure(self: JordanSelfModel) i32 {
        return jordan.trace(self.element);
    }

    /// The self-consistency measure: determinant of the Jordan self-model.
    pub fn selfConsistency(self: JordanSelfModel) i64 {
        return jordan.determinant(self.element);
    }

    /// The secondary measure: secondary trace of the Jordan self-model.
    pub fn secondaryMeasure(self: JordanSelfModel) i64 {
        return jordan.secondaryTrace(self.element);
    }

    /// Normalizes the Jordan self-model so the trace stays within SCORE_SCALE * 3.
    pub fn normalize(self: JordanSelfModel) JordanSelfModel {
        const tr = jordan.trace(self.element);
        const target: i32 = SCORE_SCALE * 3;
        if (tr <= target or tr == 0) return self;
        const scale_num: i64 = @as(i64, target);
        const scale_den: i64 = @as(i64, tr);
        var result = self.element;
        result.alpha = @intCast(@divTrunc(@as(i64, result.alpha) * scale_num, scale_den));
        result.beta = @intCast(@divTrunc(@as(i64, result.beta) * scale_num, scale_den));
        result.gamma = @intCast(@divTrunc(@as(i64, result.gamma) * scale_num, scale_den));
        for (0..8) |i| {
            const scaled: i64 = @divTrunc(@as(i64, result.o1.c[i]) * scale_num, scale_den);
            result.o1.c[i] = @intCast(scaled);
            const scaled2: i64 = @divTrunc(@as(i64, result.o2.c[i]) * scale_num, scale_den);
            result.o2.c[i] = @intCast(scaled2);
            const scaled3: i64 = @divTrunc(@as(i64, result.o3.c[i]) * scale_num, scale_den);
            result.o3.c[i] = @intCast(scaled3);
        }
        return .{ .element = result };
    }

    /// Jordan self-evaluation: X ∘ Y = (XY + YX)/2.
    /// The commutative, non-associative self-referential product.
    pub fn jordanSelfEvaluate(current: JordanSelfModel, self_model: JordanSelfModel) JordanSelfModel {
        return .{ .element = jordan.jordanProduct(current.element, self_model.element) };
    }
};

// =============================================================================
// ConsciousnessConfig — 6D configuration
// =============================================================================

/// The 6D consciousness engine configuration.
pub const ConsciousnessConfig = struct {
    /// Confidence threshold for self-correction (Q64.64 fixed-point).
    /// If the consciousness measure falls below this, self-correction is triggered.
    confidence_threshold: i32 = 150, // 1.5 * SCORE_SCALE (scale=100)
    /// Maximum reflection cycles (generate → evaluate → correct).
    max_reflection_cycles: u8 = 3,
    /// Whether to use the Jordan algebra for self-evaluation.
    use_jordan_algebra: bool = true,
    /// Whether to maintain a self-model history.
    maintain_self_model: bool = true,
};

// =============================================================================
// ConsciousnessState — 6D state
// =============================================================================

/// The 6D consciousness state — a Jordan algebra element.
pub const ConsciousnessState = struct {
    element: jordan.J3Element,
    consciousness_measure: i32,
    self_consistency: i64,
    coupling_measure: i64,
    reflection_cycles: u8,
    passed: bool,

    pub fn zero() ConsciousnessState {
        return .{
            .element = jordan.J3Element.zero(),
            .consciousness_measure = 0,
            .self_consistency = 0,
            .coupling_measure = 0,
            .reflection_cycles = 0,
            .passed = false,
        };
    }

    pub fn fromElement(element: jordan.J3Element) ConsciousnessState {
        return .{
            .element = element,
            .consciousness_measure = jordan.trace(element),
            .self_consistency = jordan.determinant(element),
            .coupling_measure = jordan.secondaryTrace(element),
            .reflection_cycles = 0,
            .passed = jordan.trace(element) > 0,
        };
    }
};

// =============================================================================
// ConsciousnessEngine — 6D Metacognition & Self-Awareness
// =============================================================================

/// The 6D consciousness engine — pure metacognition, no language generation.
pub const ConsciousnessEngine = struct {
    config: ConsciousnessConfig,
    allocator: std.mem.Allocator,
    state: ConsciousnessState,
    self_model_history: std.ArrayList(jordan.J3Element),

    pub fn init(allocator: std.mem.Allocator, config: ConsciousnessConfig) ConsciousnessEngine {
        return .{
            .config = config,
            .allocator = allocator,
            .state = ConsciousnessState.zero(),
            .self_model_history = std.ArrayList(jordan.J3Element).init(allocator),
        };
    }

    pub fn deinit(self: *ConsciousnessEngine) void {
        self.self_model_history.deinit();
    }

    /// Evaluates a response using the Jordan algebra self-evaluation operator.
    pub fn evaluate(self: *ConsciousnessEngine, eval: EvaluationResult) ConsciousnessState {
        const current = JordanSelfModel.fromEvaluation(eval);
        var new_element: jordan.J3Element = undefined;
        if (self.state.consciousness_measure == 0) {
            new_element = current.element;
        } else {
            const product = JordanSelfModel.jordanSelfEvaluate(
                current,
                JordanSelfModel{ .element = self.state.element },
            );
            new_element = product.normalize().element;
        }
        const prev_cycles = self.state.reflection_cycles;
        self.state = ConsciousnessState.fromElement(new_element);
        self.state.reflection_cycles = prev_cycles + 1;
        self.state.passed = self.state.consciousness_measure >= self.config.confidence_threshold;
        if (self.config.maintain_self_model) {
            self.self_model_history.append(new_element) catch {};
            if (self.self_model_history.items.len > 100) {
                const len = self.self_model_history.items.len;
                for (1..len) |i| {
                    self.self_model_history.items[i - 1] = self.self_model_history.items[i];
                }
                self.self_model_history.shrinkRetainingCapacity(len - 1);
            }
        }
        return self.state;
    }

    pub fn needsCorrection(self: ConsciousnessEngine) bool {
        return !self.state.passed and self.state.reflection_cycles < self.config.max_reflection_cycles;
    }

    pub fn consciousnessMeasure(self: ConsciousnessEngine) i32 {
        return self.state.consciousness_measure;
    }

    pub fn selfConsistency(self: ConsciousnessEngine) i64 {
        return self.state.self_consistency;
    }

    pub fn couplingMeasure(self: ConsciousnessEngine) i64 {
        return self.state.coupling_measure;
    }

    pub fn selfModelEigenvalues(self: ConsciousnessEngine) jordan.CharPoly {
        return jordan.characteristicPolynomial(self.state.element);
    }

    pub fn reflectionCycles(self: ConsciousnessEngine) u8 {
        return self.state.reflection_cycles;
    }

    pub fn reset(self: *ConsciousnessEngine) void {
        self.state = ConsciousnessState.zero();
        self.self_model_history.clearRetainingCapacity();
    }

    pub fn historyLength(self: ConsciousnessEngine) usize {
        return self.self_model_history.items.len;
    }

    pub fn averageConsciousness(self: ConsciousnessEngine) i32 {
        if (self.self_model_history.items.len == 0) return 0;
        var sum: i64 = 0;
        for (self.self_model_history.items) |element| {
            sum += @as(i64, jordan.trace(element));
        }
        return @intCast(@divTrunc(sum, @as(i64, @intCast(self.self_model_history.items.len))));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ConsciousnessConfig: default values" {
    const config = ConsciousnessConfig{};
    try std.testing.expect(config.confidence_threshold == 150);
    try std.testing.expect(config.max_reflection_cycles == 3);
    try std.testing.expect(config.use_jordan_algebra == true);
    try std.testing.expect(config.maintain_self_model == true);
}

test "ConsciousnessState: zero state" {
    const state = ConsciousnessState.zero();
    try std.testing.expect(state.consciousness_measure == 0);
    try std.testing.expect(state.self_consistency == 0);
    try std.testing.expect(state.coupling_measure == 0);
    try std.testing.expect(state.reflection_cycles == 0);
    try std.testing.expect(state.passed == false);
}

test "ConsciousnessState: fromElement" {
    const element = jordan.J3Element.diagonal(80, 70, 60);
    const state = ConsciousnessState.fromElement(element);
    try std.testing.expect(state.consciousness_measure == 210);
    try std.testing.expect(state.passed == true);
}

test "ConsciousnessEngine: init creates zero state" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    try std.testing.expect(engine.consciousnessMeasure() == 0);
    try std.testing.expect(engine.historyLength() == 0);
}

test "ConsciousnessEngine: evaluate updates state" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1 },
        .overall = 0.5,
        .passed = true,
    };
    const state = engine.evaluate(eval);
    try std.testing.expect(state.consciousness_measure > 0);
    try std.testing.expect(state.reflection_cycles == 1);
    try std.testing.expect(engine.historyLength() == 1);
}

test "ConsciousnessEngine: needsCorrection when below threshold" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{ .confidence_threshold = 300 });
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 },
        .overall = 0.5,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    try std.testing.expect(engine.needsCorrection());
}

test "ConsciousnessEngine: no correction when above threshold" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{ .confidence_threshold = 100 });
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9 },
        .overall = 0.9,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    try std.testing.expect(!engine.needsCorrection());
}

test "ConsciousnessEngine: multiple evaluations accumulate" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1 },
        .overall = 0.5,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    _ = engine.evaluate(eval);
    _ = engine.evaluate(eval);
    try std.testing.expect(engine.reflectionCycles() == 3);
    try std.testing.expect(engine.historyLength() == 3);
}

test "ConsciousnessEngine: selfConsistency is non-negative for positive eval" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.9, 0.9, 0.9, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .overall = 0.9,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    try std.testing.expect(engine.selfConsistency() > 0);
}

test "ConsciousnessEngine: selfModelEigenvalues returns characteristic polynomial" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.8, 0.7, 0.6, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .overall = 0.7,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    const poly = engine.selfModelEigenvalues();
    try std.testing.expect(poly.c3 == 1);
    try std.testing.expect(poly.c2 == -210);
}

test "ConsciousnessEngine: reset clears state" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1 },
        .overall = 0.5,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    engine.reset();
    try std.testing.expect(engine.consciousnessMeasure() == 0);
    try std.testing.expect(engine.historyLength() == 0);
}

test "ConsciousnessEngine: averageConsciousness from history" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval1 = EvaluationResult{
        .scores = [_]f64{ 0.9, 0.9, 0.9, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .overall = 0.9,
        .passed = true,
    };
    _ = engine.evaluate(eval1);
    try std.testing.expect(engine.averageConsciousness() == 270);
}

test "6D purity: no language generation fields" {
    try std.testing.expect(@hasField(ConsciousnessEngine, "state"));
    try std.testing.expect(@hasField(ConsciousnessEngine, "self_model_history"));
    try std.testing.expect(!@hasField(ConsciousnessEngine, "bigram_model"));
    try std.testing.expect(!@hasField(ConsciousnessEngine, "dynamic_corpus"));
    try std.testing.expect(!@hasField(ConsciousnessEngine, "sample_config"));
    try std.testing.expect(!@hasField(ConsciousnessEngine, "dynamic_routes"));
}

test "ConsciousnessEngine: couplingMeasure returns secondary trace" {
    var engine = ConsciousnessEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const eval = EvaluationResult{
        .scores = [_]f64{ 0.8, 0.7, 0.6, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .overall = 0.7,
        .passed = true,
    };
    _ = engine.evaluate(eval);
    try std.testing.expect(engine.couplingMeasure() == 14600);
}
