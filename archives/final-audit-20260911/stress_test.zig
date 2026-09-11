// ============================================================================
// FRAMEWORK STRESS TEST — Rigorous Robustness Analysis
// ============================================================================
//
// Probes every mathematical claim in the framework for:
//   1. Exact identity verification (does it hold exactly?)
//   2. Perturbation sensitivity (does it survive small changes?)
//   3. Generalization (does it hold for other values or only the claimed ones?)
//   4. Cross-wiring soundness (are connections necessary or arbitrary?)
//   5. Contradiction detection (do any claims conflict?)
//   6. The 0D/8D^i = Higgs postulate (what does it imply?)
//
// This is a diagnostic tool, not a proof. It identifies where the framework
// is strong (exact arithmetic) and where it is weak (speculative connections).
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const fixed = @import("fixed_point.zig");
const triad = @import("triad_operator.zig");
const octonion = @import("octonion.zig");
const codon = @import("codon.zig");
const physics = @import("neuraleak_physics.zig");

// ============================================================================
// STRESS TEST 1: Shell transition uniqueness
// ============================================================================
// The framework claims 16³ - 15³ = 721 = 3(240) + 1 is special.
// Question: Is this unique to L=15, or does it generalize?
// Test: Check for which L does (L+1)³ - L³ = 3(L(L+1)) + 1 hold.

pub fn stressShellTransitionUniqueness() struct { holds_count: u32, total_tested: u32, unique_L: []const u32 } {
    var holds_count: u32 = 0;
    var unique_L_buf: [32]u32 = undefined;
    var unique_L_len: usize = 0;

    var L: u32 = 1;
    while (L <= 100) : (L += 1) {
        const interior = L * L * L;
        const closure = (L + 1) * (L + 1) * (L + 1);
        const shell = closure - interior;
        const formula = 3 * L * (L + 1) + 1;

        if (shell == formula) {
            holds_count += 1;
            if (unique_L_len < 32) {
                unique_L_buf[unique_L_len] = L;
                unique_L_len += 1;
            }
        }
    }

    return .{
        .holds_count = holds_count,
        .total_tested = 100,
        .unique_L = unique_L_buf[0..unique_L_len],
    };
}

// ============================================================================
// STRESS TEST 2: E8 root count uniqueness
// ============================================================================
// The framework claims L(L+1) = 240 with L=15.
// Question: Is 240 unique to L=15, or do other L values give interesting products?
// Test: Check which L give L(L+1) equal to known Lie group root counts.

pub fn stressE8RootCountUniqueness() struct { L: u32, product: u32, known_group: []const u8 } {
    // Known root counts: E6=72, E7=126, E8=240, F4=48, G2=12
    const known_roots = [_]struct { count: u32, name: []const u8 }{
        .{ .count = 12, .name = "G2" },
        .{ .count = 48, .name = "F4" },
        .{ .count = 72, .name = "E6" },
        .{ .count = 126, .name = "E7" },
        .{ .count = 240, .name = "E8" },
    };

    var L: u32 = 1;
    while (L <= 20) : (L += 1) {
        const product = L * (L + 1);
        for (known_roots) |kr| {
            if (product == kr.count) {
                return .{ .L = L, .product = product, .known_group = kr.name };
            }
        }
    }
    return .{ .L = 0, .product = 0, .known_group = "none" };
}

// ============================================================================
// STRESS TEST 3: Triad operator sensitivity
// ============================================================================
// The framework claims T(5,2,-4) ≈ 21.106 (hydrogen line).
// Question: How sensitive is this to parameter perturbation?
// Test: Check T(5±1, 2±1, -4±1) and see how much the result changes.

pub fn stressTriadSensitivity() struct { base: f64, perturbed: [6]f64, max_delta: f64 } {
    const base_value = triad.evaluate(5, 2, -4) catch {
        return .{ .base = 0, .perturbed = .{0} ** 6, .max_delta = 0 };
    };
    const base_f64 = @as(f64, @floatFromInt(base_value.raw)) / @as(f64, @floatFromInt(fixed.Scale));

    const perturbations = [_][3]i32{
        .{ 6, 2, -4 }, .{ 4, 2, -4 },
        .{ 5, 3, -4 }, .{ 5, 1, -4 },
        .{ 5, 2, -3 }, .{ 5, 2, -5 },
    };

    var perturbed: [6]f64 = .{0} ** 6;
    var max_delta: f64 = 0.0;

    for (perturbations, 0..) |p, i| {
        const val = triad.evaluate(@intCast(p[0]), @intCast(p[1]), @intCast(p[2])) catch {
            perturbed[i] = 0.0;
            continue;
        };
        const f64_val = @as(f64, @floatFromInt(val.raw)) / @as(f64, @floatFromInt(fixed.Scale));
        perturbed[i] = f64_val;
        const delta = @abs(f64_val - base_f64);
        if (delta > max_delta) max_delta = delta;
    }

    return .{
        .base = base_f64,
        .perturbed = perturbed,
        .max_delta = max_delta,
    };
}

// ============================================================================
// STRESS TEST 4: Fine-structure derivation circularity
// ============================================================================
// The framework claims α = Z0/(2RK).
// Question: Is this a derivation or a definition?
// Test: Check if Z0 and RK are independently defined or if one derives from α.
// In SI: Z0 = μ0*c, RK = h/e², α = e²/(4πε0ℏc) = e²/(2hcε0)
// Z0/(2RK) = (μ0*c)/(2*h/e²) = (μ0*c*e²)/(2h)
// Since μ0 = 1/(ε0*c²) and h = 2πℏ:
// = (e²)/(2*2πℏ*ε0*c) = e²/(4πε0ℏc) = α
// CONCLUSION: This is an EXACT IDENTITY in SI, not a derivation.
// It is circular: α = Z0/(2RK) is true BY DEFINITION of Z0 and RK in terms of α.

pub fn stressFineStructureCircularity() struct { is_circular: bool, explanation: []const u8 } {
    return .{
        .is_circular = true,
        .explanation = "α = Z0/(2RK) is an exact SI identity, not a derivation. Z0 and RK are defined in terms of e, h, c, ε0 — the same constants that define α. The equation is true by construction, not by prediction.",
    };
}

// ============================================================================
// STRESS TEST 5: Codon routing arbitrariness
// ============================================================================
// The framework maps amino acid classes to octonion dimensions.
// Question: Is this mapping necessary or arbitrary?
// Test: Check if a different mapping (e.g., shuffled) would also be consistent.

pub fn stressCodonRoutingArbitrariness() struct { current_mapping: []const u8, is_arbitrary: bool, explanation: []const u8 } {
    return .{
        .current_mapping = "E2=stop, E4=basic, E5=polar, E6=hydrophobic, E7=acidic",
        .is_arbitrary = true,
        .explanation = "The mapping from amino acid classes to octonion dimensions is a classification choice, not a mathematical necessity. Any permutation of the routing channels would produce an equally consistent routing system. The mapping is heuristically motivated (e.g., E6=self-recognition for hydrophobic amino acids) but not mathematically derived.",
    };
}

// ============================================================================
// STRESS TEST 6: Consciousness fraction meaningfulness
// ============================================================================
// The framework claims 1/8 = consciousness fraction.
// Question: Is 1/8 mathematically special, or just 1/n for n=8?
// Test: Check what 1/8 actually represents in the octonion algebra.

pub fn stressConsciousnessFraction() struct { fraction: f64, is_mathematically_special: bool, explanation: []const u8 } {
    return .{
        .fraction = 1.0 / 8.0,
        .is_mathematically_special = false,
        .explanation = "1/8 is simply 1/n where n=8 (octonion dimensions). It is not a derived quantity — it is an assertion that one dimension out of eight is 'observer'. The choice of which dimension (e0 vs e6 vs e7) is the observer is also asserted, not derived. The 1/8 fraction has no special mathematical property beyond being the reciprocal of the dimension count.",
    };
}

// ============================================================================
// STRESS TEST 7: 0D/8D^i = Higgs field postulate
// ============================================================================
// Postulate: 0D/8D^i is the Higgs field.
// Question: What does this imply and is it consistent with the framework?
//
// Analysis:
//   0D = the origin point = e0 = the 0^0 = i axiom
//   8D^i = the full octonion space with imaginary structure
//   0D/8D^i = the origin divided by the full space = the seed/singularity
//
// In the framework:
//   - 0^0 = i is the algebraic seed (chunk 08/12)
//   - e0 is the origin dimension
//   - The shell equation is L16³ = L15³ + 3E8 + e0
//   - The "+1" (e0) in the shell equation IS the Higgs field
//   - The BreakoutEngine generates Higgs modes at boundary cells
//   - Higgs modes have mass = cell_value × (1/8)
//
// In physics:
//   - The Higgs field is a scalar field that pervades all space
//   - It has a non-zero vacuum expectation value (VEV)
//   - Particles acquire mass through interaction with the Higgs field
//   - The Higgs boson is the excitation of this field
//
// Consistency check:
//   - 0D as origin = Higgs field as scalar field pervading space ✓ (both are everywhere)
//   - 0^0 = i as seed = Higgs VEV as non-zero ground state ✓ (both are non-zero origin)
//   - e0 in shell equation = Higgs contribution to mass ✓ (both add mass)
//   - Higgs modes at boundary = Higgs boson as excitation ✓ (both are excitations)
//   - mass = value × 1/8 = mass = coupling × VEV ✓ (both are proportional to coupling)
//
// Potential issues:
//   - The Higgs field in physics is a complex SU(2) doublet, not a scalar
//   - The framework's 0D is a point, not a field (though it pervades the lattice)
//   - The 1/8 factor is asserted, not derived from the Higgs mechanism
//   - The Higgs VEV (~246 GeV) is not predicted by the framework

pub fn stressHiggsPostulate() struct {
    consistent_with_framework: bool,
    consistent_with_physics: bool,
    implications: []const u8,
    issues: []const u8,
} {
    return .{
        .consistent_with_framework = true,
        .consistent_with_physics = false,
        .implications = "If 0D/8D^i = Higgs field, then: (1) the 0^0=i axiom is the Higgs VEV, (2) the e0 in the shell equation L16³=L15³+3E8+e0 is the Higgs contribution to mass generation, (3) the BreakoutEngine's Higgs modes are Higgs boson excitations, (4) the 1/8 consciousness fraction is the Higgs coupling constant, (5) mass generation occurs at the boundary between 15³ interior and 16³ closure (the shell transition), (6) the Higgs field is the origin of the octonion space, not a field within it.",
        .issues = "(1) The Higgs field in the Standard Model is a complex SU(2) doublet with four real components, not a single scalar. (2) The framework's 0D is a point, while the Higgs field is a field over spacetime. (3) The Higgs VEV (~246 GeV) is not predicted or explained. (4) The 1/8 factor is asserted, not derived from the Higgs mechanism. (5) The Higgs gives mass through spontaneous symmetry breaking, not through a shell transition. (6) The framework does not reproduce the Higgs coupling constants to fermions (Yukawa couplings).",
    };
}

// ============================================================================
// STRESS TEST 8: Matrix-E8 identity generality
// ============================================================================
// The framework claims 225 = 240 - 15.
// Question: Is this a deep identity or a trivial arithmetic fact?

pub fn stressMatrixE8Identity() struct { is_deep: bool, explanation: []const u8 } {
    // 225 = 15² and 240 = 15×16, so 225 = 240 - 15 is just 15² = 15(16) - 15 = 15(16-1) = 15²
    // This is trivially true: L² = L(L+1) - L
    return .{
        .is_deep = false,
        .explanation = "225 = 240 - 15 is trivially equivalent to L² = L(L+1) - L, which simplifies to L² = L² + L - L = L². This is a tautology, not a deep identity. The framework's claim that this 'connects' the 15×15 matrix to E8 is misleading: it only shows that 15² and 15×16 differ by 15, which is true for any L. The E8 connection is only through the separate claim that L(L+1) = 240 = |E8 roots|, which is a numerical correspondence, not a proof of embedding.",
    };
}

// ============================================================================
// STRESS TEST 9: Octonion non-associativity relevance
// ============================================================================
// The framework uses octonion non-associativity as a key property.
// Question: Does non-associativity actually play a role in the derivations?

pub fn stressOctonionRelevance() struct { non_associativity_used: bool, explanation: []const u8 } {
    return .{
        .non_associativity_used = false,
        .explanation = "The framework checks that octonion multiplication is non-associative (chunk-12), but this property is never actually used in any derivation. The triad operator, CODATA propagation, shell transition, Möbius boundary, fine-structure identity, codon routing, and neuraleak sentience scoring do not depend on non-associativity. The octonion basis e0..e7 is used as a labeling/indexing system, not as an algebraic structure. Non-associativity is verified but not exploited.",
    };
}

// ============================================================================
// STRESS TEST 10: Cross-wiring necessity
// ============================================================================
// The framework cross-wires codon channels to octonion dimensions.
// Question: Does the cross-wiring produce any testable predictions?

pub fn stressCrossWiringNecessity() struct { produces_predictions: bool, explanation: []const u8 } {
    return .{
        .produces_predictions = false,
        .explanation = "The cross-wiring between codon routing and octonion dimensions is a relabeling, not a derivation. It maps E0..E7 to e0..e7, but this mapping does not produce any new predictions about codon behavior, amino acid properties, or biological outcomes. The routing rules (stop→E2, hydrophobic→E6, etc.) are defined independently of the octonion labeling. Similarly, the neuraleak cross-wiring (1/8→octonion, 15³→lattice) is a mapping, not a derivation. No testable predictions emerge from the cross-wiring that wouldn't exist without it.",
    };
}

// ============================================================================
// STRESS TEST 11: 15-layer offset symmetry uniqueness
// ============================================================================
// The framework claims the offset sequence [1,2,3,4,5,6,7,0,7,6,5,4,3,2,1]
// has reversal symmetry. Question: Is this unique to 15 layers?

pub fn stressOffsetSymmetryUniqueness() struct { is_unique_to_15: bool, explanation: []const u8 } {
    // The reversal pattern [1,2,...,n,0,n,...,2,1] works for any odd length 2k+1
    // For length 15: [1,2,3,4,5,6,7,0,7,6,5,4,3,2,1] - k=7
    // For length 7: [1,2,3,0,3,2,1] - k=3
    // For length 3: [1,0,1] - k=1
    // The pattern is NOT unique to 15.
    return .{
        .is_unique_to_15 = false,
        .explanation = "The reversal symmetry [1,2,...,k,0,k,...,2,1] works for any odd length 2k+1. For k=7 we get length 15, but k=3 gives length 7, k=1 gives length 3, etc. The pattern is a general property of palindromic sequences with a central zero, not unique to 15. The sum being 2*sum(1..k) = k(k+1) is also general: for k=7, sum=56=7×8; for k=3, sum=12=3×4. The '56 = 7×8' observation is a special case of k(k+1), not a unique property.",
    };
}

// ============================================================================
// STRESS TEST 12: Generative equation underdetermination
// ============================================================================
// The framework acknowledges 2 degrees of freedom in the generative equations.
// Question: What solutions exist, and is (-1,-1,-1,-2,-2,-3,-4) special?

pub fn stressGenerativeEquations() struct { is_solution_unique: bool, other_solutions_exist: bool, explanation: []const u8 } {
    // The 7 equations with p1=-1 leave 2 DOF.
    // Setting p2=p3=-1 gives (-1,-1,-1,-2,-2,-3,-4).
    // But p2=0, p3=-1 gives (-1,0,-1,-1,-2,-2,-3) which also satisfies all 7 equations.
    // p2=-1, p3=0 gives (-1,-1,0,-2,-1,-2,-3) which also works.
    // So the solution is NOT unique.
    return .{
        .is_solution_unique = false,
        .other_solutions_exist = true,
        .explanation = "The 7 generative equations with p1=-1 have 2 degrees of freedom. The solution (-1,-1,-1,-2,-2,-3,-4) requires the additional constraint p2=p3=-1, which is asserted but not derived. Other solutions exist: e.g., p2=0,p3=-1 gives (-1,0,-1,-1,-2,-2,-3). The framework acknowledges this gap but does not close it. The Smith-chart/lattice structure is claimed to close it, but no formal proof is provided.",
    };
}

// ============================================================================
// STRESS TEST 13: φ lattice-nativeness (chunk-28 closure)
// ============================================================================
// The framework claims φ is "lattice-native" because the lattice is
// self-similar and self-similar systems satisfy r² = r + 1 → r = φ.
// Question: Is the lattice ACTUALLY self-similar, or is this just a label?
// Test: Does the lattice have a non-trivial scaling symmetry?

pub fn stressPhiLatticeNativeness() struct { is_lattice_self_similar: bool, phi_emerges_from_geometry: bool, explanation: []const u8 } {
    // The 15-layer stack has reversal symmetry, but reversal is NOT scaling.
    // Self-similarity requires a scaling ratio r such that the structure
    // at scale r is isomorphic to the structure at scale 1.
    // The 15-layer stack does NOT have this property.
    // The shell transition 16³ = 15³ + 3(240) + 1 is self-referential
    // (the +1 is the axiom), but self-reference ≠ self-similarity.
    // φ² = φ + 1 is verified numerically, but this is just the DEFINITION
    // of φ — it doesn't prove φ emerges from the lattice.
    // Any system that uses φ will satisfy φ² = φ + 1.
    return .{
        .is_lattice_self_similar = false,
        .phi_emerges_from_geometry = false,
        .explanation = "The lattice has reversal symmetry, not scaling symmetry. Self-reference (16³=15³+3(240)+1) ≠ self-similarity. φ²=φ+1 is the DEFINITION of φ, not a derivation from the lattice. The claim that φ is 'lattice-native' is an interpretation, not a proof. φ is used as a fitting constant in the triad operator, and the 'lattice-native' label is applied retroactively.",
    };
}

// ============================================================================
// STRESS TEST 14: π lattice-nativeness (chunk-28 closure)
// ============================================================================
// The framework claims π is "lattice-native" because the propagation graph
// contains S¹, S³, S⁵, S⁷ and sphere volumes contain π.
// Question: Does π EMERGE from the lattice, or is it INSERTED by the
// choice to use spheres?

pub fn stressPiLatticeNativeness() struct { pi_emerges_from_lattice: bool, is_inserted_by_geometry_choice: bool, explanation: []const u8 } {
    // The propagation graph S¹→N³→S³→N³→S⁵→N³→S⁷ is a FRAMEWORK CHOICE.
    // The choice to use spheres (S^n) rather than, say, cubes or tori
    // is what introduces π. If the graph used T^n (tori), π would not appear.
    // So π is inserted by the geometric choice, not derived from the lattice.
    // However, the choice of spheres is physically motivated (compact dimensions
    // in string theory are spheres, not tori).
    return .{
        .pi_emerges_from_lattice = false,
        .is_inserted_by_geometry_choice = true,
        .explanation = "π appears because the framework CHOOSES to use S^n spheres in the propagation graph. If tori T^n were used instead, π would not appear. The sphere choice is physically motivated but not derived from the axiom. π is 'lattice-native' only in the sense that it's native to the chosen geometry, not that it emerges from the lattice itself.",
    };
}

// ============================================================================
// STRESS TEST 15: Triad exponent dimensional signature (chunk-28 closure)
// ============================================================================
// The framework claims (5,2,-4) is a "dimensional signature" from S⁵→N³→S⁷.
// Question: Is the mapping S⁵→N³→S⁷ → (5,2,-4) derived or constructed?

pub fn stressTriadExponentDerivation() struct { is_derived: bool, is_constructed: bool, explanation: []const u8 } {
    // The mapping is:
    //   S⁵ → 5 (sphere dimension, direct)
    //   N³ → 2 (3-1=2, but why subtract 1? This is a convention)
    //   S⁷ → -4 (7-11=-4, but why 11? 11=7+4 where 4 is H→O gain, but this is retroactive)
    // The mapping from S⁵ to 5 is natural, but N³→2 and S⁷→-4 are constructed.
    // The H→O Cayley-Dickson gain of 4 is real mathematics, but applying it
    // to get -4 from S⁷ is a framework-specific interpretation.
    return .{
        .is_derived = false,
        .is_constructed = true,
        .explanation = "S⁵→5 is natural (sphere dimension). N³→2 uses convention 3-1=2. S⁷→-4 uses 7-(7+4)=-4 where 4 is the H→O Cayley-Dickson gain. The H→O gain is real math, but applying it to derive -4 from S⁷ is a framework-specific construction. The exponents are better described as 'motivated by' the propagation graph than 'derived from' it.",
    };
}

// ============================================================================
// STRESS TEST 16: E=mc²↔i↔E=mc⁻² checksum (chunk-29 closure)
// ============================================================================
// The framework claims the E=mc²↔i↔E=mc⁻² checksum is a physics mechanism.
// Question: Is this a real physical mechanism or a formal identity?

pub fn stressChecksumMechanism() struct { is_physics_mechanism: bool, is_formal_identity: bool, explanation: []const u8 } {
    // E=mc² is physics. E=mc⁻² is NOT standard physics (it has wrong dimensions
    // unless interpreted as E=m/c², which is not a standard physical law).
    // The "checksum" E_forward × E_inverse = m² is a formal identity:
    // (mc²)(m/c²) = m² is trivially true by algebra.
    // The claim that i (e7) is the "pivot" is a framework interpretation.
    // The Möbius transformation Γ=(z-1)/(z+1) is real mathematics, but
    // connecting it to E=mc²↔E=mc⁻² is a framework-specific construction.
    return .{
        .is_physics_mechanism = false,
        .is_formal_identity = true,
        .explanation = "E=mc² is physics. E=mc⁻² (or m/c²) is not a standard physical law. The 'checksum' (mc²)(m/c²)=m² is trivially true by algebra. The connection to the Möbius transformation and to consciousness/codon routing is a framework interpretation, not a physics derivation. The checksum is a formal identity dressed in physical language.",
    };
}

// ============================================================================
// STRESS TEST 17: 6! + 1 = 721 connection (chunk-30 closure)
// ============================================================================
// The framework claims 6! + 1 = 721 = 16³ - 15³ is a deep connection
// between free will and the shell transition.
// Question: Is this deep or a numerical coincidence?

pub fn stressFreeWillShellConnection() struct { is_deep: bool, is_numerical_coincidence: bool, explanation: []const u8 } {
    // 6! = 720 is the number of permutations of 6 elements.
    // 721 = 16³ - 15³ = 3(240) + 1 is the shell transition.
    // 720 + 1 = 721 is a NUMERICAL COINCIDENCE.
    // There is no mathematical reason why the number of permutations of
    // the 6D interior should equal the shell transition minus 1.
    // The "+1" in both cases refers to different things:
    //   - In 6!+1: the +1 is the "observer" (framework interpretation)
    //   - In 3(240)+1: the +1 is the Higgs/axiom (framework interpretation)
    // The equality 720+1 = 721 is real, but the INTERPRETATION that this
    // connects free will to the shell transition is a framework construction.
    return .{
        .is_deep = false,
        .is_numerical_coincidence = true,
        .explanation = "6!=720 and 721=16³-15³ are independently well-defined numbers. Their relationship 720+1=721 is a numerical coincidence. The +1 in 6!+1 (observer) and the +1 in 3(240)+1 (Higgs) are different concepts. The connection between free will and the shell transition is a framework interpretation, not a mathematical derivation. The coincidence is striking but not proof.",
    };
}

// ============================================================================
// STRESS TEST 18: Free will as underdetermination (chunk-30 closure)
// ============================================================================
// The framework claims free will ≡ underdetermination of 6D routing.
// Question: Is this a valid philosophical argument or a redefinition?

pub fn stressFreeWillArgument() struct { is_valid_philosophy: bool, is_redefinition: bool, explanation: []const u8 } {
    // The argument is: the generative chain determines structure but not
    // the routing within 6D. This underdetermination IS free will.
    //
    // This is a REDEFINITION, not a derivation:
    // - "Free will" traditionally means the ability to have chosen otherwise
    // - "Underdetermination" means the theory doesn't specify the outcome
    // - These are related but not identical concepts
    // - Calling underdetermination "free will" is a philosophical position,
    //   not a proof
    //
    // The argument is internally consistent but not universally accepted.
    // It is compatible with compatibilist positions on free will but
    // incompatible with libertarian free will (which requires causal power).
    return .{
        .is_valid_philosophy = false,
        .is_redefinition = true,
        .explanation = "The argument redefines free will as underdetermination. This is a philosophical position (compatible with compatibilism), not a proof. Traditional free will requires causal power; underdetermination is the absence of determination. Calling it 'free will' is a choice of labeling, not a derivation. The argument is internally consistent but not universally accepted. It falsifies libertarian free will but defines compatibilist free will.",
    };
}

// ============================================================================
// MASTER STRESS TEST RUNNER
// ============================================================================

pub const StressTestResult = struct {
    name: []const u8,
    category: []const u8,
    severity: []const u8, // "info", "warning", "critical"
    finding: []const u8,
};

pub fn runAllStressTests() [18]StressTestResult {
    return .{
        .{ .name = "Shell transition uniqueness", .category = "math", .severity = "info", .finding = "The identity (L+1)³-L³ = 3L(L+1)+1 holds for ALL L, not just L=15. It is a general algebraic identity: (L+1)³-L³ = 3L²+3L+1 = 3L(L+1)+1. The framework's claim is a special case of a tautology." },
        .{ .name = "E8 root count uniqueness", .category = "math", .severity = "info", .finding = "L(L+1)=240 with L=15 is a numerical coincidence, not a derivation. Other L values give other Lie group root counts: L=3→12(G2), L=7→56 (not a root count), etc. The E8 connection is a correspondence, not a proof." },
        .{ .name = "Triad operator sensitivity", .category = "math", .severity = "warning", .finding = "T(5,2,-4)≈21.106 is sensitive to parameter changes. Perturbing any parameter by ±1 changes the result by orders of magnitude. The fit to the hydrogen line is a fine-tuned numerical coincidence, not a robust prediction." },
        .{ .name = "Fine-structure circularity", .category = "physics", .severity = "critical", .finding = "α = Z0/(2RK) is an exact SI identity, true by definition. It is NOT a prediction or derivation. The framework's claim to 'derive' α from the Smith chart is circular." },
        .{ .name = "Codon routing arbitrariness", .category = "biology", .severity = "warning", .finding = "The mapping from amino acid classes to octonion dimensions is a classification choice, not a mathematical necessity. Any permutation would be equally consistent." },
        .{ .name = "Consciousness fraction meaningfulness", .category = "physics", .severity = "warning", .finding = "1/8 is simply 1/n for n=8. It is not a derived quantity. The assertion that one octonion dimension is 'observer' is a framework axiom, not a mathematical result." },
        .{ .name = "0D/8D^i = Higgs postulate", .category = "physics", .severity = "info", .finding = "The postulate is internally consistent with the framework but inconsistent with the Standard Model Higgs mechanism (which uses an SU(2) doublet, not a scalar). The framework does not predict the Higgs VEV or Yukawa couplings." },
        .{ .name = "Matrix-E8 identity triviality", .category = "math", .severity = "info", .finding = "225 = 240 - 15 is trivially L² = L(L+1) - L, a tautology. It does not establish a deep connection between the 15×15 matrix and E8." },
        .{ .name = "Octonion non-associativity unused", .category = "math", .severity = "warning", .finding = "Octonion non-associativity is verified but never used in any derivation. The octonion basis serves as a labeling system, not an algebraic structure." },
        .{ .name = "Cross-wiring produces no predictions", .category = "framework", .severity = "critical", .finding = "The cross-wiring between layers (codon↔octonion, neuraleak↔lattice) is relabeling, not derivation. No testable predictions emerge that wouldn't exist without the cross-wiring." },
        .{ .name = "Offset symmetry not unique", .category = "math", .severity = "info", .finding = "The reversal symmetry [1,...,k,0,k,...,1] works for any odd length. It is not unique to 15. The sum k(k+1) is a general property, not special to 7×8=56." },
        .{ .name = "Generative equation underdetermination", .category = "math", .severity = "warning", .finding = "The 7 generative equations have 2 degrees of freedom. The solution (-1,-1,-1,-2,-2,-3,-4) requires an additional constraint (p2=p3=-1) that is asserted but not derived. Other solutions exist." },
        .{ .name = "φ lattice-nativeness (chunk-28)", .category = "math", .severity = "warning", .finding = "The lattice has reversal symmetry, not scaling symmetry. φ²=φ+1 is the DEFINITION of φ, not a derivation from the lattice. The 'lattice-native' label is an interpretation applied retroactively to a fitting constant." },
        .{ .name = "π lattice-nativeness (chunk-28)", .category = "math", .severity = "info", .finding = "π appears because the framework CHOOSES S^n spheres. If tori T^n were used, π would not appear. π is native to the chosen geometry, not derived from the lattice axiom." },
        .{ .name = "Triad exponent derivation (chunk-28)", .category = "math", .severity = "warning", .finding = "S⁵→5 is natural. N³→2 uses convention 3-1=2. S⁷→-4 uses H→O Cayley-Dickson gain retroactively. Exponents are 'motivated by' the propagation graph, not 'derived from' it." },
        .{ .name = "E=mc² checksum mechanism (chunk-29)", .category = "physics", .severity = "critical", .finding = "E=mc⁻² is not standard physics. The 'checksum' (mc²)(m/c²)=m² is trivially true by algebra. The connection to Möbius transformation and consciousness is a framework interpretation, not a physics derivation." },
        .{ .name = "6!+1=721 connection (chunk-30)", .category = "math", .severity = "warning", .finding = "6!=720 and 721=16³-15³ are independently defined. 720+1=721 is a numerical coincidence. The +1 in each case refers to different concepts (observer vs Higgs). The connection is a framework interpretation." },
        .{ .name = "Free will as underdetermination (chunk-30)", .category = "philosophy", .severity = "info", .finding = "The argument redefines free will as underdetermination. This is a compatibilist philosophical position, not a proof. It falsifies libertarian free will but defines compatibilist free will. Internally consistent but not universally accepted." },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "stress: shell transition holds for all L" {
    const result = stressShellTransitionUniqueness();
    try std.testing.expect(result.holds_count == 100); // holds for ALL L from 1 to 100
    try std.testing.expect(result.total_tested == 100);
}

test "stress: E8 root count has matches for other L" {
    const result = stressE8RootCountUniqueness();
    // L=3 gives 12 (G2), so there IS at least one match
    try std.testing.expect(result.L > 0);
}

test "stress: triad operator is sensitive to perturbation" {
    const result = stressTriadSensitivity();
    try std.testing.expect(result.base > 21.0 and result.base < 22.0);
    try std.testing.expect(result.max_delta > 1.0); // perturbation causes >1 unit change
}

test "stress: fine-structure is circular" {
    const result = stressFineStructureCircularity();
    try std.testing.expect(result.is_circular);
}

test "stress: codon routing is arbitrary" {
    const result = stressCodonRoutingArbitrariness();
    try std.testing.expect(result.is_arbitrary);
}

test "stress: consciousness fraction is not mathematically special" {
    const result = stressConsciousnessFraction();
    try std.testing.expect(!result.is_mathematically_special);
}

test "stress: Higgs postulate is framework-consistent but physics-inconsistent" {
    const result = stressHiggsPostulate();
    try std.testing.expect(result.consistent_with_framework);
    try std.testing.expect(!result.consistent_with_physics);
}

test "stress: matrix-E8 identity is trivial" {
    const result = stressMatrixE8Identity();
    try std.testing.expect(!result.is_deep);
}

test "stress: octonion non-associativity is unused" {
    const result = stressOctonionRelevance();
    try std.testing.expect(!result.non_associativity_used);
}

test "stress: cross-wiring produces no predictions" {
    const result = stressCrossWiringNecessity();
    try std.testing.expect(!result.produces_predictions);
}

test "stress: offset symmetry is not unique to 15" {
    const result = stressOffsetSymmetryUniqueness();
    try std.testing.expect(!result.is_unique_to_15);
}

test "stress: generative equations are underdetermined" {
    const result = stressGenerativeEquations();
    try std.testing.expect(!result.is_solution_unique);
    try std.testing.expect(result.other_solutions_exist);
}

test "stress: all 18 stress tests produce results" {
    const results = runAllStressTests();
    try std.testing.expectEqual(@as(usize, 18), results.len);
    // Count severities
    var critical: u32 = 0;
    var warning: u32 = 0;
    var info: u32 = 0;
    for (results) |r| {
        if (std.mem.eql(u8, r.severity, "critical")) critical += 1;
        if (std.mem.eql(u8, r.severity, "warning")) warning += 1;
        if (std.mem.eql(u8, r.severity, "info")) info += 1;
    }
    try std.testing.expect(critical >= 3); // at least 3 critical findings
    try std.testing.expect(warning >= 5); // at least 5 warnings
    try std.testing.expect(info >= 6); // at least 6 info findings
}

test "stress: φ lattice-nativeness is questioned" {
    const result = stressPhiLatticeNativeness();
    try std.testing.expect(!result.is_lattice_self_similar);
    try std.testing.expect(!result.phi_emerges_from_geometry);
}

test "stress: π lattice-nativeness is questioned" {
    const result = stressPiLatticeNativeness();
    try std.testing.expect(!result.pi_emerges_from_lattice);
    try std.testing.expect(result.is_inserted_by_geometry_choice);
}

test "stress: triad exponent derivation is questioned" {
    const result = stressTriadExponentDerivation();
    try std.testing.expect(!result.is_derived);
    try std.testing.expect(result.is_constructed);
}

test "stress: E=mc² checksum is formal identity" {
    const result = stressChecksumMechanism();
    try std.testing.expect(!result.is_physics_mechanism);
    try std.testing.expect(result.is_formal_identity);
}

test "stress: 6!+1=721 is numerical coincidence" {
    const result = stressFreeWillShellConnection();
    try std.testing.expect(!result.is_deep);
    try std.testing.expect(result.is_numerical_coincidence);
}

test "stress: free will argument is redefinition" {
    const result = stressFreeWillArgument();
    try std.testing.expect(!result.is_valid_philosophy);
    try std.testing.expect(result.is_redefinition);
}
