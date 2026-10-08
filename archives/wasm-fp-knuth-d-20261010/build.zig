// WASM build target for the E=mc²-i-E=mc⁻² toy-model proof suite.
//
// Builds the core Zig proof modules for wasm32-wasi, enabling
// bit-exact cross-platform verification in browsers and WASM runtimes.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Build for wasm32-wasi target
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // WASM library (for browser embedding)
    // Exports the integer identity checks plus real Q128.128 fixed-point
    // proofs. Wide (i512/u512) division is computed via the Knuth-D limb
    // division in src/fixed_point.zig — LLVM has no i512 div libcall on
    // wasm32, but u128 div has one on every target.
    const wasm_lib = b.addExecutable(.{
        .name = "emc2-proofs",
        .root_source_file = b.path("wasm_main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const fp_mod = b.createModule(.{
        .root_source_file = b.path("../src/fixed_point.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_lib.root_module.addImport("fixed_point", fp_mod);
    b.installArtifact(wasm_lib);

    const build_step = b.step("build", "Build WASM library");
    build_step.dependOn(&wasm_lib.step);
}
