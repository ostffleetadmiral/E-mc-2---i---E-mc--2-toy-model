// License: CC BY-NC-SA 4.0

//! lattice_hamiltonian.zig — tight-binding Hamiltonian on the qubit lattice.
//!
//! Geometry (canon, completion_10d): interior = 15^3 sites (coords 0..14 per
//! axis), shell = the three +1 faces where any coord == 15 — 16^3-15^3 = 721
//! shell sites. The transcript's "only three sides of the fifteen shale are
//! covered by a plus one" is exactly this one-sided shell.
//!
//! Dynamics:  H psi[i] = V[i]*psi[i] - hop(i,j) * sum_j psi[j]
//!   - interior-interior edges hop = t
//!   - any edge incident on a shell site hop = t_shell (0 => the shell does
//!     NOT couple — the literal hypothesis under test)
//!   - shell sites sit at V = v_shell (the barrier)
//!   - optional interior barrier plane for tunneling tests
//!
//! Matrix-free operator application only — the honest statement is "the
//! Hamiltonian is the operator", not a stored 4096x4096 matrix.
//!
//! Integer-only: Q128.128 throughout, no trig, no floats. Spectral bounds are
//! Gershgorin (row-sum) bounds — conservative, used by the Chebyshev
//! propagator in lattice_evolution.zig.

const std = @import("std");
const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");

const Q128 = fixed.Q128;
const Cx = state.Complex;

pub const Coords = struct { x: usize, y: usize, z: usize };

/// Optional interior barrier: adds `height` to V on the plane coord[axis] == plane.
pub const Barrier = struct { axis: u8, plane: usize, height: Q128 };

pub const Hamiltonian = struct {
    nx: usize,
    ny: usize,
    nz: usize,
    n: usize,
    t: Q128,
    v_interior: Q128,
    v_shell: Q128,
    t_shell: Q128,
    barrier: ?Barrier = null,

    pub fn init(nx: usize, ny: usize, nz: usize, t: Q128, v_interior: Q128, v_shell: Q128, t_shell: Q128) Hamiltonian {
        return .{ .nx = nx, .ny = ny, .nz = nz, .n = nx * ny * nz, .t = t, .v_interior = v_interior, .v_shell = v_shell, .t_shell = t_shell };
    }

    /// The canonical single-qubit lattice: 16^3, shell = 721 sites.
    pub fn canonical(t: Q128, v_shell: Q128) Hamiltonian {
        return init(16, 16, 16, t, Q128.zero, v_shell, Q128.zero);
    }

    pub fn idx(self: Hamiltonian, x: usize, y: usize, z: usize) usize {
        return x + self.nx * (y + self.ny * z);
    }

    pub fn coords(self: Hamiltonian, i: usize) Coords {
        const z = i / (self.nx * self.ny);
        const rem = i - z * self.nx * self.ny;
        const y = rem / self.nx;
        return .{ .x = rem - y * self.nx, .y = y, .z = z };
    }

    /// Shell = any coord on the +1 face of its axis.
    pub fn isShell(self: Hamiltonian, i: usize) bool {
        const c = self.coords(i);
        return c.x == self.nx - 1 or c.y == self.ny - 1 or c.z == self.nz - 1;
    }

    fn potential(self: Hamiltonian, i: usize) Q128 {
        var v = if (self.isShell(i)) self.v_shell else self.v_interior;
        if (self.barrier) |b| {
            const c = self.coords(i);
            const coord = switch (b.axis) {
                0 => c.x,
                1 => c.y,
                else => c.z,
            };
            if (coord == b.plane) v = v.add(b.height);
        }
        return v;
    }

    /// out = H psi. Scratch-free; caller-owned buffers must not alias.
    pub fn apply(self: Hamiltonian, psi: []const Cx, out: []Cx) void {
        for (0..self.n) |i| {
            const c = self.coords(i);
            const shell_i = self.isShell(i);
            var acc = psi[i].scale(self.potential(i));
            // 6 neighbors; hop depends on whether the edge touches shell.
            const hop_edge = struct {
                fn f(h: Hamiltonian, s_i: bool, j: usize) Q128 {
                    return if (s_i or h.isShell(j)) h.t_shell else h.t;
                }
            }.f;
            if (c.x > 0) acc = acc.sub(psi[i - 1].scale(hop_edge(self, shell_i, i - 1)));
            if (c.x < self.nx - 1) acc = acc.sub(psi[i + 1].scale(hop_edge(self, shell_i, i + 1)));
            if (c.y > 0) acc = acc.sub(psi[i - self.nx].scale(hop_edge(self, shell_i, i - self.nx)));
            if (c.y < self.ny - 1) acc = acc.sub(psi[i + self.nx].scale(hop_edge(self, shell_i, i + self.nx)));
            if (c.z > 0) acc = acc.sub(psi[i - self.nx * self.ny].scale(hop_edge(self, shell_i, i - self.nx * self.ny)));
            if (c.z < self.nz - 1) acc = acc.sub(psi[i + self.nx * self.ny].scale(hop_edge(self, shell_i, i + self.nx * self.ny)));
            out[i] = acc;
        }
    }

    /// <a|b> = sum conj(a_i) b_i.
    pub fn inner(self: Hamiltonian, a: []const Cx, b: []const Cx) Cx {
        var acc = Cx.zero;
        for (0..self.n) |i| acc = acc.add(a[i].conj().mul(b[i]));
        return acc;
    }

    pub fn normSq(self: Hamiltonian, psi: []const Cx) Q128 {
        var acc = Q128.zero;
        for (0..self.n) |i| acc = acc.add(psi[i].normSquared());
        return acc;
    }

    /// <psi|H|psi> — real for Hermitian H; imaginary part stays on record via inner().
    pub fn expectation(self: Hamiltonian, psi: []const Cx, scratch: []Cx) Q128 {
        self.apply(psi, scratch);
        return self.inner(psi, scratch).re;
    }

    /// Gershgorin bounds: |off-diagonal| row sum <= 6*max(|t|,|t_shell|).
    pub fn spectralBounds(self: Hamiltonian) struct { lo: Q128, hi: Q128 } {
        const hmax = if (self.t.abs().raw > self.t_shell.abs().raw) self.t.abs() else self.t_shell.abs();
        const width = hmax.mul(Q128.fromInteger(6));
        var vmin = self.v_interior;
        var vmax = self.v_interior;
        if (self.v_shell.cmp(vmin) < 0) vmin = self.v_shell;
        if (self.v_shell.cmp(vmax) > 0) vmax = self.v_shell;
        if (self.barrier) |b| {
            const vb = self.v_interior.add(b.height);
            if (vb.cmp(vmin) < 0) vmin = vb;
            if (vb.cmp(vmax) > 0) vmax = vb;
        }
        return .{ .lo = vmin.sub(width), .hi = vmax.add(width) };
    }
};

test "canonical shell count is 721 = 16^3 - 15^3" {
    const h = Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var shells: usize = 0;
    for (0..h.n) |i| shells += @intFromBool(h.isShell(i));
    try std.testing.expectEqual(@as(usize, 4096), h.n);
    try std.testing.expectEqual(@as(usize, 721), shells);
}

test "zero Hamiltonian annihilates every state" {
    const h = Hamiltonian.init(4, 4, 4, Q128.zero, Q128.zero, Q128.zero, Q128.zero);
    var psi = [_]Cx{Cx.one} ** 64;
    var out = [_]Cx{Cx.one} ** 64;
    h.apply(psi[0..], out[0..]);
    for (out) |a| try std.testing.expectEqual(@as(fixed.Raw, 0), a.re.raw);
}

test "basis-state action is exact on a fully-interior site" {
    const one = Q128.fromInteger(1);
    const h = Hamiltonian.canonical(one, Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var out: [4096]Cx = undefined;
    for (&psi) |*a| a.* = Cx.zero;
    const center = h.idx(7, 7, 7);
    psi[center] = Cx.one;
    h.apply(psi[0..], out[0..]);
    try std.testing.expectEqual(@as(fixed.Raw, 0), out[center].re.raw); // v_interior = 0
    const nbrs = [_]usize{ h.idx(6, 7, 7), h.idx(8, 7, 7), h.idx(7, 6, 7), h.idx(7, 8, 7), h.idx(7, 7, 6), h.idx(7, 7, 8) };
    for (nbrs) |j| try std.testing.expectEqual(-fixed.Scale, out[j].re.raw); // -t
}

test "non-coupling shell leaks nothing in either direction" {
    const h = Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var out: [4096]Cx = undefined;
    for (&psi) |*a| a.* = Cx.zero;
    // excite a shell site: interior must stay exactly zero
    const s = h.idx(15, 7, 7);
    psi[s] = Cx.one;
    h.apply(psi[0..], out[0..]);
    try std.testing.expectEqual(@as(fixed.Raw, 10 * fixed.Scale), out[s].re.raw); // V_shell
    try std.testing.expectEqual(@as(fixed.Raw, 0), out[h.idx(14, 7, 7)].re.raw);
    // excite the adjacent interior site: shell must stay exactly zero
    for (&psi) |*a| a.* = Cx.zero;
    psi[h.idx(14, 7, 7)] = Cx.one;
    h.apply(psi[0..], out[0..]);
    try std.testing.expectEqual(@as(fixed.Raw, 0), out[s].re.raw);
}

test "Hamiltonian is exactly Hermitian: <psi|H phi> = conj(<phi|H psi>)" {
    const h = Hamiltonian.canonical(Q128.fromInteger(1), Q128.fromInteger(10));
    var psi: [4096]Cx = undefined;
    var phi: [4096]Cx = undefined;
    var hs: [4096]Cx = undefined;
    for (0..4096) |i| {
        psi[i] = .{ .re = try Q128.fromRatio(@intCast(i % 7 + 1), @intCast(i % 5 + 3)), .im = try Q128.fromRatio(@intCast(i % 3 + 1), @intCast(i % 4 + 2)) };
        phi[i] = .{ .re = try Q128.fromRatio(@intCast(i % 4 + 1), @intCast(i % 6 + 2)), .im = try Q128.fromRatio(@intCast(i % 5 + 1), @intCast(i % 7 + 3)) };
    }
    h.apply(phi[0..], hs[0..]);
    const left = h.inner(psi[0..], hs[0..]); // <psi|H phi>
    h.apply(psi[0..], hs[0..]);
    const right = h.inner(phi[0..], hs[0..]).conj(); // conj(<phi|H psi>)
    // H is real-symmetric so the identity is exact in exact arithmetic; the
    // two sides sum different products so RNE rounding diverges in low bits —
    // bounded tolerance, not exact equality.
    const tol: fixed.Raw = @divTrunc(fixed.Scale, 1 << 40);
    const dre = left.re.sub(right.re).abs().raw;
    const dim = left.im.sub(right.im).abs().raw;
    try std.testing.expect(dre < tol);
    try std.testing.expect(dim < tol);
}
