//! ollama_client.zig — Zero-dependency HTTP client for Ollama API.
//!
//! Used by the self-training pipeline to fetch teacher responses from
//! a local Ollama instance. Only used during training, never for inference.
//!
//! Default endpoint: http://localhost:11434/api/generate
//! Override defaults via .env: OLLAMA_HOST, OLLAMA_PORT, OLLAMA_MODEL

const std = @import("std");

pub const OllamaConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 11434,
    model: []const u8 = "qwen2.5:3b",
    timeout_ms: u32 = 600_000,
    temperature: ?f64 = null,
};

/// Loads OllamaConfig from a .env file, falling back to struct defaults.
/// Caller does not need to free anything — strings from the env_loader
/// are duplicated with page_allocator so they outlive the loader.
/// Pass an existing OllamaConfig to override .env values with CLI args.
pub fn configFromEnv(allocator: std.mem.Allocator, base: OllamaConfig) OllamaConfig {
    const env_loader = @import("env_loader");
    var loader = env_loader.EnvLoader.init(allocator);
    defer loader.deinit();
    loader.loadFile(".env") catch return base;

    var config = base;
    const page = std.heap.page_allocator;
    if (loader.get("OLLAMA_HOST")) |h| {
        config.host = page.dupe(u8, h) catch base.host;
    }
    if (loader.get("OLLAMA_PORT")) |p| {
        config.port = std.fmt.parseInt(u16, p, 10) catch base.port;
    }
    if (loader.get("OLLAMA_MODEL")) |m| {
        config.model = page.dupe(u8, m) catch base.model;
    }
    return config;
}

pub const OllamaResponse = struct {
    text: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OllamaResponse) void {
        self.allocator.free(self.text);
    }
};

/// Sends a generate request to Ollama and returns the response text.
/// Caller must deinit the returned OllamaResponse.
pub fn generate(allocator: std.mem.Allocator, config: OllamaConfig, prompt: []const u8) !OllamaResponse {
    // Build JSON body: {"model":"...","prompt":"...","stream":false}
    // We must escape the prompt for JSON strings.
    var json_body = std.ArrayList(u8).init(allocator);
    defer json_body.deinit();
    try json_body.appendSlice("{\"model\":\"");
    try json_body.appendSlice(config.model);
    try json_body.appendSlice("\",\"prompt\":\"");
    // Escape prompt for JSON
    for (prompt) |c| {
        switch (c) {
            '"' => try json_body.appendSlice("\\\""),
            '\\' => try json_body.appendSlice("\\\\"),
            '\n' => try json_body.appendSlice("\\n"),
            '\r' => try json_body.appendSlice("\\r"),
            '\t' => try json_body.appendSlice("\\t"),
            0...8, 11, 12, 14...31 => {
                try std.fmt.format(json_body.writer(), "\\u{x:0>4}", .{c});
            },
            else => try json_body.append(c),
        }
    }
    try json_body.appendSlice("\",\"stream\":false");
    if (config.temperature) |temp| {
        try std.fmt.format(json_body.writer(), ",\"temperature\":{d}", .{temp});
    }
    try json_body.appendSlice("}");

    // Build HTTP request
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();
    try std.fmt.format(request.writer(), "POST /api/generate HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ config.host, config.port, json_body.items.len, json_body.items });

    // Connect to Ollama
    const address = try std.net.Address.parseIp4(config.host, config.port);
    var stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    // Set read timeout so slow Ollama responses don't block forever
    const tv = std.posix.timeval{
        .tv_sec = @intCast(config.timeout_ms / 1000),
        .tv_usec = @intCast((config.timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    // Send request
    _ = try stream.write(request.items);

    // Read response headers (until \r\n\r\n)
    var response_buf = std.ArrayList(u8).init(allocator);
    defer response_buf.deinit();
    var buf: [4096]u8 = undefined;
    var header_end: ?usize = null;
    while (header_end == null) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        try response_buf.appendSlice(buf[0..n]);
        header_end = std.mem.indexOf(u8, response_buf.items, "\r\n\r\n");
    }

    const body_start = header_end orelse {
        return error.InvalidHttpResponse;
    };

    // Parse Content-Length from headers. Ollama keeps the connection alive,
    // so reading until EOF would block until the socket timeout.
    const headers = response_buf.items[0..body_start];
    const content_length = parseContentLength(headers);

    // Read the body: exactly content_length bytes if known, else until EOF.
    if (content_length) |expected| {
        while (response_buf.items.len - (body_start + 4) < expected) {
            const n = stream.read(&buf) catch break;
            if (n == 0) break;
            try response_buf.appendSlice(buf[0..n]);
        }
    } else {
        while (true) {
            const n = stream.read(&buf) catch break;
            if (n == 0) break;
            try response_buf.appendSlice(buf[0..n]);
        }
    }

    const body = response_buf.items[body_start + 4 ..];

    // Parse JSON to extract "response" field
    const response_text = try extractJsonField(allocator, body, "response");
    return OllamaResponse{ .text = response_text, .allocator = allocator };
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

/// Extracts a string field value from a JSON object.
/// Simple parser — looks for "field":"value" pattern with proper escaping.
fn extractJsonField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]u8 {
    // Search for "field":"
    var search_buf: [256]u8 = undefined;
    const pattern = try std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field});

    const start = std.mem.indexOf(u8, json, pattern) orelse {
        return error.FieldNotFound;
    };
    const value_start = start + pattern.len;

    // Find the closing quote (handle escaped quotes)
    var i: usize = value_start;
    var result = std.ArrayList(u8).init(allocator);
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
                    // Skip unicode escape \uXXXX — just skip 4 hex chars
                    if (i + 5 < json.len) i += 4;
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

/// Checks if Ollama is reachable by attempting a connection.
pub inline fn isAvailable(config: OllamaConfig) bool {
    const address = std.net.Address.parseIp4(config.host, config.port) catch return false;
    var stream = std.net.tcpConnectToAddress(address) catch return false;
    stream.close();
    return true;
}

/// Checks if a specific model is installed on the Ollama server.
/// Queries GET /api/tags and matches the model name exactly.
/// Returns false if the server is unreachable or the model is absent.
pub fn modelExists(config: OllamaConfig) bool {
    const address = std.net.Address.parseIp4(config.host, config.port) catch return false;
    var stream = std.net.tcpConnectToAddress(address) catch return false;
    defer stream.close();

    // Build HTTP request
    var request = std.ArrayList(u8).init(std.heap.page_allocator);
    defer request.deinit();
    std.fmt.format(request.writer(), "GET /api/tags HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ config.host, config.port }) catch return false;

    _ = stream.write(request.items) catch return false;

    // Read the full response
    var response_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer response_buf.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        response_buf.appendSlice(buf[0..n]) catch break;
    }

    // Search for "name":"<model>" in the JSON body
    var search_buf: [512]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"name\":\"{s}\"", .{config.model}) catch return false;
    return std.mem.indexOf(u8, response_buf.items, pattern) != null;
}

/// Result of a draft verification pass.
pub const VerificationResult = struct {
    verified_text: []u8,
    accepted_tokens: usize,
    rejected_tokens: usize,
    acceptance_rate: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VerificationResult) void {
        self.allocator.free(self.verified_text);
    }
};

/// Sends a draft response to Ollama for verification.
/// The verifier LLM checks the draft and returns a corrected/verified version.
/// Caller must deinit the returned VerificationResult.
pub fn verifyDraft(allocator: std.mem.Allocator, config: OllamaConfig, prompt: []const u8, draft: []const u8) !VerificationResult {
    // Build verification prompt: ask Ollama to verify/correct the draft
    var verify_prompt = std.ArrayList(u8).init(allocator);
    defer verify_prompt.deinit();
    try verify_prompt.appendSlice("Given the prompt: \"");
    for (prompt) |c| {
        switch (c) {
            '"' => try verify_prompt.appendSlice("\\\""),
            '\\' => try verify_prompt.appendSlice("\\\\"),
            '\n' => try verify_prompt.appendSlice("\\n"),
            else => try verify_prompt.append(c),
        }
    }
    try verify_prompt.appendSlice("\" and the draft response: \"");
    for (draft) |c| {
        switch (c) {
            '"' => try verify_prompt.appendSlice("\\\""),
            '\\' => try verify_prompt.appendSlice("\\\\"),
            '\n' => try verify_prompt.appendSlice("\\n"),
            else => try verify_prompt.append(c),
        }
    }
    try verify_prompt.appendSlice("\", provide a corrected and verified version of the response. Keep the good parts and fix any errors.");

    var resp = try generate(allocator, config, verify_prompt.items);
    defer resp.deinit();

    // Estimate acceptance: count word overlap between draft and verified
    var accepted: usize = 0;
    var rejected: usize = 0;
    var draft_words = std.mem.tokenizeAny(u8, draft, " \t\n.,;:!?\"'()[]{}");
    while (draft_words.next()) |dw| {
        if (std.mem.indexOf(u8, resp.text, dw) != null) {
            accepted += 1;
        } else {
            rejected += 1;
        }
    }

    const total = accepted + rejected;
    const rate: f64 = if (total > 0) @as(f64, @floatFromInt(accepted)) / @as(f64, @floatFromInt(total)) else 0.0;

    // Copy the verified text
    const verified_copy = try allocator.dupe(u8, resp.text);

    return VerificationResult{
        .verified_text = verified_copy,
        .accepted_tokens = accepted,
        .rejected_tokens = rejected,
        .acceptance_rate = rate,
        .allocator = allocator,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "ollama_client: parseContentLength extracts value" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 503\r\nConnection: close";
    try std.testing.expectEqual(@as(?usize, 503), parseContentLength(headers));
}

test "ollama_client: parseContentLength is case-insensitive" {
    const headers = "HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n";
    try std.testing.expectEqual(@as(?usize, 1024), parseContentLength(headers));
}

test "ollama_client: parseContentLength returns null when absent" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n";
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(headers));
}

test "ollama_client: parseContentLength returns null for malformed value" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: abc\r\n";
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(headers));
}

test "ollama_client: isAvailable false when server unreachable" {
    // Port 1 is never listening; isAvailable must degrade to false.
    const config = OllamaConfig{ .port = 1 };
    try std.testing.expect(!isAvailable(config));
}

test "ollama_client: modelExists false when server unreachable" {
    // Port 1 is never listening; modelExists must degrade to false.
    const config = OllamaConfig{ .port = 1, .model = "qwen2.5:3b" };
    try std.testing.expect(!modelExists(config));
}

test "ollama_client: default config values" {
    const config = OllamaConfig{};
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 11434), config.port);
    try std.testing.expectEqualStrings("qwen2.5:3b", config.model);
    try std.testing.expectEqual(@as(u32, 600_000), config.timeout_ms);
}

test "ollama_client: custom config values" {
    const config = OllamaConfig{
        .host = "192.168.1.100",
        .port = 8080,
        .model = "llama3:8b",
        .timeout_ms = 5000,
    };
    try std.testing.expectEqualStrings("192.168.1.100", config.host);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqualStrings("llama3:8b", config.model);
    try std.testing.expectEqual(@as(u32, 5000), config.timeout_ms);
}

test "ollama_client: extractJsonField extracts response field" {
    const allocator = std.testing.allocator;
    const json = "{\"model\":\"qwen\",\"response\":\"Hello world\",\"done\":true}";
    const result = try extractJsonField(allocator, json, "response");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello world", result);
}

test "ollama_client: extractJsonField handles escaped characters" {
    const allocator = std.testing.allocator;
    const json = "{\"response\":\"Line1\\nLine2\\tTabbed\"}";
    const result = try extractJsonField(allocator, json, "response");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Line1\nLine2\tTabbed", result);
}

test "ollama_client: extractJsonField returns error for missing field" {
    const allocator = std.testing.allocator;
    const json = "{\"model\":\"qwen\",\"done\":true}";
    try std.testing.expectError(error.FieldNotFound, extractJsonField(allocator, json, "response"));
}

test "ollama_client: VerificationResult struct fields" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "verified text");
    var result = VerificationResult{
        .verified_text = text,
        .accepted_tokens = 10,
        .rejected_tokens = 5,
        .acceptance_rate = 0.667,
        .allocator = allocator,
    };
    defer result.deinit();

    try std.testing.expectEqualStrings("verified text", result.verified_text);
    try std.testing.expect(result.accepted_tokens == 10);
    try std.testing.expect(result.rejected_tokens == 5);
    try std.testing.expect(result.acceptance_rate > 0.66 and result.acceptance_rate < 0.67);
}

// =============================================================================
// Streaming Client — Ported from neuraleak
// =============================================================================

/// Advanced generate request with streaming support and full Ollama options.
pub const GenerateRequest = struct {
    model: []const u8,
    prompt: []const u8,
    stream: bool = true,
    think: bool = false,
    max_tokens: u32 = 128,
    temperature: f64 = 0.8,
    top_p: f64 = 0.9,
    num_threads: ?u32 = null,
    keep_alive: ?[]const u8 = null,
};

/// Parsed streaming generate response. Caller owns `text` and must free it.
pub const GenerateResponse = struct {
    allocator: std.mem.Allocator,
    text: []const u8,

    pub fn deinit(self: *const GenerateResponse) void {
        self.allocator.free(self.text);
    }
};

/// Builds the JSON payload for an advanced Ollama generate request.
pub fn buildJsonPayload(allocator: std.mem.Allocator, request: GenerateRequest) ![]const u8 {
    var json = std.ArrayList(u8).init(allocator);
    defer json.deinit();
    const writer = json.writer();

    try writer.writeAll("{");
    try writer.print("\"model\":\"{s}\",", .{request.model});
    try writer.print("\"stream\":{},", .{request.stream});
    try writer.print("\"think\":{},", .{request.think});
    if (request.keep_alive) |ka| {
        try writer.print("\"keep_alive\":\"{s}\",", .{ka});
    }
    try writer.print("\"options\":{{\"num_predict\":{d},\"temperature\":{d:.2},\"top_p\":{d:.2}", .{ request.max_tokens, request.temperature, request.top_p });
    if (request.num_threads) |nt| {
        try writer.print(",\"num_thread\":{d}", .{nt});
    }
    try writer.writeAll("},");
    try writer.print("\"prompt\":\"", .{});
    for (request.prompt) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"}");

    return try allocator.dupe(u8, json.items);
}

/// Extracts the visible response text from an Ollama JSON body.
/// Handles both single JSON objects (stream:false) and newline-delimited
/// JSON objects (stream:true), concatenating `response` fields until done.
pub fn extractResponseTextStreaming(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();

    var line_iterator = std.mem.splitScalar(u8, body, '\n');
    var saw_done = false;
    while (line_iterator.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        if (parsed.value.object.get("response")) |response| {
            if (response == .string) {
                try text.appendSlice(response.string);
            }
        }

        if (parsed.value.object.get("done")) |done| {
            if (done == .bool and done.bool) {
                saw_done = true;
            }
        }
    }

    if (text.items.len == 0 and !saw_done) {
        return error.OllamaResponseMissing;
    }

    return text.toOwnedSlice();
}

/// Sends an advanced generate request with streaming support.
/// Caller must deinit the returned GenerateResponse.
pub fn generateStreaming(allocator: std.mem.Allocator, config: OllamaConfig, request: GenerateRequest) !GenerateResponse {
    const payload = try buildJsonPayload(allocator, request);
    defer allocator.free(payload);

    // Build HTTP request
    var http_request = std.ArrayList(u8).init(allocator);
    defer http_request.deinit();
    try std.fmt.format(http_request.writer(), "POST /api/generate HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ config.host, config.port, payload.len, payload });

    const address = try std.net.Address.parseIp4(config.host, config.port);
    var stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const tv = std.posix.timeval{
        .tv_sec = @intCast(config.timeout_ms / 1000),
        .tv_usec = @intCast((config.timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    _ = try stream.write(http_request.items);

    // Read full response
    var response_buf = std.ArrayList(u8).init(allocator);
    defer response_buf.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        try response_buf.appendSlice(buf[0..n]);
    }

    // Find body start (after headers)
    const header_end = std.mem.indexOf(u8, response_buf.items, "\r\n\r\n") orelse {
        return error.InvalidHttpResponse;
    };
    const body = response_buf.items[header_end + 4 ..];

    const text = try extractResponseTextStreaming(allocator, body);
    return GenerateResponse{ .allocator = allocator, .text = text };
}

// =============================================================================
// Streaming Client Tests
// =============================================================================

test "buildJsonPayload disables thinking and caps response length" {
    const allocator = std.testing.allocator;
    const payload = try buildJsonPayload(allocator, .{
        .model = "qwen3.5:9b",
        .prompt = "hello",
        .stream = false,
        .think = false,
        .max_tokens = 64,
        .temperature = 0.5,
        .top_p = 0.85,
    });
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"think\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"num_predict\":64") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"temperature\":0.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"top_p\":0.85") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "qwen3.5:9b") != null);
}

test "buildJsonPayload escapes quotes and newlines" {
    const allocator = std.testing.allocator;
    const payload = try buildJsonPayload(allocator, .{
        .model = "qwen3.5:9b",
        .prompt = "line1\nline2\"quote",
        .stream = false,
        .think = false,
    });
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\\\"") != null);
}

test "extractResponseTextStreaming returns response from single object" {
    const allocator = std.testing.allocator;
    const body = "{\"model\":\"qwen3.5:9b\",\"response\":\"hello\"}";
    const text = try extractResponseTextStreaming(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "extractResponseTextStreaming concatenates streaming chunks" {
    const allocator = std.testing.allocator;
    const body =
        "{\"model\":\"qwen3.5:9b\",\"response\":\"Hel\",\"done\":false}\n" ++
        "{\"model\":\"qwen3.5:9b\",\"response\":\"lo\",\"done\":true}\n";
    const text = try extractResponseTextStreaming(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);
}

test "extractResponseTextStreaming errors on missing response" {
    const allocator = std.testing.allocator;
    const body = "{\"model\":\"qwen3.5:9b\"}";
    try std.testing.expectError(error.OllamaResponseMissing, extractResponseTextStreaming(allocator, body));
}

test "buildJsonPayload includes num_thread and keep_alive when provided" {
    const allocator = std.testing.allocator;
    const payload = try buildJsonPayload(allocator, .{
        .model = "tinyllama:latest",
        .prompt = "hello",
        .stream = false,
        .think = false,
        .max_tokens = 64,
        .temperature = 0.5,
        .top_p = 0.85,
        .num_threads = 8,
        .keep_alive = "30m",
    });
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"num_thread\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"keep_alive\":\"30m\"") != null);
}

test "buildJsonPayload omits optional fields when null" {
    const allocator = std.testing.allocator;
    const payload = try buildJsonPayload(allocator, .{
        .model = "tinyllama:latest",
        .prompt = "hello",
    });
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "num_thread") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "keep_alive") == null);
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
