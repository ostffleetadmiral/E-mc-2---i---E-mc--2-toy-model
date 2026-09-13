//! Qstar-Mesh Example — connection management, peer discovery, location routing.

const std = @import("std");
const mesh = @import("mesh");
const p2p = @import("p2p_types");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Mesh — P2P Mesh Networking Stack\n", .{});
    try stdout.print("========================================\n\n", .{});

    // Location
    try stdout.print("Location:\n", .{});
    const loc_a = mesh.Location.new(42.0);
    const loc_b = mesh.Location.new(37.5);
    try stdout.print("  Location A: {d:.4}\n", .{loc_a.value});
    try stdout.print("  Location B: {d:.4}\n", .{loc_b.value});
    try stdout.print("  Distance: {d:.4}\n", .{loc_a.distance(loc_b)});

    // Connection Manager
    try stdout.print("\nConnection Manager:\n", .{});
    try stdout.print("  Min connections: {d}\n", .{mesh.DEFAULT_MIN_CONNECTIONS});
    try stdout.print("  Max connections: {d}\n", .{mesh.DEFAULT_MAX_CONNECTIONS});
    try stdout.print("  Overmax slack: {d}\n", .{mesh.LATTICE_OVERMAX_SLACK});

    var cm = mesh.ConnectionManager.init(allocator, loc_a, 5, 20, false);
    defer cm.deinit();
    try stdout.print("  Connection count: {d}\n", .{cm.connectionCount()});
    try stdout.print("  Below min: {}\n", .{cm.isBelowMin()});
    try stdout.print("  At max: {}\n", .{cm.isAtMax()});

    // P2P Types
    try stdout.print("\nP2P Types:\n", .{});
    try stdout.print("  PeerId: {d} bytes\n", .{@sizeOf(p2p.PeerId)});
    try stdout.print("  Location: {d} bytes (u128)\n", .{@sizeOf(p2p.Location)});

    var pm = p2p.PeerManager.init(allocator);
    defer pm.deinit();
    try stdout.print("  PeerManager initialized\n", .{});
    try stdout.print("  Peer count: {d}\n", .{pm.allPeers().len});

    // Connection states
    try stdout.print("\nConnection States:\n", .{});
    for (std.enums.values(mesh.ConnectionState)) |state| {
        try stdout.print("  {s}\n", .{@tagName(state)});
    }

    try stdout.print("\nModules: mesh, p2p_types, relay_router, mesh_peer\n", .{});
    try stdout.print("\nDone.\n", .{});
}
