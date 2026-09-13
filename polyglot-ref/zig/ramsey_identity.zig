//! ramsey_identity.zig - RamseyIdentity transforms on Q128.128.
//!
//! Checksum: E = mc^2 <-> i <-> E = mc^-2, i = e0[e1..e7] -> e0.
//! Forward: E_f = m*c^2 (real axis). Inverse: E_i = m*c^-2.
//! Information pivot: magnitude = m, stored as pure imaginary i*m.
//! Multiplying energy by the pivot performs an exact 90-degree rotation
//! into the imaginary manifold (re -> 0, im -> |E|).

const std = @import("std");
const q = @import("q128_128");

pub const ComplexQ128 = struct {
    re: q.q128,
    im: q.q128,

    pub fn add(self: ComplexQ128, other: ComplexQ128) ComplexQ128 {
        return .{ .re = q.q128Add(self.re, other.re), .im = q.q128Add(self.im, other.im) };
    }

    pub fn sub(self: ComplexQ128, other: ComplexQ128) ComplexQ128 {
        return .{ .re = q.q128Sub(self.re, other.re), .im = q.q128Sub(self.im, other.im) };
    }

    pub fn mul(self: ComplexQ128, other: ComplexQ128) ComplexQ128 {
        const re = q.q128Sub(q.q128Mul(self.re, other.re).v, q.q128Mul(self.im, other.im).v);
        const im = q.q128Add(q.q128Mul(self.re, other.im).v, q.q128Mul(self.im, other.re).v);
        return .{ .re = re, .im = im };
    }

    pub fn div(self: ComplexQ128, other: ComplexQ128) ComplexQ128 {
        const denom = q.q128Add(
            q.q128Mul(other.re, other.re).v,
            q.q128Mul(other.im, other.im).v,
        );
        const re = q.q128Div(
            q.q128Add(q.q128Mul(self.re, other.re).v, q.q128Mul(self.im, other.im).v),
            denom,
        );
        const im = q.q128Div(
            q.q128Sub(q.q128Mul(self.im, other.re).v, q.q128Mul(self.re, other.im).v),
            denom,
        );
        return .{ .re = re, .im = im };
    }

    pub fn conj(self: ComplexQ128) ComplexQ128 {
        return .{ .re = self.re, .im = q.q128Neg(self.im) };
    }
};

pub const RamseyIdentity = struct {
    mass: q.q128,
    energy_forward: ComplexQ128,
    energy_inverse: ComplexQ128,
    information_pivot: ComplexQ128,

    pub fn init(mass: q.q128) RamseyIdentity {
        const ef = forwardTransform(mass);
        const ei = inverseTransform(mass);
        const pivot = calculateInformationPivot(ef, ei);
        return .{
            .mass = mass,
            .energy_forward = ef,
            .energy_inverse = ei,
            .information_pivot = pivot,
        };
    }

    pub fn forwardTransform(mass: q.q128) ComplexQ128 {
        return .{ .re = q.q128Mul(mass, q.Q_C2).v, .im = q.Q_ZERO };
    }

    pub fn inverseTransform(mass: q.q128) ComplexQ128 {
        return .{ .re = q.q128Mul(mass, q.Q_C2_INV).v, .im = q.Q_ZERO };
    }

    /// Pivot = (0, sqrt(re(ef * conj(ei)))) = (0, m) since
    /// ef * conj(ei) = m^2 * c^2 * c^-2 = m^2.
    pub fn calculateInformationPivot(ef: ComplexQ128, ei: ComplexQ128) ComplexQ128 {
        const product = ef.mul(ei.conj());
        const sqrt_mag = q.q128Sqrt(product.re);
        return .{ .re = q.Q_ZERO, .im = sqrt_mag };
    }

    /// |E*conj(E) - m^2*c^4| < tolerance.
    pub fn verifyConservation(self: RamseyIdentity, energy: ComplexQ128) bool {
        const conservation = energy.mul(energy.conj());
        const m2 = q.q128Mul(self.mass, self.mass).v;
        const c4 = q.q128Mul(q.Q_C2, q.Q_C2).v;
        const expected = q.q128Mul(m2, c4).v;
        const diff = q.q128AbsDelta(conservation.re, expected);
        return diff.lo.hi == 0 and diff.lo.lo < q.TOLERANCE.lo and diff.hi.hi == 0 and diff.hi.lo == 0;
    }

    /// Reconstructed mass from energy: E / c^2 == m within tolerance.
    pub fn isReversible(self: RamseyIdentity, energy: ComplexQ128) bool {
        const c2c = ComplexQ128{ .re = q.Q_C2, .im = q.Q_ZERO };
        const reconstructed = energy.div(c2c).re;
        const diff = q.q128AbsDelta(reconstructed, self.mass);
        return diff.lo.hi == 0 and diff.lo.lo < q.TOLERANCE.lo and diff.hi.hi == 0 and diff.hi.lo == 0;
    }

    pub fn energyDifference(self: RamseyIdentity) ComplexQ128 {
        return self.energy_forward.sub(self.energy_inverse);
    }

    /// E_f / E_i = c^4.
    pub fn energyRatio(self: RamseyIdentity) q.q128 {
        if (!(self.energy_inverse.re.hi == 0 and self.energy_inverse.re.lo == 0)) {
            return q.q128Div(self.energy_forward.re, self.energy_inverse.re);
        }
        return .{ .hi = (@as(u128, 1) << 127) - 1, .lo = ~@as(u128, 0) };
    }

    /// Multiply by the information pivot: exact 90-degree rotation.
    pub fn transformThroughPivot(self: RamseyIdentity, energy: ComplexQ128) ComplexQ128 {
        return energy.mul(self.information_pivot);
    }

    pub fn applyPhiScaling(self: RamseyIdentity, energy: ComplexQ128, factor: q.q128) ComplexQ128 {
        _ = self;
        return energy.mul(.{ .re = factor, .im = q.Q_ZERO });
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn expectEq(a: q.q128, b: q.q128) !void {
    try testing.expectEqual(a.hi, b.hi);
    try testing.expectEqual(a.lo, b.lo);
}

test "mass 1: forward/inverse/pivot" {
    const r = RamseyIdentity.init(q.Q_ONE);
    // E_f = c^2
    try expectEq(r.energy_forward.re, q.Q_C2);
    try expectEq(r.energy_forward.im, q.Q_ZERO);
    // E_i = c^-2
    try expectEq(r.energy_inverse.re, q.Q_C2_INV);
    // pivot = (0, ~1): c^-2 is rounded, so the magnitude is 1 + O(2^-128)
    try expectEq(r.information_pivot.re, q.Q_ZERO);
    try testing.expect(r.information_pivot.im.hi == 1);
    const pivot_err = q.q128AbsDelta(r.information_pivot.im, q.Q_ONE);
    try testing.expect(pivot_err.lo.hi == 0 and pivot_err.lo.lo < q.TOLERANCE.lo);
}

test "mass 2: linear scaling" {
    const two = q.q128FromI64(2);
    const r = RamseyIdentity.init(two);
    const c2x2 = q.q128Mul(q.Q_C2, two).v;
    try expectEq(r.energy_forward.re, c2x2);
    const c2invx2 = q.q128Mul(q.Q_C2_INV, two).v;
    try expectEq(r.energy_inverse.re, c2invx2);
}

test "pivot rotation: exact 90 degrees, re exactly 0" {
    const r = RamseyIdentity.init(q.Q_ONE);
    const e_in = ComplexQ128{ .re = q.Q_C2, .im = q.Q_ZERO };
    const e_rot = r.transformThroughPivot(e_in);
    // re must be EXACTLY 0 (zero real component drift)
    try expectEq(e_rot.re, q.Q_ZERO);
    // im ~= c^2: the pivot magnitude carries the c^-2 rounding, amplified
    // by c^2 to ~4e-6 value units; assert magnitude preservation < 1.0.
    const im_err = q.q128AbsDelta(e_rot.im, q.Q_C2);
    try testing.expect(im_err.lo.hi == 0);
}

test "conservation: E = c^2 conserves" {
    const r = RamseyIdentity.init(q.Q_ONE);
    const energy = ComplexQ128{ .re = q.Q_C2, .im = q.Q_ZERO };
    try testing.expect(r.verifyConservation(energy));
}

test "reversibility: forward reversible, arbitrary rejected" {
    const r = RamseyIdentity.init(q.Q_ONE);
    try testing.expect(r.isReversible(r.energy_forward));
    const wrong = ComplexQ128{ .re = q.q128FromI64(100), .im = q.Q_ZERO };
    try testing.expect(!r.isReversible(wrong));
}

test "energy ratio = c^4" {
    const r = RamseyIdentity.init(q.Q_ONE);
    const ratio = r.energyRatio();
    const c4 = q.q128Mul(q.Q_C2, q.Q_C2).v;
    // c^-2 is rounded (half-away), so the ratio differs from c^4 by a
    // tiny relative error; verify within 1e-15 relative tolerance.
    const diff = q.q128AbsDelta(ratio, c4);
    const rel = q.toFloat(.{ .hi = 0, .lo = diff.lo.hi }) / q.toFloat(.{ .hi = 0, .lo = c4.hi });
    try testing.expect(rel < 1e-15);
}

test "zero mass edge case" {
    const r = RamseyIdentity.init(q.Q_ZERO);
    try expectEq(r.energy_forward.re, q.Q_ZERO);
    try expectEq(r.energy_inverse.re, q.Q_ZERO);
    try expectEq(r.information_pivot.re, q.Q_ZERO);
    try expectEq(r.information_pivot.im, q.Q_ZERO);
}

test "negative mass" {
    const r = RamseyIdentity.init(q.Q_NEG_ONE);
    try expectEq(r.energy_forward.re, q.q128Neg(q.Q_C2));
    try expectEq(r.energy_inverse.re, q.q128Neg(q.Q_C2_INV));
}

test "phi scaling" {
    const r = RamseyIdentity.init(q.Q_ONE);
    const base = ComplexQ128{ .re = q.Q_C2, .im = q.Q_ZERO };
    const scaled = r.applyPhiScaling(base, q.PHI_RAW);
    const expected = q.q128Mul(q.Q_C2, q.PHI_RAW).v;
    try expectEq(scaled.re, expected);
}

test "complex arithmetic" {
    const a = ComplexQ128{ .re = q.q128FromI64(3), .im = q.q128FromI64(4) };
    const b = ComplexQ128{ .re = q.q128FromI64(1), .im = q.q128FromI64(-2) };
    const s = a.add(b);
    try expectEq(s.re, q.q128FromI64(4));
    try expectEq(s.im, q.q128FromI64(2));
    // (3+4i)(1-2i) = 3 - 6i + 4i + 8 = 11 - 2i
    const m = a.mul(b);
    try expectEq(m.re, q.q128FromI64(11));
    try expectEq(m.im, q.q128FromI64(-2));
    // conj
    const c = a.conj();
    try expectEq(c.im, q.q128FromI64(-4));
}
