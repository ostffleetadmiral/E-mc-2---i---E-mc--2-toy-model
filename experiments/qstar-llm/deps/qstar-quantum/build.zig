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

    // Quantum tests
    const quantum_tests = b.addTest(.{
        .root_source_file = b.path("src/quantum.zig"),
        .target = target,
        .optimize = optimize,
    });
    quantum_tests.root_module.addImport("fixed_point", fp_mod);
    test_step.dependOn(&b.addRunArtifact(quantum_tests).step);

    // Entangle tests
    const entangle_tests = b.addTest(.{
        .root_source_file = b.path("src/entangle.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(entangle_tests).step);

    // Holographic tests
    const holo_tests = b.addTest(.{
        .root_source_file = b.path("src/holographic.zig"),
        .target = target,
        .optimize = optimize,
    });
    holo_tests.root_module.addImport("fixed_point", fp_mod);
    test_step.dependOn(&b.addRunArtifact(holo_tests).step);

    // === Example Executable ===

    const quantum_mod = b.addModule("quantum", .{
        .root_source_file = b.path("src/quantum.zig"),
        .target = target,
        .optimize = optimize,
    });
    quantum_mod.addImport("fixed_point", fp_mod);

    const exe = b.addExecutable(.{
        .name = "qstar-quantum",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("quantum", quantum_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
