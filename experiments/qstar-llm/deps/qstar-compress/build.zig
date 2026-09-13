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

    // TurboQuant tests
    const tq_tests = b.addTest(.{
        .root_source_file = b.path("src/turbo_quant.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(tq_tests).step);

    // Compress tests
    const compress_tests = b.addTest(.{
        .root_source_file = b.path("src/compress.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_tests.root_module.addImport("fixed_point", fp_mod);
    const tq_mod_for_compress = b.addModule("turbo_quant", .{
        .root_source_file = b.path("src/turbo_quant.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_tests.root_module.addImport("turbo_quant", tq_mod_for_compress);
    test_step.dependOn(&b.addRunArtifact(compress_tests).step);

    // === Example Executable ===

    const compress_mod = b.addModule("compress", .{
        .root_source_file = b.path("src/compress.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_mod.addImport("fixed_point", fp_mod);
    const tq_mod_for_exe = b.addModule("turbo_quant", .{
        .root_source_file = b.path("src/turbo_quant.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_mod.addImport("turbo_quant", tq_mod_for_exe);

    const exe = b.addExecutable(.{
        .name = "qstar-compress",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("compress", compress_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
