//! holo_codec.zig — Holographic compression codec (N³→16³ fold/unfold).
//!
//! Ports the Q128.128 (FANO-1) project's holo.zig into qstar-llm.
//! Folds an N³ complex grid (i128 re/im pairs in Q64.64) onto a 16³ core
//! plus a per-cell e9 winding field organized in scale levels
//! (16³ → 32³ → ... → 512³). Family states (FANO-1-representable:
//! every non-core cell is an exact pivot quarter-turn of its even-floor
//! neighbor) reconstruct bit-exactly from (core, windings) — the Module 3
//! bijection — approaching the 32,908:1 node ratio. Arbitrary grids fall
//! back to residual mode with graceful degradation. The odd-perimeter
//! defect charge (Module 4) anchors the holographic index.
//!
//! Reconstruction is O(1) per cell: each level fills its new cells from
//! the previous level with one lookup plus at most one exact quarter-turn
//! (rot90: negation and swap only). Partial unfold at level L yields the
//! (16*2^L)³ grid without touching higher levels.
//!
//! Adapted from Q128.128's Q128.128 complex values to Qstar's i128 Q64.64.
//!
//! Ported from: Q128.128/zig/holo.zig
//! License: CC BY-NC-SA 4.0

const std = @import("std");

pub const CORE_SIDE: u32 = 16;
pub const CORE_CELLS: u32 = CORE_SIDE * CORE_SIDE * CORE_SIDE;
pub const MAX_LEVELS: u5 = 6; // core 16 -> 512

// =============================================================================
// Complex Value (i128 re/im in Q64.64)
// =============================================================================

/// Complex Q64.64 value (32 bytes: two i128).
pub const Cx = struct {
    re: i128,
    im: i128,

    pub fn eq(a: Cx, b: Cx) bool {
        return a.re == b.re and a.im == b.im;
    }
};

/// Exact quarter-turn (pivot rotation): (re, im) -> (-im, re).
/// This is an exact operation — only negation and swap, no arithmetic.
pub fn rot90(v: Cx) Cx {
    return .{ .re = -v.im, .im = v.re };
}

/// Apply rot90 w times (w mod 4).
pub fn rotPow(v: Cx, w: u8) Cx {
    var r = v;
    var k: u32 = 0;
    while (k < (w & 3)) : (k += 1) r = rot90(r);
    return r;
}

// =============================================================================
// Grid
// =============================================================================

pub const Grid = struct {
    n: u32,
    data: []Cx,

    pub fn init(alloc: std.mem.Allocator, n: u32) !Grid {
        const data = try alloc.alloc(Cx, @as(usize, n) * n * n);
        return .{ .n = n, .data = data };
    }

    pub fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.data = &.{};
    }

    pub inline fn idx(self: *const Grid, x: u32, y: u32, z: u32) usize {
        return @as(usize, x) + @as(usize, y) * self.n + @as(usize, z) * self.n * self.n;
    }

    pub inline fn get(self: *const Grid, x: u32, y: u32, z: u32) Cx {
        return self.data[self.idx(x, y, z)];
    }

    pub inline fn set(self: *Grid, x: u32, y: u32, z: u32, v: Cx) void {
        self.data[self.idx(x, y, z)] = v;
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// Largest ladder size 16*2^L <= n.
pub fn ladderSize(n: u32) u32 {
    var ladder: u32 = 16;
    while (ladder * 2 <= n) ladder *= 2;
    return ladder;
}

/// Number of scale levels above the core for a ladder size.
pub fn levelCountOf(ladder: u32) u5 {
    var levels: u5 = 0;
    var sz: u32 = CORE_SIDE;
    while (sz < ladder) : (sz *= 2) levels += 1;
    return levels;
}

/// Odd-cell count at a level with grid size nl (nl = 16*2^L, L >= 1):
/// nl³ - (nl/2)³.
fn oddCellCount(nl: u32) u64 {
    const a: u64 = nl;
    const b: u64 = nl / 2;
    return a * a * a - b * b * b;
}

/// True when (x,y,z) sits on the coarsest lattice (the core) inside the
/// ladder. Perimeter cells are never core cells.
fn isCoreCell(x: u32, y: u32, z: u32, stride: u32, ladder: u32) bool {
    return x < ladder and y < ladder and z < ladder and
        x % stride == 0 and y % stride == 0 and z % stride == 0;
}

// =============================================================================
// Hologram
// =============================================================================

pub const Mode = enum(u32) { dynamics, residual };

/// FHOLO1 on-disk header (64 bytes).
pub const Header = extern struct {
    magic: [8]u8, // "FHOLO1\0\0"
    version: u32,
    n: u32,
    ladder: u32,
    levels: u32,
    mode: u32,
    winding_len: u64,
    residual_count: u64,
    perimeter_count: u64,
    defect: i64,
    core_hash: u32,
    header_sum: u32,
};

/// A hologram: the folded form of an N³ grid.
pub const Hologram = struct {
    n: u32,
    ladder: u32,
    levels: u5,
    mode: Mode,
    core: []Cx,
    /// Concatenated per-level RLE streams of (u32 count, u8 winding).
    winding_rle: []u8,
    level_woff: [MAX_LEVELS + 1]u32,
    odd_counts: [MAX_LEVELS]u64,
    /// Perimeter (odd N) winding RLE stream + cell count.
    perimeter_rle: []u8,
    perimeter_count: u64,
    /// Residual mode: full values for every non-core cell (scan order).
    residuals: []Cx,
    /// Module 4 defect charge: 1 + perimeter winding charge (nonzero for
    /// every odd grid — the +1 layer is the anchor).
    defect: i64,

    pub fn deinit(self: *Hologram, alloc: std.mem.Allocator) void {
        alloc.free(self.core);
        alloc.free(self.winding_rle);
        alloc.free(self.residuals);
    }

    pub fn hologramBytes(self: *const Hologram) u64 {
        return @sizeOf(Header) + @as(u64, CORE_CELLS) * 32 +
            self.winding_rle.len + self.residuals.len * 32;
    }

    pub fn gridBytes(self: *const Hologram) u64 {
        return @as(u64, self.n) * self.n * self.n * 32;
    }

    /// Node-count ratio (the Module 3 figure): N³ / 16³.
    pub fn nodeRatio(self: *const Hologram) u64 {
        const nodes: u64 = @as(u64, self.n) * self.n * self.n;
        return @divTrunc(nodes, CORE_CELLS);
    }

    /// Byte ratio: raw grid bytes / hologram bytes (fixed-point Q32.32).
    pub fn byteRatioQ32(self: *const Hologram) u64 {
        const gb = self.gridBytes();
        const hb = self.hologramBytes();
        if (hb == 0) return 0;
        return @divTrunc(gb << 32, hb);
    }
};

// =============================================================================
// RLE for winding streams: (u32 count LE, u8 value) pairs.
// =============================================================================

fn rleEncode(alloc: std.mem.Allocator, values: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    var i: usize = 0;
    while (i < values.len) {
        const v = values[i];
        var run: u32 = 1;
        while (i + run < values.len and values[i + run] == v and run < std.math.maxInt(u32)) : (run += 1) {}
        var cnt: [4]u8 = undefined;
        std.mem.writeInt(u32, &cnt, @intCast(run), .little);
        try list.appendSlice(&cnt);
        try list.append(v);
        i += run;
    }
    return list.toOwnedSlice();
}

const RleIter = struct {
    stream: []const u8,
    pos: usize = 0,

    fn next(self: *RleIter) ?struct { count: u32, value: u8 } {
        if (self.pos + 5 > self.stream.len) return null;
        const count = std.mem.readInt(u32, self.stream[self.pos..][0..4], .little);
        const value = self.stream[self.pos + 4];
        self.pos += 5;
        return .{ .count = count, .value = value };
    }
};

/// Find w in 0..3 with rotPow(neighbor, w) == actual, else null.
fn windingFor(neighbor: Cx, actual: Cx) ?u8 {
    var w: u8 = 0;
    while (w < 4) : (w += 1) {
        if (rotPow(neighbor, w).eq(actual)) return w;
    }
    return null;
}

fn fnvCore(core: []const Cx) u32 {
    var h: u32 = 0x811c9dc5;
    for (core) |v| {
        const bytes = std.mem.asBytes(&v.re) ++ std.mem.asBytes(&v.im);
        for (bytes) |b| {
            h ^= b;
            h *%= 0x01000193;
        }
    }
    return h;
}

// =============================================================================
// Fold (compress)
// =============================================================================

/// Fold an N³ grid into a hologram. N must be a ladder size or a ladder
/// size + 1 (odd perimeter, Module 4).
pub fn fold(alloc: std.mem.Allocator, grid: *const Grid) !Hologram {
    const n = grid.n;
    const ladder = ladderSize(n);
    const levels = levelCountOf(ladder);
    const stride = @as(u32, 1) << @intCast(levels);
    const has_perimeter = (n == ladder + 1);

    var core = try alloc.alloc(Cx, CORE_CELLS);
    errdefer alloc.free(core);
    {
        var z: u32 = 0;
        while (z < CORE_SIDE) : (z += 1) {
            var y: u32 = 0;
            while (y < CORE_SIDE) : (y += 1) {
                var x: u32 = 0;
                while (x < CORE_SIDE) : (x += 1) {
                    core[x + y * CORE_SIDE + z * CORE_SIDE * CORE_SIDE] =
                        grid.get(x * stride, y * stride, z * stride);
                }
            }
        }
    }

    var holo = Hologram{
        .n = n,
        .ladder = ladder,
        .levels = levels,
        .mode = .dynamics,
        .core = core,
        .winding_rle = &.{},
        .level_woff = [_]u32{0} ** (MAX_LEVELS + 1),
        .odd_counts = [_]u64{0} ** MAX_LEVELS,
        .perimeter_rle = &.{},
        .perimeter_count = 0,
        .residuals = &.{},
        .defect = 0,
    };
    errdefer holo.deinit(alloc);

    // ---- dynamics attempt ----
    var ok = true;
    var lists: [MAX_LEVELS + 1]std.ArrayList(u8) = undefined;
    for (&lists) |*l| l.* = std.ArrayList(u8).init(alloc);
    defer for (&lists) |*l| l.deinit();
    var perimeter_wind = std.ArrayList(u8).init(alloc);
    defer perimeter_wind.deinit();

    var level: u5 = 1;
    while (level <= levels and ok) : (level += 1) {
        const nl = @as(u32, CORE_SIDE) << @intCast(level);
        const h = @as(u32, 1) << @intCast(levels - level);
        var az: u32 = 0;
        while (az < nl and ok) : (az += 1) {
            var ay: u32 = 0;
            while (ay < nl and ok) : (ay += 1) {
                var ax: u32 = 0;
                while (ax < nl and ok) : (ax += 1) {
                    if ((ax & 1) == 0 and (ay & 1) == 0 and (az & 1) == 0) continue;
                    const nb = grid.get((ax & ~@as(u32, 1)) * h, (ay & ~@as(u32, 1)) * h, (az & ~@as(u32, 1)) * h);
                    const w = windingFor(nb, grid.get(ax * h, ay * h, az * h)) orelse {
                        ok = false;
                        break;
                    };
                    try lists[level].append(w);
                }
            }
        }
    }

    if (ok and has_perimeter) {
        var z: u32 = 0;
        while (z < n and ok) : (z += 1) {
            var y: u32 = 0;
            while (y < n and ok) : (y += 1) {
                var x: u32 = 0;
                while (x < n and ok) : (x += 1) {
                    if (x != ladder and y != ladder and z != ladder) continue;
                    const nx = @min(x, ladder - 1) & ~@as(u32, 1);
                    const ny = @min(y, ladder - 1) & ~@as(u32, 1);
                    const nz = @min(z, ladder - 1) & ~@as(u32, 1);
                    const w = windingFor(grid.get(nx, ny, nz), grid.get(x, y, z)) orelse {
                        ok = false;
                        break;
                    };
                    try perimeter_wind.append(w);
                }
            }
        }
    }

    if (ok) {
        var parts: [MAX_LEVELS + 1][]u8 = undefined;
        var total: usize = 0;
        {
            var lv: u5 = 1;
            while (lv <= levels) : (lv += 1) {
                parts[lv] = try rleEncode(alloc, lists[lv].items);
                total += parts[lv].len;
            }
        }
        const per = if (has_perimeter) try rleEncode(alloc, perimeter_wind.items) else &[_]u8{};
        var combined = try alloc.alloc(u8, total + per.len);
        errdefer alloc.free(combined);
        var off: usize = 0;
        {
            var lv: u5 = 1;
            while (lv <= levels) : (lv += 1) {
                holo.level_woff[lv] = @intCast(off);
                @memcpy(combined[off .. off + parts[lv].len], parts[lv]);
                off += parts[lv].len;
            }
        }
        holo.level_woff[levels + 1] = @intCast(off);
        if (per.len > 0) @memcpy(combined[off..], per);
        var lv: u5 = 1;
        while (lv <= levels) : (lv += 1) alloc.free(parts[lv]);
        holo.winding_rle = combined;
        if (has_perimeter) {
            holo.perimeter_count = @intCast(perimeter_wind.items.len);
            holo.perimeter_rle = combined[off..];
            var it = RleIter{ .stream = holo.perimeter_rle, .pos = 0 };
            var wsum: i64 = 0;
            while (it.next()) |pr| wsum += @as(i64, pr.count) * pr.value;
            holo.defect = 1 + wsum;
        }
        return holo;
    }

    // ---- residual fallback: store every non-core cell ----
    holo.mode = .residual;
    var count: usize = 0;
    {
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var y: u32 = 0;
            while (y < n) : (y += 1) {
                var x: u32 = 0;
                while (x < n) : (x += 1) {
                    if (isCoreCell(x, y, z, stride, ladder)) continue;
                    count += 1;
                }
            }
        }
    }
    const residuals = try alloc.alloc(Cx, count);
    errdefer alloc.free(residuals);
    var k: usize = 0;
    {
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var y: u32 = 0;
            while (y < n) : (y += 1) {
                var x: u32 = 0;
                while (x < n) : (x += 1) {
                    if (isCoreCell(x, y, z, stride, ladder)) continue;
                    residuals[k] = grid.get(x, y, z);
                    k += 1;
                }
            }
        }
    }
    holo.residuals = residuals;
    holo.defect = if (has_perimeter) 1 else 0;
    return holo;
}

// =============================================================================
// Unfold (decompress) — O(1) per cell, partial at any level.
// =============================================================================

fn writeCx(buf: []u8, off: usize, v: Cx) void {
    std.mem.writeInt(i128, buf[off..][0..16], v.re, .little);
    std.mem.writeInt(i128, buf[off + 16 ..][0..16], v.im, .little);
}

fn readCx(buf: []const u8, off: usize) !Cx {
    if (off + 32 > buf.len) return error.CorruptHologram;
    return .{
        .re = std.mem.readInt(i128, buf[off..][0..16], .little),
        .im = std.mem.readInt(i128, buf[off + 16 ..][0..16], .little),
    };
}

fn unfoldDynamics(alloc: std.mem.Allocator, holo: *const Hologram, tl: u5, include_perimeter: bool, out: *Grid) !void {
    var prev = try Grid.init(alloc, CORE_SIDE);
    defer prev.deinit(alloc);
    {
        var z: u32 = 0;
        while (z < CORE_SIDE) : (z += 1) {
            var y: u32 = 0;
            while (y < CORE_SIDE) : (y += 1) {
                var x: u32 = 0;
                while (x < CORE_SIDE) : (x += 1) {
                    prev.set(x, y, z, holo.core[x + y * CORE_SIDE + z * CORE_SIDE * CORE_SIDE]);
                }
            }
        }
    }
    var s: u5 = 1;
    while (s <= tl) : (s += 1) {
        const nl = @as(u32, CORE_SIDE) << @intCast(s);
        var cur = try Grid.init(alloc, nl);
        errdefer cur.deinit(alloc);
        var z: u32 = 0;
        while (z < nl) : (z += 1) {
            var y: u32 = 0;
            while (y < nl) : (y += 1) {
                var x: u32 = 0;
                while (x < nl) : (x += 1) {
                    if ((x & 1) == 0 and (y & 1) == 0 and (z & 1) == 0) {
                        cur.set(x, y, z, prev.get(x / 2, y / 2, z / 2));
                    }
                }
            }
        }
        var it = RleIter{ .stream = holo.winding_rle, .pos = holo.level_woff[s] };
        var remaining: u32 = 0;
        var wval: u8 = 0;
        z = 0;
        while (z < nl) : (z += 1) {
            var y: u32 = 0;
            while (y < nl) : (y += 1) {
                var x: u32 = 0;
                while (x < nl) : (x += 1) {
                    if ((x & 1) == 0 and (y & 1) == 0 and (z & 1) == 0) continue;
                    if (remaining == 0) {
                        const pair = it.next() orelse return error.CorruptHologram;
                        remaining = pair.count;
                        wval = pair.value;
                    }
                    remaining -= 1;
                    const nb = cur.get(x & ~@as(u32, 1), y & ~@as(u32, 1), z & ~@as(u32, 1));
                    cur.set(x, y, z, rotPow(nb, wval));
                }
            }
        }
        prev.deinit(alloc);
        prev = cur;
    }
    // copy the ladder into out (out may be one larger for the perimeter)
    const ladder_out = @as(u32, CORE_SIDE) << @intCast(tl);
    var z: u32 = 0;
    while (z < ladder_out) : (z += 1) {
        var y: u32 = 0;
        while (y < ladder_out) : (y += 1) {
            var x: u32 = 0;
            while (x < ladder_out) : (x += 1) {
                out.set(x, y, z, prev.get(x, y, z));
            }
        }
    }
    if (include_perimeter and holo.perimeter_count > 0) {
        const ladder = holo.ladder;
        var it = RleIter{ .stream = holo.perimeter_rle, .pos = 0 };
        var remaining: u32 = 0;
        var wval: u8 = 0;
        z = 0;
        while (z < out.n) : (z += 1) {
            var y: u32 = 0;
            while (y < out.n) : (y += 1) {
                var x: u32 = 0;
                while (x < out.n) : (x += 1) {
                    if (x != ladder and y != ladder and z != ladder) continue;
                    if (remaining == 0) {
                        const pair = it.next() orelse return error.CorruptHologram;
                        remaining = pair.count;
                        wval = pair.value;
                    }
                    remaining -= 1;
                    const nx = @min(x, ladder - 1) & ~@as(u32, 1);
                    const ny = @min(y, ladder - 1) & ~@as(u32, 1);
                    const nz = @min(z, ladder - 1) & ~@as(u32, 1);
                    out.set(x, y, z, rotPow(out.get(nx, ny, nz), wval));
                }
            }
        }
    }
}

fn unfoldResidual(holo: *const Hologram, out: *Grid) !void {
    const stride = @as(u32, 1) << @intCast(holo.levels);
    var k: usize = 0;
    var z: u32 = 0;
    while (z < out.n) : (z += 1) {
        var y: u32 = 0;
        while (y < out.n) : (y += 1) {
            var x: u32 = 0;
            while (x < out.n) : (x += 1) {
                if (isCoreCell(x, y, z, stride, holo.ladder)) {
                    const ci = (x / stride) + (y / stride) * CORE_SIDE + (z / stride) * CORE_SIDE * CORE_SIDE;
                    out.set(x, y, z, holo.core[ci]);
                } else {
                    if (k >= holo.residuals.len) return error.CorruptHologram;
                    out.set(x, y, z, holo.residuals[k]);
                    k += 1;
                }
            }
        }
    }
}

/// Reconstruct the grid at scale level `target_level` (0..levels).
/// With include_perimeter and target_level == levels, yields the full
/// N³ grid (perimeter shell included for odd N).
pub fn unfoldAt(alloc: std.mem.Allocator, holo: *const Hologram, target_level: u5, include_perimeter: bool) !Grid {
    const tl = @min(target_level, holo.levels);
    const full = include_perimeter and tl == holo.levels and
        (holo.mode == .residual or holo.perimeter_count > 0);
    const n_out = if (full) holo.n else @as(u32, CORE_SIDE) << @intCast(tl);
    var out = try Grid.init(alloc, n_out);
    errdefer out.deinit(alloc);
    switch (holo.mode) {
        .dynamics => try unfoldDynamics(alloc, holo, tl, full, &out),
        .residual => {
            if (tl != holo.levels) return error.UnsupportedPartialResidual;
            try unfoldResidual(holo, &out);
        },
    }
    return out;
}

/// Full reconstruction convenience wrapper.
pub fn unfold(alloc: std.mem.Allocator, holo: *const Hologram) !Grid {
    return unfoldAt(alloc, holo, holo.levels, true);
}

// =============================================================================
// FHOLO1 Serialization
// =============================================================================

pub fn serialize(alloc: std.mem.Allocator, holo: *const Hologram) ![]u8 {
    const total = holo.hologramBytes();
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);
    var h = std.mem.zeroes(Header);
    h = .{
        .magic = "FHOLO1\x00\x00".*,
        .version = 1,
        .n = holo.n,
        .ladder = holo.ladder,
        .levels = holo.levels,
        .mode = @intFromEnum(holo.mode),
        .winding_len = holo.winding_rle.len,
        .residual_count = holo.residuals.len,
        .perimeter_count = holo.perimeter_count,
        .defect = holo.defect,
        .core_hash = fnvCore(holo.core),
        .header_sum = 0,
    };
    var sum: u32 = 0x811c9dc5;
    for (std.mem.asBytes(&h)) |b| {
        sum ^= b;
        sum *%= 0x01000193;
    }
    h.header_sum = sum;
    @memcpy(buf[0..@sizeOf(Header)], std.mem.asBytes(&h));
    var off: usize = @sizeOf(Header);
    for (holo.core) |v| {
        writeCx(buf, off, v);
        off += 32;
    }
    @memcpy(buf[off .. off + holo.winding_rle.len], holo.winding_rle);
    off += holo.winding_rle.len;
    for (holo.residuals) |v| {
        writeCx(buf, off, v);
        off += 32;
    }
    return buf;
}

pub fn deserialize(alloc: std.mem.Allocator, bytes: []const u8) !Hologram {
    if (bytes.len < @sizeOf(Header)) return error.CorruptHologram;
    var h: Header = undefined;
    @memcpy(std.mem.asBytes(&h), bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &h.magic, "FHOLO1\x00\x00")) return error.CorruptHologram;
    const saved = h.header_sum;
    h.header_sum = 0;
    var sum: u32 = 0x811c9dc5;
    for (std.mem.asBytes(&h)) |b| {
        sum ^= b;
        sum *%= 0x01000193;
    }
    if (sum != saved) return error.CorruptHologram;
    h.header_sum = saved;

    const need = @sizeOf(Header) + @as(u64, CORE_CELLS) * 32 + h.winding_len + h.residual_count * 32;
    if (bytes.len < need) return error.CorruptHologram;

    const core = try alloc.alloc(Cx, CORE_CELLS);
    errdefer alloc.free(core);
    var off: usize = @sizeOf(Header);
    for (core) |*v| {
        v.* = try readCx(bytes, off);
        off += 32;
    }
    if (fnvCore(core) != h.core_hash) return error.CorruptHologram;

    const w = try alloc.alloc(u8, h.winding_len);
    errdefer alloc.free(w);
    @memcpy(w, bytes[off .. off + h.winding_len]);
    off += @intCast(h.winding_len);

    const r = try alloc.alloc(Cx, h.residual_count);
    errdefer alloc.free(r);
    for (r) |*v| {
        v.* = try readCx(bytes, off);
        off += 32;
    }

    const levels: u5 = @intCast(h.levels);
    var holo = Hologram{
        .n = h.n,
        .ladder = h.ladder,
        .levels = levels,
        .mode = @enumFromInt(h.mode),
        .core = core,
        .winding_rle = w,
        .level_woff = [_]u32{0} ** (MAX_LEVELS + 1),
        .odd_counts = [_]u64{0} ** MAX_LEVELS,
        .perimeter_rle = &.{},
        .perimeter_count = h.perimeter_count,
        .residuals = r,
        .defect = h.defect,
    };
    // recompute level offsets by walking the RLE streams
    var pos: u32 = 0;
    var s: u5 = 1;
    while (s <= levels) : (s += 1) {
        holo.level_woff[s] = pos;
        const nl = @as(u32, CORE_SIDE) << @intCast(s);
        var it = RleIter{ .stream = w, .pos = pos };
        var seen: u64 = 0;
        while (seen < oddCellCount(nl)) {
            const pair = it.next() orelse return error.CorruptHologram;
            seen += pair.count;
        }
        pos = @intCast(it.pos);
    }
    holo.level_woff[levels + 1] = pos;
    if (holo.perimeter_count > 0) holo.perimeter_rle = w[pos..];
    return holo;
}

// =============================================================================
// Family State Generator (FANO-1-representable states)
// =============================================================================

/// Generate a family state: core random; every non-core cell an exact
/// quarter-turn of its even-floor neighbor. `winding_rate` (0..100) is
/// the percentage of cells receiving a nonzero winding.
pub fn generateFamily(alloc: std.mem.Allocator, n: u32, rng: std.Random, winding_rate: u8) !Grid {
    const ladder = ladderSize(n);
    const levels = levelCountOf(ladder);
    const has_perimeter = (n == ladder + 1);

    var prev = try Grid.init(alloc, CORE_SIDE);
    for (prev.data) |*v| {
        v.re = @as(i128, rng.int(i64));
        v.im = @as(i128, rng.int(i64));
    }
    var s: u5 = 1;
    while (s <= levels) : (s += 1) {
        var cur = try Grid.init(alloc, @as(u32, CORE_SIDE) << @intCast(s));
        const nl = cur.n;
        var z: u32 = 0;
        while (z < nl) : (z += 1) {
            var y: u32 = 0;
            while (y < nl) : (y += 1) {
                var x: u32 = 0;
                while (x < nl) : (x += 1) {
                    if ((x & 1) == 0 and (y & 1) == 0 and (z & 1) == 0) {
                        cur.set(x, y, z, prev.get(x / 2, y / 2, z / 2));
                    } else {
                        const w: u8 = if (rng.uintLessThan(u8, 100) < winding_rate)
                            @intCast(1 + rng.uintLessThan(u8, 3))
                        else
                            0;
                        const nb = cur.get(x & ~@as(u32, 1), y & ~@as(u32, 1), z & ~@as(u32, 1));
                        cur.set(x, y, z, rotPow(nb, w));
                    }
                }
            }
        }
        prev.deinit(alloc);
        prev = cur;
    }
    if (!has_perimeter) return prev;

    var out = try Grid.init(alloc, n);
    {
        var z: u32 = 0;
        while (z < ladder) : (z += 1) {
            var y: u32 = 0;
            while (y < ladder) : (y += 1) {
                var x: u32 = 0;
                while (x < ladder) : (x += 1) out.set(x, y, z, prev.get(x, y, z));
            }
        }
    }
    var z: u32 = 0;
    while (z < n) : (z += 1) {
        var y: u32 = 0;
        while (y < n) : (y += 1) {
            var x: u32 = 0;
            while (x < n) : (x += 1) {
                if (x != ladder and y != ladder and z != ladder) continue;
                const nx = @min(x, ladder - 1) & ~@as(u32, 1);
                const ny = @min(y, ladder - 1) & ~@as(u32, 1);
                const nz = @min(z, ladder - 1) & ~@as(u32, 1);
                const w: u8 = if (rng.uintLessThan(u8, 100) < winding_rate)
                    @intCast(1 + rng.uintLessThan(u8, 3))
                else
                    0;
                out.set(x, y, z, rotPow(out.get(nx, ny, nz), w));
            }
        }
    }
    prev.deinit(alloc);
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectGridEq(a: *const Grid, b: *const Grid) !void {
    try testing.expectEqual(a.n, b.n);
    for (a.data, b.data) |x, y| try testing.expect(x.eq(y));
}

test "rot90 has period 4 and is exact" {
    const v = Cx{ .re = 3, .im = 7 };
    try testing.expect(rotPow(v, 4).eq(v));
    try testing.expect(rotPow(v, 0).eq(v));
    const r1 = rot90(v);
    try testing.expectEqual(@as(i128, -7), r1.re);
    try testing.expectEqual(@as(i128, 3), r1.im);
}

test "rot90 negates and swaps" {
    const v = Cx{ .re = 42, .im = 100 };
    const r = rot90(v);
    try testing.expectEqual(-v.im, r.re);
    try testing.expectEqual(v.re, r.im);
}

test "ladder and level helpers" {
    try testing.expectEqual(@as(u32, 16), ladderSize(16));
    try testing.expectEqual(@as(u32, 16), ladderSize(17));
    try testing.expectEqual(@as(u32, 32), ladderSize(33));
    try testing.expectEqual(@as(u32, 512), ladderSize(513));
    try testing.expectEqual(@as(u5, 0), levelCountOf(16));
    try testing.expectEqual(@as(u5, 1), levelCountOf(32));
    try testing.expectEqual(@as(u5, 5), levelCountOf(512));
    try testing.expectEqual(@as(u64, 28672), oddCellCount(32));
}

test "family round-trip N=17 (core + odd perimeter)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(42);
    var g = try generateFamily(alloc, 17, prng.random(), 10);
    var h = try fold(alloc, &g);
    try testing.expectEqual(Mode.dynamics, h.mode);
    try testing.expect(h.defect != 0); // Module 4: odd perimeter carries charge
    var r = try unfold(alloc, &h);
    try expectGridEq(&g, &r);
}

test "family round-trip N=33 and N=65 with structured windings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (.{ 33, 65 }) |N| {
        var prng = std.Random.DefaultPrng.init(N);
        var g = try generateFamily(alloc, N, prng.random(), 5);
        var h = try fold(alloc, &g);
        try testing.expectEqual(Mode.dynamics, h.mode);
        var r = try unfold(alloc, &h);
        try expectGridEq(&g, &r);
    }
}

test "partial unfold at level 0 returns the core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(7);
    var g = try generateFamily(alloc, 33, prng.random(), 20);
    var h = try fold(alloc, &g);
    var r0 = try unfoldAt(alloc, &h, 0, false);
    try testing.expectEqual(@as(u32, 16), r0.n);
    var z: u32 = 0;
    while (z < 16) : (z += 1) {
        var y: u32 = 0;
        while (y < 16) : (y += 1) {
            var x: u32 = 0;
            while (x < 16) : (x += 1) {
                try testing.expect(r0.get(x, y, z).eq(g.get(2 * x, 2 * y, 2 * z)));
            }
        }
    }
}

test "random grid falls back to residual mode and round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(99);
    const rng = prng.random();
    var g = try Grid.init(alloc, 17);
    for (g.data) |*v| {
        v.re = @as(i128, rng.int(i64));
        v.im = @as(i128, rng.int(i64));
    }
    var h = try fold(alloc, &g);
    try testing.expectEqual(Mode.residual, h.mode);
    var r = try unfold(alloc, &h);
    try expectGridEq(&g, &r);
}

test "FHOLO1 serialize/deserialize round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(11);
    var g = try generateFamily(alloc, 33, prng.random(), 5);
    var h = try fold(alloc, &g);
    const bytes = try serialize(alloc, &h);
    var h2 = try deserialize(alloc, bytes);
    try testing.expectEqual(h.mode, h2.mode);
    try testing.expectEqual(h.defect, h2.defect);
    var r = try unfold(alloc, &h2);
    try expectGridEq(&g, &r);
}

test "pure family state achieves holographic ratios (Module 3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(3);
    // winding_rate = 0: the state is fully determined by the core
    var g = try generateFamily(alloc, 65, prng.random(), 0);
    var h = try fold(alloc, &g);
    try testing.expectEqual(Mode.dynamics, h.mode);
    // node ratio: 65^3 / 16^3 = 274625 / 4096 ≈ 67
    try testing.expectEqual(@as(u64, 67), h.nodeRatio());
    // byte ratio > 50 (Q32.32 fixed-point)
    try testing.expect(h.byteRatioQ32() > (50 << 32));
    var r = try unfold(alloc, &h);
    try expectGridEq(&g, &r);
}

test "Cx equality" {
    const a = Cx{ .re = 1, .im = 2 };
    const b = Cx{ .re = 1, .im = 2 };
    const c = Cx{ .re = 1, .im = 3 };
    try testing.expect(a.eq(b));
    try testing.expect(!a.eq(c));
}

test "Grid init/deinit and access" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = try Grid.init(alloc, 4);
    try testing.expectEqual(@as(u32, 4), g.n);
    try testing.expectEqual(@as(usize, 64), g.data.len);
    g.set(1, 2, 3, .{ .re = 42, .im = 99 });
    const v = g.get(1, 2, 3);
    try testing.expectEqual(@as(i128, 42), v.re);
    try testing.expectEqual(@as(i128, 99), v.im);
}

test "windingFor finds correct winding" {
    const neighbor = Cx{ .re = 1, .im = 0 };
    // rot90(neighbor) = (-0, 1) = (0, 1)
    const w1 = windingFor(neighbor, Cx{ .re = 0, .im = 1 });
    try testing.expect(w1 != null);
    try testing.expectEqual(@as(u8, 1), w1.?);
    // rotPow(neighbor, 2) = (-1, 0)
    const w2 = windingFor(neighbor, Cx{ .re = -1, .im = 0 });
    try testing.expect(w2 != null);
    try testing.expectEqual(@as(u8, 2), w2.?);
    // No winding matches an arbitrary value
    try testing.expect(windingFor(neighbor, Cx{ .re = 999, .im = 999 }) == null);
}

test "hologram byte counts are consistent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(5);
    var g = try generateFamily(alloc, 33, prng.random(), 10);
    var h = try fold(alloc, &g);
    const hb = h.hologramBytes();
    const gb = h.gridBytes();
    // Hologram should be smaller than the raw grid for family states
    try testing.expect(hb < gb);
}

test "defect is nonzero for odd perimeter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(8);
    var g = try generateFamily(alloc, 17, prng.random(), 50);
    const h = try fold(alloc, &g);
    // Module 4: odd perimeter (N=17 = 16+1) carries nonzero defect charge
    try testing.expect(h.defect != 0);
}

test "holo codec uses integer types (no f64)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(13);
    var g = try generateFamily(alloc, 17, prng.random(), 10);
    var h = try fold(alloc, &g);
    // nodeRatio returns u64, not f64
    try testing.expect(@TypeOf(h.nodeRatio()) == u64);
    // byteRatioQ32 returns u64, not f64
    try testing.expect(@TypeOf(h.byteRatioQ32()) == u64);
    // defect is i64
    try testing.expect(@TypeOf(h.defect) == i64);
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
