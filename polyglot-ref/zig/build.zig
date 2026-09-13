const std = @import("std");

fn fsh_mod_setup(t: anytype, q128_mod: anytype, b: *std.Build, target: anytype, optimize: anytype) void {
    const holo_mod = b.createModule(.{
        .root_source_file = b.path("holo.zig"),
        .target = target,
        .optimize = optimize,
    });
    holo_mod.addImport("q128_128", q128_mod);
    t.root_module.addImport("q128_128", q128_mod);
    t.root_module.addImport("holo", holo_mod);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const q128_mod = b.createModule(.{
        .root_source_file = b.path("q128_128.zig"),
        .target = target,
        .optimize = optimize,
    });

    // FANO-1 CLI (RamseyIdentity simulation)
    const exe = b.addExecutable(.{
        .name = "fano",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("q128_128", q128_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the FANO-1 RamseyIdentity simulation");
    run_step.dependOn(&run_cmd.step);

    // Engine unit tests
    const engine_tests = b.addTest(.{
        .root_source_file = b.path("q128_128.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    const engine_test_step = b.step("test-engine", "Run Q128.128 engine unit tests");
    engine_test_step.dependOn(&run_engine_tests.step);

    // RamseyIdentity unit tests
    const ri_tests = b.addTest(.{
        .root_source_file = b.path("ramsey_identity.zig"),
        .target = target,
        .optimize = optimize,
    });
    ri_tests.root_module.addImport("q128_128", q128_mod);
    const run_ri_tests = b.addRunArtifact(ri_tests);
    const ri_test_step = b.step("test-ramsey", "Run RamseyIdentity unit tests");
    ri_test_step.dependOn(&run_ri_tests.step);

    // Holographic codec tests
    const holo_tests = b.addTest(.{
        .root_source_file = b.path("holo.zig"),
        .target = target,
        .optimize = optimize,
    });
    holo_tests.root_module.addImport("q128_128", q128_mod);
    const run_holo_tests = b.addRunArtifact(holo_tests);
    const holo_test_step = b.step("test-holo", "Run holographic codec unit tests");
    holo_test_step.dependOn(&run_holo_tests.step);

    // fano-codec CLI
    const holo_mod = b.createModule(.{
        .root_source_file = b.path("holo.zig"),
        .target = target,
        .optimize = optimize,
    });
    holo_mod.addImport("q128_128", q128_mod);
    const codec = b.addExecutable(.{
        .name = "fano-codec",
        .root_source_file = b.path("holo_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    codec.root_module.addImport("holo", holo_mod);
    b.installArtifact(codec);
    const codec_run = b.addRunArtifact(codec);
    const codec_step = b.step("codec", "Run the codec ratio simulation");
    codec_step.dependOn(&codec_run.step);

    // fano-sh tests + executable
    const fsh_tests = b.addTest(.{
        .root_source_file = b.path("fano_sh.zig"),
        .target = target,
        .optimize = optimize,
    });
    fsh_mod_setup(fsh_tests, q128_mod, b, target, optimize);
    const run_fsh_tests = b.addRunArtifact(fsh_tests);

    const fsh_mod = b.createModule(.{
        .root_source_file = b.path("fano_sh.zig"),
        .target = target,
        .optimize = optimize,
    });
    fsh_mod.addImport("q128_128", q128_mod);
    fsh_mod.addImport("holo", holo_mod);
    const fansh = b.addExecutable(.{
        .name = "fano-sh",
        .root_source_file = b.path("fano_sh_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    fansh.root_module.addImport("fano_sh", fsh_mod);
    b.installArtifact(fansh);

    // Fano tensor tests
    const fano_tests = b.addTest(.{
        .root_source_file = b.path("fano_tensor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_fano_tests = b.addRunArtifact(fano_tests);
    const fano_test_step = b.step("test-fano", "Run Fano tensor unit tests");
    fano_test_step.dependOn(&run_fano_tests.step);

    // Scale table tests
    const scale_tests = b.addTest(.{
        .root_source_file = b.path("scale_table.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_scale_tests = b.addRunArtifact(scale_tests);
    const scale_test_step = b.step("test-scale", "Run scale table unit tests");
    scale_test_step.dependOn(&run_scale_tests.step);

    // Scale table CLI
    const scale_exe = b.addExecutable(.{
        .name = "fano-scale",
        .root_source_file = b.path("scale_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(scale_exe);
    const scale_run = b.addRunArtifact(scale_exe);
    const scale_step = b.step("scale", "Print the scale/expansion table");
    scale_step.dependOn(&scale_run.step);

    // Triad constants engine tests + fano-const CLI
    const triad_mod = b.createModule(.{
        .root_source_file = b.path("triad.zig"),
        .target = target,
        .optimize = optimize,
    });
    triad_mod.addImport("q128_128", q128_mod);
    const triad_tests = b.addTest(.{
        .root_source_file = b.path("triad.zig"),
        .target = target,
        .optimize = optimize,
    });
    triad_tests.root_module.addImport("q128_128", q128_mod);
    const run_triad_tests = b.addRunArtifact(triad_tests);
    const triad_test_step = b.step("test-triad", "Run Mound triad engine unit tests");
    triad_test_step.dependOn(&run_triad_tests.step);

    const const_exe = b.addExecutable(.{
        .name = "fano-const",
        .root_source_file = b.path("fano_const_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const triad_mod_cli = b.createModule(.{
        .root_source_file = b.path("triad.zig"),
        .target = target,
        .optimize = optimize,
    });
    triad_mod_cli.addImport("q128_128", q128_mod);
    const_exe.root_module.addImport("triad", triad_mod_cli);
    const_exe.root_module.addImport("q128_128", q128_mod);
    b.installArtifact(const_exe);

    // phi_cooling tests
    const phi_tests = b.addTest(.{
        .root_source_file = b.path("phi_cooling.zig"),
        .target = target,
        .optimize = optimize,
    });
    phi_tests.root_module.addImport("q128_128", q128_mod);
    const phi_triad_mod = b.createModule(.{
        .root_source_file = b.path("triad.zig"),
        .target = target,
        .optimize = optimize,
    });
    phi_triad_mod.addImport("q128_128", q128_mod);
    phi_tests.root_module.addImport("triad", phi_triad_mod);
    const run_phi_tests = b.addRunArtifact(phi_tests);
    const phi_test_step = b.step("test-phi-cooling", "Run phi-cooling unit tests");
    phi_test_step.dependOn(&run_phi_tests.step);

    // Smith chart tests
    const smith_tests = b.addTest(.{
        .root_source_file = b.path("smith.zig"),
        .target = target,
        .optimize = optimize,
    });
    smith_tests.root_module.addImport("q128_128", q128_mod);
    const run_smith_tests = b.addRunArtifact(smith_tests);
    const smith_test_step = b.step("test-smith", "Run quad Smith chart unit tests");
    smith_test_step.dependOn(&run_smith_tests.step);

    // RF harvesting tests + fano-rf CLI
    const rf_tests = b.addTest(.{
        .root_source_file = b.path("rf_harvest.zig"),
        .target = target,
        .optimize = optimize,
    });
    rf_tests.root_module.addImport("q128_128", q128_mod);
    const run_rf_tests = b.addRunArtifact(rf_tests);
    const rf_test_step = b.step("test-rf", "Run RF harvesting unit tests");
    rf_test_step.dependOn(&run_rf_tests.step);

    const rf_exe = b.addExecutable(.{
        .name = "fano-rf",
        .root_source_file = b.path("fano_rf_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rf_mod = b.createModule(.{
        .root_source_file = b.path("rf_harvest.zig"),
        .target = target,
        .optimize = optimize,
    });
    rf_mod.addImport("q128_128", q128_mod);
    rf_exe.root_module.addImport("rf_harvest", rf_mod);
    rf_exe.root_module.addImport("q128_128", q128_mod);
    b.installArtifact(rf_exe);

    // Polyglot runtime (poly.zig): QuickJS vendored C + system CPython.
    const poly_mod = b.createModule(.{
        .root_source_file = b.path("poly/poly.zig"),
        .target = target,
        .optimize = optimize,
    });
    poly_mod.addImport("q128_128", q128_mod);
    poly_mod.addIncludePath(b.path("poly/vendor"));
    poly_mod.addIncludePath(b.path("poly/c_guest"));
    poly_mod.addCSourceFiles(.{
        .root = b.path("poly/vendor"),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "libbf.c", "cutils.c" },
        .flags = &.{ "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2024-01-13\"", "-O2", "-fno-sanitize=undefined" },
    });
    poly_mod.addCSourceFile(.{
        .file = b.path("poly/c_guest/guest.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    poly_mod.link_libc = true;

    // Detect CPython headers/libs (pyenv or system) at build time.
    if (detectPython(b)) |py| {
        poly_mod.addSystemIncludePath(.{ .cwd_relative = py.include });
        poly_mod.addLibraryPath(.{ .cwd_relative = py.libdir });
        poly_mod.linkSystemLibrary(b.fmt("python{s}", .{py.ldversion}), .{});
        poly_mod.addRPath(.{ .cwd_relative = py.libdir });
    }

    const poly_tests = b.addTest(.{
        .root_source_file = b.path("poly/poly.zig"),
        .target = target,
        .optimize = optimize,
    });
    poly_tests.root_module.addImport("q128_128", q128_mod);
    poly_tests.root_module.addIncludePath(b.path("poly/vendor"));
    poly_tests.root_module.addCSourceFiles(.{
        .root = b.path("poly/vendor"),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "libbf.c", "cutils.c" },
        .flags = &.{ "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2024-01-13\"", "-O2", "-fno-sanitize=undefined" },
    });
    poly_tests.root_module.addCSourceFile(.{
        .file = b.path("poly/c_guest/guest.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    poly_tests.root_module.link_libc = true;
    if (detectPython(b)) |py| {
        poly_tests.root_module.addSystemIncludePath(.{ .cwd_relative = py.include });
        poly_tests.root_module.addLibraryPath(.{ .cwd_relative = py.libdir });
        poly_tests.linkSystemLibrary(b.fmt("python{s}", .{py.ldversion}));
        poly_tests.addRPath(.{ .cwd_relative = py.libdir });
    }
    const run_poly_tests = b.addRunArtifact(poly_tests);
    const poly_test_step = b.step("test-poly", "Run polyglot runtime unit tests");
    poly_test_step.dependOn(&run_poly_tests.step);

    // Rust guest staticlib (fano-poly-rs) built by cargo.
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo.setCwd(b.path("poly/rust_guest"));
    const rs_lib = b.path("poly/rust_guest/target/release/libfano_poly_rs.a");
    poly_tests.step.dependOn(&cargo.step);
    poly_tests.addObjectFile(rs_lib);

    // C# guest compiled to a native shared library via NativeAOT.
    const dotnet = b.addSystemCommand(&.{
        "dotnet",             "publish",                "-c",       "Release", "-r", "linux-x64",
        "-p:PublishAot=true", "-p:PublishDir=publish/", "--nologo", "-v",      "q",
    });
    dotnet.setCwd(b.path("poly/dotnet_guest"));
    poly_tests.step.dependOn(&dotnet.step);

    // Q# guest runner built offline from the cached QDK (NuGet packages).
    // Normal framework-dependent publish: fast, runs via the dotnet host.
    const qs_build = b.addSystemCommand(&.{
        "dotnet",                 "publish",  "-c", "Release",
        "-p:PublishDir=publish/", "--nologo", "-v", "q",
    });
    qs_build.setCwd(b.path("poly/qs_guest"));
    poly_tests.step.dependOn(&qs_build.step);

    // Java guest: fanopoly.FanoPoly compiled by javac into classes/.
    // The JVM itself is dlopened at run time (lib/server/libjvm.so).
    const jdk_path = detectJava(b);

    // Temporary smoke exe (same build env as poly tests) for crash isolation.
    const poly_smoke = b.addExecutable(.{
        .name = "poly-smoke",
        .root_source_file = b.path("poly/poly_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    poly_smoke.root_module.addImport("q128_128", q128_mod);
    poly_smoke.root_module.addIncludePath(b.path("poly/vendor"));
    poly_smoke.root_module.addCSourceFiles(.{
        .root = b.path("poly/vendor"),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "libbf.c", "cutils.c" },
        .flags = &.{ "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2024-01-13\"", "-O2", "-fno-sanitize=undefined" },
    });
    poly_smoke.root_module.addCSourceFile(.{
        .file = b.path("poly/c_guest/guest.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    poly_smoke.root_module.link_libc = true;
    if (detectPython(b)) |py| {
        poly_smoke.root_module.addSystemIncludePath(.{ .cwd_relative = py.include });
        poly_smoke.root_module.addLibraryPath(.{ .cwd_relative = py.libdir });
        poly_smoke.linkSystemLibrary(b.fmt("python{s}", .{py.ldversion}));
        poly_smoke.addRPath(.{ .cwd_relative = py.libdir });
    }
    poly_smoke.step.dependOn(&cargo.step);
    poly_smoke.addObjectFile(rs_lib);
    poly_smoke.step.dependOn(&dotnet.step);
    poly_smoke.step.dependOn(&qs_build.step);
    b.installArtifact(poly_smoke);

    // Java guest wiring: javac compiles fanopoly.FanoPoly into classes/,
    // and the JDK headers (jni.h) feed the JNI host code in poly.zig.
    // The JVM itself is dlopened at run time (lib/server/libjvm.so).
    if (jdk_path) |jdk| {
        const javac = b.addSystemCommand(&.{
            b.fmt("{s}/bin/javac", .{jdk}), "-d", "classes", "FanoPoly.java",
        });
        javac.setCwd(b.path("poly/java_guest"));
        poly_tests.step.dependOn(&javac.step);
        poly_tests.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{jdk}) });
        poly_tests.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/linux", .{jdk}) });
        poly_smoke.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{jdk}) });
        poly_smoke.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/linux", .{jdk}) });
        // HotSpot's libjvm.so dlopens libjava.so/libjli.so from the JDK
        // lib dirs at run time; expose them on the loader search path so
        // the embedded JVM can resolve its own dependencies.
        const run_smoke = b.addRunArtifact(poly_smoke);
        run_smoke.setEnvironmentVariable("LD_LIBRARY_PATH", b.fmt("{s}/lib/server:{s}/lib", .{ jdk, jdk }));
        poly_test_step.dependOn(&run_smoke.step);
    }

    // fano-poly CLI: the .fanop front end. Reuses the poly module and is
    // told the absolute path of this Zig tree (so generated projects can
    // import the poly runtime) through a build-options module.
    var root_buf: [4096]u8 = undefined;
    const fano_zig_root = std.fs.cwd().realpath(".", &root_buf) catch ".";
    const fanop_opts = b.addOptions();
    fanop_opts.addOption([]const u8, "fano_zig_root", fano_zig_root);
    const fanop_opts_mod = fanop_opts.createModule();

    const fano_poly = b.addExecutable(.{
        .name = "fano-poly",
        .root_source_file = b.path("poly/fanop_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    fano_poly.root_module.addImport("poly", poly_mod);
    fano_poly.root_module.addImport("build_options", fanop_opts_mod);
    b.installArtifact(fano_poly);

    // fano-poly parser/codegen unit tests.
    const fanop_tests = b.addTest(.{
        .root_source_file = b.path("poly/fanop.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_fanop_tests = b.addRunArtifact(fanop_tests);
    const fanop_test_step = b.step("test-fanop", "Run fano-poly parser/codegen tests");
    fanop_test_step.dependOn(&run_fanop_tests.step);

    // Physics layer tests (ported from E=mc²-i-E=mc⁻² toy-model)
    const physics_modules = [_][]const u8{
        "octonion.zig",
        "e8_roots.zig",
        "so10_decomposition.zig",
        "anti_octonion.zig",
        "dual_b_complex.zig",
        "jordan_algebra.zig",
        "so8_triality.zig",
        "electric_charges.zig",
        "pati_salam.zig",
        "scaling_analysis.zig",
        "checksum_6d.zig",
        "completion_10d.zig",
        "generative_chain.zig",
        "final_audit.zig",
    };
    var physics_test_steps: [physics_modules.len]*std.Build.Step = undefined;
    for (physics_modules, 0..) |mod, i| {
        const pt = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        const run_pt = b.addRunArtifact(pt);
        const step_name = b.fmt("test-physics-{d}", .{i});
        const step_desc = b.fmt("Run physics tests: {s}", .{mod});
        const ps = b.step(step_name, step_desc);
        ps.dependOn(&run_pt.step);
        physics_test_steps[i] = &run_pt.step;
    }
    const physics_test_step = b.step("test-physics", "Run all physics layer unit tests");
    for (physics_test_steps) |ps| {
        physics_test_step.dependOn(ps);
    }

    // Codon routing tests (ported from E=mc²-i-E=mc⁻² toy-model via fixed_compat.zig)
    const codon_tests = b.addTest(.{
        .root_source_file = b.path("codon.zig"),
        .target = target,
        .optimize = optimize,
    });
    codon_tests.root_module.addImport("q128_128", q128_mod);
    const run_codon_tests = b.addRunArtifact(codon_tests);
    const codon_test_step = b.step("test-codon", "Run codon routing unit tests");
    codon_test_step.dependOn(&run_codon_tests.step);

    // Aggregate test step
    const test_step = b.step("test", "Run all Zig unit tests");
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_ri_tests.step);
    test_step.dependOn(&run_holo_tests.step);
    test_step.dependOn(&run_fsh_tests.step);
    test_step.dependOn(&run_fano_tests.step);
    test_step.dependOn(&run_scale_tests.step);
    test_step.dependOn(&run_fanop_tests.step);
    test_step.dependOn(&run_triad_tests.step);
    test_step.dependOn(&run_phi_tests.step);
    test_step.dependOn(&run_smith_tests.step);
    test_step.dependOn(&run_rf_tests.step);
    test_step.dependOn(&run_poly_tests.step);
    for (physics_test_steps) |ps| {
        test_step.dependOn(ps);
    }
    test_step.dependOn(&run_codon_tests.step);
}

/// Locate CPython headers and shared library.
/// Explicit env overrides first (FANO_PYTHON_INCLUDE / FANO_PYTHON_LIB /
/// FANO_PYTHON_LDVERSION) so cross builds can point at a relocatable
/// runtime (e.g. the python-build-standalone tree shipped on the ISO);
/// otherwise fall back to python3 sysconfig detection.
fn detectPython(b: *std.Build) ?struct { include: []const u8, libdir: []const u8, ldversion: []const u8 } {
    const env_include = std.process.getEnvVarOwned(b.allocator, "FANO_PYTHON_INCLUDE") catch null;
    const env_libdir = std.process.getEnvVarOwned(b.allocator, "FANO_PYTHON_LIB") catch null;
    if (env_include != null and env_libdir != null) {
        const include = std.mem.trim(u8, env_include.?, " \r\n\t");
        const libdir = std.mem.trim(u8, env_libdir.?, " \r\n\t");
        if (include.len > 0 and libdir.len > 0) {
            const header = std.fs.path.join(b.allocator, &.{ include, "Python.h" }) catch return null;
            defer b.allocator.free(header);
            std.fs.accessAbsolute(header, .{}) catch return null;
            var ldversion: []const u8 = "3.11";
            if (std.process.getEnvVarOwned(b.allocator, "FANO_PYTHON_LDVERSION")) |v| {
                const trimmed = std.mem.trim(u8, v, " \r\n\t");
                if (trimmed.len > 0) ldversion = b.allocator.dupe(u8, trimmed) catch ldversion;
            } else |_| {}
            return .{
                .include = b.allocator.dupe(u8, include) catch return null,
                .libdir = b.allocator.dupe(u8, libdir) catch return null,
                .ldversion = ldversion,
            };
        }
    }
    const argv = [_][]const u8{
        "python3",                                                                                                                                                       "-c",
        "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY')); print(sysconfig.get_config_var('LIBDIR')); print(sysconfig.get_config_var('LDVERSION') or '')",
    };
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &argv,
    }) catch return null;
    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    const include = std.mem.trim(u8, lines.next() orelse return null, " \r\n\t");
    const libdir = std.mem.trim(u8, lines.next() orelse return null, " \r\n\t");
    const ldversion = std.mem.trim(u8, lines.next() orelse return null, " \r\n\t");
    if (include.len == 0 or libdir.len == 0 or ldversion.len == 0) return null;
    // Verify Python.h actually exists there.
    const header = std.fs.path.join(b.allocator, &.{ include, "Python.h" }) catch return null;
    defer b.allocator.free(header);
    std.fs.accessAbsolute(header, .{}) catch return null;
    return .{
        .include = b.allocator.dupe(u8, include) catch return null,
        .libdir = b.allocator.dupe(u8, libdir) catch return null,
        .ldversion = b.allocator.dupe(u8, ldversion) catch return null,
    };
}

/// Locate a JDK home: JAVA_HOME env, the repo's os/fano-langs JDK
/// checkout, then the system JVM directory.
fn detectJava(b: *std.Build) ?[]const u8 {
    if (std.process.getEnvVarOwned(b.allocator, "FANO_JDK_HOME")) |home| {
        if (home.len > 0) return home;
    } else |_| {}
    if (std.process.getEnvVarOwned(b.allocator, "JAVA_HOME")) |home| {
        if (home.len > 0) {
            const jh = std.fs.path.join(b.allocator, &.{ home, "include", "jni.h" }) catch return null;
            std.fs.accessAbsolute(jh, .{}) catch return null;
            return home;
        }
    } else |_| {}
    // Repo checkout: build.zig lives at <repo>/zig.
    const langs = std.fs.path.join(b.allocator, &.{ "..", "os", "fano-langs" }) catch return null;
    var dir = std.fs.cwd().openDir(langs, .{ .iterate = true }) catch return null;
    defer dir.close();
    const langs_abs = dir.realpathAlloc(b.allocator, ".") catch return null;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "jdk-")) continue;
        var jh_buf: [1024]u8 = undefined;
        const jh = std.fmt.bufPrint(&jh_buf, "{s}/include/jni.h", .{entry.name}) catch continue;
        dir.access(jh, .{}) catch continue;
        return std.fs.path.join(b.allocator, &.{ langs_abs, entry.name }) catch null;
    }
    return null;
}
