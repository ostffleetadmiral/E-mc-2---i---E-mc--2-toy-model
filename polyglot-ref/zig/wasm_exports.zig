//! wasm_exports.zig - WASM i256 module exports for the FANO-1 engine.
//!
//! Compiled with: zig build-exe -target wasm32-wasi-musl -O ReleaseSmall
//! Each q128 value is passed as 4 x u64 (hi.lo, hi.hi, lo.lo, lo.hi) or via
//! pointers into linear memory. All results are bit-exact with the native
//! Zig engine.

const q = @import("q128_128.zig");

fn loadQ128(p: [*]const u64) q.q128 {
    return .{
        .hi = (@as(u128, p[0]) << 64) | p[1],
        .lo = (@as(u128, p[2]) << 64) | p[3],
    };
}

fn storeQ128(p: [*]u64, v: q.q128) void {
    p[0] = @truncate(v.hi >> 64);
    p[1] = @truncate(v.hi);
    p[2] = @truncate(v.lo >> 64);
    p[3] = @truncate(v.lo);
}

/// q128_add(a, b) -> out
export fn q128_add(out: [*]u64, a: [*]const u64, b: [*]const u64) void {
    storeQ128(out, q.q128Add(loadQ128(a), loadQ128(b)));
}

/// q128_sub(a, b) -> out
export fn q128_sub(out: [*]u64, a: [*]const u64, b: [*]const u64) void {
    storeQ128(out, q.q128Sub(loadQ128(a), loadQ128(b)));
}

/// q128_neg(a) -> out
export fn q128_neg(out: [*]u64, a: [*]const u64) void {
    storeQ128(out, q.q128Neg(loadQ128(a)));
}

/// q128_mul(a, b) -> out; overflow flag written to ovf[0]
export fn q128_mul(out: [*]u64, ovf: [*]u32, a: [*]const u64, b: [*]const u64) void {
    const r = q.q128Mul(loadQ128(a), loadQ128(b));
    storeQ128(out, r.v);
    ovf[0] = if (r.overflow) 1 else 0;
}

/// q128_inner(ux, uy, vx, vy) -> 512-bit result (8 x u64)
export fn q128_inner(out: [*]u64, ux: [*]const u64, uy: [*]const u64, vx: [*]const u64, vy: [*]const u64) void {
    const p = q.q128Inner(loadQ128(ux), loadQ128(uy), loadQ128(vx), loadQ128(vy));
    out[0] = @truncate(p.hi.hi >> 64);
    out[1] = @truncate(p.hi.hi);
    out[2] = @truncate(p.hi.lo >> 64);
    out[3] = @truncate(p.hi.lo);
    out[4] = @truncate(p.lo.hi >> 64);
    out[5] = @truncate(p.lo.hi);
    out[6] = @truncate(p.lo.lo >> 64);
    out[7] = @truncate(p.lo.lo);
}

/// q128_rot90(x, y) -> rx, ry (exact 90-degree rotation)
export fn q128_rot90(rx: [*]u64, ry: [*]u64, x: [*]const u64, y: [*]const u64) void {
    const r = q.q128Rot90(loadQ128(x), loadQ128(y));
    storeQ128(rx, r.rx);
    storeQ128(ry, r.ry);
}

/// q128_sqrt(a) -> out (Newton iteration)
export fn q128_sqrt(out: [*]u64, a: [*]const u64) void {
    storeQ128(out, q.q128Sqrt(loadQ128(a)));
}

/// q128_div(a, b) -> out (truncating)
export fn q128_div(out: [*]u64, a: [*]const u64, b: [*]const u64) void {
    storeQ128(out, q.q128Div(loadQ128(a), loadQ128(b)));
}

/// Constants: write c, c^2, c^-2, pi, phi, tolerance to out (6 x 4 u64).
export fn fano_constants(out: [*]u64) void {
    storeQ128(out + 0, q.Q_C);
    storeQ128(out + 4, q.Q_C2);
    storeQ128(out + 8, q.Q_C2_INV);
    storeQ128(out + 12, q.PI_RAW);
    storeQ128(out + 16, q.PHI_RAW);
    storeQ128(out + 20, q.TOLERANCE);
}

/// RamseyIdentity for mass = 1: forward, inverse, pivot -> out (3 complex = 24 u64)
export fn fano_ramsey_identity(out: [*]u64) void {
    const r = @import("ramsey_identity.zig").RamseyIdentity.init(q.Q_ONE);
    storeQ128(out + 0, r.energy_forward.re);
    storeQ128(out + 4, r.energy_forward.im);
    storeQ128(out + 8, r.energy_inverse.re);
    storeQ128(out + 12, r.energy_inverse.im);
    storeQ128(out + 16, r.information_pivot.re);
    storeQ128(out + 20, r.information_pivot.im);
}

/// Pivot rotation: multiply (re, im) by the pivot -> out (complex, 8 u64).
export fn fano_rotate(out: [*]u64, re: [*]const u64, im: [*]const u64) void {
    const ri = @import("ramsey_identity.zig");
    const r = ri.RamseyIdentity.init(q.Q_ONE);
    const e_in = ri.ComplexQ128{ .re = loadQ128(re), .im = loadQ128(im) };
    const e_rot = r.transformThroughPivot(e_in);
    storeQ128(out + 0, e_rot.re);
    storeQ128(out + 4, e_rot.im);
}

/// Version string.
export fn fano_version() u32 {
    return 1;
}
