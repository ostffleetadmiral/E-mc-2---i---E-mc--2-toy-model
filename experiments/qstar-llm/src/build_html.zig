//! build_html.zig — Build tool that embeds WASM + distilled corpus into universe_template.html
//!
//! Usage: zig build html
//! This tool:
//! 1. Reads the pre-built qstar_llm.wasm from zig-out/lib/
//! 2. Base64-encodes the WASM binary
//! 3. Optionally reads a .qsc compressed corpus and distills the top-N most
//!    frequent sentences (by frequency) into a compact subset, base64-encoded
//! 4. Reads the universe_template.html
//! 5. Replaces {{WASM_BASE64}} and {{CORPUS_BASE64}} placeholders
//! 6. Writes the final self-contained universe.html to zig-out/universe.html
//!
//! The embedded distilled corpus makes the HTML self-modifying (quine-style):
//! the page ships with its own distilled knowledge base and can re-emit itself
//! on demand. The full corpus stays on disk as qstar_corpus.qsc; universe.html
//! embeds only the distilled subset (default <= 7 MB raw -> ~9.3 MB base64).

const std = @import("std");
const corpus_store = @import("corpus_store");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var wasm_path: []const u8 = "zig-out/lib/qstar_llm.wasm";
    var template_path: []const u8 = "src/universe_template.html";
    var output_path: []const u8 = "zig-out/universe.html";
    var corpus_path: ?[]const u8 = null;
    var distill_budget: usize = 7 * 1024 * 1024; // 7 MB raw distilled subset
    var version: []const u8 = "";
    var seed_path: ?[]const u8 = null;

    for (args, 0..) |arg, i| {
        if (i == 0) continue;
        if (std.mem.eql(u8, arg, "--wasm") and i + 1 < args.len) {
            wasm_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--template") and i + 1 < args.len) {
            template_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            output_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--corpus") and i + 1 < args.len) {
            corpus_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--distill") and i + 1 < args.len) {
            distill_budget = std.fmt.parseInt(usize, args[i + 1], 10) catch distill_budget;
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            version = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--seed") and i + 1 < args.len) {
            seed_path = args[i + 1];
        }
    }

    // Resolve seed version: --version > VERSION file > timestamp.
    var version_buf: [64]u8 = undefined;
    var version_len: usize = 0;
    if (std.fs.cwd().openFile("VERSION", .{})) |file| {
        defer file.close();
        version_len = file.readAll(&version_buf) catch 0;
    } else |_| {}
    const version_trimmed = std.mem.trim(u8, version_buf[0..version_len], " \t\r\n");
    const resolved_version = if (version.len > 0) version else if (version_trimmed.len > 0) version_trimmed else blk: {
        const ts = std.time.timestamp();
        break :blk std.fmt.bufPrint(&version_buf, "0.0.0-{d}", .{ts}) catch "0.0.0";
    };

    // Step 1: Read WASM binary
    const wasm_file = std.fs.cwd().openFile(wasm_path, .{}) catch |err| {
        std.debug.print("ERROR: Cannot open WASM at {s}: {s}\n", .{ wasm_path, @errorName(err) });
        std.debug.print("Did you run 'zig build wasm' first?\n", .{});
        return err;
    };
    defer wasm_file.close();
    const wasm_data = try wasm_file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(wasm_data);

    std.debug.print("WASM size: {d} bytes\n", .{wasm_data.len});

    // Step 2: Base64-encode the WASM
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(wasm_data.len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);
    _ = encoder.encode(b64_buf, wasm_data);

    std.debug.print("Base64 size: {d} bytes\n", .{b64_buf.len});

    // Step 2b: Hash the WASM binary (capabilities/tools ride in it).
    const wasm_hash = try sha256Hex(allocator, wasm_data);
    defer allocator.free(wasm_hash);

    // Step 3: Distill corpus (.qsc) into a compact subset and base64-encode it (optional)
    var corpus_b64: ?[]u8 = null;
    defer if (corpus_b64) |cb| allocator.free(cb);
    var distilled_raw: ?[]u8 = null;
    defer if (distilled_raw) |dr| allocator.free(dr);
    if (corpus_path) |cp| {
        const distilled = distillCorpus(allocator, cp, distill_budget) catch |err| blk: {
            std.debug.print("WARNING: Cannot distill corpus at {s}: {s} — embedding empty corpus\n", .{ cp, @errorName(err) });
            break :blk try allocator.dupe(u8, "");
        };
        distilled_raw = distilled;
        const c_b64_len = encoder.calcSize(distilled.len);
        const c_b64_buf = try allocator.alloc(u8, c_b64_len);
        _ = encoder.encode(c_b64_buf, distilled);
        corpus_b64 = c_b64_buf;
        std.debug.print("Distilled corpus: {d} raw bytes -> {d} base64 bytes\n", .{ distilled.len, c_b64_buf.len });
        // Write the raw distilled text payload for browser quine autoupdates.
        const distilled_path = "zig-out/qstar_corpus_distilled.txt";
        const df = try std.fs.cwd().createFile(distilled_path, .{});
        defer df.close();
        try df.writeAll(distilled);
        std.debug.print("Distilled payload: {s} ({d} bytes)\n", .{ distilled_path, distilled.len });
    } else {
        corpus_b64 = try allocator.dupe(u8, "");
    }

    // Hash the embedded distilled corpus (what the quine compares against the manifest).
    const distilled_hash = try sha256Hex(allocator, distilled_raw orelse "");
    defer allocator.free(distilled_hash);

    // Hash the full .qsc payload (what quines pull to learn the full corpus).
    var full_corpus_hash: ?[]u8 = null;
    defer if (full_corpus_hash) |h| allocator.free(h);
    if (corpus_path) |cp| {
        if (std.fs.cwd().openFile(cp, .{})) |cf| {
            defer cf.close();
            const cdata = cf.readToEndAlloc(allocator, 300 * 1024 * 1024) catch null;
            if (cdata) |cd| {
                defer allocator.free(cd);
                full_corpus_hash = try sha256Hex(allocator, cd);
            }
        } else |_| {}
    }

    // Step 4: Read template
    const tmpl_file = std.fs.cwd().openFile(template_path, .{}) catch |err| {
        std.debug.print("ERROR: Cannot open template at {s}: {s}\n", .{ template_path, @errorName(err) });
        return err;
    };
    defer tmpl_file.close();
    const tmpl_data = try tmpl_file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(tmpl_data);

    // Step 5: Replace placeholders (WASM then corpus)
    const placeholder = "{{WASM_BASE64}}";
    const replacement = b64_buf;
    const corpus_placeholder = "{{CORPUS_BASE64}}";
    const corpus_replacement = corpus_b64.?;

    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, tmpl_data, search_start, placeholder)) |pos| {
        count += 1;
        search_start = pos + placeholder.len;
    }

    if (count == 0) {
        std.debug.print("WARNING: Placeholder {s} not found in template. Writing template as-is.\n", .{placeholder});
        const out_file = try std.fs.cwd().createFile(output_path, .{});
        defer out_file.close();
        try out_file.writeAll(tmpl_data);
        std.debug.print("Output: {s} ({d} bytes)\n", .{ output_path, tmpl_data.len });
        return;
    }

    // Calculate output size
    const output_len = tmpl_data.len - (count * placeholder.len) + (count * replacement.len);
    const output_buf = try allocator.alloc(u8, output_len);
    defer allocator.free(output_buf);

    // Perform replacement
    var out_pos: usize = 0;
    var tmpl_pos: usize = 0;
    while (std.mem.indexOfPos(u8, tmpl_data, tmpl_pos, placeholder)) |pos| {
        @memcpy(output_buf[out_pos .. out_pos + pos - tmpl_pos], tmpl_data[tmpl_pos..pos]);
        out_pos += pos - tmpl_pos;
        @memcpy(output_buf[out_pos .. out_pos + replacement.len], replacement);
        out_pos += replacement.len;
        tmpl_pos = pos + placeholder.len;
    }
    @memcpy(output_buf[out_pos..], tmpl_data[tmpl_pos..]);

    // Step 6: Replace corpus placeholder (after WASM replacement)
    var corpus_count: usize = 0;
    var c_search_start: usize = 0;
    while (std.mem.indexOfPos(u8, output_buf, c_search_start, corpus_placeholder)) |pos| {
        corpus_count += 1;
        c_search_start = pos + corpus_placeholder.len;
    }

    var final_buf: []u8 = output_buf;
    defer if (final_buf.ptr != output_buf.ptr) allocator.free(final_buf);
    if (corpus_count > 0) {
        const final_len = final_buf.len - (corpus_count * corpus_placeholder.len) + (corpus_count * corpus_replacement.len);
        const new_buf = try allocator.alloc(u8, final_len);
        var c_out_pos: usize = 0;
        var c_tmpl_pos: usize = 0;
        while (std.mem.indexOfPos(u8, final_buf, c_tmpl_pos, corpus_placeholder)) |pos| {
            @memcpy(new_buf[c_out_pos .. c_out_pos + pos - c_tmpl_pos], final_buf[c_tmpl_pos..pos]);
            c_out_pos += pos - c_tmpl_pos;
            @memcpy(new_buf[c_out_pos .. c_out_pos + corpus_replacement.len], corpus_replacement);
            c_out_pos += corpus_replacement.len;
            c_tmpl_pos = pos + corpus_placeholder.len;
        }
        @memcpy(new_buf[c_out_pos..], final_buf[c_tmpl_pos..]);
        if (final_buf.ptr != output_buf.ptr) allocator.free(final_buf);
        final_buf = new_buf;
    }

    // Step 6b: Read and base64-encode compressed seed (optional)
    var seed_b64: []u8 = "";
    defer if (seed_b64.len > 0) allocator.free(seed_b64);
    if (seed_path) |sp| {
        if (std.fs.cwd().openFile(sp, .{})) |sf| {
            defer sf.close();
            const seed_data = try sf.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(seed_data);
            const s_b64_len = encoder.calcSize(seed_data.len);
            seed_b64 = try allocator.alloc(u8, s_b64_len);
            _ = encoder.encode(seed_b64, seed_data);
            std.debug.print("Compressed seed: {d} raw bytes -> {d} base64 bytes\n", .{ seed_data.len, seed_b64.len });
        } else |_| {
            std.debug.print("WARNING: Cannot open seed at {s} — embedding empty seed\n", .{sp});
            seed_b64 = try allocator.dupe(u8, "");
        }
    } else {
        seed_b64 = try allocator.dupe(u8, "");
    }

    // Step 7: Replace seed metadata placeholders (version + hashes + seed base64)
    const html_hash = try sha256Hex(allocator, final_buf);
    defer allocator.free(html_hash);
    const meta = [_]struct { ph: []const u8, val: []const u8 }{
        .{ .ph = "{{SEED_VERSION}}", .val = resolved_version },
        .{ .ph = "{{SEED_HASH}}", .val = distilled_hash },
        .{ .ph = "{{SEED_BASE64}}", .val = seed_b64 },
        .{ .ph = "{{WASM_HASH}}", .val = wasm_hash },
    };
    for (meta) |m| {
        const new_buf = try replaceAll(allocator, final_buf, m.ph, m.val);
        if (final_buf.ptr != output_buf.ptr) allocator.free(final_buf);
        final_buf = new_buf;
    }

    // Step 8: Write seed manifest next to the output (master node publish metadata).
    var manifest_path_buf: [1024]u8 = undefined;
    const manifest_path = if (std.mem.lastIndexOfScalar(u8, output_path, '/')) |slash|
        std.fmt.bufPrint(&manifest_path_buf, "{s}/seed_manifest.json", .{output_path[0..slash]}) catch "seed_manifest.json"
    else
        "seed_manifest.json";
    const manifest = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "version": "{s}",
        \\  "timestamp": {d},
        \\  "corpus_sha256": "{s}",
        \\  "distilled_corpus_sha256": "{s}",
        \\  "wasm_sha256": "{s}",
        \\  "html_sha256": "{s}",
        \\  "capabilities_version": "421-e0-7ch",
        \\  "tools_version": "58"
        \\}}
    , .{
        resolved_version,
        std.time.timestamp(),
        full_corpus_hash orelse "",
        distilled_hash,
        wasm_hash,
        html_hash,
    });
    defer allocator.free(manifest);
    {
        const mf = try std.fs.cwd().createFile(manifest_path, .{});
        defer mf.close();
        try mf.writeAll(manifest);
    }
    std.debug.print("Manifest: {s}\n", .{manifest_path});

    // Step 9: Write output
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    try out_file.writeAll(final_buf);

    std.debug.print("Output: {s} ({d} bytes)\n", .{ output_path, final_buf.len });
    std.debug.print("Embedded {d} WASM bytes as base64\n", .{wasm_data.len});
    std.debug.print("Embedded {d} distilled corpus bytes as base64\n", .{corpus_replacement.len});
}

/// Distills the .qsc corpus into the top-N most frequent sentences (by
/// frequency) up to `budget` raw bytes. Deterministic: same input -> same subset.
/// Returns an owned slice; caller frees.
fn distillCorpus(allocator: std.mem.Allocator, qsc_path: []const u8, budget: usize) ![]u8 {
    var store = try corpus_store.CorpusStore.init(allocator, qsc_path);
    defer store.deinit();

    // Count sentence frequencies.
    var freq = std.StringHashMap(usize).init(allocator);
    defer {
        var it = freq.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        freq.deinit();
    }
    const CountCtx = struct {
        freq: *std.StringHashMap(usize),
        allocator: std.mem.Allocator,
    };
    try store.streamLines(&CountCtx{ .freq = &freq, .allocator = allocator }, struct {
        fn cb(ctx: *const CountCtx, line: []const u8) void {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len < 8) return; // skip noise
            if (ctx.freq.getPtr(trimmed)) |count| {
                count.* += 1;
            } else {
                const key = ctx.allocator.dupe(u8, trimmed) catch return;
                ctx.freq.put(key, 1) catch {
                    ctx.allocator.free(key);
                };
            }
        }
    }.cb);

    // Collect (sentence, count) pairs and sort by count descending.
    const FreqItem = struct { text: []const u8, count: usize };
    var items = std.ArrayList(FreqItem).init(allocator);
    defer items.deinit();
    var it = freq.iterator();
    while (it.next()) |entry| {
        try items.append(.{ .text = entry.key_ptr.*, .count = entry.value_ptr.* });
    }
    std.mem.sort(FreqItem, items.items, {}, struct {
        fn lessThan(_: void, a: FreqItem, b: FreqItem) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.text, b.text);
        }
    }.lessThan);

    // Take top sentences until budget.
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (items.items) |item| {
        if (out.items.len + item.text.len + 1 > budget) break;
        try out.appendSlice(item.text);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

// =============================================================================
// Helpers
// =============================================================================

/// Computes the lowercase hex SHA-256 of `data`. Caller frees the result.
fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, 64);
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return hex;
}

/// Replaces every occurrence of `placeholder` in `buf` with `replacement`.
/// Returns a new owned buffer; caller frees. Copies even if absent.
fn replaceAll(allocator: std.mem.Allocator, buf: []const u8, placeholder: []const u8, replacement: []const u8) ![]u8 {
    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, buf, search_start, placeholder)) |pos| {
        count += 1;
        search_start = pos + placeholder.len;
    }
    const out_len = buf.len - (count * placeholder.len) + (count * replacement.len);
    const out = try allocator.alloc(u8, out_len);
    var out_pos: usize = 0;
    var tmpl_pos: usize = 0;
    while (std.mem.indexOfPos(u8, buf, tmpl_pos, placeholder)) |pos| {
        @memcpy(out[out_pos .. out_pos + pos - tmpl_pos], buf[tmpl_pos..pos]);
        out_pos += pos - tmpl_pos;
        @memcpy(out[out_pos .. out_pos + replacement.len], replacement);
        out_pos += replacement.len;
        tmpl_pos = pos + placeholder.len;
    }
    @memcpy(out[out_pos..], buf[tmpl_pos..]);
    return out;
}

// =============================================================================
// Tests
// =============================================================================

test "build_html: distill is deterministic and respects budget" {
    const allocator = std.testing.allocator;

    const raw_path = "test_distill_raw.txt";
    const qsc_path = "test_distill.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    var raw_content = std.ArrayList(u8).init(allocator);
    defer raw_content.deinit();
    // Frequent sentence appears 10x; rare sentence appears once.
    for (0..10) |_| {
        try raw_content.appendSlice("The lattice engine computes knowledge dynamically.\n");
    }
    try raw_content.appendSlice("A rare one-off observation about quantum entanglement.\n");

    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll(raw_content.items);

    _ = try corpus_store.buildCorpusStore(allocator, raw_path, qsc_path, 512);

    const d1 = try distillCorpus(allocator, qsc_path, 1024 * 1024);
    defer allocator.free(d1);
    const d2 = try distillCorpus(allocator, qsc_path, 1024 * 1024);
    defer allocator.free(d2);

    try std.testing.expectEqualStrings(d1, d2); // deterministic
    try std.testing.expect(std.mem.indexOf(u8, d1, "lattice engine computes") != null); // frequent sentence kept
    try std.testing.expect(d1.len <= 1024 * 1024); // budget respected

    // Tight budget keeps only the most frequent sentence.
    const tight = try distillCorpus(allocator, qsc_path, 60);
    defer allocator.free(tight);
    try std.testing.expect(std.mem.indexOf(u8, tight, "lattice engine computes") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight, "rare one-off") == null);
}

test "build_html: base64 round-trip of distilled corpus" {
    const allocator = std.testing.allocator;
    const encoder = std.base64.standard.Encoder;
    const decoder = std.base64.standard.Decoder;

    const sample = "The lattice engine stores knowledge. " ** 20;
    const b64_len = encoder.calcSize(sample.len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);
    _ = encoder.encode(b64_buf, sample);

    const decoded = try allocator.alloc(u8, try decoder.calcSizeForSlice(b64_buf));
    defer allocator.free(decoded);
    try decoder.decode(decoded, b64_buf);
    try std.testing.expectEqualStrings(sample, decoded);
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
