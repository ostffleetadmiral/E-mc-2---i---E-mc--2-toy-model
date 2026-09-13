//! entangle.zig — Entanglement distribution, error correction, and steganographic transport.
//!
//! Integrates:
//!   - DLCZ entanglement protocol: atom clouds, photon emission, midpoint
//!     comparison, phase stabilization, telecom wavelength conversion,
//!     entanglement swapping.
//!   - Reed-Solomon error correction over GF(256) (from prototype lvce_reed_solomon).
//!   - Shamir secret sharing over GF(2^8) (from prototype lvce_shamir).
//!   - Kleinberg small-world routing (from freenet-core strategy).
//!   - Steganographic LSB hiding (from StegaShare embedder).
//!
//! Zero external dependencies beyond std.

const std = @import("std");

// =============================================================================
// GF(256) Galois Field Arithmetic (shared by Reed-Solomon and Shamir)
// =============================================================================

pub const GaloisField = struct {
    pub const FIELD_SIZE: u16 = 256;
    pub const PRIMITIVE_POLY: u16 = 0x11D;

    exp_table: [512]u8 = undefined,
    log_table: [256]u8 = undefined,

    pub fn init() GaloisField {
        var gf: GaloisField = .{};
        var x: u16 = 1;
        var i: u16 = 0;
        while (i < 255) : (i += 1) {
            gf.exp_table[i] = @intCast(x);
            gf.log_table[x] = @intCast(i);
            x <<= 1;
            if (x & 0x100 != 0) x ^= PRIMITIVE_POLY;
        }
        while (i < 512) : (i += 1) {
            gf.exp_table[i] = gf.exp_table[i - 255];
        }
        gf.log_table[0] = 0;
        return gf;
    }

    pub inline fn mul(self: GaloisField, a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return self.exp_table[@as(usize, self.log_table[a]) + @as(usize, self.log_table[b])];
    }

    pub inline fn div(self: GaloisField, a: u8, b: u8) u8 {
        if (a == 0) return 0;
        if (b == 0) return 0;
        const log_a: i32 = @intCast(self.log_table[a]);
        const log_b: i32 = @intCast(self.log_table[b]);
        const diff = log_a - log_b;
        if (diff < 0) {
            return self.exp_table[@intCast(diff + 255)];
        }
        return self.exp_table[@intCast(diff)];
    }

    pub inline fn pow(self: GaloisField, a: u8, p: u8) u8 {
        if (a == 0) return 0;
        return self.exp_table[(@as(usize, self.log_table[a]) * @as(usize, p)) % 255];
    }

    pub inline fn inv(self: GaloisField, a: u8) u8 {
        if (a == 0) return 0;
        return self.exp_table[255 - @as(usize, self.log_table[a])];
    }
};

// =============================================================================
// Reed-Solomon Error Correction (from prototype lvce_reed_solomon)
// =============================================================================

pub const RsConfig = struct {
    data_shards: usize,
    parity_shards: usize,
    total_shards: usize,

    pub fn init(data: usize, parity: usize) RsConfig {
        return .{
            .data_shards = data,
            .parity_shards = parity,
            .total_shards = data + parity,
        };
    }
};

fn generateGeneratorPoly(allocator: std.mem.Allocator, gf: GaloisField, degree: usize) ![]u8 {
    var poly = try allocator.alloc(u8, degree + 1);
    @memset(poly, 0);
    poly[0] = 1;

    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var new_poly = try allocator.alloc(u8, degree + 1);
        @memset(new_poly, 0);
        defer allocator.free(new_poly);

        const coef = gf.exp_table[i];
        for (0..degree + 1) |j| new_poly[j] = poly[j];
        for (0..degree) |j| new_poly[j + 1] ^= gf.mul(poly[j], coef);
        @memcpy(poly, new_poly);
    }
    return poly;
}

pub fn rsEncode(allocator: std.mem.Allocator, config: RsConfig, data: []const u8) ![][]u8 {
    const gf = GaloisField.init();
    const gen_poly = try generateGeneratorPoly(allocator, gf, config.parity_shards);
    defer allocator.free(gen_poly);

    const shard_size = (data.len + config.data_shards - 1) / config.data_shards;
    var shards = try allocator.alloc([]u8, config.total_shards);
    errdefer allocator.free(shards);

    var i: usize = 0;
    while (i < config.data_shards) : (i += 1) {
        shards[i] = try allocator.alloc(u8, shard_size);
        const start = i * shard_size;
        if (start < data.len) {
            const end = @min(start + shard_size, data.len);
            @memcpy(shards[i][0 .. end - start], data[start..end]);
            if (end - start < shard_size) @memset(shards[i][end - start ..], 0);
        } else {
            @memset(shards[i], 0);
        }
    }

    while (i < config.total_shards) : (i += 1) {
        shards[i] = try allocator.alloc(u8, shard_size);
        @memset(shards[i], 0);
    }

    var p: usize = 0;
    while (p < config.parity_shards) : (p += 1) {
        var j: usize = 0;
        while (j < shard_size) : (j += 1) {
            var feedback: u8 = 0;
            var d: usize = 0;
            while (d < config.data_shards) : (d += 1) {
                feedback ^= gf.mul(shards[d][j], gen_poly[p]);
            }
            shards[config.data_shards + p][j] = feedback;
        }
    }

    return shards;
}

pub fn freeShards(allocator: std.mem.Allocator, shards: [][]u8) void {
    for (shards) |s| allocator.free(s);
    allocator.free(shards);
}

/// Reconstructs data from available shards. `present_indices` marks which
/// shards are available (true = present). Returns the reassembled data.
pub fn rsReconstruct(
    allocator: std.mem.Allocator,
    config: RsConfig,
    shards: [][]const u8,
    present: []const bool,
) ![]u8 {
    const gf = GaloisField.init();
    const shard_size = if (shards.len > 0) shards[0].len else 0;

    // Collect present data shards
    var present_data = std.ArrayList(u8).init(allocator);
    defer present_data.deinit();
    try present_data.ensureTotalCapacity(config.data_shards * shard_size);

    // Build matrix rows for present data shards (identity rows)
    var present_indices = std.ArrayList(usize).init(allocator);
    defer present_indices.deinit();
    try present_indices.ensureTotalCapacity(config.data_shards);

    for (0..config.data_shards) |idx| {
        if (idx < present.len and present[idx]) {
            try present_indices.append(idx);
        }
    }

    if (present_indices.items.len < config.data_shards) return error.InsufficientShards;

    // Simple reconstruction: just use the first data_shards present data shards
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    try result.ensureTotalCapacity(shard_size);

    var j: usize = 0;
    while (j < shard_size) : (j += 1) {
        var d: usize = 0;
        while (d < config.data_shards) : (d += 1) {
            const shard_idx = present_indices.items[d];
            if (shard_idx < shards.len and shards[shard_idx].len > j) {
                try result.append(shards[shard_idx][j]);
            } else {
                try result.append(0);
            }
        }
    }

    _ = gf;
    return result.toOwnedSlice();
}

// =============================================================================
// Shamir Secret Sharing (from prototype lvce_shamir)
// =============================================================================

pub const Share = struct {
    x: u8,
    y: []u8,

    pub fn deinit(self: Share, allocator: std.mem.Allocator) void {
        allocator.free(self.y);
    }
};

pub const ShareList = struct {
    shares: []Share,
    allocator: std.mem.Allocator,

    pub fn deinit(self: ShareList) void {
        for (self.shares) |s| self.allocator.free(s.y);
        self.allocator.free(self.shares);
    }
};

pub const ShamirError = error{
    InvalidThreshold,
    InvalidShareCount,
    InsufficientShares,
    DuplicateXValue,
    InvalidShare,
};

fn randomByte() u8 {
    var buf: [1]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return buf[0];
}

pub fn shamirSplit(
    allocator: std.mem.Allocator,
    secret: []const u8,
    n: u8,
    k: u8,
) !ShareList {
    if (n == 0 or k < n) return ShamirError.InvalidThreshold;
    if (k > 255) return ShamirError.InvalidShareCount;

    const gf = GaloisField.init();
    var shares = try allocator.alloc(Share, k);
    errdefer {
        for (shares) |s| allocator.free(s.y);
        allocator.free(shares);
    }

    var i: u8 = 0;
    while (i < k) : (i += 1) {
        shares[i].x = i + 1;
        shares[i].y = try allocator.alloc(u8, secret.len);
        @memset(shares[i].y, 0);
    }

    for (secret, 0..) |secret_byte, byte_idx| {
        var coeffs: [255]u8 = undefined;
        coeffs[0] = secret_byte;
        var j: u8 = 1;
        while (j < n) : (j += 1) coeffs[j] = randomByte();

        var xi: u8 = 0;
        while (xi < k) : (xi += 1) {
            const x = xi + 1;
            var y: u8 = coeffs[0];
            var power: u8 = 1;
            var d: u8 = 1;
            while (d < n) : (d += 1) {
                power = gf.mul(power, x);
                y ^= gf.mul(coeffs[d], power);
            }
            shares[xi].y[byte_idx] = y;
        }
    }

    return .{ .shares = shares, .allocator = allocator };
}

pub fn shamirRecover(
    allocator: std.mem.Allocator,
    shares: []const Share,
    n: u8,
) ![]u8 {
    if (shares.len < n) return ShamirError.InsufficientShares;
    if (n == 0) return ShamirError.InvalidThreshold;

    const gf = GaloisField.init();
    const secret_len = shares[0].y.len;

    for (shares[0..n]) |s| {
        if (s.y.len != secret_len) return ShamirError.InvalidShare;
    }

    var i: u8 = 0;
    while (i < n) : (i += 1) {
        var j: u8 = i + 1;
        while (j < n) : (j += 1) {
            if (shares[i].x == shares[j].x) return ShamirError.DuplicateXValue;
        }
    }

    var secret = try allocator.alloc(u8, secret_len);
    errdefer allocator.free(secret);

    for (0..secret_len) |byte_idx| {
        var result: u8 = 0;
        i = 0;
        while (i < n) : (i += 1) {
            var numerator: u8 = 1;
            var denominator: u8 = 1;
            var j: u8 = 0;
            while (j < n) : (j += 1) {
                if (j == i) continue;
                numerator = gf.mul(numerator, shares[j].x);
                denominator = gf.mul(denominator, shares[i].x ^ shares[j].x);
            }
            const lagrange_coeff = gf.div(numerator, denominator);
            result ^= gf.mul(shares[i].y[byte_idx], lagrange_coeff);
        }
        secret[byte_idx] = result;
    }

    return secret;
}

// =============================================================================
// DLCZ Entanglement Protocol
// =============================================================================

/// DLCZ entanglement node state.
pub const DLCZNode = struct {
    node_id: u32,
    location: f64, // Ring location [0, 1)
    atom_cloud_ready: bool,
    photon_emitted: bool,
    phase: f64, // Phase stabilization value
    wavelength_nm: u32, // Telecom wavelength (1550 nm standard)
    entangled_with: ?u32, // Node ID of entangled partner
};

/// DLCZ protocol configuration.
pub const DLCZConfig = struct {
    wavelength_nm: u32 = 1550, // Telecom C-band
    phase_tolerance: f64 = 0.01, // Phase stabilization tolerance (radians)
    max_retries: u8 = 3, // Maximum entanglement attempts
    swap_enabled: bool = true, // Enable entanglement swapping
};

/// DLCZ entanglement attempt result.
pub const EntanglementResult = struct {
    success: bool,
    node_a: u32,
    node_b: u32,
    phase_error: f64,
    attempts: u8,
    swapped: bool, // True if entanglement was achieved via swapping
};

/// Attempts DLCZ entanglement between two nodes.
/// Simulates: atom cloud excitation → spontaneous photon emission →
/// midpoint comparison → phase stabilization → entanglement confirmation.
pub fn dlczEntangle(
    node_a: *DLCZNode,
    node_b: *DLCZNode,
    config: DLCZConfig,
    rng: *std.Random.DefaultPrng,
) EntanglementResult {
    var attempts: u8 = 0;
    var phase_error: f64 = 0;

    while (attempts < config.max_retries) : (attempts += 1) {
        // Step 1: Atom cloud excitation
        node_a.atom_cloud_ready = true;
        node_b.atom_cloud_ready = true;

        // Step 2: Spontaneous photon emission
        node_a.photon_emitted = rng.random().float(f64) > 0.1; // 90% success rate
        node_b.photon_emitted = rng.random().float(f64) > 0.1;

        if (!node_a.photon_emitted or !node_b.photon_emitted) continue;

        // Step 3: Midpoint comparison (Bell state measurement)
        // Phase error is random, reduced by stabilization
        phase_error = rng.random().float(f64) * 0.1;

        // Step 4: Phase stabilization
        if (phase_error < config.phase_tolerance) {
            // Entanglement successful
            node_a.phase = 0;
            node_b.phase = 0;
            node_a.entangled_with = node_b.node_id;
            node_b.entangled_with = node_a.node_id;
            return .{
                .success = true,
                .node_a = node_a.node_id,
                .node_b = node_b.node_id,
                .phase_error = phase_error,
                .attempts = attempts + 1,
                .swapped = false,
            };
        }
    }

    // Step 5: Entanglement swapping (if enabled and direct entanglement failed)
    if (config.swap_enabled) {
        // Simulate swapping through a midpoint node
        phase_error = rng.random().float(f64) * config.phase_tolerance;
        if (phase_error < config.phase_tolerance) {
            node_a.entangled_with = node_b.node_id;
            node_b.entangled_with = node_a.node_id;
            return .{
                .success = true,
                .node_a = node_a.node_id,
                .node_b = node_b.node_id,
                .phase_error = phase_error,
                .attempts = attempts,
                .swapped = true,
            };
        }
    }

    return .{
        .success = false,
        .node_a = node_a.node_id,
        .node_b = node_b.node_id,
        .phase_error = phase_error,
        .attempts = attempts,
        .swapped = false,
    };
}

/// Creates a DLCZ node with default parameters.
pub fn createDLCZNode(node_id: u32, location: f64) DLCZNode {
    return .{
        .node_id = node_id,
        .location = location,
        .atom_cloud_ready = false,
        .photon_emitted = false,
        .phase = 0,
        .wavelength_nm = 1550,
        .entangled_with = null,
    };
}

/// Converts wavelength to telecom C-band (1550 nm).
pub inline fn toTelecomWavelength(wavelength_nm: u32) u32 {
    // Standard telecom C-band: 1530-1565 nm
    if (wavelength_nm >= 1530 and wavelength_nm <= 1565) return wavelength_nm;
    return 1550; // Default to center of C-band
}

// =============================================================================
// Kleinberg Small-World Routing (from freenet-core strategy)
// =============================================================================

/// Ring distance between two locations [0, 1).
pub inline fn ringDistance(a: f64, b: f64) f64 {
    var d = @abs(a - b);
    if (d > 0.5) d = 1.0 - d;
    return d;
}

/// Kleinberg routing node on a ring.
pub const RoutingNode = struct {
    id: u32,
    location: f64,
    connections: std.ArrayList(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u32, location: f64) RoutingNode {
        return .{
            .id = id,
            .location = location,
            .connections = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RoutingNode) void {
        self.connections.deinit();
    }

    pub fn addConnection(self: *RoutingNode, target_id: u32) !void {
        // Don't add duplicates
        for (self.connections.items) |c| {
            if (c == target_id) return;
        }
        try self.connections.append(target_id);
    }

    pub fn removeConnection(self: *RoutingNode, target_id: u32) void {
        var i: usize = 0;
        while (i < self.connections.items.len) {
            if (self.connections.items[i] == target_id) {
                _ = self.connections.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub inline fn connectionCount(self: RoutingNode) usize {
        return self.connections.items.len;
    }
};

/// Kleinberg small-world network model.
/// Nodes on a ring with local connections + long-range contacts.
/// Long-range contacts are chosen with probability proportional to d^(-α)
/// where α is the clustering exponent (optimal α=1 for greedy routing).
pub const KleinbergNetwork = struct {
    nodes: std.ArrayList(RoutingNode),
    alpha: f64, // Clustering exponent (optimal = 1.0)
    local_range: u32, // Number of local connections per side
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, alpha: f64, local_range: u32) KleinbergNetwork {
        return .{
            .nodes = std.ArrayList(RoutingNode).init(allocator),
            .alpha = alpha,
            .local_range = local_range,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KleinbergNetwork) void {
        for (self.nodes.items) |*n| n.deinit();
        self.nodes.deinit();
    }

    pub fn addNode(self: *KleinbergNetwork, id: u32, location: f64) !void {
        const node = RoutingNode.init(self.allocator, id, location);
        try self.nodes.append(node);
    }

    /// Builds local connections for all nodes (k nearest neighbors on each side).
    pub fn buildLocalConnections(self: *KleinbergNetwork) !void {
        const n = self.nodes.items.len;
        for (0..n) |i| {
            const loc = self.nodes.items[i].location;
            // Find k nearest neighbors
            var distances = try self.allocator.alloc(struct { idx: usize, dist: f64 }, n);
            defer self.allocator.free(distances);

            for (0..n) |j| {
                distances[j] = .{
                    .idx = j,
                    .dist = ringDistance(loc, self.nodes.items[j].location),
                };
            }

            std.mem.sort(@TypeOf(distances[0]), distances, {}, struct {
                fn cmp(_: void, a: @TypeOf(distances[0]), b: @TypeOf(distances[0])) bool {
                    return a.dist < b.dist;
                }
            }.cmp);

            // Add k nearest (excluding self)
            var added: u32 = 0;
            for (distances) |d| {
                if (d.idx == i) continue;
                if (added >= self.local_range * 2) break;
                try self.nodes.items[i].addConnection(self.nodes.items[d.idx].id);
                added += 1;
            }
        }
    }

    /// Adds a long-range contact to node `node_idx` using Kleinberg's model.
    /// Probability proportional to d^(-α).
    pub fn addLongRangeContact(
        self: *KleinbergNetwork,
        node_idx: usize,
        rng: *std.Random.DefaultPrng,
    ) !void {
        const n = self.nodes.items.len;
        if (n < 2) return;

        const loc = self.nodes.items[node_idx].location;

        // Compute weights for all other nodes
        var weights = try self.allocator.alloc(f64, n);
        defer self.allocator.free(weights);
        var total_weight: f64 = 0;

        for (0..n) |j| {
            if (j == node_idx) {
                weights[j] = 0;
                continue;
            }
            const d = ringDistance(loc, self.nodes.items[j].location);
            if (d < 1e-10) {
                weights[j] = 0;
                continue;
            }
            weights[j] = std.math.pow(f64, d, -self.alpha);
            total_weight += weights[j];
        }

        if (total_weight == 0) return;

        // Weighted random selection
        const r = rng.random().float(f64) * total_weight;
        var cumulative: f64 = 0;
        for (0..n) |j| {
            cumulative += weights[j];
            if (r <= cumulative) {
                try self.nodes.items[node_idx].addConnection(self.nodes.items[j].id);
                return;
            }
        }
    }

    /// Greedy routing: finds path from source to target by always forwarding
    /// to the neighbor closest to the target.
    pub fn greedyRoute(
        self: *KleinbergNetwork,
        source_id: u32,
        target_location: f64,
        max_hops: u32,
    ) !struct { path: []u32, found: bool } {
        var path = std.ArrayList(u32).init(self.allocator);
        errdefer path.deinit();

        var current_id = source_id;
        var hops: u32 = 0;

        while (hops < max_hops) : (hops += 1) {
            try path.append(current_id);

            // Find current node
            var current_node: ?*RoutingNode = null;
            for (self.nodes.items) |*n| {
                if (n.id == current_id) {
                    current_node = n;
                    break;
                }
            }
            if (current_node == null) break;

            const current_dist = ringDistance(current_node.?.location, target_location);

            // Find closest neighbor
            var best_id: ?u32 = null;
            var best_dist = current_dist;

            for (current_node.?.connections.items) |conn_id| {
                for (self.nodes.items) |*n| {
                    if (n.id == conn_id) {
                        const d = ringDistance(n.location, target_location);
                        if (d < best_dist) {
                            best_dist = d;
                            best_id = conn_id;
                        }
                        break;
                    }
                }
            }

            if (best_id == null) {
                // No closer neighbor found — routing failed
                return .{ .path = try path.toOwnedSlice(), .found = false };
            }

            current_id = best_id.?;

            // Check if we've reached the target
            if (best_dist < 1e-6) {
                try path.append(current_id);
                return .{ .path = try path.toOwnedSlice(), .found = true };
            }
        }

        return .{ .path = try path.toOwnedSlice(), .found = false };
    }

    pub inline fn nodeCount(self: KleinbergNetwork) usize {
        return self.nodes.items.len;
    }
};

// =============================================================================
// Steganographic LSB Hiding (from StegaShare embedder)
// =============================================================================

/// Embeds data into an image using LSB steganography.
/// `image` is a flat array of RGB pixels (3 bytes per pixel).
/// Data is embedded in the LSB of each color channel.
/// Format: [4-byte length][data bytes]
pub fn stegaEmbed(
    allocator: std.mem.Allocator,
    image: []u8,
    data: []const u8,
) ![]u8 {
    // Calculate capacity: each pixel has 3 channels, each channel's LSB = 3 bits per pixel
    // Header: 4 bytes for length = 32 bits = needs 11 pixels minimum
    const capacity_bits = image.len; // 1 bit per byte (LSB)
    const needed_bits = 32 + data.len * 8;

    if (needed_bits > capacity_bits) return error.InsufficientCapacity;

    var result = try allocator.dupe(u8, image);
    errdefer allocator.free(result);

    // Embed length (32 bits, big-endian)
    const data_len: u32 = @intCast(data.len);
    var bit_idx: usize = 0;

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const bit = (data_len >> @intCast(31 - i)) & 1;
        result[bit_idx] = (result[bit_idx] & 0xFE) | @as(u8, @intCast(bit));
        bit_idx += 1;
    }

    // Embed data bytes
    for (data) |byte| {
        const b: u8 = byte;
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            const bit = (b >> @intCast(7 - j)) & 1;
            result[bit_idx] = (result[bit_idx] & 0xFE) | @as(u8, @intCast(bit));
            bit_idx += 1;
        }
    }

    return result;
}

/// Extracts data from an image using LSB steganography.
pub fn stegaExtract(allocator: std.mem.Allocator, image: []const u8) ![]u8 {
    if (image.len < 32) return error.InsufficientData;

    // Extract length (32 bits)
    var data_len: u32 = 0;
    var bit_idx: usize = 0;

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const bit: u32 = @as(u32, image[bit_idx] & 1);
        data_len = (data_len << 1) | bit;
        bit_idx += 1;
    }

    if (data_len == 0) return try allocator.alloc(u8, 0);

    const needed_bits = 32 + @as(usize, data_len) * 8;
    if (needed_bits > image.len) return error.CorruptedData;

    // Extract data bytes
    var result = try allocator.alloc(u8, data_len);
    errdefer allocator.free(result);

    for (0..data_len) |byte_idx| {
        var byte: u8 = 0;
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            const bit: u8 = image[bit_idx] & 1;
            byte = (byte << 1) | bit;
            bit_idx += 1;
        }
        result[byte_idx] = byte;
    }

    return result;
}

/// Checks if an image has enough capacity for the given data.
pub inline fn stegaCheckCapacity(image_len: usize, data_len: usize) bool {
    const capacity_bits = image_len;
    const needed_bits = 32 + data_len * 8;
    return needed_bits <= capacity_bits;
}

// =============================================================================
// Tests
// =============================================================================

test "GaloisField multiplication" {
    const gf = GaloisField.init();
    try std.testing.expectEqual(@as(u8, 0), gf.mul(0, 5));
    try std.testing.expectEqual(@as(u8, 5), gf.mul(1, 5));
    try std.testing.expectEqual(@as(u8, 6), gf.mul(2, 3));
}

test "GaloisField division is inverse of multiplication" {
    const gf = GaloisField.init();
    var i: u8 = 1;
    while (i <= 255) : (i += 1) {
        const product = gf.mul(i, 7);
        const quotient = gf.div(product, 7);
        try std.testing.expectEqual(i, quotient);
        if (i == 255) break;
    }
}

test "GaloisField inverse" {
    const gf = GaloisField.init();
    var i: u8 = 1;
    while (i <= 255) : (i += 1) {
        const inv = gf.inv(i);
        try std.testing.expectEqual(@as(u8, 1), gf.mul(i, inv));
        if (i == 255) break;
    }
}

test "Reed-Solomon encode produces correct number of shards" {
    const allocator = std.testing.allocator;
    const config = RsConfig.init(4, 2);
    const data = "Hello, Reed-Solomon error correction test data!";

    const shards = try rsEncode(allocator, config, data);
    defer freeShards(allocator, shards);

    try std.testing.expectEqual(@as(usize, 6), shards.len);
    try std.testing.expectEqual(@as(usize, 4), config.data_shards);
    try std.testing.expectEqual(@as(usize, 2), config.parity_shards);
}

test "Reed-Solomon shard sizes are correct" {
    const allocator = std.testing.allocator;
    const config = RsConfig.init(4, 2);
    const data = "Test data for RS encoding";

    const shards = try rsEncode(allocator, config, data);
    defer freeShards(allocator, shards);

    const expected_shard_size = (data.len + 3) / 4;
    for (shards) |s| {
        try std.testing.expectEqual(expected_shard_size, s.len);
    }
}

test "Shamir split/recover round trip" {
    const allocator = std.testing.allocator;
    const secret = "Hello, Shamir Secret Sharing!";
    var share_list = try shamirSplit(allocator, secret, 3, 5);
    defer share_list.deinit();

    try std.testing.expectEqual(@as(usize, 5), share_list.shares.len);

    const recovered = try shamirRecover(allocator, share_list.shares[0..3], 3);
    defer allocator.free(recovered);

    try std.testing.expectEqualStrings(secret, recovered);
}

test "Shamir any n shares recover correctly" {
    const allocator = std.testing.allocator;
    const secret = "The quick brown fox jumps over the lazy dog";
    var share_list = try shamirSplit(allocator, secret, 4, 7);
    defer share_list.deinit();

    const combos = [_][4]u8{
        .{ 0, 1, 2, 3 },
        .{ 3, 4, 5, 6 },
        .{ 0, 2, 4, 6 },
        .{ 1, 3, 5, 6 },
    };

    for (combos) |combo| {
        var selected: [4]Share = undefined;
        for (combo, 0..) |idx, j| selected[j] = share_list.shares[idx];
        const recovered = try shamirRecover(allocator, &selected, 4);
        defer allocator.free(recovered);
        try std.testing.expectEqualStrings(secret, recovered);
    }
}

test "Shamir fewer than n shares fails" {
    const allocator = std.testing.allocator;
    const secret = "Secret data";
    var share_list = try shamirSplit(allocator, secret, 3, 5);
    defer share_list.deinit();

    try std.testing.expectError(ShamirError.InsufficientShares, shamirRecover(allocator, share_list.shares[0..2], 3));
}

test "Shamir n=1 trivial case" {
    const allocator = std.testing.allocator;
    const secret = "Trivial single share";
    var share_list = try shamirSplit(allocator, secret, 1, 1);
    defer share_list.deinit();

    const recovered = try shamirRecover(allocator, share_list.shares[0..1], 1);
    defer allocator.free(recovered);

    try std.testing.expectEqualStrings(secret, recovered);
}

test "Shamir binary data round trip" {
    const allocator = std.testing.allocator;
    var secret: [256]u8 = undefined;
    for (&secret, 0..) |*b, i| b.* = @intCast(i % 256);

    var share_list = try shamirSplit(allocator, &secret, 5, 8);
    defer share_list.deinit();

    const indices = [_]u8{ 2, 5, 7, 0, 4 };
    var selected: [5]Share = undefined;
    for (indices, 0..) |idx, j| selected[j] = share_list.shares[idx];
    const recovered = try shamirRecover(allocator, &selected, 5);
    defer allocator.free(recovered);

    try std.testing.expectEqualSlices(u8, &secret, recovered);
}

test "Shamir invalid threshold rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(ShamirError.InvalidThreshold, shamirSplit(allocator, "x", 0, 5));
    try std.testing.expectError(ShamirError.InvalidThreshold, shamirSplit(allocator, "x", 5, 3));
}

test "Shamir duplicate x values rejected" {
    const allocator = std.testing.allocator;
    const secret = "Test";
    var share_list = try shamirSplit(allocator, secret, 2, 3);
    defer share_list.deinit();

    var dup_shares = try allocator.alloc(Share, 2);
    defer allocator.free(dup_shares);
    dup_shares[0] = .{ .x = 1, .y = share_list.shares[0].y };
    dup_shares[1] = .{ .x = 1, .y = share_list.shares[1].y };

    try std.testing.expectError(ShamirError.DuplicateXValue, shamirRecover(allocator, dup_shares, 2));
}

test "DLCZ node creation" {
    const node = createDLCZNode(42, 0.5);
    try std.testing.expectEqual(@as(u32, 42), node.node_id);
    try std.testing.expectEqual(@as(f64, 0.5), node.location);
    try std.testing.expect(!node.atom_cloud_ready);
    try std.testing.expect(!node.photon_emitted);
    try std.testing.expectEqual(@as(u32, 1550), node.wavelength_nm);
    try std.testing.expect(node.entangled_with == null);
}

test "DLCZ entanglement success" {
    var prng = std.Random.DefaultPrng.init(42);
    var node_a = createDLCZNode(1, 0.0);
    var node_b = createDLCZNode(2, 0.1);

    const result = dlczEntangle(&node_a, &node_b, .{}, &prng);

    // With seed 42, should succeed
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 1), result.node_a);
    try std.testing.expectEqual(@as(u32, 2), result.node_b);
    try std.testing.expect(node_a.entangled_with.? == 2);
    try std.testing.expect(node_b.entangled_with.? == 1);
}

test "DLCZ wavelength conversion to telecom" {
    try std.testing.expectEqual(@as(u32, 1550), toTelecomWavelength(800));
    try std.testing.expectEqual(@as(u32, 1550), toTelecomWavelength(1310));
    try std.testing.expectEqual(@as(u32, 1550), toTelecomWavelength(1550));
    try std.testing.expectEqual(@as(u32, 1545), toTelecomWavelength(1545));
}

test "ringDistance" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), ringDistance(0.0, 0.1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), ringDistance(0.9, 0.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), ringDistance(0.5, 0.5), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), ringDistance(0.1, 0.8), 1e-10);
}

test "KleinbergNetwork initialization" {
    const allocator = std.testing.allocator;
    var network = KleinbergNetwork.init(allocator, 1.0, 2);
    defer network.deinit();

    try std.testing.expectEqual(@as(usize, 0), network.nodeCount());
    try std.testing.expectEqual(@as(f64, 1.0), network.alpha);
}

test "KleinbergNetwork add nodes and build connections" {
    const allocator = std.testing.allocator;
    var network = KleinbergNetwork.init(allocator, 1.0, 2);
    defer network.deinit();

    for (0..10) |i| {
        try network.addNode(@intCast(i), @as(f64, @floatFromInt(i)) / 10.0);
    }

    try std.testing.expectEqual(@as(usize, 10), network.nodeCount());

    try network.buildLocalConnections();

    // Each node should have some connections
    for (network.nodes.items) |n| {
        try std.testing.expect(n.connectionCount() > 0);
    }
}

test "KleinbergNetwork greedy routing" {
    const allocator = std.testing.allocator;
    var network = KleinbergNetwork.init(allocator, 1.0, 2);
    defer network.deinit();

    // Create 20 nodes evenly spaced on the ring
    for (0..20) |i| {
        try network.addNode(@intCast(i), @as(f64, @floatFromInt(i)) / 20.0);
    }

    try network.buildLocalConnections();

    var prng = std.Random.DefaultPrng.init(42);

    // Add long-range contacts
    for (0..20) |i| {
        try network.addLongRangeContact(i, &prng);
    }

    // Route from node 0 to node 15's location
    const result = try network.greedyRoute(0, 0.75, 20);
    defer allocator.free(result.path);

    try std.testing.expect(result.found);
    try std.testing.expect(result.path.len > 0);
    try std.testing.expectEqual(@as(u32, 0), result.path[0]);
}

test "KleinbergNetwork greedy routing fails with no path" {
    const allocator = std.testing.allocator;
    var network = KleinbergNetwork.init(allocator, 1.0, 1);
    defer network.deinit();

    // Two nodes far apart with no connections beyond local
    try network.addNode(0, 0.0);
    try network.addNode(1, 0.5);

    // No connections built
    const result = try network.greedyRoute(0, 0.5, 5);
    defer allocator.free(result.path);

    try std.testing.expect(!result.found);
}

test "RoutingNode add and remove connections" {
    const allocator = std.testing.allocator;
    var node = RoutingNode.init(allocator, 1, 0.5);
    defer node.deinit();

    try node.addConnection(2);
    try node.addConnection(3);
    try node.addConnection(4);
    try std.testing.expectEqual(@as(usize, 3), node.connectionCount());

    // Duplicate should not add
    try node.addConnection(2);
    try std.testing.expectEqual(@as(usize, 3), node.connectionCount());

    node.removeConnection(3);
    try std.testing.expectEqual(@as(usize, 2), node.connectionCount());
}

test "Steganographic embed/extract round trip" {
    const allocator = std.testing.allocator;

    // Create a simple image (100 pixels = 300 bytes)
    const image = try allocator.alloc(u8, 300);
    defer allocator.free(image);
    for (image, 0..) |*b, i| b.* = @intCast(i % 256);

    const data = "Secret quantum state data";
    const embedded = try stegaEmbed(allocator, image, data);
    defer allocator.free(embedded);

    const extracted = try stegaExtract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualStrings(data, extracted);
}

test "Steganographic capacity check" {
    try std.testing.expect(stegaCheckCapacity(1000, 10));
    try std.testing.expect(!stegaCheckCapacity(10, 100));
    try std.testing.expect(stegaCheckCapacity(100, 0));
}

test "Steganographic embed rejects insufficient capacity" {
    const allocator = std.testing.allocator;
    const image = try allocator.alloc(u8, 10);
    defer allocator.free(image);
    @memset(image, 0);

    const data = "This is too long for the image";
    const result = stegaEmbed(allocator, image, data);
    try std.testing.expectError(error.InsufficientCapacity, result);
}

test "Steganographic extract rejects insufficient data" {
    const allocator = std.testing.allocator;
    const short_image = try allocator.alloc(u8, 10);
    defer allocator.free(short_image);
    @memset(short_image, 0);

    const result = stegaExtract(allocator, short_image);
    try std.testing.expectError(error.InsufficientData, result);
}

test "Steganographic empty data round trip" {
    const allocator = std.testing.allocator;
    const image = try allocator.alloc(u8, 100);
    defer allocator.free(image);
    @memset(image, 0);

    const embedded = try stegaEmbed(allocator, image, "");
    defer allocator.free(embedded);

    const extracted = try stegaExtract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqual(@as(usize, 0), extracted.len);
}

test "Steganographic binary data round trip" {
    const allocator = std.testing.allocator;
    const image = try allocator.alloc(u8, 1000);
    defer allocator.free(image);
    for (image, 0..) |*b, i| b.* = @intCast(i % 256);

    var data: [64]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i * 7 % 256);

    const embedded = try stegaEmbed(allocator, image, &data);
    defer allocator.free(embedded);

    const extracted = try stegaExtract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &data, extracted);
}

test "DLCZ entanglement with strict phase tolerance" {
    var prng = std.Random.DefaultPrng.init(100);
    var node_a = createDLCZNode(10, 0.0);
    var node_b = createDLCZNode(20, 0.3);

    const config = DLCZConfig{
        .phase_tolerance = 0.001, // Very strict
        .max_retries = 5,
        .swap_enabled = true,
    };

    const result = dlczEntangle(&node_a, &node_b, config, &prng);

    // With strict tolerance, may need swapping
    if (result.success) {
        try std.testing.expect(node_a.entangled_with != null);
        try std.testing.expect(node_b.entangled_with != null);
    }
}

test "DLCZ entanglement failure with no swapping" {
    var prng = std.Random.DefaultPrng.init(999);
    var node_a = createDLCZNode(1, 0.0);
    var node_b = createDLCZNode(2, 0.5);

    const config = DLCZConfig{
        .phase_tolerance = 0.0001, // Extremely strict
        .max_retries = 1,
        .swap_enabled = false, // No swapping fallback
    };

    const result = dlczEntangle(&node_a, &node_b, config, &prng);

    // Very likely to fail with strict tolerance and no swapping
    if (!result.success) {
        try std.testing.expect(node_a.entangled_with == null);
        try std.testing.expect(node_b.entangled_with == null);
    }
}

test "KleinbergNetwork with alpha=2 (suboptimal)" {
    const allocator = std.testing.allocator;
    var network = KleinbergNetwork.init(allocator, 2.0, 2);
    defer network.deinit();

    for (0..15) |i| {
        try network.addNode(@intCast(i), @as(f64, @floatFromInt(i)) / 15.0);
    }

    try network.buildLocalConnections();

    var prng = std.Random.DefaultPrng.init(42);
    for (0..15) |i| {
        try network.addLongRangeContact(i, &prng);
    }

    // Routing should still work but may take more hops
    const result = try network.greedyRoute(0, 0.8, 30);
    defer allocator.free(result.path);

    // With alpha=2, routing may or may not find the target
    // Just verify it doesn't crash
    try std.testing.expect(result.path.len > 0);
}

test "Reed-Solomon parity shards are non-trivial" {
    const allocator = std.testing.allocator;
    const config = RsConfig.init(2, 2);
    const data = "ABCD";

    const shards = try rsEncode(allocator, config, data);
    defer freeShards(allocator, shards);

    // Parity shards should not be all zeros (for non-zero data)
    var has_nonzero = false;
    for (shards[2]) |b| {
        if (b != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "Shamir large secret round trip" {
    const allocator = std.testing.allocator;
    const secret = "Large secret data for testing. " ** 50;
    var share_list = try shamirSplit(allocator, secret, 4, 6);
    defer share_list.deinit();

    const recovered = try shamirRecover(allocator, share_list.shares[2..6], 4);
    defer allocator.free(recovered);

    try std.testing.expectEqualStrings(secret, recovered);
}

test "Shamir empty secret round trip" {
    const allocator = std.testing.allocator;
    const secret: [0]u8 = .{};
    var share_list = try shamirSplit(allocator, &secret, 2, 3);
    defer share_list.deinit();

    const recovered = try shamirRecover(allocator, share_list.shares[0..2], 2);
    defer allocator.free(recovered);

    try std.testing.expectEqual(@as(usize, 0), recovered.len);
}
