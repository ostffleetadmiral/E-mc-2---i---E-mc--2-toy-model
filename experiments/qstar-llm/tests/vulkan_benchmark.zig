const std = @import("std");
const agent_mod = @import("agent");
const fp = @import("fixed_point");
const vk = @import("vulkan_compute");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Qstar Vulkan Compute Benchmark ===\n\n", .{});

    // === CPU Benchmark ===
    {
        var agent = agent_mod.Agent.initDeterministic(allocator, 0, fp.ONE, 42);
        defer agent.deinit();
        agent.disableVulkan();

        // Prime activations
        for (0..421) |i| {
            agent.state.activations[i][i % 7] = fp.fromInt(@intCast(i * 10));
        }

        const N: usize = 1000;
        std.debug.print("CPU: Running {d} inference cycles...\n", .{N});
        const start = std.time.nanoTimestamp();

        for (0..N) |_| {
            agent.step();
        }

        const elapsed = std.time.nanoTimestamp() - start;
        const ms_total = @as(f64, @floatFromInt(elapsed)) / 1e6;
        const ms_per_step = ms_total / @as(f64, @floatFromInt(N));
        const steps_per_sec = @as(f64, @floatFromInt(N)) / (ms_total / 1000.0);

        std.debug.print("CPU: {d:.2} ms total, {d:.4} ms/step, {d:.1} steps/sec\n", .{ ms_total, ms_per_step, steps_per_sec });
        std.debug.print("CPU: {d} output tokens generated\n\n", .{agent.state.output_tokens.items.len});
    }

    // === GPU Benchmark ===
    std.debug.print("Attempting Vulkan GPU acceleration...\n", .{});
    {
        var agent = agent_mod.Agent.initDeterministic(allocator, 0, fp.ONE, 42);
        defer agent.deinit();

        agent.enableVulkan() catch |err| {
            std.debug.print("Vulkan unavailable ({s}) — skipping GPU benchmark.\n", .{@errorName(err)});
            return;
        };

        if (agent.getVulkanDeviceName()) |name| {
            std.debug.print("GPU: {s}\n", .{name});
        }

        // Prime same activations
        for (0..421) |i| {
            agent.state.activations[i][i % 7] = fp.fromInt(@intCast(i * 10));
        }

        const N: usize = 1000;
        std.debug.print("GPU: Running {d} inference cycles...\n", .{N});
        const start = std.time.nanoTimestamp();

        for (0..N) |_| {
            agent.step();
        }

        const elapsed = std.time.nanoTimestamp() - start;
        const ms_total = @as(f64, @floatFromInt(elapsed)) / 1e6;
        const ms_per_step = ms_total / @as(f64, @floatFromInt(N));
        const steps_per_sec = @as(f64, @floatFromInt(N)) / (ms_total / 1000.0);

        std.debug.print("GPU: {d:.2} ms total, {d:.4} ms/step, {d:.1} steps/sec\n", .{ ms_total, ms_per_step, steps_per_sec });
        std.debug.print("GPU: {d} output tokens generated\n\n", .{agent.state.output_tokens.items.len});
    }

    // === SAMC Benchmark ===
    std.debug.print("=== SAMC Relaxation Benchmark ===\n\n", .{});

    // CPU SAMC
    {
        var agent = agent_mod.Agent.initDeterministic(allocator, 0, fp.ONE, 42);
        defer agent.deinit();
        agent.disableVulkan();

        for (0..421) |i| {
            agent.state.activations[i][i % 7] = fp.fromInt(@intCast(i * 10));
        }

        const N: usize = 100;
        std.debug.print("CPU SAMC: {d} sweeps...\n", .{N});
        const start = std.time.nanoTimestamp();
        agent.relaxSAMC(N);
        const elapsed = std.time.nanoTimestamp() - start;
        const ms_total = @as(f64, @floatFromInt(elapsed)) / 1e6;
        std.debug.print("CPU SAMC: {d:.2} ms total, {d:.4} ms/sweep\n\n", .{ ms_total, ms_total / @as(f64, @floatFromInt(N)) });
    }

    // GPU SAMC
    {
        var agent = agent_mod.Agent.initDeterministic(allocator, 0, fp.ONE, 42);
        defer agent.deinit();

        agent.enableVulkan() catch return;

        for (0..421) |i| {
            agent.state.activations[i][i % 7] = fp.fromInt(@intCast(i * 10));
        }

        const N: usize = 100;
        std.debug.print("GPU SAMC: {d} sweeps...\n", .{N});
        const start = std.time.nanoTimestamp();
        agent.relaxSAMC(N);
        const elapsed = std.time.nanoTimestamp() - start;
        const ms_total = @as(f64, @floatFromInt(elapsed)) / 1e6;
        std.debug.print("GPU SAMC: {d:.2} ms total, {d:.4} ms/sweep\n\n", .{ ms_total, ms_total / @as(f64, @floatFromInt(N)) });
    }

    std.debug.print("=== Benchmark Complete ===\n", .{});
}
