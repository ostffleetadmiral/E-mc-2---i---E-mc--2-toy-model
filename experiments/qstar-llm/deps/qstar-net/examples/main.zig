//! Qstar-Net Example — NAT traversal, WebRTC, bootstrap, Sybil resistance, merge.

const std = @import("std");
const nat = @import("nat");
const webrtc = @import("webrtc");
const bootstrap = @import("bootstrap");
const sybil = @import("sybil");
const merge = @import("merge");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Net — P2P Connectivity Toolkit\n", .{});
    try stdout.print("====================================\n\n", .{});

    // NAT type detection
    try stdout.print("NAT Traversal:\n", .{});
    for (std.enums.values(nat.NATType)) |t| {
        try stdout.print("  {s}: hole-punch={}\n", .{ t.toString(), t.canHolePunch() });
    }

    // Bootstrap
    try stdout.print("\nBootstrap:\n", .{});
    const seed = bootstrap.BootstrapSeed.canonical();
    try stdout.print("  Seed nodes: {d}\n", .{bootstrap.SEED_NODE_COUNT});
    try stdout.print("  Valid: {}\n", .{seed.validate()});
    const seed_bytes = try seed.serialize(allocator);
    defer allocator.free(seed_bytes);
    try stdout.print("  Serialized: {d} bytes\n", .{seed_bytes.len});

    // Sybil resistance
    try stdout.print("\nSybil Resistance (Proof of Lattice Work):\n", .{});
    var rng = std.Random.DefaultPrng.init(42);
    const challenge = sybil.Challenge.random(&rng, 8, 1000);
    try stdout.print("  Challenge difficulty: {d}\n", .{challenge.difficulty});
    const proof = sybil.solveChallenge(challenge);
    if (proof) |p| {
        try stdout.print("  Solved! Nonce: {d}\n", .{p.nonce});
    } else {
        try stdout.print("  Not solved (difficulty too high for demo)\n", .{});
    }

    // Merge
    try stdout.print("\nMöbius Merge:\n", .{});
    var ms = merge.MergeSet.init(allocator, .last_write_wins);
    defer ms.deinit();
    try stdout.print("  Strategy: last-write-wins\n", .{});
    try stdout.print("  Face cells per merge: {d}\n", .{merge.FACE_CELLS});

    // WebRTC
    try stdout.print("\nWebRTC:\n", .{});
    try stdout.print("  Max SDP length: {d}\n", .{webrtc.SDP_MAX_LEN});
    try stdout.print("  Max channel payload: {d}\n", .{webrtc.CHANNEL_MAX_PAYLOAD});
    try stdout.print("  DTLS fingerprint size: {d}\n", .{webrtc.DTLS_FINGERPRINT_SIZE});

    try stdout.print("\nDone.\n", .{});
}
