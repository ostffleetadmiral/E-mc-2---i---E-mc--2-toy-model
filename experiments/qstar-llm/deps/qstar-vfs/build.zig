const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all unit tests");

    const fp_mod = b.addModule("fixed_point", .{
        .root_source_file = b.path("src/fixed_point.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Fixed-point tests
    const fp_tests = b.addTest(.{
        .root_source_file = b.path("src/fixed_point.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(fp_tests).step);

    // VFS Bridge tests
    const vfs_bridge_tests = b.addTest(.{
        .root_source_file = b.path("src/vfs_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_bridge_tests.root_module.addImport("fixed_point", fp_mod);
    test_step.dependOn(&b.addRunArtifact(vfs_bridge_tests).step);

    // VFS Streaming tests
    const vfs_streaming_tests = b.addTest(.{
        .root_source_file = b.path("src/vfs_streaming.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vfs_bridge_mod = b.addModule("vfs_bridge", .{
        .root_source_file = b.path("src/vfs_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_bridge_mod.addImport("fixed_point", fp_mod);
    vfs_streaming_tests.root_module.addImport("vfs_bridge", vfs_bridge_mod);
    vfs_streaming_tests.root_module.addImport("fixed_point", fp_mod);
    test_step.dependOn(&b.addRunArtifact(vfs_streaming_tests).step);

    // VFS Distributed tests
    const vfs_dist_tests = b.addTest(.{
        .root_source_file = b.path("src/vfs_distributed.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(vfs_dist_tests).step);

    // === Example Executable ===

    const vfs_bridge_mod_exe = b.addModule("vfs_bridge", .{
        .root_source_file = b.path("src/vfs_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_bridge_mod_exe.addImport("fixed_point", fp_mod);

    const exe = b.addExecutable(.{
        .name = "qstar-vfs",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vfs_bridge", vfs_bridge_mod_exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
