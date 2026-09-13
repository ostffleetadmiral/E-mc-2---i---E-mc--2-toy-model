const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all unit tests");

    // Standalone transport modules (std only)
    const standalone_modules = [_][]const u8{
        "src/transport_qr.zig",
        "src/transport_optar.zig",
        "src/transport_paperback.zig",
        "src/transport_audio.zig",
        "src/transport_cassette.zig",
        "src/transport_polyglot.zig",
        "src/transport_convert.zig",
        "src/transport_video.zig",
        "src/transport_quine.zig",
        "src/transport_stega.zig",
        "src/transport_wifi.zig",
        "src/transport_p2p.zig",
        "src/transport_lora.zig",
    };

    for (standalone_modules) |path| {
        const t = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Maypole bridge depends on transport_lora
    const lora_mod = b.addModule("transport_lora", .{
        .root_source_file = b.path("src/transport_lora.zig"),
        .target = target,
        .optimize = optimize,
    });

    const maypole_tests = b.addTest(.{
        .root_source_file = b.path("src/maypole_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    maypole_tests.root_module.addImport("transport_lora", lora_mod);
    test_step.dependOn(&b.addRunArtifact(maypole_tests).step);

    // === Example Executable ===

    const qr_mod = b.addModule("transport_qr", .{
        .root_source_file = b.path("src/transport_qr.zig"),
        .target = target,
        .optimize = optimize,
    });
    const polyglot_mod = b.addModule("transport_polyglot", .{
        .root_source_file = b.path("src/transport_polyglot.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lora_mod2 = b.addModule("transport_lora", .{
        .root_source_file = b.path("src/transport_lora.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "qstar-transport",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("transport_qr", qr_mod);
    exe.root_module.addImport("transport_polyglot", polyglot_mod);
    exe.root_module.addImport("transport_lora", lora_mod2);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
