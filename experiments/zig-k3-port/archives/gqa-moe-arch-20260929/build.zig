const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    // -Dgpu enables the optional Vulkan compute backend. It is runtime-detected
    // (dlopen), so a gpu-enabled binary still runs CPU-only on Vulkan-less
    // hosts. Requires libc for dlopen; WASI/freestanding targets never get it.
    const gpu_requested = b.option(bool, "gpu", "Enable the optional Vulkan Q128.128 compute backend") orelse false;
    const gpu_enabled = gpu_requested and target.result.os.tag != .wasi and target.result.os.tag != .freestanding;

    // ---- modules ------------------------------------------------------------
    // The q128.128 substrate vendored from Digit (see headers for provenance).
    const qmul = b.addModule("qmul", .{
        .root_source_file = b.path("src/qmul.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixed_point = b.addModule("fixed_point", .{
        .root_source_file = b.path("src/fixed_point.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixed_point.addImport("qmul", qmul);
    const q128 = b.addModule("q128", .{
        .root_source_file = b.path("src/q128.zig"),
        .target = target,
        .optimize = optimize,
    });
    q128.addImport("fixed_point", fixed_point);

    const json = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
        .target = target,
        .optimize = optimize,
    });
    json.addImport("fixed_point", fixed_point);

    const k3 = b.addModule("k3", .{
        .root_source_file = b.path("src/k3.zig"),
        .target = target,
        .optimize = optimize,
    });
    k3.addImport("fixed_point", fixed_point);

    const tok = b.addModule("tok", .{
        .root_source_file = b.path("src/tok.zig"),
        .target = target,
        .optimize = optimize,
    });
    tok.addImport("json", json);

    const tok_loader = b.addModule("tok_loader", .{
        .root_source_file = b.path("src/tok_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    tok_loader.addImport("tok", tok);
    tok_loader.addImport("json", json);

    const cfg = b.addModule("cfg", .{
        .root_source_file = b.path("src/cfg.zig"),
        .target = target,
        .optimize = optimize,
    });
    cfg.addImport("json", json);
    cfg.addImport("k3", k3);
    cfg.addImport("fixed_point", fixed_point);

    // Named modules for the flat src/ files. Every intra-src import uses a
    // module name (not a sibling path) so each file exists in exactly one
    // module per compilation — required for tools/ to share them.
    const pio = b.addModule("pio", .{
        .root_source_file = b.path("src/pio.zig"),
        .target = target,
        .optimize = optimize,
    });

    const st = b.addModule("st", .{
        .root_source_file = b.path("src/st.zig"),
        .target = target,
        .optimize = optimize,
    });
    st.addImport("pio", pio);

    const load = b.addModule("load", .{
        .root_source_file = b.path("src/load.zig"),
        .target = target,
        .optimize = optimize,
    });
    load.addImport("k3", k3);
    load.addImport("st", st);
    load.addImport("pio", pio);

    const bind = b.addModule("bind", .{
        .root_source_file = b.path("src/bind.zig"),
        .target = target,
        .optimize = optimize,
    });
    bind.addImport("k3", k3);
    bind.addImport("st", st);
    bind.addImport("fixed_point", fixed_point);

    const cache = b.addModule("cache", .{
        .root_source_file = b.path("src/cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    cache.addImport("k3", k3);
    cache.addImport("st", st);
    cache.addImport("load", load);
    cache.addImport("pio", pio);
    cache.addImport("fixed_point", fixed_point);

    const trunk = b.addModule("trunk", .{
        .root_source_file = b.path("src/trunk.zig"),
        .target = target,
        .optimize = optimize,
    });
    trunk.addImport("k3", k3);
    trunk.addImport("st", st);
    trunk.addImport("bind", bind);
    trunk.addImport("pio", pio);
    trunk.addImport("json", json);

    const ops = b.addModule("ops", .{
        .root_source_file = b.path("src/ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    ops.addImport("fixed_point", fixed_point);
    ops.addImport("k3", k3);
    ops.addImport("json", json);

    const model = b.addModule("model", .{
        .root_source_file = b.path("src/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    model.addImport("json", json);
    model.addImport("k3", k3);
    model.addImport("cfg", cfg);
    model.addImport("st", st);
    model.addImport("pio", pio);
    model.addImport("ops", ops);

    // ---- generic GQA+MoE architecture family (phase A: qwen3_moe/olmoe) ----
    const gqa_cfg = b.addModule("gqa_cfg", .{
        .root_source_file = b.path("src/gqa_cfg.zig"),
        .target = target,
        .optimize = optimize,
    });
    gqa_cfg.addImport("json", json);
    gqa_cfg.addImport("fixed_point", fixed_point);

    const gqa_ops = b.addModule("gqa_ops", .{
        .root_source_file = b.path("src/gqa_ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    gqa_ops.addImport("fixed_point", fixed_point);
    gqa_ops.addImport("k3", k3);
    gqa_ops.addImport("gqa_cfg", gqa_cfg);
    gqa_ops.addImport("ops", ops);

    const gqa_attn = b.addModule("gqa_attn", .{
        .root_source_file = b.path("src/gqa_attn.zig"),
        .target = target,
        .optimize = optimize,
    });
    gqa_attn.addImport("fixed_point", fixed_point);
    gqa_attn.addImport("k3", k3);
    gqa_attn.addImport("ops", ops);

    const gqa_bind = b.addModule("gqa_bind", .{
        .root_source_file = b.path("src/gqa_bind.zig"),
        .target = target,
        .optimize = optimize,
    });
    gqa_bind.addImport("k3", k3);
    gqa_bind.addImport("st", st);
    gqa_bind.addImport("fixed_point", fixed_point);
    gqa_bind.addImport("gqa_cfg", gqa_cfg);

    const model_gqa = b.addModule("model_gqa", .{
        .root_source_file = b.path("src/model_gqa.zig"),
        .target = target,
        .optimize = optimize,
    });
    model_gqa.addImport("json", json);
    model_gqa.addImport("k3", k3);
    model_gqa.addImport("st", st);
    model_gqa.addImport("pio", pio);
    model_gqa.addImport("ops", ops);
    model_gqa.addImport("fixed_point", fixed_point);
    model_gqa.addImport("gqa_cfg", gqa_cfg);
    model_gqa.addImport("gqa_ops", gqa_ops);
    model_gqa.addImport("gqa_attn", gqa_attn);
    model_gqa.addImport("gqa_bind", gqa_bind);
    model_gqa.addImport("model", model);

    const fixed_bridge = b.addModule("fixed_bridge", .{
        .root_source_file = b.path("src/fixed_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixed_bridge.addImport("fixed_point", fixed_point);
    fixed_bridge.addImport("k3", k3);
    fixed_bridge.addImport("st", st);
    fixed_bridge.addImport("load", load);

    const gpu = if (gpu_enabled) blk: {
        const m = b.addModule("gpu", .{
            .root_source_file = b.path("src/gpu.zig"),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("fixed_point", fixed_point);
        m.addImport("ops", ops);
        m.addImport("k3", k3);
        break :blk m;
    } else null;

    // main.zig as an importable module for tools that drive the engine's own
    // bind+forward (the checkpoint generator's ref_logits path).
    const k3main = b.addModule("k3main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    k3main.addImport("fixed_point", fixed_point);
    k3main.addImport("q128", q128);
    k3main.addImport("json", json);
    k3main.addImport("k3", k3);
    k3main.addImport("tok", tok);
    k3main.addImport("tok_loader", tok_loader);
    k3main.addImport("cfg", cfg);
    k3main.addImport("st", st);
    k3main.addImport("pio", pio);
    k3main.addImport("bind", bind);
    k3main.addImport("cache", cache);
    k3main.addImport("trunk", trunk);
    k3main.addImport("ops", ops);
    k3main.addImport("model", model);
    k3main.addImport("gqa_cfg", gqa_cfg);
    k3main.addImport("gqa_bind", gqa_bind);
    k3main.addImport("model_gqa", model_gqa);

    // ---- k3 CLI ---------------------------------------------------------------
    // main.zig @import()s the flat siblings (st/pio/bind/cache/trunk/ops/model)
    // directly; the cross-module deps come through the named modules.
    const k3_exe = b.addExecutable(.{
        .name = "k3",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    k3_exe.root_module.addImport("fixed_point", fixed_point);
    k3_exe.root_module.addImport("q128", q128);
    k3_exe.root_module.addImport("json", json);
    k3_exe.root_module.addImport("k3", k3);
    k3_exe.root_module.addImport("tok", tok);
    k3_exe.root_module.addImport("tok_loader", tok_loader);
    k3_exe.root_module.addImport("cfg", cfg);
    k3_exe.root_module.addImport("pio", pio);
    k3_exe.root_module.addImport("st", st);
    k3_exe.root_module.addImport("bind", bind);
    k3_exe.root_module.addImport("cache", cache);
    k3_exe.root_module.addImport("trunk", trunk);
    k3_exe.root_module.addImport("ops", ops);
    k3_exe.root_module.addImport("model", model);
    k3_exe.root_module.addImport("gqa_cfg", gqa_cfg);
    k3_exe.root_module.addImport("gqa_ops", gqa_ops);
    k3_exe.root_module.addImport("gqa_attn", gqa_attn);
    k3_exe.root_module.addImport("gqa_bind", gqa_bind);
    k3_exe.root_module.addImport("model_gqa", model_gqa);
    // wasi-libc provides the absolute-path resolution (preopen prefix match)
    // and environ plumbing that bare WASI lacks; native targets keep Zig's
    // direct-syscall path.
    // wasi-libc provides the absolute-path resolution (preopen prefix match)
    // and environ plumbing that bare WASI lacks; it exists for wasm32 only —
    // wasm64-wasi has no libc in Zig 0.13, and absolute paths are unsupported
    // there (preopen-relative paths only).
    if (target.result.os.tag == .wasi and target.result.cpu.arch == .wasm32) {
        k3_exe.linkLibC();
        // The decoder's scratch frames exceed Zig's default wasm stack.
        k3_exe.stack_size = 16 * 1024 * 1024;
    }
    {
        // Real gpu module with -Dgpu, otherwise a comptime-available stub so
        // src/main.zig compiles identically on both paths.
        const gm = if (gpu) |m| m else b.addModule("gpu_stub", .{
            .root_source_file = b.path("src/gpu_stub.zig"),
            .target = target,
            .optimize = optimize,
        });
        k3_exe.root_module.addImport("gpu", gm);
        if (gpu != null) {
            // dlopen/dlsym for the runtime Vulkan binding come from libc.
            if (target.result.os.tag != .wasi) k3_exe.linkLibC();
        }
    }
    b.installArtifact(k3_exe);
    const run_step = b.step("run", "Run the k3 CLI (k3 <model_dir> [options])");
    const run_cmd = b.addRunArtifact(k3_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- tools ---------------------------------------------------------------
    // Native ports of the checkpoint-independent Python tools plus the kernel
    // benchmark. They @import() src siblings relatively; module deps are the
    // same set the CLI gets.
    const tool_specs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "pack_trunk", .path = "tools/pack_trunk.zig" },
        .{ .name = "cmp_logits", .path = "tools/cmp_logits.zig" },
        .{ .name = "k3bench", .path = "tools/bench.zig" },
        .{ .name = "make_tiny_checkpoint", .path = "tools/make_tiny_checkpoint.zig" },
        .{ .name = "replay_real_layer", .path = "tools/replay_real_layer.zig" },
        .{ .name = "int8_trunk", .path = "tools/int8_trunk.zig" },
        .{ .name = "qdq_trunk", .path = "tools/qdq_trunk.zig" },
        .{ .name = "tok_probe", .path = "tools/tok_probe.zig" },
    };
    for (tool_specs) |ts| {
        const exe = b.addExecutable(.{
            .name = ts.name,
            .root_source_file = b.path(ts.path),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("fixed_point", fixed_point);
        exe.root_module.addImport("q128", q128);
        exe.root_module.addImport("json", json);
        exe.root_module.addImport("k3", k3);
        exe.root_module.addImport("tok", tok);
        exe.root_module.addImport("tok_loader", tok_loader);
        exe.root_module.addImport("cfg", cfg);
        exe.root_module.addImport("pio", pio);
        exe.root_module.addImport("st", st);
        exe.root_module.addImport("ops", ops);
        exe.root_module.addImport("bind", bind);
        exe.root_module.addImport("cache", cache);
        exe.root_module.addImport("model", model);
        exe.root_module.addImport("k3main", k3main);
        if (target.result.os.tag == .wasi and target.result.cpu.arch == .wasm32) exe.linkLibC();
        {
            const gm = if (gpu) |m| m else b.addModule("gpu_stub", .{
                .root_source_file = b.path("src/gpu_stub.zig"),
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("gpu", gm);
            if (gpu != null and target.result.os.tag != .wasi) exe.linkLibC();
        }
        b.installArtifact(exe);
    }
    // ---- prototype ------------------------------------------------------------
    // N-session shared-weights decode experiment (prototype/README.md). Same
    // module surface as the tools.
    {
        const exe = b.addExecutable(.{
            .name = "multi_session",
            .root_source_file = b.path("prototype/multi_session.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("fixed_point", fixed_point);
        exe.root_module.addImport("k3", k3);
        exe.root_module.addImport("ops", ops);
        exe.root_module.addImport("json", json);
        exe.root_module.addImport("cfg", cfg);
        exe.root_module.addImport("model", model);
        exe.root_module.addImport("pio", pio);
        b.installArtifact(exe);
    }
    {
        // Layer-lockstep batching: drives the REAL trunk+cache path through
        // the k3main module (sequential baseline = k3main.forward itself).
        const exe = b.addExecutable(.{
            .name = "lockstep",
            .root_source_file = b.path("prototype/lockstep.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("fixed_point", fixed_point);
        exe.root_module.addImport("k3", k3);
        exe.root_module.addImport("ops", ops);
        exe.root_module.addImport("json", json);
        exe.root_module.addImport("cfg", cfg);
        exe.root_module.addImport("st", st);
        exe.root_module.addImport("bind", bind);
        exe.root_module.addImport("cache", cache);
        exe.root_module.addImport("trunk", trunk);
        exe.root_module.addImport("model", model);
        exe.root_module.addImport("pio", pio);
        exe.root_module.addImport("k3main", k3main);
        b.installArtifact(exe);
    }

    if (gpu_enabled) {
        const gpu_tools = [_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "gpu_info", .path = "tools/gpu_info.zig" },
            .{ .name = "gpu_selftest", .path = "tools/gpu_selftest.zig" },
            .{ .name = "gpu_matmul", .path = "tools/gpu_matmul.zig" },
        };
        for (gpu_tools) |gt| {
            const exe = b.addExecutable(.{
                .name = gt.name,
                .root_source_file = b.path(gt.path),
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("gpu", gpu.?);
            exe.root_module.addImport("fixed_point", fixed_point);
            exe.root_module.addImport("ops", ops);
            exe.root_module.addImport("k3", k3);
            exe.linkLibC();
            b.installArtifact(exe);
        }
    }

    // ---- tests ----------------------------------------------------------------
    // Each ported module carries inline tests; this runner aggregates the files
    // that exist so far. Files are added as their ports land.
    const test_roots = [_][]const u8{
        "src/fixed_point.zig",
        "src/qmul.zig",
        "src/qmul4.zig",
        "src/qmul4_32.zig",
        "src/q128.zig",
        "src/gqa_cfg.zig",
        "src/gqa_ops.zig",
        "src/gqa_attn.zig",
        "src/gqa_bind.zig",
        "src/model_gqa.zig",
        "src/json.zig",
        "src/k3.zig",
        "src/cfg.zig",
        "src/tok.zig",
        "src/tok_loader.zig",
        "src/pio.zig",
        "src/st.zig",
        "src/load.zig",
        "src/cache.zig",
        "src/bind.zig",
        "src/trunk.zig",
        "src/fixed_bridge.zig",
        "src/ops.zig",
        "src/model.zig",
        "src/main.zig",
        "src/scale_test.zig",
        "sidecar/verify_ops.zig",
    };
    const test_step = b.step("test", "Run all tests");
    if (gpu) |gpu_module| {
        for ([_][]const u8{ "src/gpu/q128_selftest_test.zig", "src/gpu/matmul_test.zig", "src/gpu/layers_test.zig", "src/gpu/kda_test.zig", "src/gpu/composite_test.zig", "src/gpu/e2e_test.zig" }) |root| {
            const gpu_test = b.addTest(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            });
            gpu_test.root_module.addImport("fixed_point", fixed_point);
            gpu_test.root_module.addImport("ops", ops);
            gpu_test.root_module.addImport("k3", k3);
            gpu_test.root_module.addImport("gpu", gpu_module);
            gpu_test.root_module.addImport("json", json);
            gpu_test.root_module.addImport("cfg", cfg);
            gpu_test.root_module.addImport("st", st);
            gpu_test.root_module.addImport("pio", pio);
            gpu_test.root_module.addImport("model", model);
            gpu_test.linkLibC();
            test_step.dependOn(&b.addRunArtifact(gpu_test).step);
        }
    }
    for (test_roots) |root| {
        const t = b.addTest(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        t.root_module.addImport("fixed_point", fixed_point);
        t.root_module.addImport("qmul", qmul);
        t.root_module.addImport("q128", q128);
        t.root_module.addImport("json", json);
        t.root_module.addImport("k3", k3);
        t.root_module.addImport("tok", tok);
        t.root_module.addImport("tok_loader", tok_loader);
        t.root_module.addImport("cfg", cfg);
        t.root_module.addImport("pio", pio);
        t.root_module.addImport("st", st);
        t.root_module.addImport("load", load);
        t.root_module.addImport("bind", bind);
        t.root_module.addImport("cache", cache);
        t.root_module.addImport("trunk", trunk);
        t.root_module.addImport("ops", ops);
        t.root_module.addImport("model", model);
        t.root_module.addImport("fixed_bridge", fixed_bridge);
        t.root_module.addImport("k3main", k3main);
        t.root_module.addImport("gqa_cfg", gqa_cfg);
        t.root_module.addImport("gqa_ops", gqa_ops);
        t.root_module.addImport("gqa_attn", gqa_attn);
        t.root_module.addImport("gqa_bind", gqa_bind);
        t.root_module.addImport("model_gqa", model_gqa);
        // The sidecar reproduces the C kernels byte-exactly; its expf/tanhf must
        // be the same libm the C binary calls, not Zig's own approximations.
        if (std.mem.eql(u8, root, "sidecar/verify_ops.zig")) t.linkLibC();
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ---- shaders --------------------------------------------------------------
    // Manual convenience step: `zig build shaders` recompiles the compute
    // shaders with glslc and validates with spirv-val when both exist. The
    // committed src/gpu/spirv/*.spv are canonical; this step is not part of
    // any automatic build graph (in-tree output paths, no lazy tracking).
    const shaders_step = b.step("shaders", "Recompile src/gpu/shaders/*.comp to SPIR-V (requires glslc)");
    const glslc = b.findProgram(&.{"glslc"}, &.{}) catch null;
    if (glslc) |glslc_path| {
        const shader_sources = [_][]const u8{
            "q128_selftest",
            "q128_matmul",
            "q128_matmul4",
            "q128_matmul4_group",
            "q128_causal_conv",
            "q128_linear_attention",
            "q128_sigmoid",
            "k3_mmw",
            "k3_mxfp4",
            "k3_norm",
            "k3_situ_glu",
            "k3_shortconv",
            "k3_router",
            "k3_attnres",
            "k3_kda",
            "k3_elem",
        };
        const spirv_val = b.findProgram(&.{"spirv-val"}, &.{}) catch null;
        for (shader_sources) |name| {
            const src = b.fmt("src/gpu/shaders/{s}.comp", .{name});
            const spv = b.fmt("src/gpu/spirv/{s}.spv", .{name});
            const compile = b.addSystemCommand(&.{ glslc_path, "--target-env=vulkan1.3", "-fshader-stage=compute", "-O", "-I", "src/gpu/shaders", "-o", spv, src });
            shaders_step.dependOn(&compile.step);
            if (spirv_val) |val_path| {
                const validate = b.addSystemCommand(&.{ val_path, spv });
                validate.step.dependOn(&compile.step);
                shaders_step.dependOn(&validate.step);
            }
        }
    } else {
        const note = b.addSystemCommand(&.{ "echo", "glslc not found; committed src/gpu/spirv/*.spv remain in effect" });
        shaders_step.dependOn(&note.step);
    }
}
