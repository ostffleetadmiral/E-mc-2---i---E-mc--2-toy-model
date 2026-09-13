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

    // Render tests
    const render_tests = b.addTest(.{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_tests.root_module.addImport("fixed_point", fp_mod);
    test_step.dependOn(&b.addRunArtifact(render_tests).step);

    // === Example Executable ===

    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_mod.addImport("fixed_point", fp_mod);

    const exe = b.addExecutable(.{
        .name = "qstar-render",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("render", render_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
