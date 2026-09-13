//! mesh.zig — Purified peer mesh: no server, no DHT, no blockchain.
//!
//! Extracted from freenet-core (#15) and RuView (#16).
//! Shared-face protocol, phase-locking, fallback chain.
//!
//! All async/tokio/libp2p/serde stripped — pure state machine.

const std = @import("std");
const fp = @import("fixed_point");

// ---------------------------------------------------------------------------
// Location — abstract 1D ring location on [0, 1)
// ---------------------------------------------------------------------------

pub const Location = struct {
    value: f64,

    pub fn new(v: f64) Location {
        return .{ .value = @mod(v, 1.0) };
    }

    pub fn fromBytes(data: []const u8) Location {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(data);
        const h = hasher.final();
        return .{ .value = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(std.math.maxInt(u64))) };
    }

    pub fn distance(self: Location, other: Location) f64 {
        const d = @abs(self.value - other.value);
        return if (d < 0.5) d else 1.0 - d;
    }

    pub fn signedDistance(self: Location, other: Location) f64 {
        const diff = other.value - self.value;
        if (diff > 0.5) return diff - 1.0;
        if (diff < -0.5) return diff + 1.0;
        return diff;
    }

    pub fn eql(self: Location, other: Location) bool {
        return self.value == other.value;
    }

    pub fn cmp(self: Location, other: Location) std.math.Order {
        return std.math.order(self.value, other.value);
    }
};

// ---------------------------------------------------------------------------
// Connection — a peer connection in the ring
// ---------------------------------------------------------------------------

pub const ConnectionState = enum {
    pending,
    established,
    transient,
    ready,
    disconnected,
};

pub const Connection = struct {
    id: u64,
    peer_addr: []const u8,
    location: Location,
    state: ConnectionState,
    connected_at_ms: u64,
    last_activity_ms: u64,

    pub fn isEstablished(self: Connection) bool {
        return self.state == .established or self.state == .ready;
    }

    pub fn isReady(self: Connection) bool {
        return self.state == .ready;
    }
};

// ---------------------------------------------------------------------------
// ConnectionManager — ring connection pool with min/max bounds
// ---------------------------------------------------------------------------

pub const DEFAULT_MIN_CONNECTIONS: usize = 25;
pub const DEFAULT_MAX_CONNECTIONS: usize = 200;
pub const LATTICE_OVERMAX_SLACK: usize = 2;

pub const ConnectionManager = struct {
    allocator: std.mem.Allocator,
    own_location: Location,
    connections: std.AutoHashMap(u64, Connection),
    addr_to_id: std.StringHashMap(u64),
    location_to_ids: std.AutoHashMap(u64, std.ArrayList(u64)),
    min_connections: usize,
    max_connections: usize,
    next_id: u64,
    is_gateway: bool,
    transient_budget: usize,
    transient_in_use: usize,
    ready_count: usize,
    min_ready_connections: usize,
    ban_list: std.AutoHashMap(u64, void),
    rate_limiter: RateLimiter,

    pub fn init(allocator: std.mem.Allocator, own_location: Location, min_conn: usize, max_conn: usize, is_gateway: bool) ConnectionManager {
        return .{
            .allocator = allocator,
            .own_location = own_location,
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            .addr_to_id = std.StringHashMap(u64).init(allocator),
            .location_to_ids = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .min_connections = min_conn,
            .max_connections = max_conn,
            .next_id = 1,
            .is_gateway = is_gateway,
            .transient_budget = 10,
            .transient_in_use = 0,
            .ready_count = 0,
            .min_ready_connections = 0,
            .ban_list = std.AutoHashMap(u64, void).init(allocator),
            .rate_limiter = RateLimiter.init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        var it_c = self.connections.iterator();
        while (it_c.next()) |entry| {
            self.allocator.free(entry.value_ptr.peer_addr);
        }
        self.connections.deinit();
        self.addr_to_id.deinit();
        var it = self.location_to_ids.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        self.location_to_ids.deinit();
        self.ban_list.deinit();
        self.rate_limiter.deinit();
    }

    pub fn connectionCount(self: *const ConnectionManager) usize {
        var count: usize = 0;
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isEstablished()) count += 1;
        }
        return count;
    }

    pub fn isBelowMin(self: *const ConnectionManager) bool {
        return self.connectionCount() < self.min_connections;
    }

    pub fn isAtMax(self: *const ConnectionManager) bool {
        return self.connectionCount() >= self.max_connections;
    }

    pub fn isOverMax(self: *const ConnectionManager) bool {
        return self.connectionCount() > self.max_connections;
    }

    /// Connect to a peer at the given address and location.
    /// Returns the connection ID, or null if rejected (banned, at capacity).
    pub fn connect(self: *ConnectionManager, addr: []const u8, loc: Location, now_ms: u64) !?u64 {
        const loc_key = locationKey(loc);

        if (self.ban_list.contains(loc_key)) return null;

        const current = self.connectionCount();
        if (current >= self.max_connections + LATTICE_OVERMAX_SLACK) return null;

        const id = self.next_id;
        self.next_id += 1;

        const addr_copy = try self.allocator.dupe(u8, addr);
        const conn = Connection{
            .id = id,
            .peer_addr = addr_copy,
            .location = loc,
            .state = .pending,
            .connected_at_ms = now_ms,
            .last_activity_ms = now_ms,
        };

        try self.connections.put(id, conn);
        try self.addr_to_id.put(addr_copy, id);

        const gop = try self.location_to_ids.getOrPut(loc_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        }
        try gop.value_ptr.append(id);

        return id;
    }

    /// Mark a connection as established (handshake complete).
    pub fn markEstablished(self: *ConnectionManager, id: u64) !void {
        if (self.connections.getPtr(id)) |conn| {
            if (conn.state == .pending) {
                conn.state = .established;
            }
        }
    }

    /// Mark a connection as ready (peer advertised readiness).
    pub fn markReady(self: *ConnectionManager, id: u64) !void {
        if (self.connections.getPtr(id)) |conn| {
            if (conn.state != .ready) {
                conn.state = .ready;
                self.ready_count += 1;
            }
        }
    }

    /// Mark a connection as not ready.
    pub fn markNotReady(self: *ConnectionManager, id: u64) void {
        if (self.connections.getPtr(id)) |conn| {
            if (conn.state == .ready) {
                conn.state = .established;
                self.ready_count -|= 1;
            }
        }
    }

    /// Check if this node itself is ready (has enough ready connections).
    pub fn isSelfReady(self: *const ConnectionManager) bool {
        return self.min_ready_connections == 0 or self.ready_count >= self.min_ready_connections;
    }

    /// Prune a connection by ID. Returns true if a connection was removed.
    pub fn prune(self: *ConnectionManager, id: u64) bool {
        const conn = self.connections.get(id) orelse return false;
        const loc_key = locationKey(conn.location);

        if (conn.state == .ready) self.ready_count -|= 1;

        _ = self.connections.remove(id);
        _ = self.addr_to_id.remove(conn.peer_addr);

        if (self.location_to_ids.getPtr(loc_key)) |list| {
            for (list.items, 0..) |item, i| {
                if (item == id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                list.deinit();
                _ = self.location_to_ids.remove(loc_key);
            }
        }

        self.allocator.free(conn.peer_addr);
        return true;
    }

    /// Prune the farthest connection when over capacity.
    /// Lattice edges (nearest successor/predecessor) are protected.
    pub fn pruneOverMax(self: *ConnectionManager) ?u64 {
        if (!self.isOverMax()) return null;

        var farthest_id: u64 = 0;
        var farthest_dist: f64 = -1.0;

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr.*;
            if (!conn.isEstablished()) continue;

            if (isLatticeEdge(self.own_location, conn.location, &self.connections)) continue;

            const d = self.own_location.distance(conn.location);
            if (d > farthest_dist) {
                farthest_dist = d;
                farthest_id = conn.id;
            }
        }

        if (farthest_id != 0) {
            _ = self.prune(farthest_id);
            return farthest_id;
        }
        return null;
    }

    /// Get all established connections sorted by ring distance.
    pub fn getConnectionsByDistance(self: *ConnectionManager, allocator: std.mem.Allocator) ![]Connection {
        var list = std.ArrayList(Connection).init(allocator);
        defer list.deinit();
        try list.ensureTotalCapacity(self.connections.count());

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isEstablished()) {
                try list.append(entry.value_ptr.*);
            }
        }

        std.mem.sort(Connection, list.items, self.own_location, struct {
            fn cmp(loc: Location, a: Connection, b: Connection) bool {
                return loc.distance(a.location) < loc.distance(b.location);
            }
        }.cmp);

        return try allocator.dupe(Connection, list.items);
    }

    /// Ban a contract/peer by location key.
    pub fn banContract(self: *ConnectionManager, loc: Location) !void {
        try self.ban_list.put(locationKey(loc), {});
    }

    /// Check if a location is banned.
    pub fn isBanned(self: *const ConnectionManager, loc: Location) bool {
        return self.ban_list.contains(locationKey(loc));
    }

    /// Check rate limit for a key.
    pub fn rateLimit(self: *ConnectionManager, key: u64, now_ms: u64) bool {
        return self.rate_limiter.allow(key, now_ms);
    }

    /// Performs a SAMC localized knot bypass route.
    /// Finds the optimal neighbor that minimizes distance to target_loc while
    /// bypassing congested or knot-tangled peer links.
    pub fn samcBypassRoute(self: *const ConnectionManager, target_loc: Location, exclude_knot_id: ?u64) ?Connection {
        var best_conn: ?Connection = null;
        var best_dist: f64 = std.math.inf(f64);

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (exclude_knot_id) |ex_id| {
                if (entry.key_ptr.* == ex_id) continue;
            }
            const conn = entry.value_ptr.*;
            if (!conn.isEstablished()) continue;

            const dist = conn.location.distance(target_loc);
            if (dist < best_dist) {
                best_dist = dist;
                best_conn = conn;
            }
        }

        return best_conn;
    }
};

fn locationKey(loc: Location) u64 {
    return @as(u64, @intFromFloat(loc.value * @as(f64, @floatFromInt(std.math.maxInt(u64)))));
}

/// Check if a connection is a nearest-neighbor lattice edge (successor or predecessor).
fn isLatticeEdge(own_loc: Location, candidate_loc: Location, connections: *const std.AutoHashMap(u64, Connection)) bool {
    const candidate_signed = own_loc.signedDistance(candidate_loc);
    var is_successor = candidate_signed > 0;
    var is_predecessor = candidate_signed < 0;

    var it = connections.iterator();
    while (it.next()) |entry| {
        const conn = entry.value_ptr.*;
        if (!conn.isEstablished()) continue;
        if (conn.location.eql(candidate_loc)) continue;

        const other_signed = own_loc.signedDistance(conn.location);

        if (candidate_signed > 0 and other_signed > 0 and other_signed < candidate_signed) {
            is_successor = false;
        }
        if (candidate_signed < 0 and other_signed < 0 and other_signed > candidate_signed) {
            is_predecessor = false;
        }
    }

    return is_successor or is_predecessor;
}

// ---------------------------------------------------------------------------
// RateLimiter — sliding window rate limiting
// ---------------------------------------------------------------------------

pub const RATE_WINDOW_MS: u64 = 1000;
pub const RATE_MAX_REQUESTS: u32 = 10;

pub const RateLimiter = struct {
    buckets: std.AutoHashMap(u64, Bucket),

    const Bucket = struct {
        count: u32,
        window_start: u64,
    };

    pub fn init(allocator: std.mem.Allocator) RateLimiter {
        return .{ .buckets = std.AutoHashMap(u64, Bucket).init(allocator) };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.buckets.deinit();
    }

    pub fn allow(self: *RateLimiter, key: u64, now_ms: u64) bool {
        const gop = self.buckets.getOrPut(key) catch return false;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .count = 1, .window_start = now_ms };
            return true;
        }

        if (now_ms - gop.value_ptr.window_start >= RATE_WINDOW_MS) {
            gop.value_ptr.count = 1;
            gop.value_ptr.window_start = now_ms;
            return true;
        }

        if (gop.value_ptr.count >= RATE_MAX_REQUESTS) return false;
        gop.value_ptr.count += 1;
        return true;
    }
};

// ---------------------------------------------------------------------------
// InterestSync — interest synchronization protocol
// ---------------------------------------------------------------------------

pub const Interest = struct {
    contract_key: u64,
    subscribed: bool,
};

pub const Summary = struct {
    contract_key: u64,
    version: u64,
    size: usize,
};

pub const Delta = struct {
    added: []Summary,
    removed: []u64,
};

pub const InterestSync = struct {
    allocator: std.mem.Allocator,
    interests: std.AutoHashMap(u64, bool),
    summaries: std.AutoHashMap(u64, Summary),

    pub fn init(allocator: std.mem.Allocator) InterestSync {
        return .{
            .allocator = allocator,
            .interests = std.AutoHashMap(u64, bool).init(allocator),
            .summaries = std.AutoHashMap(u64, Summary).init(allocator),
        };
    }

    pub fn deinit(self: *InterestSync) void {
        self.interests.deinit();
        self.summaries.deinit();
    }

    pub fn subscribe(self: *InterestSync, contract_key: u64) !void {
        try self.interests.put(contract_key, true);
    }

    pub fn unsubscribe(self: *InterestSync, contract_key: u64) void {
        _ = self.interests.remove(contract_key);
    }

    pub fn isSubscribed(self: *const InterestSync, contract_key: u64) bool {
        return self.interests.get(contract_key) orelse false;
    }

    /// Compute the delta between our interests and a peer's summaries.
    pub fn computeDelta(self: *InterestSync, peer_summaries: []const Summary) !Delta {
        var added = std.ArrayList(Summary).init(self.allocator);
        var removed = std.ArrayList(u64).init(self.allocator);
        try added.ensureTotalCapacity(peer_summaries.len);
        try removed.ensureTotalCapacity(self.summaries.count());

        var it = self.summaries.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            var found = false;
            for (peer_summaries) |ps| {
                if (ps.contract_key == key) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try removed.append(key);
            }
        }

        for (peer_summaries) |ps| {
            if (!self.summaries.contains(ps.contract_key)) {
                try added.append(ps);
            }
        }

        return .{
            .added = try added.toOwnedSlice(),
            .removed = try removed.toOwnedSlice(),
        };
    }

    /// Apply a delta to our summary store.
    pub fn applyDelta(self: *InterestSync, delta: Delta) !void {
        for (delta.added) |s| {
            try self.summaries.put(s.contract_key, s);
        }
        for (delta.removed) |key| {
            _ = self.summaries.remove(key);
        }
    }

    /// Exchange summaries with a peer and return the delta to apply.
    pub fn syncInterests(self: *InterestSync, peer_summaries: []const Summary) !Delta {
        return try self.computeDelta(peer_summaries);
    }

    /// Get all summaries for export to peers.
    pub fn getSummaries(self: *InterestSync, allocator: std.mem.Allocator) ![]Summary {
        var list = std.ArrayList(Summary).init(allocator);
        try list.ensureTotalCapacity(self.summaries.count());
        var it = self.summaries.iterator();
        while (it.next()) |entry| {
            try list.append(entry.value_ptr.*);
        }
        return try list.toOwnedSlice();
    }

    pub fn interestCount(self: *const InterestSync) usize {
        return self.interests.count();
    }

    pub fn summaryCount(self: *const InterestSync) usize {
        return self.summaries.count();
    }
};

// ---------------------------------------------------------------------------
// Bootstrap — initial peer discovery
// ---------------------------------------------------------------------------

pub const BootstrapResult = struct {
    connected: usize,
    failed: usize,
};

pub const GatewayPeer = struct {
    addr: []const u8,
    loc: Location,
};

/// Bootstrap by connecting to a list of gateway peers.
pub fn bootstrap(cm: *ConnectionManager, gateways: []const GatewayPeer, now_ms: u64) !BootstrapResult {
    var connected: usize = 0;
    var failed: usize = 0;

    for (gateways) |gw| {
        if (cm.isBanned(gw.loc)) {
            failed += 1;
            continue;
        }
        const result = try cm.connect(gw.addr, gw.loc, now_ms);
        if (result) |id| {
            try cm.markEstablished(id);
            connected += 1;
        } else {
            failed += 1;
        }
    }

    return .{ .connected = connected, .failed = failed };
}

// ---------------------------------------------------------------------------
// TopologyManager — small-world topology optimization
// ---------------------------------------------------------------------------

pub const TopologyAdjustment = union(enum) {
    no_change,
    add_connections: []Location,
    remove_connections: []u64,
    swap_connection: struct { remove: u64, add_location: Location },
};

pub const TopologyManager = struct {
    allocator: std.mem.Allocator,
    target_long_links: usize,
    hop_count_history: std.AutoHashMap(u64, u32),

    pub fn init(allocator: std.mem.Allocator) TopologyManager {
        return .{
            .allocator = allocator,
            .target_long_links = 4,
            .hop_count_history = std.AutoHashMap(u64, u32).init(allocator),
        };
    }

    pub fn deinit(self: *TopologyManager) void {
        self.hop_count_history.deinit();
    }

    /// Adjust topology based on current connections and target structure.
    /// Kleinberg small-world: keep nearest neighbors + k long links.
    pub fn adjustTopology(
        self: *TopologyManager,
        own_loc: Location,
        connections: []const Connection,
        min_conn: usize,
        max_conn: usize,
    ) !TopologyAdjustment {
        const established_count = countEstablished(connections);

        if (established_count < min_conn) {
            const needed = min_conn - established_count;
            var targets = try self.allocator.alloc(Location, needed);
            for (0..needed) |i| {
                const angle = @as(f64, @floatFromInt(i)) * 0.618033988749895;
                targets[i] = Location.new(own_loc.value + angle);
            }
            return .{ .add_connections = targets };
        }

        if (established_count > max_conn) {
            var to_remove = try self.allocator.alloc(u64, established_count - max_conn);
            const sorted = try self.allocator.dupe(Connection, connections);
            defer self.allocator.free(sorted);

            std.mem.sort(Connection, sorted, own_loc, struct {
                fn cmp(loc: Location, a: Connection, b: Connection) bool {
                    return loc.distance(a.location) > loc.distance(b.location);
                }
            }.cmp);

            var idx: usize = 0;
            for (sorted) |conn| {
                if (!conn.isEstablished()) continue;
                if (isLatticeEdgeSlice(own_loc, conn.location, sorted)) continue;
                to_remove[idx] = conn.id;
                idx += 1;
                if (idx >= to_remove.len) break;
            }

            if (idx == 0) {
                self.allocator.free(to_remove);
                return .no_change;
            }

            return .{ .remove_connections = to_remove[0..idx] };
        }

        return .no_change;
    }

    /// Record a routing hop count for a target.
    pub fn recordHopCount(self: *TopologyManager, target: u64, hops: u32) !void {
        try self.hop_count_history.put(target, hops);
    }

    /// Average hop count across all recorded routes.
    pub fn averageHopCount(self: *const TopologyManager) f64 {
        if (self.hop_count_history.count() == 0) return 0.0;
        var total: u64 = 0;
        var count: usize = 0;
        var it = self.hop_count_history.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.*;
            count += 1;
        }
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
    }
};

fn countEstablished(connections: []const Connection) usize {
    var count: usize = 0;
    for (connections) |c| {
        if (c.isEstablished()) count += 1;
    }
    return count;
}

fn isLatticeEdgeSlice(own_loc: Location, candidate_loc: Location, connections: []const Connection) bool {
    const candidate_signed = own_loc.signedDistance(candidate_loc);
    var is_successor = candidate_signed > 0;
    var is_predecessor = candidate_signed < 0;

    for (connections) |conn| {
        if (!conn.isEstablished()) continue;
        if (conn.location.eql(candidate_loc)) continue;

        const other_signed = own_loc.signedDistance(conn.location);

        if (candidate_signed > 0 and other_signed > 0 and other_signed < candidate_signed) is_successor = false;
        if (candidate_signed < 0 and other_signed < 0 and other_signed > candidate_signed) is_predecessor = false;
    }

    return is_successor or is_predecessor;
}

// ---------------------------------------------------------------------------
// PhaseLock — Smith chart impedance matching for lattice phase-locking
// ---------------------------------------------------------------------------

pub const PhaseLock = struct {
    own_phase: f64,
    peer_phase: f64,
    impedance: f64,
    locked: bool,

    /// Compute the phase difference on the unit circle.
    pub fn phaseDifference(self: PhaseLock) f64 {
        const diff = self.own_phase - self.peer_phase;
        return @mod(diff + std.math.pi, 2.0 * std.math.pi) - std.math.pi;
    }

    /// Check if phases are locked within tolerance.
    pub fn isLocked(self: PhaseLock, tolerance: f64) bool {
        return @abs(self.phaseDifference()) < tolerance;
    }

    /// Compute the Smith chart reflection coefficient.
    /// Γ = (Z - Z0) / (Z + Z0)
    pub fn reflectionCoefficient(self: PhaseLock, z0: f64) f64 {
        if (self.impedance + z0 == 0) return 1.0;
        return (self.impedance - z0) / (self.impedance + z0);
    }

    /// Adjust phase toward peer phase with damping factor.
    pub fn adjust(self: PhaseLock, damping: f64) PhaseLock {
        const diff = self.phaseDifference();
        return .{
            .own_phase = self.own_phase - damping * diff,
            .peer_phase = self.peer_phase,
            .impedance = self.impedance,
            .locked = @abs(diff * (1.0 - damping)) < 0.01,
        };
    }
};

/// Synchronize phase across multiple peers (ESP-NOW timesync pattern).
pub fn timesync(phases: []const f64, own_phase: f64) f64 {
    if (phases.len == 0) return own_phase;
    var sum: f64 = 0;
    for (phases) |p| sum += p;
    const avg = sum / @as(f64, @floatFromInt(phases.len));
    const diff = avg - own_phase;
    return own_phase + 0.5 * diff;
}

// ---------------------------------------------------------------------------
// SwarmSync — multi-sensor fusion coordination
// ---------------------------------------------------------------------------

pub const Reading = struct {
    sensor_id: u64,
    value: f64,
    confidence: f64,
    timestamp_ms: u64,
};

/// Fuse multiple sensor readings using confidence-weighted average.
pub fn fuse(readings: []const Reading) Reading {
    if (readings.len == 0) return .{ .sensor_id = 0, .value = 0, .confidence = 0, .timestamp_ms = 0 };

    var weight_sum: f64 = 0;
    var value_sum: f64 = 0;
    var max_ts: u64 = 0;

    for (readings) |r| {
        const w = r.confidence;
        weight_sum += w;
        value_sum += r.value * w;
        if (r.timestamp_ms > max_ts) max_ts = r.timestamp_ms;
    }

    if (weight_sum == 0) return readings[0];

    return .{
        .sensor_id = 0,
        .value = value_sum / weight_sum,
        .confidence = weight_sum / @as(f64, @floatFromInt(readings.len)),
        .timestamp_ms = max_ts,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Location distance" {
    const a = Location.new(0.1);
    const b = Location.new(0.9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), a.distance(b), 0.001);

    const c = Location.new(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), a.distance(c), 0.001);
}

test "Location from bytes is deterministic" {
    const a = Location.fromBytes("hello");
    const b = Location.fromBytes("hello");
    try std.testing.expectEqual(a.value, b.value);
}

test "Location signed distance" {
    const a = Location.new(0.1);
    const b = Location.new(0.9);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), a.signedDistance(b), 0.001);
}

test "ConnectionManager connect and count" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 2, 5, false);
    defer cm.deinit();

    const id = try cm.connect("peer1", Location.new(0.3), 1000);
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(usize, 0), cm.connectionCount());

    try cm.markEstablished(id.?);
    try std.testing.expectEqual(@as(usize, 1), cm.connectionCount());
    _ = cm.prune(id.?);
}

test "ConnectionManager prune" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 2, 5, false);
    defer cm.deinit();

    const id = try cm.connect("peer1", Location.new(0.3), 1000);
    try cm.markEstablished(id.?);
    try std.testing.expectEqual(@as(usize, 1), cm.connectionCount());

    try std.testing.expect(cm.prune(id.?));
    try std.testing.expectEqual(@as(usize, 0), cm.connectionCount());
}

test "ConnectionManager max capacity" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 1, 2, false);
    defer cm.deinit();

    const id1 = try cm.connect("peer1", Location.new(0.3), 1000);
    const id2 = try cm.connect("peer2", Location.new(0.7), 1000);
    const id3 = try cm.connect("peer3", Location.new(0.1), 1000);

    try std.testing.expect(id1 != null);
    try std.testing.expect(id2 != null);
    try std.testing.expect(id3 != null);

    try cm.markEstablished(id1.?);
    try cm.markEstablished(id2.?);
    try cm.markEstablished(id3.?);

    try std.testing.expect(cm.isOverMax());
    const pruned = cm.pruneOverMax();
    try std.testing.expect(pruned != null);
    try std.testing.expectEqual(@as(usize, 2), cm.connectionCount());

    var it = cm.connections.iterator();
    while (it.next()) |entry| {
        _ = cm.prune(entry.key_ptr.*);
        it = cm.connections.iterator();
    }
}

test "ConnectionManager ready state" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 1, 5, false);
    cm.min_ready_connections = 2;
    defer cm.deinit();

    try std.testing.expect(!cm.isSelfReady());

    const id1 = try cm.connect("peer1", Location.new(0.3), 1000);
    defer _ = cm.prune(id1.?);
    try cm.markEstablished(id1.?);
    try cm.markReady(id1.?);

    const id2 = try cm.connect("peer2", Location.new(0.7), 1000);
    defer _ = cm.prune(id2.?);
    try cm.markEstablished(id2.?);
    try cm.markReady(id2.?);

    try std.testing.expect(cm.isSelfReady());

    cm.markNotReady(id1.?);
    try std.testing.expect(!cm.isSelfReady());
}

test "ConnectionManager ban" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 1, 5, false);
    defer cm.deinit();

    const loc = Location.new(0.3);
    try cm.banContract(loc);
    try std.testing.expect(cm.isBanned(loc));

    const id = try cm.connect("peer1", loc, 1000);
    try std.testing.expect(id == null);
}

test "RateLimiter allows within limit" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();

    for (0..RATE_MAX_REQUESTS) |_| {
        try std.testing.expect(rl.allow(42, 1000));
    }
    try std.testing.expect(!rl.allow(42, 1000));
    try std.testing.expect(rl.allow(42, 1000 + RATE_WINDOW_MS));
}

test "InterestSync subscribe and check" {
    const allocator = std.testing.allocator;
    var sync = InterestSync.init(allocator);
    defer sync.deinit();

    try sync.subscribe(123);
    try std.testing.expect(sync.isSubscribed(123));
    try std.testing.expect(!sync.isSubscribed(456));

    sync.unsubscribe(123);
    try std.testing.expect(!sync.isSubscribed(123));
}

test "InterestSync delta computation" {
    const allocator = std.testing.allocator;
    var sync = InterestSync.init(allocator);
    defer sync.deinit();

    try sync.summaries.put(1, .{ .contract_key = 1, .version = 1, .size = 100 });
    try sync.summaries.put(2, .{ .contract_key = 2, .version = 1, .size = 200 });

    const peer_summaries = [_]Summary{
        .{ .contract_key = 2, .version = 2, .size = 200 },
        .{ .contract_key = 3, .version = 1, .size = 300 },
    };

    const delta = try sync.computeDelta(&peer_summaries);
    defer allocator.free(delta.added);
    defer allocator.free(delta.removed);

    try std.testing.expectEqual(@as(usize, 1), delta.added.len);
    try std.testing.expectEqual(@as(u64, 3), delta.added[0].contract_key);
    try std.testing.expectEqual(@as(usize, 1), delta.removed.len);
    try std.testing.expectEqual(@as(u64, 1), delta.removed[0]);
}

test "InterestSync apply delta" {
    const allocator = std.testing.allocator;
    var sync = InterestSync.init(allocator);
    defer sync.deinit();

    const added = [_]Summary{
        .{ .contract_key = 10, .version = 1, .size = 50 },
    };
    const removed = [_]u64{};
    const delta = Delta{ .added = @constCast(&added), .removed = @constCast(&removed) };

    try sync.applyDelta(delta);
    try std.testing.expectEqual(@as(usize, 1), sync.summaryCount());
}

test "bootstrap connects to gateways" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 1, 10, false);
    defer cm.deinit();

    const gateways = [_]GatewayPeer{
        .{ .addr = "gw1", .loc = Location.new(0.1) },
        .{ .addr = "gw2", .loc = Location.new(0.9) },
        .{ .addr = "gw3", .loc = Location.new(0.3) },
    };

    const result = try bootstrap(&cm, &gateways, 1000);
    try std.testing.expectEqual(@as(usize, 3), result.connected);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 3), cm.connectionCount());

    var it = cm.connections.iterator();
    while (it.next()) |entry| {
        _ = cm.prune(entry.key_ptr.*);
        it = cm.connections.iterator();
    }
}

test "bootstrap with banned gateway" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 1, 10, false);
    defer cm.deinit();

    try cm.banContract(Location.new(0.1));

    const gateways = [_]GatewayPeer{
        .{ .addr = "gw1", .loc = Location.new(0.1) },
        .{ .addr = "gw2", .loc = Location.new(0.9) },
    };

    const result = try bootstrap(&cm, &gateways, 1000);
    try std.testing.expectEqual(@as(usize, 1), result.connected);
    try std.testing.expectEqual(@as(usize, 1), result.failed);

    var it = cm.connections.iterator();
    while (it.next()) |entry| {
        _ = cm.prune(entry.key_ptr.*);
        it = cm.connections.iterator();
    }
}

test "TopologyManager add when below min" {
    const allocator = std.testing.allocator;
    var tm = TopologyManager.init(allocator);
    defer tm.deinit();

    const own_loc = Location.new(0.5);
    const connections = [_]Connection{};
    const adj = try tm.adjustTopology(own_loc, &connections, 3, 10);
    switch (adj) {
        .add_connections => |targets| {
            try std.testing.expectEqual(@as(usize, 3), targets.len);
            allocator.free(targets);
        },
        else => try std.testing.expect(false),
    }
}

test "TopologyManager no change at steady state" {
    const allocator = std.testing.allocator;
    var tm = TopologyManager.init(allocator);
    defer tm.deinit();

    const own_loc = Location.new(0.5);
    var connections = [_]Connection{
        .{ .id = 1, .peer_addr = "p1", .location = Location.new(0.4), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
        .{ .id = 2, .peer_addr = "p2", .location = Location.new(0.6), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
        .{ .id = 3, .peer_addr = "p3", .location = Location.new(0.8), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
    };

    const adj = try tm.adjustTopology(own_loc, &connections, 3, 10);
    try std.testing.expect(adj == .no_change);
}

test "TopologyManager remove when over max" {
    const allocator = std.testing.allocator;
    var tm = TopologyManager.init(allocator);
    defer tm.deinit();

    const own_loc = Location.new(0.5);
    var connections = [_]Connection{
        .{ .id = 1, .peer_addr = "p1", .location = Location.new(0.49), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
        .{ .id = 2, .peer_addr = "p2", .location = Location.new(0.51), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
        .{ .id = 3, .peer_addr = "p3", .location = Location.new(0.9), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
        .{ .id = 4, .peer_addr = "p4", .location = Location.new(0.95), .state = .established, .connected_at_ms = 0, .last_activity_ms = 0 },
    };

    const adj = try tm.adjustTopology(own_loc, &connections, 2, 2);
    switch (adj) {
        .remove_connections => |to_remove| {
            try std.testing.expect(to_remove.len > 0);
            allocator.free(to_remove);
        },
        else => try std.testing.expect(false),
    }
}

test "TopologyManager hop count average" {
    const allocator = std.testing.allocator;
    var tm = TopologyManager.init(allocator);
    defer tm.deinit();

    try tm.recordHopCount(1, 3);
    try tm.recordHopCount(2, 5);
    try tm.recordHopCount(3, 4);

    try std.testing.expectApproxEqAbs(@as(f64, 4.0), tm.averageHopCount(), 0.01);
}

test "PhaseLock phase difference" {
    const pl = PhaseLock{ .own_phase = 0.5, .peer_phase = 0.3, .impedance = 50.0, .locked = false };
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), pl.phaseDifference(), 0.001);
}

test "PhaseLock is locked within tolerance" {
    const pl = PhaseLock{ .own_phase = 1.0, .peer_phase = 1.01, .impedance = 50.0, .locked = false };
    try std.testing.expect(pl.isLocked(0.02));
    try std.testing.expect(!pl.isLocked(0.005));
}

test "PhaseLock reflection coefficient" {
    const pl = PhaseLock{ .own_phase = 0, .peer_phase = 0, .impedance = 100.0, .locked = true };
    const gamma = pl.reflectionCoefficient(50.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3333), gamma, 0.001);
}

test "PhaseLock adjust" {
    const pl = PhaseLock{ .own_phase = 1.0, .peer_phase = 0.5, .impedance = 50.0, .locked = false };
    const adjusted = pl.adjust(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), adjusted.own_phase, 0.001);
}

test "timesync averages phases" {
    const phases = [_]f64{ 0.3, 0.5, 0.7 };
    const result = timesync(&phases, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), result, 0.01);
}

test "fuse confidence-weighted average" {
    const readings = [_]Reading{
        .{ .sensor_id = 1, .value = 10.0, .confidence = 0.9, .timestamp_ms = 100 },
        .{ .sensor_id = 2, .value = 20.0, .confidence = 0.1, .timestamp_ms = 200 },
    };
    const result = fuse(&readings);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.value, 0.01);
    try std.testing.expectEqual(@as(u64, 200), result.timestamp_ms);
}

test "fuse empty returns zero" {
    const result = fuse(&[_]Reading{});
    try std.testing.expectEqual(@as(f64, 0), result.value);
}

test "getConnectionsByDistance sorted" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.5), 1, 10, false);
    defer cm.deinit();

    const id1 = try cm.connect("p1", Location.new(0.9), 1000);
    const id2 = try cm.connect("p2", Location.new(0.4), 1000);
    const id3 = try cm.connect("p3", Location.new(0.6), 1000);
    try cm.markEstablished(id1.?);
    try cm.markEstablished(id2.?);
    try cm.markEstablished(id3.?);

    const sorted = try cm.getConnectionsByDistance(allocator);
    defer allocator.free(sorted);

    try std.testing.expectEqual(@as(usize, 3), sorted.len);
    try std.testing.expect(sorted[0].location.eql(Location.new(0.4)));
    try std.testing.expect(sorted[1].location.eql(Location.new(0.6)));
    try std.testing.expect(sorted[2].location.eql(Location.new(0.9)));

    _ = cm.prune(id1.?);
    _ = cm.prune(id2.?);
    _ = cm.prune(id3.?);
}

// =============================================================================
// Cell-Face Transport Integration
// =============================================================================

/// Transport modes available for cell face encoding.
pub const TransportMode = enum {
    qr,
    video,
    polyglot,
    audio,
    paper,
    cassette,
    wifi,
    p2p,
    stega,
    quine,
    optar,
    paperback,
};

/// The 6 faces of a lattice cell (±x, ±y, ±z).
pub const FaceAxis = enum {
    pos_x,
    neg_x,
    pos_y,
    neg_y,
    pos_z,
    neg_z,
};

/// A single face of a lattice cell with associated transport mode.
pub const FaceComponent = struct {
    axis: FaceAxis,
    transport_mode: TransportMode,
    payload: []const u8,
    payload_len: usize,

    pub fn init(axis: FaceAxis, mode: TransportMode) FaceComponent {
        return .{
            .axis = axis,
            .transport_mode = mode,
            .payload = &.{},
            .payload_len = 0,
        };
    }

    pub fn setPayload(self: *FaceComponent, data: []const u8) void {
        self.payload = data;
        self.payload_len = data.len;
    }
};

/// A lattice cell with 6 faces, each with its own transport mode.
pub const LatticeCell = struct {
    x: u32,
    y: u32,
    z: u32,
    faces: [6]FaceComponent,

    pub fn init(x: u32, y: u32, z: u32) LatticeCell {
        return .{
            .x = x,
            .y = y,
            .z = z,
            .faces = .{
                FaceComponent.init(.pos_x, .qr),
                FaceComponent.init(.neg_x, .qr),
                FaceComponent.init(.pos_y, .video),
                FaceComponent.init(.neg_y, .polyglot),
                FaceComponent.init(.pos_z, .audio),
                FaceComponent.init(.neg_z, .cassette),
            },
        };
    }

    pub fn getFace(self: *const LatticeCell, axis: FaceAxis) *const FaceComponent {
        return &self.faces[@intFromEnum(axis)];
    }

    pub fn setFaceMode(self: *LatticeCell, axis: FaceAxis, mode: TransportMode) void {
        self.faces[@intFromEnum(axis)].transport_mode = mode;
    }
};

/// Transport router: selects optimal transport mode based on availability.
/// Priority: p2p → wifi → video → qr → polyglot → audio → stega → paper → optar → paperback → cassette → quine
pub const TransportRouter = struct {
    available: [12]bool = .{ true, true, true, true, true, true, true, true, true, true, true, true },

    pub fn isAvailable(self: TransportRouter, mode: TransportMode) bool {
        return self.available[@intFromEnum(mode)];
    }

    pub fn setAvailable(self: *TransportRouter, mode: TransportMode, available: bool) void {
        self.available[@intFromEnum(mode)] = available;
    }

    /// Selects the best available transport mode for the given priority.
    pub fn selectTransport(self: TransportRouter) TransportMode {
        const priority = [_]TransportMode{
            .p2p, .wifi, .video, .qr, .polyglot, .audio,
            .stega, .paper, .optar, .paperback, .cassette, .quine,
        };
        for (priority) |mode| {
            if (self.isAvailable(mode)) return mode;
        }
        return .quine; // always fallback to self-referential
    }

    /// Selects transport for a specific face based on face axis and availability.
    pub fn selectForFace(self: TransportRouter, axis: FaceAxis) TransportMode {
        // Each axis has a preferred transport, but falls back to router priority
        const preferred: TransportMode = switch (axis) {
            .pos_x => .qr,
            .neg_x => .qr,
            .pos_y => .video,
            .neg_y => .polyglot,
            .pos_z => .audio,
            .neg_z => .cassette,
        };
        if (self.isAvailable(preferred)) return preferred;
        return self.selectTransport();
    }
};

/// Generates all 3,375 lattice cells (15³) with 6 faces each.
/// Total: 3,375 × 6 = 20,250 face payloads per lattice unit.
pub fn generateLatticeCells(allocator: std.mem.Allocator, edge: u32) ![]LatticeCell {
    const total = edge * edge * edge;
    var cells = try allocator.alloc(LatticeCell, total);
    errdefer allocator.free(cells);

    var idx: usize = 0;
    var x: u32 = 0;
    while (x < edge) : (x += 1) {
        var y: u32 = 0;
        while (y < edge) : (y += 1) {
            var z: u32 = 0;
            while (z < edge) : (z += 1) {
                cells[idx] = LatticeCell.init(x, y, z);
                idx += 1;
            }
        }
    }

    return cells;
}

/// Counts total face payloads for a lattice of given edge.
pub fn totalFacePayloads(edge: u32) u64 {
    return @as(u64, edge) * edge * edge * 6;
}

test "TransportMode availability" {
    var router = TransportRouter{};
    try std.testing.expect(router.isAvailable(.qr));
    try std.testing.expect(router.isAvailable(.cassette));

    router.setAvailable(.qr, false);
    try std.testing.expect(!router.isAvailable(.qr));
}

test "TransportRouter selects best available" {
    var router = TransportRouter{};
    try std.testing.expectEqual(TransportMode.p2p, router.selectTransport());

    router.setAvailable(.p2p, false);
    try std.testing.expectEqual(TransportMode.wifi, router.selectTransport());

    router.setAvailable(.wifi, false);
    try std.testing.expectEqual(TransportMode.video, router.selectTransport());
}

test "TransportRouter fallback to quine" {
    var router = TransportRouter{};
    for (0..12) |i| router.available[i] = false;
    router.setAvailable(.quine, true);
    try std.testing.expectEqual(TransportMode.quine, router.selectTransport());
}

test "TransportRouter face-specific selection" {
    var router = TransportRouter{};

    try std.testing.expectEqual(TransportMode.qr, router.selectForFace(.pos_x));
    try std.testing.expectEqual(TransportMode.video, router.selectForFace(.pos_y));
    try std.testing.expectEqual(TransportMode.polyglot, router.selectForFace(.neg_y));
    try std.testing.expectEqual(TransportMode.audio, router.selectForFace(.pos_z));
    try std.testing.expectEqual(TransportMode.cassette, router.selectForFace(.neg_z));
}

test "TransportRouter face fallback when preferred unavailable" {
    var router = TransportRouter{};
    router.setAvailable(.qr, false);
    router.setAvailable(.p2p, false);
    router.setAvailable(.wifi, false);
    router.setAvailable(.video, false);

    // pos_x prefers qr, but qr is unavailable → falls back to next available
    const mode = router.selectForFace(.pos_x);
    try std.testing.expect(mode != .qr);
    try std.testing.expect(mode != .p2p);
    try std.testing.expect(mode != .wifi);
    try std.testing.expect(mode != .video);
}

test "LatticeCell initialization" {
    const cell = LatticeCell.init(3, 7, 11);
    try std.testing.expectEqual(@as(u32, 3), cell.x);
    try std.testing.expectEqual(@as(u32, 7), cell.y);
    try std.testing.expectEqual(@as(u32, 11), cell.z);

    try std.testing.expectEqual(TransportMode.qr, cell.getFace(.pos_x).transport_mode);
    try std.testing.expectEqual(TransportMode.video, cell.getFace(.pos_y).transport_mode);
    try std.testing.expectEqual(TransportMode.cassette, cell.getFace(.neg_z).transport_mode);
}

test "LatticeCell set face mode" {
    var cell = LatticeCell.init(0, 0, 0);
    cell.setFaceMode(.pos_x, .wifi);
    try std.testing.expectEqual(TransportMode.wifi, cell.getFace(.pos_x).transport_mode);
}

test "generateLatticeCells 15³" {
    const allocator = std.testing.allocator;
    const cells = try generateLatticeCells(allocator, 15);
    defer allocator.free(cells);

    try std.testing.expectEqual(@as(usize, 3375), cells.len);
    try std.testing.expectEqual(@as(u32, 0), cells[0].x);
    try std.testing.expectEqual(@as(u32, 14), cells[3374].x);
}

test "total face payloads" {
    try std.testing.expectEqual(@as(u64, 3375 * 6), totalFacePayloads(15));
    try std.testing.expectEqual(@as(u64, 20250), totalFacePayloads(15));
}

test "FaceComponent payload" {
    var face = FaceComponent.init(.pos_x, .qr);
    const data = "test payload";
    face.setPayload(data);
    try std.testing.expectEqual(@as(usize, 12), face.payload_len);
    try std.testing.expectEqualStrings("test payload", face.payload);
}

// =============================================================================
// Connected Lattice Surfaces Protocol
// =============================================================================

/// A shared face between two connected lattices.
/// When two peers connect, their lattices align at a boundary face.
/// The Möbius twist at the boundary creates instant correlation.
/// All states are Q32.32 fixed-point i64 — no floating-point in core state.
pub const SharedFace = struct {
    peer_id: []const u8,
    face_axis: FaceAxis,
    edge: u32,
    /// E0 states on the shared face (15² = 225 cells per face) in Q32.32.
    local_states: [225]i64,
    remote_states: [225]i64,
    synced: bool,
    /// Previous local states for delta computation.
    prev_local_states: [225]i64 = [_]i64{0} ** 225,

    pub fn init(peer_id: []const u8, axis: FaceAxis, edge: u32) SharedFace {
        return .{
            .peer_id = peer_id,
            .face_axis = axis,
            .edge = edge,
            .local_states = [_]i64{0} ** 225,
            .remote_states = [_]i64{0} ** 225,
            .synced = false,
        };
    }

    /// Sets local E0 states from a slice of Q32.32 activations.
    pub fn setLocalStates(self: *SharedFace, states: []const i64) void {
        const n = @min(states.len, 225);
        // Save previous states for delta computation
        @memcpy(self.prev_local_states[0..n], self.local_states[0..n]);
        for (0..n) |i| self.local_states[i] = states[i];
    }

    /// Sets remote E0 states received from peer.
    pub fn setRemoteStates(self: *SharedFace, states: []const i64) void {
        const n = @min(states.len, 225);
        for (0..n) |i| self.remote_states[i] = states[i];
        self.synced = true;
    }

    /// Computes delta: returns indices and values of changed local states.
    /// Only entries that differ from prev_local_states are included.
    /// Output buffer must be large enough for up to 225 entries.
    pub fn computeDelta(self: *const SharedFace, out_indices: []u8, out_values: []i64) usize {
        var count: usize = 0;
        for (0..225) |i| {
            if (self.local_states[i] != self.prev_local_states[i]) {
                if (count >= out_indices.len or count >= out_values.len) break;
                out_indices[count] = @intCast(i);
                out_values[count] = self.local_states[i];
                count += 1;
            }
        }
        return count;
    }

    /// Applies a delta received from a peer to remote_states.
    pub fn applyDelta(self: *SharedFace, indices: []const u8, values: []const i64) void {
        const n = @min(indices.len, values.len);
        for (0..n) |i| {
            const idx = indices[i];
            if (idx < 225) {
                self.remote_states[idx] = values[i];
            }
        }
        self.synced = true;
    }

    /// Serializes local states to a byte buffer (full 1800 bytes).
    pub fn serializeFull(self: *const SharedFace, out: []u8) usize {
        const size = 225 * @sizeOf(i64);
        if (out.len < size) return 0;
        for (0..225) |i| {
            const bytes = std.mem.asBytes(&self.local_states[i]);
            @memcpy(out[i * 8 .. i * 8 + 8], bytes);
        }
        return size;
    }

    /// Deserializes full states from a byte buffer.
    pub fn deserializeFull(self: *SharedFace, data: []const u8) void {
        const n = @min(data.len / 8, 225);
        for (0..n) |i| {
            var val: i64 = 0;
            @memcpy(std.mem.asBytes(&val), data[i * 8 .. i * 8 + 8]);
            self.remote_states[i] = val;
        }
        self.synced = true;
    }

    /// Computes the Möbius correlation between local and remote states.
    pub fn mobiusCorrelation(self: *const SharedFace) i64 {
        var correlation: i64 = 0;
        for (0..225) |i| {
            const remote_idx = 224 - i;
            correlation += fp.mul(self.local_states[i], self.remote_states[remote_idx]);
        }
        return fp.div(correlation, fp.fromInt(225));
    }

    /// Checks if the shared face is phase-locked (|correlation| > threshold).
    pub fn isPhaseLocked(self: *const SharedFace, threshold: i64) bool {
        return fp.absVal(self.mobiusCorrelation()) > threshold;
    }
};

/// Connection pool for managing multiple peer connections efficiently.
pub const ConnectionPool = struct {
    connections: std.ArrayList(SharedFace),
    allocator: std.mem.Allocator,
    max_connections: usize,

    pub fn init(allocator: std.mem.Allocator, max_connections: usize) ConnectionPool {
        return .{
            .connections = std.ArrayList(SharedFace).init(allocator),
            .allocator = allocator,
            .max_connections = max_connections,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.connections.deinit();
    }

    pub fn addConnection(self: *ConnectionPool, peer_id: []const u8, axis: FaceAxis, edge: u32) !void {
        if (self.connections.items.len >= self.max_connections) return error.PoolFull;
        try self.connections.append(SharedFace.init(peer_id, axis, edge));
    }

    pub fn getConnection(self: *ConnectionPool, peer_id: []const u8) ?*SharedFace {
        for (self.connections.items) |*face| {
            if (std.mem.eql(u8, face.peer_id, peer_id)) return face;
        }
        return null;
    }

    pub fn removeConnection(self: *ConnectionPool, peer_id: []const u8) void {
        var i: usize = 0;
        while (i < self.connections.items.len) {
            if (std.mem.eql(u8, self.connections.items[i].peer_id, peer_id)) {
                _ = self.connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn count(self: *const ConnectionPool) usize {
        return self.connections.items.len;
    }

    /// Batch sync: updates all connections with local states and collects correlations.
    pub fn batchSync(self: *ConnectionPool, local_states: []const i64) []i64 {
        var correlations = self.allocator.alloc(i64, self.connections.items.len) catch return &[_]i64{};
        for (self.connections.items, 0..) |*face, i| {
            face.setLocalStates(local_states);
            correlations[i] = face.mobiusCorrelation();
        }
        return correlations;
    }
};

/// Connects two lattices at a shared boundary face.
/// Returns a SharedFace that maintains the correlation.
pub fn connectLattices(peer_id: []const u8, axis: FaceAxis, edge: u32) SharedFace {
    return SharedFace.init(peer_id, axis, edge);
}

/// Synchronizes E0 states across a shared face.
/// Local states are sent to peer, remote states are received.
/// The Möbius twist creates the dual torus / wormhole structure.
pub fn syncSharedFace(face: *SharedFace, local_states: []const i64, remote_states: []const i64) void {
    face.setLocalStates(local_states);
    face.setRemoteStates(remote_states);
}

/// Computes the dual torus wormhole correlation between two connected lattices.
/// The shared face is the wormhole throat. Information flows through the Möbius boundary.
pub fn dualTorusCorrelation(face_a: *const SharedFace, face_b: *const SharedFace) i64 {
    const corr_a = face_a.mobiusCorrelation();
    const corr_b = face_b.mobiusCorrelation();
    // Dual torus: average of both face correlations
    return fp.div(corr_a + corr_b, fp.fromInt(2));
}

test "SharedFace initialization" {
    const face = SharedFace.init("peer1", .pos_x, 15);
    try std.testing.expectEqualStrings("peer1", face.peer_id);
    try std.testing.expectEqual(FaceAxis.pos_x, face.face_axis);
    try std.testing.expectEqual(@as(u32, 15), face.edge);
    try std.testing.expect(!face.synced);
}

test "SharedFace set states" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    const local = [_]i64{fp.HALF_FP} ** 225;
    const remote = [_]i64{fp.div(fp.fromInt(3), fp.fromInt(10))} ** 225;
    face.setLocalStates(&local);
    face.setRemoteStates(&remote);
    try std.testing.expect(face.synced);
    try std.testing.expectEqual(fp.HALF_FP, face.local_states[0]);
    try std.testing.expectEqual(fp.div(fp.fromInt(3), fp.fromInt(10)), face.remote_states[0]);
}

test "SharedFace Möbius correlation" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    // Set local and remote to same values → high correlation
    for (0..225) |i| {
        face.local_states[i] = fp.div(fp.fromInt(4), fp.fromInt(5)); // 0.8
        face.remote_states[224 - i] = fp.div(fp.fromInt(4), fp.fromInt(5)); // 0.8 reversed
    }
    const corr = face.mobiusCorrelation();
    // 0.8 * 0.8 = 0.64 in Q32.32
    const expected = fp.mul(fp.div(fp.fromInt(4), fp.fromInt(5)), fp.div(fp.fromInt(4), fp.fromInt(5)));
    try std.testing.expectEqual(expected, corr);
}

test "SharedFace phase locked" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    for (0..225) |i| {
        face.local_states[i] = fp.div(fp.fromInt(9), fp.fromInt(10)); // 0.9
        face.remote_states[224 - i] = fp.div(fp.fromInt(9), fp.fromInt(10));
    }
    try std.testing.expect(face.isPhaseLocked(fp.HALF_FP));
}

test "SharedFace not phase locked" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    for (0..225) |i| {
        face.local_states[i] = fp.div(fp.fromInt(9), fp.fromInt(10));
        face.remote_states[i] = 0; // no correlation
    }
    try std.testing.expect(!face.isPhaseLocked(fp.HALF_FP));
}

test "connectLattices creates shared face" {
    const face = connectLattices("peer2", .neg_y, 15);
    try std.testing.expectEqualStrings("peer2", face.peer_id);
    try std.testing.expectEqual(FaceAxis.neg_y, face.face_axis);
}

test "syncSharedFace updates states" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    const local = [_]i64{fp.div(fp.fromInt(1), fp.fromInt(10))} ** 225;
    const remote = [_]i64{fp.div(fp.fromInt(2), fp.fromInt(10))} ** 225;
    syncSharedFace(&face, &local, &remote);
    try std.testing.expect(face.synced);
    try std.testing.expectEqual(fp.div(fp.fromInt(1), fp.fromInt(10)), face.local_states[0]);
    try std.testing.expectEqual(fp.div(fp.fromInt(2), fp.fromInt(10)), face.remote_states[0]);
}

test "dualTorusCorrelation averages two faces" {
    var face_a = SharedFace.init("peer1", .pos_x, 15);
    var face_b = SharedFace.init("peer2", .neg_x, 15);
    for (0..225) |i| {
        face_a.local_states[i] = fp.div(fp.fromInt(4), fp.fromInt(5)); // 0.8
        face_a.remote_states[224 - i] = fp.div(fp.fromInt(4), fp.fromInt(5));
        face_b.local_states[i] = fp.div(fp.fromInt(3), fp.fromInt(5)); // 0.6
        face_b.remote_states[224 - i] = fp.div(fp.fromInt(3), fp.fromInt(5));
    }
    const corr = dualTorusCorrelation(&face_a, &face_b);
    // (0.64 + 0.36) / 2 = 0.50 in Q32.32
    const expected_a = fp.mul(fp.div(fp.fromInt(4), fp.fromInt(5)), fp.div(fp.fromInt(4), fp.fromInt(5)));
    const expected_b = fp.mul(fp.div(fp.fromInt(3), fp.fromInt(5)), fp.div(fp.fromInt(3), fp.fromInt(5)));
    const expected = fp.div(expected_a + expected_b, fp.fromInt(2));
    try std.testing.expectEqual(expected, corr);
}

test "SharedFace delta serialization" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    const states = [_]i64{fp.fromInt(1), fp.fromInt(2), fp.fromInt(3)} ++ [_]i64{0} ** 222;
    face.setLocalStates(&states);

    // Now change a few states
    const states2 = [_]i64{fp.fromInt(1), fp.fromInt(5), fp.fromInt(3)} ++ [_]i64{0} ** 222;
    face.setLocalStates(&states2);

    var indices: [225]u8 = undefined;
    var values: [225]i64 = undefined;
    const delta_count = face.computeDelta(&indices, &values);

    // Only index 1 changed
    try std.testing.expectEqual(@as(usize, 1), delta_count);
    try std.testing.expectEqual(@as(u8, 1), indices[0]);
    try std.testing.expectEqual(fp.fromInt(5), values[0]);
}

test "SharedFace apply delta" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    const indices = [_]u8{ 0, 5, 10 };
    const values = [_]i64{ fp.fromInt(10), fp.fromInt(20), fp.fromInt(30) };

    face.applyDelta(&indices, &values);

    try std.testing.expectEqual(fp.fromInt(10), face.remote_states[0]);
    try std.testing.expectEqual(fp.fromInt(20), face.remote_states[5]);
    try std.testing.expectEqual(fp.fromInt(30), face.remote_states[10]);
    try std.testing.expect(face.synced);
}

test "SharedFace full serialize/deserialize" {
    var face = SharedFace.init("peer1", .pos_x, 15);
    const states = [_]i64{fp.fromInt(42)} ++ [_]i64{0} ** 224;
    face.setLocalStates(&states);

    var buf: [1800]u8 = undefined;
    const written = face.serializeFull(&buf);
    try std.testing.expectEqual(@as(usize, 1800), written);

    var face2 = SharedFace.init("peer2", .neg_x, 15);
    face2.deserializeFull(&buf);
    try std.testing.expectEqual(fp.fromInt(42), face2.remote_states[0]);
    try std.testing.expect(face2.synced);
}

test "ConnectionPool basic operations" {
    var pool = ConnectionPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    try pool.addConnection("peer1", .pos_x, 15);
    try pool.addConnection("peer2", .neg_y, 15);
    try std.testing.expectEqual(@as(usize, 2), pool.count());

    const face = pool.getConnection("peer1");
    try std.testing.expect(face != null);
    try std.testing.expectEqualStrings("peer1", face.?.peer_id);

    pool.removeConnection("peer1");
    try std.testing.expectEqual(@as(usize, 1), pool.count());
    try std.testing.expect(pool.getConnection("peer1") == null);
}

test "ConnectionPool batch sync" {
    var pool = ConnectionPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    try pool.addConnection("peer1", .pos_x, 15);
    try pool.addConnection("peer2", .neg_x, 15);

    const states = [_]i64{fp.fromInt(1)} ++ [_]i64{0} ** 224;
    const correlations = pool.batchSync(&states);
    defer std.testing.allocator.free(correlations);

    try std.testing.expectEqual(@as(usize, 2), correlations.len);
}

test "ConnectionPool full" {
    var pool = ConnectionPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    try pool.addConnection("peer1", .pos_x, 15);
    try std.testing.expectError(error.PoolFull, pool.addConnection("peer2", .neg_x, 15));
}

// =============================================================================
// Freenet-Style Offline Mesh
// =============================================================================

/// Fallback chain for offline transport: WebRTC → WiFi → LoRa → QR → paper → cassette.
/// Each step degrades gracefully. Store-and-forward for disconnected peers.
pub const OfflineTransportRouter = struct {
    webrtc_available: bool = true,
    wifi_available: bool = true,
    lora_available: bool = false,
    qr_available: bool = true,
    paper_available: bool = true,
    cassette_available: bool = true,

    /// Selects the best available offline transport.
    /// Fallback chain: WebRTC → WiFi → LoRa → QR → paper → cassette.
    pub fn selectOfflineTransport(self: OfflineTransportRouter) TransportMode {
        if (self.webrtc_available) return .p2p;
        if (self.wifi_available) return .wifi;
        if (self.lora_available) return .wifi; // LoRa uses wifi frame format
        if (self.qr_available) return .qr;
        if (self.paper_available) return .optar;
        if (self.cassette_available) return .cassette;
        return .quine; // ultimate fallback: self-referential
    }

    /// Returns the fallback level (0=best, 5=worst).
    pub fn fallbackLevel(self: OfflineTransportRouter) u8 {
        if (self.webrtc_available) return 0;
        if (self.wifi_available) return 1;
        if (self.lora_available) return 2;
        if (self.qr_available) return 3;
        if (self.paper_available) return 4;
        if (self.cassette_available) return 5;
        return 6;
    }

    /// Returns true if the system is in civilization-collapse mode
    /// (only paper and cassette available).
    pub fn isCivilizationCollapse(self: OfflineTransportRouter) bool {
        return !self.webrtc_available and !self.wifi_available and
            !self.lora_available and !self.qr_available and
            (self.paper_available or self.cassette_available);
    }
};

/// A queued message for store-and-forward to disconnected peers.
pub const QueuedMessage = struct {
    peer_id: []const u8,
    payload: []const u8,
    timestamp: u64,
    ttl: u64,
    priority: u8,
    transport_mode: TransportMode,
};

/// Store-and-forward queue for offline messages.
/// Messages are queued when peers are disconnected and flushed when they reconnect.
pub const StoreAndForward = struct {
    messages: std.ArrayList(QueuedMessage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StoreAndForward {
        return .{
            .messages = std.ArrayList(QueuedMessage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StoreAndForward) void {
        self.messages.deinit();
    }

    /// Queues a message for later delivery.
    pub fn enqueue(self: *StoreAndForward, peer_id: []const u8, payload: []const u8, ttl: u64, priority: u8, mode: TransportMode) !void {
        try self.messages.append(.{
            .peer_id = peer_id,
            .payload = payload,
            .timestamp = @intCast(if (@import("builtin").os.tag == .freestanding) @as(u64, 0) else @as(u64, @intCast(std.time.timestamp()))),
            .ttl = ttl,
            .priority = priority,
            .transport_mode = mode,
        });
    }

    /// Flushes all queued messages for a reconnected peer.
    /// Returns the number of messages delivered.
    pub fn flushForPeer(self: *StoreAndForward, peer_id: []const u8) !usize {
        var delivered: usize = 0;
        var i: usize = 0;
        while (i < self.messages.items.len) {
            if (std.mem.eql(u8, self.messages.items[i].peer_id, peer_id)) {
                _ = self.messages.swapRemove(i);
                delivered += 1;
            } else {
                i += 1;
            }
        }
        return delivered;
    }

    /// Removes expired messages (TTL exceeded).
    pub fn purgeExpired(self: *StoreAndForward, current_time: u64) usize {
        var purged: usize = 0;
        var i: usize = 0;
        while (i < self.messages.items.len) {
            const msg = self.messages.items[i];
            if (current_time > msg.timestamp + msg.ttl) {
                _ = self.messages.swapRemove(i);
                purged += 1;
            } else {
                i += 1;
            }
        }
        return purged;
    }

    /// Returns the number of queued messages.
    pub fn count(self: StoreAndForward) usize {
        return self.messages.items.len;
    }

    /// Returns messages for a specific peer.
    pub fn messagesForPeer(self: StoreAndForward, peer_id: []const u8) usize {
        var msg_count: usize = 0;
        for (self.messages.items) |msg| {
            if (std.mem.eql(u8, msg.peer_id, peer_id)) msg_count += 1;
        }
        return msg_count;
    }
};

test "OfflineTransportRouter: best available (WebRTC)" {
    const router = OfflineTransportRouter{};
    try std.testing.expectEqual(TransportMode.p2p, router.selectOfflineTransport());
    try std.testing.expectEqual(@as(u8, 0), router.fallbackLevel());
}

test "OfflineTransportRouter: WiFi fallback" {
    const router = OfflineTransportRouter{ .webrtc_available = false };
    try std.testing.expectEqual(TransportMode.wifi, router.selectOfflineTransport());
    try std.testing.expectEqual(@as(u8, 1), router.fallbackLevel());
}

test "OfflineTransportRouter: QR fallback" {
    const router = OfflineTransportRouter{
        .webrtc_available = false,
        .wifi_available = false,
        .lora_available = false,
    };
    try std.testing.expectEqual(TransportMode.qr, router.selectOfflineTransport());
    try std.testing.expectEqual(@as(u8, 3), router.fallbackLevel());
}

test "OfflineTransportRouter: paper fallback" {
    const router = OfflineTransportRouter{
        .webrtc_available = false,
        .wifi_available = false,
        .lora_available = false,
        .qr_available = false,
    };
    try std.testing.expectEqual(TransportMode.optar, router.selectOfflineTransport());
}

test "OfflineTransportRouter: cassette fallback" {
    const router = OfflineTransportRouter{
        .webrtc_available = false,
        .wifi_available = false,
        .lora_available = false,
        .qr_available = false,
        .paper_available = false,
    };
    try std.testing.expectEqual(TransportMode.cassette, router.selectOfflineTransport());
}

test "OfflineTransportRouter: quine ultimate fallback" {
    const router = OfflineTransportRouter{
        .webrtc_available = false,
        .wifi_available = false,
        .lora_available = false,
        .qr_available = false,
        .paper_available = false,
        .cassette_available = false,
    };
    try std.testing.expectEqual(TransportMode.quine, router.selectOfflineTransport());
    try std.testing.expectEqual(@as(u8, 6), router.fallbackLevel());
}

test "OfflineTransportRouter: civilization-collapse mode" {
    const router = OfflineTransportRouter{
        .webrtc_available = false,
        .wifi_available = false,
        .lora_available = false,
        .qr_available = false,
    };
    try std.testing.expect(router.isCivilizationCollapse());
}

test "OfflineTransportRouter: not civilization-collapse" {
    const router = OfflineTransportRouter{};
    try std.testing.expect(!router.isCivilizationCollapse());
}

test "StoreAndForward: enqueue and count" {
    const allocator = std.testing.allocator;
    var saf = StoreAndForward.init(allocator);
    defer saf.deinit();

    try saf.enqueue("peer1", "hello", 3600, 1, .p2p);
    try saf.enqueue("peer1", "world", 3600, 2, .p2p);
    try saf.enqueue("peer2", "test", 3600, 1, .wifi);

    try std.testing.expectEqual(@as(usize, 3), saf.count());
    try std.testing.expectEqual(@as(usize, 2), saf.messagesForPeer("peer1"));
    try std.testing.expectEqual(@as(usize, 1), saf.messagesForPeer("peer2"));
}

test "StoreAndForward: flush for peer" {
    const allocator = std.testing.allocator;
    var saf = StoreAndForward.init(allocator);
    defer saf.deinit();

    try saf.enqueue("peer1", "hello", 3600, 1, .p2p);
    try saf.enqueue("peer2", "world", 3600, 1, .wifi);
    try saf.enqueue("peer1", "again", 3600, 1, .p2p);

    const delivered = try saf.flushForPeer("peer1");
    try std.testing.expectEqual(@as(usize, 2), delivered);
    try std.testing.expectEqual(@as(usize, 1), saf.count());
}

test "StoreAndForward: purge expired" {
    const allocator = std.testing.allocator;
    var saf = StoreAndForward.init(allocator);
    defer saf.deinit();

    try saf.enqueue("peer1", "old", 100, 1, .p2p);
    try saf.enqueue("peer2", "new", 999999, 1, .wifi);

    // Purge with current time far in the future (real timestamp + large offset)
    const future_time: u64 = @intCast(std.time.timestamp() + 200);
    const purged = saf.purgeExpired(future_time);
    try std.testing.expectEqual(@as(usize, 1), purged);
    try std.testing.expectEqual(@as(usize, 1), saf.count());
}

test "ConnectionManager: samcBypassRoute bypasses knot" {
    const allocator = std.testing.allocator;
    var cm = ConnectionManager.init(allocator, Location.new(0.0), 2, 10, false);
    defer cm.deinit();

    const id1 = (try cm.connect("127.0.0.1:9001", Location.new(0.1), 100)).?;
    const id2 = (try cm.connect("127.0.0.1:9002", Location.new(0.2), 100)).?;
    const id3 = (try cm.connect("127.0.0.1:9003", Location.new(0.8), 100)).?;

    try cm.markEstablished(id1);
    try cm.markEstablished(id2);
    try cm.markEstablished(id3);

    // Target is near 0.15. Normally id1 is closest (dist 0.05).
    // If id1 is marked as knot-congested, samcBypassRoute chooses id2 (dist 0.05).
    const bypassed = cm.samcBypassRoute(Location.new(0.15), id1);
    try std.testing.expect(bypassed != null);
    try std.testing.expectEqual(id2, bypassed.?.id);
}

test "StoreAndForward: empty queue" {
    const allocator = std.testing.allocator;
    var saf = StoreAndForward.init(allocator);
    defer saf.deinit();

    try std.testing.expectEqual(@as(usize, 0), saf.count());
    const delivered = try saf.flushForPeer("nobody");
    try std.testing.expectEqual(@as(usize, 0), delivered);
}
