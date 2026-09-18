//! splat_render.zig — Fixed-point Gaussian splat rasterizer.
//!
//! Reverse-engineered port of the 3D Gaussian Splatting output stage
//! (Kerbl et al. 2023, gsplat math suppl. arXiv:2312.02121) onto the Qstar
//! lattice: the 421 E0 nodes become sparse Gaussian splats, rendered to an
//! RGB framebuffer — the pixel-space output stage that LongCat's VAE decoder
//! occupies in the reference pipeline (see docs/LONGCAT-REVERSE-MAP.md).
//!
//! Per-Gaussian state: mean μ∈R³, covariance Σ = R·S²·Rᵀ parameterized by
//! scale vector s and rotation quaternion q (dim_4d), RGB color, opacity α.
//! Projection: μ' = K·μ/z on the image plane; Σ' = J·Σ·Jᵀ with J the
//! first-order Jacobian of perspective projection. Pixels evaluate
//! α = o·exp(-½·dᵀΣ'⁻¹d) and composite front-to-back by depth.
//!
//! All arithmetic is integer-only (i128 Q64.64). No floating-point in core
//! paths. License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");
const dim4 = @import("dim_4d_rotation");

pub const Quaternion = dim4.Quaternion;
pub const Vec3 = [3]i128;
/// Row-major 3x3 fixed-point matrix.
pub const Mat3 = [9]i128;

/// A 3D Gaussian splat. All fields Q64.64 fixed-point except color (u8 RGB).
pub const Gaussian = struct {
    mean: Vec3,
    scale: Vec3,
    rot: Quaternion,
    color: [3]u8,
    /// Opacity in [0, 1] as Q64.64.
    opacity: i128,
};

/// Pinhole camera. fx/fy are focal lengths in pixels (Q64.64); cx/cy are the
/// principal point in pixel units (Q64.64). Camera looks down +z; world space
/// is camera space.
pub const Camera = struct {
    fx: i128,
    fy: i128,
    cx: i128,
    cy: i128,
    width: u32,
    height: u32,

    /// Default 64×64 avatar viewport: focal ≈ 64px, centered principal point.
    pub fn avatarDefault() Camera {
        return .{
            .fx = fp.fromInt(64),
            .fy = fp.fromInt(64),
            .cx = fp.fromInt(32),
            .cy = fp.fromInt(32),
            .width = 64,
            .height = 64,
        };
    }
};

/// A splat projected into image space: 2D mean, 2x2 covariance (packed a,b,d),
/// depth (z, ascending = nearer first), color, opacity, and pixel bbox radius.
pub const ProjectedSplat = struct {
    mx: i128,
    my: i128,
    depth: i128,
    /// Σ' = [[a, b], [b, d]] packed.
    cov_a: i128,
    cov_b: i128,
    cov_d: i128,
    color: [3]u8,
    opacity: i128,
    /// Rasterization bounding radius in whole pixels (3σ of max eigenvalue).
    radius_px: u32,
};

/// Quaternion (w,b,c,d) → 3x3 rotation matrix, fixed-point.
/// R = [[1-2(c²+d²), 2(bc-ad),   2(bd+ac)  ],
///      [2(bc+ad),   1-2(c²+d²)... ]]
/// Input need not be normalized; normalized internally.
pub fn quatToMat3(q_in: Quaternion) Mat3 {
    const ns = q_in.normSquared();
    if (ns == 0) return identity3();
    // Normalize: divide each component by sqrt(ns).
    const inv = fp.div(fp.ONE, fp.sqrt(ns));
    const a = fp.mul(q_in.a, inv);
    const b = fp.mul(q_in.b, inv);
    const c = fp.mul(q_in.c, inv);
    const d = fp.mul(q_in.d, inv);
    const two = fp.fromInt(2);
    return .{
        fp.ONE - fp.mul(two, fp.mul(c, c) + fp.mul(d, d)),
        fp.mul(two, fp.mul(b, c) - fp.mul(a, d)),
        fp.mul(two, fp.mul(b, d) + fp.mul(a, c)),
        fp.mul(two, fp.mul(b, c) + fp.mul(a, d)),
        fp.ONE - fp.mul(two, fp.mul(b, b) + fp.mul(d, d)),
        fp.mul(two, fp.mul(c, d) - fp.mul(a, b)),
        fp.mul(two, fp.mul(b, d) - fp.mul(a, c)),
        fp.mul(two, fp.mul(c, d) + fp.mul(a, b)),
        fp.ONE - fp.mul(two, fp.mul(b, b) + fp.mul(c, c)),
    };
}

/// 3x3 identity matrix (Q64.64).
pub fn identity3() Mat3 {
    return .{ fp.ONE, 0, 0, 0, fp.ONE, 0, 0, 0, fp.ONE };
}

/// m = a·b for row-major 3x3 fixed-point matrices.
pub fn mat3Mul(a: Mat3, b: Mat3) Mat3 {
    var m: Mat3 = undefined;
    for (0..3) |r| {
        for (0..3) |col| {
            var acc: i128 = 0;
            for (0..3) |k| {
                acc += fp.mul(a[r * 3 + k], b[k * 3 + col]);
            }
            m[r * 3 + col] = acc;
        }
    }
    return m;
}

/// Σ = R·S²·Rᵀ — the 3DGS covariance parameterization. S = diag(scale).
pub fn covariance(g: Gaussian) Mat3 {
    const r = quatToMat3(g.rot);
    var s2: Mat3 = .{0} ** 9;
    s2[0] = fp.mul(g.scale[0], g.scale[0]);
    s2[4] = fp.mul(g.scale[1], g.scale[1]);
    s2[8] = fp.mul(g.scale[2], g.scale[2]);
    const rs = mat3Mul(r, s2);
    // rs·rᵀ
    var rt: Mat3 = undefined;
    for (0..3) |i| for (0..3) |j| {
        rt[i * 3 + j] = r[j * 3 + i];
    };
    return mat3Mul(rs, rt);
}

/// Projects a Gaussian into image space. Returns null if behind the camera
/// (z <= 0) or its 3σ bounding box misses the viewport.
pub fn project(cam: Camera, g: Gaussian) ?ProjectedSplat {
    const x = g.mean[0];
    const y = g.mean[1];
    const z = g.mean[2];
    if (z <= 0) return null;

    const inv_z = fp.div(fp.ONE, z);
    const inv_z2 = fp.mul(inv_z, inv_z);
    const mx = fp.mul(fp.mul(cam.fx, x), inv_z) + cam.cx;
    const my = fp.mul(fp.mul(cam.fy, y), inv_z) + cam.cy;

    // Jacobian of perspective projection at μ:
    //   J = [[fx/z, 0, -fx·x/z²], [0, fy/z, -fy·y/z]]
    const j00 = fp.mul(cam.fx, inv_z);
    const j02 = -fp.mul(fp.mul(cam.fx, x), inv_z2);
    const j11 = fp.mul(cam.fy, inv_z);
    const j12 = -fp.mul(fp.mul(cam.fy, y), inv_z2);

    const sig = covariance(g);
    // Σ' = J·Σ·Jᵀ (2x2). Expand: Σ'[i][j] = Σ_k Σ_l J[i][k]·Σ[k][l]·J[j][l].
    const j = [2][3]i128{ .{ j00, 0, j02 }, .{ 0, j11, j12 } };
    var cov: [2][2]i128 = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (0..2) |i| {
        for (0..2) |jj| {
            var acc: i128 = 0;
            for (0..3) |k| {
                for (0..3) |l| {
                    acc += fp.mul(fp.mul(j[i][k], sig[k * 3 + l]), j[jj][l]);
                }
            }
            cov[i][jj] = acc;
        }
    }
    // Guard against degenerate/negative variance from projection.
    if (cov[0][0] <= 0 or cov[1][1] <= 0) return null;

    // Max eigenvalue of 2x2 Σ': λ = (a+d)/2 + sqrt(((a-d)/2)² + b²).
    const half = fp.fromRatio(1, 2);
    const tr = fp.mul(cov[0][0] + cov[1][1], half);
    const dif = fp.mul(cov[0][0] - cov[1][1], half);
    const lam = tr + fp.sqrt(fp.mul(dif, dif) + fp.mul(cov[0][1], cov[0][1]));
    if (lam <= 0) return null;

    const sigma_px = fp.sqrt(lam);
    const r_q = fp.mul(fp.fromInt(3), sigma_px);
    const radius_px: u32 = @intCast(@max(1, @min(4096, r_q >> fp.FRAC_BITS)));

    // Cheap cull: bbox must intersect the viewport.
    const pw = fp.fromInt(@intCast(cam.width));
    const ph = fp.fromInt(@intCast(cam.height));
    const rad = @as(i128, radius_px) << fp.FRAC_BITS;
    if (mx + rad < 0 or mx - rad > pw or my + rad < 0 or my - rad > ph) return null;

    return .{
        .mx = mx,
        .my = my,
        .depth = z,
        .cov_a = cov[0][0],
        .cov_b = cov[0][1],
        .cov_d = cov[1][1],
        .color = g.color,
        .opacity = g.opacity,
        .radius_px = radius_px,
    };
}

/// Comparator: front-to-back by depth (ascending z).
fn depthLess(_: void, a: ProjectedSplat, b: ProjectedSplat) bool {
    return a.depth < b.depth;
}

/// Sorts projected splats front-to-back in place.
pub fn sortSplats(splats: []ProjectedSplat) void {
    std.mem.sort(ProjectedSplat, splats, {}, depthLess);
}

/// Rasterizes sorted (front-to-back) splats into an RGB framebuffer of
/// width×height×3 bytes. Compositing: C += T·α·color; T *= (1-α).
/// `fb` must be preallocated (cleared to background `bg` by this function).
pub fn render(cam: Camera, splats: []const ProjectedSplat, bg: [3]u8, fb: []u8) void {
    const npix = @as(usize, cam.width) * @as(usize, cam.height);
    std.debug.assert(fb.len >= npix * 3);
    // Fill background.
    var p: usize = 0;
    while (p < npix) : (p += 1) {
        fb[p * 3] = bg[0];
        fb[p * 3 + 1] = bg[1];
        fb[p * 3 + 2] = bg[2];
    }

    // Per-pixel transmittance buffer would be npix×8 bytes; to stay
    // allocation-free we composite per-splat onto the framebuffer directly.
    // Correctness preserved, order = front-to-back.
    for (splats) |s| {
        const det = fp.mul(s.cov_a, s.cov_d) - fp.mul(s.cov_b, s.cov_b);
        if (det <= 0) continue;
        const inv_a = fp.div(s.cov_d, det);
        const inv_b = -fp.div(s.cov_b, det);
        const inv_d = fp.div(s.cov_a, det);

        const cx_i: i64 = @intCast(s.mx >> fp.FRAC_BITS);
        const cy_i: i64 = @intCast(s.my >> fp.FRAC_BITS);
        const r: i64 = @intCast(s.radius_px);
        const x0 = @max(0, cx_i - r);
        const x1 = @min(@as(i64, cam.width) - 1, cx_i + r);
        const y0 = @max(0, cy_i - r);
        const y1 = @min(@as(i64, cam.height) - 1, cy_i + r);

        const neg_half = -fp.fromRatio(1, 2);
        var yi = y0;
        while (yi <= y1) : (yi += 1) {
            var xi = x0;
            while (xi <= x1) : (xi += 1) {
                // d = pixel_center - mean (Q64.64)
                const dx = ((@as(i128, xi) << fp.FRAC_BITS) + fp.HALF) - s.mx;
                const dy = ((@as(i128, yi) << fp.FRAC_BITS) + fp.HALF) - s.my;
                const power = fp.mul(neg_half, fp.mul(dx, fp.mul(inv_a, dx) + fp.mul(inv_b, dy)) +
                    fp.mul(dy, fp.mul(inv_b, dx) + fp.mul(inv_d, dy)));
                var alpha = fp.mul(s.opacity, fp.exp(power));
                if (alpha <= 0) continue;
                if (alpha > fp.ONE) alpha = fp.ONE;

                const idx = (@as(usize, @intCast(yi)) * cam.width + @as(usize, @intCast(xi))) * 3;
                const inv_alpha = fp.ONE - alpha;
                for (0..3) |ch| {
                    const src = @as(i128, s.color[ch]) << fp.FRAC_BITS;
                    const dst = @as(i128, fb[idx + ch]) << fp.FRAC_BITS;
                    const blended = fp.mul(alpha, src) + fp.mul(inv_alpha, dst);
                    fb[idx + ch] = @intCast(@min(255, @max(0, blended >> fp.FRAC_BITS)));
                }
            }
        }
    }
}

// =============================================================================
// Lattice → splat mapping
// =============================================================================

/// Grid edge of the E0 node lattice (15³).
pub const GRID_EDGE: u32 = 15;
/// World-space depth where the lattice grid front plane sits.
pub const LATTICE_DEPTH: i128 = 4 << 64; // z = 4.0

/// Maps a node index to its (x,y,z) coordinate in the 15³ grid.
/// Ordering matches dim_3d_space.coordOf semantics (x-major).
pub fn nodeCoord(idx: usize) Vec3 {
    const i = @as(i128, @intCast(idx));
    const x = @mod(i, GRID_EDGE);
    const y = @mod(@divFloor(i, GRID_EDGE), GRID_EDGE);
    const z = @divFloor(i, GRID_EDGE * GRID_EDGE);
    // Center at origin: coord ∈ [-1, 1] roughly; grid is 0..14 → (c-7)/7.
    return .{
        fp.div((x - 7) << fp.FRAC_BITS, fp.fromInt(7)),
        fp.div((y - 7) << fp.FRAC_BITS, fp.fromInt(7)),
        LATTICE_DEPTH + fp.div((z - 7) << fp.FRAC_BITS, fp.fromInt(7)),
    };
}

/// Converts a lattice state (node_count × channel_count i128 activations,
/// row-major node-major) into Gaussian splats. Each node → one Gaussian:
///   mean   = grid coord (centered, pushed to LATTICE_DEPTH)
///   scale  = base_scale × (1 + mean|activation|) per axis
///   rot    = axis-aligned rotation derived from channel phase (dim_4d)
///   color  = top-3 channel group magnitudes → RGB
///   opacity= mean |activation| clamped to [0,1]
/// `state` layout: state[node * channel_count + channel].
pub fn latticeToSplats(
    allocator: std.mem.Allocator,
    state: []const i128,
    node_count: usize,
    channel_count: usize,
    base_scale: i128,
) ![]Gaussian {
    var out = try allocator.alloc(Gaussian, node_count);
    errdefer allocator.free(out);
    for (0..node_count) |n| {
        const acts = state[n * channel_count .. (n + 1) * channel_count];
        var sum_abs: i128 = 0;
        var ch = [3]i128{ 0, 0, 0 };
        for (acts, 0..) |a, ci| {
            const abs_a = if (a < 0) -a else a;
            sum_abs += abs_a;
            ch[ci % 3] += abs_a;
        }
        const mean_abs = @divTrunc(sum_abs, @as(i128, @intCast(channel_count)));
        const opacity = @min(mean_abs, fp.ONE);
        const s = base_scale + fp.mul(base_scale, mean_abs);
        // Color: normalize channel groups to u8.
        var color: [3]u8 = undefined;
        for (0..3) |ci| {
            const maxv = @max(ch[ci], fp.ONE * 2);
            color[ci] = @intCast(@min(255, @max(0, @divTrunc(ch[ci] << 8, maxv))));
        }
        out[n] = .{
            .mean = nodeCoord(n),
            .scale = .{ s, s, s },
            .rot = Quaternion.one(),
            .color = color,
            .opacity = opacity,
        };
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

test "quatToMat3: identity quaternion gives identity matrix" {
    const r = quatToMat3(Quaternion.one());
    try std.testing.expect(r[0] == fp.ONE and r[4] == fp.ONE and r[8] == fp.ONE);
    try std.testing.expect(r[1] == 0 and r[3] == 0);
}

test "covariance: axis-aligned identity rotation gives diag(s²)" {
    const g = Gaussian{
        .mean = .{ 0, 0, fp.fromInt(4) },
        .scale = .{ fp.fromInt(2), fp.fromInt(3), fp.ONE },
        .rot = Quaternion.one(),
        .color = .{ 255, 0, 0 },
        .opacity = fp.ONE,
    };
    const sig = covariance(g);
    try std.testing.expect(sig[0] == fp.fromInt(4)); // 2²
    try std.testing.expect(sig[4] == fp.fromInt(9)); // 3²
    try std.testing.expect(sig[8] == fp.ONE); // 1²
    try std.testing.expect(sig[1] == 0 and sig[3] == 0);
}

test "project: on-axis gaussian lands at principal point" {
    const cam = Camera.avatarDefault();
    const g = Gaussian{
        .mean = .{ 0, 0, fp.fromInt(4) },
        .scale = .{ fp.ONE, fp.ONE, fp.ONE },
        .rot = Quaternion.one(),
        .color = .{ 255, 255, 255 },
        .opacity = fp.ONE,
    };
    const s = project(cam, g).?;
    try std.testing.expect(s.mx == cam.cx and s.my == cam.cy);
    try std.testing.expect(s.cov_a > 0 and s.cov_d > 0);
    try std.testing.expect(s.cov_b == 0); // symmetric on-axis
    try std.testing.expect(s.radius_px > 0);
}

test "project: behind camera returns null" {
    const cam = Camera.avatarDefault();
    const g = Gaussian{
        .mean = .{ 0, 0, -fp.fromInt(1) },
        .scale = .{ fp.ONE, fp.ONE, fp.ONE },
        .rot = Quaternion.one(),
        .color = .{ 0, 0, 0 },
        .opacity = fp.ONE,
    };
    try std.testing.expect(project(cam, g) == null);
}

test "sortSplats: front-to-back ordering" {
    var splats = [_]ProjectedSplat{
        .{ .mx = 0, .my = 0, .depth = fp.fromInt(9), .cov_a = fp.ONE, .cov_b = 0, .cov_d = fp.ONE, .color = .{ 0, 0, 0 }, .opacity = 0, .radius_px = 1 },
        .{ .mx = 0, .my = 0, .depth = fp.fromInt(2), .cov_a = fp.ONE, .cov_b = 0, .cov_d = fp.ONE, .color = .{ 0, 0, 0 }, .opacity = 0, .radius_px = 1 },
        .{ .mx = 0, .my = 0, .depth = fp.fromInt(5), .cov_a = fp.ONE, .cov_b = 0, .cov_d = fp.ONE, .color = .{ 0, 0, 0 }, .opacity = 0, .radius_px = 1 },
    };
    sortSplats(&splats);
    try std.testing.expect(splats[0].depth == fp.fromInt(2));
    try std.testing.expect(splats[2].depth == fp.fromInt(9));
}

test "render: opaque center splat colors the center pixel" {
    const cam = Camera.avatarDefault();
    const splats = [_]Gaussian{.{
        .mean = .{ 0, 0, fp.fromInt(4) },
        .scale = .{ fp.ONE, fp.ONE, fp.ONE },
        .rot = Quaternion.one(),
        .color = .{ 255, 0, 0 },
        .opacity = fp.ONE,
    }};
    var proj = [_]ProjectedSplat{project(cam, splats[0]).?};
    sortSplats(&proj);
    const fb = try std.testing.allocator.alloc(u8, @as(usize, cam.width) * cam.height * 3);
    defer std.testing.allocator.free(fb);
    render(cam, &proj, .{ 0, 0, 0 }, fb);
    const c = (@as(usize, 32) * cam.width + 32) * 3;
    try std.testing.expect(fb[c] > 128); // red channel lit
    try std.testing.expect(fb[c + 1] < 128 and fb[c + 2] < 128);
}

test "latticeToSplats: maps node count and clamps opacity" {
    const alloc = std.testing.allocator;
    const nodes: usize = 421;
    const chans: usize = 8;
    var state = try alloc.alloc(i128, nodes * chans);
    defer alloc.free(state);
    @memset(state, 0);
    // Activate node 0 channels.
    for (0..chans) |c| state[c] = fp.fromInt(2);
    const splats = try latticeToSplats(alloc, state, nodes, chans, fp.fromRatio(1, 10));
    defer alloc.free(splats);
    try std.testing.expect(splats.len == nodes);
    try std.testing.expect(splats[0].opacity == fp.ONE); // mean|act|=2 → clamp 1
    try std.testing.expect(splats[1].opacity == 0);
    // Node 0 sits at grid corner: x=y=-1, z=3.
    try std.testing.expect(splats[0].mean[0] == -fp.ONE);
}
