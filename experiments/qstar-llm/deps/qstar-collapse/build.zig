const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all unit tests");

    const collapse_tests = b.addTest(.{
        .root_source_file = b.path("src/collapse.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(collapse_tests).step);

    const qr_nest_tests = b.addTest(.{
        .root_source_file = b.path("src/qr_nest.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(qr_nest_tests).step);

    // === Example Executable ===

    const collapse_mod = b.addModule("collapse", .{
        .root_source_file = b.path("src/collapse.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "qstar-collapse",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("collapse", collapse_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
