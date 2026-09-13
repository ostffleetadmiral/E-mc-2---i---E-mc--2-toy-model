const std = @import("std");

// =============================================================================
// Feed Manager — Layer registration, lifecycle, state tracking
// =============================================================================
// Manages live data feed layers (flights, vessels, satellites, earthquakes,
// traffic, CCTV). Each layer has a state machine: nominal → loading → degraded
// → stale → unavailable. Pure Zig, no external dependencies.

pub const FeedState = enum {
    unavailable,
    loading,
    nominal,
    degraded,
    stale,
};

pub const LayerType = enum {
    flights,
    vessels,
    satellites,
    earthquakes,
    traffic,
    cctv,
};

pub const FeedStats = struct {
    item_count: usize = 0,
    last_fetch_time: f64 = 0,
    fetch_count: u32 = 0,
    error_count: u32 = 0,
    avg_fetch_ms: f64 = 0,
};

pub const FeedEntry = struct {
    id: LayerType,
    name: []const u8,
    state: FeedState,
    enabled: bool,
    stats: FeedStats,
    last_update: f64 = 0,
    poll_interval_ms: u32 = 10_000, // default 10s

    pub fn init(id: LayerType, name: []const u8) FeedEntry {
        return .{
            .id = id,
            .name = name,
            .state = .unavailable,
            .enabled = false,
            .stats = .{},
            .last_update = 0,
        };
    }
};

pub const FeedManager = struct {
    allocator: std.mem.Allocator,
    layers: std.AutoHashMap(LayerType, FeedEntry),
    current_time: f64 = 0,

    pub fn init(allocator: std.mem.Allocator) FeedManager {
        return .{
            .allocator = allocator,
            .layers = std.AutoHashMap(LayerType, FeedEntry).init(allocator),
        };
    }

    pub fn deinit(self: *FeedManager) void {
        self.layers.deinit();
    }

    pub fn registerLayer(self: *FeedManager, layer_type: LayerType, name: []const u8) !void {
        const entry = FeedEntry.init(layer_type, name);
        try self.layers.put(layer_type, entry);
    }

    pub fn enableLayer(self: *FeedManager, layer_type: LayerType) !void {
        var entry = self.layers.get(layer_type) orelse return error.LayerNotFound;
        entry.enabled = true;
        entry.state = .loading;
        try self.layers.put(layer_type, entry);
    }

    pub fn disableLayer(self: *FeedManager, layer_type: LayerType) void {
        var entry = self.layers.get(layer_type) orelse return;
        entry.enabled = false;
        entry.state = .unavailable;
        self.layers.put(layer_type, entry) catch {};
    }

    pub fn isLayerEnabled(self: *FeedManager, layer_type: LayerType) bool {
        if (self.layers.get(layer_type)) |entry| {
            return entry.enabled;
        }
        return false;
    }

    pub fn getLayerState(self: *FeedManager, layer_type: LayerType) FeedState {
        if (self.layers.get(layer_type)) |entry| {
            return entry.state;
        }
        return .unavailable;
    }

    pub fn getLayerStats(self: *FeedManager, layer_type: LayerType) ?FeedStats {
        if (self.layers.get(layer_type)) |entry| {
            return entry.stats;
        }
        return null;
    }

    /// Update layer state after a fetch attempt
    pub fn updateLayerResult(self: *FeedManager, layer_type: LayerType, success: bool, item_count: usize, fetch_ms: f64) void {
        var entry = self.layers.get(layer_type) orelse return;
        entry.stats.fetch_count += 1;
        entry.stats.item_count = item_count;
        entry.stats.last_fetch_time = self.current_time;
        entry.last_update = self.current_time;

        // Update rolling average fetch time
        if (entry.stats.fetch_count == 1) {
            entry.stats.avg_fetch_ms = fetch_ms;
        } else {
            entry.stats.avg_fetch_ms = (entry.stats.avg_fetch_ms * 0.9) + (fetch_ms * 0.1);
        }

        if (success) {
            entry.state = if (item_count > 0) .nominal else .degraded;
        } else {
            entry.stats.error_count += 1;
            entry.state = if (entry.stats.error_count > 3) .unavailable else .degraded;
        }

        self.layers.put(layer_type, entry) catch {};
    }

    /// Check for stale layers (no update within 2x poll interval)
    pub fn refreshStates(self: *FeedManager) void {
        var it = self.layers.iterator();
        while (it.next()) |kv| {
            var entry = kv.value_ptr.*;
            if (!entry.enabled) continue;
            if (entry.state == .unavailable) continue;

            const elapsed = self.current_time - entry.last_update;
            const stale_threshold = @as(f64, @floatFromInt(entry.poll_interval_ms)) * 2.0 / 1000.0;

            if (elapsed > stale_threshold and entry.state == .nominal) {
                entry.state = .stale;
                self.layers.put(kv.key_ptr.*, entry) catch {};
            }
        }
    }

    pub fn tick(self: *FeedManager, dt: f64) void {
        self.current_time += dt;
        self.refreshStates();
    }

    /// Get summary of all layers as JSON string
    pub fn getStatsJson(self: *FeedManager, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try buf.appendSlice("{\"layers\":[");
        var first = true;
        var it = self.layers.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (!first) try buf.appendSlice(",");
            first = false;
            try std.fmt.format(buf.writer(), "{{\"id\":\"{s}\",\"name\":\"{s}\",\"state\":\"{s}\",\"enabled\":{},\"items\":{d},\"errors\":{d}}}", .{
                @tagName(entry.id),
                entry.name,
                @tagName(entry.state),
                entry.enabled,
                entry.stats.item_count,
                entry.stats.error_count,
            });
        }
        try buf.appendSlice("]}");
        return buf.toOwnedSlice();
    }

    pub fn getEnabledLayers(self: *FeedManager, allocator: std.mem.Allocator) ![]LayerType {
        var result = std.ArrayList(LayerType).init(allocator);
        var it = self.layers.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.enabled) {
                try result.append(kv.key_ptr.*);
            }
        }
        return result.toOwnedSlice();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "live_feeds: register and enable layer" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.flights, "OpenSky Flights");
    try std.testing.expectEqual(FeedState.unavailable, fm.getLayerState(.flights));

    try fm.enableLayer(.flights);
    try std.testing.expect(fm.isLayerEnabled(.flights));
    try std.testing.expectEqual(FeedState.loading, fm.getLayerState(.flights));
}

test "live_feeds: disable layer" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.vessels, "AIS Vessels");
    try fm.enableLayer(.vessels);
    try std.testing.expect(fm.isLayerEnabled(.vessels));

    fm.disableLayer(.vessels);
    try std.testing.expect(!fm.isLayerEnabled(.vessels));
    try std.testing.expectEqual(FeedState.unavailable, fm.getLayerState(.vessels));
}

test "live_feeds: successful fetch transitions to nominal" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.flights, "Flights");
    try fm.enableLayer(.flights);

    fm.updateLayerResult(.flights, true, 150, 250.0);
    try std.testing.expectEqual(FeedState.nominal, fm.getLayerState(.flights));

    const stats = fm.getLayerStats(.flights).?;
    try std.testing.expectEqual(@as(usize, 150), stats.item_count);
    try std.testing.expectEqual(@as(u32, 1), stats.fetch_count);
    try std.testing.expectEqual(@as(u32, 0), stats.error_count);
}

test "live_feeds: empty result transitions to degraded" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.earthquakes, "USGS");
    try fm.enableLayer(.earthquakes);

    fm.updateLayerResult(.earthquakes, true, 0, 100.0);
    try std.testing.expectEqual(FeedState.degraded, fm.getLayerState(.earthquakes));
}

test "live_feeds: repeated errors transition to unavailable" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.traffic, "TomTom");
    try fm.enableLayer(.traffic);

    fm.updateLayerResult(.traffic, false, 0, 5000.0);
    try std.testing.expectEqual(FeedState.degraded, fm.getLayerState(.traffic));

    fm.updateLayerResult(.traffic, false, 0, 5000.0);
    fm.updateLayerResult(.traffic, false, 0, 5000.0);
    fm.updateLayerResult(.traffic, false, 0, 5000.0);
    try std.testing.expectEqual(FeedState.unavailable, fm.getLayerState(.traffic));
}

test "live_feeds: stale detection after timeout" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.satellites, "Celestrak");
    try fm.enableLayer(.satellites);
    fm.layers.getPtr(.satellites).?.poll_interval_ms = 1000; // 1 second

    fm.updateLayerResult(.satellites, true, 50, 200.0);
    try std.testing.expectEqual(FeedState.nominal, fm.getLayerState(.satellites));

    // Advance time past stale threshold (2x poll interval = 2 seconds)
    fm.tick(3.0);
    try std.testing.expectEqual(FeedState.stale, fm.getLayerState(.satellites));
}

test "live_feeds: getEnabledLayers" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.flights, "Flights");
    try fm.registerLayer(.vessels, "Vessels");
    try fm.registerLayer(.cctv, "CCTV");

    try fm.enableLayer(.flights);
    try fm.enableLayer(.cctv);

    const enabled = try fm.getEnabledLayers(allocator);
    defer allocator.free(enabled);

    try std.testing.expectEqual(@as(usize, 2), enabled.len);
}

test "live_feeds: getStatsJson produces valid JSON" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.flights, "Flights");
    try fm.enableLayer(.flights);
    fm.updateLayerResult(.flights, true, 42, 150.0);

    const json = try fm.getStatsJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "{\"layers\":["));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Flights\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"items\":42") != null);
}

test "live_feeds: rolling average fetch time" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try fm.registerLayer(.flights, "Flights");
    try fm.enableLayer(.flights);

    fm.updateLayerResult(.flights, true, 10, 100.0);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), fm.getLayerStats(.flights).?.avg_fetch_ms, 1e-6);

    fm.updateLayerResult(.flights, true, 10, 200.0);
    // 100*0.9 + 200*0.1 = 110
    try std.testing.expectApproxEqAbs(@as(f64, 110.0), fm.getLayerStats(.flights).?.avg_fetch_ms, 1e-6);
}

test "live_feeds: enable non-existent layer returns error" {
    const allocator = std.testing.allocator;
    var fm = FeedManager.init(allocator);
    defer fm.deinit();

    try std.testing.expectError(error.LayerNotFound, fm.enableLayer(.flights));
}
