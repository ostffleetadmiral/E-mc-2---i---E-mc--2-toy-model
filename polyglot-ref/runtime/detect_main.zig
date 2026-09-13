//! detect_main.zig - fano-detect CLI: prints the hardware profile and
//! the auto-selected backend + grid size for the FANO-1 engine.

const std = @import("std");
const detect = @import("detect");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    const sys = detect.detectAll(alloc);

    try stdout.print("=== FANO-1 Hardware Detection ===\n", .{});
    try stdout.print("CPU: {s}\n", .{sys.cpu.model[0..sys.cpu.model_len]});
    try stdout.print("  cores: {d}\n", .{sys.cpu.cores});
    try stdout.print("  vector: {s}\n", .{@tagName(sys.cpu.feature)});
    try stdout.print("  RAM: {d:.1} GB\n", .{@as(f64, @floatFromInt(sys.ram_bytes)) / (1024.0 * 1024.0 * 1024.0)});

    try stdout.print("GPUs: {d} device(s), vulkan={s}\n", .{ sys.gpus.device_count, if (sys.gpus.vulkan_available) "yes" else "no" });
    for (sys.gpus.devices[0..sys.gpus.device_count]) |d| {
        try stdout.print("  {s}: {s}, VRAM {d:.2} GB\n", .{
            d.name[0..d.name_len],
            if (d.is_discrete) "discrete" else "integrated",
            @as(f64, @floatFromInt(d.vram_bytes)) / (1024.0 * 1024.0 * 1024.0),
        });
    }

    // Backend selection for the documented grid sizes
    try stdout.print("\nBackend selection by grid:\n", .{});
    const grids = [_]u64{ 16, 32, 64, 128, 256, 512, 1024 };
    for (grids) |g| {
        const nodes = g * g * g;
        const backend = sys.selectBackend(nodes);
        try stdout.print("  {d}^3 ({d} nodes, {d:.2} GB): {s}\n", .{
            g, nodes, @as(f64, @floatFromInt(nodes * 32)) / (1024.0 * 1024.0 * 1024.0), @tagName(backend),
        });
    }

    // Auto-scale for the best backend
    const best = sys.selectBackend(512 * 512 * 512);
    const grid = sys.autoScaleGrid(best);
    try stdout.print("\nAuto-scaled grid for {s}: {d}^3\n", .{ @tagName(best), grid });
}
