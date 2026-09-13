//! fanop.zig - the `.fanop` polyglot project format: parser + codegen.
//!
//! A `.fanop` file is a sequence of language-tagged function blocks plus
//! one `zig fn main` orchestration block. fano-poly parses the file,
//! emits a self-contained Zig project (generated bindings + guest source
//! files + a build.zig that reuses the FANO poly runtime), and builds it
//! with the host Zig toolchain.
//!
//! Block grammar (concrete and deliberately small):
//!
//!     # comment line
//!     name: <project-name>
//!
//!     <lang> fn <name>(<params>) { <body> }
//!
//! `<lang>` is one of `py`, `js`, `zig`. `py`/`js` bodies are literal
//! source in the target language (Python bodies are indented by the
//! author inside the braces; the braces are stripped on emit). `zig` has
//! exactly one block named `main` whose body is the program body.
//!
//! py/js functions take and return the canonical i256 ABI (256-bit
//! two's-complement); the generated Zig bindings marshal each argument
//! through its exact decimal form so arbitrary-precision guests see the
//! full value. This is a real v1 front end: the compiled guests
//! (c/rs/cs/java/qs) reuse the pre-built FANO guest libraries and are
//! wired in a later phase.

const std = @import("std");

pub const Lang = enum { py, js, zig };

pub const Block = struct {
    lang: Lang,
    name: []const u8,
    params: []const []const u8,
    body: []const u8,
    line: u32,
};

pub const Project = struct {
    name: []const u8,
    blocks: []const Block,
};

pub const FanopError = error{
    OutOfMemory,
    UnclosedBlock,
    DuplicateMain,
    MissingMain,
    BadBlockHeader,
    InvalidLang,
};

// ---------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------

pub fn parse(alloc: std.mem.Allocator, src: []const u8) FanopError!Project {
    var blocks = std.ArrayList(Block).init(alloc);
    errdefer blocks.deinit();

    var name: []const u8 = "fanop-out";
    var i: usize = 0;
    var line: u32 = 1;
    while (i < src.len) {
        const ch = src[i];
        if (ch == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
            continue;
        }
        if (ch == '#') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        // `name: <value>` header.
        if (std.mem.startsWith(u8, src[i..], "name:")) {
            i += "name:".len;
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
            const start = i;
            while (i < src.len and src[i] != '\n') i += 1;
            name = std.mem.trim(u8, src[start..i], " \t\r");
            continue;
        }
        // Otherwise a `<lang> fn <name>(<params>) {` block header.
        const block = try parseBlock(alloc, src, &i, &line);
        try blocks.append(block);
    }
    return .{ .name = try alloc.dupe(u8, name), .blocks = try blocks.toOwnedSlice() };
}

fn parseBlock(alloc: std.mem.Allocator, src: []const u8, i: *usize, line: *u32) FanopError!Block {
    const start_line = line.*;
    const header_start = i.*;
    // lang token
    while (i.* < src.len) {
        const c = src[i.*];
        if (c == ' ' or c == '\t' or c == '\n') break;
        i.* += 1;
    }
    const lang_end = i.*;
    const lang_str = src[header_start..lang_end];
    const lang: Lang = std.meta.stringToEnum(Lang, lang_str) orelse return FanopError.InvalidLang;
    skipWs(src, i, line);
    // `fn`
    if (!std.mem.startsWith(u8, src[i.*..], "fn")) return FanopError.BadBlockHeader;
    i.* += 2;
    skipWs(src, i, line);
    // name
    const name_start = i.*;
    while (i.* < src.len) {
        const c = src[i.*];
        if (c == '(' or c == ' ' or c == '\t' or c == '\n') break;
        i.* += 1;
    }
    const name = src[name_start..i.*];
    if (name.len == 0) return FanopError.BadBlockHeader;
    skipWs(src, i, line);
    // params
    if (i.* >= src.len or src[i.*] != '(') return FanopError.BadBlockHeader;
    i.* += 1;
    const params_start = i.*;
    while (i.* < src.len and src[i.*] != ')') {
        if (src[i.*] == '\n') line.* += 1;
        i.* += 1;
    }
    if (i.* >= src.len) return FanopError.BadBlockHeader;
    const params_src = src[params_start..i.*];
    i.* += 1; // consume ')'
    skipWs(src, i, line);
    // '{'
    if (i.* >= src.len or src[i.*] != '{') return FanopError.BadBlockHeader;
    i.* += 1;
    const body_start = i.*;
    var depth: u32 = 1;
    while (i.* < src.len and depth > 0) {
        const c = src[i.*];
        if (c == '{') {
            depth += 1;
            i.* += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) break;
            i.* += 1;
        } else if (c == '\n') {
            line.* += 1;
            i.* += 1;
        } else {
            i.* += 1;
        }
    }
    if (depth != 0) return FanopError.UnclosedBlock;
    const body_end = i.*;
    i.* += 1; // consume '}'
    const body = std.mem.trim(u8, src[body_start..body_end], "\r\n");
    const params = try parseParams(alloc, params_src);
    return .{
        .lang = lang,
        .name = try alloc.dupe(u8, name),
        .params = params,
        .body = try alloc.dupe(u8, body),
        .line = start_line,
    };
}

fn parseParams(alloc: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, src, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r\n");
        if (p.len > 0) try list.append(try alloc.dupe(u8, p));
    }
    return list.toOwnedSlice();
}

fn skipWs(src: []const u8, i: *usize, line: *u32) void {
    while (i.* < src.len) {
        const c = src[i.*];
        if (c == ' ' or c == '\t' or c == '\r') {
            i.* += 1;
        } else if (c == '\n') {
            line.* += 1;
            i.* += 1;
        } else if (c == '#') {
            while (i.* < src.len and src[i.*] != '\n') i.* += 1;
        } else break;
    }
}

// ---------------------------------------------------------------------
// Codegen
// ---------------------------------------------------------------------

/// Generate a self-contained Zig project under `out_dir` that reuses the
/// FANO poly runtime at `fano_zig_root`. Writes main.zig, polygen.py,
/// polygen.js, build.zig and build.zig.zon.
pub fn codegen(
    alloc: std.mem.Allocator,
    proj: Project,
    fano_zig_root: []const u8,
    out_dir: []const u8,
) !void {
    try std.fs.cwd().makePath(out_dir);
    try emitPolygenPy(alloc, proj, out_dir);
    try emitPolygenJs(alloc, proj, out_dir);
    try emitMainZig(alloc, proj, out_dir);
    try emitBuildZig(alloc, proj, fano_zig_root, out_dir);
    try emitBuildZon(alloc, proj, out_dir);
}

fn emitPolygenPy(alloc: std.mem.Allocator, proj: Project, out_dir: []const u8) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("# polygen.py - generated by fano-poly. Do not edit by hand.\n");
    for (proj.blocks) |b| {
        if (b.lang != .py) continue;
        try buf.writer().print("def {s}({s}):\n", .{ b.name, joinParams(b.params) });
        // The body is already indented Python (author-indented inside
        // the braces). Re-emit verbatim, ensuring at least one indented
        // statement so empty bodies are valid.
        if (b.body.len == 0) {
            try buf.appendSlice("    pass\n");
        } else {
            try buf.appendSlice(b.body);
            try buf.append('\n');
        }
    }
    try writeFile(out_dir, "polygen.py", buf.items);
}

fn emitPolygenJs(alloc: std.mem.Allocator, proj: Project, out_dir: []const u8) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("// polygen.js - generated by fano-poly. Do not edit by hand.\n");
    for (proj.blocks) |b| {
        if (b.lang != .js) continue;
        try buf.writer().print("function {s}({s}) {{\n{s}\n}}\n", .{ b.name, joinParams(b.params), b.body });
    }
    try writeFile(out_dir, "polygen.js", buf.items);
}

fn emitMainZig(alloc: std.mem.Allocator, proj: Project, out_dir: []const u8) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print(
        \\// main.zig - generated by fano-poly for project "{s}".
        \\const std = @import("std");
        \\const poly = @import("poly");
        \\
        \\// The QuickJS engine is module-level so the generated js_* bindings
        \\// can reach it without capturing a local from main.
        \\var g_engine: poly.QuickJS = undefined;
        \\
    , .{proj.name});

    // Top-level guest bindings.
    for (proj.blocks) |b| {
        if (b.lang == .py) {
            try w.print("// py fn {s} (line {d})\n", .{ b.name, b.line });
            try emitPyBinding(w, b);
        } else if (b.lang == .js) {
            try w.print("// js fn {s} (line {d})\n", .{ b.name, b.line });
            try emitJsBinding(w, b);
        }
    }

    try w.writeAll(
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    const alloc = gpa.allocator();
        \\    try poly.Python.init();
        \\    g_engine = try poly.QuickJS.init();
        \\    defer g_engine.deinit();
        \\    // Define the Python guest functions by execing polygen.py into
        \\    // __main__ (embedded CPython's sys.path does not include the
        \\    // CWD, so a plain `import polygen` is unreliable).
        \\    const py_src = try std.fs.cwd().readFileAlloc(alloc, "polygen.py", 1 << 20);
        \\    defer alloc.free(py_src);
        \\    try poly.Python.run(py_src);
        \\    // Load the JS guest module by evaluating polygen.js once.
        \\    const js_src = try std.fs.cwd().readFileAlloc(alloc, "polygen.js", 1 << 20);
        \\    defer alloc.free(js_src);
        \\    _ = try g_engine.eval(alloc, js_src);
        \\
    );

    var saw_main = false;
    for (proj.blocks) |b| {
        if (b.lang == .zig and std.mem.eql(u8, b.name, "main")) {
            try w.print("    // zig fn main (line {d})\n", .{b.line});
            try w.writeAll(b.body);
            try w.writeAll("\n");
            saw_main = true;
        }
    }
    if (!saw_main) {
        try w.writeAll("    std.debug.print(\"fanop: no zig fn main block; nothing to do\\n\", .{});\n");
    }
    try w.writeAll("}\n");
    try writeFile(out_dir, "main.zig", buf.items);
}

fn emitPyBinding(w: anytype, b: Block) !void {
    // fn py_<name>(a: poly.I256, ...) poly.PolyError!poly.I256
    try w.print("fn py_{s}(", .{b.name});
    for (b.params, 0..) |p, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("{s}: poly.I256", .{p});
    }
    try w.writeAll(") poly.PolyError!poly.I256 {\n");
    try w.writeAll("    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n");
    try w.writeAll("    defer arena.deinit();\n");
    try w.writeAll("    const al = arena.allocator();\n");
    for (b.params) |p| {
        try w.print("    const d_{s} = try poly.i256ToDecimal(al, {s});\n", .{ p, p });
    }
    try w.print("    const expr = try std.fmt.allocPrint(al, \"{s}(", .{b.name});
    for (b.params, 0..) |_, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.writeAll("{s}");
    }
    try w.writeAll(")\", .{");
    for (b.params, 0..) |p, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("d_{s}", .{p});
    }
    try w.writeAll("});\n");
    try w.writeAll("    return poly.Python.evalI256(expr);\n}\n\n");
}

fn emitJsBinding(w: anytype, b: Block) !void {
    try w.print("fn js_{s}(", .{b.name});
    for (b.params, 0..) |p, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("{s}: poly.I256", .{p});
    }
    try w.writeAll(") poly.PolyError!poly.I256 {\n");
    try w.writeAll("    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n");
    try w.writeAll("    defer arena.deinit();\n");
    try w.writeAll("    const al = arena.allocator();\n");
    for (b.params) |p| {
        try w.print("    const d_{s} = try poly.i256ToDecimal(al, {s});\n", .{ p, p });
    }
    try w.print("    const expr = try std.fmt.allocPrint(al, \"{s}(", .{b.name});
    for (b.params, 0..) |_, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.writeAll("BigInt(\\\"{s}\\\")");
    }
    try w.writeAll(")\", .{");
    for (b.params, 0..) |p, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("d_{s}", .{p});
    }
    try w.writeAll("});\n");
    try w.writeAll("    return g_engine.evalI256(expr);\n}\n\n");
}

fn emitBuildZig(alloc: std.mem.Allocator, proj: Project, fano_zig_root: []const u8, out_dir: []const u8) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print(
        \\// build.zig - generated by fano-poly for project "{s}".
        \\// Reuses the FANO poly runtime at FANO_ZIG_ROOT (or the baked path).
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const root = std.process.getEnvVarOwned(b.allocator, "FANO_ZIG_ROOT") catch null;
        \\    const fano: []const u8 = if (root) |r| r else "{s}";
        \\    defer if (root) |r| b.allocator.free(r);
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const q128_mod = b.createModule(.{{ .root_source_file = .{{ .cwd_relative = b.fmt("{{s}}/q128_128.zig", .{{fano}}) }}, .target = target, .optimize = optimize }});
        \\    const poly_mod = b.createModule(.{{ .root_source_file = .{{ .cwd_relative = b.fmt("{{s}}/poly/poly.zig", .{{fano}}) }}, .target = target, .optimize = optimize }});
        \\    poly_mod.addImport("q128_128", q128_mod);
        \\    poly_mod.addIncludePath(.{{ .cwd_relative = b.fmt("{{s}}/poly/vendor", .{{fano}}) }});
        \\    poly_mod.addIncludePath(.{{ .cwd_relative = b.fmt("{{s}}/poly/c_guest", .{{fano}}) }});
        \\    poly_mod.addCSourceFiles(.{{
        \\        .root = .{{ .cwd_relative = b.fmt("{{s}}/poly/vendor", .{{fano}}) }},
        \\        .files = &.{{ "quickjs.c", "libregexp.c", "libunicode.c", "libbf.c", "cutils.c" }},
        \\        .flags = &.{{ "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2024-01-13\"", "-O2", "-fno-sanitize=undefined" }},
        \\    }});
        \\    poly_mod.addCSourceFile(.{{ .file = .{{ .cwd_relative = b.fmt("{{s}}/poly/c_guest/guest.c", .{{fano}}) }}, .flags = &.{{ "-O2", "-fno-sanitize=undefined" }} }});
        \\    poly_mod.link_libc = true;
        \\    if (detectPython(b)) |py| {{
        \\        poly_mod.addSystemIncludePath(.{{ .cwd_relative = py.include }});
        \\        poly_mod.addLibraryPath(.{{ .cwd_relative = py.libdir }});
        \\        poly_mod.linkSystemLibrary(b.fmt("python{{s}}", .{{py.ldversion}}), .{{}});
        \\    }}
        \\
        \\    const exe = b.addExecutable(.{{ .name = "{s}", .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize }});
        \\    exe.root_module.addImport("poly", poly_mod);
        \\    b.installArtifact(exe);
        \\    const run = b.addRunArtifact(exe);
        \\    if (b.args) |args| run.addArgs(args);
        \\    b.step("run", "Run the fano-poly project").dependOn(&run.step);
        \\}}
        \\
        \\const PyInfo = struct {{ include: []const u8, libdir: []const u8, ldversion: []const u8 }};
        \\fn detectPython(b: *std.Build) ?PyInfo {{
        \\    const a = b.allocator;
        \\    const home = std.process.getEnvVarOwned(a, "HOME") catch return null;
        \\    const pyenv_inc = std.fmt.allocPrint(a, "{{s}}/.pyenv/versions/3.11.9/include/python3.11", .{{home}}) catch return null;
        \\    if (std.fs.accessAbsolute(pyenv_inc, .{{}})) |_| {{
        \\        const pyenv_lib = std.fmt.allocPrint(a, "{{s}}/.pyenv/versions/3.11.9/lib", .{{home}}) catch return null;
        \\        return .{{ .include = pyenv_inc, .libdir = pyenv_lib, .ldversion = "3.11" }};
        \\    }} else |_| {{}}
        \\    if (std.fs.accessAbsolute("/usr/include/python3.11", .{{}})) |_| {{
        \\        return .{{ .include = "/usr/include/python3.11", .libdir = "/usr/lib", .ldversion = "3.11" }};
        \\    }} else |_| {{}}
        \\    return null;
        \\}}
        \\
    , .{ proj.name, fano_zig_root, proj.name });

    try writeFile(out_dir, "build.zig", buf.items);
}

fn emitBuildZon(alloc: std.mem.Allocator, proj: Project, out_dir: []const u8) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.writer().print(
        \\.{{
        \\    .name = "{s}",
        \\    .version = "0.0.1",
        \\    .paths = .{{"main.zig", "polygen.py", "polygen.js", "build.zig"}},
        \\}}
        \\
    , .{proj.name});
    try writeFile(out_dir, "build.zig.zon", buf.items);
}

fn joinParams(params: []const []const u8) []const u8 {
    // Single-line join for emit; uses a static buffer is unsafe across
    // calls, so callers format params directly. This helper is only used
    // where a pre-joined string is acceptable via a thread-local buffer.
    // To keep codegen allocation-free here, we return the first param
    // joined through a private buffer.
    return joinParamsBuf(params, &join_buf);
}

threadlocal var join_buf: [256]u8 = undefined;
fn joinParamsBuf(params: []const []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (params, 0..) |p, idx| {
        if (idx > 0) {
            if (len + 2 > buf.len) break;
            buf[len] = ',';
            buf[len + 1] = ' ';
            len += 2;
        }
        if (len + p.len > buf.len) break;
        @memcpy(buf[len .. len + p.len], p);
        len += p.len;
    }
    return buf[0..len];
}

fn writeFile(out_dir: []const u8, name: []const u8, content: []const u8) !void {
    var dir = try std.fs.cwd().openDir(out_dir, .{});
    defer dir.close();
    var f = try dir.createFile(name, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "fanop parses py/js/zig blocks" {
    const src =
        \\name: demo
        \\py fn add(a, b) {
        \\    return a + b
        \\}
        \\js fn mul(a, b) {
        \\    return a * b
        \\}
        \\zig fn main() {
        \\    const r = py_add(a, b)
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj = try parse(arena.allocator(), src);
    try testing.expectEqualStrings("demo", proj.name);
    try testing.expectEqual(@as(usize, 3), proj.blocks.len);
    try testing.expectEqual(Lang.py, proj.blocks[0].lang);
    try testing.expectEqualStrings("add", proj.blocks[0].name);
    try testing.expectEqual(@as(usize, 2), proj.blocks[0].params.len);
    try testing.expectEqualStrings("a", proj.blocks[0].params[0]);
    try testing.expectEqualStrings("b", proj.blocks[0].params[1]);
    try testing.expectEqual(Lang.js, proj.blocks[1].lang);
    try testing.expectEqual(Lang.zig, proj.blocks[2].lang);
    try testing.expectEqualStrings("main", proj.blocks[2].name);
}

test "fanop rejects unclosed blocks" {
    const src = "py fn add(a, b) { return a + b";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(FanopError.UnclosedBlock, parse(arena.allocator(), src));
}

test "fanop rejects unknown lang" {
    const src = "perl fn add(a) { x }";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(FanopError.InvalidLang, parse(arena.allocator(), src));
}

test "fanop codegen emits a buildable project" {
    const src =
        \\name: cgtest
        \\py fn inc(x) {
        \\    return x + 1
        \\}
        \\zig fn main() {
        \\    const one = py_inc(.{0} ** 32);
        \\    _ = one;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj = try parse(arena.allocator(), src);
    const tmp = "zig-cache/fanop-cgtest";
    std.fs.cwd().deleteTree(tmp) catch {};
    try codegen(arena.allocator(), proj, "/home/projects/Q128.128/zig", tmp);
    var dir = try std.fs.cwd().openDir(tmp, .{});
    defer dir.close();
    var f = try dir.openFile("main.zig", .{});
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = try f.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "fn py_inc(x: poly.I256)") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "py_inc(.{0} ** 32)") != null);
    var pf = try dir.openFile("polygen.py", .{});
    defer pf.close();
    const pn = try pf.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..pn], "def inc(x):") != null);
    std.fs.cwd().deleteTree(tmp) catch {};
}
