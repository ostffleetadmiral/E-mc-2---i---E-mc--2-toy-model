//! Qstar-Quantum Example — quantum gates, Grover search, Bell states.

const std = @import("std");
const quantum = @import("quantum");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Quantum — Quantum Computing Simulation\n", .{});
    try stdout.print("=============================================\n\n", .{});

    try stdout.print("Max qubits: {d}\n", .{quantum.MAX_QUBITS});
    try stdout.print("E0 nodes: {d}\n", .{quantum.E0_NODE_COUNT});
    try stdout.print("Channels: {d}\n\n", .{quantum.CHANNEL_COUNT});

    // Create a 2-qubit state
    var state = try quantum.QuantumState.init(allocator, 2);
    defer state.deinit();
    try stdout.print("Initial state: {d} qubits, {d} amplitudes\n", .{ 2, state.amplitudes.len });

    // Apply Hadamard to qubit 0 (creates superposition)
    quantum.applyHadamard(&state, 0);
    try stdout.print("\nAfter Hadamard on qubit 0:\n", .{});
    try stdout.print("  Total probability: {d}\n", .{state.totalProbability()});

    // Apply CNOT (creates Bell state)
    quantum.applyCNOT(&state, 0, 1);
    try stdout.print("\nAfter CNOT(0, 1) — Bell state:\n", .{});
    try stdout.print("  Total probability: {d}\n", .{state.totalProbability()});

    // Measure
    var rng = std.Random.DefaultPrng.init(42);
    const result = state.measure(&rng);
    try stdout.print("\nMeasurement result: |{d:0>2}>\n", .{result});

    // Grover search demo
    try stdout.print("\nGrover Search:\n", .{});
    var grover_state = try quantum.QuantumState.init(allocator, 3);
    defer grover_state.deinit();

    // Apply Hadamard to all qubits (uniform superposition)
    for (0..3) |q| {
        quantum.applyHadamard(&grover_state, @intCast(q));
    }
    try stdout.print("  3-qubit uniform superposition created\n", .{});
    try stdout.print("  Search space: {d} states\n", .{grover_state.amplitudes.len});

    try stdout.print("\nDone. Also available: entangle.zig (Reed-Solomon, Shamir, DLCZ), holographic.zig (3D DFT, RF fingerprint)\n", .{});
}
