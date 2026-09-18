//! safetensors.zig — SafeTensors container parser with integer-exact decode.
//!
//! Reads the SafeTensors format (HF safetensors): 8-byte LE header length,
//! JSON header {name: {dtype, shape, data_offsets}}, then raw tensor data.
//! Tensors are accessed as bounded windows via positioned reads — the caller
//! never materializes a multi-GB tensor in memory.
//!
//! Decode path is integer-only: bf16/f16/f32 bits are converted to Q64.64
//! (i128) with no floating-point arithmetic in the core path.
//!
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

pub const MAX_HEADER_BYTES: usize = 64 * 1024 * 1024; // 64MB JSON header cap
pub const WINDOW_ELEMS: usize = 1 << 20; // 1M elements per read window

pub const Dtype = enum {
    bf16,
    f16,
    f32,
    f64,
    i64_,
    i32_,
    u8_,
    bool_,

    pub fn size(self: Dtype) usize {
        return switch (self) {
            .bf16, .f16 => 2,
            .f32, .i32_ => 4,
            .f64, .i64_ => 8,
            .u8_, .bool_ => 1,
        };
    }
};

pub const TensorInfo = struct {
    name: []const u8,
    dtype: Dtype,
    shape: []u64,
    /// Byte offset into the file's data section (after the header).
    data_offset: u64,
    data_len: u64,

    /// Element count = product of shape dims.
    pub fn elements(self: TensorInfo) u64 {
        var n: u64 = 1;
        for (self.shape) |d| n *= d;
        return n;
    }
};

pub const SafeTensors = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    tensors: []TensorInfo,
    /// Absolute file offset where tensor data begins.
    data_start: u64,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SafeTensors {
        var file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        var len_buf: [8]u8 = undefined;
        if (try file.readAll(&len_buf) != 8) return error.BadHeader;
        const header_len = std.mem.readInt(u64, &len_buf, .little);
        if (header_len == 0 or header_len > MAX_HEADER_BYTES) return error.BadHeader;

        const header = try allocator.alloc(u8, @intCast(header_len));
        defer allocator.free(header);
        _ = try file.readAll(header);

        const tensors = try parseHeader(allocator, header);
        errdefer {
            for (tensors) |t| {
                allocator.free(t.name);
                allocator.free(t.shape);
            }
            allocator.free(tensors);
        }

        return .{
            .allocator = allocator,
            .file = file,
            .tensors = tensors,
            .data_start = 8 + header_len,
        };
    }

    pub fn close(self: *SafeTensors) void {
        for (self.tensors) |t| {
            self.allocator.free(t.name);
            self.allocator.free(t.shape);
        }
        self.allocator.free(self.tensors);
        self.file.close();
    }

    pub fn tensorCount(self: SafeTensors) usize {
        return self.tensors.len;
    }

    pub fn find(self: SafeTensors, name: []const u8) ?TensorInfo {
        for (self.tensors) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// Total parameter count across all tensors.
    pub fn totalParams(self: SafeTensors) u64 {
        var n: u64 = 0;
        for (self.tensors) |t| n += t.elements();
        return n;
    }

    /// Reads up to `out.len` elements starting at element `elem_offset` of
    /// `tensor`, decoded to Q64.64. Returns the number of elements decoded.
    /// Bounded window — never allocates.
    pub fn readWindow(
        self: *const SafeTensors,
        tensor: TensorInfo,
        elem_offset: u64,
        out: []i128,
    ) !usize {
        const elem_size = tensor.dtype.size();
        const avail = tensor.elements() -| elem_offset;
        const n = @min(avail, out.len);
        if (n == 0) return 0;

        const byte_off = self.data_start + tensor.data_offset + elem_offset * elem_size;
        const byte_len = n * elem_size;
        const buf = try self.allocator.alloc(u8, @intCast(byte_len));
        defer self.allocator.free(buf);

        try self.file.seekTo(byte_off);
        const got = try self.file.readAll(buf);
        if (got != buf.len) return error.ShortRead;

        for (0..@intCast(n)) |i| {
            out[i] = decodeElem(tensor.dtype, buf[i * elem_size .. (i + 1) * elem_size]);
        }
        return @intCast(n);
    }
};

/// Decodes one element to Q64.64 (i128). Integer-only.
pub fn decodeElem(dtype: Dtype, bytes: []const u8) i128 {
    return switch (dtype) {
        .bf16 => decodeBf16(std.mem.readInt(u16, bytes[0..2], .little)),
        .f16 => decodeF16(std.mem.readInt(u16, bytes[0..2], .little)),
        .f32 => decodeF32Bits(std.mem.readInt(u32, bytes[0..4], .little)),
        .f64 => fp.fromInt(@intFromFloat(@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little))))),
        .i64_ => fp.fromInt(std.mem.readInt(i64, bytes[0..8], .little)),
        .i32_ => fp.fromInt(std.mem.readInt(i32, bytes[0..4], .little)),
        .u8_ => fp.fromInt(bytes[0]),
        .bool_ => if (bytes[0] != 0) fp.ONE else 0,
    };
}

/// bf16 → Q64.64, integer-only. bf16 = sign(1)|exp(8)|mantissa(7).
/// value = ±(1 + m/128)·2^(e-127) = ±(128+m)·2^(e-134); in Q64.64 that's
/// ±(128+m)·2^(e-134+64) = ±(128+m)·2^(e-70).
pub fn decodeBf16(bits: u16) i128 {
    const sign: i128 = if (bits & 0x8000 != 0) -1 else 1;
    const exp_field = (bits >> 7) & 0xFF;
    const mant: i128 = bits & 0x7F;
    if (exp_field == 0) {
        // Subnormal: ±m·2^-133 — far below Q64.64 resolution, treat as 0.
        return 0;
    }
    if (exp_field == 0xFF) return if (sign > 0) fp.MAX_VAL else fp.MIN_VAL;
    const shift: i32 = @as(i32, @intCast(exp_field)) - 70;
    return scaleMantissa(sign, 128 + mant, shift);
}

/// f16 → Q64.64. f16 = sign(1)|exp(5)|mantissa(10); bias 15.
/// value = ±(1 + m/1024)·2^(e-15) = ±(1024+m)·2^(e-15-10+64) = ±(1024+m)·2^(e+39).
pub fn decodeF16(bits: u16) i128 {
    const sign: i128 = if (bits & 0x8000 != 0) -1 else 1;
    const exp_field = (bits >> 10) & 0x1F;
    const mant: i128 = bits & 0x3FF;
    if (exp_field == 0) return 0;
    if (exp_field == 0x1F) return if (sign > 0) fp.MAX_VAL else fp.MIN_VAL;
    const shift: i32 = @as(i32, @intCast(exp_field)) + 39;
    return scaleMantissa(sign, 1024 + mant, shift);
}

/// f32 bits → Q64.64. f32 = sign(1)|exp(8)|mantissa(23); bias 127.
/// value = ±(1 + m/2^23)·2^(e-127) = ±(2^23+m)·2^(e-127-23+64) = ±(2^23+m)·2^(e-86).
pub fn decodeF32Bits(bits: u32) i128 {
    const sign: i128 = if (bits & 0x8000_0000 != 0) -1 else 1;
    const exp_field = (bits >> 23) & 0xFF;
    const mant: i128 = bits & 0x7F_FFFF;
    if (exp_field == 0) return 0;
    if (exp_field == 0xFF) return if (sign > 0) fp.MAX_VAL else fp.MIN_VAL;
    const shift: i32 = @as(i32, @intCast(exp_field)) - 86;
    return scaleMantissa(sign, 0x80_0000 + mant, shift);
}

fn scaleMantissa(sign: i128, mant_plus: i128, shift: i32) i128 {
    if (shift >= 0) {
        if (shift > 60) return if (sign > 0) fp.MAX_VAL else fp.MIN_VAL; // saturate
        const v = mant_plus << @intCast(shift);
        return if (v > fp.MAX_VAL) sign * fp.MAX_VAL else sign * v;
    }
    const rs: u6 = @intCast(@min(-shift, 127));
    if (rs > 120) return 0;
    return sign * (mant_plus >> rs);
}

// =============================================================================
// Header parsing
// =============================================================================

fn parseHeader(allocator: std.mem.Allocator, json_bytes: []const u8) ![]TensorInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadHeader;

    var list = std.ArrayList(TensorInfo).init(allocator);
    errdefer list.deinit();

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "__metadata__")) continue;
        const obj = entry.value_ptr.*;
        if (obj != .object) return error.BadHeader;

        const dtype_str = obj.object.get("dtype") orelse return error.BadHeader;
        const shape_arr = obj.object.get("shape") orelse return error.BadHeader;
        const offsets = obj.object.get("data_offsets") orelse return error.BadHeader;
        if (dtype_str != .string or shape_arr != .array or offsets != .array) return error.BadHeader;
        if (offsets.array.items.len != 2) return error.BadHeader;

        const shape = try allocator.alloc(u64, shape_arr.array.items.len);
        errdefer allocator.free(shape);
        for (shape_arr.array.items, 0..) |dim, i| {
            if (dim != .integer) return error.BadHeader;
            shape[i] = @intCast(dim.integer);
        }

        try list.append(.{
            .name = try allocator.dupe(u8, name),
            .dtype = parseDtype(dtype_str.string) orelse return error.UnsupportedDtype,
            .shape = shape,
            .data_offset = @intCast(offsets.array.items[0].integer),
            .data_len = @intCast(offsets.array.items[1].integer - offsets.array.items[0].integer),
        });
    }
    return try list.toOwnedSlice();
}

fn parseDtype(s: []const u8) ?Dtype {
    const map = std.StaticStringMap(Dtype).initComptime(.{
        .{ "BF16", .bf16 }, .{ "F16", .f16 },  .{ "F32", .f32 }, .{ "F64", .f64 },
        .{ "I64", .i64_ },  .{ "I32", .i32_ }, .{ "U8", .u8_ },  .{ "BOOL", .bool_ },
    });
    return map.get(s);
}

// =============================================================================
// Tests
// =============================================================================

test "decodeBf16: exact powers and fractions" {
    // bf16 0x3F80 = 1.0
    try std.testing.expect(decodeBf16(0x3F80) == fp.ONE);
    // bf16 0x4000 = 2.0
    try std.testing.expect(decodeBf16(0x4000) == fp.fromInt(2));
    // bf16 0xBF80 = -1.0
    try std.testing.expect(decodeBf16(0xBF80) == -fp.ONE);
    // bf16 0x3F00 = 0.5
    try std.testing.expect(decodeBf16(0x3F00) == fp.HALF);
    // bf16 0x4049 = ~3.1406 (pi truncated)
    try std.testing.expect(decodeBf16(0x4049) == fp.fromRatio(201, 64));
}

test "decodeF16: 1.0 and -2.5" {
    try std.testing.expect(decodeF16(0x3C00) == fp.ONE); // 1.0
    try std.testing.expect(decodeF16(0xC100) == -fp.fromRatio(5, 2)); // -2.5
}

test "decodeF32Bits: 1.0" {
    try std.testing.expect(decodeF32Bits(0x3F80_0000) == fp.ONE);
    try std.testing.expect(decodeF32Bits(0xC000_0000) == -fp.fromInt(2));
}

test "SafeTensors: round-trip write/parse" {
    const alloc = std.testing.allocator;
    const path = "/tmp/test_st.safetensors";
    defer std.fs.cwd().deleteFile(path) catch {};

    // Write a minimal safetensors file: 2 bf16 tensors.
    const header =
        \\{"w1":{"dtype":"BF16","shape":[2],"data_offsets":[0,4]},"w2":{"dtype":"BF16","shape":[2,2],"data_offsets":[4,12]}}
    ;
    var f = try std.fs.cwd().createFile(path, .{});
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, header.len, .little);
    try f.writeAll(&len_buf);
    try f.writeAll(header);
    // w1: 1.0, 2.0 ; w2: 0.5, -1.0, 4.0, 8.0
    const data = [_]u8{
        0x80, 0x3F, 0x00, 0x40, // w1: 1.0, 2.0
        0x00, 0x3F, 0x80, 0xBF, 0x80, 0x40, 0x00, 0x41, // w2: 0.5, -1.0, 4.0, 8.0
    };
    try f.writeAll(&data);
    f.close();

    var st = try SafeTensors.open(alloc, path);
    defer st.close();
    try std.testing.expect(st.tensorCount() == 2);
    try std.testing.expect(st.totalParams() == 6);

    const w1 = st.find("w1").?;
    try std.testing.expect(w1.elements() == 2);
    var buf: [4]i128 = undefined;
    const n = try st.readWindow(w1, 0, &buf);
    try std.testing.expect(n == 2);
    try std.testing.expect(buf[0] == fp.ONE and buf[1] == fp.fromInt(2));

    const w2 = st.find("w2").?;
    try std.testing.expect(w2.shape.len == 2);
    const n2 = try st.readWindow(w2, 1, buf[0..3]);
    try std.testing.expect(n2 == 3);
    try std.testing.expect(buf[0] == -fp.ONE and buf[2] == fp.fromInt(8));
}
