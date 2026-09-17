//! llama_server.zig — HTTP client for llama.cpp's llama-server.
//!
//! llama-server provides an OpenAI-compatible API at /v1/chat/completions.
//! This module wraps that endpoint for use as a streaming fallback when the
//! lattice engine has low confidence.
//!
//! Usage:
//!   1. Start llama-server: ./llama-server -m qwen3-9b.gguf --port 8080 -ngl 99
//!   2. Create LlamaServerConfig with host/port
//!   3. Call generate() with a prompt
//!   4. The agent routes to this when lattice confidence < threshold

const std = @import("std");

pub const LlamaServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    model: []const u8 = "qwen3-9b",
    temperature: f64 = 0.7,
    max_tokens: u32 = 512,
    timeout_ms: u32 = 30_000,

    pub fn fromEnv(allocator: std.mem.Allocator, base: LlamaServerConfig) LlamaServerConfig {
        var config = base;
        if (std.posix.getenv("LLAMA_SERVER_HOST")) |host| {
            config.host = allocator.dupe(u8, host) catch base.host;
        }
        if (std.posix.getenv("LLAMA_SERVER_PORT")) |port_str| {
            config.port = std.fmt.parseInt(u16, port_str, 10) catch base.port;
        }
        if (std.posix.getenv("LLAMA_SERVER_MODEL")) |model| {
            config.model = allocator.dupe(u8, model) catch base.model;
        }
        return config;
    }
};

pub const LlamaServerResponse = struct {
    text: []u8,
    allocator: std.mem.Allocator,
    finish_reason: []const u8 = "stop",
    usage_prompt_tokens: u32 = 0,
    usage_completion_tokens: u32 = 0,

    pub fn deinit(self: *LlamaServerResponse) void {
        self.allocator.free(self.text);
    }
};

/// Checks if llama-server is reachable by attempting a TCP connection.
pub fn isAvailable(config: LlamaServerConfig) bool {
    const addr = std.net.Address.parseIp4(config.host, config.port) catch return false;
    var stream = std.net.tcpConnectToAddress(addr) catch return false;
    stream.close();
    return true;
}

/// Generates a response using llama-server's OpenAI-compatible endpoint.
pub fn generate(
    allocator: std.mem.Allocator,
    config: LlamaServerConfig,
    system_prompt: []const u8,
    user_prompt: []const u8,
) !LlamaServerResponse {
    const addr = try std.net.Address.parseIp4(config.host, config.port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    // Build OpenAI-compatible chat completion request
    const payload = try buildChatPayload(allocator, config, system_prompt, user_prompt);
    defer allocator.free(payload);

    // Build HTTP request
    const http_request = try buildHttpRequest(allocator, config, payload);
    defer allocator.free(http_request);

    // Send request
    _ = try stream.writeAll(http_request);

    // Read response
    var response_buf = std.ArrayList(u8).init(allocator);
    defer response_buf.deinit();
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&read_buf) catch break;
        if (n == 0) break;
        try response_buf.appendSlice(read_buf[0..n]);
        if (response_buf.items.len > 1024 * 1024) break; // 1MB limit
    }

    // Parse HTTP response (skip headers, find body)
    const body = findJsonBody(response_buf.items) orelse return error.InvalidResponse;

    // Extract text from JSON response
    const text = try extractContent(allocator, body);
    return .{
        .text = text,
        .allocator = allocator,
    };
}

/// Generates a response with streaming (Server-Sent Events).
/// Returns the full text after streaming completes.
pub fn generateStreaming(
    allocator: std.mem.Allocator,
    config: LlamaServerConfig,
    system_prompt: []const u8,
    user_prompt: []const u8,
) !LlamaServerResponse {
    const addr = try std.net.Address.parseIp4(config.host, config.port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    // Build streaming chat completion request
    const payload = try buildChatPayloadStreaming(allocator, config, system_prompt, user_prompt);
    defer allocator.free(payload);

    const http_request = try buildHttpRequest(allocator, config, payload);
    defer allocator.free(http_request);

    _ = try stream.writeAll(http_request);

    // Read SSE stream and accumulate content
    var full_text = std.ArrayList(u8).init(allocator);
    errdefer full_text.deinit();
    var read_buf: [4096]u8 = undefined;
    var line_buf = std.ArrayList(u8).init(allocator);
    defer line_buf.deinit();

    while (true) {
        const n = stream.read(&read_buf) catch break;
        if (n == 0) break;

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                if (line_buf.items.len > 0) {
                    if (std.mem.startsWith(u8, line_buf.items, "data: ")) {
                        const data = line_buf.items[6..];
                        if (std.mem.eql(u8, std.mem.trim(u8, data, " \r"), "[DONE]")) {
                            break;
                        }
                        // Extract content delta from SSE data
                        if (extractDeltaContent(allocator, data)) |delta| {
                            defer allocator.free(delta);
                            try full_text.appendSlice(delta);
                        } else |_| {}
                    }
                    line_buf.clearRetainingCapacity();
                }
            } else {
                try line_buf.append(byte);
            }
        }
    }

    return .{
        .text = try full_text.toOwnedSlice(),
        .allocator = allocator,
    };
}

// =============================================================================
// Internal helpers
// =============================================================================

fn buildChatPayload(
    allocator: std.mem.Allocator,
    config: LlamaServerConfig,
    system_prompt: []const u8,
    user_prompt: []const u8,
) ![]u8 {
    // Escape JSON strings
    const sys_escaped = try escapeJsonString(allocator, system_prompt);
    defer allocator.free(sys_escaped);
    const user_escaped = try escapeJsonString(allocator, user_prompt);
    defer allocator.free(user_escaped);

    return try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}],"temperature":{d},"max_tokens":{d},"stream":false}}
    , .{ config.model, sys_escaped, user_escaped, config.temperature, config.max_tokens });
}

fn buildChatPayloadStreaming(
    allocator: std.mem.Allocator,
    config: LlamaServerConfig,
    system_prompt: []const u8,
    user_prompt: []const u8,
) ![]u8 {
    const sys_escaped = try escapeJsonString(allocator, system_prompt);
    defer allocator.free(sys_escaped);
    const user_escaped = try escapeJsonString(allocator, user_prompt);
    defer allocator.free(user_escaped);

    return try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}],"temperature":{d},"max_tokens":{d},"stream":true}}
    , .{ config.model, sys_escaped, user_escaped, config.temperature, config.max_tokens });
}

fn buildHttpRequest(
    allocator: std.mem.Allocator,
    config: LlamaServerConfig,
    payload: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(allocator, "POST /v1/chat/completions HTTP/1.1\r\n" ++
        "Host: {s}:{d}\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}", .{ config.host, config.port, payload.len, payload });
}

fn findJsonBody(response: []const u8) ?[]const u8 {
    // Find the end of HTTP headers (double CRLF)
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return null;
    return response[header_end + 4 ..];
}

fn extractContent(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // Find "content" field in the JSON response
    const content_key = "\"content\":\"";
    const start = std.mem.indexOf(u8, json, content_key) orelse {
        // Try with escaped quotes or different format
        const content_key2 = "\"content\": \"";
        const start2 = std.mem.indexOf(u8, json, content_key2) orelse return error.NoContent;
        const content_start = start2 + content_key2.len;
        return try extractJsonString(allocator, json, content_start);
    };
    const content_start = start + content_key.len;
    return try extractJsonString(allocator, json, content_start);
}

fn extractDeltaContent(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // SSE streaming format: {"choices":[{"delta":{"content":"..."}}]}
    const delta_key = "\"content\":\"";
    const start = std.mem.indexOf(u8, json, delta_key) orelse return error.NoContent;
    const content_start = start + delta_key.len;
    return try extractJsonString(allocator, json, content_start);
}

fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, start: usize) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i = start;
    while (i < json.len) {
        if (json[i] == '\\' and i + 1 < json.len) {
            switch (json[i + 1]) {
                'n' => {
                    try result.append('\n');
                    i += 2;
                },
                't' => {
                    try result.append('\t');
                    i += 2;
                },
                'r' => {
                    try result.append('\r');
                    i += 2;
                },
                '"' => {
                    try result.append('"');
                    i += 2;
                },
                '\\' => {
                    try result.append('\\');
                    i += 2;
                },
                '/' => {
                    try result.append('/');
                    i += 2;
                },
                'u' => {
                    // Unicode escape: \uXXXX (6 chars total)
                    if (i + 5 < json.len) {
                        const hex = json[i + 2 .. i + 6];
                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch {
                            try result.append(json[i]);
                            i += 1;
                            continue;
                        };
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                            try result.append(json[i]);
                            i += 1;
                            continue;
                        };
                        try result.appendSlice(utf8_buf[0..len]);
                        i += 6; // Skip all 6 chars of \uXXXX
                    } else {
                        try result.append(json[i]);
                        i += 1;
                    }
                },
                else => {
                    try result.append(json[i + 1]);
                    i += 2;
                },
            }
        } else if (json[i] == '"') {
            break;
        } else {
            try result.append(json[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice();
}

fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => {
                if (c < 0x20) {
                    var hex_buf: [7]u8 = undefined;
                    const hex_str = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try result.appendSlice(hex_str);
                } else {
                    try result.append(c);
                }
            },
        }
    }

    return try result.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "llama_server: config defaults" {
    const config = LlamaServerConfig{};
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqualStrings("qwen3-9b", config.model);
    try std.testing.expectEqual(@as(f64, 0.7), config.temperature);
    try std.testing.expectEqual(@as(u32, 512), config.max_tokens);
}

test "llama_server: build chat payload" {
    const allocator = std.testing.allocator;
    const config = LlamaServerConfig{ .model = "test-model", .temperature = 0.5, .max_tokens = 128 };
    const payload = try buildChatPayload(allocator, config, "You are helpful.", "Hello!");
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "You are helpful.") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Hello!") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":false") != null);
}

test "llama_server: build streaming payload" {
    const allocator = std.testing.allocator;
    const config = LlamaServerConfig{};
    const payload = try buildChatPayloadStreaming(allocator, config, "System", "User");
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
}

test "llama_server: build HTTP request" {
    const allocator = std.testing.allocator;
    const config = LlamaServerConfig{ .host = "localhost", .port = 9999 };
    const payload = try buildChatPayload(allocator, config, "sys", "user");
    defer allocator.free(payload);
    const http_req = try buildHttpRequest(allocator, config, payload);
    defer allocator.free(http_req);

    try std.testing.expect(std.mem.startsWith(u8, http_req, "POST /v1/chat/completions HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, http_req, "Host: localhost:9999") != null);
    try std.testing.expect(std.mem.indexOf(u8, http_req, "Content-Type: application/json") != null);
}

test "llama_server: find JSON body" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"choices\":[]}";
    const body = findJsonBody(response).?;
    try std.testing.expectEqualStrings("{\"choices\":[]}", body);
}

test "llama_server: find JSON body returns null for no headers" {
    const response = "no headers here";
    try std.testing.expect(findJsonBody(response) == null);
}

test "llama_server: extract content from JSON" {
    const allocator = std.testing.allocator;
    const json = "{\"choices\":[{\"message\":{\"content\":\"Hello, world!\"}}]}";
    const text = try extractContent(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello, world!", text);
}

test "llama_server: extract content with escaped characters" {
    const allocator = std.testing.allocator;
    const json = "{\"content\":\"Hello\\nWorld\\t!\"}";
    const text = try extractContent(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello\nWorld\t!", text);
}

test "llama_server: extract delta content from SSE" {
    const allocator = std.testing.allocator;
    const sse_data = "{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}";
    const text = try extractDeltaContent(allocator, sse_data);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hi", text);
}

test "llama_server: escape JSON string" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsonString(allocator, "Hello\n\"World\"");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Hello\\n\\\"World\\\"", escaped);
}

test "llama_server: extract content with unicode escape" {
    const allocator = std.testing.allocator;
    const json = "{\"content\":\"Hello \\u00e9 World\"}";
    const text = try extractContent(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello é World", text);
}

test "llama_server: isAvailable returns false for unreachable host" {
    const config = LlamaServerConfig{ .host = "127.0.0.1", .port = 59999 };
    try std.testing.expect(!isAvailable(config));
}
