//! detect.zig - automated hardware detection and auto-scaling for FANO-1.
//!
//! Detects CPU vector features (AVX-512/AVX2/AVX/none), Vulkan devices
//! (discrete/integrated/CPU fallback) with VRAM sizes, and selects the
//! best execution backend for a given grid size. Auto-scales the grid to
//! the detected memory budget using the Fano/binary step sequences.

const std = @import("std");

pub const CpuFeature = enum { avx512, avx2, avx, none };

pub const GpuDevice = struct {
    name: [128]u8,
    name_len: usize,
    is_discrete: bool,
    vram_bytes: u64,
};

pub const CpuInfo = struct {
    model: [64]u8,
    model_len: usize,
    feature: CpuFeature,
    cores: u32,
};

pub const GpuInfo = struct {
    devices: [4]GpuDevice,
    device_count: usize,
    vulkan_available: bool,
};

/// Read the CPU model name from /proc/cpuinfo.
fn readCpuModel(buf: *[64]u8) usize {
    const f = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return 0;
    defer f.close();
    var data: [8192]u8 = undefined;
    const n = f.readAll(&data) catch return 0;
    const idx = std.mem.indexOf(u8, data[0..n], "model name") orelse return 0;
    const colon = std.mem.indexOfScalarPos(u8, data[0..n], idx, ':') orelse return 0;
    var start = colon + 1;
    while (start < n and data[start] == ' ') start += 1;
    var eol = std.mem.indexOfScalarPos(u8, data[0..n], start, '\n') orelse n;
    while (eol > start and (data[eol - 1] == ' ' or data[eol - 1] == '\t')) eol -= 1;
    const len = @min(eol - start, buf.len);
    @memcpy(buf[0..len], data[start .. start + len]);
    return len;
}

fn cpuid(leaf: u32, subleaf: u32, eax: *u32, ebx: *u32, ecx: *u32, edx: *u32) void {
    var out_eax: u32 = undefined;
    var out_ebx: u32 = undefined;
    var out_ecx: u32 = undefined;
    var out_edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (out_eax),
          [ebx] "={ebx}" (out_ebx),
          [ecx] "={ecx}" (out_ecx),
          [edx] "={edx}" (out_edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    eax.* = out_eax;
    ebx.* = out_ebx;
    ecx.* = out_ecx;
    edx.* = out_edx;
}

fn xgetbv() u64 {
    return asm volatile ("xgetbv"
        : [ret] "={rax}" (-> u64),
        : [ecx] "{ecx}" (@as(u32, 0)),
    );
}

/// Detect CPU vector features via cpuid (x86_64 only).
pub fn detectCpu() CpuInfo {
    var info: CpuInfo = .{ .model = undefined, .model_len = 0, .feature = .none, .cores = 1 };
    info.model_len = readCpuModel(&info.model);
    info.cores = @intCast(std.Thread.getCpuCount() catch 1);

    if (comptime @import("builtin").cpu.arch != .x86_64) return info;

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    cpuid(1, 0, &eax, &ebx, &ecx, &edx);
    const has_osxsave = (ecx >> 27) & 1 != 0;
    const has_avx = (ecx >> 28) & 1 != 0;

    var eax7: u32 = undefined;
    var ebx7: u32 = undefined;
    var ecx7: u32 = undefined;
    var edx7: u32 = undefined;
    cpuid(7, 0, &eax7, &ebx7, &ecx7, &edx7);
    const has_avx2 = (ebx7 >> 5) & 1 != 0;
    const has_avx512 = (ebx7 >> 16) & 1 != 0;

    if (has_osxsave and has_avx) {
        const xcr0 = xgetbv();
        const os_avx = (xcr0 & 0x6) == 0x6; // XMM + YMM state enabled
        if (os_avx) {
            if (has_avx512 and (xcr0 & 0xE0) == 0xE0) {
                info.feature = .avx512;
            } else if (has_avx2) {
                info.feature = .avx2;
            } else {
                info.feature = .avx;
            }
        }
    }
    return info;
}

/// Read VRAM bytes for a DRM card from sysfs.
fn readVramBytes(card_path: []const u8) u64 {
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/device/mem_info_vram_total", .{card_path}) catch return 0;
    const f = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer f.close();
    var buf: [32]u8 = undefined;
    const n = f.readAll(&buf) catch return 0;
    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \n"), 10) catch 0;
}

/// Read a sysfs attribute into a fixed buffer, returning its length.
fn readSysfs(path: []const u8, buf: *[128]u8) usize {
    const f = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer f.close();
    const n = f.readAll(buf) catch return 0;
    var end = n;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == ' ')) end -= 1;
    return end;
}

/// Detect Vulkan GPUs by enumerating DRM cards from sysfs and reading
/// vendor/device IDs plus VRAM sizes. vulkan_available reflects whether
/// the vulkaninfo utility (hence a Vulkan ICD) is present.
pub fn detectGpus(alloc: std.mem.Allocator) GpuInfo {
    var info: GpuInfo = .{ .devices = undefined, .device_count = 0, .vulkan_available = false };
    for (&info.devices) |*d| d.* = .{
        .name = undefined,
        .name_len = 0,
        .is_discrete = false,
        .vram_bytes = 0,
    };

    // Check vulkaninfo availability (indicates a Vulkan ICD is installed).
    const which = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "sh", "-c", "command -v vulkaninfo" },
        .max_output_bytes = 4096,
    }) catch return info;
    defer alloc.free(which.stdout);
    defer alloc.free(which.stderr);
    info.vulkan_available = std.mem.indexOf(u8, which.stdout, "vulkaninfo") != null;

    // Enumerate DRM cards from sysfs.
    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return info;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (info.device_count >= info.devices.len) break;
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        const suffix = entry.name[4..];
        if (suffix.len == 0 or !std.ascii.isDigit(suffix[0])) continue; // skip card0-*

        var path_buf: [160]u8 = undefined;
        const card_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}", .{entry.name}) catch continue;

        // vendor: 0x8086 = Intel (integrated), 0x1002 = AMD (discrete)
        var vendor_path_buf: [176]u8 = undefined;
        const vendor_path = std.fmt.bufPrint(&vendor_path_buf, "{s}/device/vendor", .{card_path}) catch continue;
        var vbuf: [128]u8 = undefined;
        const vlen = readSysfs(vendor_path, &vbuf);
        if (vlen == 0) continue;
        const is_amd = std.mem.indexOf(u8, vbuf[0..vlen], "1002") != null;
        const is_intel = std.mem.indexOf(u8, vbuf[0..vlen], "8086") != null;
        if (!is_amd and !is_intel) continue;

        const d = &info.devices[info.device_count];
        // device name from the kernel driver link or the device id
        var name_path_buf: [176]u8 = undefined;
        const name_path = std.fmt.bufPrint(&name_path_buf, "{s}/device/product_name", .{card_path}) catch continue;
        var nlen = readSysfs(name_path, &d.name);
        if (nlen == 0) {
            const label = if (is_amd) "AMD GPU" else "Intel GPU";
            nlen = @min(label.len, d.name.len);
            @memcpy(d.name[0..nlen], label);
        }
        d.name_len = nlen;
        d.is_discrete = is_amd;
        d.vram_bytes = readVramBytes(card_path);
        info.device_count += 1;
    }
    return info;
}

// ---------------------------------------------------------------------
// Backend selection & auto-scaling
// ---------------------------------------------------------------------

pub const SystemProfile = struct {
    cpu: CpuInfo,
    gpus: GpuInfo,
    ram_bytes: u64,
};

/// Detect total system RAM from /proc/meminfo.
fn detectRam() u64 {
    const f = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 0;
    defer f.close();
    var data: [4096]u8 = undefined;
    const n = f.readAll(&data) catch return 0;
    const idx = std.mem.indexOf(u8, data[0..n], "MemTotal:") orelse return 0;
    _ = std.mem.indexOfScalarPos(u8, data[0..n], idx, '\n') orelse n;
    // parse the number (kB)
    var i = idx + "MemTotal:".len;
    while (i < n and (data[i] == ' ')) i += 1;
    var j = i;
    while (j < n and std.ascii.isDigit(data[j])) j += 1;
    const kb = std.fmt.parseInt(u64, data[i..j], 10) catch 0;
    return kb * 1024;
}

/// Full hardware detection pass.
pub fn detectAll(alloc: std.mem.Allocator) SystemInfo {
    const cpu = detectCpu();
    const gpus = detectGpus(alloc);
    return .{
        .cpu = cpu,
        .gpus = gpus,
        .ram_bytes = detectRam(),
    };
}

pub const SystemInfo = struct {
    cpu: CpuInfo,
    gpus: GpuInfo,
    ram_bytes: u64,

    /// Select the best backend for a grid of `nodes` complex Q128.128
    /// nodes (32 bytes each). Priority: Vulkan GPU (fits VRAM) -> native
    /// Zig (AVX2+) -> wasm3 -> custom interpreter.
    pub fn selectBackend(self: *const SystemInfo, nodes: u64) Backend {
        const needed = nodes * 32;
        // discrete GPU with enough free VRAM (leave 3 GB for the OS/overhead)
        for (self.gpus.devices[0..self.gpus.device_count]) |d| {
            if (d.is_discrete and d.vram_bytes > needed + 3 * 1024 * 1024 * 1024) {
                return .vulkan_gpu;
            }
        }
        if (self.cpu.feature == .avx2 or self.cpu.feature == .avx512) {
            return .native_zig;
        }
        return .wasm3;
    }

    /// Auto-scale: the largest power-of-two grid (16..512) whose state
    /// matrix fits the budget (VRAM for GPU, RAM otherwise), leaving a
    /// 25% safety margin.
    pub fn autoScaleGrid(self: *const SystemInfo, backend: Backend) u64 {
        const budget = budget_for(backend, self) * 3 / 4;
        var grid: u64 = 16;
        while (grid < 512) {
            const next = grid * 2;
            const nodes = next * next * next;
            if (nodes * 32 > budget) break;
            grid = next;
        }
        return grid;
    }

    fn budget_for(backend: Backend, self: *const SystemInfo) u64 {
        return switch (backend) {
            .vulkan_gpu => blk: {
                for (self.gpus.devices[0..self.gpus.device_count]) |d| {
                    if (d.is_discrete) break :blk d.vram_bytes;
                }
                break :blk self.ram_bytes;
            },
            else => self.ram_bytes,
        };
    }
};

pub const Backend = enum {
    vulkan_gpu,
    native_zig,
    wasm3,
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "cpu detection returns a feature" {
    const info = detectCpu();
    try testing.expect(info.model_len > 0);
    try testing.expect(info.cores >= 1);
}

test "gpu detection enumerates devices" {
    const alloc = testing.allocator;
    const info = detectGpus(alloc);
    // On the dev machine: RX 580 (discrete) + Intel HD 4000
    try testing.expect(info.device_count >= 1);
}

test "backend selection prefers GPU for large grids" {
    var sys: SystemInfo = .{
        .cpu = .{ .model = undefined, .model_len = 0, .feature = .avx2, .cores = 4 },
        .gpus = .{ .devices = undefined, .device_count = 1, .vulkan_available = true },
        .ram_bytes = 16 * 1024 * 1024 * 1024,
    };
    sys.gpus.devices[0] = .{
        .name = undefined,
        .name_len = 0,
        .is_discrete = true,
        .vram_bytes = 8 * 1024 * 1024 * 1024,
    };
    // 512^3 = 134M nodes * 32B = 4.295 GB; fits 8GB - 3GB = 5GB budget
    try testing.expectEqual(Backend.vulkan_gpu, sys.selectBackend(134217728));
    // 1024^3 = 1.07B nodes * 32B = 34.36 GB; does not fit
    try testing.expectEqual(Backend.native_zig, sys.selectBackend(1073741824));
}

test "backend selection falls back to wasm3 without AVX2" {
    var sys: SystemInfo = .{
        .cpu = .{ .model = undefined, .model_len = 0, .feature = .avx, .cores = 4 },
        .gpus = .{ .devices = undefined, .device_count = 0, .vulkan_available = false },
        .ram_bytes = 16 * 1024 * 1024 * 1024,
    };
    try testing.expectEqual(Backend.wasm3, sys.selectBackend(4096));
}

test "auto-scale caps at 512 for an 8GB GPU" {
    var sys: SystemInfo = .{
        .cpu = .{ .model = undefined, .model_len = 0, .feature = .avx2, .cores = 4 },
        .gpus = .{ .devices = undefined, .device_count = 1, .vulkan_available = true },
        .ram_bytes = 16 * 1024 * 1024 * 1024,
    };
    sys.gpus.devices[0] = .{
        .name = undefined,
        .name_len = 0,
        .is_discrete = true,
        .vram_bytes = 8 * 1024 * 1024 * 1024,
    };
    const grid = sys.autoScaleGrid(.vulkan_gpu);
    try testing.expectEqual(@as(u64, 512), grid);
}
