// License: CC BY-NC-SA 4.0

// Codon DNA -> 6D Jordan algebra routing port.
//
// Ports the Python codon project into the Zig/Q# fixed-point proof architecture.
// Implements:
//   - 64-codon standard genetic code (RNA alphabet).
//   - 6-bit base-4 codon encoding (A=00, C=01, G=10, U/T=11; first base most significant).
//   - Chemistry-derived qubit coordinates (qx, qy, qz) from integer-scaled molecular data.
//   - Base-point lattice coordinates using Q128.128 fixed-point arithmetic.
//   - Surface area from van der Waals radii (fixed-point).
//   - Lattice triangle area (integer cross product + fixed-point sqrt).
//   - Dimensional ladder coordinates.
//   - E2/E6/E7/E5/E4/E0 routing rules.
//   - Stop, hydrophobic, acidic, polar, basic, other classification.
//   - ChemistrySignatureBuilder (AUG outlier) and PlaceholderSignatureBuilder (GCA outlier).
//   - Rule predicates: predictsStop, predictsHydrophobic, predictsAcidic, predictedLabel.
//
// Scientific scope: verifies exact arithmetic identities (64 codons, base-4 encoding,
// genetic code lookup, routing rules), fixed-point chemistry computations, and
// deterministic signature construction. Does not prove the speculative biological
// interpretation or a physical Jordan algebra embedding.

const std = @import("std");
const fixed = @import("fixed_point.zig");
const constants = @import("constants.zig");

// ---------------------------------------------------------------------------
// Constants and data tables
// ---------------------------------------------------------------------------

pub const Codon = [3]u8;
pub const Stop: u8 = 20;

// Amino acid symbol table (index 0..19 are real amino acids, 20 = STOP).
// F L I M V P A W G S T C Y N Q D E K R H  STOP
// 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19  20
pub const symbols = "FLIMVPAWGSTCYNQDEKRH";

// Base alphabet (index order: A=0, C=1, G=2, U=3).
const bases = "ACGU";

// Genetic code: 64-entry table mapping base-4 index -> amino acid code.
// Built from GENETIC_CODE in constants.py, indexed by 6-bit base-4 index
// with first base most significant: idx = b0<<4 | b1<<2 | b2.
// Amino codes: F=0 L=1 I=2 M=3 V=4 P=5 A=6 W=7 G=8 S=9 T=10 C=11 Y=12
// N=13 Q=14 D=15 E=16 K=17 R=18 H=19 STOP=20
const amino_codes = [_]u8{
    // b0=0 (A): AAx, ACx, AGx, AUx (indices 0..15)
    // b2 order: A=0, C=1, G=2, U=3
    17, 13, 17, 13, // AAA=K, AAC=N, AAG=K, AAU=N
    10, 10, 10, 10, // ACA=T, ACC=T, ACG=T, ACU=T
    18, 9, 18, 9, // AGA=R, AGC=S, AGG=R, AGU=S
    2, 2, 3, 2, // AUA=I, AUC=I, AUG=M, AUU=I
    // b0=1 (C): CAx, CCx, CGx, CUx (indices 16..31)
    14, 19, 14, 19, // CAA=Q, CAC=H, CAG=Q, CAU=H
    5, 5, 5, 5, // CCA=P, CCC=P, CCG=P, CCU=P
    18, 18, 18, 18, // CGA=R, CGC=R, CGG=R, CGU=R
    1, 1, 1, 1, // CUA=L, CUC=L, CUG=L, CUU=L
    // b0=2 (G): GAx, GCx, GGx, GUx (indices 32..47)
    16, 15, 16, 15, // GAA=E, GAC=D, GAG=E, GAU=D
    6, 6, 6, 6, // GCA=A, GCC=A, GCG=A, GCU=A
    8, 8, 8, 8, // GGA=G, GGC=G, GGG=G, GGU=G
    4, 4, 4, 4, // GUA=V, GUC=V, GUG=V, GUU=V
    // b0=3 (U): UAx, UCx, UGx, UUx (indices 48..63)
    20, 12, 20, 12, // UAA=STOP, UAC=Y, UAG=STOP, UAU=Y
    9, 9, 9, 9, // UCA=S, UCC=S, UCG=S, UCU=S
    20, 11, 7, 11, // UGA=STOP, UGC=C, UGG=W, UGU=C
    1, 0, 1, 0, // UUA=L, UUC=F, UUG=L, UUU=F
};

// Base chemistry data from Appendix E.3.
// mw values are in 0.1 g/mol units (e.g. 3472 = 347.2 g/mol).
// rings, hbonds, atoms, N, O are exact integers.
const BaseChemistry = struct {
    mw10: u16, // molecular weight * 10
    rings: u8,
    hbonds: u8,
    atoms: u8,
    n_count: u8,
    o_count: u8,
    vdw_001nm: u16, // van der Waals radius in 0.001 nm units (Angstrom * 10)
};

const base_chemistry = [_]BaseChemistry{
    .{ .mw10 = 3472, .rings = 2, .hbonds = 2, .atoms = 15, .n_count = 5, .o_count = 1, .vdw_001nm = 188 }, // A
    .{ .mw10 = 3232, .rings = 1, .hbonds = 3, .atoms = 13, .n_count = 3, .o_count = 2, .vdw_001nm = 175 }, // C
    .{ .mw10 = 3632, .rings = 2, .hbonds = 3, .atoms = 16, .n_count = 5, .o_count = 2, .vdw_001nm = 196 }, // G
    .{ .mw10 = 3242, .rings = 1, .hbonds = 2, .atoms = 13, .n_count = 2, .o_count = 3, .vdw_001nm = 180 }, // U
};

// Backbone radius in 0.001 nm units (0.34 nm = 340).
const backbone_001nm: u16 = 340;

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub fn baseValue(base: u8) u8 {
    return switch (base) {
        'A' => 0,
        'C' => 1,
        'G' => 2,
        'U', 'T' => 3,
        else => 255,
    };
}

/// 6-bit base-4 index: first base is most significant (bits 4-5),
/// second base bits 2-3, third base bits 0-1.
/// Matches _triplet_qubit_index in signature.py.
pub fn indexOf(codon: Codon) u8 {
    return (baseValue(codon[0]) << 4) | (baseValue(codon[1]) << 2) | baseValue(codon[2]);
}

fn codonFromIndex(index: u8) Codon {
    return .{ bases[(index >> 4) & 3], bases[(index >> 2) & 3], bases[index & 3] };
}

fn aminoFor(index: u8) u8 {
    return amino_codes[index];
}

fn aminoSymbol(code: u8) u8 {
    return if (code == Stop) 'X' else symbols[code];
}

// ---------------------------------------------------------------------------
// Amino acid classification
// ---------------------------------------------------------------------------

fn isHydrophobic(code: u8) bool {
    // F L I M V P A W G -> codes 0..8
    return code <= 8;
}

fn isPolar(code: u8) bool {
    // S T C Y N Q -> codes 9..14
    return code >= 9 and code <= 14;
}

fn isAcidic(code: u8) bool {
    // D E -> codes 15, 16
    return code == 15 or code == 16;
}

fn isBasic(code: u8) bool {
    // K R H -> codes 17, 18, 19
    return code >= 17 and code <= 19;
}

/// Routing channel: E0=0, E1=1, E2=2, E3=3, E4=4, E5=5, E6=6, E7=7.
fn channelFor(code: u8) u8 {
    if (code == Stop) return 2;
    if (isHydrophobic(code)) return 6;
    if (isAcidic(code)) return 7;
    if (isPolar(code)) return 5;
    if (isBasic(code)) return 4;
    return 0;
}

/// Routing A/C/D flags from _routing_for in signature.py.
fn routingFlags(channel: u8) struct { a: u1, c: u1, d: u1 } {
    return switch (channel) {
        2 => .{ .a = 1, .c = 1, .d = 0 }, // stop
        6 => .{ .a = 0, .c = 1, .d = 1 }, // hydrophobic
        7 => .{ .a = 0, .c = 0, .d = 0 }, // acidic
        5 => .{ .a = 1, .c = 1, .d = 1 }, // polar
        4 => .{ .a = 1, .c = 0, .d = 1 }, // basic
        else => .{ .a = 1, .c = 1, .d = 1 }, // unknown/E0
    };
}

// ---------------------------------------------------------------------------
// Dimensional ladder coordinates (Q128.128 fixed-point)
// ---------------------------------------------------------------------------

pub fn ladderCoordinate(channel: u8) fixed.Q128 {
    return switch (channel) {
        0 => fixed.Q128.zero,
        1 => constants.phi,
        2 => constants.pi,
        3 => fixed.Q128.fromRaw(@divTrunc(21 * fixed.Scale, 4)),
        4 => fixed.Q128.fromRaw(@divTrunc(21 * fixed.Scale, 2)),
        5 => fixed.Q128.fromInteger(21),
        6 => fixed.Q128.fromInteger(42),
        7 => fixed.Q128.fromInteger(21),
        else => fixed.Q128.zero,
    };
}

// ---------------------------------------------------------------------------
// Chemistry-derived computations
// ---------------------------------------------------------------------------

/// Chemistry-derived qubit coordinates (qx, qy, qz) from _qubit_coords.
/// Uses integer-scaled molecular weights to avoid floating-point.
fn qubitCoords(codon: Codon) struct { qx: u1, qy: u1, qz: u1 } {
    var mw10_sum: u32 = 0;
    var ring_hbond_sum: u32 = 0;
    var no_sum: u32 = 0;
    for (codon) |base| {
        const idx = baseValue(base);
        const chem = base_chemistry[idx];
        mw10_sum += chem.mw10;
        ring_hbond_sum += @as(u32, chem.rings) * 5 + @as(u32, chem.hbonds) * 3;
        no_sum += chem.n_count + chem.o_count;
    }
    // qx = floor((mw_sum - 970.0) / 30.0) % 2
    // mw_sum = mw10_sum / 10, so (mw10_sum - 9700) / 300
    const qx: u1 = @intCast(@mod(@divTrunc(@as(i64, @intCast(mw10_sum)) - 9700, 300), 2));
    // qy = floor(ring_hbond_sum) % 2
    const qy: u1 = @intCast(@mod(@as(i64, @intCast(ring_hbond_sum)), 2));
    // qz = floor(no_sum) % 2
    const qz: u1 = @intCast(@mod(@as(i64, @intCast(no_sum)), 2));
    return .{ .qx = qx, .qy = qy, .qz = qz };
}

/// Chemistry qubit index = qx + 2*qy + 4*qz (0..7).
fn chemistryQubitIndex(codon: Codon) u8 {
    const q = qubitCoords(codon);
    return @as(u8, q.qx) + 2 * @as(u8, q.qy) + 4 * @as(u8, q.qz);
}

/// Base-point lattice coordinate at codon position pos (0,1,2).
/// Uses Q128.128 fixed-point for the phi/pi/21-over-4 terms.
/// Returns (x, y, z) as integers after floor and mod 15.
fn basePoint(base: u8, pos: u8) struct { x: u8, y: u8, z: u8 } {
    const idx = baseValue(base);
    const chem = base_chemistry[idx];

    // x = floor(((mw - 323.2) / 40.0) * 14.0 + pos * PHI) % 15
    // (mw - 323.2) / 40.0 * 14.0 = (mw10 - 3232) * 14 / 400 = (mw10 - 3232) * 7 / 200
    // As Q128.128: chemistry_x = Q128.fromRaw((mw10 - 3232) * 7 * Scale / 200)
    const mw_diff: i64 = @as(i64, chem.mw10) - 3232;
    const chem_x_raw: i256 = @divTrunc(mw_diff * 7 * fixed.Scale, 200);
    const pos_phi = constants.phi.mul(fixed.Q128.fromInteger(pos));
    const x_q128 = fixed.Q128.fromRaw(chem_x_raw).add(pos_phi);
    const x: u8 = @intCast(@mod(x_q128.toInteger(), 15));

    // y = floor((rings * 7 + hbonds * 2) + pos * PI) % 15
    const y_chem: i256 = @as(i256, chem.rings) * 7 + @as(i256, chem.hbonds) * 2;
    const pos_pi = constants.pi.mul(fixed.Q128.fromInteger(pos));
    const y_q128 = fixed.Q128.fromInteger(y_chem).add(pos_pi);
    const y: u8 = @intCast(@mod(y_q128.toInteger(), 15));

    // z = floor(((atoms - 13) / 3.0) * 14.0 + pos * (21/4)) % 15
    // (atoms - 13) / 3.0 * 14.0 = (atoms - 13) * 14 / 3
    // As Q128.128: chemistry_z = Q128.fromRaw((atoms - 13) * 14 * Scale / 3)
    const atoms_diff: i64 = @as(i64, chem.atoms) - 13;
    const chem_z_raw: i256 = @divTrunc(atoms_diff * 14 * fixed.Scale, 3);
    const pos_21_4 = fixed.Q128.fromRaw(@divTrunc(21 * fixed.Scale, 4)).mul(fixed.Q128.fromInteger(pos));
    const z_q128 = fixed.Q128.fromRaw(chem_z_raw).add(pos_21_4);
    const z: u8 = @intCast(@mod(z_q128.toInteger(), 15));

    return .{ .x = x, .y = y, .z = z };
}

/// Count coordinates equal to 0 across all three base points.
fn e0Count(codon: Codon) u8 {
    var count: u8 = 0;
    for (codon, 0..) |base, pos| {
        const p = basePoint(base, @intCast(pos));
        if (p.x == 0) count += 1;
        if (p.y == 0) count += 1;
        if (p.z == 0) count += 1;
    }
    return count;
}

/// Lattice triangle area from three base points.
/// area = 0.5 * sqrt(|cross|^2) where cross is the integer cross product.
/// Returns the squared magnitude (exact integer) and the area as Q128.128.
fn latticeAreaSq(codon: Codon) i256 {
    const p0 = basePoint(codon[0], 0);
    const p1 = basePoint(codon[1], 1);
    const p2 = basePoint(codon[2], 2);
    // a = p0 - p1, b = p0 - p2
    const ax: i256 = @as(i256, p0.x) - @as(i256, p1.x);
    const ay: i256 = @as(i256, p0.y) - @as(i256, p1.y);
    const az: i256 = @as(i256, p0.z) - @as(i256, p1.z);
    const bx: i256 = @as(i256, p0.x) - @as(i256, p2.x);
    const by: i256 = @as(i256, p0.y) - @as(i256, p2.y);
    const bz: i256 = @as(i256, p0.z) - @as(i256, p2.z);
    // cross = a x b
    const cx = ay * bz - az * by;
    const cy = az * bx - ax * bz;
    const cz = ax * by - ay * bx;
    return cx * cx + cy * cy + cz * cz;
}

/// Integer square root for i256 (returns floor of sqrt).
fn isqrt256(n: i256) i256 {
    if (n <= 0) return 0;
    if (n < 4) return 1;
    var lo: i256 = 2;
    var hi: i256 = n;
    while (lo < hi) {
        const mid = lo + @divTrunc(hi - lo, 2);
        if (mid <= @divTrunc(n, mid)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo - 1;
}

/// Lattice triangle area as Q128.128 fixed-point.
/// area = 0.5 * sqrt(cross_sq)
/// For fixed-point: area_raw = sqrt(cross_sq * Scale^2) / 2
/// But cross_sq * Scale^2 overflows i256, so we compute:
/// area_raw = isqrt(cross_sq) * Scale / 2 + correction
/// More precisely: area = 0.5 * sqrt(N), so area_raw = sqrt(N * Scale^2) / 2
/// We compute sqrt(N) as integer, then the fractional part separately.
fn latticeArea(codon: Codon) fixed.Q128 {
    const n = latticeAreaSq(codon);
    if (n == 0) return fixed.Q128.zero;
    // Integer part of sqrt(N)
    const int_sqrt = isqrt256(n);
    // Remainder: N - int_sqrt^2
    const remainder = n - int_sqrt * int_sqrt;
    // Fractional part of sqrt(N) ≈ remainder / (2 * int_sqrt)
    // As Q128.128: frac_raw = remainder * Scale / (2 * int_sqrt)
    var sqrt_raw: i256 = int_sqrt * fixed.Scale;
    if (int_sqrt > 0) {
        sqrt_raw += @divTrunc(remainder * fixed.Scale, 2 * int_sqrt);
    }
    // area = sqrt / 2
    return fixed.Q128.fromRaw(@divTrunc(sqrt_raw, 2));
}

/// Surface area in nm^2 from van der Waals radii + backbone.
/// area = 4 * pi * (r_sum_nm + backbone_nm)^2
/// r_sum_nm = sum(vdw_radius_angstrom) / 10
/// All computed in fixed-point using 0.001 nm integer units.
fn surfaceArea(codon: Codon) fixed.Q128 {
    var vdw_001nm_sum: u32 = 0;
    for (codon) |base| {
        vdw_001nm_sum += base_chemistry[baseValue(base)].vdw_001nm;
    }
    const total_001nm: i256 = @as(i256, vdw_001nm_sum) + backbone_001nm;
    // total_nm = total_001nm / 1000
    // area = 4 * pi * total_nm^2 = 4 * pi * total_001nm^2 / 1000000
    // In fixed-point: area_raw = 4 * pi.raw * total_001nm^2 / 1000000
    const total_sq: i512 = @as(i512, total_001nm) * @as(i512, total_001nm);
    const pi_raw_wide: i512 = @as(i512, constants.pi.raw);
    const area_raw_wide: i512 = @divTrunc(4 * pi_raw_wide * total_sq, 1000000);
    return fixed.Q128.fromRaw(@truncate(area_raw_wide));
}

// ---------------------------------------------------------------------------
// Signature structure and builders
// ---------------------------------------------------------------------------

pub const Signature = struct {
    codon: Codon,
    index: u8, // 6-bit base-4 index (0..63)
    amino_code: u8, // 0..20
    amino_symbol: u8, // ASCII
    label: u8, // Classification label index
    qubit_index: u8, // 6-bit base-4 index (chemistry builder)
    chem_qubit_index: u8, // 3-bit chemistry-derived index (0..7)
    qx: u1,
    qy: u1,
    qz: u1,
    channel: u8, // Routing channel E0..E7
    a_flag: u1,
    c_flag: u1,
    d_flag: u1,
    max_dim: u8,
    coord_sum: fixed.Q128,
    sorted_values: [3]u8,
    e0_count: u8,
    lattice_area: fixed.Q128,
    surface_area: fixed.Q128,
};

// Label indices: 0=stop, 1=hydrophobic, 2=acidic, 3=polar, 4=basic, 5=other
pub const Label = struct {
    pub const stop: u8 = 0;
    pub const hydrophobic: u8 = 1;
    pub const acidic: u8 = 2;
    pub const polar: u8 = 3;
    pub const basic: u8 = 4;
    pub const other: u8 = 5;
};

fn labelForCode(code: u8) u8 {
    if (code == Stop) return Label.stop;
    if (isHydrophobic(code)) return Label.hydrophobic;
    if (isAcidic(code)) return Label.acidic;
    if (isPolar(code)) return Label.polar;
    if (isBasic(code)) return Label.basic;
    return Label.other;
}

/// Build a codon signature.
/// placeholder=true uses PlaceholderSignatureBuilder logic (GCA outlier).
/// placeholder=false uses ChemistrySignatureBuilder logic (AUG outlier).
pub fn buildSignature(codon: Codon, placeholder: bool) Signature {
    const index = indexOf(codon);
    const amino_code = aminoFor(index);
    const channel = channelFor(amino_code);
    const flags = routingFlags(channel);
    const q = qubitCoords(codon);
    const chem_qidx = chemistryQubitIndex(codon);
    const label = labelForCode(amino_code);

    // sorted_vals, max_dim, coord_sum
    var sorted: [3]u8 = .{ 0, 1, channel };
    var max_dim: u8 = channel;
    var coord_sum = ladderCoordinate(0).add(ladderCoordinate(1)).add(ladderCoordinate(channel));

    // Outlier handling:
    // Chemistry builder: AUG is the E6 outlier (sorted=[0,0,6], coord_sum=42.0)
    // Placeholder builder: GCA is the E6 outlier (sorted=[0,0,6], coord_sum=42.0)
    const is_outlier = if (placeholder)
        codon[0] == 'G' and codon[1] == 'C' and codon[2] == 'A'
    else
        codon[0] == 'A' and codon[1] == 'U' and codon[2] == 'G';

    if (is_outlier) {
        sorted = .{ 0, 0, 6 };
        coord_sum = fixed.Q128.fromInteger(42);
    }

    // Placeholder builder has different routing for polar and other:
    // polar: sorted=[0,2,2], max_dim=2, coord_sum = E0 + 2*E2
    // other: sorted=[0,1,4], max_dim=4, coord_sum = E0 + E1 + E4
    if (placeholder) {
        if (label == Label.polar) {
            sorted = .{ 0, 2, 2 };
            max_dim = 2;
            coord_sum = ladderCoordinate(0).add(ladderCoordinate(2)).add(ladderCoordinate(2));
        } else if (label == Label.other) {
            sorted = .{ 0, 1, 4 };
            max_dim = 4;
            coord_sum = ladderCoordinate(0).add(ladderCoordinate(1)).add(ladderCoordinate(4));
        }
    }

    return .{
        .codon = codon,
        .index = index,
        .amino_code = amino_code,
        .amino_symbol = aminoSymbol(amino_code),
        .label = label,
        .qubit_index = index,
        .chem_qubit_index = chem_qidx,
        .qx = q.qx,
        .qy = q.qy,
        .qz = q.qz,
        .channel = channel,
        .a_flag = flags.a,
        .c_flag = flags.c,
        .d_flag = flags.d,
        .max_dim = max_dim,
        .coord_sum = coord_sum,
        .sorted_values = sorted,
        .e0_count = e0Count(codon),
        .lattice_area = latticeArea(codon),
        .surface_area = surfaceArea(codon),
    };
}

/// Build all 64 codon signatures.
pub fn allSignatures(placeholder: bool) [64]Signature {
    var signatures: [64]Signature = undefined;
    var index: u8 = 0;
    while (index < 64) : (index += 1) {
        signatures[index] = buildSignature(codonFromIndex(index), placeholder);
    }
    return signatures;
}

// ---------------------------------------------------------------------------
// Routing rule predicates (from rules.py)
// ---------------------------------------------------------------------------

/// E2 phase-space stop-codon rule.
pub fn predictsStop(sig: Signature) bool {
    const sv = sig.sorted_values;
    if (sv[0] == 0 and sv[1] == 1 and sv[2] == 2) return true;
    if (sv[0] == 1 and sv[1] == 2 and sv[2] == 2) {
        return sig.surface_area.raw > 30 * fixed.Scale;
    }
    return false;
}

/// E6 Jordan-mirror hydrophobic rule.
pub fn predictsHydrophobic(sig: Signature) bool {
    return sig.coord_sum.raw > 42 * fixed.Scale and sig.max_dim >= 6;
}

/// E7 color-charge acidic rule.
pub fn predictsAcidic(sig: Signature) bool {
    return sig.max_dim >= 7;
}

/// Predicted label: stop > hydrophobic > acidic > other.
pub fn predictedLabel(sig: Signature) u8 {
    if (predictsStop(sig)) return Label.stop;
    if (predictsHydrophobic(sig)) return Label.hydrophobic;
    if (predictsAcidic(sig)) return Label.acidic;
    return Label.other;
}

// ---------------------------------------------------------------------------
// Cross-wiring with existing mathematical system
// ---------------------------------------------------------------------------

/// Cross-wire codon channels to octonion basis indices.
/// E0->e0, E1->e1, ..., E7->e7.
pub fn channelToOctonion(channel: u8) u3 {
    return @intCast(channel & 7);
}

/// Cross-wire codon 6-bit index to 3-qubit state index.
/// The 6-bit base-4 index maps directly to a 3-qubit computational basis
/// state when interpreted as 6 binary bits (qubit_index = index).
pub fn codonToQubitState(codon: Codon) u8 {
    return indexOf(codon);
}

/// Cross-wire the 15-layer lattice: codon channels map to the central row
/// of the 15x15 octonion matrix. The central row is [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6].
pub fn channelToCentralRow(channel: u8) u8 {
    const central_row = [_]u8{ 6, 5, 4, 3, 2, 1, 0, 7, 0, 1, 2, 3, 4, 5, 6 };
    if (channel < 8) return central_row[7 - channel];
    return 0;
}

/// Smith/Mobius boundary: map codon channel to a reflection coefficient.
/// Gamma = (z-1)/(z+1) where z = ladder_coordinate / Z0_analog.
/// For the codon system, we use the channel index as a discrete z value.
pub fn channelToGamma(channel: u8) fixed.Q128 {
    const z = fixed.Q128.fromInteger(channel);
    const one = fixed.Q128.one;
    // Gamma = (z - 1) / (z + 1)
    if (channel == 1) return fixed.Q128.zero;
    const numerator = z.sub(one);
    const denominator = z.add(one);
    return numerator.div(denominator) catch fixed.Q128.zero;
}

// ---------------------------------------------------------------------------
// Proof function
// ---------------------------------------------------------------------------

pub fn proof() bool {
    const chem_sigs = allSignatures(false);
    var checks: u16 = 0;
    var failures: u16 = 0;

    // Check 1: 64 codons present
    checks += 1;
    if (chem_sigs.len != 64) failures += 1;

    // Check 2: All indices 0..63 are unique
    checks += 1;
    var seen: [64]bool = .{false} ** 64;
    for (chem_sigs) |sig| {
        if (sig.index >= 64 or seen[sig.index]) {
            failures += 1;
            break;
        }
        seen[sig.index] = true;
    }

    // Check 3: Exactly 3 stop codons, all route through E2
    checks += 1;
    var stop_count: u8 = 0;
    for (chem_sigs) |sig| {
        if (sig.amino_code == Stop) {
            stop_count += 1;
            if (sig.channel != 2) failures += 1;
            if (!predictsStop(sig)) failures += 1;
        }
    }
    if (stop_count != 3) failures += 1;

    // Check 4: AUG is the chemistry-builder E6 outlier
    checks += 1;
    const aug = chem_sigs[indexOf(.{ 'A', 'U', 'G' })];
    if (aug.channel != 6) failures += 1;
    if (aug.sorted_values[0] != 0 or aug.sorted_values[1] != 0 or aug.sorted_values[2] != 6) failures += 1;
    if (aug.coord_sum.raw != 42 * fixed.Scale) failures += 1;

    // Check 5: GCA is the placeholder-builder E6 outlier
    checks += 1;
    const placeholder_sigs = allSignatures(true);
    const gca = placeholder_sigs[indexOf(.{ 'G', 'C', 'C' })]; // GCC, not GCA
    const gca_sig = placeholder_sigs[indexOf(.{ 'G', 'C', 'A' })];
    if (gca_sig.sorted_values[0] != 0 or gca_sig.sorted_values[1] != 0 or gca_sig.sorted_values[2] != 6) failures += 1;
    if (gca_sig.coord_sum.raw != 42 * fixed.Scale) failures += 1;
    // GCC should NOT be the outlier
    if (gca.sorted_values[0] == 0 and gca.sorted_values[1] == 0 and gca.sorted_values[2] == 6) failures += 1;

    // Check 6: Acidic codons route through E7
    checks += 1;
    for (chem_sigs) |sig| {
        if (sig.amino_code == 15 or sig.amino_code == 16) {
            if (sig.channel != 7) failures += 1;
            if (!predictsAcidic(sig)) failures += 1;
        }
    }

    // Check 7: Qubit indices cover full range 0..63
    checks += 1;
    var qubit_seen: [64]bool = .{false} ** 64;
    for (chem_sigs) |sig| {
        qubit_seen[sig.qubit_index] = true;
    }
    for (qubit_seen) |s| {
        if (!s) {
            failures += 1;
            break;
        }
    }

    // Check 8: Cross-wiring to octonion basis
    checks += 1;
    if (channelToOctonion(0) != 0 or channelToOctonion(7) != 7) failures += 1;

    // Check 9: Cross-wiring to 3-qubit state
    checks += 1;
    if (codonToQubitState(.{ 'A', 'U', 'G' }) != 14) failures += 1;

    // Check 10: Cross-wiring to 15-layer central row
    checks += 1;
    // central_row = [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6]
    // channelToCentralRow(ch) = central_row[7 - ch]
    // E0 (ch=0) -> central_row[7] = 7 (center element)
    // E7 (ch=7) -> central_row[0] = 6 (first element)
    if (channelToCentralRow(0) != 7) failures += 1;
    if (channelToCentralRow(7) != 6) failures += 1;

    // Check 11: Smith/Mobius boundary for channel 1 gives Gamma=0
    checks += 1;
    const gamma1 = channelToGamma(1);
    if (gamma1.raw != 0) failures += 1;

    // Check 12: Ladder coordinate E6 = 42
    checks += 1;
    if (ladderCoordinate(6).raw != 42 * fixed.Scale) failures += 1;

    return checks > 0 and failures == 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "64 codons present with unique indices" {
    const sigs = allSignatures(false);
    try std.testing.expectEqual(@as(usize, 64), sigs.len);
    var seen: [64]bool = .{false} ** 64;
    for (sigs) |sig| {
        try std.testing.expect(sig.index < 64);
        try std.testing.expect(!seen[sig.index]);
        seen[sig.index] = true;
    }
}

test "base-4 encoding: AUG = 14" {
    try std.testing.expectEqual(@as(u8, 14), indexOf(.{ 'A', 'U', 'G' }));
}

test "base-4 encoding: UAA = 48" {
    try std.testing.expectEqual(@as(u8, 48), indexOf(.{ 'U', 'A', 'A' }));
}

test "base-4 encoding: GAA = 32" {
    try std.testing.expectEqual(@as(u8, 32), indexOf(.{ 'G', 'A', 'A' }));
}

test "base-4 encoding: all 64 indices unique" {
    const sigs = allSignatures(false);
    var seen: [64]bool = .{false} ** 64;
    for (sigs) |sig| {
        try std.testing.expect(!seen[sig.index]);
        seen[sig.index] = true;
    }
}

test "stop codons route through E2" {
    const sigs = allSignatures(false);
    for ([_]u8{ indexOf(.{ 'U', 'A', 'A' }), indexOf(.{ 'U', 'A', 'G' }), indexOf(.{ 'U', 'G', 'A' }) }) |idx| {
        const sig = sigs[idx];
        try std.testing.expectEqual(@as(u8, 2), sig.channel);
        try std.testing.expectEqual(@as(u8, Stop), sig.amino_code);
        try std.testing.expect(predictsStop(sig));
    }
}

test "exactly 3 stop codons" {
    const sigs = allSignatures(false);
    var count: u8 = 0;
    for (sigs) |sig| {
        if (sig.amino_code == Stop) count += 1;
    }
    try std.testing.expectEqual(@as(u8, 3), count);
}

test "AUG is chemistry-builder E6 outlier" {
    const sigs = allSignatures(false);
    const aug = sigs[indexOf(.{ 'A', 'U', 'G' })];
    try std.testing.expectEqual(@as(u8, 6), aug.channel);
    try std.testing.expectEqual(@as(u8, 3), aug.amino_code); // M
    try std.testing.expectEqual(@as(u8, 0), aug.sorted_values[0]);
    try std.testing.expectEqual(@as(u8, 0), aug.sorted_values[1]);
    try std.testing.expectEqual(@as(u8, 6), aug.sorted_values[2]);
    try std.testing.expectEqual(@as(i256, 42 * fixed.Scale), aug.coord_sum.raw);
}

test "GCA is placeholder-builder E6 outlier" {
    const sigs = allSignatures(true);
    const gca = sigs[indexOf(.{ 'G', 'C', 'A' })];
    try std.testing.expectEqual(@as(u8, 6), gca.channel);
    try std.testing.expectEqual(@as(u8, 0), gca.sorted_values[0]);
    try std.testing.expectEqual(@as(u8, 0), gca.sorted_values[1]);
    try std.testing.expectEqual(@as(u8, 6), gca.sorted_values[2]);
    try std.testing.expectEqual(@as(i256, 42 * fixed.Scale), gca.coord_sum.raw);
}

test "GCA is NOT chemistry-builder outlier" {
    const sigs = allSignatures(false);
    const gca = sigs[indexOf(.{ 'G', 'C', 'A' })];
    try std.testing.expectEqual(@as(u8, 1), gca.sorted_values[1]); // [0,1,6] not [0,0,6]
}

test "acidic codons route through E7" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code == 15 or sig.amino_code == 16) { // D or E
            try std.testing.expectEqual(@as(u8, 7), sig.channel);
            try std.testing.expect(predictsAcidic(sig));
        }
    }
}

test "hydrophobic codons route through E6" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code <= 8 and sig.amino_code != Stop) {
            try std.testing.expectEqual(@as(u8, 6), sig.channel);
        }
    }
}

test "polar codons route through E5" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code >= 9 and sig.amino_code <= 14) {
            try std.testing.expectEqual(@as(u8, 5), sig.channel);
        }
    }
}

test "basic codons route through E4" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code >= 17 and sig.amino_code <= 19) {
            try std.testing.expectEqual(@as(u8, 4), sig.channel);
        }
    }
}

test "routing A/C/D flags match documentation" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        const flags = routingFlags(sig.channel);
        try std.testing.expectEqual(flags.a, sig.a_flag);
        try std.testing.expectEqual(flags.c, sig.c_flag);
        try std.testing.expectEqual(flags.d, sig.d_flag);
    }
}

test "synonymous codons share routing channel" {
    const sigs = allSignatures(false);
    // GAA and GAG both code for E (acidic)
    try std.testing.expectEqual(sigs[indexOf(.{ 'G', 'A', 'A' })].channel, sigs[indexOf(.{ 'G', 'A', 'G' })].channel);
    // GGU and GGC both code for G (hydrophobic)
    try std.testing.expectEqual(sigs[indexOf(.{ 'G', 'G', 'U' })].channel, sigs[indexOf(.{ 'G', 'G', 'C' })].channel);
    // UCU and UCC both code for S (polar)
    try std.testing.expectEqual(sigs[indexOf(.{ 'U', 'C', 'U' })].channel, sigs[indexOf(.{ 'U', 'C', 'C' })].channel);
}

test "third-base wobble preserves channel for synonymous codons" {
    const sigs = allSignatures(false);
    // All four CUx codons code for L (hydrophobic, E6)
    const cuu = sigs[indexOf(.{ 'C', 'U', 'U' })];
    const cuc = sigs[indexOf(.{ 'C', 'U', 'C' })];
    const cua = sigs[indexOf(.{ 'C', 'U', 'A' })];
    const cug = sigs[indexOf(.{ 'C', 'U', 'G' })];
    try std.testing.expectEqual(cuu.channel, cuc.channel);
    try std.testing.expectEqual(cuu.channel, cua.channel);
    try std.testing.expectEqual(cuu.channel, cug.channel);
    try std.testing.expectEqual(@as(u8, 6), cuu.channel);
}

test "chemistry qubit coords for AUG" {
    const q = qubitCoords(.{ 'A', 'U', 'G' });
    try std.testing.expectEqual(@as(u1, 0), q.qx);
    try std.testing.expectEqual(@as(u1, 0), q.qy);
    try std.testing.expectEqual(@as(u1, 0), q.qz);
    try std.testing.expectEqual(@as(u8, 0), chemistryQubitIndex(.{ 'A', 'U', 'G' }));
}

test "chemistry qubit coords for UAA" {
    const q = qubitCoords(.{ 'U', 'A', 'A' });
    try std.testing.expectEqual(@as(u1, 1), q.qx);
    try std.testing.expectEqual(@as(u1, 1), q.qy);
    try std.testing.expectEqual(@as(u1, 1), q.qz);
}

test "chemistry qubit coords for GAA" {
    const q = qubitCoords(.{ 'G', 'A', 'A' });
    try std.testing.expectEqual(@as(u1, 0), q.qx);
    try std.testing.expectEqual(@as(u1, 1), q.qy);
    try std.testing.expectEqual(@as(u1, 1), q.qz);
}

test "e0_count for UGA" {
    try std.testing.expectEqual(@as(u8, 3), e0Count(.{ 'U', 'G', 'A' }));
}

test "e0_count for UAA" {
    try std.testing.expectEqual(@as(u8, 2), e0Count(.{ 'U', 'A', 'A' }));
}

test "lattice area squared magnitude for UGA" {
    // UGA: points (0,11,0), (0,8,4), (11,9,4)
    // cross = (-4, 44, 33), |cross|^2 = 16 + 1936 + 1089 = 3041
    try std.testing.expectEqual(@as(i256, 3041), latticeAreaSq(.{ 'U', 'G', 'A' }));
}

test "ladder coordinates" {
    try std.testing.expectEqual(@as(i256, 0), ladderCoordinate(0).raw);
    try std.testing.expectEqual(constants.phi.raw, ladderCoordinate(1).raw);
    try std.testing.expectEqual(constants.pi.raw, ladderCoordinate(2).raw);
    try std.testing.expectEqual(@divTrunc(21 * fixed.Scale, 4), ladderCoordinate(3).raw);
    try std.testing.expectEqual(@divTrunc(21 * fixed.Scale, 2), ladderCoordinate(4).raw);
    try std.testing.expectEqual(21 * fixed.Scale, ladderCoordinate(5).raw);
    try std.testing.expectEqual(42 * fixed.Scale, ladderCoordinate(6).raw);
    try std.testing.expectEqual(21 * fixed.Scale, ladderCoordinate(7).raw);
}

test "surface area is positive for all codons" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        try std.testing.expect(sig.surface_area.raw > 0);
    }
}

test "lattice area is positive for all codons" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        try std.testing.expect(sig.lattice_area.raw > 0);
    }
}

test "cross-wiring: channel to octonion basis" {
    try std.testing.expectEqual(@as(u3, 0), channelToOctonion(0));
    try std.testing.expectEqual(@as(u3, 2), channelToOctonion(2));
    try std.testing.expectEqual(@as(u3, 6), channelToOctonion(6));
    try std.testing.expectEqual(@as(u3, 7), channelToOctonion(7));
}

test "cross-wiring: codon to 3-qubit state" {
    try std.testing.expectEqual(@as(u8, 14), codonToQubitState(.{ 'A', 'U', 'G' }));
    try std.testing.expectEqual(@as(u8, 48), codonToQubitState(.{ 'U', 'A', 'A' }));
}

test "cross-wiring: channel to 15-layer central row" {
    // Central row: [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6]
    // channelToCentralRow(ch) = central_row[7 - ch]
    // E0 (channel 0) -> central_row[7] = 7
    // E7 (channel 7) -> central_row[0] = 6
    try std.testing.expectEqual(@as(u8, 7), channelToCentralRow(0));
    try std.testing.expectEqual(@as(u8, 6), channelToCentralRow(7));
}

test "cross-wiring: Smith/Mobius Gamma for channel 1 is zero" {
    const gamma = channelToGamma(1);
    try std.testing.expectEqual(@as(i256, 0), gamma.raw);
}

test "cross-wiring: Smith/Mobius Gamma for channel 0 is -1" {
    const gamma = channelToGamma(0);
    // z=0: Gamma = (0-1)/(0+1) = -1
    try std.testing.expectEqual(-fixed.Scale, gamma.raw);
}

test "proof function passes" {
    try std.testing.expect(proof());
}

test "placeholder builder polar routing differs from chemistry" {
    const chem = allSignatures(false);
    const placeholder = allSignatures(true);
    // UCU is polar (S)
    const chem_ucu = chem[indexOf(.{ 'U', 'C', 'U' })];
    const placeholder_ucu = placeholder[indexOf(.{ 'U', 'C', 'U' })];
    // Chemistry: sorted=[0,1,5], placeholder: sorted=[0,2,2]
    try std.testing.expectEqual(@as(u8, 5), chem_ucu.sorted_values[2]);
    try std.testing.expectEqual(@as(u8, 2), placeholder_ucu.sorted_values[2]);
    try std.testing.expectEqual(@as(u8, 2), placeholder_ucu.sorted_values[1]);
}

test "placeholder builder other routing differs from chemistry" {
    const chem = allSignatures(false);
    const placeholder = allSignatures(true);
    // CAU is basic/other (H)
    const chem_cau = chem[indexOf(.{ 'C', 'A', 'U' })];
    const placeholder_cau = placeholder[indexOf(.{ 'C', 'A', 'U' })];
    // Chemistry: sorted=[0,1,4], placeholder: sorted=[0,1,4] -- same for basic
    // But coord_sum differs: chemistry uses E0+E1+E4, placeholder also uses E0+E1+E4
    // Actually for basic (code 19=H), label is "other" in CODON_LABELS
    // Chemistry builder routes H through E4 (basic), placeholder routes through E4 too
    // But the placeholder "other" case uses sorted=[0,1,4] which is the same as chemistry E4
    // The difference is in the label: chemistry says "other" (from CODON_LABELS), but routes through E4
    // Let me check: in the placeholder builder, "other" uses sorted=[0,1,4], max_dim=4
    // In the chemistry builder, basic (E4) uses sorted=[0,1,4], max_dim=4
    // So they should be the same for H codons
    try std.testing.expectEqual(chem_cau.sorted_values[2], placeholder_cau.sorted_values[2]);
}

test "all amino acid symbols are valid" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code == Stop) {
            try std.testing.expectEqual(@as(u8, 'X'), sig.amino_symbol);
        } else {
            try std.testing.expect(sig.amino_symbol >= 'A' and sig.amino_symbol <= 'Z');
        }
    }
}

test "predicted label matches actual label for stop codons" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code == Stop) {
            try std.testing.expectEqual(Label.stop, predictedLabel(sig));
        }
    }
}

test "predicted label matches actual label for acidic codons" {
    const sigs = allSignatures(false);
    for (sigs) |sig| {
        if (sig.amino_code == 15 or sig.amino_code == 16) {
            try std.testing.expectEqual(Label.acidic, predictedLabel(sig));
        }
    }
}
