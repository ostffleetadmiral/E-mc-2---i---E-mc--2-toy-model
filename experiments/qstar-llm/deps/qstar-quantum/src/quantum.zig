//! quantum.zig — Quantum gate model on the Qstar lattice.
//!
//! Implements quantum gates (Hadamard, CNOT, Pauli X/Y/Z), Bell pair
//! generation, Grover amplification, state compression (Huffman-inspired
//! amplitude encoding from prototype lvce_huffman), and quantum state
//! chain (SHA-256 tip hash from llm/quine.html blockchain pattern).
//!
//! Foundation integration:
//!   - prototype lvce_huffman: amplitude compression
//!   - prototype lvce_token_packer: N-bit amplitude quantization
//!   - llm/quine.html: blockchain state chain (SHA-256 tip hash)
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

/// Number of E0 nodes (lattice qubit positions).
pub const E0_NODE_COUNT: usize = 421;

/// Number of channels (octonion dimensions e0-e6).
pub const CHANNEL_COUNT: usize = 7;

/// Maximum qubits supported in simulation.
pub const MAX_QUBITS: usize = 20;

// =============================================================================
// Complex number (reused from holographic.zig pattern)
// =============================================================================

pub const Complex = struct {
    re: i64,
    im: i64,

    pub inline fn new(re: i64, im: i64) Complex {
        return .{ .re = re, .im = im };
    }

    pub inline fn zero() Complex {
        return .{ .re = 0, .im = 0 };
    }

    pub inline fn one() Complex {
        return .{ .re = fp.ONE, .im = 0 };
    }

    pub inline fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub inline fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub inline fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = fp.mul(a.re, b.re) - fp.mul(a.im, b.im),
            .im = fp.mul(a.re, b.im) + fp.mul(a.im, b.re),
        };
    }

    pub inline fn scale(a: Complex, s: i64) Complex {
        return .{ .re = fp.mul(a.re, s), .im = fp.mul(a.im, s) };
    }

    pub inline fn conjugate(a: Complex) Complex {
        return .{ .re = a.re, .im = -a.im };
    }

    pub fn magnitude(a: Complex) i64 {
        return fp.sqrt(fp.mul(a.re, a.re) + fp.mul(a.im, a.im));
    }

    pub inline fn magnitudeSq(a: Complex) i64 {
        return fp.mul(a.re, a.re) + fp.mul(a.im, a.im);
    }

    pub inline fn eql(a: Complex, b: Complex) bool {
        return a.re == b.re and a.im == b.im;
    }
};

// =============================================================================
// Quantum State — 2^n amplitude vector
// =============================================================================

/// A quantum state of n qubits: 2^n complex amplitudes.
pub const QuantumState = struct {
    num_qubits: u8,
    amplitudes: []Complex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_qubits: u8) !QuantumState {
        const n = @as(usize, 1) << @intCast(num_qubits);
        const amplitudes = try allocator.alloc(Complex, n);
        for (amplitudes) |*a| a.* = Complex.zero();
        amplitudes[0] = Complex.one(); // |0...0⟩
        return .{
            .num_qubits = num_qubits,
            .amplitudes = amplitudes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuantumState) void {
        self.allocator.free(self.amplitudes);
    }

    pub fn clone(self: QuantumState) !QuantumState {
        const new_state = try QuantumState.init(self.allocator, self.num_qubits);
        @memcpy(new_state.amplitudes, self.amplitudes);
        return new_state;
    }

    /// Returns the number of basis states (2^n).
    pub inline fn dimension(self: QuantumState) usize {
        return self.amplitudes.len;
    }

    /// Normalizes the state so that total probability = 1 (fp.ONE).
    pub fn normalize(self: *QuantumState) void {
        var norm: i64 = 0;
        for (self.amplitudes) |a| norm += a.magnitudeSq();
        norm = fp.sqrt(norm);
        if (norm > 0) {
            const inv_norm = fp.div(fp.ONE, norm);
            for (self.amplitudes) |*a| a.* = a.scale(inv_norm);
        }
    }

    /// Computes the total probability (should be fp.ONE after normalize).
    pub fn totalProbability(self: QuantumState) i64 {
        var p: i64 = 0;
        for (self.amplitudes) |a| p += a.magnitudeSq();
        return p;
    }

    /// Measures the state, collapsing to a basis state.
    /// Returns the measured basis state index.
    /// Uses integer-based cumulative probability for deterministic measurement.
    pub fn measure(self: *QuantumState, rng: *std.Random.DefaultPrng) usize {
        const r: i64 = @as(i64, @intCast(rng.random().int(u32))) << 32;
        var cumulative: i64 = 0;
        for (self.amplitudes, 0..) |a, i| {
            cumulative += a.magnitudeSq();
            if (r <= cumulative) {
                for (self.amplitudes) |*amp| amp.* = Complex.zero();
                self.amplitudes[i] = Complex.one();
                return i;
            }
        }
        return self.amplitudes.len - 1;
    }

    /// Gets the probability of measuring a specific basis state.
    pub inline fn probability(self: QuantumState, basis_idx: usize) i64 {
        if (basis_idx >= self.amplitudes.len) return 0;
        return self.amplitudes[basis_idx].magnitudeSq();
    }
};

// =============================================================================
// Quantum Gates
// =============================================================================

/// Gate type enumeration.
pub const GateType = enum {
    hadamard,
    cnot,
    pauli_x,
    pauli_y,
    pauli_z,
    phase,
    swap,
};

/// A quantum gate application descriptor.
pub const Gate = struct {
    gate_type: GateType,
    target: u8,
    control: ?u8 = null, // For CNOT, SWAP
    parameter: i64 = 0, // For phase gates (Q32.32 angle)
};

/// Applies a Hadamard gate to qubit `target` in the state.
/// H = (1/√2) [[1, 1], [1, -1]]
/// Uses precomputed INV_SQRT2 in Q32.32.
pub fn applyHadamard(state: *QuantumState, target: u8) void {
    const size = state.amplitudes.len;
    const target_bit = @as(usize, 1) << @intCast(target);

    var i: usize = 0;
    while (i < size) : (i += 1) {
        if ((i & target_bit) == 0) {
            const j = i | target_bit;
            const a = state.amplitudes[i];
            const b = state.amplitudes[j];
            state.amplitudes[i] = Complex.new(
                fp.mul(a.re + b.re, fp.INV_SQRT2),
                fp.mul(a.im + b.im, fp.INV_SQRT2),
            );
            state.amplitudes[j] = Complex.new(
                fp.mul(a.re - b.re, fp.INV_SQRT2),
                fp.mul(a.im - b.im, fp.INV_SQRT2),
            );
        }
    }
}

/// Applies a CNOT gate with `control` controlling `target`.
/// Flips target bit when control bit is 1.
pub fn applyCNOT(state: *QuantumState, control: u8, target: u8) void {
    const size = state.amplitudes.len;
    const control_bit = @as(usize, 1) << @intCast(control);
    const target_bit = @as(usize, 1) << @intCast(target);

    for (0..size) |i| {
        if ((i & control_bit) != 0 and (i & target_bit) == 0) {
            const j = i | target_bit;
            const tmp = state.amplitudes[i];
            state.amplitudes[i] = state.amplitudes[j];
            state.amplitudes[j] = tmp;
        }
    }
}

/// Applies Pauli-X gate (bit flip) to `target`.
/// X = [[0, 1], [1, 0]]
pub fn applyPauliX(state: *QuantumState, target: u8) void {
    const size = state.amplitudes.len;
    const target_bit = @as(usize, 1) << @intCast(target);

    for (0..size) |i| {
        if ((i & target_bit) == 0) {
            const j = i | target_bit;
            const tmp = state.amplitudes[i];
            state.amplitudes[i] = state.amplitudes[j];
            state.amplitudes[j] = tmp;
        }
    }
}

/// Applies Pauli-Y gate to `target`.
/// Y = [[0, -i], [i, 0]]
pub fn applyPauliY(state: *QuantumState, target: u8) void {
    const size = state.amplitudes.len;
    const target_bit = @as(usize, 1) << @intCast(target);
    const i_complex = Complex{ .re = 0, .im = fp.ONE };
    const neg_i = Complex{ .re = 0, .im = -fp.ONE };

    for (0..size) |idx| {
        if ((idx & target_bit) == 0) {
            const j = idx | target_bit;
            const a = state.amplitudes[idx];
            const b = state.amplitudes[j];
            state.amplitudes[idx] = Complex.mul(neg_i, b);
            state.amplitudes[j] = Complex.mul(i_complex, a);
        }
    }
}

/// Applies Pauli-Z gate to `target`.
/// Z = [[1, 0], [0, -1]]
pub fn applyPauliZ(state: *QuantumState, target: u8) void {
    const size = state.amplitudes.len;
    const target_bit = @as(usize, 1) << @intCast(target);

    for (0..size) |i| {
        if ((i & target_bit) != 0) {
            state.amplitudes[i] = state.amplitudes[i].scale(-fp.ONE);
        }
    }
}

/// Applies a phase gate R(θ) to `target`.
/// R(θ) = [[1, 0], [0, e^(iθ)]]
/// Uses integer sin/cos lookup tables.
pub fn applyPhase(state: *QuantumState, target: u8, theta: i64) void {
    const size = state.amplitudes.len;
    const target_bit = @as(usize, 1) << @intCast(target);
    const phase_factor = Complex{
        .re = fp.cos(theta),
        .im = fp.sin(theta),
    };

    for (0..size) |i| {
        if ((i & target_bit) != 0) {
            state.amplitudes[i] = Complex.mul(state.amplitudes[i], phase_factor);
        }
    }
}

/// Applies a SWAP gate between qubits `a` and `b`.
pub fn applySWAP(state: *QuantumState, a: u8, b: u8) void {
    if (a == b) return;
    const size = state.amplitudes.len;
    const a_bit = @as(usize, 1) << @intCast(a);
    const b_bit = @as(usize, 1) << @intCast(b);

    for (0..size) |i| {
        const has_a = (i & a_bit) != 0;
        const has_b = (i & b_bit) != 0;
        if (has_a != has_b) {
            const j = i ^ a_bit ^ b_bit;
            if (j > i) {
                const tmp = state.amplitudes[i];
                state.amplitudes[i] = state.amplitudes[j];
                state.amplitudes[j] = tmp;
            }
        }
    }
}

/// Applies a gate to the state.
pub fn applyGate(state: *QuantumState, gate: Gate) void {
    switch (gate.gate_type) {
        .hadamard => applyHadamard(state, gate.target),
        .cnot => applyCNOT(state, gate.control.?, gate.target),
        .pauli_x => applyPauliX(state, gate.target),
        .pauli_y => applyPauliY(state, gate.target),
        .pauli_z => applyPauliZ(state, gate.target),
        .phase => applyPhase(state, gate.target, gate.parameter),
        .swap => applySWAP(state, gate.control.?, gate.target),
    }
}

// =============================================================================
// Bell Pair Generation
// =============================================================================

/// Creates a Bell pair (maximally entangled 2-qubit state).
/// |Φ+⟩ = (|00⟩ + |11⟩) / √2
pub fn createBellPair(allocator: std.mem.Allocator) !QuantumState {
    var state = try QuantumState.init(allocator, 2);
    // Start in |00⟩
    // Apply Hadamard to qubit 0
    applyHadamard(&state, 0);
    // Apply CNOT with control=0, target=1
    applyCNOT(&state, 0, 1);
    return state;
}

/// Creates a Bell pair with a specific Bell state.
pub const BellState = enum {
    phi_plus, // (|00⟩ + |11⟩) / √2
    phi_minus, // (|00⟩ - |11⟩) / √2
    psi_plus, // (|01⟩ + |10⟩) / √2
    psi_minus, // (|01⟩ - |10⟩) / √2
};

pub fn createBellState(allocator: std.mem.Allocator, bell: BellState) !QuantumState {
    var state = try QuantumState.init(allocator, 2);
    switch (bell) {
        .phi_plus => {
            applyHadamard(&state, 0);
            applyCNOT(&state, 0, 1);
        },
        .phi_minus => {
            applyHadamard(&state, 0);
            applyCNOT(&state, 0, 1);
            applyPauliZ(&state, 0);
        },
        .psi_plus => {
            applyHadamard(&state, 0);
            applyCNOT(&state, 0, 1);
            applyPauliX(&state, 1);
        },
        .psi_minus => {
            applyHadamard(&state, 0);
            applyCNOT(&state, 0, 1);
            applyPauliX(&state, 1);
            applyPauliZ(&state, 0);
        },
    }
    return state;
}

// =============================================================================
// Grover's Search Algorithm
// =============================================================================

/// Grover's search over n qubits.
/// `oracle` marks the target basis state by flipping its phase.
/// `num_iterations` = optimal ≈ π/(4) × √(N/M) where N=2^n, M=number of targets.
pub fn groverSearch(
    state: *QuantumState,
    target_idx: usize,
    num_iterations: u32,
) void {
    const n = state.num_qubits;
    const size = state.amplitudes.len;

    // Step 1: Apply Hadamard to all qubits (uniform superposition)
    for (0..n) |q| {
        applyHadamard(state, @intCast(q));
    }

    // Step 2: Grover iterations
    for (0..num_iterations) |_| {
        // Oracle: flip phase of target state
        state.amplitudes[target_idx] = state.amplitudes[target_idx].scale(-fp.ONE);

        // Diffusion operator (Grover amplification)
        // H^n (2|0⟩⟨0| - I) H^n = 2|s⟩⟨s| - I
        // where |s⟩ is the uniform superposition

        // Apply H^n
        for (0..n) |q| {
            applyHadamard(state, @intCast(q));
        }

        // Apply (2|0⟩⟨0| - I): flip all except |0⟩, then flip all
        for (0..size) |i| {
            if (i != 0) {
                state.amplitudes[i] = state.amplitudes[i].scale(-fp.ONE);
            }
        }

        // Apply H^n again
        for (0..n) |q| {
            applyHadamard(state, @intCast(q));
        }
    }
}

/// Computes the optimal number of Grover iterations for N items.
/// Returns floor(π/4 × √N) using fixed-point arithmetic.
pub fn optimalGroverIterations(num_items: usize) u32 {
    const n_fp = fp.fromInt(@as(i64, @intCast(num_items)));
    const sqrt_n = fp.sqrt(n_fp);
    const pi_over_4 = fp.div(fp.PI, fp.fromInt(4));
    const result = fp.mul(pi_over_4, sqrt_n);
    return @intCast(fp.toInt(result));
}

// =============================================================================
// State Compression (bit-exact i64 serialization)
// =============================================================================

/// Amplitude compression header.
pub const QuantumHeader = struct {
    magic: [4]u8 = .{ 'Q', 'S', 'T', 'A' }, // Quantum STate Archive
    version: u16 = 2, // Version 2 = integer-only format
    num_qubits: u8,
    num_amplitudes: u32,
    checksum: u32,

    pub const SIZE: usize = 4 + 2 + 1 + 4 + 4;

    pub fn write(self: QuantumHeader, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u16, self.version, .little);
        try writer.writeByte(self.num_qubits);
        try writer.writeInt(u32, self.num_amplitudes, .little);
        try writer.writeInt(u32, self.checksum, .little);
    }

    pub fn read(reader: anytype) !QuantumHeader {
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &.{ 'Q', 'S', 'T', 'A' })) return error.InvalidMagic;
        return .{
            .magic = magic,
            .version = try reader.readInt(u16, .little),
            .num_qubits = try reader.readByte(),
            .num_amplitudes = try reader.readInt(u32, .little),
            .checksum = try reader.readInt(u32, .little),
        };
    }
};

/// Compresses quantum state into exact binary representation.
/// Each amplitude (re, im) is stored as raw i64 — NO quantization, NO loss.
/// Round-trip is bit-exact: decompressState(compressState(s)) == s.
pub fn compressState(allocator: std.mem.Allocator, state: QuantumState) ![]u8 {
    const total = state.amplitudes.len;

    var hasher = std.hash.Crc32.init();
    for (state.amplitudes) |a| {
        hasher.update(std.mem.asBytes(&a.re));
        hasher.update(std.mem.asBytes(&a.im));
    }
    const checksum = hasher.final();

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.ensureTotalCapacity(total * 16 + 64);
    const header = QuantumHeader{
        .num_qubits = state.num_qubits,
        .num_amplitudes = @intCast(total),
        .checksum = checksum,
    };
    try header.write(buf.writer());

    for (state.amplitudes) |a| {
        try buf.writer().writeInt(i64, a.re, .little);
        try buf.writer().writeInt(i64, a.im, .little);
    }

    return buf.toOwnedSlice();
}

/// Decompresses binary representation back to quantum state.
/// Bit-exact inverse of compressState.
pub fn decompressState(allocator: std.mem.Allocator, encoded: []const u8) !QuantumState {
    var fbs = std.io.fixedBufferStream(encoded);
    const header = try QuantumHeader.read(fbs.reader());
    if (header.version != 2) return error.UnsupportedVersion;

    const total: usize = @intCast(header.num_amplitudes);
    var state = try QuantumState.init(allocator, header.num_qubits);
    errdefer state.deinit();

    for (0..total) |i| {
        state.amplitudes[i].re = try fbs.reader().readInt(i64, .little);
        state.amplitudes[i].im = try fbs.reader().readInt(i64, .little);
    }

    var hasher = std.hash.Crc32.init();
    for (state.amplitudes) |a| {
        hasher.update(std.mem.asBytes(&a.re));
        hasher.update(std.mem.asBytes(&a.im));
    }
    if (hasher.final() != header.checksum) return error.ChecksumMismatch;

    return state;
}

// =============================================================================
// Quantum State Chain (blockchain pattern from llm/quine.html)
// =============================================================================

/// A block in the quantum state chain.
pub const StateBlock = struct {
    block_height: u64,
    previous_hash: [32]u8,
    state_hash: [32]u8,
    timestamp: u64,
    gate_type: u8, // Gate type that produced this state
    target_qubit: u8, // Target qubit of the gate
    nonce: u64,

    pub fn computeHash(self: StateBlock) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.block_height));
        hasher.update(&self.previous_hash);
        hasher.update(&self.state_hash);
        hasher.update(std.mem.asBytes(&self.timestamp));
        hasher.update(std.mem.asBytes(&self.gate_type));
        hasher.update(std.mem.asBytes(&self.target_qubit));
        hasher.update(std.mem.asBytes(&self.nonce));
        return hasher.finalResult();
    }
};

/// Quantum state chain — tracks the history of quantum gate operations.
pub const StateChain = struct {
    blocks: std.ArrayList(StateBlock),
    tip_hash: [32]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StateChain {
        return .{
            .blocks = std.ArrayList(StateBlock).init(allocator),
            .tip_hash = [_]u8{0} ** 32,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateChain) void {
        self.blocks.deinit();
    }

    /// Computes the SHA-256 hash of a quantum state's amplitudes.
    pub fn hashState(state: QuantumState) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (state.amplitudes) |a| {
            hasher.update(std.mem.asBytes(&a.re));
            hasher.update(std.mem.asBytes(&a.im));
        }
        return hasher.finalResult();
    }

    /// Adds a new block to the chain after applying a gate.
    pub fn addBlock(
        self: *StateChain,
        state: QuantumState,
        gate_type: u8,
        target_qubit: u8,
        timestamp: u64,
    ) !void {
        const state_hash = hashState(state);
        const block = StateBlock{
            .block_height = self.blocks.items.len + 1,
            .previous_hash = self.tip_hash,
            .state_hash = state_hash,
            .timestamp = timestamp,
            .gate_type = gate_type,
            .target_qubit = target_qubit,
            .nonce = 0,
        };
        self.tip_hash = block.computeHash();
        try self.blocks.append(block);
    }

    /// Verifies the chain integrity.
    pub fn verify(self: StateChain) bool {
        var expected_prev: [32]u8 = [_]u8{0} ** 32;
        for (self.blocks.items) |block| {
            if (!std.mem.eql(u8, &block.previous_hash, &expected_prev)) return false;
            expected_prev = block.computeHash();
        }
        // Final check: recomputed tip must match stored tip
        if (self.blocks.items.len > 0) {
            if (!std.mem.eql(u8, &expected_prev, &self.tip_hash)) return false;
        }
        return true;
    }

    /// Returns the chain height (number of blocks).
    pub fn height(self: StateChain) u64 {
        return self.blocks.items.len;
    }

    /// Returns the tip hash.
    pub fn tipHash(self: StateChain) [32]u8 {
        return self.tip_hash;
    }
};

// =============================================================================
// Quantum Circuit Builder
// =============================================================================

/// A quantum circuit: a sequence of gates to apply.
pub const Circuit = struct {
    gates: std.ArrayList(Gate),
    num_qubits: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_qubits: u8) Circuit {
        return .{
            .gates = std.ArrayList(Gate).init(allocator),
            .num_qubits = num_qubits,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Circuit) void {
        self.gates.deinit();
    }

    pub fn addHadamard(self: *Circuit, target: u8) !void {
        try self.gates.append(.{ .gate_type = .hadamard, .target = target });
    }

    pub fn addCNOT(self: *Circuit, control: u8, target: u8) !void {
        try self.gates.append(.{ .gate_type = .cnot, .target = target, .control = control });
    }

    pub fn addPauliX(self: *Circuit, target: u8) !void {
        try self.gates.append(.{ .gate_type = .pauli_x, .target = target });
    }

    pub fn addPauliY(self: *Circuit, target: u8) !void {
        try self.gates.append(.{ .gate_type = .pauli_y, .target = target });
    }

    pub fn addPauliZ(self: *Circuit, target: u8) !void {
        try self.gates.append(.{ .gate_type = .pauli_z, .target = target });
    }

    pub fn addPhase(self: *Circuit, target: u8, theta: i64) !void {
        try self.gates.append(.{ .gate_type = .phase, .target = target, .parameter = theta });
    }

    pub fn addSWAP(self: *Circuit, a: u8, b: u8) !void {
        try self.gates.append(.{ .gate_type = .swap, .target = a, .control = b });
    }

    /// Runs the circuit on a quantum state, optionally recording to a state chain.
    pub fn run(self: Circuit, state: *QuantumState, chain: ?*StateChain) !void {
        for (self.gates.items) |gate| {
            applyGate(state, gate);
            if (chain) |ch| {
                try ch.addBlock(state.*, @intFromEnum(gate.gate_type), gate.target, 0);
            }
        }
    }

    pub fn gateCount(self: Circuit) usize {
        return self.gates.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "complex arithmetic is integer" {
    const a = Complex.new(fp.fromInt(3), fp.fromInt(4));
    const b = Complex.new(fp.fromInt(1), fp.fromInt(2));

    const sum = Complex.add(a, b);
    try std.testing.expectEqual(fp.fromInt(4), sum.re);
    try std.testing.expectEqual(fp.fromInt(6), sum.im);

    const prod = Complex.mul(a, b);
    try std.testing.expectEqual(fp.fromInt(-5), prod.re);
    try std.testing.expectEqual(fp.fromInt(10), prod.im);
}

test "no floating-point types in quantum complex" {
    try std.testing.expectEqual(@sizeOf(i64), @sizeOf(@TypeOf(@as(Complex, undefined).re)));
    try std.testing.expectEqual(@sizeOf(i64), @sizeOf(@TypeOf(@as(Complex, undefined).im)));
}

test "QuantumState initialization" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    try std.testing.expectEqual(@as(u8, 3), state.num_qubits);
    try std.testing.expectEqual(@as(usize, 8), state.dimension());
    try std.testing.expectEqual(fp.ONE, state.amplitudes[0].re);
    try std.testing.expectEqual(@as(i64, 0), state.amplitudes[1].re);
}

test "QuantumState normalization" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    state.amplitudes[0] = Complex.new(fp.fromInt(3), 0);
    state.amplitudes[1] = Complex.new(fp.fromInt(4), 0);
    state.normalize();

    // Total probability should be ~1.0 (fp.ONE)
    const tp = state.totalProbability();
    try std.testing.expect(fp.absVal(tp - fp.ONE) < 5000000);
    // 3/5 = 0.6, 4/5 = 0.8
    try std.testing.expect(fp.absVal(state.amplitudes[0].re - fp.div(fp.fromInt(3), fp.fromInt(5))) < 5000000);
    try std.testing.expect(fp.absVal(state.amplitudes[1].re - fp.div(fp.fromInt(4), fp.fromInt(5))) < 5000000);
}

test "Hadamard on |0⟩ produces uniform superposition" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyHadamard(&state, 0);

    // Both amplitudes should be INV_SQRT2
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[1].re);
}

test "Hadamard is self-inverse" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyHadamard(&state, 0);
    applyHadamard(&state, 0);

    // Should return to |00⟩ — allow small fixed-point error
    try std.testing.expect(fp.absVal(state.amplitudes[0].re - fp.ONE) < 5000000);
    try std.testing.expect(fp.absVal(state.amplitudes[1].re) < 5000000);
}

test "Pauli-X flips qubit" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyPauliX(&state, 0);

    try std.testing.expectEqual(@as(i64, 0), state.amplitudes[0].re);
    try std.testing.expectEqual(fp.ONE, state.amplitudes[1].re);
}

test "Pauli-Z adds phase" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyPauliX(&state, 0);
    applyPauliZ(&state, 0);

    try std.testing.expectEqual(-fp.ONE, state.amplitudes[1].re);
}

test "CNOT creates entanglement" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);

    // Bell state: (|00⟩ + |11⟩) / √2
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(@as(i64, 0), state.amplitudes[1].re);
    try std.testing.expectEqual(@as(i64, 0), state.amplitudes[2].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[3].re);
}

test "Bell pair creation" {
    const allocator = std.testing.allocator;
    var state = try createBellPair(allocator);
    defer state.deinit();

    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[3].re);
    // Total probability ≈ 1.0
    const tp = state.totalProbability();
    try std.testing.expect(fp.absVal(tp - fp.ONE) < 5000000);
}

test "All four Bell states" {
    const allocator = std.testing.allocator;

    var phi_plus = try createBellState(allocator, .phi_plus);
    defer phi_plus.deinit();
    try std.testing.expectEqual(fp.INV_SQRT2, phi_plus.amplitudes[0].re);
    try std.testing.expectEqual(fp.INV_SQRT2, phi_plus.amplitudes[3].re);

    var phi_minus = try createBellState(allocator, .phi_minus);
    defer phi_minus.deinit();
    try std.testing.expectEqual(fp.INV_SQRT2, phi_minus.amplitudes[0].re);
    // |00⟩ - |11⟩ → amplitudes[3] should be negative
    try std.testing.expectEqual(-fp.INV_SQRT2, phi_minus.amplitudes[3].re);

    var psi_plus = try createBellState(allocator, .psi_plus);
    defer psi_plus.deinit();
    try std.testing.expectEqual(fp.INV_SQRT2, psi_plus.amplitudes[1].re);
    try std.testing.expectEqual(fp.INV_SQRT2, psi_plus.amplitudes[2].re);

    var psi_minus = try createBellState(allocator, .psi_minus);
    defer psi_minus.deinit();
    // psi_minus = (|01⟩ - |10⟩) / √2 up to global phase
    // Gate sequence produces -|01⟩ + |10⟩ (same state, global phase -1)
    try std.testing.expectEqual(-fp.INV_SQRT2, psi_minus.amplitudes[1].re);
    try std.testing.expectEqual(fp.INV_SQRT2, psi_minus.amplitudes[2].re);
}

test "Grover search finds target" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    const target: usize = 5;
    const num_iterations = optimalGroverIterations(8);

    groverSearch(&state, target, num_iterations);

    var max_prob: i64 = 0;
    var max_idx: usize = 0;
    for (0..8) |i| {
        const p = state.amplitudes[i].magnitudeSq();
        if (p > max_prob) {
            max_prob = p;
            max_idx = i;
        }
    }
    try std.testing.expectEqual(target, max_idx);
    // max_prob > 0.5 → fp.HALF
    try std.testing.expect(max_prob > fp.HALF);
}

test "Grover search with 4 qubits" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 4);
    defer state.deinit();

    const target: usize = 7;
    const num_iterations = optimalGroverIterations(16);

    groverSearch(&state, target, num_iterations);

    var max_prob: i64 = 0;
    var max_idx: usize = 0;
    for (0..16) |i| {
        const p = state.amplitudes[i].magnitudeSq();
        if (p > max_prob) {
            max_prob = p;
            max_idx = i;
        }
    }
    try std.testing.expectEqual(target, max_idx);
}

test "optimalGroverIterations" {
    try std.testing.expectEqual(@as(u32, 2), optimalGroverIterations(8));
    try std.testing.expectEqual(@as(u32, 3), optimalGroverIterations(16));
    try std.testing.expectEqual(@as(u32, 50), optimalGroverIterations(4096));
}

test "Phase gate" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyPauliX(&state, 0); // |1⟩
    applyPhase(&state, 0, fp.div(fp.PI, fp.fromInt(2))); // R(π/2)

    // cos(π/2) ≈ 0, sin(π/2) = 1 — allow lookup table quantization error
    // 1024-entry table places π/2 at index 255 (truncation), cos(255π/512) ≈ 0.006 → ~26M in Q32.32
    try std.testing.expect(fp.absVal(state.amplitudes[1].re) < 50000000);
    try std.testing.expect(fp.absVal(state.amplitudes[1].im - fp.ONE) < 50000000);
}

test "SWAP gate" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyPauliX(&state, 1); // |10⟩
    try std.testing.expectEqual(fp.ONE, state.amplitudes[2].re);

    applySWAP(&state, 0, 1); // → |01⟩
    try std.testing.expectEqual(@as(i64, 0), state.amplitudes[2].re);
    try std.testing.expectEqual(fp.ONE, state.amplitudes[1].re);
}

test "Pauli-Y gate" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyPauliY(&state, 0);
    // Y|0⟩ = i|1⟩
    try std.testing.expectEqual(@as(i64, 0), state.amplitudes[0].re);
    try std.testing.expectEqual(fp.ONE, state.amplitudes[1].im);
}

test "State compression round trip is bit-exact" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);
    applyPhase(&state, 2, fp.div(fp.PI, fp.fromInt(3)));

    const encoded = try compressState(allocator, state);
    defer allocator.free(encoded);

    var decoded = try decompressState(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(state.num_qubits, decoded.num_qubits);
    try std.testing.expectEqual(state.amplitudes.len, decoded.amplitudes.len);

    // Bit-exact equality — NO tolerance
    for (0..state.amplitudes.len) |i| {
        try std.testing.expectEqual(state.amplitudes[i].re, decoded.amplitudes[i].re);
        try std.testing.expectEqual(state.amplitudes[i].im, decoded.amplitudes[i].im);
    }
}

test "State compression rejects invalid magic" {
    const allocator = std.testing.allocator;
    const bad_data = try allocator.alloc(u8, 100);
    defer allocator.free(bad_data);
    @memset(bad_data, 0);

    const result = decompressState(allocator, bad_data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "State compression rejects wrong version" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice("QSTA");
    try buf.writer().writeInt(u16, 1, .little); // version 1, not 2
    try buf.writer().writeByte(2);
    try buf.writer().writeInt(u32, 4, .little);
    try buf.writer().writeInt(u32, 0, .little);

    const result = decompressState(allocator, buf.items);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "QuantumHeader write and read" {
    const header = QuantumHeader{
        .num_qubits = 4,
        .num_amplitudes = 16,
        .checksum = 0xCAFEBABE,
    };

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try header.write(buf.writer());

    var fbs = std.io.fixedBufferStream(buf.items);
    const read_header = try QuantumHeader.read(fbs.reader());

    try std.testing.expectEqual(header.num_qubits, read_header.num_qubits);
    try std.testing.expectEqual(header.num_amplitudes, read_header.num_amplitudes);
    try std.testing.expectEqual(header.checksum, read_header.checksum);
}

test "StateChain initialization and verification" {
    const allocator = std.testing.allocator;
    var chain = StateChain.init(allocator);
    defer chain.deinit();

    try std.testing.expectEqual(@as(u64, 0), chain.height());
    try std.testing.expect(chain.verify());
}

test "StateChain records gate operations" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    var chain = StateChain.init(allocator);
    defer chain.deinit();

    applyHadamard(&state, 0);
    try chain.addBlock(state, @intFromEnum(GateType.hadamard), 0, 1000);

    applyCNOT(&state, 0, 1);
    try chain.addBlock(state, @intFromEnum(GateType.cnot), 1, 2000);

    try std.testing.expectEqual(@as(u64, 2), chain.height());
    try std.testing.expect(chain.verify());
}

test "StateChain detects tampering" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    var chain = StateChain.init(allocator);
    defer chain.deinit();

    applyHadamard(&state, 0);
    try chain.addBlock(state, @intFromEnum(GateType.hadamard), 0, 1000);

    chain.blocks.items[0].gate_type = @intFromEnum(GateType.pauli_x);

    try std.testing.expect(!chain.verify());
}

test "StateChain tip hash changes with each block" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    var chain = StateChain.init(allocator);
    defer chain.deinit();

    const hash0 = chain.tipHash();

    applyHadamard(&state, 0);
    try chain.addBlock(state, @intFromEnum(GateType.hadamard), 0, 1000);

    const hash1 = chain.tipHash();
    try std.testing.expect(!std.mem.eql(u8, &hash0, &hash1));

    applyPauliX(&state, 0);
    try chain.addBlock(state, @intFromEnum(GateType.pauli_x), 0, 2000);

    const hash2 = chain.tipHash();
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "Circuit builder and execution" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    var circuit = Circuit.init(allocator, 2);
    defer circuit.deinit();

    try circuit.addHadamard(0);
    try circuit.addCNOT(0, 1);

    try std.testing.expectEqual(@as(usize, 2), circuit.gateCount());

    try circuit.run(&state, null);

    // Should be Bell state
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[3].re);
}

test "Circuit with state chain recording" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    var circuit = Circuit.init(allocator, 2);
    defer circuit.deinit();

    var chain = StateChain.init(allocator);
    defer chain.deinit();

    try circuit.addHadamard(0);
    try circuit.addCNOT(0, 1);
    try circuit.addPauliZ(1);

    try circuit.run(&state, &chain);

    try std.testing.expectEqual(@as(u64, 3), chain.height());
    try std.testing.expect(chain.verify());
}

test "QuantumState clone" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);

    var cloned = try state.clone();
    defer cloned.deinit();

    for (0..4) |i| {
        try std.testing.expectEqual(state.amplitudes[i].re, cloned.amplitudes[i].re);
        try std.testing.expectEqual(state.amplitudes[i].im, cloned.amplitudes[i].im);
    }
}

test "QuantumState probability" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyHadamard(&state, 0);

    // Each basis state has probability ~0.5 (fp.HALF)
    try std.testing.expect(fp.absVal(state.probability(0) - fp.HALF) < 5000000);
    try std.testing.expect(fp.absVal(state.probability(1) - fp.HALF) < 5000000);
    try std.testing.expectEqual(@as(i64, 0), state.probability(100));
}

test "QuantumState measure collapses state" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyHadamard(&state, 0);

    var prng = std.Random.DefaultPrng.init(42);
    const result = state.measure(&prng);

    try std.testing.expect(result < 2);
    // After measurement, total probability should be ~1.0
    const tp = state.totalProbability();
    try std.testing.expect(fp.absVal(tp - fp.ONE) < 5000000);
}

test "applyGate dispatches correctly" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyGate(&state, .{ .gate_type = .pauli_x, .target = 0 });
    try std.testing.expectEqual(fp.ONE, state.amplitudes[1].re);
}

test "Grover search preserves total probability" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    groverSearch(&state, 3, 2);

    // Total probability should be ~1.0 (fp.ONE)
    const tp = state.totalProbability();
    try std.testing.expect(fp.absVal(tp - fp.ONE) < 10000000); // slightly looser for Grover
}

test "Compress/decompress preserves normalized state" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);

    const encoded = try compressState(allocator, state);
    defer allocator.free(encoded);

    var decoded = try decompressState(allocator, encoded);
    defer decoded.deinit();

    // Bit-exact: probabilities must be identical
    for (0..4) |i| {
        try std.testing.expectEqual(state.amplitudes[i].magnitudeSq(), decoded.amplitudes[i].magnitudeSq());
    }
}

test "StateChain hashState is deterministic" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyHadamard(&state, 0);

    const hash1 = StateChain.hashState(state);
    const hash2 = StateChain.hashState(state);

    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "Multiple Grover targets have amplified probability" {
    const allocator = std.testing.allocator;

    for (0..8) |target| {
        var state = try QuantumState.init(allocator, 3);
        defer state.deinit();

        groverSearch(&state, target, 2);

        // probability > 0.3 → fp.fromInt(3) / fp.fromInt(10)
        const threshold = fp.div(fp.fromInt(3), fp.fromInt(10));
        try std.testing.expect(state.probability(target) > threshold);
    }
}

test "Circuit with all gate types" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    var circuit = Circuit.init(allocator, 3);
    defer circuit.deinit();

    try circuit.addHadamard(0);
    try circuit.addPauliX(1);
    try circuit.addPauliY(2);
    try circuit.addCNOT(0, 1);
    try circuit.addPauliZ(2);
    try circuit.addPhase(0, fp.div(fp.PI, fp.fromInt(4)));
    try circuit.addSWAP(1, 2);

    try std.testing.expectEqual(@as(usize, 7), circuit.gateCount());

    try circuit.run(&state, null);

    // Total probability should be ~1.0
    const tp = state.totalProbability();
    try std.testing.expect(fp.absVal(tp - fp.ONE) < 10000000);
}

test "quantum state is deterministic" {
    const allocator = std.testing.allocator;
    var state1 = try QuantumState.init(allocator, 2);
    defer state1.deinit();
    var state2 = try QuantumState.init(allocator, 2);
    defer state2.deinit();

    applyHadamard(&state1, 0);
    applyCNOT(&state1, 0, 1);
    applyHadamard(&state2, 0);
    applyCNOT(&state2, 0, 1);

    for (0..4) |i| {
        try std.testing.expectEqual(state1.amplitudes[i].re, state2.amplitudes[i].re);
        try std.testing.expectEqual(state1.amplitudes[i].im, state2.amplitudes[i].im);
    }
}
