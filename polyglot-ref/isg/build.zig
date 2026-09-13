const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import the Q128.128 engine module from ../zig/
    const q128_mod = b.createModule(.{
        .root_source_file = b.path("../zig/q128_128.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Q128 error correction tests
    const ec_tests = b.addTest(.{
        .root_source_file = b.path("q128_error_correct.zig"),
        .target = target,
        .optimize = optimize,
    });
    ec_tests.root_module.addImport("q128_128", q128_mod);
    const run_ec_tests = b.addRunArtifact(ec_tests);
    const ec_test_step = b.step("test-ec", "Run Q128 error correction tests");
    ec_test_step.dependOn(&run_ec_tests.step);

    // RGB packer tests
    const packer_tests = b.addTest(.{
        .root_source_file = b.path("rgb_packer.zig"),
        .target = target,
        .optimize = optimize,
    });
    packer_tests.root_module.addImport("q128_128", q128_mod);
    const run_packer_tests = b.addRunArtifact(packer_tests);
    const packer_test_step = b.step("test-packer", "Run RGB packer tests");
    packer_test_step.dependOn(&run_packer_tests.step);

    // RGB unpacker tests (needs q128 for checksum verification)
    const unpacker_tests = b.addTest(.{
        .root_source_file = b.path("rgb_unpacker.zig"),
        .target = target,
        .optimize = optimize,
    });
    unpacker_tests.root_module.addImport("q128_128", q128_mod);
    const run_unpacker_tests = b.addRunArtifact(unpacker_tests);
    const unpacker_test_step = b.step("test-unpacker", "Run RGB unpacker tests");
    unpacker_test_step.dependOn(&run_unpacker_tests.step);

    // Video I/O tests
    const video_tests = b.addTest(.{
        .root_source_file = b.path("video_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_video_tests = b.addRunArtifact(video_tests);
    const video_test_step = b.step("test-video", "Run video I/O tests");
    video_test_step.dependOn(&run_video_tests.step);

    // OpenCV availability option
    const has_opencv = b.option(bool, "has-opencv", "Enable OpenCV MP4 support") orelse false;

    // Conditionally use real OpenCV bridge or stub
    const opencv_mod = b.createModule(.{
        .root_source_file = if (has_opencv)
            b.path("opencv_bridge.zig")
        else
            b.path("opencv_stub.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ISG CLI executable
    const exe = b.addExecutable(.{
        .name = "isg-rgb",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("q128_128", q128_mod);
    exe.root_module.addImport("opencv", opencv_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the ISG RGB transcoder CLI");
    run_step.dependOn(&run_cmd.step);

    // OpenCV bridge tests (requires OpenCV installed)
    const opencv_tests = b.addTest(.{
        .root_source_file = b.path("opencv_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_opencv_tests = b.addRunArtifact(opencv_tests);
    const opencv_test_step = b.step("test-opencv", "Run OpenCV bridge tests");
    opencv_test_step.dependOn(&run_opencv_tests.step);

    // Aggregate test step (opencv tests are separate: zig build test-opencv)
    const test_step = b.step("test", "Run all ISG tests");
    test_step.dependOn(&run_ec_tests.step);
    test_step.dependOn(&run_packer_tests.step);
    test_step.dependOn(&run_unpacker_tests.step);
    test_step.dependOn(&run_video_tests.step);
}
