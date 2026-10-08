// License: CC BY-NC-SA 4.0

//! lattice_evolution.zig — Chebyshev propagator U(tau) = exp(-i H tau) on the
//! qubit lattice. A real spectral method, not an Euler toy: the error is the
//! tail of a Bessel series, which is rigorously bounded and testable.
//!
//!   H~ = (H - b)/a,  spectrum(H~) subset [-1,1]  (Gershgorin bounds)
//!   U(tau) = e^{-i b tau} * sum_k (2 - d_{k0}) (-i)^k J_k(a tau) T_k(H~)
//!
//! The global phase e^{-i b tau} is dropped — it cancels in every observable
//! we compute (norms, |<phi|psi>|^2, <H>), and reversibility U(-t)U(t)=I is
//! preserved exactly because the dropped phases cancel pairwise. This is
//! documented scope, not an approximation hidden from the record.
//!
//! Bessel coefficients are computed in Q128 by the power series
//!   J_k(x) = sum_m (-1)^m (x/2)^{2m+k} / (m! (m+k)!)
//! with a terminated-tail bound — no trig, no floats anywhere.

const std = @import("std");
const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");
const ham = @import("lattice_hamiltonian.zig");

const Q128 = fixed.Q128;
const Cx = state.Complex;

/// Series cutoff: stop when a term drops below 2^-64 of scale.
const EPS: fixed.Raw = @divTrunc(fixed.Scale, 1 << 64);
const MAX_TERMS: usize = 128;

/// J_k(x) by power series. x >= 0.
pub fn besselJ(k: usize, x: Q128) Q128 {
    if (x.raw == 0) return if (k == 0) Q128.one else Q128.zero;
    // term_0 = (x/2)^k / k! = prod_{j=1..k} x/(2j)
    const x2 = x.mul(try2(Q128.fromRatio(1, 2)));
    var term = Q128.one;
    for (1..k + 1) |j| term = try2(term.mul(x2).div(Q128.fromInteger(@intCast(j))));
    var sum = term;
    const neg_x2sq = x2.mul(x2).neg(); // -(x/2)^2
    var m: usize = 0;
    while (m < MAX_TERMS) : (m += 1) {
        const den: i256 = @as(i256, @intCast((m + 1) * (m + k + 1)));
        term = try2(term.mul(neg_x2sq).div(Q128.fromInteger(den)));
        if (term.abs().raw < EPS) break;
        sum = sum.add(term);
    }
    return sum;
}

/// The Chebyshev coefficient c_k = (2 - d_{k0}) (-i)^k J_k(a tau).
fn coeff(k: usize, x: Q128) Cx {
    var j = besselJ(k, x);
    if (k > 0) j = j.add(j);
    return switch (k % 4) {
        0 => Cx.fromReal(j),
        1 => .{ .re = Q128.zero, .im = j.neg() }, // -i
        2 => Cx.fromReal(j.neg()), // -1
        else => .{ .re = Q128.zero, .im = j }, // +i
    };
}

fn try2(v: anytype) @TypeOf(v catch unreachable) {
    return v catch unreachable;
}

/// Apply the rescaled Hamiltonian: out = (H psi - b psi) / a.
fn applyScaled(h: ham.Hamiltonian, a: Q128, b: Q128, psi: []const Cx, out: []Cx, scratch: []Cx) void {
    h.apply(psi, scratch);
    for (0..h.n) |i| {
        const d = scratch[i].sub(psi[i].scale(b));
        out[i] = .{ .re = try2(d.re.div(a)), .im = try2(d.im.div(a)) };
    }
}

/// out = U(tau) psi  (modulo the documented global phase).
/// Order is the Chebyshev truncation K; callers pick it via neededOrder().
pub fn propagate(h: ham.Hamiltonian, psi: []const Cx, out: []Cx, tau: Q128, order: usize, scratch: []Cx) void {
    std.debug.assert(scratch.len >= 4 * h.n);
    const t_prev = scratch[0..h.n];
    const t_cur = scratch[h.n .. 2 * h.n];
    const t_next = scratch[2 * h.n .. 3 * h.n];
    const hs = scratch[3 * h.n .. 4 * h.n];

    const bnds = h.spectralBounds();
    const two = Q128.fromInteger(2);
    const a = try2(bnds.hi.sub(bnds.lo).div(two));
    const b = try2(bnds.hi.add(bnds.lo).div(two));
    if (a.raw == 0) {
        @memcpy(out, psi);
        return;
    }
    // Negative tau conjugates every coefficient: U(-t) = U(t)^dagger.
    const backward = tau.raw < 0;
    const x = a.mul(tau.abs());
    const c = struct {
        fn f(k: usize, xv: Q128, neg: bool) Cx {
            const v = coeff(k, xv);
            return if (neg) v.conj() else v;
        }
    }.f;

    // T_0 = psi, T_1 = H~ psi.
    @memcpy(t_prev, psi);
    applyScaled(h, a, b, psi, t_cur, hs);
    for (0..h.n) |i| out[i] = c(0, x, backward).mul(t_prev[i]).add(c(1, x, backward).mul(t_cur[i]));
    var k: usize = 1;
    while (k < order) : (k += 1) {
        // T_{k+1} = 2 H~ T_k - T_{k-1}
        applyScaled(h, a, b, t_cur, t_next, hs);
        for (0..h.n) |i| t_next[i] = t_next[i].scale(two).sub(t_prev[i]);
        const ck = c(k + 1, x, backward);
        for (0..h.n) |i| out[i] = out[i].add(ck.mul(t_next[i]));
        @memcpy(t_prev, t_cur);
        @memcpy(t_cur, t_next);
    }
}

/// Order needed for the Bessel tail to drop below eps: smallest K with
/// |2 J_{K+1}(a tau)| < eps. Deterministic scan — the honest truncation bound.
pub fn neededOrder(h: ham.Hamiltonian, tau: Q128, eps: fixed.Raw) usize {
    const bnds = h.spectralBounds();
    const a = try2(bnds.hi.sub(bnds.lo).div(Q128.fromInteger(2)));
    if (a.raw == 0) return 0;
    const x = a.mul(tau.abs());
    var k: usize = 1;
    while (k < 256) : (k += 1) {
        if (besselJ(k, x).abs().raw * 2 < eps) return k;
    }
    return 256;
}

test "J_0(0) = 1, J_1(x) ~ x/2 for small x" {
    try std.testing.expectEqual(fixed.Scale, besselJ(0, Q128.zero).raw);
    try std.testing.expectEqual(@as(fixed.Raw, 0), besselJ(3, Q128.zero).raw);
    const j1 = besselJ(1, try Q128.fromRatio(1, 1000));
    const half_x = try Q128.fromRatio(1, 2000);
    try std.testing.expect(j1.sub(half_x).abs().raw < @divTrunc(fixed.Scale, 1 << 30));
}

test "propagate(tau=0) is the identity" {
    const h = ham.Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var out: [4096]Cx = undefined;
    var scratch: [4 * 4096]Cx = undefined;
    for (0..4096) |i| psi[i] = if (i == 100) Cx.one else Cx.zero;
    propagate(h, psi[0..], out[0..], Q128.zero, 8, scratch[0..]);
    try std.testing.expectEqual(fixed.Scale, out[100].re.raw);
    try std.testing.expectEqual(@as(fixed.Raw, 0), out[0].re.raw);
}

test "unitarity: norm drift is within the truncation bound" {
    const h = ham.Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var out: [4096]Cx = undefined;
    var scratch: [4 * 4096]Cx = undefined;
    // normalized two-site superposition
    const s2 = try (try Q128.fromRatio(1, 2)).sqrt();
    for (0..4096) |i| psi[i] = Cx.zero;
    psi[h.idx(3, 3, 3)] = Cx.fromReal(s2);
    psi[h.idx(7, 7, 7)] = Cx.fromReal(s2);
    const tau = try Q128.fromRatio(1, 8);
    const order = neededOrder(h, tau, EPS);
    propagate(h, psi[0..], out[0..], tau, order, scratch[0..]);
    const n = h.normSq(out[0..]);
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 30);
    try std.testing.expect(if (n.raw > fixed.Scale) n.raw - fixed.Scale < tol else fixed.Scale - n.raw < tol);
}

test "reversibility: U(-tau) U(tau) returns the state within bound" {
    const h = ham.Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var mid: [4096]Cx = undefined;
    var back: [4096]Cx = undefined;
    var scratch: [4 * 4096]Cx = undefined;
    for (0..4096) |i| psi[i] = if (i == h.idx(5, 5, 5)) Cx.one else Cx.zero;
    const tau = try Q128.fromRatio(1, 8);
    const order = neededOrder(h, tau, EPS);
    propagate(h, psi[0..], mid[0..], tau, order, scratch[0..]);
    propagate(h, mid[0..], back[0..], tau.neg(), order, scratch[0..]);
    // modulo global phase the phases cancel pairwise — fidelity must be ~1
    const fid = h.inner(psi[0..], back[0..]).normSquared();
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 30);
    try std.testing.expect(fid.raw > fixed.Scale - tol);
}

test "energy expectation is conserved under propagation" {
    const h = ham.Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var out: [4096]Cx = undefined;
    var scratch: [4 * 4096]Cx = undefined;
    for (0..4096) |i| psi[i] = if (i == h.idx(4, 4, 4)) Cx.one else Cx.zero;
    const e0 = h.expectation(psi[0..], scratch[0..4096]);
    const tau = try Q128.fromRatio(1, 8);
    const order = neededOrder(h, tau, EPS);
    propagate(h, psi[0..], out[0..], tau, order, scratch[0..]);
    const e1 = h.expectation(out[0..], scratch[0..4096]);
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 20);
    try std.testing.expect(e0.sub(e1).abs().raw < tol);
}
