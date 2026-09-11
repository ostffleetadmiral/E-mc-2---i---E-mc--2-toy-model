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
    // Note: Only integer-only verification functions are exported.
    // The full proof suite uses i256 arithmetic which requires compiler-rt
    // library calls not available in wasm32-wasi with Zig 0.13.0.
    // For full proof verification, use the native binary (emc2-proofs).
    const wasm_lib = b.addExecutable(.{
        .name = "emc2-proofs",
        .root_source_file = b.path("wasm_main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    b.installArtifact(wasm_lib);

    const build_step = b.step("build", "Build WASM library");
    build_step.dependOn(&wasm_lib.step);
}
