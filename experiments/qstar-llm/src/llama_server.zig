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
const builtin = @import("builtin");

/// TCP sockets are unavailable on freestanding targets (WASM); every network
/// entry point degrades to "server unreachable" so callers fall back to
/// lattice-only generation.
const is_freestanding = builtin.os.tag == .freestanding;

pub const LlamaServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    model: []const u8 = "qwen3-9b",
    temperature: f64 = 0.7,
    max_tokens: u32 = 512,
    timeout_ms: u32 = 30_000,
    /// Creative path token budget (high-quality default; the wall-clock
    /// timeout is the real bound that eliminates outliers).
    creative_max_tokens: u32 = 384,
    /// Creative path temperature (slightly higher for variety).
    creative_temperature: f64 = 0.8,
    /// Minimum tokens accumulated before a wall-clock timeout may fire.
    /// Prevents returning empty on slow time-to-first-token.
    min_tokens_before_timeout: u32 = 32,
    /// When true, the streaming loop checks shouldEarlyTerminateCreative
    /// on accumulated text and closes the socket early when a complete
    /// stanza/paragraph is detected. Set by the caller for creative prompts.
    early_terminate_creative: bool = false,

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
        if (std.posix.getenv("LLAMA_SERVER_TIMEOUT_MS")) |t| {
            config.timeout_ms = std.fmt.parseInt(u32, t, 10) catch base.timeout_ms;
        }
        if (std.posix.getenv("LLAMA_SERVER_BENCH_TIMEOUT_MS")) |t| {
            config.timeout_ms = std.fmt.parseInt(u32, t, 10) catch 60_000;
        } else {
            // Benchmark/general path default: 60s wall-clock cap.
            config.timeout_ms = 60_000;
        }
        if (std.posix.getenv("LLAMA_SERVER_CREATIVE_MAX_TOKENS")) |t| {
            config.creative_max_tokens = std.fmt.parseInt(u32, t, 10) catch base.creative_max_tokens;
        }
        if (std.posix.getenv("LLAMA_SERVER_CREATIVE_TEMPERATURE")) |t| {
            config.creative_temperature = std.fmt.parseFloat(f64, t) catch base.creative_temperature;
        }
        return config;
    }
};

/// Returns a config tuned for the training path: 5-minute wall-clock
/// timeout to allow longer high-quality teacher generations.
pub fn trainingConfig(allocator: std.mem.Allocator, base: LlamaServerConfig) LlamaServerConfig {
    var config = LlamaServerConfig.fromEnv(allocator, base);
    if (std.posix.getenv("LLAMA_SERVER_TRAIN_TIMEOUT_MS")) |t| {
        config.timeout_ms = std.fmt.parseInt(u32, t, 10) catch 300_000;
    } else {
        config.timeout_ms = 300_000; // 5 minutes
    }
    return config;
}

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
    if (is_freestanding) return false;
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
    if (is_freestanding) return error.ServerUnreachable;
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
    if (is_freestanding) return error.ServerUnreachable;
    const addr = try std.net.Address.parseIp4(config.host, config.port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    // Set a socket receive timeout so that read() doesn't block indefinitely.
    // This allows the wall-clock deadline check to fire even when the model
    // has a long TTFT (time to first token). The read timeout is 1 second,
    // so the loop iterates at least once per second to check the deadline.
    const read_timeout = std.posix.timeval{ .tv_sec = 1, .tv_usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&read_timeout)) catch {};

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
    var done = false;
    var served_model_seen = false;

    // Qwen3 models generate "reasoning_content" (thinking) before "content".
    // We track reasoning separately so it doesn't pollute the response, but
    // we count it toward the timeout threshold so the wall-clock timeout
    // fires even during long reasoning phases.
    var reasoning_text = std.ArrayList(u8).init(allocator);
    defer reasoning_text.deinit();
    _ = &reasoning_text;

    // Wall-clock deadline: break out of the read loop if the configured
    // timeout elapses, returning whatever has been streamed so far (as
    // long as we have at least min_tokens_before_timeout characters of
    // content OR reasoning combined).
    // This eliminates the 100-300s outliers observed on creative prompts
    // when the local Qwen3-8B server is slow or in long reasoning phases.
    const start_ns = std.time.nanoTimestamp();
    const deadline_ns: i128 = start_ns +
        @divTrunc(@as(i128, config.timeout_ms) * @as(i128, std.time.ns_per_s), 1000);

    while (!done) {
        // Hard wall-clock deadline: break regardless of content state.
        // The caller handles empty/partial responses by falling back to the
        // lattice. This prevents the Qwen3 reasoning phase from blocking
        // indefinitely. The min_tokens_before_timeout threshold only prevents
        // breaking on partial content that's too short to be useful.
        if (std.time.nanoTimestamp() >= deadline_ns) {
            // If we have partial content, only break if it's long enough.
            // If we have no content, break immediately (caller will fall back).
            if (full_text.items.len == 0 or
                full_text.items.len >= config.min_tokens_before_timeout)
            {
                break;
            }
        }
        // read() may return error.WouldBlock when the socket receive timeout
        // fires. In that case, continue the loop to check the wall-clock
        // deadline instead of breaking.
        const n = stream.read(&read_buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => break,
        };
        if (n == 0) break;

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                if (line_buf.items.len > 0) {
                    if (std.mem.startsWith(u8, line_buf.items, "data: ")) {
                        const data = line_buf.items[6..];
                        if (isDoneEvent(data)) {
                            done = true;
                        } else {
                            if (!served_model_seen) {
                                if (servedModel(data)) |served| {
                                    served_model_seen = true;
                                    if (!std.ascii.eqlIgnoreCase(served, config.model) and
                                        std.ascii.indexOfIgnoreCase(served, config.model) == null and
                                        std.ascii.indexOfIgnoreCase(config.model, served) == null)
                                    {
                                        return error.ServedModelMismatch;
                                    }
                                }
                            }
                            // Extract reasoning_content (Qwen3 thinking phase).
                            // We accumulate it for timeout tracking but don't
                            // include it in the final response.
                            if (extractDeltaReasoningContent(allocator, data)) |delta| {
                                defer allocator.free(delta);
                                try reasoning_text.appendSlice(delta);
                            } else |_| {}
                            if (extractDeltaContent(allocator, data)) |delta| {
                                defer allocator.free(delta);
                                try full_text.appendSlice(delta);
                                // Early-termination for creative prompts: if the
                                // accumulated text has reached a complete
                                // stanza/paragraph boundary, close the socket
                                // early to eliminate runaway generation.
                                if (config.early_terminate_creative and
                                    full_text.items.len >= 80 and
                                    shouldEarlyTerminateCreative(full_text.items))
                                {
                                    done = true;
                                }
                            } else |_| {}
                        }
                    }
                    line_buf.clearRetainingCapacity();
                }
            } else {
                try line_buf.append(byte);
            }
            if (done) break;
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

fn servedModel(data: []const u8) ?[]const u8 {
    const key = "\"model\":\"";
    const start = std.mem.indexOf(u8, data, key) orelse return null;
    const value_start = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, data, value_start, '\"') orelse return null;
    return data[value_start..end];
}

fn isDoneEvent(data: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, data, " \r\t"), "[DONE]");
}

fn extractDeltaContent(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // SSE streaming format: {"choices":[{"delta":{"content":"..."}}]}
    const delta_key = "\"content\":\"";
    const start = std.mem.indexOf(u8, json, delta_key) orelse return error.NoContent;
    const content_start = start + delta_key.len;
    return try extractJsonString(allocator, json, content_start);
}

fn extractDeltaReasoningContent(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // Qwen3 SSE streaming format: {"choices":[{"delta":{"reasoning_content":"..."}}]}
    // This is the model's internal thinking, not the visible response.
    // We extract it to count toward the timeout threshold.
    const delta_key = "\"reasoning_content\":\"";
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
// Creative early-termination detector
// =============================================================================

/// Detects whether accumulated streamed creative text has reached a natural
/// completion point (a complete stanza, paragraph, or story ending). When true,
/// the caller may close the socket early and return the accumulated text,
/// eliminating runaway generation latency while preserving coherent output.
///
/// Heuristics (any one triggers termination):
/// 1. Double newline followed by 2+ sentences (stanza/paragraph boundary).
/// 2. A period after 120+ characters of story prose (complete narrative beat).
/// 3. A closing stanza marker (e.g., a final line ending with punctuation
///    after at least 4 lines of verse).
pub fn shouldEarlyTerminateCreative(text: []const u8) bool {
    if (text.len < 80) return false;

    // Heuristic 1: double newline followed by 2+ sentences.
    // Look for "\n\n" then count sentence-ending punctuation after it.
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, "\n\n")) |dbl_nl| {
        const after = text[dbl_nl + 2 ..];
        if (after.len < 10) {
            search_start = dbl_nl + 1;
            continue;
        }
        // Count sentence endings in the text after the double newline.
        var sentence_count: usize = 0;
        for (after) |c| {
            if (c == '.' or c == '!' or c == '?') sentence_count += 1;
            if (sentence_count >= 2) return true;
        }
        search_start = dbl_nl + 1;
        if (search_start >= text.len) break;
    }

    // Heuristic 2: period after 120+ chars of prose (story beat complete).
    // Only trigger if the text has no verse-like line structure (few short lines).
    var short_line_count: usize = 0;
    var line_start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            if (i - line_start < 40 and i - line_start > 0) short_line_count += 1;
            line_start = i + 1;
        }
    }
    // If not verse-like (few short lines), a period after 120 chars is a beat.
    if (short_line_count < 4 and text.len > 120) {
        // Check if the last 20 chars contain a period (recent sentence end).
        const tail = text[text.len - 20 ..];
        if (std.mem.indexOfScalar(u8, tail, '.') != null) return true;
    }

    // Heuristic 3: verse with 4+ short lines ending in punctuation.
    if (short_line_count >= 4) {
        const tail = text[text.len - 20 ..];
        if (std.mem.indexOfAny(u8, tail, ".!?") != null) return true;
    }

    return false;
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
    try std.testing.expectEqual(@as(u32, 384), config.creative_max_tokens);
    try std.testing.expectEqual(@as(f64, 0.8), config.creative_temperature);
    try std.testing.expectEqual(@as(u32, 32), config.min_tokens_before_timeout);
}

test "llama_server: shouldEarlyTerminateCreative detects stanza boundary" {
    const poem =
        \\Waves crash upon the shore,
        \\Salt spray fills the air.
        \\The ocean sings forevermore,
        \\A song beyond compare.
        \\
        \\The moon reflects on water deep,
        \\While stars begin to peep.
    ;
    try std.testing.expect(shouldEarlyTerminateCreative(poem));
}

test "llama_server: shouldEarlyTerminateCreative detects prose beat" {
    const prose =
        \\The robot picked up the brush for the first time. It mixed blue and yellow
        \\on the palette, watching the green emerge like a memory it never had. The
        \\canvas waited, white and patient. It made the first stroke.
    ;
    try std.testing.expect(shouldEarlyTerminateCreative(prose));
}

test "llama_server: shouldEarlyTerminateCreative rejects short text" {
    try std.testing.expect(!shouldEarlyTerminateCreative("Short text."));
    try std.testing.expect(!shouldEarlyTerminateCreative(""));
}

test "llama_server: shouldEarlyTerminateCreative rejects mid-sentence" {
    const mid = "The robot began to paint and the colors flowed across the canvas in a way that was beautiful and the brush moved";
    try std.testing.expect(!shouldEarlyTerminateCreative(mid));
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

test "llama_server: served model is extracted" {
    const model = servedModel("{\"model\":\"qwen3-9b\",\"choices\":[]}").?;
    try std.testing.expectEqualStrings("qwen3-9b", model);
    try std.testing.expect(servedModel("{\"choices\":[]}") == null);
}

test "llama_server: done SSE event is recognized" {
    try std.testing.expect(isDoneEvent("[DONE]"));
    try std.testing.expect(isDoneEvent("  [DONE] \r"));
    try std.testing.expect(!isDoneEvent("[DONE] extra"));
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
