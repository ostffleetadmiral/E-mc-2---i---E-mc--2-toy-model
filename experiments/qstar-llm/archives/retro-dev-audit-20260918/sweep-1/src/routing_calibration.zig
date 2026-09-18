//! Fixed-point calibration utilities for lattice/external routing.
//!
//! A sample is labeled from a held-out judge or trusted local evaluator. This
//! module only measures threshold behavior; it does not manufacture labels.

const std = @import("std");
const q128 = @import("q128");

pub const Sample = struct {
    confidence: q128.Fp,
    needs_fallback: bool,
};

pub const Metrics = struct {
    threshold: q128.Fp,
    true_positive: usize = 0,
    false_positive: usize = 0,
    true_negative: usize = 0,
    false_negative: usize = 0,

    pub fn fallbackRate(self: Metrics) q128.Fp {
        const total = self.true_positive + self.false_positive + self.true_negative + self.false_negative;
        if (total == 0) return 0;
        return q128.fromRatio(@intCast(self.true_positive + self.false_positive), @intCast(total));
    }

    pub fn precision(self: Metrics) q128.Fp {
        const total = self.true_positive + self.false_positive;
        if (total == 0) return 0;
        return q128.fromRatio(@intCast(self.true_positive), @intCast(total));
    }

    pub fn recall(self: Metrics) q128.Fp {
        const total = self.true_positive + self.false_negative;
        if (total == 0) return 0;
        return q128.fromRatio(@intCast(self.true_positive), @intCast(total));
    }

    pub fn f1(self: Metrics) q128.Fp {
        const p = self.precision();
        const r = self.recall();
        if (p == 0 or r == 0) return 0;
        return q128.div(q128.mul(q128.fromInt(2), q128.mul(p, r)), q128.add(p, r));
    }
};

pub fn evaluate(samples: []const Sample, threshold: q128.Fp) Metrics {
    var result = Metrics{ .threshold = threshold };
    for (samples) |sample| {
        const predicted_fallback = q128.cmp(sample.confidence, threshold) < 0;
        if (predicted_fallback and sample.needs_fallback) result.true_positive += 1;
        if (predicted_fallback and !sample.needs_fallback) result.false_positive += 1;
        if (!predicted_fallback and !sample.needs_fallback) result.true_negative += 1;
        if (!predicted_fallback and sample.needs_fallback) result.false_negative += 1;
    }
    return result;
}

pub fn bestThreshold(samples: []const Sample, candidates: []const q128.Fp) ?Metrics {
    if (candidates.len == 0) return null;
    var best = evaluate(samples, candidates[0]);
    for (candidates[1..]) |threshold| {
        const current = evaluate(samples, threshold);
        if (q128.cmp(current.f1(), best.f1()) > 0 or
            (current.f1() == best.f1() and q128.cmp(current.precision(), best.precision()) > 0))
        {
            best = current;
        }
    }
    return best;
}

test "routing calibration computes confusion matrix" {
    const samples = [_]Sample{
        .{ .confidence = q128.fromRatio(1, 10), .needs_fallback = true },
        .{ .confidence = q128.fromRatio(2, 10), .needs_fallback = true },
        .{ .confidence = q128.fromRatio(8, 10), .needs_fallback = false },
        .{ .confidence = q128.fromRatio(9, 10), .needs_fallback = false },
    };
    const metrics = evaluate(&samples, q128.fromRatio(5, 10));
    try std.testing.expectEqual(@as(usize, 2), metrics.true_positive);
    try std.testing.expectEqual(@as(usize, 2), metrics.true_negative);
    try std.testing.expectEqual(q128.ONE, metrics.precision());
    try std.testing.expectEqual(q128.ONE, metrics.recall());
}

test "routing calibration selects best threshold" {
    const samples = [_]Sample{
        .{ .confidence = q128.fromRatio(1, 10), .needs_fallback = true },
        .{ .confidence = q128.fromRatio(4, 10), .needs_fallback = true },
        .{ .confidence = q128.fromRatio(7, 10), .needs_fallback = false },
        .{ .confidence = q128.fromRatio(9, 10), .needs_fallback = false },
    };
    const thresholds = [_]q128.Fp{ q128.fromRatio(2, 10), q128.fromRatio(5, 10), q128.fromRatio(8, 10) };
    const best = bestThreshold(&samples, &thresholds).?;
    try std.testing.expectEqual(q128.fromRatio(5, 10), best.threshold);
}

test "routing calibration handles empty candidates" {
    const samples = [_]Sample{};
    try std.testing.expect(bestThreshold(&samples, &[_]q128.Fp{}) == null);
}
