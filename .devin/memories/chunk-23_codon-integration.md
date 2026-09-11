# Chunk 23: Codon DNA → 6D Jordan Algebra Routing Integration

**Source:** `codon/` (Python project port)
**Created:** 2026-09-12
**Category:** codon-integration

## Summary

Ports the Python `codon/` project (64-codon DNA → 6D Jordan algebra routing test suite) into the Zig/Q#/sidecar proof architecture. Cross-wires codon routing channels to the existing octonion basis, 3-qubit states, 15-layer central row, and Smith/Möbius boundary concepts.

## Key Concepts

### Codon Encoding

- 6-bit base-4 index: A=00, C=01, G=10, U=11
- First base is most significant: `idx = b0<<4 | b1<<2 | b2`
- AUG index = 14, UAA index = 48, GAA index = 32
- 64 codons total, 20 amino acids + STOP

### Routing Channels

| Channel | Class | Amino acids | A/C/D flags |
|---|---|---|---|
| E0 | unknown/other | — | 1,1,1 |
| E2 | stop | UAA, UAG, UGA | 1,1,0 |
| E4 | basic | K, R, H | 1,0,1 |
| E5 | polar | S, T, C, Y, N, Q | 1,1,1 |
| E6 | hydrophobic | F, L, I, M, V, P, A, W, G | 0,1,1 |
| E7 | acidic | D, E | 0,0,0 |

### Ladder Coordinates

| Channel | Value |
|---|---|
| E0 | 0.0 |
| E1 | φ ≈ 1.618 |
| E2 | π ≈ 3.142 |
| E3 | 21/4 = 5.25 |
| E4 | 21/2 = 10.5 |
| E5 | 21.0 |
| E6 | 42.0 |
| E7 | 21.0 |

### Chemistry-Derived Qubit Coordinates

- `qx = floor((mw_sum - 970) / 30) % 2`
- `qy = floor(ring_hbond_sum) % 2`
- `qz = floor(no_sum) % 2`

### Base-Point Lattice Coordinates

- `x = floor(((mw - 323.2) / 40) * 14 + pos * φ) % 15`
- `y = floor(rings*7 + hbonds*2 + pos * π) % 15`
- `z = floor(((atoms - 13) / 3) * 14 + pos * 5.25) % 15`

### Outliers

- **Chemistry builder**: AUG → sorted=[0,0,6], coord_sum=42.0
- **Placeholder builder**: GCA → sorted=[0,0,6], coord_sum=42.0

## Cross-Wiring

| Codon concept | Existing system concept | Implementation |
|---|---|---|
| 6-bit base-4 index | 3-qubit computational basis | `codonToQubitState()` / Q# `CodonEncode6Bit` |
| Chemistry qubit coords | 3-qubit octonion basis | `chemistryQubitIndex()` / Q# `CodonEncode3Qubit` |
| Routing channel E0..E7 | Octonion basis e0..e7 | `channelToOctonion()` / Q# `CodonOctonionCrossWire` |
| Channel position | 15×15 matrix central row | `channelToCentralRow()` |
| Channel reflection | Γ = (z-1)/(z+1) | `channelToGamma()` / Q# `CodonSmithMobiusBoundary` |

## Verified Values

- AUG qubit coords = (0, 0, 0)
- UAA qubit coords = (1, 1, 1)
- GAA qubit coords = (0, 1, 1)
- AUG surface area ≈ 10.2694 nm²
- UAA surface area ≈ 10.0885 nm²
- AUG lattice area ≈ 20.62
- UAA lattice area ≈ 59.76
- UGA e0_count = 3
- UGA lattice area squared magnitude = 3041
- Ladder E6 = 42.0 (exact)
- 3 stop codons, 4 acidic codons, 64 total codons

## Implementation

- **Zig core**: `src/codon.zig` — 64-codon genetic code, base-4 encoding, chemistry computations (Q128.128 fixed-point), routing rules, both builders, cross-wiring, 12 proof checks, 34 tests
- **Q#**: `qsharp/CodonProofs.qs` — 6-qubit codon encoding, 3-qubit chemistry encoding, routing phase witnesses, Smith/Möbius boundary, 6 witness operations
- **Sidecar**: `sidecar/verify_codon.zig` — f64 validation of surface area, lattice area, qubit coords, ladder coords, 16 tests
- **Proof integration**: `proof_core.zig` chunk22() includes `codon.proof()` as additional check

## Scientific Limitations

1. Chemistry-derived routing fields use documented heuristics; source manuscripts do not define exact base-to-dimension mapping.
2. PlaceholderSignatureBuilder and ChemistrySignatureBuilder produce different routing for polar/basic amino acids.
3. Port verifies arithmetic identities and routing rule consistency, not the speculative biological interpretation.
4. No genome classification accuracy or shuffled-control p-values computed in Zig/Q# port.
5. Does not prove a physical Jordan algebra embedding.
