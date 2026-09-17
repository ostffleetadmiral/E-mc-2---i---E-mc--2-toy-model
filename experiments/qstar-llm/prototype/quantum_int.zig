//! quantum_int.zig — Integer-only quantum gate model prototype.
//!
//! Replaces all f64 Complex amplitudes with Q64.64 fixed-point i128.
//! State compression uses exact i128 serialization (no lossy u16 quantization).
//! All gate operations use integer arithmetic with precomputed constants.
//! Bit-exact round-trip: decompressState(compressState(s)) == s.

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

pub const MAX_QUBITS: usize = 20;

// =============================================================================
// Complex Number — Integer Fixed-Point (Q32.32)
// =============================================================================

pub const Complex = struct {
    re: i128,
    im: i128,

    pub fn new(re: i128, im: i128) Complex {
        return .{ .re = re, .im = im };
    }

    pub fn zero() Complex {
        return .{ .re = 0, .im = 0 };
    }

    pub fn one() Complex {
        return .{ .re = fp.ONE, .im = 0 };
    }

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = fp.mul(a.re, b.re) - fp.mul(a.im, b.im),
            .im = fp.mul(a.re, b.im) + fp.mul(a.im, b.re),
        };
    }

    pub fn scale(a: Complex, s: i128) Complex {
        return .{ .re = fp.mul(a.re, s), .im = fp.mul(a.im, s) };
    }

    pub fn conjugate(a: Complex) Complex {
        return .{ .re = a.re, .im = -a.im };
    }

    pub fn magnitudeSq(a: Complex) i128 {
        return fp.mul(a.re, a.re) + fp.mul(a.im, a.im);
    }

    pub fn eql(a: Complex, b: Complex) bool {
        return a.re == b.re and a.im == b.im;
    }
};

// =============================================================================
// Quantum State — Integer Amplitudes
// =============================================================================

pub const QuantumState = struct {
    num_qubits: u8,
    amplitudes: []Complex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_qubits: u8) !QuantumState {
        const n = @as(usize, 1) << @intCast(num_qubits);
        const amplitudes = try allocator.alloc(Complex, n);
        for (amplitudes) |*a| a.* = Complex.zero();
        amplitudes[0] = Complex.one();
        return .{
            .num_qubits = num_qubits,
            .amplitudes = amplitudes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuantumState) void {
        self.allocator.free(self.amplitudes);
    }

    pub fn totalProbability(self: QuantumState) i128 {
        var p: i128 = 0;
        for (self.amplitudes) |a| {
            p += a.magnitudeSq();
        }
        return p;
    }

    pub fn probability(self: QuantumState, basis_idx: usize) i128 {
        if (basis_idx >= self.amplitudes.len) return 0;
        return self.amplitudes[basis_idx].magnitudeSq();
    }
};

// =============================================================================
// Quantum Gates — All Integer Arithmetic
// =============================================================================

pub const GateType = enum {
    hadamard,
    cnot,
    pauli_x,
    pauli_y,
    pauli_z,
    phase,
    swap,
};

pub const Gate = struct {
    gate_type: GateType,
    target: u8,
    control: ?u8 = null,
    parameter: i128 = 0, // Q64.64 phase angle
};

/// Hadamard: H = (1/√2) [[1, 1], [1, -1]]
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
            // (a + b) / √2
            state.amplitudes[i] = Complex.new(
                fp.mul(a.re + b.re, fp.INV_SQRT2),
                fp.mul(a.im + b.im, fp.INV_SQRT2),
            );
            // (a - b) / √2
            state.amplitudes[j] = Complex.new(
                fp.mul(a.re - b.re, fp.INV_SQRT2),
                fp.mul(a.im - b.im, fp.INV_SQRT2),
            );
        }
    }
}

/// CNOT: flip target when control is 1. Pure integer bit manipulation.
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

/// Pauli-X: bit flip. Pure integer swap.
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

/// Pauli-Y: [[0, -i], [i, 0]]
/// i = 0 + 1*i in Q32.32: {re=0, im=ONE}
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

/// Pauli-Z: [[1, 0], [0, -1]]. Scale by -1 = negate.
pub fn applyPauliZ(state: *QuantumState, target: u8) void {
    const size = state.amplitudes.len;
    const target_bit = @as(usize, 1) << @intCast(target);

    for (0..size) |i| {
        if ((i & target_bit) != 0) {
            state.amplitudes[i] = state.amplitudes[i].scale(-fp.ONE);
        }
    }
}

/// Phase gate R(θ): [[1, 0], [0, e^(iθ)]]
/// Uses integer sin/cos lookup tables.
pub fn applyPhase(state: *QuantumState, target: u8, theta: i128) void {
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

/// SWAP gate: swap amplitudes between qubits a and b.
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

pub fn createBellPair(allocator: std.mem.Allocator) !QuantumState {
    var state = try QuantumState.init(allocator, 2);
    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);
    return state;
}

// =============================================================================
// Grover's Search
// =============================================================================

pub fn groverSearch(state: *QuantumState, target_idx: usize, num_iterations: u32) void {
    const n = state.num_qubits;
    const size = state.amplitudes.len;

    // Uniform superposition
    for (0..n) |q| {
        applyHadamard(state, @intCast(q));
    }

    for (0..num_iterations) |_| {
        // Oracle: flip phase of target
        state.amplitudes[target_idx] = state.amplitudes[target_idx].scale(-fp.ONE);

        // Diffusion: H^n, flip all except |0⟩, H^n
        for (0..n) |q| {
            applyHadamard(state, @intCast(q));
        }
        for (0..size) |i| {
            if (i != 0) {
                state.amplitudes[i] = state.amplitudes[i].scale(-fp.ONE);
            }
        }
        for (0..n) |q| {
            applyHadamard(state, @intCast(q));
        }
    }
}

/// Integer square root for Grover iteration count.
/// Returns floor(π/4 × √N) using fixed-point arithmetic.
pub fn optimalGroverIterations(num_items: usize) u32 {
    const n_fp = fp.fromInt(@as(i64, @intCast(num_items)));
    const sqrt_n = fp.sqrt(n_fp);
    // π/4 * √N
    const pi_over_4 = fp.div(fp.PI, fp.fromInt(4));
    const result = fp.mul(pi_over_4, sqrt_n);
    return @intCast(fp.toInt(result));
}

// =============================================================================
// State Compression — Bit-Exact i128 Serialization (NO quantization loss)
// =============================================================================

pub const QuantumHeader = struct {
    magic: [4]u8 = .{ 'Q', 'S', 'T', 'A' },
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
/// Each amplitude (re, im) is stored as raw i128 — NO quantization, NO loss.
/// Round-trip is bit-exact: decompressState(compressState(s)) == s.
pub fn compressState(allocator: std.mem.Allocator, state: QuantumState) ![]u8 {
    const total = state.amplitudes.len;

    // Checksum over raw amplitude bytes
    var hasher = std.hash.Crc32.init();
    for (state.amplitudes) |a| {
        hasher.update(std.mem.asBytes(&a.re));
        hasher.update(std.mem.asBytes(&a.im));
    }
    const checksum = hasher.final();

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const header = QuantumHeader{
        .num_qubits = state.num_qubits,
        .num_amplitudes = @intCast(total),
        .checksum = checksum,
    };
    try header.write(buf.writer());

    // Write raw i128 amplitudes — exact, no quantization
    for (state.amplitudes) |a| {
        try buf.writer().writeInt(i128, a.re, .little);
        try buf.writer().writeInt(i128, a.im, .little);
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
        state.amplitudes[i].re = try fbs.reader().readInt(i128, .little);
        state.amplitudes[i].im = try fbs.reader().readInt(i128, .little);
    }

    // Verify checksum
    var hasher = std.hash.Crc32.init();
    for (state.amplitudes) |a| {
        hasher.update(std.mem.asBytes(&a.re));
        hasher.update(std.mem.asBytes(&a.im));
    }
    if (hasher.final() != header.checksum) return error.ChecksumMismatch;

    return state;
}

// =============================================================================
// Quantum State Chain (SHA-256, same as original — pure integer)
// =============================================================================

pub const StateBlock = struct {
    block_height: u64,
    previous_hash: [32]u8,
    state_hash: [32]u8,
    timestamp: u64,
    gate_type: u8,
    target_qubit: u8,
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

    pub fn hashState(state: QuantumState) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (state.amplitudes) |a| {
            hasher.update(std.mem.asBytes(&a.re));
            hasher.update(std.mem.asBytes(&a.im));
        }
        return hasher.finalResult();
    }

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

    pub fn verify(self: StateChain) bool {
        var expected_prev: [32]u8 = [_]u8{0} ** 32;
        for (self.blocks.items) |block| {
            if (!std.mem.eql(u8, &block.previous_hash, &expected_prev)) return false;
            expected_prev = block.computeHash();
        }
        if (self.blocks.items.len > 0) {
            if (!std.mem.eql(u8, &expected_prev, &self.tip_hash)) return false;
        }
        return true;
    }

    pub fn height(self: StateChain) u64 {
        return self.blocks.items.len;
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

    const product = Complex.mul(a, b);
    // (3+4i)(1+2i) = 3 + 6i + 4i - 8 = -5 + 10i
    try std.testing.expectEqual(fp.fromInt(-5), product.re);
    try std.testing.expectEqual(fp.fromInt(10), product.im);
}

test "hadamard on |0⟩ produces superposition" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyHadamard(&state, 0);

    // |0⟩ → (|0⟩ + |1⟩) / √2
    // Both amplitudes should be INV_SQRT2
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[1].re);
    try std.testing.expectEqual(@as(i128, 0), state.amplitudes[0].im);
    try std.testing.expectEqual(@as(i128, 0), state.amplitudes[1].im);
}

test "bell pair creation" {
    const allocator = std.testing.allocator;
    var state = try createBellPair(allocator);
    defer state.deinit();

    // |Φ+⟩ = (|00⟩ + |11⟩) / √2
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(@as(i128, 0), state.amplitudes[1].re);
    try std.testing.expectEqual(@as(i128, 0), state.amplitudes[2].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[3].re);
}

test "pauli-x flips qubit" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 1);
    defer state.deinit();

    applyPauliX(&state, 0);

    // |0⟩ → |1⟩
    try std.testing.expectEqual(@as(i128, 0), state.amplitudes[0].re);
    try std.testing.expectEqual(fp.ONE, state.amplitudes[1].re);
}

test "cnot creates entanglement" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);

    // Should be Bell state
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[0].re);
    try std.testing.expectEqual(fp.INV_SQRT2, state.amplitudes[3].re);
}

test "state compression round trip is bit-exact" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    // Create non-trivial state
    applyHadamard(&state, 0);
    applyCNOT(&state, 0, 1);
    applyPhase(&state, 2, fp.div(fp.PI, fp.fromInt(3)));

    const encoded = try compressState(allocator, state);
    defer allocator.free(encoded);

    var decoded = try decompressState(allocator, encoded);
    defer decoded.deinit();

    // Bit-exact equality — NO tolerance, NO approximation
    try std.testing.expectEqual(state.num_qubits, decoded.num_qubits);
    try std.testing.expectEqual(state.amplitudes.len, decoded.amplitudes.len);

    for (0..state.amplitudes.len) |i| {
        try std.testing.expectEqual(state.amplitudes[i].re, decoded.amplitudes[i].re);
        try std.testing.expectEqual(state.amplitudes[i].im, decoded.amplitudes[i].im);
    }
}

test "state compression rejects invalid magic" {
    const allocator = std.testing.allocator;
    const bad_data = try allocator.alloc(u8, 100);
    defer allocator.free(bad_data);
    @memset(bad_data, 0);

    const result = decompressState(allocator, bad_data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "state compression rejects wrong version" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    // Write v1 header
    try buf.appendSlice("QSTA");
    try buf.writer().writeInt(u16, 1, .little); // version 1, not 2
    try buf.writer().writeByte(2);
    try buf.writer().writeInt(u32, 4, .little);
    try buf.writer().writeInt(u32, 0, .little);

    const result = decompressState(allocator, buf.items);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "grover search amplifies target" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 3);
    defer state.deinit();

    // Search for state |5⟩
    groverSearch(&state, 5, 2);

    // Target amplitude should be amplified (highest probability)
    const target_prob = state.probability(5);
    for (0..8) |i| {
        if (i != 5) {
            try std.testing.expect(target_prob >= state.probability(i));
        }
    }
}

test "optimal grover iterations" {
    // For N=8 (3 qubits), optimal ≈ π/4 * √8 ≈ 2.22 → 2
    const iter = optimalGroverIterations(8);
    try std.testing.expectEqual(@as(u32, 2), iter);

    // For N=4 (2 qubits), optimal ≈ π/4 * √4 ≈ 1.57 → 1
    const iter4 = optimalGroverIterations(4);
    try std.testing.expectEqual(@as(u32, 1), iter4);
}

test "state chain is verifiable" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    var chain = StateChain.init(allocator);
    defer chain.deinit();

    applyHadamard(&state, 0);
    try chain.addBlock(state, 0, 0, 1000);

    applyCNOT(&state, 0, 1);
    try chain.addBlock(state, 1, 1, 2000);

    try std.testing.expect(chain.verify());
    try std.testing.expectEqual(@as(u64, 2), chain.height());
}

test "state chain detects tampering" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    var chain = StateChain.init(allocator);
    defer chain.deinit();

    applyHadamard(&state, 0);
    try chain.addBlock(state, 0, 0, 1000);

    // Tamper with block
    chain.blocks.items[0].nonce = 999;

    try std.testing.expect(!chain.verify());
}

test "quantum state is deterministic" {
    const allocator = std.testing.allocator;
    var state1 = try QuantumState.init(allocator, 2);
    defer state1.deinit();
    var state2 = try QuantumState.init(allocator, 2);
    defer state2.deinit();

    // Same operations
    applyHadamard(&state1, 0);
    applyCNOT(&state1, 0, 1);
    applyHadamard(&state2, 0);
    applyCNOT(&state2, 0, 1);

    // States must be identical
    for (0..4) |i| {
        try std.testing.expectEqual(state1.amplitudes[i].re, state2.amplitudes[i].re);
        try std.testing.expectEqual(state1.amplitudes[i].im, state2.amplitudes[i].im);
    }
}

test "no floating-point types in quantum state" {
    // Verify at comptime that Complex uses i128, not f64
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(Complex, undefined).re)));
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(Complex, undefined).im)));
}

test "SWAP gate exchanges qubits" {
    const allocator = std.testing.allocator;
    var state = try QuantumState.init(allocator, 2);
    defer state.deinit();

    // Put qubit 0 in |1⟩
    applyPauliX(&state, 0);

    // SWAP qubits 0 and 1
    applySWAP(&state, 0, 1);

    // Now qubit 1 should be |1⟩, qubit 0 should be |0⟩
    // |01⟩ = state index 2 (binary 10)
    try std.testing.expectEqual(fp.ONE, state.amplitudes[2].re);
    try std.testing.expectEqual(@as(i128, 0), state.amplitudes[1].re);
}
