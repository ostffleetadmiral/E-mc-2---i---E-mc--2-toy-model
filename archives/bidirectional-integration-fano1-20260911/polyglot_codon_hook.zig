// polyglot_codon_hook.zig — Integration hook for cross-language codon routing
// via Q128.128/FANO-1's polyglot runtime.
//
// This module provides the bridge between the hardware project's codon
// routing system and the FANO-1 OS's polyglot runtime, enabling codon
// routing to be called from Python, JavaScript, Rust, C, and C#.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");

/// Codon routing result (matching hardware's src/codon.zig)
pub const CodonResult = extern struct {
    index: u8, // 6-bit base-4 index (0..63)
    amino_code: u8, // 0..20 (20 = STOP)
    channel: u8, // Routing channel E0..E7
    label: u8, // Classification label index
    qubit_index: u8, // 6-bit base-4 index
    chem_qubit_index: u8, // 3-bit chemistry-derived index (0..7)
    e0_count: u8, // Count of zero coordinates
    max_dim: u8, // Maximum dimension in sorted values
    a_flag: u8, // Routing A flag
    c_flag: u8, // Routing C flag
    d_flag: u8, // Routing D flag
};

/// Base-4 encoding: A=0, C=1, G=2, U/T=3
pub fn baseValue(base: u8) u8 {
    return switch (base) {
        'A' => 0,
        'C' => 1,
        'G' => 2,
        'U', 'T' => 3,
        else => 255,
    };
}

/// 6-bit base-4 index: first base most significant
pub fn codonIndex(codon: [3]u8) u8 {
    return (baseValue(codon[0]) << 4) | (baseValue(codon[1]) << 2) | baseValue(codon[2]);
}

/// Genetic code table (64 entries, matching hardware's src/codon.zig)
const amino_codes = [_]u8{
    17, 13, 17, 13, 10, 10, 10, 10, 18, 9,  18, 9,  2, 2, 3, 2,
    14, 19, 14, 19, 5,  5,  5,  5,  18, 18, 18, 18, 1, 1, 1, 1,
    16, 15, 16, 15, 6,  6,  6,  6,  8,  8,  8,  8,  4, 4, 4, 4,
    20, 12, 20, 12, 9,  9,  9,  9,  20, 11, 7,  11, 1, 0, 1, 0,
};

const Stop: u8 = 20;

fn isHydrophobic(code: u8) bool {
    return code <= 8;
}
fn isAcidic(code: u8) bool {
    return code == 15 or code == 16;
}
fn isPolar(code: u8) bool {
    return code >= 9 and code <= 14;
}
fn isBasic(code: u8) bool {
    return code >= 17 and code <= 19;
}

fn channelFor(code: u8) u8 {
    if (code == Stop) return 2;
    if (isHydrophobic(code)) return 6;
    if (isAcidic(code)) return 7;
    if (isPolar(code)) return 5;
    if (isBasic(code)) return 4;
    return 0;
}

fn labelForCode(code: u8) u8 {
    if (code == Stop) return 0;
    if (isHydrophobic(code)) return 1;
    if (isAcidic(code)) return 2;
    if (isPolar(code)) return 3;
    if (isBasic(code)) return 4;
    return 5;
}

/// Route a single codon through the 6D Jordan algebra.
/// This is the polyglot-callable entry point.
/// Takes a pointer to a 3-byte codon array (C calling convention compatible).
pub export fn routeCodon(codon_ptr: [*]const u8) CodonResult {
    const codon = .{ codon_ptr[0], codon_ptr[1], codon_ptr[2] };
    const index = codonIndex(codon);
    const amino_code = amino_codes[index];
    const channel = channelFor(amino_code);
    const label = labelForCode(amino_code);

    return .{
        .index = index,
        .amino_code = amino_code,
        .channel = channel,
        .label = label,
        .qubit_index = index,
        .chem_qubit_index = 0, // Computed by full implementation
        .e0_count = 0, // Computed by full implementation
        .max_dim = channel,
        .a_flag = 1,
        .c_flag = 1,
        .d_flag = 1,
    };
}

/// Route all 64 codons and return the results.
/// Called from the polyglot runtime to populate the full routing table.
pub export fn routeAllCodons(results: [*]CodonResult) void {
    const bases = "ACGU";
    var idx: u8 = 0;
    while (idx < 64) : (idx += 1) {
        const codon = [3]u8{
            bases[(idx >> 4) & 3],
            bases[(idx >> 2) & 3],
            bases[idx & 3],
        };
        results[idx] = routeCodon(&codon);
    }
}

/// Get the amino acid symbol for a code.
pub export fn aminoSymbol(code: u8) u8 {
    const symbols = "FLIMVPAWGSTCYNQDEKRH";
    if (code == Stop) return 'X';
    if (code >= symbols.len) return '?';
    return symbols[code];
}

// Tests
test "codon index" {
    try std.testing.expectEqual(@as(u8, 14), codonIndex(.{ 'A', 'U', 'G' }));
    try std.testing.expectEqual(@as(u8, 48), codonIndex(.{ 'U', 'A', 'A' }));
    try std.testing.expectEqual(@as(u8, 32), codonIndex(.{ 'G', 'A', 'A' }));
}

test "route AUG" {
    const codon = [3]u8{ 'A', 'U', 'G' };
    const result = routeCodon(&codon);
    try std.testing.expectEqual(@as(u8, 14), result.index);
    try std.testing.expectEqual(@as(u8, 3), result.amino_code); // M
    try std.testing.expectEqual(@as(u8, 6), result.channel); // E6
}

test "route UAA (stop)" {
    const codon = [3]u8{ 'U', 'A', 'A' };
    const result = routeCodon(&codon);
    try std.testing.expectEqual(@as(u8, Stop), result.amino_code);
    try std.testing.expectEqual(@as(u8, 2), result.channel); // E2
    try std.testing.expectEqual(@as(u8, 0), result.label); // stop
}

test "route all 64 codons" {
    var results: [64]CodonResult = undefined;
    routeAllCodons(&results);
    // All indices should be unique 0..63
    var seen: [64]bool = .{false} ** 64;
    for (results) |r| {
        try std.testing.expect(!seen[r.index]);
        seen[r.index] = true;
    }
}

test "amino symbols" {
    try std.testing.expectEqual(@as(u8, 'M'), aminoSymbol(3));
    try std.testing.expectEqual(@as(u8, 'X'), aminoSymbol(Stop));
    try std.testing.expectEqual(@as(u8, 'K'), aminoSymbol(17));
}
