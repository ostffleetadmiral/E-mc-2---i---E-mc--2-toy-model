//! Deterministic metabench for routing and cognitive-lane promotion.
//! It is offline by design; live model quality belongs to meta-bench.

const std = @import("std");
const q128 = @import("q128");
const lanes = @import("cognitive_lanes");
const kimi = @import("kimi_stream_adapter");
const calibration = @import("routing_calibration");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var lane_state = lanes.CognitiveLanes.init(allocator, 64, 32);
    defer lane_state.deinit();
    var cache = try kimi.ExpertCache.init(allocator, 8);
    defer cache.deinit(allocator);

    var promoted: usize = 0;
    var rejected: usize = 0;
    var observed: usize = 0;
    for (0..128) |i| {
        const confidence = q128.fromRatio(@intCast((i * 7) % 101), 100);
        const candidate = lanes.Candidate{
            .id = @intCast(i),
            .confidence = confidence,
            .novelty = q128.fromRatio(@intCast((i % 10) + 1), 10),
            .provenance = if (i % 3 == 0) .external else .lattice,
            .verified = i % 3 == 0,
        };
        try lane_state.submitImplicit(candidate);
        observed += 1;
        const decision = try lane_state.promote(candidate);
        if (decision.accepted) promoted += 1 else rejected += 1;

        const slot = cache.reserve(@intCast(i % 12), false);
        if (slot) |s| _ = cache.publish(s, 1024, true);
    }

    const calibration_samples = [_]calibration.Sample{
        .{ .confidence = q128.fromRatio(2, 10), .needs_fallback = true },
        .{ .confidence = q128.fromRatio(4, 10), .needs_fallback = true },
        .{ .confidence = q128.fromRatio(8, 10), .needs_fallback = false },
        .{ .confidence = q128.fromRatio(9, 10), .needs_fallback = false },
    };
    const calibration_metrics = calibration.evaluate(&calibration_samples, q128.fromRatio(5, 10));
    const writer = std.io.getStdOut().writer();
    try writer.print(
        "{{\"observed\":{d},\"implicit_retained\":{d},\"promoted\":{d}," ++
            "\"rejected\":{d},\"cache_hits\":{d},\"cache_misses\":{d}," ++
            "\"cache_evictions\":{d},\"calibration_f1\":{d}}}\n",
        .{ observed, lane_state.implicit.items.items.len, promoted, rejected, cache.hits, cache.misses, cache.evictions, q128.toF64(calibration_metrics.f1()) },
    );
}
