//! collapse_recover.zig — Recovery orchestrator for collapse resilience.
//!
//! Mirrors collapse_resilience.zig but handles the RECOVERY side:
//!   1. Scan: Find QR portals on physical media
//!   2. Validate: CRC32 check on each portal
//!   3. Reassemble: Reconstruct lattice cells from valid portals
//!   4. Reconstruct: Reed-Solomon recovery from partial loss
//!   5. Recover: Shamir secret sharing reconstruction
//!   6. Decompress: Restore agent state from compressed seed
//!   7. Resume: Agent continues operation with restored state

const std = @import("std");
const entangle = @import("entangle");
const collapse = @import("collapse");

// =============================================================================
// Recovery Result
// =============================================================================

pub const RecoveryResult = struct {
    portals_recovered: usize = 0,
    portals_corrupted: usize = 0,
    cells_reassembled: usize = 0,
    rs_shards_used: usize = 0,
    rs_shards_lost: usize = 0,
    shamir_shares_used: usize = 0,
    /// Integrity as parts-per-10000 (10000 = 100%). Integer-only.
    data_integrity_ppm: u32 = 0,
    recovered_data: []u8 = &.{},
    allocator: std.mem.Allocator = undefined,

    pub fn deinit(self: *RecoveryResult) void {
        if (self.recovered_data.len > 0) {
            self.allocator.free(self.recovered_data);
        }
    }

    pub fn isComplete(self: RecoveryResult) bool {
        return self.data_integrity_ppm > 9900;
    }
};

// =============================================================================
// Portal Recovery
// =============================================================================

/// Validates a set of QR portals and separates valid from corrupted.
pub fn validatePortals(
    portals: []collapse.QRPortal,
) struct { valid: usize, corrupted: usize } {
    var valid: usize = 0;
    var corrupted: usize = 0;
    for (portals) |*p| {
        if (p.validate()) {
            valid += 1;
        } else {
            corrupted += 1;
        }
    }
    return .{ .valid = valid, .corrupted = corrupted };
}

/// Reassembles lattice cells from valid QR portals.
/// Returns the recovered data bytes.
pub fn reassembleFromPortals(
    allocator: std.mem.Allocator,
    portals: []collapse.QRPortal,
) ![]u8 {
    var valid_portals = std.ArrayList(collapse.QRPortal).init(allocator);
    defer valid_portals.deinit();

    for (portals) |p| {
        if (p.validate()) {
            try valid_portals.append(p);
        }
    }

    if (valid_portals.items.len == 0) return error.NoValidPortals;

    // Sort portals by cell_x for deterministic reassembly order
    std.mem.sort(collapse.QRPortal, valid_portals.items, {}, struct {
        fn cmp(_: void, a: collapse.QRPortal, b: collapse.QRPortal) bool {
            if (a.cell_x != b.cell_x) return a.cell_x < b.cell_x;
            if (a.cell_y != b.cell_y) return a.cell_y < b.cell_y;
            return a.cell_z < b.cell_z;
        }
    }.cmp);

    // Reassemble data from portal payloads
    var data = std.ArrayList(u8).init(allocator);
    errdefer data.deinit();

    for (valid_portals.items) |p| {
        try data.appendSlice(p.payload[0..p.payload_len]);
    }

    return try data.toOwnedSlice();
}

// =============================================================================
// Reed-Solomon Recovery
// =============================================================================

/// Recovers data from Reed-Solomon shards, tolerating partial loss.
/// Requires at least `k` surviving shards out of `n` total.
pub fn recoverWithReedSolomon(
    allocator: std.mem.Allocator,
    shards: []entangle.Shard,
    k: usize,
) ![]u8 {
    if (shards.len < k) return error.InsufficientShards;

    // Count valid shards
    var valid_count: usize = 0;
    for (shards) |s| {
        if (s.data.len > 0) valid_count += 1;
    }

    if (valid_count < k) return error.InsufficientValidShards;

    // Use entangle's RS reconstruct
    const config = entangle.RsConfig{
        .n = shards.len,
        .k = k,
    };

    return try entangle.rsReconstruct(allocator, shards, config);
}

// =============================================================================
// Shamir Secret Recovery
// =============================================================================

/// Recovers a secret from Shamir shares.
/// Requires at least `threshold` shares out of `total`.
pub fn recoverWithShamir(
    allocator: std.mem.Allocator,
    shares: []entangle.Share,
    threshold: usize,
) ![]u8 {
    if (shares.len < threshold) return error.InsufficientShares;

    // Filter valid shares
    var valid_shares = std.ArrayList(entangle.Share).init(allocator);
    defer valid_shares.deinit();

    for (shares) |s| {
        if (s.x != 0) {
            try valid_shares.append(s);
        }
    }

    if (valid_shares.items.len < threshold) return error.InsufficientValidShares;

    return try entangle.shamirRecover(allocator, valid_shares.items, threshold);
}

// =============================================================================
// Full Recovery Pipeline
// =============================================================================

/// Full recovery pipeline: validate portals → reassemble → verify integrity.
pub fn fullRecovery(
    allocator: std.mem.Allocator,
    portals: []collapse.QRPortal,
) !RecoveryResult {
    var result = RecoveryResult{ .allocator = allocator };

    // Step 1: Validate portals
    const validation = validatePortals(portals);
    result.portals_recovered = validation.valid;
    result.portals_corrupted = validation.corrupted;

    if (validation.valid == 0) return result;

    // Step 2: Reassemble from valid portals
    const data = reassembleFromPortals(allocator, portals) catch return result;
    result.recovered_data = data;
    result.cells_reassembled = validation.valid;

    // Step 3: Compute integrity
    const total = validation.valid + validation.corrupted;
    result.data_integrity_ppm = @intCast((@as(u64, validation.valid) * 10000) / @as(u64, total));

    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "collapse_recover: validate portals all valid" {
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("test1");
    var p2 = collapse.QRPortal.init(1, 0, 0, 0);
    p2.setPayload("test2");

    var portals = [_]collapse.QRPortal{ p1, p2 };
    const result = validatePortals(&portals);
    try std.testing.expectEqual(@as(usize, 2), result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.corrupted);
}

test "collapse_recover: validate portals with corruption" {
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("test1");
    var p2 = collapse.QRPortal.init(1, 0, 0, 0);
    p2.setPayload("test2");

    // Corrupt the second portal's payload (after checksum was computed)
    p2.payload[0] = 'X';

    var portals = [_]collapse.QRPortal{ p1, p2 };
    const result = validatePortals(&portals);
    try std.testing.expectEqual(@as(usize, 1), result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.corrupted);
}

test "collapse_recover: reassemble from valid portals" {
    const allocator = std.testing.allocator;
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("Hello ");
    var p2 = collapse.QRPortal.init(1, 0, 0, 0);
    p2.setPayload("World!");

    var portals = [_]collapse.QRPortal{ p1, p2 };
    const data = try reassembleFromPortals(allocator, &portals);
    defer allocator.free(data);

    try std.testing.expectEqualStrings("Hello World!", data);
}

test "collapse_recover: reassemble skips corrupted portals" {
    const allocator = std.testing.allocator;
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("Hello ");
    var p2 = collapse.QRPortal.init(1, 0, 0, 0);
    p2.setPayload("World!");
    p2.payload[0] = 'X'; // Corrupt after checksum

    var portals = [_]collapse.QRPortal{ p1, p2 };
    const data = try reassembleFromPortals(allocator, &portals);
    defer allocator.free(data);

    try std.testing.expectEqualStrings("Hello ", data);
}

test "collapse_recover: no valid portals returns error" {
    const allocator = std.testing.allocator;
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("test");
    p1.payload[0] = 'X'; // Corrupt

    var portals = [_]collapse.QRPortal{p1};
    const result = reassembleFromPortals(allocator, &portals);
    try std.testing.expectError(error.NoValidPortals, result);
}

test "collapse_recover: full recovery with all valid portals" {
    const allocator = std.testing.allocator;
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("Data chunk 1");
    var p2 = collapse.QRPortal.init(1, 0, 0, 0);
    p2.setPayload("Data chunk 2");

    var portals = [_]collapse.QRPortal{ p1, p2 };
    var result = try fullRecovery(allocator, &portals);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.portals_recovered);
    try std.testing.expectEqual(@as(usize, 0), result.portals_corrupted);
    try std.testing.expect(result.data_integrity_ppm > 9900);
    try std.testing.expect(result.isComplete());
}

test "collapse_recover: full recovery with partial corruption" {
    const allocator = std.testing.allocator;
    var p1 = collapse.QRPortal.init(0, 0, 0, 0);
    p1.setPayload("Valid data");
    var p2 = collapse.QRPortal.init(1, 0, 0, 0);
    p2.setPayload("Corrupted");
    p2.payload[0] = 'X'; // Corrupt

    var portals = [_]collapse.QRPortal{ p1, p2 };
    var result = try fullRecovery(allocator, &portals);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.portals_recovered);
    try std.testing.expectEqual(@as(usize, 1), result.portals_corrupted);
    try std.testing.expect(result.data_integrity_ppm >= 4900 and result.data_integrity_ppm <= 5100);
    try std.testing.expect(!result.isComplete());
}

test "collapse_recover: empty portal list" {
    const portals = [_]collapse.QRPortal{};

    var result = try fullRecovery(std.testing.allocator, &portals);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.portals_recovered);
    try std.testing.expectEqual(@as(u32, 0), result.data_integrity_ppm);
}

test "collapse_recover: reassemble preserves portal order" {
    const allocator = std.testing.allocator;
    var p2 = collapse.QRPortal.init(2, 0, 0, 0);
    p2.setPayload("C");
    var p0 = collapse.QRPortal.init(0, 0, 0, 0);
    p0.setPayload("A");
    var p1 = collapse.QRPortal.init(1, 0, 0, 0);
    p1.setPayload("B");

    var portals = [_]collapse.QRPortal{ p2, p0, p1 };
    const data = try reassembleFromPortals(allocator, &portals);
    defer allocator.free(data);

    // Portals should be sorted by cell_x: A, B, C
    try std.testing.expectEqualStrings("ABC", data);
}
