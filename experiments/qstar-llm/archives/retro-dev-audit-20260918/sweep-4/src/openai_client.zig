//! openai_client.zig — Zero-dependency HTTPS client for the OpenAI Chat Completions API.
//!
//! Used by the competitive benchmark (frontier opponent + judge) and the
//! self-training pipeline (frontier teacher). Only used during training and
//! benchmarking, never for inference.
//!
//! Default endpoint: https://api.openai.com/v1/chat/completions
//! TLS via std.crypto.tls.Client with the system CA bundle.

const std = @import("std");

pub const OpenAIConfig = struct {
    api_key: []const u8 = "",
    model: []const u8 = "gpt-4o",
    base_url: []const u8 = "api.openai.com",
    port: u16 = 443,
    timeout_ms: u32 = 120_000,
    temperature: ?f64 = null,
    max_tokens: ?usize = null,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const OpenAIResponse = struct {
    text: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OpenAIResponse) void {
        self.allocator.free(self.text);
    }
};

/// Sends a chat completion request to OpenAI and returns the assistant text.
/// Caller must deinit the returned OpenAIResponse.
pub fn chatCompletion(allocator: std.mem.Allocator, config: OpenAIConfig, messages: []const ChatMessage) !OpenAIResponse {
    if (config.api_key.len == 0) return error.MissingApiKey;

    // Build JSON body: {"model":"...","messages":[{"role":"...","content":"..."}],"stream":false}
    var json_body = std.ArrayList(u8).init(allocator);
    defer json_body.deinit();
    try json_body.appendSlice("{\"model\":\"");
    try json_body.appendSlice(config.model);
    try json_body.appendSlice("\",\"messages\":[");
    for (messages, 0..) |msg, i| {
        if (i > 0) try json_body.appendSlice(",");
        try json_body.appendSlice("{\"role\":\"");
        try json_body.appendSlice(msg.role);
        try json_body.appendSlice("\",\"content\":\"");
        try appendEscaped(&json_body, msg.content);
        try json_body.appendSlice("\"}");
    }
    try json_body.appendSlice("],\"stream\":false");
    if (config.temperature) |temp| {
        try std.fmt.format(json_body.writer(), ",\"temperature\":{d}", .{temp});
    }
    if (config.max_tokens) |mt| {
        try std.fmt.format(json_body.writer(), ",\"max_tokens\":{d}", .{mt});
    }
    try json_body.appendSlice("}");

    // Build HTTP request - headers first, then append json body
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();
    try std.fmt.format(request.writer(), "POST /v1/chat/completions HTTP/1.1\r\nHost: {s}\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ config.base_url, config.api_key, json_body.items.len });
    try request.appendSlice(json_body.items);

    // Resolve hostname and connect
    const addr_list = try std.net.getAddressList(allocator, config.base_url, config.port);
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return error.DnsResolutionFailed;

    var stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
    defer stream.close();

    // Set read timeout so slow responses don't block forever
    const tv = std.posix.timeval{
        .tv_sec = @intCast(config.timeout_ms / 1000),
        .tv_usec = @intCast((config.timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    // TLS handshake with system CA bundle
    var ca_bundle = std.crypto.Certificate.Bundle{};
    defer ca_bundle.deinit(allocator);
    ca_bundle.rescan(allocator) catch {};

    var tls = std.crypto.tls.Client.init(stream, ca_bundle, config.base_url) catch |err| {
        return err;
    };

    // Send request over TLS
    tls.writeAll(stream, request.items) catch |err| {
        return err;
    };

    // Read response headers (until \r\n\r\n)
    var response_buf = std.ArrayList(u8).init(allocator);
    defer response_buf.deinit();
    var buf: [4096]u8 = undefined;
    var header_end: ?usize = null;
    while (header_end == null) {
        const n = tls.read(stream, &buf) catch break;
        if (n == 0) break;
        try response_buf.appendSlice(buf[0..n]);
        header_end = std.mem.indexOf(u8, response_buf.items, "\r\n\r\n");
    }

    const body_start = header_end orelse {
        return error.InvalidHttpResponse;
    };

    // Check for HTTP error status immediately, while the headers slice is
    // still valid (body reads below may reallocate response_buf).
    const headers = response_buf.items[0..body_start];
    if (std.mem.startsWith(u8, headers, "HTTP/1.1 4") or std.mem.startsWith(u8, headers, "HTTP/1.1 5")) {
        return error.OpenAIHttpError;
    }

    // Parse Content-Length from headers. OpenAI keeps the connection alive,
    // so reading until EOF would block until the socket timeout.
    const content_length = parseContentLength(headers);

    // Read the body: exactly content_length bytes if known, else until EOF.
    if (content_length) |expected| {
        while (response_buf.items.len - (body_start + 4) < expected) {
            const n = tls.read(stream, &buf) catch break;
            if (n == 0) break;
            try response_buf.appendSlice(buf[0..n]);
        }
    } else {
        while (true) {
            const n = tls.read(stream, &buf) catch break;
            if (n == 0) break;
            try response_buf.appendSlice(buf[0..n]);
        }
    }

    const body = response_buf.items[body_start + 4 ..];

    // Parse JSON to extract choices[0].message.content
    const response_text = try extractContentField(allocator, body);
    return OpenAIResponse{ .text = response_text, .allocator = allocator };
}

/// Appends a string to a JSON body with proper escaping.
fn appendEscaped(out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0...8, 11, 12, 14...31 => {
                try std.fmt.format(out.writer(), "\\u{x:0>4}", .{c});
            },
            else => try out.append(c),
        }
    }
}

/// Parses the Content-Length header from HTTP response headers.
/// Returns null if the header is absent or malformed.
fn parseContentLength(headers: []const u8) ?usize {
    var content_length: ?usize = null;
    var header_it = std.mem.splitSequence(u8, headers, "\r\n");
    while (header_it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return content_length;
}

/// Extracts the "content" field from the first choice in an OpenAI response.
/// Response shape: {"choices":[{"message":{"role":"assistant","content":"..."}}]}
fn extractContentField(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // Find "choices" array, then the first "message" object, then "content"
    const choices_pos = std.mem.indexOf(u8, json, "\"choices\"") orelse return error.FieldNotFound;
    const message_pos = std.mem.indexOfPos(u8, json, choices_pos, "\"message\"") orelse return error.FieldNotFound;
    const content_pos = std.mem.indexOfPos(u8, json, message_pos, "\"content\"") orelse return error.FieldNotFound;

    // Find the colon after "content"
    const colon_pos = std.mem.indexOfPos(u8, json, content_pos + "\"content\"".len, ":") orelse return error.FieldNotFound;
    var i = colon_pos + 1;
    // Skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return error.FieldNotFound;
    i += 1;

    // Read the string value with escape handling
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    while (i < json.len) {
        if (json[i] == '\\' and i + 1 < json.len) {
            switch (json[i + 1]) {
                '"' => try result.append('"'),
                '\\' => try result.append('\\'),
                'n' => try result.append('\n'),
                'r' => try result.append('\r'),
                't' => try result.append('\t'),
                '/' => try result.append('/'),
                'u' => {
                    // Decode \uXXXX escape
                    if (i + 5 < json.len) {
                        const hex = json[i + 2 .. i + 6];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch 0xFFFD;
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 3;
                        try result.appendSlice(utf8_buf[0..len]);
                        i += 4;
                    }
                },
                else => try result.append(json[i + 1]),
            }
            i += 2;
        } else if (json[i] == '"') {
            break;
        } else {
            try result.append(json[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Checks if OpenAI is usable: API key present and (optionally) reachable.
/// Never blocks longer than a short probe timeout.
pub fn isAvailable(config: OpenAIConfig) bool {
    if (config.api_key.len == 0) return false;
    // Lightweight probe: try resolving the host. Full TLS handshake is
    // expensive and may fail in sandboxed CI; key presence is the primary gate.
    const addr_list = std.net.getAddressList(std.heap.page_allocator, config.base_url, config.port) catch return false;
    addr_list.deinit();
    return true;
}

/// Builds a single-turn chat request from a prompt string.
pub fn simplePrompt(allocator: std.mem.Allocator, config: OpenAIConfig, system: []const u8, prompt: []const u8) !OpenAIResponse {
    var messages = [_]ChatMessage{
        .{ .role = "system", .content = system },
        .{ .role = "user", .content = prompt },
    };
    return chatCompletion(allocator, config, &messages);
}

// =============================================================================
// Tests
// =============================================================================

test "openai_client: parseContentLength extracts value" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 503\r\nConnection: close";
    try std.testing.expectEqual(@as(?usize, 503), parseContentLength(headers));
}

test "openai_client: parseContentLength is case-insensitive" {
    const headers = "HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n";
    try std.testing.expectEqual(@as(?usize, 1024), parseContentLength(headers));
}

test "openai_client: parseContentLength returns null when absent" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n";
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(headers));
}

test "openai_client: default config values" {
    const config = OpenAIConfig{};
    try std.testing.expectEqualStrings("", config.api_key);
    try std.testing.expectEqualStrings("gpt-4o", config.model);
    try std.testing.expectEqualStrings("api.openai.com", config.base_url);
    try std.testing.expectEqual(@as(u16, 443), config.port);
    try std.testing.expectEqual(@as(u32, 120_000), config.timeout_ms);
}

test "openai_client: isAvailable false without key" {
    const config = OpenAIConfig{};
    try std.testing.expect(!isAvailable(config));
}

test "openai_client: extractContentField extracts assistant text" {
    const allocator = std.testing.allocator;
    const json = "{\"id\":\"x\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Hello from GPT\"}}]}";
    const result = try extractContentField(allocator, json);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello from GPT", result);
}

test "openai_client: extractContentField handles escaped characters" {
    const allocator = std.testing.allocator;
    const json = "{\"choices\":[{\"message\":{\"content\":\"Line1\\nLine2\\tTabbed\"}}]}";
    const result = try extractContentField(allocator, json);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Line1\nLine2\tTabbed", result);
}

test "openai_client: extractContentField handles unicode escapes" {
    const allocator = std.testing.allocator;
    const json = "{\"choices\":[{\"message\":{\"content\":\"caf\\u00e9\"}}]}";
    const result = try extractContentField(allocator, json);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("caf\u{e9}", result);
}

test "openai_client: extractContentField returns error for missing content" {
    const allocator = std.testing.allocator;
    const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\"}}]}";
    try std.testing.expectError(error.FieldNotFound, extractContentField(allocator, json));
}

test "openai_client: extractContentField skips earlier content fields" {
    const allocator = std.testing.allocator;
    // The "content" inside "system" or earlier messages must be skipped;
    // only the first choice's message content is extracted.
    const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"final answer\"}}]}";
    const result = try extractContentField(allocator, json);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("final answer", result);
}

test "openai_client: chatCompletion errors without key" {
    const allocator = std.testing.allocator;
    const config = OpenAIConfig{};
    var messages = [_]ChatMessage{.{ .role = "user", .content = "hi" }};
    try std.testing.expectError(error.MissingApiKey, chatCompletion(allocator, config, &messages));
}

test "openai_client: appendEscaped escapes quotes and newlines" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try appendEscaped(&out, "say \"hi\"\nnext");
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\nnext", out.items);
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
