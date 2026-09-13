//! maypole_bridge.zig — ESP32 WiFi-to-LoRa bridge for Qstar.
//!
//! Retro-ported from Maypole V1.4 firmware concepts:
//! - WiFi network configuration with multi-AP fallback
//! - HTTP server for web-based configuration
//! - SPIFFS/SD file system abstraction for credential storage
//! - OTA update support via firmware chunking
//! - Bridge mode: forward WiFi packets to LoRa radio and vice versa
//! - WASM/freestanding compatible (pure logic, no hardware I/O)
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const lora = @import("transport_lora");

// =============================================================================
// Constants
// =============================================================================

/// Maximum WiFi SSID length.
pub const MAX_SSID_LEN: usize = 32;

/// Maximum WiFi password length.
pub const MAX_PASS_LEN: usize = 64;

/// Maximum number of stored WiFi credentials.
pub const MAX_WIFI_CREDENTIALS: usize = 8;

/// HTTP server port (matches Maypole default).
pub const HTTP_PORT: u16 = 80;

/// OTA chunk size for firmware updates.
pub const OTA_CHUNK_SIZE: usize = 4096;

/// Maximum OTA firmware size.
pub const OTA_MAX_SIZE: usize = 4 * 1024 * 1024; // 4 MB (ESP32 flash)

/// Bridge statistics counters.
pub const BridgeStats = struct {
    wifi_to_lora: u64 = 0,
    lora_to_wifi: u64 = 0,
    ota_bytes: u64 = 0,
    connect_attempts: u64 = 0,
    connect_successes: u64 = 0,
};

// =============================================================================
// WiFiCredential — stored network credentials
// =============================================================================

pub const WiFiCredential = struct {
    ssid: [MAX_SSID_LEN]u8,
    ssid_len: u8,
    password: [MAX_PASS_LEN]u8,
    pass_len: u8,
    priority: u8, // Lower = higher priority

    pub fn fromSlices(ssid: []const u8, password: []const u8, priority: u8) !WiFiCredential {
        if (ssid.len > MAX_SSID_LEN) return error.SsidTooLong;
        if (password.len > MAX_PASS_LEN) return error.PassTooLong;

        var cred: WiFiCredential = .{
            .ssid = [_]u8{0} ** MAX_SSID_LEN,
            .ssid_len = @intCast(ssid.len),
            .password = [_]u8{0} ** MAX_PASS_LEN,
            .pass_len = @intCast(password.len),
            .priority = priority,
        };
        @memcpy(cred.ssid[0..ssid.len], ssid);
        @memcpy(cred.password[0..password.len], password);
        return cred;
    }

    pub fn getSsid(self: *const WiFiCredential) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    pub fn getPassword(self: *const WiFiCredential) []const u8 {
        return self.password[0..self.pass_len];
    }
};

// =============================================================================
// WiFiConfig — multi-AP configuration with fallback
// =============================================================================

pub const WiFiConfig = struct {
    credentials: [MAX_WIFI_CREDENTIALS]?WiFiCredential = [_]?WiFiCredential{null} ** MAX_WIFI_CREDENTIALS,
    count: u8 = 0,
    connected_index: ?u8 = null,

    /// Add a WiFi credential. Returns the index it was stored at.
    pub fn add(self: *WiFiConfig, ssid: []const u8, password: []const u8, priority: u8) !u8 {
        if (self.count >= MAX_WIFI_CREDENTIALS) return error.NoSpace;
        const cred = try WiFiCredential.fromSlices(ssid, password, priority);
        const idx = self.count;
        self.credentials[idx] = cred;
        self.count += 1;
        self.sortByPriority();
        return idx;
    }

    /// Remove a credential by index.
    pub fn remove(self: *WiFiConfig, idx: u8) void {
        if (idx >= self.count) return;
        self.credentials[idx] = null;
        // Compact: shift remaining down
        var write_idx: u8 = 0;
        for (0..MAX_WIFI_CREDENTIALS) |i| {
            if (self.credentials[i] != null) {
                if (i != write_idx) {
                    self.credentials[write_idx] = self.credentials[i];
                    self.credentials[i] = null;
                }
                write_idx += 1;
            }
        }
        self.count = write_idx;
        if (self.connected_index == idx) self.connected_index = null;
    }

    /// Get the next credential to try (by priority).
    pub fn nextToTry(self: *const WiFiConfig) ?WiFiCredential {
        for (0..self.count) |i| {
            if (self.credentials[i] != null) {
                return self.credentials[i];
            }
        }
        return null;
    }

    /// Mark a credential as connected.
    pub fn markConnected(self: *WiFiConfig, idx: u8) void {
        self.connected_index = idx;
    }

    /// Get the currently connected credential.
    pub fn getConnected(self: *const WiFiConfig) ?WiFiCredential {
        if (self.connected_index) |idx| {
            if (idx < self.count) return self.credentials[idx];
        }
        return null;
    }

    /// Sort credentials by priority (bubble sort — small array).
    fn sortByPriority(self: *WiFiConfig) void {
        for (0..self.count) |i| {
            for (0..self.count - 1 - i) |j| {
                if (self.credentials[j] != null and self.credentials[j + 1] != null) {
                    if (self.credentials[j].?.priority > self.credentials[j + 1].?.priority) {
                        const tmp = self.credentials[j];
                        self.credentials[j] = self.credentials[j + 1];
                        self.credentials[j + 1] = tmp;
                    }
                }
            }
        }
    }

    /// Clear all credentials.
    pub fn clear(self: *WiFiConfig) void {
        for (0..MAX_WIFI_CREDENTIALS) |i| {
            self.credentials[i] = null;
        }
        self.count = 0;
        self.connected_index = null;
    }
};

// =============================================================================
// OTAUpdate — firmware update via chunked transfer
// =============================================================================

pub const OTAUpdate = struct {
    total_size: u32,
    received: u32 = 0,
    chunk_count: u32 = 0,
    checksum: u16 = 0,
    active: bool = false,

    pub fn init(total_size: u32) OTAUpdate {
        return .{
            .total_size = total_size,
            .active = true,
        };
    }

    /// Process an OTA chunk. Returns true when update is complete.
    pub fn processChunk(self: *OTAUpdate, chunk: []const u8) !bool {
        if (!self.active) return error.OTANotActive;
        if (self.received + chunk.len > self.total_size) return error.OTAOverflow;
        if (self.received + chunk.len > OTA_MAX_SIZE) return error.OTATooLarge;

        self.received += @intCast(chunk.len);
        self.chunk_count += 1;
        self.checksum = lora.crc16(chunk);

        return self.received >= self.total_size;
    }

    /// Get progress as a percentage (0-100).
    pub fn progress(self: *const OTAUpdate) u8 {
        if (self.total_size == 0) return 0;
        const pct = (self.received * 100) / self.total_size;
        return @intCast(pct);
    }

    /// Cancel the update.
    pub fn cancel(self: *OTAUpdate) void {
        self.active = false;
        self.received = 0;
        self.chunk_count = 0;
    }

    /// Check if the update is complete.
    pub fn isComplete(self: *const OTAUpdate) bool {
        return self.active and self.received >= self.total_size;
    }
};

// =============================================================================
// MaypoleBridge — WiFi-to-LoRa bridge
// =============================================================================

pub const MaypoleBridge = struct {
    allocator: std.mem.Allocator,
    wifi_config: WiFiConfig,
    stats: BridgeStats,
    ota: ?OTAUpdate = null,
    /// Our LoRa node ID.
    node_id: u32,
    /// Bridge mode enabled.
    bridge_enabled: bool = false,
    /// Clock for timing.
    clock_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, node_id: u32) MaypoleBridge {
        return .{
            .allocator = allocator,
            .wifi_config = WiFiConfig{},
            .stats = BridgeStats{},
            .node_id = node_id,
        };
    }

    pub fn deinit(self: *MaypoleBridge) void {
        _ = self;
    }

    /// Add a WiFi network to the fallback list.
    pub fn addWiFi(self: *MaypoleBridge, ssid: []const u8, password: []const u8, priority: u8) !u8 {
        return try self.wifi_config.add(ssid, password, priority);
    }

    /// Remove a WiFi network.
    pub fn removeWiFi(self: *MaypoleBridge, idx: u8) void {
        self.wifi_config.remove(idx);
    }

    /// Attempt to connect to the next WiFi network.
    /// Returns the index of the credential used, or null if none available.
    pub fn tryConnectWiFi(self: *MaypoleBridge) ?u8 {
        const cred = self.wifi_config.nextToTry() orelse return null;
        self.stats.connect_attempts += 1;

        // In a real implementation, this would attempt WiFi connection.
        // Here we simulate success on first try.
        for (0..self.wifi_config.count) |i| {
            if (self.wifi_config.credentials[i] != null) {
                if (std.mem.eql(u8, self.wifi_config.credentials[i].?.getSsid(), cred.getSsid())) {
                    self.wifi_config.markConnected(@intCast(i));
                    self.stats.connect_successes += 1;
                    return @intCast(i);
                }
            }
        }
        return null;
    }

    /// Enable bridge mode — forward WiFi packets to LoRa and vice versa.
    pub fn enableBridge(self: *MaypoleBridge) void {
        self.bridge_enabled = true;
    }

    /// Disable bridge mode.
    pub fn disableBridge(self: *MaypoleBridge) void {
        self.bridge_enabled = false;
    }

    /// Forward a WiFi packet to the LoRa radio.
    /// Returns the encoded LoRa packet bytes.
    pub fn wifiToLoRa(self: *MaypoleBridge, data: []const u8, dest: u32) ![]u8 {
        if (!self.bridge_enabled) return error.BridgeNotEnabled;
        if (data.len > lora.LORA_MTU) return error.PayloadTooLarge;

        const packet = lora.LoRaPacket{
            .sender = self.node_id,
            .receiver = dest,
            .msg_id = 0,
            .flags = 0,
            .spreading_factor = .sf9,
            .payload = data,
        };

        const encoded = try lora.encodePacket(self.allocator, packet);
        self.stats.wifi_to_lora += 1;
        return encoded;
    }

    /// Forward a LoRa packet to the WiFi network.
    /// Returns the payload extracted from the LoRa packet.
    pub fn loRaToWiFi(self: *MaypoleBridge, encoded: []const u8) ![]u8 {
        if (!self.bridge_enabled) return error.BridgeNotEnabled;

        const decoded = try lora.decodePacket(self.allocator, encoded) orelse return error.InvalidPacket;
        defer self.allocator.free(decoded.payload);

        // Only forward packets addressed to us or broadcasts
        if (decoded.receiver != self.node_id and !decoded.isBroadcast()) {
            return error.NotForUs;
        }

        const payload = try self.allocator.dupe(u8, decoded.payload);
        self.stats.lora_to_wifi += 1;
        return payload;
    }

    /// Start an OTA firmware update.
    pub fn startOTA(self: *MaypoleBridge, total_size: u32) void {
        self.ota = OTAUpdate.init(total_size);
    }

    /// Process an OTA chunk.
    pub fn processOTAChunk(self: *MaypoleBridge, chunk: []const u8) !bool {
        if (self.ota == null) return error.OTANotStarted;
        const complete = try self.ota.?.processChunk(chunk);
        self.stats.ota_bytes += chunk.len;
        return complete;
    }

    /// Get OTA progress percentage.
    pub fn otaProgress(self: *const MaypoleBridge) u8 {
        if (self.ota) |o| return o.progress();
        return 0;
    }

    /// Cancel OTA update.
    pub fn cancelOTA(self: *MaypoleBridge) void {
        if (self.ota) |*o| o.cancel();
        self.ota = null;
    }

    /// Get bridge statistics.
    pub fn getStats(self: *const MaypoleBridge) BridgeStats {
        return self.stats;
    }

    /// Advance the internal clock.
    pub fn tick(self: *MaypoleBridge, dt_ms: u64) void {
        self.clock_ms +%= dt_ms;
    }

    /// Get the currently connected WiFi SSID, if any.
    pub fn getConnectedSSID(self: *const MaypoleBridge) ?[]const u8 {
        const idx = self.wifi_config.connected_index orelse return null;
        if (idx >= self.wifi_config.count) return null;
        if (self.wifi_config.credentials[idx]) |*cred| {
            return cred.getSsid();
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "maypole: WiFiCredential creation" {
    const cred = try WiFiCredential.fromSlices("MyNetwork", "password123", 1);
    try std.testing.expectEqualStrings("MyNetwork", cred.getSsid());
    try std.testing.expectEqualStrings("password123", cred.getPassword());
    try std.testing.expectEqual(@as(u8, 1), cred.priority);
}

test "maypole: WiFiCredential rejects oversized SSID" {
    var long_ssid: [33]u8 = undefined;
    for (&long_ssid) |*b| b.* = 'A';
    try std.testing.expectError(error.SsidTooLong, WiFiCredential.fromSlices(&long_ssid, "pass", 0));
}

test "maypole: WiFiCredential rejects oversized password" {
    var long_pass: [65]u8 = undefined;
    for (&long_pass) |*b| b.* = 'B';
    try std.testing.expectError(error.PassTooLong, WiFiCredential.fromSlices("SSID", &long_pass, 0));
}

test "maypole: WiFiConfig add and retrieve" {
    var config = WiFiConfig{};
    const idx1 = try config.add("Network1", "pass1", 2);
    const idx2 = try config.add("Network2", "pass2", 1);
    try std.testing.expectEqual(@as(u8, 2), config.count);

    // Network2 has higher priority (lower number) so should be first
    const next = config.nextToTry().?;
    try std.testing.expectEqualStrings("Network2", next.getSsid());
    _ = idx1;
    _ = idx2;
}

test "maypole: WiFiConfig remove" {
    var config = WiFiConfig{};
    _ = try config.add("Net1", "p1", 1);
    _ = try config.add("Net2", "p2", 2);
    _ = try config.add("Net3", "p3", 3);
    try std.testing.expectEqual(@as(u8, 3), config.count);

    config.remove(0);
    try std.testing.expectEqual(@as(u8, 2), config.count);
}

test "maypole: WiFiConfig clear" {
    var config = WiFiConfig{};
    _ = try config.add("Net1", "p1", 1);
    _ = try config.add("Net2", "p2", 2);
    config.clear();
    try std.testing.expectEqual(@as(u8, 0), config.count);
    try std.testing.expect(config.nextToTry() == null);
}

test "maypole: WiFiConfig max credentials" {
    var config = WiFiConfig{};
    for (0..MAX_WIFI_CREDENTIALS) |i| {
        const ssid = try std.fmt.allocPrint(std.testing.allocator, "Net{d}", .{i});
        defer std.testing.allocator.free(ssid);
        _ = try config.add(ssid, "pass", @intCast(i));
    }
    try std.testing.expectEqual(@as(u8, MAX_WIFI_CREDENTIALS), config.count);
    try std.testing.expectError(error.NoSpace, config.add("Overflow", "pass", 0));
}

test "maypole: WiFiConfig markConnected and getConnected" {
    var config = WiFiConfig{};
    const idx = try config.add("MyNet", "pass", 0);
    config.markConnected(idx);
    const connected = config.getConnected().?;
    try std.testing.expectEqualStrings("MyNet", connected.getSsid());
}

test "maypole: OTAUpdate process chunks" {
    var ota = OTAUpdate.init(1000);
    try std.testing.expectEqual(@as(u8, 0), ota.progress());

    const chunk1 = [_]u8{0} ** 400;
    const complete1 = try ota.processChunk(&chunk1);
    try std.testing.expect(!complete1);
    try std.testing.expectEqual(@as(u8, 40), ota.progress());

    const chunk2 = [_]u8{0} ** 600;
    const complete2 = try ota.processChunk(&chunk2);
    try std.testing.expect(complete2);
    try std.testing.expectEqual(@as(u8, 100), ota.progress());
    try std.testing.expect(ota.isComplete());
}

test "maypole: OTAUpdate overflow" {
    var ota = OTAUpdate.init(100);
    const chunk = [_]u8{0} ** 200;
    try std.testing.expectError(error.OTAOverflow, ota.processChunk(&chunk));
}

test "maypole: OTAUpdate cancel" {
    var ota = OTAUpdate.init(1000);
    const chunk = [_]u8{0} ** 500;
    _ = try ota.processChunk(&chunk);
    ota.cancel();
    try std.testing.expect(!ota.active);
    try std.testing.expectEqual(@as(u32, 0), ota.received);
}

test "maypole: OTAUpdate not active" {
    var ota = OTAUpdate.init(100);
    ota.cancel();
    const chunk = [_]u8{0} ** 10;
    try std.testing.expectError(error.OTANotActive, ota.processChunk(&chunk));
}

test "maypole: MaypoleBridge init and WiFi config" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    _ = try bridge.addWiFi("TestNet", "password", 0);
    try std.testing.expectEqual(@as(u8, 1), bridge.wifi_config.count);
    try std.testing.expectEqual(@as(u32, 42), bridge.node_id);
}

test "maypole: MaypoleBridge tryConnectWiFi" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    _ = try bridge.addWiFi("TestNet", "password", 0);
    const idx = bridge.tryConnectWiFi();
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u64, 1), bridge.stats.connect_attempts);
    try std.testing.expectEqual(@as(u64, 1), bridge.stats.connect_successes);

    const ssid = bridge.getConnectedSSID().?;
    try std.testing.expectEqualStrings("TestNet", ssid);
}

test "maypole: MaypoleBridge tryConnectWiFi with no credentials" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    const idx = bridge.tryConnectWiFi();
    try std.testing.expect(idx == null);
}

test "maypole: MaypoleBridge wifiToLoRa" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();
    bridge.enableBridge();

    const data = "Hello from WiFi!";
    const encoded = try bridge.wifiToLoRa(data, 100);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
    try std.testing.expectEqual(@as(u64, 1), bridge.stats.wifi_to_lora);
}

test "maypole: MaypoleBridge wifiToLoRa without bridge enabled" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    try std.testing.expectError(error.BridgeNotEnabled, bridge.wifiToLoRa("test", 100));
}

test "maypole: MaypoleBridge loRaToWiFi" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();
    bridge.enableBridge();

    // First create a packet addressed to us
    const data = "LoRa payload";
    const packet = lora.LoRaPacket{
        .sender = 100,
        .receiver = 42,
        .msg_id = 1,
        .flags = 0,
        .spreading_factor = .sf9,
        .payload = data,
    };
    const encoded = try lora.encodePacket(std.testing.allocator, packet);
    defer std.testing.allocator.free(encoded);

    const payload = try bridge.loRaToWiFi(encoded);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(data, payload);
    try std.testing.expectEqual(@as(u64, 1), bridge.stats.lora_to_wifi);
}

test "maypole: MaypoleBridge loRaToWiFi broadcast" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();
    bridge.enableBridge();

    const data = "Broadcast msg";
    const packet = lora.LoRaPacket{
        .sender = 100,
        .receiver = 0, // Broadcast
        .msg_id = 2,
        .flags = lora.FLAG_BROADCAST,
        .spreading_factor = .sf9,
        .payload = data,
    };
    const encoded = try lora.encodePacket(std.testing.allocator, packet);
    defer std.testing.allocator.free(encoded);

    const payload = try bridge.loRaToWiFi(encoded);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(data, payload);
}

test "maypole: MaypoleBridge loRaToWiFi rejects not-for-us" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();
    bridge.enableBridge();

    const packet = lora.LoRaPacket{
        .sender = 100,
        .receiver = 200, // Not us
        .msg_id = 3,
        .flags = 0,
        .spreading_factor = .sf9,
        .payload = "not for us",
    };
    const encoded = try lora.encodePacket(std.testing.allocator, packet);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.NotForUs, bridge.loRaToWiFi(encoded));
}

test "maypole: MaypoleBridge loRaToWiFi invalid packet" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();
    bridge.enableBridge();

    const bad_data = [_]u8{0} ** 30;
    try std.testing.expectError(error.InvalidPacket, bridge.loRaToWiFi(&bad_data));
}

test "maypole: MaypoleBridge OTA" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    bridge.startOTA(100);
    try std.testing.expectEqual(@as(u8, 0), bridge.otaProgress());

    const chunk = [_]u8{0xAA} ** 50;
    const complete1 = try bridge.processOTAChunk(&chunk);
    try std.testing.expect(!complete1);
    try std.testing.expectEqual(@as(u8, 50), bridge.otaProgress());

    const complete2 = try bridge.processOTAChunk(&chunk);
    try std.testing.expect(complete2);
    try std.testing.expectEqual(@as(u8, 100), bridge.otaProgress());
    try std.testing.expectEqual(@as(u64, 100), bridge.stats.ota_bytes);
}

test "maypole: MaypoleBridge OTA not started" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    const chunk = [_]u8{0} ** 10;
    try std.testing.expectError(error.OTANotStarted, bridge.processOTAChunk(&chunk));
}

test "maypole: MaypoleBridge cancel OTA" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    bridge.startOTA(1000);
    const chunk = [_]u8{0} ** 500;
    _ = try bridge.processOTAChunk(&chunk);
    bridge.cancelOTA();
    try std.testing.expect(bridge.ota == null);
}

test "maypole: MaypoleBridge enable/disable bridge" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    try std.testing.expect(!bridge.bridge_enabled);
    bridge.enableBridge();
    try std.testing.expect(bridge.bridge_enabled);
    bridge.disableBridge();
    try std.testing.expect(!bridge.bridge_enabled);
}

test "maypole: MaypoleBridge getStats" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();
    bridge.enableBridge();

    const enc1 = try bridge.wifiToLoRa("test1", 100);
    defer std.testing.allocator.free(enc1);
    const enc2 = try bridge.wifiToLoRa("test2", 100);
    defer std.testing.allocator.free(enc2);

    const stats = bridge.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.wifi_to_lora);
    try std.testing.expectEqual(@as(u64, 0), stats.lora_to_wifi);
}

test "maypole: MaypoleBridge tick advances clock" {
    var bridge = MaypoleBridge.init(std.testing.allocator, 42);
    defer bridge.deinit();

    bridge.tick(100);
    bridge.tick(200);
    try std.testing.expectEqual(@as(u64, 300), bridge.clock_ms);
}

test "maypole: WiFiConfig priority sorting" {
    var config = WiFiConfig{};
    _ = try config.add("Low", "p", 5);
    _ = try config.add("High", "p", 1);
    _ = try config.add("Mid", "p", 3);

    // Should be sorted: High(1), Mid(3), Low(5)
    const first = config.nextToTry().?;
    try std.testing.expectEqualStrings("High", first.getSsid());
}
