// License: CC BY-NC-SA 4.0

//! lattice_decoherence.zig — stochastic pure-dephasing on the qubit lattice,
//! plus the falsifiable shell-shield experiment.
//!
//! Model (quantum-trajectory style): each step evolves the state by U(tau),
//! then applies an exact random phase from {+1,-1,+i,-i} — the framework's
//! own 90-degree-rotation group, no trig — to a rate-gamma fraction of the
//! *exposed* sites. A seeded splitmix64 makes every run reproducible.
//!
//! The experiment the transcript asks for: the environment acts on the
//! boundary. When the shell couples weakly (t_shell = j) and carries barrier
//! V_shell, perturbations injected on shell sites must leak through the
//! barrier to reach the interior. If the shell-shield claim holds IN MODEL,
//! interior coherence retention rises with V_shell; if it is flat, the claim
//! is refuted in-model. The numbers are filed verbatim either way.
//!
//! Honest scope: this is a stochastic unraveling of a pure-dephasing
//! channel, not a full Lindblad master equation over the 4096-dimensional
//! density operator (16.7M complex entries). The trajectory ensemble is the
//! standard computable proxy; the limitation is on record.

const std = @import("std");
const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");
const ham = @import("lattice_hamiltonian.zig");
const evo = @import("lattice_evolution.zig");

const Q128 = fixed.Q128;
const Cx = state.Complex;

pub const Rng = struct {
    s: u64,
    pub fn init(seed: u64) Rng {
        return .{ .s = seed };
    }
    pub fn next(self: *Rng) u64 {
        self.s +%= 0x9E3779B97F4A7C15;
        var z = self.s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
};

/// Apply one exact phase kick to site i: phase chosen by 2 bits.
fn kick(psi: []Cx, i: usize, bits: u2) void {
    psi[i] = switch (bits) {
        0 => psi[i],
        1 => psi[i].neg(),
        2 => .{ .re = psi[i].im.neg(), .im = psi[i].re }, // *i
        3 => .{ .re = psi[i].im, .im = psi[i].re.neg() }, // *(-i)
    };
}

/// One trajectory step: propagate then kick `kicks` pseudo-random sites in
/// `mask` (mask[i] = site is exposed to the environment).
pub fn step(h: ham.Hamiltonian, psi: []Cx, out: []Cx, tau: Q128, order: usize, scratch: []Cx, rng: *Rng, mask: []const bool, kicks: usize) void {
    evo.propagate(h, psi, out, tau, order, scratch);
    for (0..kicks) |_| {
        // rejection-sample a masked site — bounded tries, deterministic stream
        var tries: usize = 0;
        while (tries < 64) : (tries += 1) {
            const i: usize = @intCast(rng.next() % @as(u64, @intCast(h.n)));
            if (mask[i]) {
                kick(out, i, @truncate(rng.next()));
                break;
            }
        }
    }
}

/// Coherence metric: |<psi_clean(t)|psi_kicked(t)>|^2 per trajectory —
/// identical unitary dynamics on both arms, kicks the only difference, so
/// free-evolution decay cancels and what remains is pure dephasing damage.
pub const Experiment = struct {
    shielded_fidelity: Q128,
    unshielded_fidelity: Q128,
    v_shell: Q128,
    trajectories: usize,
};

/// The shell-shield experiment. `runs` trajectories, `steps` each.
///   shielded  — kicks land on shell sites only; they reach the interior
///               only through the coupling t_shell = j past the barrier.
///   unshielded — kicks land directly on interior surface sites (any coord
///               0 or 14), same count: the no-shell baseline.
/// Fidelity 1 = the kicks did nothing; the filing is the pair of numbers.
pub fn shellShieldExperiment(
    alloc: std.mem.Allocator,
    v_shell: Q128,
    t_shell: Q128,
    runs: usize,
    steps: usize,
    kicks_per_step: usize,
    tau: Q128,
    seed: u64,
) !Experiment {
    var h = ham.Hamiltonian.canonical(Q128.fromInteger(1), v_shell);
    h.t_shell = t_shell;

    const n = h.n;
    const psi0 = try alloc.alloc(Cx, n);
    defer alloc.free(psi0);
    const clean = try alloc.alloc(Cx, n);
    defer alloc.free(clean);
    const kicked = try alloc.alloc(Cx, n);
    defer alloc.free(kicked);
    const scratch = try alloc.alloc(Cx, 5 * n);
    defer alloc.free(scratch);
    const shell_mask = try alloc.alloc(bool, n);
    defer alloc.free(shell_mask);
    const surf_mask = try alloc.alloc(bool, n);
    defer alloc.free(surf_mask);

    for (0..n) |i| {
        shell_mask[i] = h.isShell(i);
        const c = h.coords(i);
        surf_mask[i] = !shell_mask[i] and (c.x == 0 or c.x == 14 or c.y == 0 or c.y == 14 or c.z == 0 or c.z == 14);
        psi0[i] = Cx.zero;
    }
    const half = try (try Q128.fromRatio(1, 2)).sqrt();
    psi0[h.idx(4, 4, 4)] = Cx.fromReal(half);
    psi0[h.idx(10, 10, 10)] = Cx.fromReal(half);

    const order = evo.neededOrder(h, tau, @divTrunc(fixed.Scale, 1 << 64));
    var rng = Rng.init(seed);

    var acc_shield = Q128.zero;
    var acc_unshield = Q128.zero;
    for (0..runs) |_| {
        var arm: usize = 0;
        while (arm < 2) : (arm += 1) {
            @memcpy(clean, psi0);
            @memcpy(kicked, psi0);
            const mask = if (arm == 0) shell_mask else surf_mask;
            for (0..steps) |_| {
                evo.propagate(h, clean, scratch[0..n], tau, order, scratch[n..]);
                @memcpy(clean, scratch[0..n]);
                step(h, kicked, scratch[0..n], tau, order, scratch[n..], &rng, mask, kicks_per_step);
                @memcpy(kicked, scratch[0..n]);
            }
            const fid = h.inner(clean, kicked).normSquared();
            if (arm == 0) acc_shield = acc_shield.add(fid) else acc_unshield = acc_unshield.add(fid);
        }
    }
    const runs_q = Q128.fromInteger(@intCast(runs));
    return .{
        .shielded_fidelity = try acc_shield.div(runs_q),
        .unshielded_fidelity = try acc_unshield.div(runs_q),
        .v_shell = v_shell,
        .trajectories = runs,
    };
}

test "seed determinism: identical seeds give identical trajectories" {
    const h = ham.Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    const n = h.n;
    var rng_a = Rng.init(42);
    var rng_b = Rng.init(42);
    const psi = try std.testing.allocator.alloc(Cx, n);
    defer std.testing.allocator.free(psi);
    const out_a = try std.testing.allocator.alloc(Cx, n);
    defer std.testing.allocator.free(out_a);
    const out_b = try std.testing.allocator.alloc(Cx, n);
    defer std.testing.allocator.free(out_b);
    const scratch = try std.testing.allocator.alloc(Cx, 4 * n);
    defer std.testing.allocator.free(scratch);
    const mask = try std.testing.allocator.alloc(bool, n);
    defer std.testing.allocator.free(mask);
    for (0..n) |i| {
        psi[i] = if (i == 7) Cx.one else Cx.zero;
        mask[i] = true;
    }
    const tau = try Q128.fromRatio(1, 16);
    const order = evo.neededOrder(h, tau, @divTrunc(fixed.Scale, 1 << 64));
    step(h, psi, out_a, tau, order, scratch, &rng_a, mask, 8);
    step(h, psi, out_b, tau, order, scratch, &rng_b, mask, 8);
    for (0..n) |i| {
        try std.testing.expectEqual(out_a[i].re.raw, out_b[i].re.raw);
        try std.testing.expectEqual(out_a[i].im.raw, out_b[i].im.raw);
    }
}

test "zero kicks preserve coherence within the evolution bound" {
    const r = try shellShieldExperiment(std.testing.allocator, Q128.fromInteger(10), Q128.fromInteger(0), 2, 4, 0, try Q128.fromRatio(1, 16), 7);
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 24);
    try std.testing.expect(r.shielded_fidelity.raw > fixed.Scale - tol);
    try std.testing.expect(r.unshielded_fidelity.raw > fixed.Scale - tol);
}

test "the shell-shield experiment runs and returns finite fidelities" {
    // kicks_per_step > 0: both arms decohere; the filing is the pair of numbers.
    const r = try shellShieldExperiment(std.testing.allocator, Q128.fromInteger(10), Q128.fromInteger(0), 4, 6, 3, try Q128.fromRatio(1, 16), 11);
    try std.testing.expect(r.shielded_fidelity.raw >= 0);
    try std.testing.expect(r.unshielded_fidelity.raw >= 0);
    // shielded arm: kicks on decoupled shell sites (t_shell=0) cannot reach
    // the interior at all — fidelity must stay at the noiseless bound.
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 24);
    try std.testing.expect(r.shielded_fidelity.raw > fixed.Scale - tol);
}
