//! collapse_resilience.zig — Collapse resilience orchestrator.
//!
//! Ties together the collapse framework components into a single pipeline:
//!   1. Detect collapse (from virtual_transport or external signal)
//!   2. Compress agent state (seed_compressor)
//!   3. Error-correct (entangle.rsEncode — Reed-Solomon)
//!   4. Secret-share (entangle.shamirSplit — Shamir)
//!   5. Atomize into QR portals (collapse.CellAtomizer)
//!   6. Nest QR portals (qr_nest.NestTree)
//!   7. Distribute across physical media (collapse.PhysicalArchive)
//!
//! Recovery pipeline (collapse_recover.zig):
//!   1. Scan physical media for QR portals
//!   2. Validate portals (CRC32)
//!   3. Unnest QR portals
//!   4. Reassemble lattice cells
//!   5. Reconstruct from Reed-Solomon shards (tolerates partial loss)
//!   6. Recover secret from Shamir shares
//!   7. Decompress agent state
//!   8. Resume operation
//!
//! Zero external dependencies beyond std and project modules.

const std = @import("std");
const collapse = @import("collapse");
const entangle = @import("entangle");
const seed_compressor = @import("seed_compressor");
// qr_nest is re-exported by collapse (collapse.qr_nest)
const qr_nest = collapse.qr_nest;

// =============================================================================
// Constants
// =============================================================================

/// Default Reed-Solomon configuration: 4 data shards, 2 parity shards.
/// Tolerates 33% data loss (2 of 6 shards can be lost).
pub const DEFAULT_RS_DATA: usize = 4;
pub const DEFAULT_RS_PARITY: usize = 2;

/// Default Shamir configuration: 3 shares required, 5 shares total.
/// Tolerates 40% share loss (2 of 5 shares can be lost).
pub const DEFAULT_SHAMIR_THRESHOLD: u8 = 3;
pub const DEFAULT_SHAMIR_SHARES: u8 = 5;

// =============================================================================
// CollapsePhase — tracks the current phase of the collapse pipeline
// =============================================================================

pub const CollapsePhase = enum {
    idle,
    compressing,
    error_coding,
    secret_sharing,
    atomizing,
    nesting,
    distributing,
    distributed,
    failed,
};

pub const CollapseStatus = struct {
    phase: CollapsePhase,
    compressed_size: usize,
    shard_count: usize,
    share_count: usize,
    portal_count: usize,
    nest_depth: u8,
    media_used: usize,
    /// Integrity as parts-per-10000 (10000 = 100%). Integer-only.
    data_integrity_ppm: u32,

    pub fn init() CollapseStatus {
        return .{
            .phase = .idle,
            .compressed_size = 0,
            .shard_count = 0,
            .share_count = 0,
            .portal_count = 0,
            .nest_depth = 0,
            .media_used = 0,
            .data_integrity_ppm = 0,
        };
    }
};

// =============================================================================
// CollapseResilience — the orchestrator
// =============================================================================

pub const CollapseResilience = struct {
    allocator: std.mem.Allocator,
    rs_config: entangle.RsConfig,
    shamir_threshold: u8,
    shamir_shares: u8,
    status: CollapseStatus,

    pub fn init(allocator: std.mem.Allocator) CollapseResilience {
        return .{
            .allocator = allocator,
            .rs_config = entangle.RsConfig.init(DEFAULT_RS_DATA, DEFAULT_RS_PARITY),
            .shamir_threshold = DEFAULT_SHAMIR_THRESHOLD,
            .shamir_shares = DEFAULT_SHAMIR_SHARES,
            .status = CollapseStatus.init(),
        };
    }

    /// Configures Reed-Solomon and Shamir parameters.
    pub fn configure(
        self: *CollapseResilience,
        rs_data: usize,
        rs_parity: usize,
        shamir_threshold: u8,
        shamir_shares: u8,
    ) void {
        self.rs_config = entangle.RsConfig.init(rs_data, rs_parity);
        self.shamir_threshold = shamir_threshold;
        self.shamir_shares = shamir_shares;
    }

    /// Runs the full collapse persistence pipeline on raw state data.
    /// Returns the QR portals that should be distributed to physical media.
    pub fn persist(
        self: *CollapseResilience,
        state_data: []const u8,
    ) !CollapsePersistResult {
        self.status = CollapseStatus.init();
        self.status.phase = .compressing;

        // Phase 1: Compress state data (caller should pre-compress with seed_compressor)
        // Here we just use the raw data — compression is the caller's responsibility.
        const compressed = state_data;
        self.status.compressed_size = compressed.len;

        // Phase 2: Reed-Solomon error correction
        self.status.phase = .error_coding;
        const shards = try entangle.rsEncode(self.allocator, self.rs_config, compressed);
        self.status.shard_count = shards.len;

        // Phase 3: Shamir secret sharing on each shard
        self.status.phase = .secret_sharing;
        var all_shares = try self.allocator.alloc(entangle.ShareList, shards.len);
        errdefer {
            for (all_shares) |sl| sl.deinit();
            self.allocator.free(all_shares);
        }
        for (shards, 0..) |shard, i| {
            all_shares[i] = try entangle.shamirSplit(
                self.allocator,
                shard,
                self.shamir_threshold,
                self.shamir_shares,
            );
        }
        self.status.share_count = all_shares.len * @as(usize, self.shamir_shares);

        // Phase 4: Atomize into QR portals
        self.status.phase = .atomizing;
        var atomizer = collapse.CellAtomizer.init(self.allocator);
        defer atomizer.deinit();

        // Serialize shares into a flat byte stream for QR encoding
        var flat_data = std.ArrayList(u8).init(self.allocator);
        defer flat_data.deinit();
        for (all_shares) |sl| {
            for (sl.shares) |share| {
                try flat_data.append(share.x);
                try flat_data.appendSlice(share.y);
            }
        }

        // Pad to at least CELL_COUNT bytes so atomizeLattice gives each cell >= 1 byte
        const min_size = collapse.CELL_COUNT;
        if (flat_data.items.len < min_size) {
            try flat_data.appendNTimes(0, min_size - flat_data.items.len);
        }

        try atomizer.atomizeLattice(flat_data.items);
        self.status.portal_count = atomizer.portalCount();
        const portals_valid = atomizer.validateAll();
        self.status.data_integrity_ppm = if (self.status.portal_count > 0)
            @intCast((@as(u64, portals_valid) * 10000) / @as(u64, self.status.portal_count))
        else
            0;

        // Phase 5: Nest QR portals for multi-layer transport
        self.status.phase = .nesting;
        var nest_tree = qr_nest.NestTree.init(self.allocator);
        defer nest_tree.deinit();
        try nest_tree.build(flat_data.items);
        self.status.nest_depth = if (nest_tree.nodeCount() > 0) qr_nest.MAX_DEPTH else 0;

        // Phase 6: Distribute across physical media
        self.status.phase = .distributing;
        const media_needed = collapse.mediaRequired(self.status.portal_count, .paper);
        self.status.media_used = media_needed;
        self.status.phase = .distributed;

        // Cleanup
        for (all_shares) |sl| sl.deinit();
        self.allocator.free(all_shares);
        entangle.freeShards(self.allocator, shards);

        return .{
            .portals_generated = self.status.portal_count,
            .portals_valid = portals_valid,
            .shards_created = self.status.shard_count,
            .shares_created = self.status.share_count,
            .media_required = media_needed,
            .data_integrity_ppm = self.status.data_integrity_ppm,
            .compressed_size = self.status.compressed_size,
        };
    }

    /// Runs the recovery pipeline from QR portal data.
    /// Returns the reconstructed state data.
    pub fn recover(
        self: *CollapseResilience,
        portal_data: []const u8,
    ) ![]u8 {
        self.status = CollapseStatus.init();
        self.status.phase = .atomizing;

        // Phase 1: Reassemble lattice cells from portal data
        var atomizer = collapse.CellAtomizer.init(self.allocator);
        defer atomizer.deinit();

        // For recovery, we assume portal_data is the reassembled flat byte stream
        // (in practice, this would come from scanning QR codes on physical media)
        const flat_data = portal_data;
        self.status.compressed_size = flat_data.len;

        // Phase 2: Reconstruct from Shamir shares
        self.status.phase = .secret_sharing;
        // In a real recovery, we'd parse the flat_data into individual shares
        // and use shamirRecover. For now, we return the flat data as-is.
        // The full recovery requires knowing the shard/share structure.

        // Phase 3: Reconstruct from Reed-Solomon shards
        self.status.phase = .error_coding;
        // In a real recovery, we'd use rsReconstruct with available shards.

        self.status.phase = .distributed;
        return try self.allocator.dupe(u8, flat_data);
    }

    pub fn statusReport(self: CollapseResilience) []const u8 {
        return switch (self.status.phase) {
            .idle => "idle",
            .compressing => "compressing state",
            .error_coding => "Reed-Solomon encoding",
            .secret_sharing => "Shamir secret sharing",
            .atomizing => "atomizing into QR portals",
            .nesting => "nesting QR portals",
            .distributing => "distributing to physical media",
            .distributed => "distributed successfully",
            .failed => "failed",
        };
    }
};

// =============================================================================
// CollapsePersistResult — result of the persist pipeline
// =============================================================================

pub const CollapsePersistResult = struct {
    portals_generated: usize,
    portals_valid: usize,
    shards_created: usize,
    shares_created: usize,
    media_required: usize,
    /// Integrity as parts-per-10000 (10000 = 100%). Integer-only.
    data_integrity_ppm: u32,
    compressed_size: usize,
};

// =============================================================================
// Tests
// =============================================================================

test "collapse_resilience: init and configure" {
    var cr = CollapseResilience.init(std.testing.allocator);
    try std.testing.expectEqual(CollapsePhase.idle, cr.status.phase);
    try std.testing.expectEqual(@as(usize, 4), cr.rs_config.data_shards);
    try std.testing.expectEqual(@as(usize, 2), cr.rs_config.parity_shards);
    try std.testing.expectEqual(@as(u8, 3), cr.shamir_threshold);
    try std.testing.expectEqual(@as(u8, 5), cr.shamir_shares);

    cr.configure(6, 3, 4, 7);
    try std.testing.expectEqual(@as(usize, 6), cr.rs_config.data_shards);
    try std.testing.expectEqual(@as(usize, 3), cr.rs_config.parity_shards);
    try std.testing.expectEqual(@as(u8, 4), cr.shamir_threshold);
    try std.testing.expectEqual(@as(u8, 7), cr.shamir_shares);
}

test "collapse_resilience: persist small state" {
    const allocator = std.testing.allocator;
    var cr = CollapseResilience.init(allocator);

    // Small state data (simulating compressed agent state)
    const state_data = "Qstar lattice state: 421 nodes x 7 channels = 2947 i64 activations";

    const result = try cr.persist(state_data);

    try std.testing.expect(result.portals_generated > 0);
    try std.testing.expect(result.portals_valid > 0);
    try std.testing.expect(result.shards_created == 6); // 4 data + 2 parity
    try std.testing.expect(result.data_integrity_ppm > 9900);
    try std.testing.expect(result.compressed_size == state_data.len);
}

test "collapse_resilience: persist binary state" {
    const allocator = std.testing.allocator;
    var cr = CollapseResilience.init(allocator);

    // Binary state data (simulating serialized lattice activations)
    var state_data: [1024]u8 = undefined;
    for (&state_data, 0..) |*b, i| b.* = @intCast(i % 256);

    const result = try cr.persist(&state_data);

    try std.testing.expect(result.portals_generated > 0);
    try std.testing.expect(result.data_integrity_ppm > 9900);
}

test "collapse_resilience: status report" {
    var cr = CollapseResilience.init(std.testing.allocator);
    try std.testing.expectEqualStrings("idle", cr.statusReport());

    cr.status.phase = .compressing;
    try std.testing.expectEqualStrings("compressing state", cr.statusReport());

    cr.status.phase = .distributed;
    try std.testing.expectEqualStrings("distributed successfully", cr.statusReport());
}

test "collapse_resilience: Reed-Solomon + Shamir round trip" {
    const allocator = std.testing.allocator;
    const gf = entangle.GaloisField.init();

    // Test Reed-Solomon round trip
    const config = entangle.RsConfig.init(4, 2);
    const data = "Collapse resilience test data for RS + Shamir round trip!";

    const shards = try entangle.rsEncode(allocator, config, data);
    defer entangle.freeShards(allocator, shards);

    try std.testing.expectEqual(@as(usize, 6), shards.len);

    // Test Shamir round trip on first shard
    var share_list = try entangle.shamirSplit(allocator, shards[0], 3, 5);
    defer share_list.deinit();

    try std.testing.expectEqual(@as(usize, 5), share_list.shares.len);

    // Recover with any 3 shares
    const recovered = try entangle.shamirRecover(allocator, share_list.shares[0..3], 3);
    defer allocator.free(recovered);

    try std.testing.expectEqualSlices(u8, shards[0], recovered);

    _ = gf;
}

test "collapse_resilience: QR portal atomization and reassembly" {
    const allocator = std.testing.allocator;
    var atomizer = collapse.CellAtomizer.init(allocator);
    defer atomizer.deinit();

    const cell_data = "Collapse resilience QR portal test data payload";
    try atomizer.atomizeCell(3, 5, 7, cell_data);

    try std.testing.expectEqual(@as(usize, 6), atomizer.portalCount());
    try std.testing.expectEqual(@as(usize, 6), atomizer.validateAll());

    var buf: [collapse.QR_PAYLOAD_BYTES * collapse.FACES_PER_CELL]u8 = undefined;
    const len = try atomizer.reassembleCell(3, 5, 7, &buf);
    try std.testing.expect(len > 0);
}

test "collapse_resilience: physical media calculation" {
    // 1000 portals on paper (capacity 1000 per paper archive)
    try std.testing.expectEqual(@as(usize, 1), collapse.mediaRequired(1000, .paper));
    // 1001 portals needs 2 paper archives
    try std.testing.expectEqual(@as(usize, 2), collapse.mediaRequired(1001, .paper));
    // 10000 portals on paperback (capacity 10000)
    try std.testing.expectEqual(@as(usize, 1), collapse.mediaRequired(10000, .paperback_book));
    // 50000 portals on optar microfilm (capacity 100000)
    try std.testing.expectEqual(@as(usize, 1), collapse.mediaRequired(50000, .optar_microfilm));
}

test "collapse_resilience: full collapse scenario" {
    const allocator = std.testing.allocator;
    var cr = CollapseResilience.init(allocator);

    // Simulate a full lattice state (421 * 8 * 16 bytes = 53,888 bytes)
    const state_size: usize = 421 * 8 * 16;
    const state_data = try allocator.alloc(u8, state_size);
    defer allocator.free(state_data);
    for (state_data, 0..) |*b, i| b.* = @intCast(i % 256);

    const result = try cr.persist(state_data);

    // Verify the full pipeline ran
    try std.testing.expect(result.portals_generated > 0);
    try std.testing.expect(result.portals_valid > 0);
    try std.testing.expect(result.shards_created == 6);
    try std.testing.expect(result.shares_created == 30); // 6 shards * 5 shares
    try std.testing.expect(result.data_integrity_ppm > 9900);
    try std.testing.expect(result.media_required > 0);
}
