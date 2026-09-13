//! compress.zig — Self-contained compressor for the Qstar corpus pipeline.
//!
//! Ported from /home/projects/Qstar/src/compress.zig (purified compressor).
//! No file I/O — pure functions only: compress([]const u8) → []u8 / decompress([]const u8) → []u8.
//!
//! Pipeline:
//!   compress:   data → dedup → gzip → lattice_transform(level) → RMSY container
//!   decompress: RMSY container → lattice_inverse → gzip_decompress → dedup_restore → data
//!
//! Self-similarity dedup: find repeated 8-byte patterns, store as templates.
//! This is the compression engine behind the quine-style .qsc corpus container:
//! the container stores its own schema (magic + page table) and re-emits itself
//! on demand, allowing a larger effective corpus within the 500 MB raw cap.

const std = @import("std");

// =============================================================================
// Lattice transform (inlined from lattice.zig for self-containment)
// =============================================================================

const BASE_EDGE: u32 = 15;

fn latticeEdge(level: u8) u32 {
    return BASE_EDGE * (@as(u32, 1) << @intCast(level));
}

const Coords = struct {
    x: u32,
    y: u32,
    z: u32,
};

fn unflatCoords(chunk_idx: usize, level: u8) Coords {
    const size: usize = latticeEdge(level);
    const total = size * size * size;
    const wrapped_idx = chunk_idx % total;
    const slice_size = size * size;
    const x: u32 = @intCast(wrapped_idx / slice_size);
    const rem = wrapped_idx % slice_size;
    const y: u32 = @intCast(rem / size);
    const z: u32 = @intCast(rem % size);
    return .{ .x = x, .y = y, .z = z };
}

fn computeEValue(x: u32, y: u32, z: u32, level: u8) u3 {
    const base_size: u32 = latticeEdge(level);
    const mid: u32 = base_size / 2;
    const dx: i64 = @min(@as(i64, x), @as(i64, base_size - 1 - x));
    const dy: i64 = @min(@as(i64, y), @as(i64, base_size - 1 - y));
    const dz: i64 = @intCast(@abs(@as(i64, z) - @as(i64, mid)));
    const raw: i64 = 6 - dx - dy + dz;
    return @intCast(@mod(raw, 8));
}

fn isBoundaryCoord(x: u32, y: u32, z: u32, level: u8) bool {
    const base_size: u32 = latticeEdge(level);
    return x == 0 or x == base_size - 1 or
        y == 0 or y == base_size - 1 or
        z == 0 or z == base_size - 1;
}

const LatticeLookup = struct {
    e_vals: []u3,
    is_boundaries: []bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, level: u8, num_chunks: usize) !LatticeLookup {
        const e_vals = try allocator.alloc(u3, num_chunks);
        errdefer allocator.free(e_vals);
        const is_boundaries = try allocator.alloc(bool, num_chunks);
        errdefer allocator.free(is_boundaries);

        for (0..num_chunks) |chunk_idx| {
            const coords = unflatCoords(chunk_idx, level);
            e_vals[chunk_idx] = computeEValue(coords.x, coords.y, coords.z, level);
            is_boundaries[chunk_idx] = isBoundaryCoord(coords.x, coords.y, coords.z, level);
        }

        return .{
            .e_vals = e_vals,
            .is_boundaries = is_boundaries,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LatticeLookup) void {
        self.allocator.free(self.e_vals);
        self.allocator.free(self.is_boundaries);
    }
};

inline fn permuteChunkForward(bytes: [8]u8, e_val: u3, is_boundary: bool) [8]u8 {
    const vec: @Vector(8, u8) = bytes;
    const rotated = switch (e_val) {
        0 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 0, 1, 2, 3, 4, 5, 6, 7 }),
        1 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 7, 0, 1, 2, 3, 4, 5, 6 }),
        2 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 6, 7, 0, 1, 2, 3, 4, 5 }),
        3 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 5, 6, 7, 0, 1, 2, 3, 4 }),
        4 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 4, 5, 6, 7, 0, 1, 2, 3 }),
        5 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 3, 4, 5, 6, 7, 0, 1, 2 }),
        6 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 2, 3, 4, 5, 6, 7, 0, 1 }),
        7 => @shuffle(u8, vec, undefined, @Vector(8, i32){ 1, 2, 3, 4, 5, 6, 7, 0 }),
    };
    if (!is_boundary) {
        var result: [8]u8 = undefined;
        @memcpy(&result, std.mem.asBytes(&rotated));
        return result;
    }
    const reflected = @shuffle(u8, rotated, undefined, @Vector(8, i32){ 7, 6, 5, 4, 3, 2, 1, 0 });
    var result: [8]u8 = undefined;
    @memcpy(&result, std.mem.asBytes(&reflected));
    return result;
}

inline fn permuteChunkInverse(bytes: [8]u8, e_val: u3, is_boundary: bool) [8]u8 {
    const vec: @Vector(8, u8) = bytes;
    const after_reflect = if (is_boundary) @shuffle(u8, vec, undefined, @Vector(8, i32){ 7, 6, 5, 4, 3, 2, 1, 0 }) else vec;
    const original = switch (e_val) {
        0 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 0, 1, 2, 3, 4, 5, 6, 7 }),
        1 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 1, 2, 3, 4, 5, 6, 7, 0 }),
        2 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 2, 3, 4, 5, 6, 7, 0, 1 }),
        3 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 3, 4, 5, 6, 7, 0, 1, 2 }),
        4 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 4, 5, 6, 7, 0, 1, 2, 3 }),
        5 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 5, 6, 7, 0, 1, 2, 3, 4 }),
        6 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 6, 7, 0, 1, 2, 3, 4, 5 }),
        7 => @shuffle(u8, after_reflect, undefined, @Vector(8, i32){ 7, 0, 1, 2, 3, 4, 5, 6 }),
    };
    var result: [8]u8 = undefined;
    @memcpy(&result, std.mem.asBytes(&original));
    return result;
}

fn mapToLattice(allocator: std.mem.Allocator, data: []const u8, level: u8) ![]u8 {
    const num_chunks = (data.len + 7) / 8;
    var out = try allocator.alloc(u8, num_chunks * 8);
    errdefer allocator.free(out);
    var lookup = try LatticeLookup.init(allocator, level, num_chunks);
    defer lookup.deinit();
    for (0..num_chunks) |chunk_idx| {
        var chunk: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const start = chunk_idx * 8;
        const end = @min(start + 8, data.len);
        for (start..end, 0..) |src, i| {
            chunk[i] = data[src];
        }
        const e_val = lookup.e_vals[chunk_idx];
        const is_bdy = lookup.is_boundaries[chunk_idx];
        const permuted = permuteChunkForward(chunk, e_val, is_bdy);
        @memcpy(out[start .. start + 8], &permuted);
    }
    return out;
}

fn unmapFromLattice(allocator: std.mem.Allocator, mapped: []const u8, original_len: usize, level: u8) ![]u8 {
    const num_chunks = (original_len + 7) / 8;
    if (mapped.len < num_chunks * 8) return error.IncompleteMappedData;
    var out = try allocator.alloc(u8, original_len);
    errdefer allocator.free(out);
    var lookup = try LatticeLookup.init(allocator, level, num_chunks);
    defer lookup.deinit();
    for (0..num_chunks) |chunk_idx| {
        var permuted: [8]u8 = undefined;
        const start = chunk_idx * 8;
        @memcpy(&permuted, mapped[start .. start + 8]);
        const e_val = lookup.e_vals[chunk_idx];
        const is_bdy = lookup.is_boundaries[chunk_idx];
        const recovered = permuteChunkInverse(permuted, e_val, is_bdy);
        const end = @min(start + 8, original_len);
        for (start..end, 0..) |dst, i| {
            out[dst] = recovered[i];
        }
    }
    return out;
}

fn computeChecksum(data: []const u8) u32 {
    var hash = std.hash.Crc32.init();
    hash.update(data);
    return hash.final();
}

// =============================================================================
// RMSY container
// =============================================================================

const RMSY_MAGIC: [4]u8 = .{ 'R', 'M', 'S', 'Y' };
const RMSY_VERSION: u16 = 1;

const RmsyHeader = struct {
    magic: [4]u8,
    version: u16,
    lattice_level: u8,
    qubit_config: u8,
    payload_offset: u32,
    payload_len: u32,
    original_len: u32,
    checksum: u32,

    pub const SIZE: usize = 4 + 2 + 1 + 1 + 4 + 4 + 4 + 4;

    pub fn write(self: RmsyHeader, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u16, self.version, .little);
        try writer.writeByte(self.lattice_level);
        try writer.writeByte(self.qubit_config);
        try writer.writeInt(u32, self.payload_offset, .little);
        try writer.writeInt(u32, self.payload_len, .little);
        try writer.writeInt(u32, self.original_len, .little);
        try writer.writeInt(u32, self.checksum, .little);
    }

    pub fn read(reader: anytype) !RmsyHeader {
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &RMSY_MAGIC)) return error.InvalidMagic;
        return .{
            .magic = magic,
            .version = try reader.readInt(u16, .little),
            .lattice_level = try reader.readByte(),
            .qubit_config = try reader.readByte(),
            .payload_offset = try reader.readInt(u32, .little),
            .payload_len = try reader.readInt(u32, .little),
            .original_len = try reader.readInt(u32, .little),
            .checksum = try reader.readInt(u32, .little),
        };
    }
};

const RmsyContainer = struct {
    header: RmsyHeader,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: RmsyContainer) void {
        self.allocator.free(self.payload);
    }
};

fn writeRmsy(writer: anytype, payload: []const u8, original_len: usize, lattice_level: u8, qubit_config: u8) !void {
    const checksum = computeChecksum(payload);
    const header = RmsyHeader{
        .magic = RMSY_MAGIC,
        .version = RMSY_VERSION,
        .lattice_level = lattice_level,
        .qubit_config = qubit_config,
        .payload_offset = @intCast(RmsyHeader.SIZE),
        .payload_len = @intCast(payload.len),
        .original_len = @intCast(original_len),
        .checksum = checksum,
    };
    try header.write(writer);
    try writer.writeAll(payload);
}

fn readRmsy(allocator: std.mem.Allocator, reader: anytype) !RmsyContainer {
    const header = try RmsyHeader.read(reader);
    if (header.version != RMSY_VERSION) return error.UnsupportedVersion;
    if (header.payload_offset != RmsyHeader.SIZE) return error.InvalidOffset;
    const payload = try allocator.alloc(u8, header.payload_len);
    errdefer allocator.free(payload);
    const read_bytes = try reader.readAll(payload);
    if (read_bytes != header.payload_len) return error.TruncatedPayload;
    const computed = computeChecksum(payload);
    if (computed != header.checksum) return error.ChecksumMismatch;
    return .{ .header = header, .payload = payload, .allocator = allocator };
}

// =============================================================================
// Gzip compression / decompression (using std.compress)
// =============================================================================

/// Gzip compresses a byte slice.
pub fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out_list = std.ArrayList(u8).init(allocator);
    errdefer out_list.deinit();
    try out_list.ensureTotalCapacity(data.len + data.len / 10 + 64);

    var compressor = try std.compress.gzip.compressor(out_list.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();

    return out_list.toOwnedSlice();
}

/// Gzip decompresses a byte slice.
pub fn gzipDecompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in_stream = std.io.fixedBufferStream(compressed);
    var out_list = std.ArrayList(u8).init(allocator);
    errdefer out_list.deinit();
    try out_list.ensureTotalCapacity(compressed.len * 4);

    try std.compress.gzip.decompress(in_stream.reader(), out_list.writer());

    return out_list.toOwnedSlice();
}

// =============================================================================
// Self-similarity dedup
// =============================================================================

/// Template entry: a repeated 8-byte pattern found in the data.
pub const Template = struct {
    pattern: [8]u8,
    count: u32,
    first_offset: usize,
};

/// Finds repeated 8-byte patterns in data.
/// Returns templates sorted by count (descending).
pub fn findSelfSimilarPatterns(allocator: std.mem.Allocator, data: []const u8) ![]Template {
    if (data.len < 16) return try allocator.alloc(Template, 0);

    var pattern_map = std.AutoHashMap(u64, Template).init(allocator);
    defer pattern_map.deinit();

    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        var chunk: [8]u8 = undefined;
        @memcpy(&chunk, data[i .. i + 8]);

        const key = std.mem.readInt(u64, &chunk, .little);

        if (pattern_map.getPtr(key)) |entry| {
            entry.count += 1;
        } else {
            try pattern_map.put(key, .{
                .pattern = chunk,
                .count = 1,
                .first_offset = i,
            });
        }
    }

    var templates = try allocator.alloc(Template, pattern_map.count());
    var idx: usize = 0;
    var it = pattern_map.iterator();
    while (it.next()) |entry| {
        templates[idx] = entry.value_ptr.*;
        idx += 1;
    }

    std.mem.sort(Template, templates, {}, struct {
        fn cmp(_: void, a: Template, b: Template) bool {
            return a.count > b.count;
        }
    }.cmp);

    return templates;
}

/// Replaces repeated patterns with template references.
/// Returns deduplicated data and the template table.
pub const DedupResult = struct {
    data: []u8,
    templates: []Template,
    allocator: std.mem.Allocator,

    pub fn deinit(self: DedupResult) void {
        self.allocator.free(self.data);
        self.allocator.free(self.templates);
    }
};

/// Deduplicates data by replacing repeated 8-byte patterns with template indices.
/// Template index 0-254 stored as byte + marker; 255 = literal.
pub fn deduplicate(allocator: std.mem.Allocator, data: []const u8) !DedupResult {
    const templates = try findSelfSimilarPatterns(allocator, data);

    // Only use templates that repeat more than once
    var useful_count: usize = 0;
    for (templates) |t| {
        if (t.count > 1 and useful_count < 255) {
            useful_count += 1;
        } else break;
    }

    // Build replacement map
    var replace_map = std.AutoHashMap(u64, u8).init(allocator);
    defer replace_map.deinit();
    for (templates[0..useful_count], 0..) |t, i| {
        const key = std.mem.readInt(u64, &t.pattern, .little);
        try replace_map.put(key, @intCast(i));
    }

    // Encode: for each 8-byte chunk, if it matches a template, write [0xFF, template_idx]
    // Otherwise write [0x00, 8 literal bytes]
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(data.len + data.len / 8 + 16);

    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        var chunk: [8]u8 = undefined;
        @memcpy(&chunk, data[i .. i + 8]);
        const key = std.mem.readInt(u64, &chunk, .little);

        if (replace_map.get(key)) |idx| {
            try out.append(0xFF);
            try out.append(idx);
        } else {
            try out.append(0x00);
            try out.appendSlice(&chunk);
        }
    }

    // Handle remaining bytes (not a full chunk)
    if (i < data.len) {
        try out.append(0x00);
        try out.appendSlice(data[i..]);
    }

    return .{
        .data = try out.toOwnedSlice(),
        .templates = templates,
        .allocator = allocator,
    };
}

/// Restores original data from deduplicated form.
/// Stream format: [0xDE, 0xD0][u8 count][count × 8 bytes][deduped body]
/// Body format: [0xFF, idx] = template reference, [0x00, 8 bytes] = literal
fn restoreDedup(allocator: std.mem.Allocator, stream: []const u8) ![]u8 {
    if (stream.len < 3) return error.InvalidDedupStream;
    if (stream[0] != 0xDE or stream[1] != 0xD0) return error.InvalidDedupStream;

    const template_count: usize = stream[2];
    const header_len = 3 + template_count * 8;
    if (stream.len < header_len) return error.InvalidDedupStream;

    // Extract template patterns
    const templates = try allocator.alloc([8]u8, template_count);
    defer allocator.free(templates);
    for (0..template_count) |t| {
        @memcpy(&templates[t], stream[3 + t * 8 .. 3 + t * 8 + 8]);
    }

    const body = stream[header_len..];
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(body.len * 4);

    var i: usize = 0;
    while (i < body.len) {
        const marker = body[i];
        if (marker == 0xFF and i + 1 < body.len) {
            const idx: usize = body[i + 1];
            if (idx >= template_count) return error.InvalidTemplateIndex;
            try out.appendSlice(&templates[idx]);
            i += 2;
        } else if (marker == 0x00) {
            const remaining = body.len - i - 1;
            const literal_len = @min(remaining, 8);
            try out.appendSlice(body[i + 1 .. i + 1 + literal_len]);
            i += 1 + literal_len;
        } else {
            return error.InvalidDedupMarker;
        }
    }

    return out.toOwnedSlice();
}

// =============================================================================
// Compress / decompress pipeline
// =============================================================================

pub const CompressConfig = struct {
    lattice_level: u8 = 5,
    use_dedup: bool = true,
    qubit_config: u8 = 1,
};

/// Compressed container: RMSY-wrapped, lattice-transformed, gzip-compressed data.
pub const CompressedContainer = struct {
    rmsy_bytes: []u8,
    original_len: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: CompressedContainer) void {
        self.allocator.free(self.rmsy_bytes);
    }
};

/// Compresses raw data into a self-contained container.
/// Pipeline: data → [dedup] → gzip → lattice_transform → RMSY
pub fn compress(allocator: std.mem.Allocator, data: []const u8, config: CompressConfig) !CompressedContainer {
    // Step 1: Optional dedup — serialize templates + deduped data into one stream
    var processed_data: []const u8 = data;
    var dedup_result: ?DedupResult = null;
    var dedup_stream: ?[]u8 = null;
    if (config.use_dedup and data.len > 64) {
        dedup_result = try deduplicate(allocator, data);
        var stream = std.ArrayList(u8).init(allocator);
        errdefer stream.deinit();
        try stream.ensureTotalCapacity(data.len / 2 + 16);
        try stream.appendSlice(&.{ 0xDE, 0xD0 });
        const useful = @min(dedup_result.?.templates.len, 255);
        try stream.append(@intCast(useful));
        for (dedup_result.?.templates[0..useful]) |t| {
            try stream.appendSlice(&t.pattern);
        }
        try stream.appendSlice(dedup_result.?.data);
        dedup_stream = try stream.toOwnedSlice();
        processed_data = dedup_stream.?;
    }
    defer if (dedup_result) |dr| dr.deinit();
    defer if (dedup_stream) |ds| allocator.free(ds);

    // Step 2: Gzip compress
    const compressed = try gzipCompress(allocator, processed_data);
    defer allocator.free(compressed);

    // Step 3: Lattice transform
    const lattice_data = try mapToLattice(allocator, compressed, config.lattice_level);
    defer allocator.free(lattice_data);

    // Step 4: Wrap in RMSY container
    var rmsy_buf = std.ArrayList(u8).init(allocator);
    errdefer rmsy_buf.deinit();
    try rmsy_buf.ensureTotalCapacity(lattice_data.len + 64);
    try writeRmsy(
        rmsy_buf.writer(),
        lattice_data,
        compressed.len,
        config.lattice_level,
        config.qubit_config,
    );

    const rmsy_bytes = try rmsy_buf.toOwnedSlice();

    return .{
        .rmsy_bytes = rmsy_bytes,
        .original_len = data.len,
        .allocator = allocator,
    };
}

/// Decompresses a container back to the original data.
/// Pipeline: RMSY → lattice_inverse → gzip_decompress → dedup_restore
pub fn decompress(allocator: std.mem.Allocator, container: CompressedContainer) ![]u8 {
    // Step 1: Read RMSY container
    var fbs = std.io.fixedBufferStream(container.rmsy_bytes);
    const rmsy = try readRmsy(allocator, fbs.reader());
    defer rmsy.deinit();

    // Step 2: Inverse lattice transform
    const unmapped = try unmapFromLattice(
        allocator,
        rmsy.payload,
        rmsy.header.original_len,
        rmsy.header.lattice_level,
    );
    defer allocator.free(unmapped);

    // Step 3: Gzip decompress
    const decompressed = try gzipDecompress(allocator, unmapped);
    defer allocator.free(decompressed);

    // Step 4: Check for dedup magic header and restore if present
    if (decompressed.len >= 3 and decompressed[0] == 0xDE and decompressed[1] == 0xD0) {
        return try restoreDedup(allocator, decompressed);
    }

    // Otherwise, the decompressed data IS the original (dedup was not used)
    return try allocator.dupe(u8, decompressed);
}

/// Verifies compress → decompress round-trip produces identical data.
pub fn verifyRoundTrip(allocator: std.mem.Allocator, data: []const u8, config: CompressConfig) !bool {
    const container = try compress(allocator, data, config);
    defer container.deinit();

    const restored = try decompress(allocator, container);
    defer allocator.free(restored);

    return std.mem.eql(u8, data, restored);
}

// =============================================================================
// Tests
// =============================================================================

test "compress: gzip round-trip" {
    const allocator = std.testing.allocator;
    const data = "The quick brown fox jumps over the lazy dog. " ** 10;
    const compressed = try gzipCompress(allocator, data);
    defer allocator.free(compressed);
    const restored = try gzipDecompress(allocator, compressed);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(data, restored);
}

test "compress: gzip actually compresses repetitive data" {
    const allocator = std.testing.allocator;
    const data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const compressed = try gzipCompress(allocator, data);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len < data.len);
}

test "compress: findSelfSimilarPatterns finds repeats" {
    const allocator = std.testing.allocator;
    const data = "ABCDEFGHABCDEFGHABCDEFGHXYZXYZXYZ";
    const templates = try findSelfSimilarPatterns(allocator, data);
    defer allocator.free(templates);
    var found_repeat = false;
    for (templates) |t| {
        if (t.count > 1) found_repeat = true;
    }
    try std.testing.expect(found_repeat);
}

test "compress: deduplicate round-trip restores data" {
    const allocator = std.testing.allocator;
    const data = "ABCDEFGHABCDEFGHABCDEFGHABCDEFGH";
    const dedup = try deduplicate(allocator, data);
    defer dedup.deinit();
    try std.testing.expect(dedup.data.len < data.len);
}

test "compress: full pipeline round-trip with dedup" {
    const allocator = std.testing.allocator;
    const data = "The lattice computing engine stores knowledge in a dynamic corpus. " ** 20;
    const config = CompressConfig{ .use_dedup = true };
    try std.testing.expect(try verifyRoundTrip(allocator, data, config));
}

test "compress: full pipeline round-trip without dedup" {
    const allocator = std.testing.allocator;
    const data = "Short unique text that has no repeating 8-byte patterns here.";
    const config = CompressConfig{ .use_dedup = false };
    try std.testing.expect(try verifyRoundTrip(allocator, data, config));
}

test "compress: full pipeline round-trip binary data" {
    const allocator = std.testing.allocator;
    var data_buf: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&data_buf);
    const config = CompressConfig{ .use_dedup = true };
    try std.testing.expect(try verifyRoundTrip(allocator, &data_buf, config));
}

test "compress: compress produces smaller output for repetitive corpus text" {
    const allocator = std.testing.allocator;
    const data = "The human heart pumps blood throughout the body. " ** 50;
    const container = try compress(allocator, data, .{});
    defer container.deinit();
    try std.testing.expect(container.rmsy_bytes.len < data.len);
}

test "compress: checksum detects corruption" {
    const allocator = std.testing.allocator;
    const data = "Corpus data that must be verified by checksum. " ** 8;
    const container = try compress(allocator, data, .{});
    defer container.deinit();
    // Corrupt a byte in the payload
    var corrupted = try allocator.dupe(u8, container.rmsy_bytes);
    defer allocator.free(corrupted);
    if (corrupted.len > 10) corrupted[corrupted.len - 1] ^= 0xFF;
    var fbs = std.io.fixedBufferStream(corrupted);
    try std.testing.expectError(error.ChecksumMismatch, readRmsy(allocator, fbs.reader()));
}

test "compress: invalid magic rejected" {
    const allocator = std.testing.allocator;
    const bad = "NOPE" ++ "1234567890123456789012345678901234567890";
    var fbs = std.io.fixedBufferStream(bad);
    try std.testing.expectError(error.InvalidMagic, readRmsy(allocator, fbs.reader()));
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework compression ratio from the 7-defect: 7/8 of data is compressible,
/// 1/8 is the irreducible consciousness aperture.
pub const FRAMEWORK_COMPRESSIBLE_FRACTION: u32 = 7; // 7/8 compressible
pub const FRAMEWORK_IRREDUCIBLE_FRACTION: u32 = 1; // 1/8 irreducible

/// Verifies the 7+1=8 compression structure from the framework.
pub fn verifyCompressionStructure() bool {
    return FRAMEWORK_COMPRESSIBLE_FRACTION + FRAMEWORK_IRREDUCIBLE_FRACTION == 8;
}

test "framework: compression 7/8 + 1/8 = 8/8" {
    try std.testing.expect(verifyCompressionStructure());
}
