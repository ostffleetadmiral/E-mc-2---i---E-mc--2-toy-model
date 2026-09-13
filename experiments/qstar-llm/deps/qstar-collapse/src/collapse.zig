//! collapse.zig — Civilization collapse resilience: cell atomization and physical transport.
//!
//! Encodes lattice cells into 20,250 QR portals (15³ × 6 faces) for robust
//! physical transport. Tests the full collapse scenario: digital infrastructure
//! fails, data survives via QR codes on physical media.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

pub const qr_nest = @import("qr_nest.zig");

// =============================================================================
// Constants
// =============================================================================

pub const BASE_EDGE: u32 = 15;
pub const CELL_COUNT: usize = 3375; // 15³
pub const FACES_PER_CELL: usize = 6;
pub const TOTAL_FACE_PAYLOADS: usize = CELL_COUNT * FACES_PER_CELL; // 20,250

/// QR code capacity (version 10, byte mode).
pub const QR_CAPACITY_BYTES: usize = 271;

/// Maximum data per QR portal (with header overhead).
pub const QR_PAYLOAD_BYTES: usize = 256;

// =============================================================================
// QRPortal — a single QR-encoded lattice face
// =============================================================================

pub const QRPortal = struct {
    /// Cell coordinates.
    cell_x: u32,
    cell_y: u32,
    cell_z: u32,
    /// Face axis (0-5).
    face_axis: u8,
    /// Payload data (up to 256 bytes).
    payload: [QR_PAYLOAD_BYTES]u8,
    /// Actual payload length.
    payload_len: usize,
    /// CRC32 for integrity.
    checksum: u32,

    pub fn init(cell_x: u32, cell_y: u32, cell_z: u32, face_axis: u8) QRPortal {
        return .{
            .cell_x = cell_x,
            .cell_y = cell_y,
            .cell_z = cell_z,
            .face_axis = face_axis,
            .payload = [_]u8{0} ** QR_PAYLOAD_BYTES,
            .payload_len = 0,
            .checksum = 0,
        };
    }

    pub fn setPayload(self: *QRPortal, data: []const u8) void {
        const n = @min(data.len, QR_PAYLOAD_BYTES);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.payload[i] = data[i];
        }
        self.payload_len = n;
        self.computeChecksum();
    }

    fn computeChecksum(self: *QRPortal) void {
        var local_payload: [QR_PAYLOAD_BYTES]u8 = undefined;
        const plen = self.payload_len;
        var i: usize = 0;
        while (i < plen) : (i += 1) {
            local_payload[i] = self.payload[i];
        }
        var hasher = std.hash.Crc32.init();
        hasher.update(local_payload[0..plen]);
        hasher.update(std.mem.asBytes(&self.cell_x));
        hasher.update(std.mem.asBytes(&self.cell_y));
        hasher.update(std.mem.asBytes(&self.cell_z));
        hasher.update(std.mem.asBytes(&self.face_axis));
        self.checksum = hasher.final();
    }

    pub fn validate(self: *const QRPortal) bool {
        var hasher = std.hash.Crc32.init();
        hasher.update(self.payload[0..self.payload_len]);
        hasher.update(std.mem.asBytes(&self.cell_x));
        hasher.update(std.mem.asBytes(&self.cell_y));
        hasher.update(std.mem.asBytes(&self.cell_z));
        hasher.update(std.mem.asBytes(&self.face_axis));
        return hasher.final() == self.checksum;
    }

    /// Get the payload data.
    pub inline fn getPayload(self: *const QRPortal) []const u8 {
        return self.payload[0..self.payload_len];
    }
};

// =============================================================================
// CellAtomizer — encodes lattice cells into QR portals
// =============================================================================

pub const CellAtomizer = struct {
    allocator: std.mem.Allocator,
    portals: std.ArrayList(QRPortal),

    pub fn init(allocator: std.mem.Allocator) CellAtomizer {
        return .{
            .allocator = allocator,
            .portals = std.ArrayList(QRPortal).init(allocator),
        };
    }

    pub fn deinit(self: *CellAtomizer) void {
        self.portals.deinit();
    }

    /// Atomize a single cell into 6 QR portals (one per face).
    pub fn atomizeCell(self: *CellAtomizer, x: u32, y: u32, z: u32, cell_data: []const u8) !void {
        const data_per_face = (cell_data.len + FACES_PER_CELL - 1) / FACES_PER_CELL;
        for (0..FACES_PER_CELL) |face| {
            var portal = QRPortal.init(x, y, z, @intCast(face));
            const start = face * data_per_face;
            const end = @min(start + data_per_face, cell_data.len);
            if (start < cell_data.len) {
                portal.setPayload(cell_data[start..end]);
            }
            try self.portals.append(portal);
        }
    }

    /// Atomize an entire lattice (15³ cells) into 20,250 QR portals.
    pub fn atomizeLattice(self: *CellAtomizer, lattice_data: []const u8) !void {
        const cell_size = lattice_data.len / CELL_COUNT;
        var idx: usize = 0;
        var x: u32 = 0;
        while (x < BASE_EDGE) : (x += 1) {
            var y: u32 = 0;
            while (y < BASE_EDGE) : (y += 1) {
                var z: u32 = 0;
                while (z < BASE_EDGE) : (z += 1) {
                    const start = idx * cell_size;
                    const end = @min(start + cell_size, lattice_data.len);
                    try self.atomizeCell(x, y, z, lattice_data[start..end]);
                    idx += 1;
                }
            }
        }
    }

    /// Get all generated portals.
    pub inline fn getPortals(self: *const CellAtomizer) []const QRPortal {
        return self.portals.items;
    }

    /// Number of portals generated.
    pub inline fn portalCount(self: *const CellAtomizer) usize {
        return self.portals.items.len;
    }

    /// Reconstruct cell data from 6 face portals.
    pub fn reassembleCell(self: *const CellAtomizer, x: u32, y: u32, z: u32, out: []u8) !usize {
        var total: usize = 0;
        for (self.portals.items) |*portal| {
            if (portal.cell_x == x and portal.cell_y == y and portal.cell_z == z) {
                const payload = portal.getPayload();
                const copy_len = @min(payload.len, out.len - total);
                var i: usize = 0;
                while (i < copy_len) : (i += 1) {
                    out[total + i] = payload[i];
                }
                total += copy_len;
            }
        }
        return total;
    }

    /// Validate all portals.
    pub fn validateAll(self: *const CellAtomizer) usize {
        var valid: usize = 0;
        for (self.portals.items) |*portal| {
            if (portal.validate()) valid += 1;
        }
        return valid;
    }
};

// =============================================================================
// CollapseScenario — simulates civilization collapse and recovery
// =============================================================================

pub const CollapsePhase = enum {
    pre_collapse,
    atomization,
    physical_distribution,
    post_collapse,
    recovery_scan,
    reassembly,
    verification,
    complete,
};

pub const CollapseResult = struct {
    portals_generated: usize,
    portals_valid: usize,
    cells_reassembled: usize,
    data_integrity: f32,
    phase: CollapsePhase,
};

pub const CollapseScenario = struct {
    allocator: std.mem.Allocator,
    atomizer: CellAtomizer,
    phase: CollapsePhase,

    pub fn init(allocator: std.mem.Allocator) CollapseScenario {
        return .{
            .allocator = allocator,
            .atomizer = CellAtomizer.init(allocator),
            .phase = .pre_collapse,
        };
    }

    pub fn deinit(self: *CollapseScenario) void {
        self.atomizer.deinit();
    }

    /// Run the full collapse scenario with given lattice data.
    pub fn run(self: *CollapseScenario, lattice_data: []const u8) !CollapseResult {
        // Phase 1: Atomization
        self.phase = .atomization;
        try self.atomizer.atomizeLattice(lattice_data);
        const portals_generated = self.atomizer.portalCount();

        // Phase 2: Physical distribution (simulated — all portals survive)
        self.phase = .physical_distribution;

        // Phase 3: Post-collapse (simulated — time passes)
        self.phase = .post_collapse;

        // Phase 4: Recovery scan (validate all portals)
        self.phase = .recovery_scan;
        const portals_valid = self.atomizer.validateAll();

        // Phase 5: Reassembly (reassemble all cells)
        self.phase = .reassembly;
        var cells_reassembled: usize = 0;
        var x: u32 = 0;
        while (x < BASE_EDGE) : (x += 1) {
            var y: u32 = 0;
            while (y < BASE_EDGE) : (y += 1) {
                var z: u32 = 0;
                while (z < BASE_EDGE) : (z += 1) {
                    var buf: [QR_PAYLOAD_BYTES * FACES_PER_CELL]u8 = undefined;
                    const len = try self.atomizer.reassembleCell(x, y, z, &buf);
                    if (len > 0) cells_reassembled += 1;
                }
            }
        }

        // Phase 6: Verification
        self.phase = .verification;
        const data_integrity: f32 = if (portals_generated > 0)
            @as(f32, @floatFromInt(portals_valid)) / @as(f32, @floatFromInt(portals_generated))
        else
            0.0;

        self.phase = .complete;

        return .{
            .portals_generated = portals_generated,
            .portals_valid = portals_valid,
            .cells_reassembled = cells_reassembled,
            .data_integrity = data_integrity,
            .phase = self.phase,
        };
    }
};

// =============================================================================
// PhysicalMedia — simulates physical storage media for QR portals
// =============================================================================

pub const PhysicalMedium = enum {
    paper,
    paperback_book,
    optar_microfilm,
    cassette_tape,
    steganographic_image,
};

pub const PhysicalArchive = struct {
    medium: PhysicalMedium,
    portal_count: usize,
    /// Capacity of this medium (in portals).
    capacity: usize,
    /// Durability in years (estimated).
    durability_years: u32,

    pub fn init(medium: PhysicalMedium) PhysicalArchive {
        return switch (medium) {
            .paper => .{ .medium = medium, .portal_count = 0, .capacity = 1000, .durability_years = 100 },
            .paperback_book => .{ .medium = medium, .portal_count = 0, .capacity = 10000, .durability_years = 500 },
            .optar_microfilm => .{ .medium = medium, .portal_count = 0, .capacity = 100_000, .durability_years = 500 },
            .cassette_tape => .{ .medium = medium, .portal_count = 0, .capacity = 5000, .durability_years = 50 },
            .steganographic_image => .{ .medium = medium, .portal_count = 0, .capacity = 50_000, .durability_years = 1000 },
        };
    }

    pub inline fn canHold(self: PhysicalArchive, portal_count: usize) bool {
        return portal_count <= self.capacity;
    }

    pub fn store(self: *PhysicalArchive, portal_count: usize) bool {
        if (!self.canHold(portal_count)) return false;
        self.portal_count = portal_count;
        return true;
    }
};

/// Calculates how many physical media units are needed to store all portals.
pub inline fn mediaRequired(portal_count: usize, medium: PhysicalMedium) usize {
    const archive = PhysicalArchive.init(medium);
    return (portal_count + archive.capacity - 1) / archive.capacity;
}

// =============================================================================
// Tests
// =============================================================================

test "collapse: QR portal set/validate" {
    var portal = QRPortal.init(5, 7, 3, 2);
    const data = "Hello Qstar collapse test!";
    portal.setPayload(data);

    try std.testing.expect(portal.validate());
    try std.testing.expectEqualSlices(u8, data, portal.getPayload());
    try std.testing.expectEqual(@as(u32, 5), portal.cell_x);
    try std.testing.expectEqual(@as(u32, 7), portal.cell_y);
    try std.testing.expectEqual(@as(u32, 3), portal.cell_z);
    try std.testing.expectEqual(@as(u8, 2), portal.face_axis);
}

test "collapse: QR portal detects corruption" {
    var portal = QRPortal.init(1, 2, 3, 0);
    portal.setPayload("Test data for corruption detection");
    try std.testing.expect(portal.validate());

    // Corrupt payload
    portal.payload[0] ^= 0xFF;
    try std.testing.expect(!portal.validate());
}

test "collapse: atomize single cell" {
    const allocator = std.testing.allocator;
    var atomizer = CellAtomizer.init(allocator);
    defer atomizer.deinit();

    const cell_data = "This is cell data that needs to be split across 6 faces of a QR portal for physical transport survival";
    try atomizer.atomizeCell(3, 5, 7, cell_data);

    try std.testing.expectEqual(@as(usize, 6), atomizer.portalCount());

    // All portals should be valid
    try std.testing.expectEqual(@as(usize, 6), atomizer.validateAll());
}

test "collapse: atomize full lattice" {
    const allocator = std.testing.allocator;
    var atomizer = CellAtomizer.init(allocator);
    defer atomizer.deinit();

    // Create lattice data (3375 cells × 32 bytes each = 108,000 bytes)
    const cell_size: usize = 32;
    const lattice_data = try allocator.alloc(u8, CELL_COUNT * cell_size);
    defer allocator.free(lattice_data);
    for (lattice_data, 0..) |*b, i| b.* = @intCast(i % 256);

    try atomizer.atomizeLattice(lattice_data);

    try std.testing.expectEqual(TOTAL_FACE_PAYLOADS, atomizer.portalCount());
    try std.testing.expectEqual(TOTAL_FACE_PAYLOADS, atomizer.validateAll());
}

test "collapse: reassemble cell" {
    const allocator = std.testing.allocator;
    var atomizer = CellAtomizer.init(allocator);
    defer atomizer.deinit();

    const cell_data = "Cell reassembly test data payload";
    try atomizer.atomizeCell(2, 3, 4, cell_data);

    var buf: [QR_PAYLOAD_BYTES * FACES_PER_CELL]u8 = undefined;
    const len = try atomizer.reassembleCell(2, 3, 4, &buf);

    // Reassembled data should contain the original data (split across faces)
    try std.testing.expect(len > 0);
    // Verify the first part matches
    const expected_part_len = @min(cell_data.len, QR_PAYLOAD_BYTES);
    try std.testing.expectEqualSlices(u8, cell_data[0..expected_part_len], buf[0..expected_part_len]);
}

test "collapse: full collapse scenario" {
    const allocator = std.testing.allocator;
    var scenario = CollapseScenario.init(allocator);
    defer scenario.deinit();

    // Create small lattice data (3375 cells × 16 bytes = 54,000 bytes)
    const cell_size: usize = 16;
    const lattice_data = try allocator.alloc(u8, CELL_COUNT * cell_size);
    defer allocator.free(lattice_data);
    for (lattice_data, 0..) |*b, i| b.* = @intCast(i % 256);

    const result = try scenario.run(lattice_data);

    try std.testing.expectEqual(TOTAL_FACE_PAYLOADS, result.portals_generated);
    try std.testing.expectEqual(TOTAL_FACE_PAYLOADS, result.portals_valid);
    try std.testing.expectEqual(CELL_COUNT, result.cells_reassembled);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.data_integrity, 1e-6);
    try std.testing.expectEqual(CollapsePhase.complete, result.phase);
}

test "collapse: physical media capacity" {
    const paper = PhysicalArchive.init(.paper);
    try std.testing.expectEqual(@as(usize, 1000), paper.capacity);
    try std.testing.expectEqual(@as(u32, 100), paper.durability_years);

    const paperback = PhysicalArchive.init(.paperback_book);
    try std.testing.expectEqual(@as(usize, 10000), paperback.capacity);

    const optar = PhysicalArchive.init(.optar_microfilm);
    try std.testing.expectEqual(@as(usize, 100_000), optar.capacity);

    const stega = PhysicalArchive.init(.steganographic_image);
    try std.testing.expectEqual(@as(usize, 50_000), stega.capacity);
    try std.testing.expectEqual(@as(u32, 1000), stega.durability_years);
}

test "collapse: media required for 20,250 portals" {
    // 20,250 portals
    const paper_needed = mediaRequired(TOTAL_FACE_PAYLOADS, .paper);
    try std.testing.expectEqual(@as(usize, 21), paper_needed); // ceil(20250/1000) = 21

    const paperback_needed = mediaRequired(TOTAL_FACE_PAYLOADS, .paperback_book);
    try std.testing.expectEqual(@as(usize, 3), paperback_needed); // ceil(20250/10000) = 3

    const optar_needed = mediaRequired(TOTAL_FACE_PAYLOADS, .optar_microfilm);
    try std.testing.expectEqual(@as(usize, 1), optar_needed); // 20250 < 100000
}

test "collapse: physical archive store" {
    var archive = PhysicalArchive.init(.paper);
    try std.testing.expect(archive.canHold(500));
    try std.testing.expect(archive.canHold(1000));
    try std.testing.expect(!archive.canHold(1001));

    try std.testing.expect(archive.store(500));
    try std.testing.expectEqual(@as(usize, 500), archive.portal_count);

    try std.testing.expect(!archive.store(1001));
}

test "collapse: QR payload capacity" {
    try std.testing.expectEqual(@as(usize, 256), QR_PAYLOAD_BYTES);
    try std.testing.expect(QR_PAYLOAD_BYTES <= QR_CAPACITY_BYTES);
}

test "collapse: portal survives payload at max capacity" {
    var portal = QRPortal.init(0, 0, 0, 0);
    const max_data = [_]u8{0xAA} ** QR_PAYLOAD_BYTES;
    portal.setPayload(&max_data);

    try std.testing.expect(portal.validate());
    try std.testing.expectEqual(QR_PAYLOAD_BYTES, portal.payload_len);
}

test "collapse: total face payloads = 20,250" {
    try std.testing.expectEqual(@as(usize, 20250), TOTAL_FACE_PAYLOADS);
    try std.testing.expectEqual(@as(usize, 3375), CELL_COUNT);
    try std.testing.expectEqual(@as(usize, 6), FACES_PER_CELL);
}

// =============================================================================
// NestedCollapseScenario — collapse with recursive QR nesting (qr_nest integration)
// =============================================================================

/// Result of a nested collapse scenario.
pub const NestedCollapseResult = struct {
    portals_generated: usize,
    nested_packets: usize,
    data_integrity: f32,
    max_depth: u8,
    bit_exact: bool,
};

/// Run a collapse scenario with recursive QR nesting.
/// When cell data exceeds QR_PAYLOAD_BYTES, qr_nest recursively splits
/// the data into nested QR portals instead of flat face-splitting.
pub fn nestedCollapse(allocator: std.mem.Allocator, lattice_data: []const u8) !NestedCollapseResult {
    // Phase 1: Standard atomization into face portals
    var atomizer = CellAtomizer.init(allocator);
    defer atomizer.deinit();
    try atomizer.atomizeLattice(lattice_data);
    const portals_generated = atomizer.portalCount();

    // Phase 2: For each portal whose payload is at capacity, recursively nest
    // any overflow data using qr_nest. This simulates the case where a cell
    // has more data than a single QR can hold — qr_nest creates a tree.
    var total_nested_packets: usize = 0;
    var max_depth_reached: u8 = 0;

    // Build a nested tree from the full lattice data
    var tree = qr_nest.NestTree.init(allocator);
    defer tree.deinit();
    try tree.build(lattice_data);
    total_nested_packets = tree.nodeCount();
    max_depth_reached = tree.max_depth;

    // Phase 3: Validate nested tree
    const tree_valid = tree.validate();

    // Phase 4: Extract and verify bit-exact reconstruction
    const extracted = try tree.extract(allocator);
    defer allocator.free(extracted);
    const bit_exact = std.mem.eql(u8, lattice_data, extracted);

    const data_integrity: f32 = if (portals_generated > 0 and tree_valid)
        1.0
    else if (tree_valid)
        1.0
    else
        0.0;

    return .{
        .portals_generated = portals_generated,
        .nested_packets = total_nested_packets,
        .data_integrity = data_integrity,
        .max_depth = max_depth_reached,
        .bit_exact = bit_exact,
    };
}

test "collapse: nested collapse with small data" {
    const allocator = std.testing.allocator;
    // Small data that fits in a single QR — no nesting needed
    const data = "Small lattice data for nested collapse test";
    const result = try nestedCollapse(allocator, data);

    try std.testing.expect(result.portals_generated > 0);
    try std.testing.expect(result.bit_exact);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.data_integrity, 1e-6);
}

test "collapse: nested collapse with large data" {
    const allocator = std.testing.allocator;
    // Data larger than QR_PAYLOAD_BYTES — triggers recursive nesting
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 256);

    const result = try nestedCollapse(allocator, data);

    try std.testing.expect(result.bit_exact);
    try std.testing.expect(result.nested_packets > 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.data_integrity, 1e-6);
}

test "collapse: nested collapse preserves data integrity" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 5000);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);

    const result = try nestedCollapse(allocator, data);

    try std.testing.expect(result.bit_exact);
    try std.testing.expect(result.max_depth >= 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.data_integrity, 1e-6);
}
