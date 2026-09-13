//! Qstar-Collapse Example — demonstrates cell atomization and QR nesting.

const std = @import("std");
const collapse = @import("collapse");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Collapse — Civilization Collapse Resilience\n", .{});
    try stdout.print("=================================================\n\n", .{});

    // Cell atomization demo
    try stdout.print("Cell Atomization:\n", .{});
    try stdout.print("  Lattice: {d}³ = {d} cells\n", .{ collapse.BASE_EDGE, collapse.CELL_COUNT });
    try stdout.print("  Faces per cell: {d}\n", .{collapse.FACES_PER_CELL});
    try stdout.print("  Total QR portals: {d}\n", .{collapse.TOTAL_FACE_PAYLOADS});
    try stdout.print("  QR payload bytes: {d}\n\n", .{collapse.QR_PAYLOAD_BYTES});

    var atomizer = collapse.CellAtomizer.init(allocator);
    defer atomizer.deinit();

    const test_data = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.";
    try stdout.print("Atomizing {d} bytes of test data...\n", .{test_data.len});
    try atomizer.atomizeCell(0, 0, 0, test_data);

    const valid = atomizer.validateAll();
    try stdout.print("Valid portals after atomization: {d}\n", .{valid});

    var buf: [256]u8 = undefined;
    const recovered = try atomizer.reassembleCell(0, 0, 0, &buf);
    try stdout.print("Recovered {d} bytes: \"{s}\"\n\n", .{ recovered, buf[0..recovered] });

    // QR Nest demo
    try stdout.print("QR Nesting:\n", .{});
    try stdout.print("  Max depth: {d}\n", .{collapse.qr_nest.MAX_DEPTH});
    try stdout.print("  Effective capacity per QR: {d} bytes\n", .{collapse.qr_nest.EFFECTIVE_CAPACITY});

    var tree = collapse.qr_nest.NestTree.init(allocator);
    defer tree.deinit();

    const nest_data = "Data that needs to survive centuries. Encoded in recursive QR codes.";
    try stdout.print("\nNesting {d} bytes of data...\n", .{nest_data.len});
    try tree.build(nest_data);
    try stdout.print("  Nodes: {d}\n", .{tree.nodeCount()});
    try stdout.print("  Leaves: {d}\n", .{tree.leafCount()});

    const extracted = try tree.extract(allocator);
    defer allocator.free(extracted);
    try stdout.print("  Extracted: {d} bytes\n", .{extracted.len});
    try stdout.print("  Round-trip match: {}\n", .{std.mem.eql(u8, nest_data, extracted)});

    // Capacity table
    try stdout.print("\nCapacity by nesting depth:\n", .{});
    var capacity: u64 = collapse.qr_nest.EFFECTIVE_CAPACITY;
    for (1..6) |depth| {
        try stdout.print("  Depth {d}: ~{d} bytes ({d} KB)\n", .{ depth, capacity, capacity / 1024 });
        capacity *= collapse.qr_nest.EFFECTIVE_CAPACITY / 10;
    }
}
