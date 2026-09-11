// ============================================================================
// OLLAMA CLIENT — Neuraleak
// ============================================================================
//
// Minimal HTTP/JSON client for the Ollama generate API. It is designed to be
// testable without a running server: the public API accepts an endpoint and
// can be exercised with a local test harness.
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");

/// Ollama generate request payload.
///
/// `model` and `prompt` are required. Streaming is enabled by default so the
/// client can process tokens as they arrive and detect completion. Thinking is
/// disabled by default for Qwen3-family models that would otherwise spend the
/// token budget on internal reasoning traces.
pub const GenerateRequest = struct {
    model: []const u8,
    prompt: []const u8,
    stream: bool = true,
    think: bool = false,
    max_tokens: u32 = 128,
    temperature: f32 = 0.8,
    top_p: f32 = 0.9,
    num_threads: ?u32 = null,
    keep_alive: ?[]const u8 = null,
};

/// Parsed Ollama generate response. The caller owns `text` and must free it.
pub const GenerateResponse = struct {
    allocator: std.mem.Allocator,
    text: []const u8,

    pub fn deinit(self: *const GenerateResponse) void {
        self.allocator.free(self.text);
    }
};

/// Send a generate request to the Ollama server at `endpoint`.
///
/// `endpoint` is the full URL, e.g. `http://localhost:11434/api/generate`.
/// The function returns an allocated `text` copy on success. On failure it
/// returns an error, including network or JSON errors.
///
/// The caller must call `response.deinit()` to free the returned text.
pub fn generate(allocator: std.mem.Allocator, endpoint: []const u8, request: GenerateRequest) !GenerateResponse {
    const payload = try buildJsonPayload(allocator, request);
    defer allocator.free(payload);

    const body = try post(allocator, endpoint, payload);
    defer allocator.free(body);

    const text = try extractResponseText(allocator, body);

    return .{
        .allocator = allocator,
        .text = text,
    };
}

/// Build the JSON payload for the Ollama generate request.
fn buildJsonPayload(allocator: std.mem.Allocator, request: GenerateRequest) ![]const u8 {
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
    // JSON-escape the prompt.
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

/// Perform an HTTP POST and return the response body as an allocated string.
fn post(allocator: std.mem.Allocator, endpoint: []const u8, payload: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();

    const content_type_header = .{ .name = "Content-Type", .value = "application/json" };

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = endpoint },
        .extra_headers = &.{content_type_header},
        .payload = payload,
        .response_storage = .{ .dynamic = &body },
    });

    if (result.status.class() != .success) {
        return error.OllamaRequestFailed;
    }

    return body.toOwnedSlice();
}

/// Extract the visible response text from an Ollama JSON body.
///
/// Handles both a single JSON object (`stream: false`) and newline-delimited
/// JSON objects (`stream: true`). In the streaming case, each chunk's
/// `response` field is concatenated until a chunk with `done: true` is seen.
fn extractResponseText(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();

    var line_iterator = std.mem.splitScalar(u8, body, '\n');
    var saw_done = false;
    while (line_iterator.next()) |line| {
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("response")) |response| {
            if (response != .string) return error.OllamaResponseNotString;
            try text.appendSlice(response.string);
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

// ============================================================================
// Tests
// ============================================================================

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
    try std.testing.expect(std.mem.indexOf(u8, payload, "qwen3.5:9b") != null);
}

test "extractResponseText returns the response field from a single object" {
    const allocator = std.testing.allocator;
    const body = "{\"model\":\"qwen3.5:9b\",\"response\":\"hello\"}";
    const text = try extractResponseText(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "extractResponseText concatenates streaming chunks" {
    const allocator = std.testing.allocator;
    const body =
        "{\"model\":\"qwen3.5:9b\",\"response\":\"Hel\",\"done\":false}\n" ++
        "{\"model\":\"qwen3.5:9b\",\"response\":\"lo\",\"done\":true}\n";
    const text = try extractResponseText(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);
}

test "extractResponseText errors on missing response field" {
    const allocator = std.testing.allocator;
    const body = "{\"model\":\"qwen3.5:9b\"}";
    try std.testing.expectError(error.OllamaResponseMissing, extractResponseText(allocator, body));
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
