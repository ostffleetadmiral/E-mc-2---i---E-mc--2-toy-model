# Axioms A1-A7

The mathematical foundations of the Qstar lattice engine. Each axiom maps to a concrete function in `lattice.zig`. Every function traces to one of these axioms.

---

## A1: Grid & 3+1 Shell Architecture

**Concept:** The universe is a 3D lattice grid with edge length 15 at the base level (s=0), doubling per level up to s=7, enveloped by a 3+1 shell ($16^3$) with $e_8$ boundary closure.

**Formula:**
```
edge(s) = 15 × 2^s
shell(s) = edge(s) × 16/15
interior_nodes(s) = edge(s)³ = 15³ = 3,375
shell_nodes(s) = shell(s)³ = 16³ = 4,096
boundary_nodes(s) = shell_nodes(s) - interior_nodes(s) = 4,096 - 3,375 = 721 (7 × 103)
qubits(s) = 8^s
resolution(s) = 8^(s+1)
```

**3+1 Shell Topology:**
- **3 Spatial Sides:** Channels $e_1..e_7$ radiating outward from $e_0$ observer at center $(7,7,7)$.
- **1 Final Plane:** $e_8$ Möbius boundary completion ($E_8$ root system, 240 roots), pointing toward the open circuit ($|\Gamma| = \infty$) of the conjugate Smith Chart.
- **Boundary Defect:** $\delta = 7 / 225 \approx 0.03111$.
- **Active Node Density:** $\rho = 421 / 3375 \approx 0.12474$.
- **Universal Coupling Constant:** $g = \delta \times \rho = (7/225) \times (421/3375) \approx 0.0038809$.

**Implementation:**
- `latticeEdge(level)` → `BASE_EDGE * (1 << level)`
- `shellEdge(level)` → `latticeEdge(level) * 16 / 15`
- `interiorNodes(level)` → `edge³`
- `shellNodes(level)` → `shell_edge³`
- `boundaryNodes(level)` → `shellNodes - interiorNodes` (721 at s=0)
- `qubitCount(level)` → `1 << (level * 3)` (8^s scaling)
- `resolutionDims(level)` → `1 << ((level + 1) * 3)`
- `unflatCoords(chunk_idx, level)` → 3D coordinates from flat index

**Scale table:**

| s | Edge | Interior Nodes | Shell Nodes | Boundary Cells | Qubits | Universes | Physical Scale |
|---|------|----------------|-------------|----------------|--------|-----------|----------------|
| 0 | 15 | 3,375 | 4,096 | 721 | 1 | 1 | Quantum event |
| 1 | 30 | 27,000 | 32,768 | 5,768 | 8 | 8 | Atomic nucleus |
| 2 | 60 | 216,000 | 262,144 | 46,144 | 64 | 64 | DNA codon |
| 3 | 120 | 1,728,000 | 2,097,152 | 369,152 | 512 | 512 | Cell |
| 4 | 240 | 13,824,000 | 16,777,216 | 2,953,216 | 4,096 | 4,096 | Ecosystem |
| 5 | 480 | 110,592,000 | 134,217,728 | 23,625,728 | 32,768 | 32,768 | Planetary system |
| 6 | 960 | 884,736,000 | 1,073,741,824 | 189,005,824 | 262,144 | 262,144 | Galactic arm |
| 7 | 1,920 | 7,077,888,000 | 8,589,934,592 | 1,512,046,592 | 2,097,152 | 2,097,152 | Observable universe |

**Source:** Extracted from prototype (#13) LVCE grid initialization.

---

## A2: E0 Node Placement

**Concept:** 421 E0 nodes are placed in the 15³ base grid at positions where `(x + y + z) mod 3 == 0`. Each qualifying position maps to one of 421 slots via a multiplicative hash.

**Formula:**
```
if (x + y + z) mod 3 ≠ 0 → no E0 node
otherwise: index = (x×7 + y×11 + z×13) mod 421
```

**Implementation:**
- `E0_NODE_COUNT = 421`
- `e0NodeIndex(x, y, z)` → `?usize` (null if not an E0 position)

**Significance:** 421 E0 nodes replace 3 billion transformer parameters in the agent model (Phase 6, `agent.zig`). Each node has 7 channels (one per octonion dimension), giving 421 × 7 = 2,947 active units. The agent module implements lattice-native inference using these nodes with φ-cooling and Fibonacci projection, achieving 23 KB state size vs 75 MB for a traditional transformer.

**Source:** Extracted from prototype (#13), corrected from 422 to 421.

---

## A3: Möbius Twist & Dual-Twist Quadrupole (Boundary Reflection)

**Concept:** Data chunks on the boundary of the lattice undergo a Möbius reflection — their byte order is reversed — before octonion rotation. In EU v11.1, connecting a second twister at 90° ($\psi(x,y,0) = \psi(y,x,14)$) creates a 4-quadrant quadrupole ($E \perp B$) with 4-fold symmetry, producing orthogonal electric and magnetic traveling wave modes.

**The Dual Twister:**
- **Twister 1 (Original, 0°):** Anti-diagonal $\psi(x,y,0) = \psi(14-x, 14-y, 14)$, symmetry axis $x+y=14$ (Electric field $E$).
- **Twister 2 (Mirror, 90°):** Main diagonal $\psi(x,y,0) = \psi(y,x,14)$, symmetry axis $x=y$ (Magnetic field $B$).
- **Quadrupole Mapping:**
  - $Q_1$ ($x > 7, y > 7$): Quaternion $i$, Channel $e_1$
  - $Q_2$ ($x < 7, y > 7$): Quaternion $j$, Channel $e_2$
  - $Q_3$ ($x < 7, y < 7$): Quaternion $k$, Channel $e_3$
  - $Q_4$ ($x > 7, y < 7$): Quaternion $1$ (Real), Channel $e_0$

**Algorithm:**
```
Forward (Single Twist):
  1. Rotate bytes by e_val positions: rotated[(i + e) mod 8] = bytes[i]
  2. If boundary: reverse order: reflected[i] = rotated[7 - i]

Forward (Quadrupole Dual Twist):
  1. Apply T1 (0°): rotated_1[(i + e) mod 8] = bytes[i]
  2. Apply T2 (90°): cross-phase with quadrant offset (Q1..Q4)
  3. Combine orthogonal E ⊥ B modes
```

**Implementation:**
- `permuteChunkForward(bytes, e_val, is_boundary)` → `[8]u8`
- `permuteChunkInverse(bytes, e_val, is_boundary)` → `[8]u8`
- `permuteQuadrupole(bytes, e_val, quadrant, is_boundary)` → `[8]u8`
- `mapToLattice(allocator, data, level)` → full forward transform
- `unmapFromLattice(allocator, mapped, orig_len, level)` → full inverse

**Property:** `permuteChunkInverse(permuteChunkForward(x)) == x` — the transform is an involution ($R \circ G = I$).

---

## A4: Octonion Routing & Fano Plane Router

**Concept:** Each 8-byte chunk at lattice coordinates (x, y, z) is assigned an e-value (0-7) based on its position. In EU v11.1, channel transitions follow the 7 associative lines of the Fano plane router, establishing deterministic information transfer between Lie group algebras.

**The 7 Fano Plane Lines:**
1. **Line 1: $(e_1, e_2, e_3)$** — Real $\rightarrow$ Complex $\rightarrow$ Vector (Time $\rightarrow$ Plane $\rightarrow$ Space)
2. **Line 2: $(e_1, e_4, e_5)$** — Real $\rightarrow$ Quaternion $\rightarrow$ Bi-complex (Time $\rightarrow$ Spacetime $\rightarrow$ Fold/Language)
3. **Line 3: $(e_1, e_6, e_7)$** — Real $\rightarrow$ Jordan $\rightarrow$ Octonion (Time $\rightarrow$ Consciousness $\rightarrow$ Color Force)
4. **Line 4: $(e_2, e_4, e_6)$** — Complex $\rightarrow$ Quaternion $\rightarrow$ Jordan (Plane $\rightarrow$ Spacetime $\rightarrow$ Consciousness)
5. **Line 5: $(e_2, e_5, e_7)$** — Complex $\rightarrow$ Bi-complex $\rightarrow$ Octonion (Plane $\rightarrow$ Language $\rightarrow$ Color Force)
6. **Line 6: $(e_3, e_4, e_7)$** — Vector $\rightarrow$ Quaternion $\rightarrow$ Octonion (Space $\rightarrow$ Spacetime $\rightarrow$ Color Force)
7. **Line 7: $(e_3, e_5, e_6)$** — Vector $\rightarrow$ Bi-complex $\rightarrow$ Jordan (Space $\rightarrow$ Language $\rightarrow$ Consciousness)

**Formula:**
```
dx = min(x, edge-1-x)     // distance to nearest x-boundary
dy = min(y, edge-1-y)     // distance to nearest y-boundary
dz = |z - edge/2|         // distance from mid-plane
e = (6 - dx - dy + dz) mod 8
```

**Implementation:**
- `computeEValue(x, y, z, level)` → `u3` (0-7)
- `isBoundaryCoord(x, y, z, level)` → `bool`
- `FANO_LINES` → `[7][3]u3`
- `fanoRoute(ch_a, ch_b)` → `?u3` (returns third point on the Fano line)

---

## A5: φ-Cooling & Universal Coupling

**Concept:** Temperature decreases by the golden ratio φ per lattice level. Inter-level coupling and breathing dynamics are governed by the exact geometric coupling constant $g = \delta \times \rho$.

**Formula:**
```
T(s) = T₀ × φ^(-s)
Defect density: δ = 7 / 225 ≈ 0.03111
Active node density: ρ = 421 / 3375 ≈ 0.12474
Universal coupling constant: g = δ × ρ = (7/225) × (421/3375) ≈ 0.0038809
Fundamental breathing period: T_H = 0.704 ns (f_H = 1420.40575177 MHz)
Consciousness bandwidth: C = c(6) / c(5) = 42 / 21 = 2.0 (exact)
```

**Implementation:**
- `DEFECT_DELTA` → `7.0 / 225.0` (display) / Q32.32 `i64`
- `COUPLING_G` → `0.0038809` in Q32.32
- `BANDWIDTH_C` → `2.0` in Q32.32
- `T_H_NS` → `0.704`
- `coolTemperature()` in `agent.zig` using fixed-point φ-cooling and defect coupling $g$.

---

## A6: 15-Element Palindromic Dimensional Ladder

**Concept:** The universe follows a 15-element palindrome across the $e_0$ observer anchor with $e_8$ as the containing shell:
```
E = mc²  ↔  i  ↔  E = mc⁻²
where i = e0[e7, e6, e5, e4, e3, e2, e1, e0, e1, e2, e3, e4, e5, e6, e7]e0
e0 = E8 = 0⁰ = 240 roots (observer anchor)
```

**Dimension & Lie Group Table:**

| Dim | Name | Algebra | SM Gauge | Lie Group | Physics | Class |
|-----|------|---------|----------|-----------|---------|-------|
| 0 | Point | Real (observer anchor) | E8 | E8 × E8 (240 roots) | Origin / Observer | Preserved |
| 1 | Line | Real numbers | U(1) | A1 | Time / EM | Preserved |
| 2 | Plane | Complex numbers | U(1)×U(1) | A1 × A1 | Plane / Wave | Preserved |
| 3 | Space | Vector algebra (S³) | SO(3) | SO(4)=SU(2)×SU(2)| 3D Space | Chaotic |
| 4 | Quaternion | Quaternions | SU(2) | SO(5)=Sp(2) | Spacetime | Quaternion |
| 5 | Fold | Bi-complex | U(2) | SO(4)×SO(4) | Language / Fold | Preserved |
| 6 | Peak | Jordan algebra H₃(O) | E6/F4 | E6/F4 | Consciousness ($C=2$) | Jordan |
| 7 | Color | Octonions | SU(3) | G2 | Strong force | Chaotic |
| 8 | Boundary | Möbius completion | E8 | E8 root | 3+1 Shell ($e_8$) | Preserved |

Standard Model gauge unification: $U(1) \times SU(2) \times SU(3) = e_1 \times (e_2..e_4) \times e_7$.

**Scaling formulas:**
```
Preserved:  coord(s, d) = 2^(s + d/11)
Quaternion: coord(s, d) = 2^(s + d/11) × φ
Jordan:     coord(s, d) = 2^(s + d/11) / φ
Chaotic:    coord(s, d) = 2^(s + d/11) × sin(d)
```

**The Pattern:**
- **Preserved** (C=Yes, A=Yes): 0D, 1D, 2D, 5D, 8D, 10D — structure preserved
- **Quaternion** (C=No, A=Yes): 4D — quaternions unique (non-commutative but associative)
- **Jordan** (C=Yes, A=No): 6D — Jordan unique (commutative but non-associative)
- **Chaotic** (C=No, A=No): 3D, 7D, 9D — odd dimensions lose structure

**Ladder pattern:** perfect symmetry → chaos → fold (regain) → peak (Jordan) → chaos → boundary (regain)

**Key corrections from original mapping:**
- e0: U(1) not E8 (0D is a point, phase reference only — E8 is 8D)
- e2: SU(2) not A1×A1 (lattice symmetry at 2D)
- e6: E6/F4 (E6 is maximal, F4 is compact form)
- e7: SU(3) not G2 (G2 is automorphism group, SU(3) is the gauge group from octonions)
- 8D: Added (was missing — frequency dimension, dormant at s=0)
- 10D: SO(8) (triality = three 8D representations = three particle generations)

**Implementation:**
- `StructureClass` enum: `preserved`, `quaternion`, `jordan`, `chaotic`
- `DimSpec` struct with `structureClass()` method
- `DIMENSION_TABLE` — static array of all 11 `DimSpec` entries
- `dimCoordinate(level, dim)` — standard scaling
- `dimCoordinateRemapped(level, dim)` — per-dimension scaling by structure class
- Query functions: `dimSpec`, `dimName`, `dimAlgebra`, `dimSymmetry`, `dimPhysics`, `isCommutative`, `isAssociative`, `dimStructureClass`

**Source:** Remapped from first principles. Original concept from prototype (#13).

---

## A7: λ_H — Exact Wavelength

**Concept:** The Hubble wavelength λ_H is computed exactly as the speed of light divided by the Hubble frequency. This is the fundamental length scale of the observable universe.

**Formula:**
```
λ_H = c / f_H
```

**Implementation:**
- `C_LIGHT = 299_792_458.0` (m/s, exact by SI definition)
- `lambdaH(f_h)` → `C_LIGHT / f_h`

**Example:**
```
f_H = 2.4 GHz → λ_H = 299,792,458 / 2.4×10⁹ ≈ 0.1249 m
```

**Source:** Extracted from prototype (#13) λ_H calculation.

---

## Integer-Only Core State Invariant

All core state transitions in Qstar use `i64` Q32.32 fixed-point arithmetic. This is a fundamental architectural invariant:

### R∘G=I (Round-trip Involution)

For every generative transform G and its inverse R, R∘G = I (identity):

| Transform | G (forward) | R (inverse) | Round-trip |
|-----------|-------------|-------------|------------|
| Compression | `compress(data, config)` | `decompress(container)` | Bit-exact (gzip + dedup + lattice) |
| Möbius twist | `permuteChunkForward` | `permuteChunkInverse` | Bit-exact (involution) |
| Quantum compression | `compressState(state)` | `decompressState(data)` | Bit-exact (i64 serialization + CRC32) |
| Holographic encode | `holographicEncode(data)` | `holographicDecode(encoded)` | Bit-exact (i64 fixed-point FFT) |
| Shamir sharing | `shamirSplit(secret)` | `shamirRecover(shares)` | Bit-exact (GF(2^8) polynomial) |
| Reed-Solomon | `rsEncode(config, data)` | `rsReconstruct(shards)` | Bit-exact (GF(256)) |
| VFS page | `serializePage(page)` | `deserializePage(data)` | Bit-exact (i64 activation, 8 bytes per node) |

### Integer-Only Modules

| Module | Core State Type | Arithmetic |
|--------|----------------|------------|
| `agent.zig` | `activations: [421][7]i64`, `temperature: i64` | Q32.32 fixed-point (fp.mul, fp.div, fp.fromInt) |
| `quantum.zig` | `Complex { re: i64, im: i64 }`, `amplitudes: []Complex` | Q32.32 fixed-point (lookup tables for sin/cos) |
| `holographic.zig` | `Complex { re: i64, im: i64 }`, DFT input: `[]i64` | Q32.32 fixed-point (precomputed roots of unity) |
| `mesh.zig` | `SharedFace.local_states: [225]i64`, `remote_states: [225]i64` | Q32.32 fixed-point |
| `vfs_bridge.zig` | `E0Node.activation: i64` | Q32.32 fixed-point (8-byte serialization) |
| `compress.zig` | `E0NodeSeed.activation: i64` | Q32.32 fixed-point (8-byte serialization) |
| `render.zig` | `E0SeedNode.activation: i64` → `ExpandedCell.activation: f32` | i64 in seed, f32 at display boundary |

### Floating-Point Sidecars (never feed back into core state)

| Module | Usage | Type |
|--------|-------|------|
| `render.zig` | Camera, projection, WGSL uniforms, Smith Chart | f32/f64 (display) |
| `entangle.zig` | DLCZ Monte Carlo simulation | f64 (physics simulation) |
| `lattice.zig` | `phiCooling`, `dimCoordinate`, `lambdaH` | f64 (query/display sidecar) |

---

## Axiom Interactions

The axioms are not independent — they interact through the lattice geometry:

```
A1 (Grid) ─── provides coordinates for ──→ A4 (Octonion Routing)
  │                                            │
  │                                            ▼
  │                                     A3 (Möbius Twist)
  │                                            │
  │                                            ▼
  └── provides levels for ──→ A5 (φ-Cooling)   │
                               │                │
                               ▼                ▼
                          A6 (11-Dim) ── scales ──→ A2 (E0 Placement)
                               │
                               ▼
                          A7 (λ_H) — fundamental length scale
```

- **A1** defines the grid that **A4** routes through
- **A3** transforms data at boundaries defined by **A1**
- **A5** cools the system as it expands through **A1** levels
- **A6** provides the dimensional framework for **A2** node placement
- **A7** sets the fundamental scale that **A1** levels are measured against

---

## Supporting Structures

### Ring Location (from freenet-core)

A 1D ring location on [0, 1) with circular distance metric. Used by the peer mesh for routing.

- `Location.new(v)` — validate and create
- `Location.fromBytes(bytes)` — hash to location
- `Location.distance(other)` — shortest arc
- `Location.signedDistance(other)` — signed arc

### Isotonic Regression (PAV algorithm)

Monotonically non-decreasing regression using Pool Adjacent Violators. Used for fitting observed data to monotonic constraints.

- `IsotonicRegression.fit(allocator, raw)` — PAV fit
- `IsotonicRegression.predict(x)` — linear interpolation

### RMSY Container Format

24-byte header + payload with CRC32 integrity. Used by the compressor to wrap lattice-transformed data.

### Manifest Format

32-byte header + file entries. Used for multi-file archives with per-file CRC32 verification.

---

## Quantum Holographic Axiom Extensions

The quantum holographic compute modules (`holographic.zig`, `quantum.zig`, `entangle.zig`, `compute.wgsl`) extend the A1-A7 axioms into the quantum and holographic domains:

### A1 → 3D DFT Domain

The lattice grid (A1) serves as the spatial domain for the 3D DFT. `latticeFFT` transforms E0 activations from spatial to frequency domain, with e-value phase modulation providing position-dependent spectral encoding. The DFT operates on arbitrary-size lattices (no power-of-2 padding required).

### A2 → Quantum Basis States

E0 node placement (A2) maps to quantum basis states. The 421 E0 nodes define the computational basis for quantum state vectors. `quantum.zig` uses 2^N amplitudes where N qubits encode E0 activation patterns.

### A3 → Möbius Phase Reflection

The Möbius twist (A3) extends to the frequency domain as a phase reflection at lattice boundaries. In `holographic.zig`, boundary cells receive conjugate phase factors in the DFT, creating a non-orientable frequency topology.

### A4 → Quantum Gate Algebra

The 8 e-values (A4) correspond to the 8 quantum gate types: Identity, Hadamard, CNOT, Pauli-X, Pauli-Y, Pauli-Z, Phase, SWAP. The octonion routing formula determines which gate applies at each lattice position, creating a position-dependent quantum circuit.

### A5 → Grover Iteration Optimization

The φ-cooling schedule (A5) determines the optimal Grover iteration count: `iterations ≈ π/4 × √N`, where N = 2^(number of qubits). The golden ratio governs the convergence rate of amplitude amplification.

### A6 → Entanglement Routing Dimensions

The 11-dimensional ladder (A6) provides the routing framework for entanglement distribution. Kleinberg greedy forwarding operates on a ring topology where long-range contacts follow the 11-dim scaling formula. Shamir secret sharing uses GF(2^8) with polynomial evaluation across dimensions.

### A7 → RF Fingerprint Wavelength

The Hubble wavelength (A7) extends to RF fingerprinting: the 128-dim fingerprint vector captures spectral signatures at wavelengths determined by `λ = c/f`, where f ranges over the DFT frequency bins. The fingerprint is L2-normalized to unit length, matching the quantum state normalization condition.
