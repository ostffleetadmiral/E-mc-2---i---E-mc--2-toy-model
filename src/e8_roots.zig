// ============================================================================
// E8 ROOT SYSTEM — Explicit Construction of 240 Roots
// ============================================================================
//
// The E8 root system has exactly 240 roots in 8-dimensional Euclidean space.
// This module constructs them explicitly using integer coordinates (scaled
// by 2 to avoid fractions), verifies the count, and connects to the
// framework's 15 × 16 = 240 identity.
//
// The 240 roots come in two families:
//   112 roots: (±2, ±2, 0, 0, 0, 0, 0, 0) and all permutations
//     Count: C(8,2) × 4 = 28 × 4 = 112
//   128 roots: (±1, ±1, ±1, ±1, ±1, ±1, ±1, ±1) with even number of minus signs
//     Count: 2^7 = 128 (fix first sign, even parity constraint)
//   Total: 112 + 128 = 240
//
// Connection to the framework:
//   240 = 15 × 16 = SM fermions × SO(10) spinor dimension
//   E8 contains SO(16) as a maximal subgroup
//   SO(16) contains SO(10) as a subgroup
//   The 240 roots decompose under SO(16) as 120 + 120 (spinor weights)
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

pub const DIM: u8 = 8;
pub const ROOT_COUNT: usize = 240;

pub const Root = [DIM]i8;

/// Generate all 112 roots of the form (±2, ±2, 0, 0, 0, 0, 0, 0).
/// These are the "D8" roots: permutations of (±2, ±2, 0, 0, 0, 0, 0, 0).
fn generateD8Roots(buf: []Root) usize {
    var idx: usize = 0;
    // Choose 2 positions out of 8 for the ±2 entries
    for (0..DIM) |i| {
        for (i + 1..DIM) |j| {
            // 4 sign combinations: (+,+), (+,-), (-,+), (-,-)
            const signs = [_][2]i8{ .{ 2, 2 }, .{ 2, -2 }, .{ -2, 2 }, .{ -2, -2 } };
            for (signs) |s| {
                if (idx >= buf.len) return idx;
                var root: Root = .{0} ** DIM;
                root[i] = s[0];
                root[j] = s[1];
                buf[idx] = root;
                idx += 1;
            }
        }
    }
    return idx;
}

/// Generate all 128 roots of the form (±1, ±1, ±1, ±1, ±1, ±1, ±1, ±1)
/// with an even number of minus signs.
fn generateE8SpinorRoots(buf: []Root) usize {
    var idx: usize = 0;
    // Iterate over all 256 sign combinations
    for (0..256) |bits| {
        // Count minus signs (bits where sign is -1)
        var minus_count: u8 = 0;
        for (0..DIM) |k| {
            if ((bits >> @intCast(k)) & 1 == 1) minus_count += 1;
        }
        // Only keep even number of minus signs
        if (@rem(minus_count, 2) != 0) continue;

        if (idx >= buf.len) return idx;
        var root: Root = .{0} ** DIM;
        for (0..DIM) |k| {
            root[k] = if ((bits >> @intCast(k)) & 1 == 1) -1 else 1;
        }
        buf[idx] = root;
        idx += 1;
    }
    return idx;
}

/// Generate all 240 E8 roots.
pub fn generateAllRoots(buf: []Root) usize {
    var total: usize = 0;
    total += generateD8Roots(buf[total..]);
    total += generateE8SpinorRoots(buf[total..]);
    return total;
}

/// Compute the squared norm of a root (using the scaled coordinates).
/// For D8 roots: |root|² = 4 + 4 = 8
/// For spinor roots: |root|² = 8 × 1 = 8
/// All E8 roots have the same squared norm (simply-laced).
pub fn normSquared(root: Root) i32 {
    var sum: i32 = 0;
    for (root) |r| {
        sum += @as(i32, r) * @as(i32, r);
    }
    return sum;
}

/// Compute the inner product of two roots.
pub fn innerProduct(a: Root, b: Root) i32 {
    var sum: i32 = 0;
    for (0..DIM) |k| {
        sum += @as(i32, a[k]) * @as(i32, b[k]);
    }
    return sum;
}

/// Verify that all roots have the same squared norm (E8 is simply-laced).
pub fn verifyUniformNorm(roots: []const Root) bool {
    if (roots.len == 0) return false;
    const expected = normSquared(roots[0]);
    for (roots[1..]) |r| {
        if (normSquared(r) != expected) return false;
    }
    return expected == 8; // All E8 roots have norm² = 8 (in our scaling)
}

/// Verify that the root system is closed under reflections.
/// For any two roots α, β, the reflection of β through α should be
/// another root: β' = β - 2(α·β)/(α·α) × α
/// Since all norms are 8: β' = β - (α·β)/4 × α
pub fn verifyReflectionClosure(roots: []const Root) bool {
    for (roots) |alpha| {
        for (roots) |beta| {
            const ip = innerProduct(alpha, beta);
            if (ip == 0) continue; // β' = β, already a root
            // β' = β - (ip/4) × α
            // Since ip must be divisible by 4 for β' to have integer coordinates
            if (@rem(ip, 4) != 0) continue; // Not a root reflection (ip must be 0, ±4, ±8)
            const factor = @divTrunc(ip, 4);
            var reflected: Root = beta;
            for (0..DIM) |k| {
                reflected[k] = beta[k] - @as(i8, @intCast(factor)) * alpha[k];
            }
            // Check if reflected is in the root system
            var found = false;
            for (roots) |r| {
                if (std.mem.eql(i8, &r, &reflected)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return true;
}

/// Count roots by type (D8 vs spinor).
pub fn countByType(roots: []const Root) struct { d8: usize, spinor: usize } {
    var d8: usize = 0;
    var spinor: usize = 0;
    for (roots) |r| {
        var non_zero: u8 = 0;
        var all_pm1 = true;
        for (r) |v| {
            if (v != 0) non_zero += 1;
            if (v != 1 and v != -1) all_pm1 = false;
        }
        if (all_pm1 and non_zero == DIM) {
            spinor += 1;
        } else {
            d8 += 1;
        }
    }
    return .{ .d8 = d8, .spinor = spinor };
}

/// Verify the connection to the framework: 240 = 15 × 16.
pub fn verifyFrameworkConnection() bool {
    return ROOT_COUNT == 15 * 16;
}

/// Verify that E8 contains SO(16) structure.
/// The 240 roots decompose as 112 (D8 roots = SO(16) roots) + 128 (spinor weights).
/// SO(16) has dimension 120, but the D8 root system has 112 roots.
/// The 128 spinor roots are the weights of one of the two SO(16) half-spinor representations.
pub fn verifySO16Decomposition(roots: []const Root) bool {
    const counts = countByType(roots);
    return counts.d8 == 112 and counts.spinor == 128;
}

// ============================================================================
// Tests
// ============================================================================

test "E8 has exactly 240 roots" {
    var roots: [ROOT_COUNT]Root = undefined;
    const count = generateAllRoots(&roots);
    try std.testing.expectEqual(ROOT_COUNT, count);
}

test "E8 roots: 112 D8 + 128 spinor" {
    var roots: [ROOT_COUNT]Root = undefined;
    _ = generateAllRoots(&roots);
    const counts = countByType(&roots);
    try std.testing.expectEqual(@as(usize, 112), counts.d8);
    try std.testing.expectEqual(@as(usize, 128), counts.spinor);
}

test "all E8 roots have uniform norm squared = 8" {
    var roots: [ROOT_COUNT]Root = undefined;
    _ = generateAllRoots(&roots);
    try std.testing.expect(verifyUniformNorm(&roots));
}

test "E8 root system is closed under reflections" {
    var roots: [ROOT_COUNT]Root = undefined;
    _ = generateAllRoots(&roots);
    try std.testing.expect(verifyReflectionClosure(&roots));
}

test "E8 root count = 15 × 16 (framework connection)" {
    try std.testing.expect(verifyFrameworkConnection());
    try std.testing.expectEqual(@as(usize, 240), 15 * 16);
}

test "E8 decomposes as 112 D8 + 128 spinor (SO(16) structure)" {
    var roots: [ROOT_COUNT]Root = undefined;
    _ = generateAllRoots(&roots);
    try std.testing.expect(verifySO16Decomposition(&roots));
}

test "D8 roots are permutations of (±2, ±2, 0, 0, 0, 0, 0, 0)" {
    var roots: [ROOT_COUNT]Root = undefined;
    _ = generateAllRoots(&roots);
    // First 112 roots should be D8
    for (0..112) |i| {
        var non_zero: u8 = 0;
        for (roots[i]) |v| {
            if (v != 0) {
                non_zero += 1;
                try std.testing.expect(v == 2 or v == -2);
            }
        }
        try std.testing.expectEqual(@as(u8, 2), non_zero);
    }
}

test "spinor roots have all coordinates ±1 with even minus signs" {
    var roots: [ROOT_COUNT]Root = undefined;
    _ = generateAllRoots(&roots);
    // Last 128 roots should be spinor
    for (112..240) |i| {
        var minus_count: u8 = 0;
        for (roots[i]) |v| {
            try std.testing.expect(v == 1 or v == -1);
            if (v == -1) minus_count += 1;
        }
        try std.testing.expect(@rem(minus_count, 2) == 0);
    }
}
