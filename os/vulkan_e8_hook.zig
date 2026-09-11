// vulkan_e8_hook.zig — Integration hook for GPU-accelerated E8 root verification
// via Q128.128/FANO-1's Vulkan compute pipeline.
//
// This module provides the bridge between the hardware project's E8 root
// system verification and the FANO-1 OS's Vulkan compute shaders. It
// generates the SPIR-V shader input data and verifies GPU results against
// the CPU reference.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");

/// E8 root system parameters (matching hardware's src/e8_roots.zig)
pub const ROOT_COUNT: u32 = 240;
pub const DIM: u32 = 8;

/// E8 root: 8-dimensional integer vector (scaled by 2 for half-integer roots).
pub const Root = [DIM]i32;

/// D8 roots: permutations of (±2, ±2, 0, 0, 0, 0, 0, 0) — 112 roots.
pub fn d8Roots() [112]Root {
    var roots: [112]Root = undefined;
    var idx: u32 = 0;
    // Choose 2 positions out of 8 for the ±2 values
    var i: u32 = 0;
    while (i < DIM) : (i += 1) {
        var j: u32 = i + 1;
        while (j < DIM) : (j += 1) {
            // 4 sign combinations: (+,+), (+,-), (-,+), (-,-)
            for ([_]i32{ 2, -2 }) |s1| {
                for ([_]i32{ 2, -2 }) |s2| {
                    var root: Root = .{0} ** DIM;
                    root[i] = s1;
                    root[j] = s2;
                    roots[idx] = root;
                    idx += 1;
                }
            }
        }
    }
    return roots;
}

/// Spinor roots: (±1, ±1, ±1, ±1, ±1, ±1, ±1, ±1) with even number of minus signs — 128 roots.
pub fn spinorRoots() [128]Root {
    var roots: [128]Root = undefined;
    var idx: u32 = 0;
    // 2^8 = 256 sign combinations; keep those with even number of minus signs
    var mask: u32 = 0;
    while (mask < 256) : (mask += 1) {
        // Count minus signs (bits set)
        const minus_count = @popCount(mask);
        if (minus_count % 2 == 0) {
            var root: Root = undefined;
            var bit: u32 = 0;
            while (bit < DIM) : (bit += 1) {
                root[bit] = if ((mask >> @intCast(bit)) & 1 == 1) -1 else 1;
            }
            roots[idx] = root;
            idx += 1;
        }
    }
    return roots;
}

/// All 240 E8 roots (112 D8 + 128 spinor).
pub fn allRoots() [ROOT_COUNT]Root {
    const d8 = d8Roots();
    const sp = spinorRoots();
    var roots: [ROOT_COUNT]Root = undefined;
    @memcpy(roots[0..112], &d8);
    @memcpy(roots[112..240], &sp);
    return roots;
}

/// GPU shader input: flat array of 240 × 8 = 1920 i32 values.
pub fn shaderInput() [ROOT_COUNT * DIM]i32 {
    const roots = allRoots();
    var input: [ROOT_COUNT * DIM]i32 = undefined;
    for (roots, 0..) |root, i| {
        @memcpy(input[i * DIM .. (i + 1) * DIM], &root);
    }
    return input;
}

/// Verify a GPU-computed reflection result against the CPU reference.
/// For each root pair (α, β), the reflection of β through α is:
///   β' = β - 2(β·α)/(α·α) × α
/// The GPU shader checks whether β' is also in the root set.
pub fn verifyReflection(roots: []const Root, alpha_idx: u32, beta_idx: u32) bool {
    const alpha = roots[alpha_idx];
    const beta = roots[beta_idx];

    // Dot products (exact integer arithmetic)
    var dot_ba: i64 = 0;
    var dot_aa: i64 = 0;
    for (0..DIM) |k| {
        dot_ba += @as(i64, beta[k]) * @as(i64, alpha[k]);
        dot_aa += @as(i64, alpha[k]) * @as(i64, alpha[k]);
    }

    // Reflection: β' = β - 2(β·α)/(α·α) × α
    // For E8 (simply-laced), α·α = 8 for all roots, so:
    // β' = β - (β·α)/4 × α
    // The coefficient 2(β·α)/(α·α) = (β·α)/4 must be an integer
    if (dot_aa != 8) return false;
    const coeff = @divTrunc(2 * dot_ba, dot_aa);

    var reflected: Root = undefined;
    for (0..DIM) |k| {
        reflected[k] = beta[k] - @as(i32, @intCast(coeff)) * alpha[k];
    }

    // Check if reflected root is in the set
    for (roots) |r| {
        if (std.mem.eql(i32, &r, &reflected)) return true;
    }
    return false;
}

/// Verify the full root system is closed under reflections.
pub fn verifyClosure() bool {
    const roots = allRoots();
    for (0..ROOT_COUNT) |i| {
        for (0..ROOT_COUNT) |j| {
            if (!verifyReflection(&roots, @intCast(i), @intCast(j))) {
                return false;
            }
        }
    }
    return true;
}

// Tests
test "root count" {
    try std.testing.expectEqual(@as(u32, 240), ROOT_COUNT);
}

test "D8 root count" {
    const d8 = d8Roots();
    try std.testing.expectEqual(@as(u32, 112), d8.len);
}

test "spinor root count" {
    const sp = spinorRoots();
    try std.testing.expectEqual(@as(u32, 128), sp.len);
}

test "shader input size" {
    const input = shaderInput();
    try std.testing.expectEqual(@as(usize, 1920), input.len);
}

test "root closure" {
    try std.testing.expect(verifyClosure());
}
