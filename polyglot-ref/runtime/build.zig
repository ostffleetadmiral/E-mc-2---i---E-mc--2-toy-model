const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const q128_mod = b.createModule(.{
        .root_source_file = b.path("../zig/q128_128.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ri_mod = b.createModule(.{
        .root_source_file = b.path("../zig/ramsey_identity.zig"),
        .target = target,
        .optimize = optimize,
    });
    ri_mod.addImport("q128_128", q128_mod);

    const exe = b.addExecutable(.{
        .name = "interp_test",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("q128_128", q128_mod);
    exe.root_module.addImport("ramsey_identity", ri_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the custom interpreter test harness");
    run_step.dependOn(&run_cmd.step);

    // Interpreter unit tests
    const interp_tests = b.addTest(.{
        .root_source_file = b.path("interpret.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_interp_tests = b.addRunArtifact(interp_tests);

    // Hardware detection unit tests
    const detect_tests = b.addTest(.{
        .root_source_file = b.path("detect.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_detect_tests = b.addRunArtifact(detect_tests);

    // fano-detect CLI: prints the hardware profile and backend selection
    const detect_exe = b.addExecutable(.{
        .name = "fano-detect",
        .root_source_file = b.path("detect_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    detect_exe.root_module.addImport("detect", b.createModule(.{
        .root_source_file = b.path("detect.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(detect_exe);
    const detect_run = b.addRunArtifact(detect_exe);
    const detect_step = b.step("detect", "Run hardware detection");
    detect_step.dependOn(&detect_run.step);

    // Aggregate test step
    const test_step = b.step("test", "Run all Zig unit tests");
    test_step.dependOn(&run_interp_tests.step);
    test_step.dependOn(&run_detect_tests.step);

    // main.zig unit tests (helper functions: storeQ128/loadQ128 round-trip)
    const main_tests = b.addTest(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("q128_128", q128_mod);
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);
}
