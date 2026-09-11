// License: CC BY-NC-SA 4.0

// Sidecar f64 validation for codon signatures.
//
// This module validates the f64 chemistry computations that the Zig core
// performs in fixed-point. It computes:
//   - Surface area from van der Waals radii (f64).
//   - Lattice triangle area from base-point coordinates (f64).
//   - Chemistry-derived qubit coordinates (qx, qy, qz).
//   - Ladder coordinate sums.
//   - Base-4 codon encoding.
//
// Results are compared against the reference JSON signature table values
// and against the fixed-point Zig core where appropriate.

const std = @import("std");

const phi = (1.0 + @sqrt(5.0)) / 2.0;
const pi = std.math.pi;

const BaseChem = struct {
    mw: f64,
    rings: u8,
    hbonds: u8,
    atoms: u8,
    n_count: u8,
    o_count: u8,
    vdw_radius: f64, // Angstrom
};

const base_chem = [_]BaseChem{
    .{ .mw = 347.2, .rings = 2, .hbonds = 2, .atoms = 15, .n_count = 5, .o_count = 1, .vdw_radius = 1.88 }, // A
    .{ .mw = 323.2, .rings = 1, .hbonds = 3, .atoms = 13, .n_count = 3, .o_count = 2, .vdw_radius = 1.75 }, // C
    .{ .mw = 363.2, .rings = 2, .hbonds = 3, .atoms = 16, .n_count = 5, .o_count = 2, .vdw_radius = 1.96 }, // G
    .{ .mw = 324.2, .rings = 1, .hbonds = 2, .atoms = 13, .n_count = 2, .o_count = 3, .vdw_radius = 1.80 }, // U
};

const backbone_radius_nm: f64 = 0.34;

const ladder_coords = [_]f64{
    0.0, // E0
    phi, // E1
    pi, // E2
    21.0 / 4.0, // E3
    21.0 / 2.0, // E4
    21.0, // E5
    42.0, // E6
    21.0, // E7
};

// Genetic code: amino acid for each base-4 index (first base most significant).
// Symbols: F L I M V P A W G S T C Y N Q D E K R H STOP
const genetic_code = [_][]const u8{
    "K",    "N", "K",    "N", "T", "T", "T", "T", "R",    "S", "R", "S", "I", "I", "M", "I",
    "Q",    "H", "Q",    "H", "P", "P", "P", "P", "R",    "R", "R", "R", "L", "L", "L", "L",
    "E",    "D", "E",    "D", "A", "A", "A", "A", "G",    "G", "G", "G", "V", "V", "V", "V",
    "STOP", "Y", "STOP", "Y", "S", "S", "S", "S", "STOP", "C", "W", "C", "L", "F", "L", "F",
};

fn baseValue(base: u8) u8 {
    return switch (base) {
        'A' => 0,
        'C' => 1,
        'G' => 2,
        'U', 'T' => 3,
        else => 255,
    };
}

pub fn codonIndex(codon: [3]u8) u8 {
    return (baseValue(codon[0]) << 4) | (baseValue(codon[1]) << 2) | baseValue(codon[2]);
}

fn qubitCoords(codon: [3]u8) struct { qx: u8, qy: u8, qz: u8 } {
    var mw_sum: f64 = 0;
    var ring_hbond_sum: f64 = 0;
    var no_sum: f64 = 0;
    for (codon) |base| {
        const chem = base_chem[baseValue(base)];
        mw_sum += chem.mw;
        ring_hbond_sum += @as(f64, @floatFromInt(chem.rings * 5 + chem.hbonds * 3));
        no_sum += @as(f64, @floatFromInt(chem.n_count + chem.o_count));
    }
    const qx_f = @floor((mw_sum - 970.0) / 30.0);
    const qy_f = @floor(ring_hbond_sum);
    const qz_f = @floor(no_sum);
    const qx: u8 = @intCast(@mod(@as(i64, @intFromFloat(qx_f)), 2));
    const qy: u8 = @intCast(@mod(@as(i64, @intFromFloat(qy_f)), 2));
    const qz: u8 = @intCast(@mod(@as(i64, @intFromFloat(qz_f)), 2));
    return .{ .qx = qx, .qy = qy, .qz = qz };
}

fn basePoint(base: u8, pos: u8) struct { x: f64, y: f64, z: f64 } {
    const chem = base_chem[baseValue(base)];
    const pos_f: f64 = @floatFromInt(pos);
    const x_raw = @floor(((chem.mw - 323.2) / 40.0) * 14.0 + pos_f * phi);
    const y_raw = @floor(@as(f64, @floatFromInt(chem.rings * 7 + chem.hbonds * 2)) + pos_f * pi);
    const z_raw = @floor(((@as(f64, @floatFromInt(chem.atoms)) - 13.0) / 3.0) * 14.0 + pos_f * (21.0 / 4.0));
    const x: f64 = @as(f64, @floatFromInt(@mod(@as(i64, @intFromFloat(x_raw)), 15)));
    const y: f64 = @as(f64, @floatFromInt(@mod(@as(i64, @intFromFloat(y_raw)), 15)));
    const z: f64 = @as(f64, @floatFromInt(@mod(@as(i64, @intFromFloat(z_raw)), 15)));
    return .{ .x = x, .y = y, .z = z };
}

pub fn surfaceArea(codon: [3]u8) f64 {
    var r_sum: f64 = 0;
    for (codon) |base| {
        r_sum += base_chem[baseValue(base)].vdw_radius;
    }
    const total_r = r_sum / 10.0 + backbone_radius_nm;
    return 4.0 * pi * total_r * total_r;
}

fn latticeArea(codon: [3]u8) f64 {
    const p0 = basePoint(codon[0], 0);
    const p1 = basePoint(codon[1], 1);
    const p2 = basePoint(codon[2], 2);
    const ax = p0.x - p1.x;
    const ay = p0.y - p1.y;
    const az = p0.z - p1.z;
    const bx = p0.x - p2.x;
    const by = p0.y - p2.y;
    const bz = p0.z - p2.z;
    const cx = ay * bz - az * by;
    const cy = az * bx - ax * bz;
    const cz = ax * by - ay * bx;
    return 0.5 * @sqrt(cx * cx + cy * cy + cz * cz);
}

fn e0Count(codon: [3]u8) u8 {
    var count: u8 = 0;
    for (codon, 0..) |base, pos| {
        const p = basePoint(base, @intCast(pos));
        if (p.x == 0) count += 1;
        if (p.y == 0) count += 1;
        if (p.z == 0) count += 1;
    }
    return count;
}

fn channelFor(aa: []const u8) u8 {
    if (std.mem.eql(u8, aa, "STOP")) return 2;
    // hydrophobic: F L I M V P A W G
    const hydrophobic = [_][]const u8{ "F", "L", "I", "M", "V", "P", "A", "W", "G" };
    for (hydrophobic) |h| if (std.mem.eql(u8, aa, h)) return 6;
    // acidic: D E
    if (std.mem.eql(u8, aa, "D") or std.mem.eql(u8, aa, "E")) return 7;
    // polar: S T C Y N Q
    const polar = [_][]const u8{ "S", "T", "C", "Y", "N", "Q" };
    for (polar) |p| if (std.mem.eql(u8, aa, p)) return 5;
    // basic: K R H
    if (std.mem.eql(u8, aa, "K") or std.mem.eql(u8, aa, "R") or std.mem.eql(u8, aa, "H")) return 4;
    return 0;
}

pub fn verifyAll() bool {
    const bases_str = "ACGU";
    var pass: u16 = 0;
    var fail: u16 = 0;

    // Verify all 64 codons
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const codon = [3]u8{
            bases_str[(i >> 4) & 3],
            bases_str[(i >> 2) & 3],
            bases_str[i & 3],
        };
        const idx = codonIndex(codon);
        if (idx != i) {
            fail += 1;
            continue;
        }
        const aa = genetic_code[i];
        const channel = channelFor(aa);
        const q = qubitCoords(codon);
        const area = surfaceArea(codon);
        const larea = latticeArea(codon);
        const e0 = e0Count(codon);

        // Basic sanity checks
        if (area < 5.0 or area > 15.0) fail += 1; // surface area should be ~10 nm^2
        if (larea < 0.0) fail += 1;
        if (q.qx > 1 or q.qy > 1 or q.qz > 1) fail += 1;
        if (e0 > 9) fail += 1;
        if (channel > 7) fail += 1;

        // Stop codons must be channel 2
        if (std.mem.eql(u8, aa, "STOP") and channel != 2) fail += 1;

        pass += 1;
    }

    // Verify specific known values from the JSON signature table
    // AUG: qubit_index=14, qx=0, qy=0, qz=0, surface_area~10.2694, lattice_area~20.62
    const aug = [3]u8{ 'A', 'U', 'G' };
    if (codonIndex(aug) != 14) fail += 1;
    const aug_q = qubitCoords(aug);
    if (aug_q.qx != 0 or aug_q.qy != 0 or aug_q.qz != 0) fail += 1;
    const aug_area = surfaceArea(aug);
    if (@abs(aug_area - 10.2694) > 0.01) fail += 1;
    const aug_larea = latticeArea(aug);
    if (@abs(aug_larea - 20.62) > 0.1) fail += 1;

    // UAA: qubit_index=48, qx=1, qy=1, qz=1, surface_area~10.0885, lattice_area~59.76
    const uaa = [3]u8{ 'U', 'A', 'A' };
    if (codonIndex(uaa) != 48) fail += 1;
    const uaa_q = qubitCoords(uaa);
    if (uaa_q.qx != 1 or uaa_q.qy != 1 or uaa_q.qz != 1) fail += 1;
    const uaa_area = surfaceArea(uaa);
    if (@abs(uaa_area - 10.0885) > 0.01) fail += 1;
    const uaa_larea = latticeArea(uaa);
    if (@abs(uaa_larea - 59.76) > 0.1) fail += 1;

    // GAA: qubit_index=32, qx=0, qy=1, qz=1, channel=E7
    const gaa = [3]u8{ 'G', 'A', 'A' };
    if (codonIndex(gaa) != 32) fail += 1;
    const gaa_q = qubitCoords(gaa);
    if (gaa_q.qx != 0 or gaa_q.qy != 1 or gaa_q.qz != 1) fail += 1;
    if (channelFor(genetic_code[32]) != 7) fail += 1;

    // UGA: e0_count=3
    const uga = [3]u8{ 'U', 'G', 'A' };
    if (e0Count(uga) != 3) fail += 1;

    // Ladder coordinate checks
    if (ladder_coords[6] != 42.0) fail += 1;
    if (ladder_coords[5] != 21.0) fail += 1;
    if (@abs(ladder_coords[1] - phi) > 1e-15) fail += 1;
    if (@abs(ladder_coords[2] - pi) > 1e-15) fail += 1;

    return fail == 0 and pass == 64;
}

pub fn printSummary(writer: anytype) !void {
    const bases_str = "ACGU";
    try writer.print("Codon sidecar f64 validation:\n", .{});
    try writer.print("  phi = {d:.15}\n", .{phi});
    try writer.print("  pi  = {d:.15}\n", .{pi});
    try writer.print("  ladder[6] (E6) = {d:.6}\n", .{ladder_coords[6]});
    try writer.print("  ladder[2] (E2) = {d:.6}\n", .{ladder_coords[2]});

    // Print a few key codons
    const aug = [3]u8{ 'A', 'U', 'G' };
    try writer.print("  AUG: idx={d} qx={d} qy={d} qz={d} area={d:.4} lattice={d:.2}\n", .{
        codonIndex(aug),  qubitCoords(aug).qx, qubitCoords(aug).qy, qubitCoords(aug).qz,
        surfaceArea(aug), latticeArea(aug),
    });

    const uaa = [3]u8{ 'U', 'A', 'A' };
    try writer.print("  UAA: idx={d} qx={d} qy={d} qz={d} area={d:.4} lattice={d:.2}\n", .{
        codonIndex(uaa),  qubitCoords(uaa).qx, qubitCoords(uaa).qy, qubitCoords(uaa).qz,
        surfaceArea(uaa), latticeArea(uaa),
    });

    const gaa = [3]u8{ 'G', 'A', 'A' };
    try writer.print("  GAA: idx={d} qx={d} qy={d} qz={d} area={d:.4} lattice={d:.2}\n", .{
        codonIndex(gaa),  qubitCoords(gaa).qx, qubitCoords(gaa).qy, qubitCoords(gaa).qz,
        surfaceArea(gaa), latticeArea(gaa),
    });

    // Verify all 64 codons
    var all_pass = true;
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const codon = [3]u8{
            bases_str[(i >> 4) & 3],
            bases_str[(i >> 2) & 3],
            bases_str[i & 3],
        };
        const area = surfaceArea(codon);
        if (area < 5.0 or area > 15.0) all_pass = false;
    }

    try writer.print("  all 64 codons surface area in [5,15]: {}\n", .{all_pass});
    try writer.print("  verifyAll() = {}\n", .{verifyAll()});
}

test "codon base-4 encoding AUG=14" {
    try std.testing.expectEqual(@as(u8, 14), codonIndex(.{ 'A', 'U', 'G' }));
}

test "codon base-4 encoding UAA=48" {
    try std.testing.expectEqual(@as(u8, 48), codonIndex(.{ 'U', 'A', 'A' }));
}

test "codon qubit coords AUG" {
    const q = qubitCoords(.{ 'A', 'U', 'G' });
    try std.testing.expectEqual(@as(u8, 0), q.qx);
    try std.testing.expectEqual(@as(u8, 0), q.qy);
    try std.testing.expectEqual(@as(u8, 0), q.qz);
}

test "codon qubit coords UAA" {
    const q = qubitCoords(.{ 'U', 'A', 'A' });
    try std.testing.expectEqual(@as(u8, 1), q.qx);
    try std.testing.expectEqual(@as(u8, 1), q.qy);
    try std.testing.expectEqual(@as(u8, 1), q.qz);
}

test "codon surface area AUG ~10.2694" {
    const area = surfaceArea(.{ 'A', 'U', 'G' });
    try std.testing.expect(@abs(area - 10.2694) < 0.01);
}

test "codon lattice area UGA ~27.57" {
    const area = latticeArea(.{ 'U', 'G', 'A' });
    try std.testing.expect(@abs(area - 27.57) < 0.1);
}

test "codon e0_count UGA=3" {
    try std.testing.expectEqual(@as(u8, 3), e0Count(.{ 'U', 'G', 'A' }));
}

test "codon verifyAll passes" {
    try std.testing.expect(verifyAll());
}

test "codon ladder coordinates" {
    try std.testing.expectEqual(@as(f64, 42.0), ladder_coords[6]);
    try std.testing.expectEqual(@as(f64, 21.0), ladder_coords[5]);
    try std.testing.expect(@abs(ladder_coords[1] - phi) < 1e-15);
}

test "codon all 64 surface areas in valid range" {
    const bases_str = "ACGU";
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const codon = [3]u8{
            bases_str[(i >> 4) & 3],
            bases_str[(i >> 2) & 3],
            bases_str[i & 3],
        };
        const area = surfaceArea(codon);
        try std.testing.expect(area > 5.0 and area < 15.0);
    }
}
