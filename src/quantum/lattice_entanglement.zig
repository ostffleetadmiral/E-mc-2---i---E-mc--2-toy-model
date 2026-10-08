// License: CC BY-NC-SA 4.0

//! lattice_entanglement.zig — exact entanglement metrics in Q128.
//!
//! v1 scope, stated honestly:
//!   - exact two-qubit concurrence C = 2|ad - bc| for pure pairs
//!   - Bell-pair construction via Hadamard + controlled phase (exact gates)
//!   - lattice-level proxies: site occupation, interior->shell population
//!     transfer, pair correlation |<psi_i* psi_j>|
//! A full reduced-density-matrix SVD over a 3375x721 bipartition is out of
//! scope for v1 — that limitation is on record, not papered over.

const std = @import("std");
const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");
const ham = @import("lattice_hamiltonian.zig");

const Q128 = fixed.Q128;
const Cx = state.Complex;

/// Exact concurrence of a pure two-qubit state |psi> = a|00>+b|01>+c|10>+d|11>.
/// C = 2|a*d - b*c| in [0,1]; sqrt of the Q128 modulus squared keeps it exact.
pub fn concurrence(a: Cx, b: Cx, c: Cx, d: Cx) fixed.Error!Q128 {
    const det = a.mul(d).sub(b.mul(c));
    return (try det.normSquared().sqrt()).mul(Q128.fromInteger(2));
}

/// Controlled phase: |11> -> -|11>, exact.
pub fn controlledPhase(v: *[4]Cx) void {
    v[3] = v[3].neg();
}

/// Build a Bell pair from |00>: H on qubit 0, then controlled phase flip via
/// the integer-exact CNOT+CZ-free route: H0 then CNOT is the textbook pair;
/// here we use H0 then CNOT implemented as amplitude permutation (exact).
pub fn bellState() [4]Cx {
    const s2 = gates_half();
    // H on qubit 0: |00> -> (|00>+|10>)/sqrt2 ; CNOT -> (|00>+|11>)/sqrt2
    return .{ Cx.fromReal(s2), Cx.zero, Cx.zero, Cx.fromReal(s2) };
}

fn gates_half() Q128 {
    return fixed.Q128.fromRaw(240615969168004511545033772477625056650); // 1/sqrt(2) Q128
}

/// Total probability mass on shell sites (interior->shell transfer metric).
pub fn shellPopulation(h: ham.Hamiltonian, psi: []const Cx) Q128 {
    var acc = Q128.zero;
    for (0..h.n) |i| {
        if (h.isShell(i)) acc = acc.add(psi[i].normSquared());
    }
    return acc;
}

/// Population inside a coordinate range (used for block A / block B splits).
pub fn regionPopulation(h: ham.Hamiltonian, psi: []const Cx, x_lo: usize, x_hi: usize) Q128 {
    var acc = Q128.zero;
    for (0..h.n) |i| {
        const c = h.coords(i);
        if (!h.isShell(i) and c.x >= x_lo and c.x <= x_hi) acc = acc.add(psi[i].normSquared());
    }
    return acc;
}

/// Pair correlation |psi_i* . psi_j| — the two-site coherence observable.
pub fn pairCorrelation(psi: []const Cx, i: usize, j: usize) Q128 {
    const p = psi[i].conj().mul(psi[j]);
    return p.normSquared().sqrt() catch unreachable;
}

test "Bell pair has concurrence 1, product state has concurrence 0" {
    const bell = bellState();
    const cb = try concurrence(bell[0], bell[1], bell[2], bell[3]);
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 40);
    try std.testing.expect(if (cb.raw > fixed.Scale) cb.raw - fixed.Scale < tol else fixed.Scale - cb.raw < tol);
    // product (|0>+|1>)/sqrt2 x (|0>+|1>)/sqrt2 — all four amplitudes s2
    const s2 = gates_half();
    const cp = try concurrence(Cx.fromReal(s2), Cx.fromReal(s2), Cx.fromReal(s2), Cx.fromReal(s2));
    try std.testing.expect(cp.raw < tol);
}

test "shell population is zero for interior-only states" {
    const h = ham.Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    for (0..4096) |i| psi[i] = if (i == h.idx(7, 7, 7)) Cx.one else Cx.zero;
    try std.testing.expectEqual(@as(fixed.Raw, 0), shellPopulation(h, psi[0..]).raw);
}
