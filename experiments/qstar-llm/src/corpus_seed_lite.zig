//! corpus_seed_lite.zig — Reduced seed corpus for ESP32 device-lite wasm (~8 KB).
//!
//! Contains the lattice/quantum core, fixed-point arithmetic, conversational
//! responses, and minimal domain coverage. Additional corpus arrives via SD
//! card at boot (Phase 5) or through learn_from_text at runtime.

pub const IS_LITE: bool = true;

pub const SEED_CORPUS_TEXT: []const u8 =
    \\The E0 lattice projects continuous coordinates onto a discrete grid with 421 basis nodes.
    \\Octonionic routing distributes activation signals across seven reasoning channels.
    \\The Fibonacci projection weights channel activations using golden ratio proportions.
    \\Discrete lattice geometry provides a natural framework for cellular automaton computation.
    \\The Mobius reflection at boundary nodes creates symmetric activation patterns.
    \\Refractory inhibition prevents repeated firing of the same node in consecutive cycles.
    \\Self-assembly Monte Carlo relaxation reconfigures activation flow paths with phi cooling.
    \\The lattice invariant constraint requires that coordinates satisfy modular arithmetic conditions.
    \\E0 nodes fire when their activation exceeds a threshold after temperature scaling.
    \\Neighbor propagation spreads activation along lattice edges with weighted connections.
    \\Fixed-point arithmetic eliminates floating-point rounding drift across different hardware.
    \\The Q32.32 format represents values as 64-bit integers with 32 fractional bits.
    \\Integer-only computation guarantees deterministic execution on any processor architecture.
    \\Fixed-point multiplication requires careful shifting to maintain precision.
    \\Quantum superposition allows particles to exist in multiple states simultaneously until measured.
    \\The quantum state vector collapses into an observable eigenstate upon measurement.
    \\Quantum entanglement connects particles across vast distances through nonlocal correlations.
    \\The Heisenberg uncertainty principle states that position and momentum cannot be simultaneously known.
    \\Quantum decoherence occurs when a quantum system interacts with its environment losing phase coherence.
    \\The Schrodinger equation describes how the quantum state of a physical system changes over time.
    \\Quantum tunneling enables particles to pass through energy barriers that they classically should not.
    \\The double slit experiment demonstrates wave particle duality of light and matter.
    \\Quantum computing uses qubits that can exist in superposition of zero and one states.
    \\Grover search algorithm provides quadratic speedup over classical linear search algorithms.
    \\Shor algorithm factors integers in polynomial time on a quantum computer.
    \\Quantum error correction uses entangled ancilla qubits to detect and correct errors.
    \\The Bell inequality proves that quantum mechanics cannot be explained by local hidden variables.
    \\Quantum field theory describes particles as excitations of underlying fields permeating spacetime.
    \\The Planck constant relates the energy of a photon to its frequency in quantum mechanics.
    \\The golden ratio appears in nature art and architecture as a proportion of harmony.
    \\Fibonacci sequences model growth patterns in shells plants and spiral galaxies.
    \\Mathematics is the language of nature describing patterns and relationships in abstract structures.
    \\Algorithms are step-by-step procedures for solving problems and processing data.
    \\Programming is the art of instructing computers to perform tasks through code.
    \\Functions encapsulate reusable logic that accepts parameters and returns results.
    \\Variables store data values that can be read and modified during program execution.
    \\Loops repeat blocks of code until a condition is met or a limit is reached.
    \\Artificial intelligence enables machines to learn reason and make decisions.
    \\Machine learning trains models on data to recognize patterns and make predictions.
    \\Neural networks use layered interconnected nodes inspired by biological neurons.
    \\Natural language processing enables computers to understand and generate human language.
    \\Inference runs trained models on new inputs to produce predictions or outputs.
    \\The speed of light in vacuum is approximately 299792458 meters per second.
    \\General relativity describes gravity as curvature of spacetime caused by mass.
    \\Energy and mass are equivalent according to the famous equation E equals mc squared.
    \\The Big Bang theory describes the origin of the universe from a singularity.
    \\Photosynthesis converts sunlight into chemical energy stored in glucose molecules.
    \\Cells are the basic structural and functional units of all living organisms.
    \\DNA carries the genetic instructions for the development and function of living organisms.
    \\The brain processes information through networks of neurons firing electrical signals.
    \\The sky appears blue because air molecules scatter shorter blue wavelengths more than red.
    \\The chemical formula for water is H2O with two hydrogen atoms bonded to one oxygen atom.
    \\Paris is the capital of France and has been a major center of culture art and politics for centuries.
    \\TCP provides reliable ordered delivery of data packets between networked applications.
    \\UDP offers lightweight fast datagram transmission without delivery guarantees.
    \\Data compression reduces the size of information for efficient storage and transmission.
    \\Cryptography secures communications by encrypting data with mathematical algorithms.
    \\The Qstar agent maps text to E0 node activations and propagates signals through octonionic reasoning channels.
    \\The E0 lattice projects continuous coordinates onto a discrete grid with 421 basis nodes across seven channels.
    \\Fixed-point arithmetic eliminates floating-point rounding drift guaranteeing bit-exact execution across hardware architectures.
    \\The Q32.32 format represents values as 64-bit integers with 32 fractional bits for deterministic computation.
    \\Programming in Zig provides memory safety without garbage collection and explicit allocation semantics.
    \\Computer networks connect devices using TCP for reliable delivery and UDP for lightweight datagram transmission.
    \\Data compression reduces information size using Huffman coding entropy encoding and quantization techniques.
    \\Hello and welcome to the world of intelligent conversation and reasoning.
    \\How can I help you today? I am here to answer questions and provide information.
    \\Thank you for your question. Let me provide a detailed and thoughtful response.
    \\That is an interesting topic. There are many perspectives to consider.
    \\I understand your concern. Let me explain the key concepts and principles.
    \\The answer depends on several factors that we should examine carefully.
    \\Let me break this down into simpler terms for better understanding.
    \\This is a complex subject with many interrelated components and considerations.
    \\To fully understand this we need to consider the underlying principles.
    \\The key insight is that small changes can have large cascading effects.
    \\In summary the main points are clear and the conclusions follow logically.
    \\Therefore we can see that the relationship between these concepts is fundamental.
    \\Furthermore additional research and analysis would provide deeper insights.
    \\Finally it is important to remember that context matters in all situations.
    \\Overall this represents a significant advancement in our understanding.
    \\Knowledge is understanding of or information about a subject acquired through experience or education.
    \\Science is a systematic enterprise that builds and organizes knowledge through testable explanations.
    \\Logic requires precision in reasoning teaching us not to jump to conclusions that are not justified by evidence.
    \\Two plus two equals four in standard arithmetic and this is not a matter of opinion but mathematical fact.
    \\Consciousness is the state of being aware of and able to perceive experiences subjectively.
    \\The meaning of life is a philosophical question that has been debated for centuries.
    \\The E=mc²-i-E=mc⁻² framework connects octonion algebra to physics through a generative bootstrap chain.
    \\The 421 identity states that 421 equals 15³ minus 7 divided by 8 connecting E0 nodes to the octonion dimension.
    \\The consciousness aperture is 1/8 meaning the observer occupies one eighth of the lattice space.
    \\The C=2 consciousness value arises from the 5D to 6D transition creating the observer-observed duality.
    \\The 7-defect is the structural gap in cubic doubling where 2³ minus 1 equals 7.
    \\The surface computation 2 plus 7 equals 9 connects the boundary dimension to the 7-defect.
    \\The E8 root system has 240 roots which equals 15 times 16 connecting SM fermions to the SO(10) spinor.
    \\The generative axiom 0^0=i generates complex numbers quaternions and octonions through the Cayley-Dickson construction.
    \\The framework uses fixed-point arithmetic to eliminate floating-point rounding drift across hardware platforms.
    \\The phi cooling schedule decreases temperature by the golden ratio factor per level for natural lattice annealing.
;

// =============================================================================
// Tests
// =============================================================================

const std = @import("std");

test "corpus_seed_lite: IS_LITE is true for lite corpus" {
    try std.testing.expect(IS_LITE);
}

test "corpus_seed_lite: SEED_CORPUS_TEXT is non-empty" {
    try std.testing.expect(SEED_CORPUS_TEXT.len > 1000);
}

test "corpus_seed_lite: SEED_CORPUS_TEXT contains lattice content" {
    try std.testing.expect(std.mem.indexOf(u8, SEED_CORPUS_TEXT, "E0") != null);
    try std.testing.expect(std.mem.indexOf(u8, SEED_CORPUS_TEXT, "lattice") != null);
}

test "corpus_seed_lite: SEED_CORPUS_TEXT contains fixed-point content" {
    try std.testing.expect(std.mem.indexOf(u8, SEED_CORPUS_TEXT, "fixed-point") != null);
}

test "corpus_seed_lite: SEED_CORPUS_TEXT contains phi cooling content" {
    try std.testing.expect(std.mem.indexOf(u8, SEED_CORPUS_TEXT, "phi cooling") != null);
}

test "corpus_seed_lite: SEED_CORPUS_TEXT contains E8 content" {
    try std.testing.expect(std.mem.indexOf(u8, SEED_CORPUS_TEXT, "E8") != null);
}
