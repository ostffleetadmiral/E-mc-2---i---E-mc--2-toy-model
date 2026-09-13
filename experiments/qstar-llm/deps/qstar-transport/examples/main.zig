//! Qstar-Transport Example — demonstrates QR encoding, polyglot containers, LoRa packets.

const std = @import("std");
const qr = @import("transport_qr");
const polyglot = @import("transport_polyglot");
const lora = @import("transport_lora");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Transport — Multi-Modal Data Transport\n", .{});
    try stdout.print("==============================================\n\n", .{});

    // QR encoding
    try stdout.print("QR Code Transport:\n", .{});
    const test_data = "HELLO WORLD 1234";
    const encoded = try qr.encode(allocator, test_data);
    defer allocator.free(encoded);
    try stdout.print("  Input: \"{s}\" ({d} bytes)\n", .{ test_data, test_data.len });
    try stdout.print("  Encoded: {d} bytes\n", .{encoded.len});
    const decoded = try qr.decode(allocator, encoded);
    defer allocator.free(decoded);
    try stdout.print("  Decoded: \"{s}\" ({d} bytes)\n", .{ decoded, decoded.len });
    try stdout.print("  Round-trip: {}\n", .{std.mem.eql(u8, test_data, decoded)});

    // Polyglot
    try stdout.print("\nPolyglot Container:\n", .{});
    try stdout.print("  Formats: PNG, ZIP, JAR, PYZ\n", .{});
    const payload = "executable payload data";
    const jar = try polyglot.encode(allocator, payload, .jar);
    defer allocator.free(jar);
    try stdout.print("  JAR encoded: {d} bytes\n", .{jar.len});
    const jar_decoded = try polyglot.decode(allocator, jar, .jar);
    defer allocator.free(jar_decoded);
    try stdout.print("  JAR decoded: \"{s}\"\n", .{jar_decoded});
    try stdout.print("  Round-trip: {}\n", .{std.mem.eql(u8, payload, jar_decoded)});

    // LoRa
    try stdout.print("\nLoRa Radio Transport:\n", .{});
    try stdout.print("  MTU: {d} bytes\n", .{lora.LORA_MTU});
    try stdout.print("  Spreading factors: {d}-{d}\n", .{ lora.SF_MIN, lora.SF_MAX });
    try stdout.print("  CRC16 poly: 0x{X}\n", .{lora.CRC16_POLY});
    try stdout.print("  Default retries: {d}\n", .{lora.DEFAULT_MAX_RETRIES});
    try stdout.print("  ACK timeout: {d}ms\n", .{lora.DEFAULT_ACK_TIMEOUT_MS});

    try stdout.print("\n14 transport modules available. Try: zig build test\n", .{});
}
