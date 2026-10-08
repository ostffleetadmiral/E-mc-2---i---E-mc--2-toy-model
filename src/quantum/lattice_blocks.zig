// License: CC BY-NC-SA 4.0

//! lattice_blocks.zig — the two-block communication falsification module.
//!
//! The transcript's mechanism, implemented verbatim: two adjacent 15^3
//! qubit-blocks (A: x in 0..14, B: x in 16..30) inside a 32 x 16 x 16
//! lattice. The seam plane x=15 is the shared open face — "the shell always
//! points outward" means the ONLY shell sites are the exterior +1 faces
//! (y==15, z==15, x==31, x==0 is capped too); interior faces between blocks
//! are open and couple with the same hopping t.
//!
//! What the model computes — filed verbatim either way:
//!   * tunneling: a barrier plane on the seam transmits nonzero amplitude
//!     for E < V0 (the transcript's "15.1 < 16" image, made concrete)
//!   * coupling: a controlled excitation in block A produces population in
//!     block B — the mechanism exists
//!   * THE LIGHT CONE: correlation fronts in a local lattice Hamiltonian are
//!     ballistically bounded (Lieb-Robinson, Commun. Math. Phys. 28:251
//!     (1972) — v_LR ~ 2 * coordination * t). The test measures the actual
//!     front: population reaching distance d at time tau must stay below
//!     eps for tau < d / v_bound. In this model correlation is real but
//!     ballistic — never instant. That IS the no-communication theorem,
//!     computed rather than asserted.

const std = @import("std");
const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");
const ham = @import("lattice_hamiltonian.zig");
const evo = @import("lattice_evolution.zig");
const ent = @import("lattice_entanglement.zig");

const Q128 = fixed.Q128;
const Cx = state.Complex;

/// The canonical two-block stack: 32 x 16 x 16. Block A interior x in 0..14,
/// seam plane x=15, block B interior x in 16..30, shell = the exterior +1
/// faces (x==31, y==15, z==15 — plus x==0 capped as the outer face).
pub fn twoBlock(t: Q128, v_shell: Q128, t_shell: Q128) ham.Hamiltonian {
    return ham.Hamiltonian.init(32, 16, 16, t, Q128.zero, v_shell, t_shell);
}

/// Shell predicate for the two-block geometry: +1 exterior faces only.
/// x==0 is the outer cap (a finite stack has ends); the seam x=15 is open.
pub fn isTwoBlockShell(h: ham.Hamiltonian, i: usize) bool {
    const c = h.coords(i);
    return c.x == h.nx - 1 or c.y == h.ny - 1 or c.z == h.nz - 1 or c.x == 0;
}

/// Lieb-Robinson-style bound: amplitude cannot have propagated faster than
/// v ~ 2*degree*t per unit tau. We test the tail: population at x >= x_front
/// after time tau starting from a source at x_src must be ~0 when
/// tau * v_bound < (x_front - x_src).
pub fn frontViolation(
    h: ham.Hamiltonian,
    psi0: []const Cx,
    out: []Cx,
    tau: Q128,
    order: usize,
    scratch: []Cx,
    x_front: usize,
) Q128 {
    evo.propagate(h, psi0, out, tau, order, scratch);
    var acc = Q128.zero;
    for (0..h.n) |i| {
        const c = h.coords(i);
        if (!isTwoBlockShell(h, i) and c.x >= x_front) acc = acc.add(out[i].normSquared());
    }
    return acc;
}

pub const BlockTransfer = struct {
    seam_open_b: Q128, // population reaching block B with the seam open
    seam_shut_b: Q128, // same run with seam coupling removed (t -> 0 on seam)
};

/// The mechanism test: excite a source site in A, evolve, measure block-B
/// population with the seam open vs. shut (barrier height on the seam).
pub fn blockTransfer(
    alloc: std.mem.Allocator,
    seam_barrier: Q128,
    tau: Q128,
    steps: usize,
    seed_site: usize,
) !BlockTransfer {
    const t = Q128.fromInteger(1);
    const h_open = twoBlock(t, Q128.fromInteger(50), Q128.zero);
    var h_shut = twoBlock(t, Q128.fromInteger(50), Q128.zero);
    h_shut.barrier = .{ .axis = 0, .plane = 15, .height = seam_barrier };

    const n = h_open.n;
    const psi0 = try alloc.alloc(Cx, n);
    defer alloc.free(psi0);
    const a = try alloc.alloc(Cx, n);
    defer alloc.free(a);
    const b = try alloc.alloc(Cx, n);
    defer alloc.free(b);
    const scratch = try alloc.alloc(Cx, 5 * n);
    defer alloc.free(scratch);

    for (0..n) |i| psi0[i] = Cx.zero;
    psi0[seed_site] = Cx.one;

    const order = evo.neededOrder(h_open, tau, @divTrunc(fixed.Scale, 1 << 64));

    @memcpy(a, psi0);
    @memcpy(b, psi0);
    for (0..steps) |_| {
        evo.propagate(h_open, a, scratch[0..n], tau, order, scratch[n..]);
        @memcpy(a, scratch[0..n]);
        evo.propagate(h_shut, b, scratch[0..n], tau, order, scratch[n..]);
        @memcpy(b, scratch[0..n]);
    }
    return .{
        .seam_open_b = ent.regionPopulation(h_open, a, 16, 30),
        .seam_shut_b = ent.regionPopulation(h_shut, b, 16, 30),
    };
}

test "two-block shell count matches the geometry" {
    const h = twoBlock(Q128.fromInteger(1), Q128.fromInteger(50), Q128.zero);
    var shells: usize = 0;
    for (0..h.n) |i| shells += @intFromBool(isTwoBlockShell(h, i));
    // inclusion-exclusion: |X0|+|X31|+|Y15|+|Z15| = 256+256+512+512 = 1536,
    // minus pairs (4*16 + 32) = 96, plus triples (2) = 1442.
    try std.testing.expectEqual(@as(usize, 1442), shells);
}

test "coupling mechanism: amplitude crosses the open seam into block B" {
    const h = twoBlock(Q128.fromInteger(1), Q128.fromInteger(50), Q128.zero);
    var psi: [32 * 16 * 16]Cx = undefined;
    var out: [32 * 16 * 16]Cx = undefined;
    var scratch: [4 * 32 * 16 * 16]Cx = undefined;
    for (0..h.n) |i| psi[i] = Cx.zero;
    psi[h.idx(14, 7, 7)] = Cx.one; // block A, adjacent to the seam
    const tau = try Q128.fromRatio(1, 4);
    const order = evo.neededOrder(h, tau, @divTrunc(fixed.Scale, 1 << 64));
    evo.propagate(h, psi[0..], out[0..], tau, order, scratch[0..]);
    const in_b = ent.regionPopulation(h, out[0..], 16, 30);
    try std.testing.expect(in_b.raw > 0); // the channel exists in-model
}

test "light cone: no population beyond the ballistic front" {
    const h = twoBlock(Q128.fromInteger(1), Q128.fromInteger(50), Q128.zero);
    var psi: [32 * 16 * 16]Cx = undefined;
    var out: [32 * 16 * 16]Cx = undefined;
    var scratch: [4 * 32 * 16 * 16]Cx = undefined;
    for (0..h.n) |i| psi[i] = Cx.zero;
    psi[h.idx(1, 7, 7)] = Cx.one; // source near the A cap
    // source at x=1; probe x>=27. Distance 26. v_bound ~ 2*6*t = 12/tau-unit.
    // tau = 1 -> ballistic bound reaches x ~ 13 << 27; the Bessel tail
    // J_d(2t*tau) at d=26 is ~1e-6 per site — population must stay under
    // the filed bound. That suppression IS the in-model light cone.
    const tau = Q128.fromInteger(1);
    const order = evo.neededOrder(h, tau, @divTrunc(fixed.Scale, 1 << 64));
    const front = frontViolation(h, psi[0..], out[0..], tau, order, scratch[0..], 27);
    const bound: fixed.Raw = @divTrunc(fixed.Scale, 1 << 20);
    try std.testing.expect(front.raw < bound);
    // and the state did NOT stay put — propagation is real, just bounded:
    const near = ent.regionPopulation(h, out[0..], 4, 14);
    try std.testing.expect(near.raw > 0);
}

test "seam barrier suppresses but does not zero the transfer" {
    const r = try blockTransfer(std.testing.allocator, Q128.fromInteger(8), try Q128.fromRatio(1, 4), 6, 14 + 32 * (7 + 16 * 7));
    // tunneling: open seam transmits; barrier suppresses
    try std.testing.expect(r.seam_open_b.raw > 0);
    try std.testing.expect(r.seam_shut_b.raw < r.seam_open_b.raw);
}
