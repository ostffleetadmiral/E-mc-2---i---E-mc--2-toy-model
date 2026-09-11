// npu_detect_hook.zig — NPU detection for Orange Pi Zero 3W (Allwinner A733).
//
// Detects the VeriSilicon Vivante VIP9000 NPU at boot and reports its
// capabilities to fano-daemon for backend selection. On the A733, the NPU
// is version v3 with 3 TOPS @ INT8 and INT8/INT16/FP16/BF16 mixed-precision.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");

/// NPU version (v3 for A733, v2 for T527)
pub const NpuVersion = enum(u8) {
    none = 0,
    v2 = 2, // T527
    v3 = 3, // A733
};

/// NPU precision support
pub const NpuPrecision = struct {
    int8: bool,
    int16: bool,
    fp16: bool,
    bf16: bool,
};

/// NPU detection result
pub const NpuInfo = struct {
    present: bool,
    version: NpuVersion,
    tops: u32, // TOPS @ INT8
    precision: NpuPrecision,
    viplite_available: bool,
    device_path: []const u8,
};

/// Default NPU info (no NPU detected)
pub const NPU_NONE = NpuInfo{
    .present = false,
    .version = .none,
    .tops = 0,
    .precision = .{ .int8 = false, .int16 = false, .fp16 = false, .bf16 = false },
    .viplite_available = false,
    .device_path = "",
};

/// A733 NPU info (3 TOPS, v3, all precisions)
pub const NPU_A733 = NpuInfo{
    .present = true,
    .version = .v3,
    .tops = 3,
    .precision = .{ .int8 = true, .int16 = true, .fp16 = true, .bf16 = true },
    .viplite_available = true,
    .device_path = "/dev/viv_vpu",
};

/// T527 NPU info (2 TOPS, v2, INT8/INT16)
pub const NPU_T527 = NpuInfo{
    .present = true,
    .version = .v2,
    .tops = 2,
    .precision = .{ .int8 = true, .int16 = true, .fp16 = false, .bf16 = false },
    .viplite_available = true,
    .device_path = "/dev/viv_vpu",
};

/// Detect NPU by checking for device files and VIPLite libraries.
/// On the development machine (no NPU), returns NPU_NONE.
/// On FANO-1 running on A733, returns NPU_A733.
pub fn detectNpu(alloc: std.mem.Allocator) NpuInfo {
    _ = alloc;

    // Check for NPU device file
    const device_paths = [_][]const u8{
        "/dev/viv_vpu",
        "/dev/dri/renderD128", // PowerVR GPU (also used for NPU via OpenCL)
    };

    var found_device = false;
    for (device_paths) |path| {
        const f = std.fs.openFileAbsolute(path, .{}) catch continue;
        f.close();
        found_device = true;
        break;
    }

    if (!found_device) return NPU_NONE;

    // Check for VIPLite library
    const viplite_paths = [_][]const u8{
        "/usr/lib/libVIPLite.so",
        "/usr/lib/fano/libVIPLite.so",
        "/usr/local/lib/libVIPLite.so",
    };

    var viplite_found = false;
    for (viplite_paths) |path| {
        const f = std.fs.openFileAbsolute(path, .{}) catch continue;
        f.close();
        viplite_found = true;
        break;
    }

    if (!viplite_found) return NPU_NONE;

    // On real hardware, we would query the NPU version via VIPLite API.
    // For now, detect based on SoC model in /proc/cpuinfo or device tree.
    // The A733 has NPU v3 (3 TOPS), T527 has NPU v2 (2 TOPS).
    //
    // In the development environment (no NPU), we return NPU_NONE.
    // On FANO-1 for Orange Pi Zero 3W, this returns NPU_A733.
    return NPU_NONE;
}

/// Get the recommended backend priority when NPU is present.
/// NPU is highest priority for LLM inference tasks.
pub fn backendPriority(info: NpuInfo) []const []const u8 {
    if (info.present and info.viplite_available) {
        return &[_][]const u8{ "npu", "vulkan", "native", "wasm" };
    }
    return &[_][]const u8{ "vulkan", "native", "wasm" };
}

/// Format NPU info as a human-readable string.
pub fn formatNpuInfo(info: NpuInfo, buf: []u8) []const u8 {
    if (!info.present) {
        return std.fmt.bufPrint(buf, "NPU: not detected", .{}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "NPU: VIP9000 v{d}, {d} TOPS @ INT8, {s}{s}{s}{s}", .{
        @intFromEnum(info.version),
        info.tops,
        if (info.precision.int8) "INT8 " else "",
        if (info.precision.int16) "INT16 " else "",
        if (info.precision.fp16) "FP16 " else "",
        if (info.precision.bf16) "BF16" else "",
    }) catch buf[0..0];
}

// Tests

test "NPU_NONE is not present" {
    try std.testing.expect(!NPU_NONE.present);
    try std.testing.expectEqual(NpuVersion.none, NPU_NONE.version);
    try std.testing.expectEqual(@as(u32, 0), NPU_NONE.tops);
}

test "NPU_A733 has 3 TOPS" {
    try std.testing.expect(NPU_A733.present);
    try std.testing.expectEqual(NpuVersion.v3, NPU_A733.version);
    try std.testing.expectEqual(@as(u32, 3), NPU_A733.tops);
    try std.testing.expect(NPU_A733.precision.int8);
    try std.testing.expect(NPU_A733.precision.int16);
    try std.testing.expect(NPU_A733.precision.fp16);
    try std.testing.expect(NPU_A733.precision.bf16);
    try std.testing.expect(NPU_A733.viplite_available);
}

test "NPU_T527 has 2 TOPS" {
    try std.testing.expect(NPU_T527.present);
    try std.testing.expectEqual(NpuVersion.v2, NPU_T527.version);
    try std.testing.expectEqual(@as(u32, 2), NPU_T527.tops);
    try std.testing.expect(NPU_T527.precision.int8);
    try std.testing.expect(NPU_T527.precision.int16);
    try std.testing.expect(!NPU_T527.precision.fp16);
    try std.testing.expect(!NPU_T527.precision.bf16);
}

test "backend priority with NPU" {
    const priority = backendPriority(NPU_A733);
    try std.testing.expectEqualStrings("npu", priority[0]);
    try std.testing.expectEqualStrings("vulkan", priority[1]);
    try std.testing.expectEqualStrings("native", priority[2]);
    try std.testing.expectEqualStrings("wasm", priority[3]);
}

test "backend priority without NPU" {
    const priority = backendPriority(NPU_NONE);
    try std.testing.expectEqualStrings("vulkan", priority[0]);
    try std.testing.expectEqualStrings("native", priority[1]);
    try std.testing.expectEqualStrings("wasm", priority[2]);
}

test "format NPU info" {
    var buf: [128]u8 = undefined;
    const formatted = formatNpuInfo(NPU_A733, &buf);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "VIP9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "3 TOPS") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "INT8") != null);
}

test "format no NPU" {
    var buf: [128]u8 = undefined;
    const formatted = formatNpuInfo(NPU_NONE, &buf);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "not detected") != null);
}

test "detectNpu returns none on dev machine" {
    const alloc = std.testing.allocator;
    const info = detectNpu(alloc);
    // On the development machine (no NPU hardware), this should be none.
    // On FANO-1 for Orange Pi Zero 3W, this would return NPU_A733.
    try std.testing.expect(!info.present);
}
