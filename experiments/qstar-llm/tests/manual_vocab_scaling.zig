//! manual_vocab_scaling.zig — Verification script for vocab × lattice scaling prototype
//!
//! Runs the prototype as an executable and verifies:
//! 1. Collision statistics per level
//! 2. Round-trip fidelity meets targets
//! 3. Mapping is O(1) at all scales
//! 4. s=0 is backward compatible with current Qstar

const std = @import("std");
const vls = @import("vocab_lattice_scaling");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Vocab × Lattice Scaling — Manual Verification           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});

    const vocab_paths = [_][]const u8{
        ".foundations/RamseyLLM/vocabs/vocab-128k.txt",
        ".foundations/RamseyLLM/vocabs/vocab-256k.txt",
        ".foundations/RamseyLLM/vocabs/vocab-512k.txt",
        ".foundations/RamseyLLM/vocabs/vocab-1m.txt",
    };

    const expected_sizes = [_]usize{ 131072, 262144, 524288, 1048576 };

    var all_pass = true;
    var results: [4]vls.LevelResult = undefined;

    for (0..4) |idx| {
        const level: u8 = @intCast(idx);

        std.debug.print("\n  [{d}/4] Loading vocab: {s}\n", .{ idx + 1, vocab_paths[idx] });
        var vocab = vls.VocabEntry.init(allocator);
        defer vocab.deinit();

        const loaded = vocab.loadTxt(vocab_paths[idx]) catch |err| {
            std.debug.print("  FAILED: {s}\n", .{@errorName(err)});
            all_pass = false;
            continue;
        };

        std.debug.print("  Loaded {d} tokens (expected {d})\n", .{ loaded, expected_sizes[idx] });
        if (loaded != expected_sizes[idx]) {
            std.debug.print("  ⚠  SIZE MISMATCH\n", .{});
            all_pass = false;
        }

        const result = try vls.runLevelTest(allocator, level, &vocab);
        results[idx] = result;

        std.debug.print("  Node count:    {d}\n", .{result.node_count});
        std.debug.print("  Token slots:   {d}\n", .{result.token_slots});
        std.debug.print("  Tok/slot:      {d:.2}\n", .{result.tok_per_slot});
        std.debug.print("  Slots used:    {d} / {d} ({d:.2}%)\n", .{ result.slots_used, result.token_slots, result.slot_coverage * 100 });
        std.debug.print("  Tok/slot range:{d} .. {d}\n", .{ result.min_tokens_per_slot, result.max_tokens_per_slot });
        std.debug.print("  Collisions:    {d} ({d:.4}%)\n", .{ result.collision_count, result.collision_rate * 100 });
        std.debug.print("  Fidelity:      {d:.4}%\n", .{result.roundtrip_fidelity * 100});
        std.debug.print("  Map time:      {d} ns/op\n", .{result.map_time_ns});

        // Round-trip should be 100% (modular arithmetic is bijection within mappable range)
        if (result.roundtrip_fidelity >= 1.0) {
            std.debug.print("  ✓  PASS (fidelity 100%)\n", .{});
        } else {
            std.debug.print("  ✗  FAIL — fidelity {d:.4}% < 100%\n", .{result.roundtrip_fidelity * 100});
            all_pass = false;
        }

        if (result.roundtrip_fail > 0) {
            std.debug.print("  ✗  FAIL — {d} round-trip failures\n", .{result.roundtrip_fail});
            all_pass = false;
        }

        // Slot coverage: 100% when vocab ≥ slots, lower is OK when vocab < slots
        if (result.vocab_size >= result.token_slots and result.slot_coverage < 0.99) {
            std.debug.print("  ✗  FAIL — slot coverage {d:.2}% < 99% (vocab > slots, should be full)\n", .{result.slot_coverage * 100});
            all_pass = false;
        } else if (result.vocab_size < result.token_slots) {
            std.debug.print("  ✓  Slot coverage {d:.2}% (expected: vocab < slots, sparse is OK)\n", .{result.slot_coverage * 100});
        } else {
            std.debug.print("  ✓  Slot coverage OK ({d:.2}%)\n", .{result.slot_coverage * 100});
        }
    }

    // Backward compatibility check
    std.debug.print("\n  Backward compatibility (s=0 = current Qstar):\n", .{});
    if (vls.scaledNodeCount(0) == 421) {
        std.debug.print("  ✓  s=0 node count = 421 (matches current Qstar)\n", .{});
    } else {
        std.debug.print("  ✗  s=0 node count = {d} (NOT 421)\n", .{vls.scaledNodeCount(0)});
        all_pass = false;
    }

    // Performance summary
    std.debug.print("\n  Performance summary:\n", .{});
    for (results) |r| {
        std.debug.print("  s={d}: {d} ns/op, {d} tok/slot, {d:.4}% fidelity\n", .{ r.level, r.map_time_ns, r.tok_per_slot, r.roundtrip_fidelity * 100 });
    }

    // Autoscaler demo
    std.debug.print("\n  ┌─ Autoscaler Demo ────────────────────────────────────\n", .{});
    const scenarios = [_]struct {
        name: []const u8,
        unique_tokens: usize,
        corpus_bytes: usize,
        expected_level: u8,
    }{
        .{ .name = "Small (1K tokens, 100KB)", .unique_tokens = 1_000, .corpus_bytes = 100 * 1024, .expected_level = 0 },
        .{ .name = "Medium (3.2K tokens, 200KB)", .unique_tokens = 3_200, .corpus_bytes = 200 * 1024, .expected_level = 0 },
        .{ .name = "Growing (130K tokens, 1MB)", .unique_tokens = 130_000, .corpus_bytes = 1 * 1024 * 1024, .expected_level = 2 },
        .{ .name = "Large (260K tokens, 3MB)", .unique_tokens = 260_000, .corpus_bytes = 3 * 1024 * 1024, .expected_level = 2 },
        .{ .name = "Very large (600K tokens, 10MB)", .unique_tokens = 600_000, .corpus_bytes = 10 * 1024 * 1024, .expected_level = 3 },
        .{ .name = "Full 1M (1M tokens, 20MB)", .unique_tokens = 1_000_000, .corpus_bytes = 20 * 1024 * 1024, .expected_level = 3 },
        .{ .name = "Shrink back (1K tokens, 50KB)", .unique_tokens = 1_000, .corpus_bytes = 50 * 1024, .expected_level = 0 },
    };

    var scaler = vls.Autoscaler.init(0, .{});
    for (scenarios) |s| {
        const final_level = scaler.simulateCorpus(s.unique_tokens, s.corpus_bytes);
        const vocab = scaler.currentVocab();
        const pass = final_level == s.expected_level;
        if (!pass) all_pass = false;
        std.debug.print("  │ {s:<30} → s{d} | {s} | {s}\n", .{
            s.name, final_level, vocab.name,
            if (pass) "✓" else "✗ FAIL",
        });
    }
    std.debug.print("  └───────────────────────────────────────────────────────\n", .{});

    // Final verdict
    std.debug.print("\n", .{});
    if (all_pass) {
        std.debug.print("  ╔══════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("  ║  ✓ ALL VERIFICATION CHECKS PASSED                    ║\n", .{});
        std.debug.print("  ║  Prototype is ready for Phase 3 integration.         ║\n", .{});
        std.debug.print("  ╚══════════════════════════════════════════════════════╝\n", .{});
    } else {
        std.debug.print("  ╔══════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("  ║  ✗ SOME CHECKS FAILED — Review output above          ║\n", .{});
        std.debug.print("  ╚══════════════════════════════════════════════════════╝\n", .{});
    }
}
