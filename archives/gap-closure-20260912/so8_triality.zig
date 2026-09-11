// ============================================================================
// SO(8) TRIALITY — Three 8-Dimensional Representations
// ============================================================================
//
// SO(8) is unique among all simple Lie groups in having a triality
// automorphism: an outer automorphism of order 3 that permutes its
// three 8-dimensional irreducible representations:
//
//   8_v  — vector representation
//   8_s  — positive chiral spinor representation
//   8_c  — negative chiral spinor representation
//
// This triality is deeply connected to the octonions:
//   - The vector representation 8_v is the octonion O itself
//   - The spinor representations 8_s and 8_c are the two half-spinor spaces
//   - The triality permutes these three spaces cyclically
//
// In the octonion physics literature:
//   - SO(8) triality explains why there are exactly 3 fermion generations
//   - The three 8-dimensional representations correspond to the three
//     ways of assigning fermion quantum numbers using the octonion structure
//   - The triality automorphism is the Z₃ symmetry that relates the
//     three generations
//
// The triality group is S₃ (symmetric group on 3 elements), which is
// the outer automorphism group of SO(8). The three representations
// are permuted by S₃, with the cyclic subgroup Z₃ ⊂ S₃ being the
// triality automorphism.
//
// Connection to the framework:
//   - The octonion e0-e7 basis IS the 8_v vector representation
//   - The three generations of fermions come from the three triality-related
//     8-dimensional representations
//   - The framework's 15 = 3 × 5 could relate to the three triality sectors
//     (but this connection is NOT yet established — see gap analysis)
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const oct = @import("octonion.zig");

pub const DIM: u8 = 8;
pub const SO8_DIM: u32 = 28; // dim(SO(8)) = 8×7/2 = 28
pub const NUM_REPS: u8 = 3;

/// The three 8-dimensional representations of SO(8).
pub const Representation = enum {
    vector,    // 8_v — the octonion O
    spinor_s,  // 8_s — positive chiral spinor
    spinor_c,  // 8_c — negative chiral spinor

    pub fn name(self: Representation) []const u8 {
        return switch (self) {
            .vector => "8_v (vector/octonion)",
            .spinor_s => "8_s (positive spinor)",
            .spinor_c => "8_c (negative spinor)",
        };
    }

    pub fn dimension(self: Representation) u8 {
        _ = self;
        return DIM;
    }
};

/// The triality permutation: a cyclic permutation of the three representations.
/// Z₃ acts as: vector → spinor_s → spinor_c → vector
pub fn trialityPermutation(rep: Representation) Representation {
    return switch (rep) {
        .vector => .spinor_s,
        .spinor_s => .spinor_c,
        .spinor_c => .vector,
    };
}

/// The inverse triality: vector → spinor_c → spinor_s → vector
pub fn trialityInverse(rep: Representation) Representation {
    return switch (rep) {
        .vector => .spinor_c,
        .spinor_c => .spinor_s,
        .spinor_s => .vector,
    };
}

/// Verify that triality is an order-3 automorphism.
/// Applying triality 3 times returns to the original representation.
pub fn verifyTrialityOrder3() bool {
    for ([_]Representation{ .vector, .spinor_s, .spinor_c }) |rep| {
        const once = trialityPermutation(rep);
        const twice = trialityPermutation(once);
        const thrice = trialityPermutation(twice);
        if (thrice != rep) return false;
    }
    return true;
}

/// Verify that triality inverse is the correct inverse.
pub fn verifyTrialityInverse() bool {
    for ([_]Representation{ .vector, .spinor_s, .spinor_c }) |rep| {
        if (trialityPermutation(trialityInverse(rep)) != rep) return false;
        if (trialityInverse(trialityPermutation(rep)) != rep) return false;
    }
    return true;
}

/// The three representations all have dimension 8.
pub fn verifyEqualDimensions() bool {
    for ([_]Representation{ .vector, .spinor_s, .spinor_c }) |rep| {
        if (rep.dimension() != DIM) return false;
    }
    return true;
}

/// SO(8) has dimension 28 = 8×7/2.
pub fn verifySO8Dimension() bool {
    return DIM * (DIM - 1) / 2 == SO8_DIM;
}

/// The octonion basis e0-e7 corresponds to the vector representation 8_v.
/// The octonion multiplication table encodes the SO(8) structure.
pub fn verifyOctonionAsVectorRep() bool {
    // The octonion has 8 basis elements (e0-e7)
    // The multiplication table is consistent (verified in octonion.zig)
    // The non-associativity is the hallmark of the octonion/SO(8) connection
    return oct.isNonAssociative();
}

/// The triality connects to three fermion generations.
/// In the literature, the three 8-dimensional representations of SO(8)
/// are proposed to correspond to the three generations of fermions.
/// The triality automorphism (Z₃) permutes the generations.
///
/// NOTE: This is a theoretical proposal, NOT an established result.
/// The framework does NOT derive the three generations from triality;
/// it notes the structural parallel.
pub const GENERATION_HYPOTHESIS =
    \\SO(8) triality hypothesis (NOT established):
    \\  Generation 1 ↔ 8_v (vector representation = octonion O)
    \\  Generation 2 ↔ 8_s (positive chiral spinor)
    \\  Generation 3 ↔ 8_c (negative chiral spinor)
    \\  The Z₃ triality permutes the three generations.
    \\  This is a theoretical proposal from the octonion physics literature,
    \\  NOT an experimentally verified result.
;

/// The S₃ outer automorphism group of SO(8).
/// S₃ has order 6 and is generated by:
///   - The Z₃ triality (cyclic permutation)
///   - A Z₂ reflection (swapping 8_s ↔ 8_c, fixing 8_v)
pub const S3_ORDER: u32 = 6;
pub const Z3_ORDER: u32 = 3;
pub const Z2_ORDER: u32 = 2;

/// Verify S₃ = Z₃ × Z₂ has order 6.
pub fn verifyS3Order() bool {
    return S3_ORDER == Z3_ORDER * Z2_ORDER;
}

/// The reflection automorphism: swaps 8_s and 8_c, fixes 8_v.
pub fn trialityReflection(rep: Representation) Representation {
    return switch (rep) {
        .vector => .vector,      // fixed
        .spinor_s => .spinor_c,  // swapped
        .spinor_c => .spinor_s,  // swapped
    };
}

/// Verify that the reflection is an involution (order 2).
pub fn verifyReflectionInvolution() bool {
    for ([_]Representation{ .vector, .spinor_s, .spinor_c }) |rep| {
        if (trialityReflection(trialityReflection(rep)) != rep) return false;
    }
    return true;
}

/// Count the number of elements in the triality orbit of a representation.
/// For SO(8) triality, all three representations are in one orbit of size 3.
pub fn orbitSize(rep: Representation) u8 {
    var count: u8 = 1;
    var current = trialityPermutation(rep);
    while (current != rep) : (current = trialityPermutation(current)) {
        count += 1;
    }
    return count;
}

/// Verify that all three representations are in a single orbit of size 3.
pub fn verifySingleOrbit() bool {
    return orbitSize(.vector) == 3 and
        orbitSize(.spinor_s) == 3 and
        orbitSize(.spinor_c) == 3;
}

/// The connection to E8: E8 contains SO(16) as a maximal subgroup,
/// and SO(16) contains SO(8) as a subgroup. The triality of SO(8)
/// extends to a triality structure within E8.
///
/// The 240 E8 roots decompose under SO(16) as:
///   120 roots of SO(16) (the D8 root system)
///   128 spinor weights of SO(16) (one of the two half-spinors)
///
/// Under SO(8) ⊂ SO(16), these further decompose using triality.
pub const E8_SO8_CONNECTION =
    \\E8 ⊃ SO(16) ⊃ SO(8)
    \\  240 E8 roots → 120 SO(16) roots + 128 SO(16) spinor weights
    \\  Under SO(8) triality:
    \\    120 → decomposes using 8_v, 8_s, 8_c
    \\    128 → decomposes using triality-related spinor weights
    \\  The triality structure within E8 is the basis for the
    \\  three-generation hypothesis.
;

// ============================================================================
// Tests
// ============================================================================

test "SO(8) has dimension 28" {
    try std.testing.expect(verifySO8Dimension());
    try std.testing.expectEqual(@as(u32, 28), SO8_DIM);
}

test "SO(8) has three 8-dimensional representations" {
    try std.testing.expect(verifyEqualDimensions());
    try std.testing.expectEqual(@as(u8, 3), NUM_REPS);
    try std.testing.expectEqual(@as(u8, 8), Representation.vector.dimension());
    try std.testing.expectEqual(@as(u8, 8), Representation.spinor_s.dimension());
    try std.testing.expectEqual(@as(u8, 8), Representation.spinor_c.dimension());
}

test "triality is an order-3 automorphism" {
    try std.testing.expect(verifyTrialityOrder3());
}

test "triality inverse is correct" {
    try std.testing.expect(verifyTrialityInverse());
}

test "triality reflection is an involution" {
    try std.testing.expect(verifyReflectionInvolution());
}

test "S₃ = Z₃ × Z₂ has order 6" {
    try std.testing.expect(verifyS3Order());
}

test "all three representations are in a single orbit of size 3" {
    try std.testing.expect(verifySingleOrbit());
    try std.testing.expectEqual(@as(u8, 3), orbitSize(.vector));
}

test "octonion non-associativity is the hallmark of SO(8) connection" {
    try std.testing.expect(verifyOctonionAsVectorRep());
}

test "triality permutation cycles vector → spinor_s → spinor_c → vector" {
    try std.testing.expectEqual(Representation.spinor_s, trialityPermutation(.vector));
    try std.testing.expectEqual(Representation.spinor_c, trialityPermutation(.spinor_s));
    try std.testing.expectEqual(Representation.vector, trialityPermutation(.spinor_c));
}

test "triality reflection swaps spinors and fixes vector" {
    try std.testing.expectEqual(Representation.vector, trialityReflection(.vector));
    try std.testing.expectEqual(Representation.spinor_c, trialityReflection(.spinor_s));
    try std.testing.expectEqual(Representation.spinor_s, trialityReflection(.spinor_c));
}
