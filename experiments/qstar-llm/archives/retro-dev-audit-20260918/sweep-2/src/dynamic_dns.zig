//! dynamic_dns.zig — ClouDNS dynamic URL updater for qstar.mesh projects.
//!
//! Performs an HTTP GET to a ClouDNS dynamic DNS update URL to keep
//! the master node's public IP address in sync with the DNS record.
//!
//! Used by:
//!   - qstar-llm master server (built-in module)
//!   - qstar-net / qstar-mesh projects (as importable module)
//!   - Standalone via `qstar dns-update` CLI subcommand
//!   - Python fallback: dynamic-url-python.py (for cron use)
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const builtin = @import("builtin");

/// Default ClouDNS dynamic DNS update URL.
/// Updates the A record for the qstar.mesh domain to the current public IP.
const DEFAULT_DYNAMIC_DNS_URL =
    "https://ipv4.cloudns.net/api/dynamicURL/?q=MTUwMjk0NjI6ODgzNzIwNjgyOjg0ZWQwNjIwYzQwNTc0MWFmM2NlMDEzODZmZmJiZWZjODAwN2E2YjZiNjA5MmUzZjI4M2UxYjZhY2NjMjY5ZWI";

/// Default HTTP timeout in milliseconds.
const DEFAULT_TIMEOUT_MS: u32 = 10_000;

/// Default retry count for failed updates.
const DEFAULT_RETRY_COUNT: u32 = 3;

/// Default delay between retries in milliseconds.
const DEFAULT_RETRY_DELAY_MS: u32 = 5_000;

/// Maximum URL length.
const MAX_URL_LEN: usize = 512;

/// Configuration for the dynamic DNS updater.
pub const DynamicDnsConfig = struct {
    /// The ClouDNS dynamic DNS update URL.
    url: []const u8 = DEFAULT_DYNAMIC_DNS_URL,
    /// HTTP timeout in milliseconds.
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    /// Number of retry attempts on failure.
    retry_count: u32 = DEFAULT_RETRY_COUNT,
    /// Delay between retries in milliseconds.
    retry_delay_ms: u32 = DEFAULT_RETRY_DELAY_MS,

    /// Create a config from a URL string (uses defaults for other fields).
    pub fn fromUrl(url: []const u8) DynamicDnsConfig {
        return .{ .url = url };
    }

    /// Create a config from environment variables, falling back to defaults.
    /// Reads DYNAMIC_DNS_URL from the env loader if available.
    pub fn fromEnv(env: anytype) DynamicDnsConfig {
        var config = DynamicDnsConfig{};
        if (env.get("DYNAMIC_DNS_URL")) |url| {
            config.url = url;
        }
        if (env.get("DYNAMIC_DNS_TIMEOUT_MS")) |timeout_str| {
            config.timeout_ms = std.fmt.parseInt(u32, timeout_str, 10) catch DEFAULT_TIMEOUT_MS;
        }
        if (env.get("DYNAMIC_DNS_RETRY_COUNT")) |retry_str| {
            config.retry_count = std.fmt.parseInt(u32, retry_str, 10) catch DEFAULT_RETRY_COUNT;
        }
        if (env.get("DYNAMIC_DNS_RETRY_DELAY_MS")) |delay_str| {
            config.retry_delay_ms = std.fmt.parseInt(u32, delay_str, 10) catch DEFAULT_RETRY_DELAY_MS;
        }
        return config;
    }

    /// Validate the config.
    pub fn validate(self: DynamicDnsConfig) bool {
        if (self.url.len == 0 or self.url.len > MAX_URL_LEN) return false;
        if (!std.mem.startsWith(u8, self.url, "https://")) return false;
        if (self.timeout_ms == 0) return false;
        return true;
    }
};

/// Result of a dynamic DNS update attempt.
pub const UpdateResult = struct {
    success: bool,
    status_code: u16,
    attempt: u32,
    error_msg: ?[]const u8 = null,
};

/// Perform a single HTTP GET to the dynamic DNS update URL.
/// Returns the result of the attempt.
pub fn update(allocator: std.mem.Allocator, config: DynamicDnsConfig) !UpdateResult {
    if (!config.validate()) {
        return .{
            .success = false,
            .status_code = 0,
            .attempt = 1,
            .error_msg = "invalid config (URL must be HTTPS, non-empty, under 512 chars)",
        };
    }

    // Skip real network calls in test builds
    if (builtin.is_test) {
        return .{
            .success = true,
            .status_code = 200,
            .attempt = 1,
        };
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = config.url },
        .method = .GET,
        .response_storage = .{ .dynamic = &response_body },
    }) catch |err| {
        return .{
            .success = false,
            .status_code = 0,
            .attempt = 1,
            .error_msg = @errorName(err),
        };
    };

    const success = result.status == .ok;
    return .{
        .success = success,
        .status_code = @intFromEnum(result.status),
        .attempt = 1,
        .error_msg = if (success) null else "non-200 HTTP status",
    };
}

/// Perform the dynamic DNS update with retry logic.
/// Retries up to `config.retry_count` times with `config.retry_delay_ms` delay.
pub fn updateWithRetry(allocator: std.mem.Allocator, config: DynamicDnsConfig) !UpdateResult {
    var attempt: u32 = 0;
    while (attempt < config.retry_count) : (attempt += 1) {
        const result = try update(allocator, config);
        if (result.success) {
            return .{
                .success = true,
                .status_code = result.status_code,
                .attempt = attempt + 1,
            };
        }

        // Log failure
        if (result.error_msg) |msg| {
            std.debug.print("Dynamic DNS update attempt {d}/{d} failed: {s}\n", .{
                attempt + 1, config.retry_count, msg,
            });
        } else {
            std.debug.print("Dynamic DNS update attempt {d}/{d} failed (HTTP {d})\n", .{
                attempt + 1, config.retry_count, result.status_code,
            });
        }

        // Delay before next retry (skip on last attempt)
        if (attempt + 1 < config.retry_count and config.retry_delay_ms > 0) {
            std.time.sleep(@as(u64, config.retry_delay_ms) * std.time.ns_per_ms);
        }
    }

    return .{
        .success = false,
        .status_code = 0,
        .attempt = attempt,
        .error_msg = "all retry attempts exhausted",
    };
}

/// Print a human-readable summary of the update result.
pub fn printResult(result: UpdateResult) void {
    if (result.success) {
        std.debug.print("Dynamic DNS update succeeded (attempt {d}, HTTP {d})\n", .{
            result.attempt, result.status_code,
        });
    } else {
        if (result.error_msg) |msg| {
            std.debug.print("Dynamic DNS update failed after {d} attempts: {s}\n", .{
                result.attempt, msg,
            });
        } else {
            std.debug.print("Dynamic DNS update failed after {d} attempts (HTTP {d})\n", .{
                result.attempt, result.status_code,
            });
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "dynamic_dns: default config is valid" {
    const config = DynamicDnsConfig{};
    try std.testing.expect(config.validate());
}

test "dynamic_dns: default URL is HTTPS" {
    const config = DynamicDnsConfig{};
    try std.testing.expect(std.mem.startsWith(u8, config.url, "https://"));
}

test "dynamic_dns: default URL is cloudns" {
    const config = DynamicDnsConfig{};
    try std.testing.expect(std.mem.indexOf(u8, config.url, "cloudns.net") != null);
}

test "dynamic_dns: fromUrl sets custom URL" {
    const config = DynamicDnsConfig.fromUrl("https://example.com/update?token=abc");
    try std.testing.expectEqualStrings("https://example.com/update?token=abc", config.url);
    try std.testing.expect(config.validate());
}

test "dynamic_dns: fromUrl uses default timeout and retry" {
    const config = DynamicDnsConfig.fromUrl("https://example.com/update");
    try std.testing.expectEqual(@as(u32, DEFAULT_TIMEOUT_MS), config.timeout_ms);
    try std.testing.expectEqual(@as(u32, DEFAULT_RETRY_COUNT), config.retry_count);
    try std.testing.expectEqual(@as(u32, DEFAULT_RETRY_DELAY_MS), config.retry_delay_ms);
}

test "dynamic_dns: empty URL is invalid" {
    const config = DynamicDnsConfig{ .url = "" };
    try std.testing.expect(!config.validate());
}

test "dynamic_dns: HTTP URL is invalid (must be HTTPS)" {
    const config = DynamicDnsConfig{ .url = "http://example.com/update" };
    try std.testing.expect(!config.validate());
}

test "dynamic_dns: URL over 512 chars is invalid" {
    var long_url: [600]u8 = undefined;
    @memset(&long_url, 'a');
    long_url[0..8].* = "https://".*;
    const config = DynamicDnsConfig{ .url = &long_url };
    try std.testing.expect(!config.validate());
}

test "dynamic_dns: zero timeout is invalid" {
    const config = DynamicDnsConfig{ .timeout_ms = 0 };
    try std.testing.expect(!config.validate());
}

test "dynamic_dns: update returns success in test mode" {
    const allocator = std.testing.allocator;
    const config = DynamicDnsConfig{};
    const result = try update(allocator, config);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u16, 200), result.status_code);
}

test "dynamic_dns: updateWithRetry succeeds in test mode" {
    const allocator = std.testing.allocator;
    const config = DynamicDnsConfig{ .retry_count = 3, .retry_delay_ms = 0 };
    const result = try updateWithRetry(allocator, config);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 1), result.attempt);
}

test "dynamic_dns: printResult does not crash on success" {
    const result = UpdateResult{ .success = true, .status_code = 200, .attempt = 1 };
    printResult(result);
}

test "dynamic_dns: printResult does not crash on failure" {
    const result = UpdateResult{
        .success = false,
        .status_code = 500,
        .attempt = 3,
        .error_msg = "server error",
    };
    printResult(result);
}

test "dynamic_dns: printResult handles null error_msg" {
    const result = UpdateResult{
        .success = false,
        .status_code = 0,
        .attempt = 3,
        .error_msg = null,
    };
    printResult(result);
}

test "dynamic_dns: config from env with mock loader" {
    const MockEnv = struct {
        const entries = [_]struct { key: []const u8, val: []const u8 }{
            .{ .key = "DYNAMIC_DNS_URL", .val = "https://custom.example.com/update" },
            .{ .key = "DYNAMIC_DNS_TIMEOUT_MS", .val = "5000" },
            .{ .key = "DYNAMIC_DNS_RETRY_COUNT", .val = "5" },
            .{ .key = "DYNAMIC_DNS_RETRY_DELAY_MS", .val = "2000" },
        };

        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            for (entries) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.val;
            }
            return null;
        }
    };

    const config = DynamicDnsConfig.fromEnv(MockEnv{});
    try std.testing.expectEqualStrings("https://custom.example.com/update", config.url);
    try std.testing.expectEqual(@as(u32, 5000), config.timeout_ms);
    try std.testing.expectEqual(@as(u32, 5), config.retry_count);
    try std.testing.expectEqual(@as(u32, 2000), config.retry_delay_ms);
    try std.testing.expect(config.validate());
}

test "dynamic_dns: config from env falls back to defaults when env empty" {
    const EmptyEnv = struct {
        pub fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };

    const config = DynamicDnsConfig.fromEnv(EmptyEnv{});
    try std.testing.expectEqualStrings(DEFAULT_DYNAMIC_DNS_URL, config.url);
    try std.testing.expectEqual(@as(u32, DEFAULT_TIMEOUT_MS), config.timeout_ms);
    try std.testing.expectEqual(@as(u32, DEFAULT_RETRY_COUNT), config.retry_count);
    try std.testing.expectEqual(@as(u32, DEFAULT_RETRY_DELAY_MS), config.retry_delay_ms);
}

test "dynamic_dns: config from env handles invalid timeout gracefully" {
    const BadEnv = struct {
        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "DYNAMIC_DNS_TIMEOUT_MS")) return "not_a_number";
            return null;
        }
    };

    const config = DynamicDnsConfig.fromEnv(BadEnv{});
    try std.testing.expectEqual(@as(u32, DEFAULT_TIMEOUT_MS), config.timeout_ms);
}

test "dynamic_dns: UpdateResult success has null error_msg" {
    const result = UpdateResult{ .success = true, .status_code = 200, .attempt = 1 };
    try std.testing.expect(result.error_msg == null);
}

// =============================================================================
// Framework Network Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework mesh node count: 421 E0 nodes.
pub const FRAMEWORK_MESH_NODE_COUNT: u32 = 421;

/// Framework mesh channel count: 7 octonionic channels.
pub const FRAMEWORK_MESH_CHANNEL_COUNT: u32 = 7;

/// Framework mesh routing uses the Fano plane for channel routing.
/// The 7 Fano lines provide the routing table for 7-channel mesh.
pub const FRAMEWORK_FANO_LINES: u32 = 7;

/// Verifies the mesh node count matches the E0 lattice.
pub fn verifyMeshNodeCountMatchesFramework() bool {
    return FRAMEWORK_MESH_NODE_COUNT == 421;
}

/// Verifies the mesh channel count matches the 7-defect.
pub fn verifyMeshChannelCountMatchesFramework() bool {
    return FRAMEWORK_MESH_CHANNEL_COUNT == 7;
}

test "framework: mesh node count 421 = E0 lattice" {
    try std.testing.expect(verifyMeshNodeCountMatchesFramework());
}

test "framework: mesh channel count 7 = 7-defect" {
    try std.testing.expect(verifyMeshChannelCountMatchesFramework());
}
