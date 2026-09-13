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

    // Mesh tests
    const mesh_tests = b.addTest(.{
        .root_source_file = b.path("src/mesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_tests.root_module.addImport("fixed_point", fp_mod);
    test_step.dependOn(&b.addRunArtifact(mesh_tests).step);

    // P2P Types tests
    const p2p_tests = b.addTest(.{
        .root_source_file = b.path("src/p2p_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(p2p_tests).step);

    // Relay Router tests
    const relay_tests = b.addTest(.{
        .root_source_file = b.path("src/relay_router.zig"),
        .target = target,
        .optimize = optimize,
    });
    const p2p_mod = b.addModule("p2p_types", .{
        .root_source_file = b.path("src/p2p_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    relay_tests.root_module.addImport("p2p_types", p2p_mod);
    test_step.dependOn(&b.addRunArtifact(relay_tests).step);

    // Mesh Peer tests
    const mesh_peer_tests = b.addTest(.{
        .root_source_file = b.path("src/mesh_peer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mesh_mod = b.addModule("mesh", .{
        .root_source_file = b.path("src/mesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_mod.addImport("fixed_point", fp_mod);
    const p2p_mod_for_peer = b.addModule("p2p_types", .{
        .root_source_file = b.path("src/p2p_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const relay_mod = b.addModule("relay_router", .{
        .root_source_file = b.path("src/relay_router.zig"),
        .target = target,
        .optimize = optimize,
    });
    relay_mod.addImport("p2p_types", p2p_mod_for_peer);
    mesh_peer_tests.root_module.addImport("mesh", mesh_mod);
    mesh_peer_tests.root_module.addImport("p2p_types", p2p_mod_for_peer);
    mesh_peer_tests.root_module.addImport("relay_router", relay_mod);
    test_step.dependOn(&b.addRunArtifact(mesh_peer_tests).step);

    // === Example Executable ===

    const mesh_mod_exe = b.addModule("mesh", .{
        .root_source_file = b.path("src/mesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_mod_exe.addImport("fixed_point", fp_mod);

    const p2p_mod_exe = b.addModule("p2p_types", .{
        .root_source_file = b.path("src/p2p_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "qstar-mesh",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mesh", mesh_mod_exe);
    exe.root_module.addImport("p2p_types", p2p_mod_exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
