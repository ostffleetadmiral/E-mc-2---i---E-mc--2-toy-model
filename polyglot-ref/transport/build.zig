const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const q128_mod = b.createModule(.{
        .root_source_file = b.path("../zig/q128_128.zig"),
        .target = target,
        .optimize = optimize,
    });

    // fsk_modem tests
    const fsk_tests = b.addTest(.{
        .root_source_file = b.path("fsk_modem.zig"),
        .target = target,
        .optimize = optimize,
    });
    fsk_tests.root_module.addImport("q128_128", q128_mod);
    const run_fsk_tests = b.addRunArtifact(fsk_tests);

    // optical_token tests
    const token_tests = b.addTest(.{
        .root_source_file = b.path("optical_token.zig"),
        .target = target,
        .optimize = optimize,
    });
    token_tests.root_module.addImport("q128_128", q128_mod);
    const run_token_tests = b.addRunArtifact(token_tests);

    // steganography tests
    const stego_tests = b.addTest(.{
        .root_source_file = b.path("steganography.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_stego_tests = b.addRunArtifact(stego_tests);

    // polyglot tests
    const polyglot_tests = b.addTest(.{
        .root_source_file = b.path("polyglot.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_polyglot_tests = b.addRunArtifact(polyglot_tests);

    const test_step = b.step("test", "Run all transport tests");
    test_step.dependOn(&run_fsk_tests.step);
    test_step.dependOn(&run_token_tests.step);
    test_step.dependOn(&run_stego_tests.step);
    test_step.dependOn(&run_polyglot_tests.step);
}
