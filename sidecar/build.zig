// License: CC BY-NC-SA 4.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "f64-verification", .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    const step = b.step("run", "Run f64 sidecar verification");
    step.dependOn(&run.step);
    const tests = b.addTest(.{ .root_source_file = b.path("all_tests.zig"), .target = target, .optimize = optimize });
    const test_step = b.step("test", "Run f64 sidecar tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
