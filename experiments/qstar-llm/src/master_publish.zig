//! master_publish.zig — Master node publisher.
//!
//! Copies the CI/CD-gated quine payloads (universe.html, qstar_corpus.qsc,
//! qstar_llm.wasm, seed_manifest.json) from zig-out/ into the master publish
//! directory (zig-out/master/). This directory is the authoritative update
//! channel served by `qstar master-serve` and mirrored over P2P by
//! `qstar master publish-p2p`.
//!
//! Usage: master_publish [--output <dir>]

const std = @import("std");

const ARTIFACTS = [_][]const u8{
    "universe.html",
    "qstar_corpus.qsc",
    "qstar_corpus_distilled.txt",
    "qstar_llm.wasm",
    "seed_manifest.json",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var output_dir: []const u8 = "zig-out/master";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        }
    }

    try std.fs.cwd().makePath(output_dir);

    var published: usize = 0;
    for (ARTIFACTS) |name| {
        // The WASM installs under zig-out/wasm/; everything else lives in zig-out/.
        const src_path = if (std.mem.eql(u8, name, "qstar_llm.wasm"))
            try std.fs.path.join(allocator, &.{ "zig-out", "wasm", name })
        else
            try std.fs.path.join(allocator, &.{ "zig-out", name });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ output_dir, name });
        defer allocator.free(dst_path);

        const src = std.fs.cwd().openFile(src_path, .{}) catch |err| {
            std.debug.print("WARNING: missing artifact {s} ({s}) — skipping\n", .{ src_path, @errorName(err) });
            continue;
        };
        defer src.close();
        const data = src.readToEndAlloc(allocator, 400 * 1024 * 1024) catch continue;
        defer allocator.free(data);

        const dst = try std.fs.cwd().createFile(dst_path, .{});
        defer dst.close();
        try dst.writeAll(data);
        std.debug.print("Published: {s} ({d} bytes)\n", .{ dst_path, data.len });
        published += 1;
    }

    std.debug.print("Master publish complete: {d}/{d} artifacts in {s}\n", .{ published, ARTIFACTS.len, output_dir });
    if (published < ARTIFACTS.len) return error.MissingArtifacts;
}

// =============================================================================
// Tests
// =============================================================================

test "master_publish: artifact list is complete" {
    try std.testing.expectEqual(@as(usize, 5), ARTIFACTS.len);
    try std.testing.expectEqualStrings("universe.html", ARTIFACTS[0]);
    try std.testing.expectEqualStrings("qstar_corpus.qsc", ARTIFACTS[1]);
    try std.testing.expectEqualStrings("qstar_corpus_distilled.txt", ARTIFACTS[2]);
    try std.testing.expectEqualStrings("qstar_llm.wasm", ARTIFACTS[3]);
    try std.testing.expectEqualStrings("seed_manifest.json", ARTIFACTS[4]);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
