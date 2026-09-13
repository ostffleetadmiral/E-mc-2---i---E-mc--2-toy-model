const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all unit tests");

    const modules = [_][]const u8{
        "src/nat.zig",
        "src/webrtc.zig",
        "src/bootstrap.zig",
        "src/sybil.zig",
        "src/merge.zig",
    };

    for (modules) |path| {
        const t = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // === Module Definitions ===

    const nat_mod = b.addModule("nat", .{
        .root_source_file = b.path("src/nat.zig"),
        .target = target,
        .optimize = optimize,
    });
    const webrtc_mod = b.addModule("webrtc", .{
        .root_source_file = b.path("src/webrtc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bootstrap_mod = b.addModule("bootstrap", .{
        .root_source_file = b.path("src/bootstrap.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sybil_mod = b.addModule("sybil", .{
        .root_source_file = b.path("src/sybil.zig"),
        .target = target,
        .optimize = optimize,
    });
    const merge_mod = b.addModule("merge", .{
        .root_source_file = b.path("src/merge.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === Example Executable ===

    const exe = b.addExecutable(.{
        .name = "qstar-net",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("nat", nat_mod);
    exe.root_module.addImport("webrtc", webrtc_mod);
    exe.root_module.addImport("bootstrap", bootstrap_mod);
    exe.root_module.addImport("sybil", sybil_mod);
    exe.root_module.addImport("merge", merge_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
