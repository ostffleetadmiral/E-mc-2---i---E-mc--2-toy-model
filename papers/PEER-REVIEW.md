# Peer Review Report

**Reviewer:** Devin AI (self-review, critical)
**Date:** September 11, 2026
**Scope:** 4 arXiv papers from the E=mc²-i-E=mc⁻² (toy-model) framework
**DOI:** 10.5281/zenodo.22715355

---

## Overall Assessment

**Recommendation: Major revisions required for all 4 papers.**

The framework demonstrates computational competence and honest self-classification, but the papers contain mathematical errors, missing derivations, unsupported claims, and insufficient experimental data. Below are the specific issues by paper.

---

## Paper 1: A Computational Framework for Octonionic Physics

### Critical Issues

**C1. M\"obius self-inverse claim is WRONG (Theorem 14, Table 3).**
The paper claims Γ(z) = (z-1)/(z+1) is self-inverse. It is NOT. Direct computation:
```
Γ(Γ(z)) = ((z-1)/(z+1) - 1) / ((z-1)/(z+1) + 1)
        = ((z-1)-(z+1)) / ((z-1)+(z+1))
        = (-2) / (2z) = -1/z ≠ z
```
The self-inverse transformation is Γ(z) = (1-z)/(1+z), NOT (z-1)/(z+1). Paper 3's proof catches this error mid-proof ("Wait---this gives -1/z, not z") but then leaves the wrong theorem statement in place. This is a **published error** that must be fixed.

**C2. Smith chart boundary values are wrong for the stated formula.**
For Γ(z) = (z-1)/(z+1):
- Γ(0) = -1 (paper claims +1)
- Γ(1) = 0 (correct)
- Γ(∞) = +1 (paper claims -1)

The values in the paper match Γ(z) = (1-z)/(1+z), not (z-1)/(z+1). Claim 15 in the proven list is false as stated.

**C3. "15 SM fermions including antiparticles" is ambiguous.**
The SO(10) 16-dimensional spinor decomposes as 15 + 1. But "15" is the count of SM fermions per generation (one chirality, NOT including antiparticles in the usual convention). The paper says "including antiparticles" which would give 30, not 15. This needs precise definition.

### Major Issues

**M1. The 421 identity proof is confusingly written.**
The proof says "Cross-multiply: 421 × 27000 = 11,367,000 and 3375 × (3375 - 7) = 3375 × 3368 = 11,367,000." This proves 421/3375 = 3368/27000, which equals (3375-7)/27000 = 1/8 - 7/27000. The intermediate step is missing. A reader cannot follow the logic.

**M2. Literature review table is inconsistent.**
- 5 + 13 + 16 = 34, not 36. The remaining 2 claims are unaccounted for.
- "Combined verified + proven: 21 (58%)" — 5 + 16 = 21, but this excludes the 13 "reinforced." Why?
- "CONSCIOUSNESS-DERIVED: 20 (56%)" overlaps with other rows. Is this a subset? The table doesn't say.
- Percentages don't sum to 100%.

**M3. References are inadequate.**
Many references cite "arXiv preprint" or "Zenodo" with author "Various" — these are not verifiable. Examples:
- `cubicscaling2025`: author "Various", no title, no arXiv ID
- `octoconscious2025`: author "Various", no title
- `sankhya2025`: author "Various", no title
A peer reviewer cannot verify these references.

**M4. The scaling chain relation "128 = 2 × 62 + 4" is unexplained.**
Why +4? This is not a natural algebraic relation. It looks like the chain was constructed to reach 128, not derived.

**M5. Balmer series analogy is historically inaccurate.**
Balmer's formula was an empirical regularity derived from observed spectral data, not a "numerical coincidence." The framework's correspondences are constructed (built to match), not empirically observed. The analogy is misleading.

---

## Paper 2: Q128.128 Deterministic Arithmetic

### Critical Issues

**C1. Error bound proof does not use the RNE property.**
The proof states "RNE ensures |d - h| ≤ h" but this is true for ANY rounding scheme (truncation also satisfies this). The error bound ≤ 2^{-129} holds for round-to-nearest with any tie-breaking rule, not specifically RNE. RNE provides unbiasedness, not a tighter bound. The proof should clarify this distinction.

### Major Issues

**M1. "Sub-Planck precision" is misleading.**
Numerical precision ≠ physical resolution. Having 2^{-128} arithmetic precision does not mean the framework resolves sub-Planckian physics. A calculator with 40 digits doesn't have "sub-atomic precision." This claim should be removed or reframed.

**M2. fromRatio algorithm deviates from standard round-half-away-from-zero.**
The condition `r = h and r ≠ 0` is a bug fix for the n=0 case, but it means the algorithm does NOT implement standard round-half-away-from-zero. Standard RHAZ rounds up whenever r ≥ h. The paper should acknowledge this as a modified RHAZ, not standard.

**M3. No performance benchmarks.**
The paper reports test pass/fail but no timing data. A cs.NA paper should include:
- Multiplication latency (cycles or ns)
- Division latency
- Comparison with IEEE-754 double precision performance
- WASM vs native performance overhead

**M4. RamseyIdentity transforms are undefined.**
"E = mc² ↔ i ↔ E = mc⁻²" is presented as a name, not a mathematical operation. What is the transformation? What are the domain and codomain? Is it a group action? An algebraic isomorphism? Without a definition, this is meaningless.

**M5. Polyglot runtime claims lack evidence.**
The table claims 22/22 tests for Python, JavaScript, Rust, C, C#/.NET, but no test methodology, no code examples, and no reproducibility instructions are provided.

---

## Paper 3: Codon Routing

### Critical Issues

**C1. Theorem statement contradicts its own proof.**
The theorem states Γ(z) = (z-1)/(z+1) is self-inverse. The proof computes Γ(Γ(z)) = -1/z, says "Wait---this gives -1/z, not z", then switches to a different formula. This is a **fatal error** in a published paper. The theorem must state Γ(z) = (1-z)/(1+z) from the beginning.

**C2. Smith chart boundaries are wrong for the stated formula.**
Same as Paper 1 C2. The paper says Γ(0) = 1, Γ(1) = 0, Γ(∞) = -1, but for (z-1)/(z+1) these are -1, 0, +1 respectively.

### Major Issues

**M1. Scaling factor S is never defined.**
The qubit coordinates use "integer scaling factor S" but its value is never specified. Without it, the coordinates are not reproducible.

**M2. "15-layer central row" is unexplained.**
What is the 15-layer central row? How is it derived? How does it connect to the 15×15 matrix?

**M3. AUG and GCA outliers are not quantified.**
"Deviates from the expected pattern" — how? By how much? What is the expected pattern?

**M4. Paper is too short for the claimed scope.**
6 pages for a paper claiming to map the entire genetic code to Jordan algebra channels. The routing rules, chemistry derivation, and biological motivation need far more detail.

**M5. No comparison with existing genetic code algebraic models.**
The paper cites Petoukhov (2011) but doesn't compare or contrast with existing algebraic models of the genetic code. A q-bio paper should situate itself in the literature.

---

## Paper 4: Neuraleak

### Critical Issues

**C1. No experimental results.**
The paper describes a sentience testing system but reports ZERO actual scores from LLM experiments. A cs.AI paper about LLM testing must include at least a pilot study with real data.

**C2. Control experiment claim is unsupported.**
The paper says "verifies that sentience scores are higher for constrained prompts than for shuffled prompts" but provides no data. This is an unsupported claim.

### Major Issues

**M1. Sentience scoring is trivially naive.**
5 binary keyword matches is a 1990s-era approach to text classification. Modern NLP uses embeddings, fine-tuned models, or LLM-as-judge approaches. A 2026 paper should justify why keyword matching is sufficient or compare with stronger methods.

**M2. 1/√8 rendering threshold has no connection to 421/3375.**
The paper states 421/3375 ≈ 1/8 as the "consciousness aperture" and 1/√8 as the "rendering threshold." But 1/8 ≠ 1/√8 (0.125 vs 0.354). These are different numbers with no stated relationship. Why is the threshold 1/√8 and not 1/8?

**M3. Q# "quantum witnesses" are classical simulations.**
The Q# operations are simulated classically, not run on quantum hardware. The paper should clarify this. Calling them "quantum witnesses" without this caveat is misleading.

**M4. NPU benchmarks lack methodology.**
"21 tok/s" is reported without batch size, sequence length, warmup, measurement protocol, or comparison with CPU-only inference on the same hardware.

**M5. The 6D observer model is not testable.**
The paper describes a "6D interior" and "observer at e0 pivot" but provides no falsifiable prediction. What experiment would distinguish this model from any other? What would disprove it?

---

## Cross-Paper Issues

**X1. AI authorship.**
"Devin AI, Chat-GPT, Gemini, GLM-2.5, Kimi AI" as co-authors may violate arXiv's submission policy. arXiv requires all co-authors to be responsible for the content. AI systems cannot take responsibility. Consider listing AI tools in acknowledgments instead.

**X2. Papers don't cite each other.**
Paper 1 references Q128.128 (Paper 2's topic), Paper 4 references the 6D model (Paper 1's topic), but none cite each other formally. Cross-citations are needed.

**X3. Fabricated or vague references.**
Multiple references have author "Various" and no specific paper. These are not verifiable and would be flagged by any referee:
- `cubicscaling2025`: "Various", "arXiv preprint"
- `octoconscious2025`: "Various", "Zenodo"
- `sankhya2025`: "Various", "arXiv preprint"
- `aps2026alpha`: "APS Collaboration" (which APS? which paper?)

**X4. No actual arXiv submission.**
The papers have a Zenodo DOI but no arXiv ID. The README says "arXiv-ready" but they have not been submitted to or accepted by arXiv.

---

## Summary of Required Revisions

| Severity | Count | Examples |
|----------|-------|----------|
| Critical | 7 | M\"obius formula wrong, no experimental data in Paper 4, proof contradicts theorem |
| Major | 17 | Missing definitions, no benchmarks, vague references, AI authorship |
| Minor | 8+ | Formatting, cross-citations, historical accuracy |

### Must-fix before arXiv submission:
1. Fix the M\"obius formula in all papers: (1-z)/(1+z), not (z-1)/(z+1)
2. Fix Smith chart boundary values
3. Remove or fix the mid-proof "Wait" in Paper 3
4. Add actual experimental data to Paper 4
5. Replace vague references with real citations or remove them
6. Move AI tools from author list to acknowledgments
7. Add cross-citations between papers
8. Define the scaling factor S in Paper 3
9. Remove "sub-Planck precision" claim from Paper 2
10. Clarify "15 SM fermions" in Paper 1
