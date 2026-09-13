//! env_loader.zig — Zero-dependency .env file loader.
//!
//! Parses KEY=VALUE lines from a .env file. Real environment variables
//! take precedence over .env file values. Supports:
//!   - '#' comments and blank lines
//!   - Quoted values ("..." or '...')
//!   - CRLF and LF line endings
//!   - Whitespace trimming around keys and values
//!
//! Used to load OPENAI_API_KEY (and other secrets) without hardcoding them.

const std = @import("std");

pub const EnvLoader = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) EnvLoader {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *EnvLoader) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Loads a .env file from disk. Missing file is not an error.
    pub fn loadFile(self: *EnvLoader, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 4 * 1024 * 1024);
        defer self.allocator.free(content);
        try self.parse(content);
    }

    /// Parses .env content from a buffer.
    pub fn parse(self: *EnvLoader, content: []const u8) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |raw_line| {
            // Strip trailing \r (CRLF support)
            const line = std.mem.trimRight(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            if (key.len == 0) continue;
            var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Strip surrounding quotes
            if (value.len >= 2 and
                ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
            {
                value = value[1 .. value.len - 1];
            }

            // Skip if the real environment already defines this key
            if (std.process.getEnvVarOwned(self.allocator, key)) |env_val| {
                self.allocator.free(env_val);
                continue;
            } else |_| {}

            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            const gop = try self.entries.getOrPut(key_copy);
            if (gop.found_existing) {
                self.allocator.free(key_copy);
                self.allocator.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = value_copy;
        }
    }

    /// Returns the value for a key, or null if not found.
    /// Checks real environment first, then .env entries.
    /// The returned slice is borrowed (process env or loader-owned); do not free.
    pub fn get(self: *const EnvLoader, key: []const u8) ?[]const u8 {
        if (std.posix.getenv(key)) |env_val| return env_val;
        if (self.entries.get(key)) |value| return value;
        return null;
    }

    /// Returns true if a key is present (env or .env).
    pub fn has(self: *const EnvLoader, key: []const u8) bool {
        return self.get(key) != null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "env_loader: parses basic key=value" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("OPENAI_API_KEY=sk-test123\nFOO=bar\n");
    try std.testing.expectEqualStrings("sk-test123", loader.get("OPENAI_API_KEY").?);
    try std.testing.expectEqualStrings("bar", loader.get("FOO").?);
}

test "env_loader: skips comments and blank lines" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("# comment\n\nSECRET=abc\n   \n# another\n");
    try std.testing.expectEqualStrings("abc", loader.get("SECRET").?);
    try std.testing.expect(loader.get("comment") == null);
}

test "env_loader: strips surrounding quotes" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("A=\"quoted value\"\nB='single'\n");
    try std.testing.expectEqualStrings("quoted value", loader.get("A").?);
    try std.testing.expectEqualStrings("single", loader.get("B").?);
}

test "env_loader: handles CRLF line endings" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("KEY=value\r\nOTHER=x\r\n");
    try std.testing.expectEqualStrings("value", loader.get("KEY").?);
    try std.testing.expectEqualStrings("x", loader.get("OTHER").?);
}

test "env_loader: trims whitespace around key and value" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("  KEY  =  spaced value  \n");
    try std.testing.expectEqualStrings("spaced value", loader.get("KEY").?);
}

test "env_loader: ignores lines without equals" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("NOEQUALS\nKEY=val\n");
    try std.testing.expect(loader.get("NOEQUALS") == null);
    try std.testing.expectEqualStrings("val", loader.get("KEY").?);
}

test "env_loader: missing file is not an error" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.loadFile("/nonexistent/path/.env");
    try std.testing.expect(loader.get("ANYTHING") == null);
}

test "env_loader: duplicate keys overwrite" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("KEY=first\nKEY=second\n");
    try std.testing.expectEqualStrings("second", loader.get("KEY").?);
}

test "env_loader: has returns true/false" {
    const allocator = std.testing.allocator;
    var loader = EnvLoader.init(allocator);
    defer loader.deinit();
    try loader.parse("PRESENT=yes\n");
    try std.testing.expect(loader.has("PRESENT"));
    try std.testing.expect(!loader.has("ABSENT"));
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
