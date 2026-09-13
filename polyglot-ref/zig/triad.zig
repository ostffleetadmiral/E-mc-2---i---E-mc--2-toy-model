//! triad.zig - Mound triad operator engine: O(a,b,c) = phi^a + pi^b + phi^c.
//!
//! All 145 physical constants from x/mound_triad_results.csv are stored as
//! integer exponent triples (6 bytes of payload each) and evaluated in
//! Q128.128 fixed-point at runtime — no floating-point constants in the
//! arithmetic path. The `sign` column carries the physical sign convention
//! for constants whose value is negative while the operator is a positive
//! sum (fermion magnetic moments, Sackur-Tetrode entropy).

const std = @import("std");
const Q = @import("q128_128");
const table_mod = @import("triad_table.zig");

pub const Const = table_mod.Const;
pub const table = table_mod.table;
pub const TABLE_LEN = table_mod.TABLE_LEN;

pub const TriadValue = struct {
    v: Q.q128,
    /// At least one term fell below the epsilon floor (2^-128) and was
    /// flushed to zero. Informational: the surviving terms still sum
    /// correctly (e.g. Critical Density loses only its pi^b term).
    underflow: bool,
};

/// O(a,b,c) = phi^a + pi^b + phi^c as a positive magnitude.
pub fn triadValue(a: i32, b: i32, c: i32) Q.Q128Pow {
    const pa = Q.q128Pow(Q.PHI_RAW, a);
    const pb = Q.q128Pow(Q.PI_RAW, b);
    const pc = Q.q128Pow(Q.PHI_RAW, c);
    const s = Q.q128Add(Q.q128Add(pa.v, pb.v), pc.v);
    return .{ .v = s, .underflow = pa.underflow or pb.underflow or pc.underflow };
}

/// Signed value: applies the constant's physical sign convention.
pub fn triadSigned(k: *const Const) Q.Q128Pow {
    const t = triadValue(k.a, k.b, k.c);
    return .{
        .v = if (k.sign < 0) Q.q128Neg(t.v) else t.v,
        .underflow = t.underflow,
    };
}

pub fn lookupByName(name: []const u8) ?*const Const {
    for (&table) |*k| {
        if (std.mem.eql(u8, k.name, name)) return k;
    }
    return null;
}

pub fn lookupBySubstring(needle: []const u8) ?*const Const {
    for (&table) |*k| {
        if (std.ascii.indexOfIgnoreCase(k.name, needle) != null) return k;
    }
    return null;
}

pub const VerifyRow = struct {
    index: usize,
    name: []const u8,
    err_pct: f64,
    underflow: bool,
    ok: bool,
};

pub const VerifyResult = struct {
    total: usize,
    within_1pct: usize,
    arithmetic_failures: usize,
    underflow_count: usize,
    rows: []VerifyRow,

    pub fn deinit(self: *VerifyResult, alloc: std.mem.Allocator) void {
        alloc.free(self.rows);
    }
};

/// Recompute every table entry in Q128.128 and compare against the CSV
/// reference value (arithmetic check, 1e-12 relative) and its target
/// (fit-quality report). Underflowed results (below the 2^-128 floor) are
/// reported, not failed.
pub fn verifyAll(alloc: std.mem.Allocator) !VerifyResult {
    const rows = try alloc.alloc(VerifyRow, table.len);
    errdefer alloc.free(rows);
    var within: usize = 0;
    var failures: usize = 0;
    var under_count: usize = 0;
    for (&table, 0..) |*k, i| {
        const t = triadSigned(k);
        const f = Q.toFloat(t.v);
        const err_pct = if (k.target != 0) (f - k.target) / k.target * 100.0 else 0.0;
        const row_under = t.underflow and Q.q128Eq(t.v, Q.Q_ZERO) and k.target != 0;
        // Arithmetic check: our Q128.128 evaluation must reproduce the CSV
        // triad value to f64 conversion accuracy. (The CSV's Triad_Value is
        // the f64 reference for the same O(a,b,c).) Tolerance is relative
        // 1e-12 OR the accumulated fixed-point rounding bound: each pow
        // contributes <= |exp| half-ulp (2^-129) absolute errors.
        const ref = @as(f64, @floatFromInt(k.sign)) * triadValueF64(k.a, k.b, k.c);
        // Accumulated fixed-point rounding bound: each pow contributes
        // <= |exp| half-ulps (2^-129 value units) of absolute error.
        const ulp_bound = @as(f64, @floatFromInt(@as(i32, @abs(k.a)) + @as(i32, @abs(k.b)) + @as(i32, @abs(k.c)) + 16)) * 1.4693679385278594e-39;
        const ok = if (row_under) true else @abs(f - ref) <= @max(1e-12 * @abs(ref), ulp_bound);
        if (!ok) failures += 1;
        if (!row_under and @abs(err_pct) <= 1.0) within += 1;
        if (row_under) under_count += 1;
        rows[i] = .{ .index = i, .name = k.name, .err_pct = err_pct, .underflow = row_under, .ok = ok };
    }
    return .{
        .total = table.len,
        .within_1pct = within,
        .arithmetic_failures = failures,
        .underflow_count = under_count,
        .rows = rows,
    };
}

/// The CSV's reference triad value for a constant (recomputed from the
/// exponents in f64 — matches the source CSV's Triad_Value column).
fn triadRefFloat(k: *const Const) f64 {
    return triadValueF64(k.a, k.b, k.c);
}

/// f64 reference evaluation of O(a,b,c) (matches the CSV generator).
pub fn triadValueF64(a: i32, b: i32, c: i32) f64 {
    const phi: f64 = 1.6180339887498948482;
    const pi: f64 = std.math.pi;
    return std.math.pow(f64, phi, @as(f64, @floatFromInt(a))) +
        std.math.pow(f64, pi, @as(f64, @floatFromInt(b))) +
        std.math.pow(f64, phi, @as(f64, @floatFromInt(c)));
}

pub const FitResult = struct {
    a: i32,
    b: i32,
    c: i32,
    value: f64,
    rel_err: f64,
    found: bool,
};

/// Exhaustive bounded search for (a,b,c) with O(a,b,c) ≈ target.
/// Precomputes phi^a / pi^b tables over [-bound, bound] and binary-searches
/// the monotone phi^c axis for every (a,b) pair.
pub fn fit(target: f64, bound: i32) FitResult {
    var best = FitResult{ .a = 0, .b = 0, .c = 0, .value = 0, .rel_err = std.math.inf(f64), .found = false };
    if (target <= 0 or bound < 1) return best;
    const n: usize = @intCast(2 * bound + 1);
    const phi_p = std.heap.page_allocator.alloc(f64, n) catch return best;
    defer std.heap.page_allocator.free(phi_p);
    const pi_p = std.heap.page_allocator.alloc(f64, n) catch return best;
    defer std.heap.page_allocator.free(pi_p);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e: i32 = @as(i32, @intCast(i)) - bound;
        phi_p[i] = Q.toFloat(Q.q128Pow(Q.PHI_RAW, e).v);
        pi_p[i] = Q.toFloat(Q.q128Pow(Q.PI_RAW, e).v);
    }
    var ai: usize = 0;
    while (ai < n) : (ai += 1) {
        const a_val = phi_p[ai];
        var bj: usize = 0;
        while (bj < n) : (bj += 1) {
            const partial = a_val + pi_p[bj];
            const need = target - partial;
            if (need <= 0) continue;
            // binary search the monotone phi^c axis for `need`
            var lo: usize = 0;
            var hi: usize = n - 1;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (phi_p[mid] < need) lo = mid + 1 else hi = mid;
            }
            var k = lo;
            if (k > 0) k -= 1;
            const k_end = @min(lo + 1, n - 1);
            while (k <= k_end) : (k += 1) {
                const total = a_val + pi_p[bj] + phi_p[k];
                const err = @abs(total - target);
                if (err < best.rel_err) {
                    best = .{
                        .a = @as(i32, @intCast(ai)) - bound,
                        .b = @as(i32, @intCast(bj)) - bound,
                        .c = @as(i32, @intCast(k)) - bound,
                        .value = total,
                        .rel_err = err,
                        .found = true,
                    };
                }
            }
        }
    }
    if (best.found) best.rel_err /= target;
    return best;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "triad doc examples" {
    // Proton Magnetic Moment: a=-143, b=-52, c=-136
    const pm = triadValue(-143, -52, -136);
    try testing.expect(!pm.underflow);
    try testing.expect(@abs(Q.toFloat(pm.v) - 1.4106285177150063e-26) /
        1.4106285177150063e-26 < 1e-12);
    // Hydrogen 21cm: a=5, b=2, c=-4 -> 21.10567237858915
    const h21 = triadValue(5, 2, -4);
    try testing.expect(@abs(Q.toFloat(h21.v) - 21.10567237858915) < 1e-12);
}

test "triad sign convention" {
    const k = lookupByName("Electron Magnetic Moment (μ_e)") orelse return error.NotFound;
    try testing.expectEqual(@as(i8, -1), k.sign);
    const signed = triadSigned(k);
    try testing.expect(Q.toFloat(signed.v) < 0);
    try testing.expect(@abs(Q.toFloat(signed.v) - (-9.212043261334205e-24)) /
        9.2847647043e-24 < 1e-12);
}

test "triad underflow reporting" {
    // Planck Time (a=-214, b=-88, c=-208): every term is below 2^-128.
    const pt = triadValue(-214, -88, -208);
    try testing.expect(pt.underflow);
    try testing.expect(Q.q128Eq(pt.v, Q.Q_ZERO));
}

test "fit recovers known triple" {
    // 21cm: O(5, 2, -4) = 21.10567 — the fitter should land on it exactly.
    const r = fit(21.10567237858915, 8);
    try testing.expectEqual(@as(i32, 5), r.a);
    try testing.expectEqual(@as(i32, 2), r.b);
    try testing.expectEqual(@as(i32, -4), r.c);
    try testing.expect(r.rel_err < 1e-9);
}

test "lookup" {
    try testing.expect(lookupByName("Hydrogen Line Wavelength (21cm)") != null);
    try testing.expect(lookupBySubstring("higgs vacuum") != null);
    try testing.expect(lookupByName("no such constant") == null);
}
