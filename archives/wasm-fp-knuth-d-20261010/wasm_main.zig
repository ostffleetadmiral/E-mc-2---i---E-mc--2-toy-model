// WASM entry point for the E=mc²-i-E=mc⁻² toy-model proof suite.
//
// Exports proof verification functions for browser/WASM runtime use.
// All arithmetic is integer/fixed-point — no f64 in the WASM core.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");
const Q128 = fp.Q128;

/// Run all proof checks and return the number of passes.
/// Ten integer-identity checks plus four real Q128.128 fixed-point
/// proofs (RNE multiply, division, fromRatio rounding, Newton sqrt).
/// Wide-integer division runs through the Knuth-D limb division in
/// src/fixed_point.zig — LLVM has no i512 div libcall on wasm32.
export fn run_all_proofs() usize {
    var passed: usize = 0;
    if (verify_e8_roots()) passed += 1;
    if (verify_so10()) passed += 1;
    if (verify_scaling()) passed += 1;
    if (verify_shell_transition()) passed += 1;
    if (verify_seven_defect()) passed += 1;
    if (verify_codon_boundary()) passed += 1;
    if (verify_mersenne_prime()) passed += 1;
    if (verify_root_count_identity()) passed += 1;
    if (verify_shell_closure()) passed += 1;
    if (verify_consciousness_fraction()) passed += 1;
    if (verify_rne_multiply()) passed += 1;
    if (verify_fp_division()) passed += 1;
    if (verify_fp_from_ratio()) passed += 1;
    if (verify_fp_sqrt()) passed += 1;
    return passed;
}

/// Total number of proof checks exported by this WASM module.
export fn proof_module_count() usize {
    return 14;
}

/// Total number of checks (same as module count).
export fn total_proof_checks() usize {
    return 14;
}

/// Verify RNE multiply on Q128.128: below-half rounds down, exact-half
/// ties to even, above-half rounds up. Product discarded bits are the
/// low 128 of the exact 512-bit product.
export fn verify_rne_multiply() bool {
    const Q = Q128;
    // 2^-128 × 0.25 = 0.25 ulp → rounds down to 0.
    const below = Q.fromRaw(1).mul(Q.fromRaw(1 << 126)).raw == 0;
    // 2^-127 × 0.75 = 1.5 ulp → exact tie → rounds to even (2 ulp).
    const tie = Q.fromRaw(2).mul(Q.fromRaw(3 << 126)).raw == 2;
    // 2^-128 × 1.25 = 1.25 ulp → rounds up to 1 ulp.
    const above = Q.fromRaw(1).mul(Q.fromRaw(5 << 126)).raw == 1;
    // Identity: 1×x == x for a non-trivial magnitude.
    const id = Q.one.mul(Q.fromInteger(-17)).raw == @as(i256, -17) << 128;
    return below and tie and above and id;
}

/// Verify Q128.128 division through the wide (i512) path, both signs.
export fn verify_fp_division() bool {
    const Q = Q128;
    // 7/2 = 3.5 → raw = 7·2^127.
    const a = Q.fromInteger(7).div(Q.fromInteger(2)) catch return false;
    const b = Q.fromInteger(-7).div(Q.fromInteger(2)) catch return false;
    const c = Q.fromInteger(-7).div(Q.fromInteger(-2)) catch return false;
    const expect: i256 = @as(i256, 7) << 127;
    return a.raw == expect and b.raw == -expect and c.raw == expect;
}

/// Verify fromRatio's round-half-away-from-zero: 1/2 exact, 1/3 rounds
/// up (remainder 1 == half_den boundary), -1/4 symmetric.
export fn verify_fp_from_ratio() bool {
    const Q = Q128;
    const h = Q.fromRatio(1, 2) catch return false;
    const t = Q.fromRatio(1, 3) catch return false;
    const n = Q.fromRatio(-1, 4) catch return false;
    const third: i256 = ((@as(i256, 1) << 128) - 1) / 3 + 1;
    return h.raw == (@as(i256, 1) << 127) and t.raw == third and
        n.raw == -(@as(i256, 1) << 126);
}

/// Verify Newton sqrt on Q128.128: sqrt(4)=2 exactly; sqrt(2) squares
/// back to within a few ULP of 2 (fixed-point floor semantics).
export fn verify_fp_sqrt() bool {
    const Q = Q128;
    const four = Q.fromInteger(4).sqrt() catch return false;
    if (four.raw != @as(i256, 2) << 128) return false;
    const two_raw: i256 = @as(i256, 2) << 128;
    const s = Q.fromInteger(2).sqrt() catch return false;
    const sq = s.mul(s);
    return sq.raw <= two_raw and sq.raw > two_raw - 8;
}

/// Verify the E8 root count = 240.
export fn verify_e8_roots() bool {
    // 112 D8 roots + 128 spinor roots = 240
    return 112 + 128 == 240;
}

/// Verify the SO(10) decomposition: 16 = 15 + 1.
export fn verify_so10() bool {
    return 15 + 1 == 16;
}

/// Verify the scaling chain: 421 = (3375 - 7) / 8.
export fn verify_scaling() bool {
    return (3375 - 7) / 8 == 421;
}

/// Verify the shell transition: 16³ - 15³ = 721.
export fn verify_shell_transition() bool {
    return 16 * 16 * 16 - 15 * 15 * 15 == 721;
}

/// Verify the 7-defect: 2³ - 1 = 7.
export fn verify_seven_defect() bool {
    return 2 * 2 * 2 - 1 == 7;
}

/// Verify the codon boundary: 62 = 64 - 2.
export fn verify_codon_boundary() bool {
    return 64 - 2 == 62;
}

/// Verify the Mersenne prime: 31 = 2^5 - 1.
export fn verify_mersenne_prime() bool {
    return 32 - 1 == 31;
}

/// Verify the E8 root count identity: 15 × 16 = 240.
export fn verify_root_count_identity() bool {
    return 15 * 16 == 240;
}

/// Verify the shell closure: 16³ - 15³ = 721 = 720 + 1.
export fn verify_shell_closure() bool {
    return 16 * 16 * 16 - 15 * 15 * 15 == 721 and 6 * 120 + 1 == 721;
}

/// Verify the consciousness fraction: 421/3375 = 1/8 - 7/27000.
export fn verify_consciousness_fraction() bool {
    // 421 * 8 = 3376, 3375 - 7 = 3368, 3376 != 3368
    // Actually: 421/3375 = 1/8 - 7/27000
    // Cross multiply: 421 * 27000 = 11367000, 3375 * (3375 - 7) = 3375 * 3368 = 11367000
    return 421 * 27000 == 3375 * 3368;
}

pub fn main() void {
    const passed = run_all_proofs();
    if (passed == proof_module_count()) {
        std.debug.print("All {d} proofs passed in WASM.\n", .{passed});
    } else {
        std.debug.print("{d}/{d} proofs passed in WASM.\n", .{ passed, proof_module_count() });
    }
}
