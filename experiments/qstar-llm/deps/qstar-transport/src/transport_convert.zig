//! transport_convert.zig — MIME type conversion graph transport.
//!
//! Extracted from convert (#12).
//! Builds an adjacency graph of convertible MIME types and finds shortest paths via BFS.

const std = @import("std");

pub const MimeEntry = struct {
    from: []const u8,
    to: []const u8,
    convert_fn: ConvertFn,
};

pub const ConvertFn = *const fn (allocator: std.mem.Allocator, data: []const u8) anyerror![]u8;

pub const MimeGraph = struct {
    entries: std.ArrayList(MimeEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MimeGraph {
        return .{
            .entries = std.ArrayList(MimeEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MimeGraph) void {
        self.entries.deinit();
    }

    pub fn addEdge(self: *MimeGraph, from: []const u8, to: []const u8, convert_fn: ConvertFn) !void {
        try self.entries.append(.{ .from = from, .to = to, .convert_fn = convert_fn });
    }

    pub fn findPath(self: *MimeGraph, from: []const u8, to: []const u8) !?[]const MimeEntry {
        if (std.mem.eql(u8, from, to)) return &[_]MimeEntry{};

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        var queue = std.ArrayList(struct { mime: []const u8, path: std.ArrayList(MimeEntry) }).init(self.allocator);
        defer {
            for (queue.items) |item| item.path.deinit();
            queue.deinit();
        }

        try visited.put(from, {});
        try queue.append(.{ .mime = from, .path = std.ArrayList(MimeEntry).init(self.allocator) });

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            defer current.path.deinit();

            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.from, current.mime)) {
                    if (std.mem.eql(u8, entry.to, to)) {
                        var result = try self.allocator.alloc(MimeEntry, current.path.items.len + 1);
                        @memcpy(result[0..current.path.items.len], current.path.items);
                        result[current.path.items.len] = entry;
                        return result;
                    }
                    if (!visited.contains(entry.to)) {
                        try visited.put(entry.to, {});
                        var new_path = std.ArrayList(MimeEntry).init(self.allocator);
                        try new_path.appendSlice(current.path.items);
                        try new_path.append(entry);
                        try queue.append(.{ .mime = entry.to, .path = new_path });
                    }
                }
            }
        }
        return null;
    }

    pub fn convert(self: *MimeGraph, allocator: std.mem.Allocator, data: []const u8, from: []const u8, to: []const u8) ![]u8 {
        const path = try self.findPath(from, to) orelse return error.NoConversionPath;
        defer self.allocator.free(path);
        if (path.len == 0) return try allocator.dupe(u8, data);

        var current = try allocator.dupe(u8, data);
        for (path) |entry| {
            const next = try entry.convert_fn(allocator, current);
            allocator.free(current);
            current = next;
        }
        return current;
    }
};

// Built-in conversion functions

fn identityConvert(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return try allocator.dupe(u8, data);
}

fn upperConvert(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, data.len);
    for (data, 0..) |b, i| {
        result[i] = if (b >= 'a' and b <= 'z') b - 32 else b;
    }
    return result;
}

fn lowerConvert(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, data.len);
    for (data, 0..) |b, i| {
        result[i] = if (b >= 'A' and b <= 'Z') b + 32 else b;
    }
    return result;
}

fn base64EncodeConvert(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const Encoder = std.base64.standard.Encoder;
    const len = Encoder.calcSize(data.len);
    const result = try allocator.alloc(u8, len);
    _ = Encoder.encode(result, data);
    return result;
}

fn base64DecodeConvert(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const Decoder = std.base64.standard.Decoder;
    const max_len = try Decoder.calcSizeForSlice(data);
    const result = try allocator.alloc(u8, max_len);
    try Decoder.decode(result, data);
    return result;
}

pub fn defaultGraph(allocator: std.mem.Allocator) !MimeGraph {
    var graph = MimeGraph.init(allocator);
    try graph.addEdge("text/plain", "text/upper", &upperConvert);
    try graph.addEdge("text/upper", "text/plain", &lowerConvert);
    try graph.addEdge("text/plain", "application/base64", &base64EncodeConvert);
    try graph.addEdge("application/base64", "text/plain", &base64DecodeConvert);
    try graph.addEdge("text/upper", "application/base64", &base64EncodeConvert);
    return graph;
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "convert";
}

// Tests

test "convert graph direct path" {
    const allocator = std.testing.allocator;
    var graph = try defaultGraph(allocator);
    defer graph.deinit();

    const result = try graph.convert(allocator, "hello", "text/plain", "text/upper");
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "HELLO", result);
}

test "convert graph multi-hop path" {
    const allocator = std.testing.allocator;
    var graph = try defaultGraph(allocator);
    defer graph.deinit();

    const result = try graph.convert(allocator, "hello", "text/upper", "application/base64");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("aGVsbG8=", result);
}

test "convert graph same type" {
    const allocator = std.testing.allocator;
    var graph = try defaultGraph(allocator);
    defer graph.deinit();

    const result = try graph.convert(allocator, "hello", "text/plain", "text/plain");
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "hello", result);
}

test "convert graph no path" {
    const allocator = std.testing.allocator;
    var graph = try defaultGraph(allocator);
    defer graph.deinit();

    try std.testing.expectError(error.NoConversionPath, graph.convert(allocator, "hello", "text/plain", "image/png"));
}

test "convert base64 round trip" {
    const allocator = std.testing.allocator;
    var graph = try defaultGraph(allocator);
    defer graph.deinit();

    const data = "Hello, Base64!";

    const encoded = try graph.convert(allocator, data, "text/plain", "application/base64");
    defer allocator.free(encoded);

    const decoded = try graph.convert(allocator, encoded, "application/base64", "text/plain");
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "convert name" {
    try std.testing.expectEqualStrings("convert", name());
}
