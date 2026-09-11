const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mathematical-proofs",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run all mathematical proofs");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run all Zig proof tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
