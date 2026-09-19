const std = @import("std");

pub const MapleError = error{
    ConnectionFailed,
    BadResponse,
    InvalidHost,
    OutOfMemory,
};

pub const MapleStatus = struct {
    device: []const u8,
    version: []const u8,
    wasm3_ready: bool,
    wasm3_mode: []const u8,
    corpus_sentences: u32,
    corpus_loaded_bytes: u32,
    free_heap: u32,
    hostname: []const u8,
    node_fqdn: []const u8,
    wifi_connected: bool,
    ip: []const u8,
    mesh_nodes: u32,
};

pub const MapleBenchResult = struct {
    prompt: []const u8,
    iterations: u32,
    min_ms: u32,
    max_ms: u32,
    avg_ms: u32,
    total_ms: u32,
    heap_before: u32,
    heap_after: u32,
    heap_delta: i32,
    wasm3_ready: bool,
};

pub const MapleClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) MapleClient {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
        };
    }

    pub fn defaultPort() u16 {
        return 80;
    }

    fn buildUrl(self: *const MapleClient, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ self.host, self.port, path });
    }

    pub fn generate(self: *const MapleClient, prompt: []const u8) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/agent/generate");
        defer self.allocator.free(url);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const payload = try std.fmt.allocPrint(self.allocator, "prompt={s}", .{prompt});
        defer self.allocator.free(payload);

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            },
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn getStatus(self: *const MapleClient) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/agent");
        defer self.allocator.free(url);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn runBench(self: *const MapleClient, prompt: []const u8, iterations: u32) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/bench");
        defer self.allocator.free(url);

        const payload = try std.fmt.allocPrint(self.allocator, "prompt={s}&iterations={d}", .{ prompt, iterations });
        defer self.allocator.free(payload);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            },
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn getMeshNodes(self: *const MapleClient) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/mesh/nodes");
        defer self.allocator.free(url);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn getMeshTopology(self: *const MapleClient) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/mesh/topology");
        defer self.allocator.free(url);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn registerMeshNode(self: *const MapleClient, node_name: []const u8, node_ip: []const u8) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/mesh/register");
        defer self.allocator.free(url);

        const payload = try std.fmt.allocPrint(self.allocator, "name={s}&ip={s}", .{ node_name, node_ip });
        defer self.allocator.free(payload);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            },
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn pushCorpusFile(self: *const MapleClient, file_path: []const u8, remote_name: []const u8) ![]u8 {
        const file_data = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 512 * 1024);
        defer self.allocator.free(file_data);

        const boundary = "----QstarHeartbeatBoundary";
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        const header = try std.fmt.allocPrint(
            self.allocator,
            "--{s}\r\nContent-Disposition: form-data; name=\"update\"; filename=\"/{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
            .{ boundary, remote_name },
        );
        defer self.allocator.free(header);
        try body.appendSlice(header);
        try body.appendSlice(file_data);

        const footer = try std.fmt.allocPrint(self.allocator, "\r\n--{s}--\r\n", .{boundary});
        defer self.allocator.free(footer);
        try body.appendSlice(footer);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/upload");
        defer self.allocator.free(url);

        const content_type = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(content_type);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body.items,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = content_type },
            },
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn triggerCorpusScan(self: *const MapleClient) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try self.buildUrl(self.allocator, "/api/corpus/scan");
        defer self.allocator.free(url);

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .response_storage = .{ .dynamic = &response_body },
        }) catch return MapleError.ConnectionFailed;

        if (result.status != .ok) return MapleError.BadResponse;

        return response_body.toOwnedSlice();
    }

    pub fn corpusStatus(self: *const MapleClient) ![]u8 {
        return self.getStatus();
    }
};

test "maple client init" {
    const client = MapleClient.init(std.testing.allocator, "qstar001.qstar", 80);
    try std.testing.expectEqualStrings("qstar001.qstar", client.host);
    try std.testing.expectEqual(@as(u16, 80), client.port);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
