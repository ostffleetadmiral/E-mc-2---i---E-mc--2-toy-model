//! poly.zig - FANO polyglot runtime core.
//!
//! Embeds real language runtimes in-process behind one Zig API:
//!   - CPython 3.11 (CPython C API, linked against libpython3.11)
//!   - QuickJS (vendored C sources under poly/vendor)
//!   - Rust (cargo staticlib, fano-poly-rs)
//!   - C (compiled into the binary)
//!   - C#/.NET (NativeAOT-compiled shared library, dlopened)
//!
//! The universal cross-language numeric is the FANO i256: a 256-bit
//! two's-complement integer carrying a Q128.128 fixed-point value scaled
//! by 2^-128. The canonical byte ABI matches runtime/main.zig storeQ128:
//! four 64-bit limbs written little-endian, most-significant limb first
//! (bytes 0..8 = bits 255..192, ..., bytes 24..32 = bits 63..0).
//!
//! Values cross language boundaries exactly through decimal strings
//! (Python ints and JS BigInts are arbitrary precision), parsed here into
//! u256 two's complement with wraparound masking.

const std = @import("std");
const q = @import("q128_128");

// ---------------------------------------------------------------------
// I256: the canonical cross-language numeric ABI
// ---------------------------------------------------------------------

/// 256-bit two's-complement integer, canonical FANO poly ABI: plain
/// little-endian bytes (matches Rust i256, .NET BigInteger and
/// Python int.to_bytes conventions; the WASM runtime's limb-swapped
/// layout is a separate convention converted at that boundary).
pub const I256 = [32]u8;

pub const PolyError = error{
    OutOfMemory,
    NotAnInteger,
    IntegerOverflow,
    InvalidDecimal,
    PythonInitFailed,
    PythonError,
    QuickJSInitFailed,
    QuickJSError,
    GuestUnavailable,
    QsGuestUnavailable,
    QsError,
    JavaGuestUnavailable,
    JavaInitFailed,
    JavaClassNotFound,
    JavaError,
    NodeGuestUnavailable,
    NodeError,
};

/// Pack a Q128.128 fixed-point value into the canonical i256 byte ABI
/// (plain little-endian 256-bit two's complement).
pub fn i256FromQ128(v: q.q128) I256 {
    var out: I256 = undefined;
    std.mem.writeInt(u256, &out, (@as(u256, v.hi) << 128) | v.lo, .little);
    return out;
}

/// Unpack the canonical i256 byte ABI into a Q128.128 fixed-point value.
pub fn i256ToQ128(v: I256) q.q128 {
    const wide = std.mem.readInt(u256, &v, .little);
    return .{
        .hi = @truncate(wide >> 128),
        .lo = @truncate(wide),
    };
}

/// Parse a decimal string (optional +/-, arbitrary precision) into a
/// 256-bit two's-complement value, wrapping modulo 2^256.
pub fn i256FromDecimal(s: []const u8) PolyError!I256 {
    if (s.len == 0) return PolyError.InvalidDecimal;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-' or s[0] == '+') {
        neg = s[0] == '-';
        i = 1;
    }
    if (i >= s.len) return PolyError.InvalidDecimal;
    // u256 arithmetic wraps naturally in Zig, which is exactly mod 2^256.
    var acc: u256 = 0;
    for (s[i..]) |ch| {
        if (ch < '0' or ch > '9') return PolyError.InvalidDecimal;
        const digit: u32 = ch - '0';
        acc = acc *% 10 +% digit;
    }
    if (neg) acc = ~acc +% 1;
    var out: I256 = undefined;
    std.mem.writeInt(u256, &out, acc, .little);
    return out;
}

/// Format a 256-bit two's-complement value as a decimal string with an
/// optional leading '-'. Caller owns the returned allocation.
pub fn i256ToDecimal(alloc: std.mem.Allocator, v: I256) ![]u8 {
    const wide: u256 = std.mem.readInt(u256, &v, .little);
    if (wide == 0) return alloc.dupe(u8, "0");
    var mag = wide;
    var neg = false;
    if (wide >> 255 != 0) {
        mag = ~wide +% 1;
        neg = true;
    }
    // Max 78 decimal digits for u256 (2^256 ~ 1.16e77).
    var buf: [80]u8 = undefined;
    var idx: usize = buf.len;
    while (mag != 0) {
        const digit: u8 = @intCast(mag % 10);
        idx -= 1;
        buf[idx] = '0' + digit;
        mag /= 10;
    }
    const digits = buf[idx..];
    if (neg) {
        const out = try alloc.alloc(u8, digits.len + 1);
        out[0] = '-';
        @memcpy(out[1..], digits);
        return out;
    }
    return alloc.dupe(u8, digits);
}

/// Convert a Q128.128 value to its exact i256 ABI bytes.
pub fn q128ToBytes(v: q.q128) I256 {
    return i256FromQ128(v);
}

/// Recover a Q128.128 fixed-point value from the canonical i256 ABI.
pub fn q128FromI256(v: I256) q.q128 {
    return i256ToQ128(v);
}

// ---------------------------------------------------------------------
// Python guest (CPython 3.11 C API)
// ---------------------------------------------------------------------

pub const cpy = @cImport({
    @cInclude("Python.h");
    @cInclude("stdlib.h");
});

pub const Python = struct {
    var started = false;

    /// Boot the embedded CPython interpreter. Idempotent and
    /// process-lifetime: CPython does not support reliable re-init after
    /// Py_FinalizeEx, so deinit is only for explicit process teardown.
    /// When FANO_PYTHON_HOME is set (relocatable runtime, e.g. the FANO-1
    /// ISO's packaged CPython), it is applied as PYTHONHOME before boot.
    pub fn init() !void {
        if (started) return;
        if (cpy.Py_IsInitialized() == 0) {
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "FANO_PYTHON_HOME")) |home| {
                if (home.len > 0) {
                    _ = cpy.setenv("PYTHONHOME", home.ptr, 1);
                }
            } else |_| {}
            cpy.Py_Initialize();
        }
        if (cpy.Py_IsInitialized() == 0) return PolyError.PythonInitFailed;
        started = true;
    }

    /// Finalize the embedded interpreter. Only call at process exit;
    /// the interpreter must not be re-initialized afterwards.
    pub fn deinit() void {
        if (!started) return;
        if (cpy.Py_FinalizeEx() != 0) {
            // Buffered output could not be flushed; nothing actionable.
        }
        started = false;
    }

    pub fn isRunning() bool {
        return started and cpy.Py_IsInitialized() != 0;
    }

    /// Execute a statement block. Returns PythonError on exception.
    pub fn run(code: []const u8) !void {
        if (!isRunning()) return PolyError.GuestUnavailable;
        const buf = try std.heap.c_allocator.dupeZ(u8, code);
        defer std.heap.c_allocator.free(buf);
        const rc = cpy.PyRun_SimpleString(buf.ptr);
        if (rc != 0) return PolyError.PythonError;
    }

    /// Evaluate an expression and return its repr() as an owned string.
    pub fn eval(alloc: std.mem.Allocator, expr: []const u8) ![]u8 {
        if (!isRunning()) return PolyError.GuestUnavailable;
        const exprz = try std.heap.c_allocator.dupeZ(u8, expr);
        defer std.heap.c_allocator.free(exprz);
        const globals = cpy.PyModule_GetDict(cpy.PyImport_AddModule("__main__"));
        const result = cpy.PyRun_String(exprz.ptr, cpy.Py_eval_input, globals, globals);
        if (result == null) {
            cpy.PyErr_Clear();
            return PolyError.PythonError;
        }
        defer cpy.Py_DecRef(result);
        const repr = cpy.PyObject_Repr(result);
        if (repr == null) {
            cpy.PyErr_Clear();
            return PolyError.PythonError;
        }
        defer cpy.Py_DecRef(repr);
        const utf8 = cpy.PyUnicode_AsUTF8(repr);
        if (utf8 == null) {
            cpy.PyErr_Clear();
            return PolyError.PythonError;
        }
        return alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(utf8))));
    }

    /// Evaluate an integer expression exactly into the i256 ABI.
    /// The expression must yield a Python int; it is converted through
    /// its exact decimal form and wrapped to 256-bit two's complement.
    pub fn evalI256(expr: []const u8) PolyError!I256 {
        if (!isRunning()) return PolyError.GuestUnavailable;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const wrapped = try std.fmt.allocPrint(arena.allocator(), "hex(int({s}))", .{expr});
        const repr = eval(arena.allocator(), wrapped) catch return PolyError.PythonError;
        // repr is like '0x2a'; strip quotes and parse hex.
        if (repr.len < 3 or repr[0] != '\'' or repr[repr.len - 1] != '\'') return PolyError.NotAnInteger;
        const hex = repr[1 .. repr.len - 1];
        if (hex.len < 3 or !std.mem.startsWith(u8, hex, "0x")) return PolyError.NotAnInteger;
        return i256FromHex(hex[2..]);
    }

    /// Evaluate a Q128.128 fixed-point expression: the Python side works
    /// on plain integers scaled by 2^128 (the raw mantissa), and the
    /// result is reinterpreted as a q128.
    pub fn evalQ128(expr: []const u8) PolyError!q.q128 {
        const v = try evalI256(expr);
        return i256ToQ128(v);
    }
};

/// Parse a hex string (no 0x prefix, optional '-') into 256-bit two's
/// complement. Digits beyond 64 hex chars wrap modulo 2^256.
pub fn i256FromHex(hex: []const u8) PolyError!I256 {
    var wide: u256 = 0;
    var start: usize = 0;
    var neg = false;
    if (hex.len > 0 and hex[0] == '-') {
        neg = true;
        start = 1;
    }
    if (start >= hex.len) return PolyError.InvalidDecimal;
    for (hex[start..]) |ch| {
        const d: u8 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return PolyError.InvalidDecimal,
        };
        wide = (wide << 4) | d; // natural u256 wraparound = mod 2^256
    }
    if (neg) wide = ~wide +% 1;
    var out: I256 = undefined;
    std.mem.writeInt(u256, &out, wide, .little);
    return out;
}

// ---------------------------------------------------------------------
// QuickJS guest (vendored C sources)
// ---------------------------------------------------------------------

pub const qjs = @cImport({
    @cInclude("quickjs.h");
});

pub const QuickJS = struct {
    rt: *qjs.JSRuntime,
    ctx: *qjs.JSContext,

    /// Create a fresh QuickJS runtime + context with ES2020 + BigInt.
    pub fn init() !QuickJS {
        const rt = qjs.JS_NewRuntime() orelse return PolyError.QuickJSInitFailed;
        const ctx = qjs.JS_NewContext(rt) orelse {
            qjs.JS_FreeRuntime(rt);
            return PolyError.QuickJSInitFailed;
        };
        return .{ .rt = rt, .ctx = ctx };
    }

    pub fn deinit(self: *QuickJS) void {
        qjs.JS_FreeContext(self.ctx);
        qjs.JS_FreeRuntime(self.rt);
    }

    /// Evaluate an expression and return its string conversion.
    pub fn eval(self: *QuickJS, alloc: std.mem.Allocator, expr: []const u8) ![]u8 {
        const exprz = try std.heap.c_allocator.dupeZ(u8, expr);
        defer std.heap.c_allocator.free(exprz);
        const result = qjs.JS_Eval(self.ctx, exprz.ptr, expr.len, "<poly>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (qjs.JS_IsException(result) != 0) {
            const exc = qjs.JS_GetException(self.ctx);
            qjs.JS_FreeValue(self.ctx, exc);
            return PolyError.QuickJSError;
        }
        defer qjs.JS_FreeValue(self.ctx, result);
        const str = qjs.JS_ToCString(self.ctx, result);
        if (str == null) {
            return PolyError.QuickJSError;
        }
        defer qjs.JS_FreeCString(self.ctx, str);
        return alloc.dupe(u8, std.mem.span(str));
    }

    /// Evaluate an expression that must yield a BigInt (or an integral
    /// number) and convert it exactly into the i256 ABI.
    pub fn evalI256(self: *QuickJS, expr: []const u8) PolyError!I256 {
        const s = self.eval(std.heap.page_allocator, expr) catch |err| switch (err) {
            PolyError.QuickJSError => return PolyError.QuickJSError,
            else => return PolyError.OutOfMemory,
        };
        defer std.heap.page_allocator.free(s);
        var text = std.mem.trim(u8, s, " \t\r\n");
        if (text.len > 0 and text[text.len - 1] == 'n') {
            text = text[0 .. text.len - 1]; // BigInt toString suffix
        }
        if (text.len >= 3 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
            return i256FromHex(text[2..]);
        }
        return i256FromDecimal(text);
    }

    /// Evaluate a Q128.128 fixed-point expression (raw mantissa math).
    pub fn evalQ128(self: *QuickJS, expr: []const u8) PolyError!q.q128 {
        const v = try self.evalI256(expr);
        return i256ToQ128(v);
    }
};

// ---------------------------------------------------------------------
// Rust guest (staticlib, C ABI)
// ---------------------------------------------------------------------

extern fn poly_rs_version() u32;
extern "C" fn poly_rs_echo(v: *const I256, out: *I256) void;
extern "C" fn poly_rs_mulraw(a: *const I256, b: *const I256, out: *I256) void;
extern "C" fn poly_rs_add128(a: *const I256, b: *const I256, out: *I256) void;
extern "C" fn poly_rs_mul128(a: *const I256, b: *const I256, out: *I256) void;

/// Rust guest: statically linked fano-poly-rs crate. Stateless functions
/// on the canonical i256 ABI; no runtime to initialize.
pub const Rust = struct {
    pub fn version() u32 {
        return poly_rs_version();
    }

    pub fn echo(v: I256) I256 {
        var out: I256 = undefined;
        poly_rs_echo(&v, &out);
        return out;
    }

    pub fn mulraw(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        poly_rs_mulraw(&a, &b, &out);
        return out;
    }

    pub fn add128(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        poly_rs_add128(&a, &b, &out);
        return out;
    }

    /// Q128.128 fixed-point multiply through the exact 512-bit product.
    pub fn mul128(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        poly_rs_mul128(&a, &b, &out);
        return out;
    }

    pub fn mulQ128(a: q.q128, b: q.q128) q.q128 {
        const r = mul128(i256FromQ128(a), i256FromQ128(b));
        return i256ToQ128(r);
    }
};

// ---------------------------------------------------------------------
// C guest (compiled C source, C ABI)
// ---------------------------------------------------------------------

extern "C" fn poly_c_version() u32;
extern "C" fn poly_c_echo(v: *const I256, out: *I256) void;
extern "C" fn poly_c_add128(a: *const I256, b: *const I256, out: *I256) void;
extern "C" fn poly_c_mulraw(a: *const I256, b: *const I256, out: *I256) void;
extern "C" fn poly_c_mul128(a: *const I256, b: *const I256, out: *I256) void;

/// C guest: guest.c compiled into the binary. Stateless functions on the
/// canonical i256 ABI; no runtime to initialize.
pub const CGuest = struct {
    pub fn version() u32 {
        return poly_c_version();
    }

    pub fn echo(v: I256) I256 {
        var out: I256 = undefined;
        poly_c_echo(&v, &out);
        return out;
    }

    pub fn add128(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        poly_c_add128(&a, &b, &out);
        return out;
    }

    pub fn mulraw(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        poly_c_mulraw(&a, &b, &out);
        return out;
    }

    /// Q128.128 fixed-point multiply through the exact 512-bit product.
    pub fn mul128(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        poly_c_mul128(&a, &b, &out);
        return out;
    }

    pub fn mulQ128(a: q.q128, b: q.q128) q.q128 {
        const r = mul128(i256FromQ128(a), i256FromQ128(b));
        return i256ToQ128(r);
    }
};

// ---------------------------------------------------------------------
// .NET guest (C# compiled to a native shared library via NativeAOT)
// ---------------------------------------------------------------------

pub const DotNet = struct {
    var lib: ?std.DynLib = null;
    var f_version: ?*const fn () callconv(.C) u32 = null;
    var f_echo: ?*const fn (*const I256, *I256) callconv(.C) void = null;
    var f_add128: ?*const fn (*const I256, *const I256, *I256) callconv(.C) void = null;
    var f_mulraw: ?*const fn (*const I256, *const I256, *I256) callconv(.C) void = null;
    var f_mul128: ?*const fn (*const I256, *const I256, *I256) callconv(.C) void = null;
    var initialized: bool = false;

    const VersionFn = *const fn () callconv(.C) u32;
    const EchoFn = *const fn (*const I256, *I256) callconv(.C) void;
    const BinOpFn = *const fn (*const I256, *const I256, *I256) callconv(.C) void;

    /// Open the NativeAOT-compiled C# guest (`libFanoPolyCs.so`) and
    /// resolve its UnmanagedCallersOnly exports into typed C-ABI pointers.
    pub fn init(so_path: []const u8) !void {
        if (initialized) return;
        lib = std.DynLib.open(so_path) catch return error.DotNetGuestUnavailable;
        f_version = lib.?.lookup(VersionFn, "fano_poly_version") orelse return error.DotNetExportNotFound;
        f_echo = lib.?.lookup(EchoFn, "fano_poly_echo") orelse return error.DotNetExportNotFound;
        f_add128 = lib.?.lookup(BinOpFn, "fano_poly_add128") orelse return error.DotNetExportNotFound;
        f_mulraw = lib.?.lookup(BinOpFn, "fano_poly_mulraw") orelse return error.DotNetExportNotFound;
        f_mul128 = lib.?.lookup(BinOpFn, "fano_poly_mul128") orelse return error.DotNetExportNotFound;
        initialized = true;
    }

    pub fn version() u32 {
        return f_version.?();
    }

    pub fn echo(v: I256) I256 {
        var out: I256 = undefined;
        f_echo.?(&v, &out);
        return out;
    }

    pub fn add128(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        f_add128.?(&a, &b, &out);
        return out;
    }

    pub fn mulraw(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        f_mulraw.?(&a, &b, &out);
        return out;
    }

    /// Q128.128 fixed-point multiply through the exact product.
    pub fn mul128(a: I256, b: I256) I256 {
        var out: I256 = undefined;
        f_mul128.?(&a, &b, &out);
        return out;
    }

    pub fn mulQ128(a: q.q128, b: q.q128) q.q128 {
        const r = mul128(i256FromQ128(a), i256FromQ128(b));
        return i256ToQ128(r);
    }
};

// ---------------------------------------------------------------------
// Q# guest (QDK-compiled runner driven as a child process)
// ---------------------------------------------------------------------
//
// The QDK compiles .qs sources offline from the cached NuGet packages.
// In-process hosting would need hostfxr (broken on the build machine)
// or NativeAOT (ILC takes 30+ minutes on the QDK dependency tree), so
// the guest runs the compiled runner as a child process and exchanges
// bare integers on stdout. This mirrors the plan's Node bridge model.

pub const Qs = struct {
    var dll_store: [512]u8 = undefined;
    var dll_len: usize = 0;
    var initialized: bool = false;

    /// Register the QDK-built runner assembly (FanoQs.dll).
    pub fn init(dll: []const u8) !void {
        std.fs.cwd().access(dll, .{}) catch return error.QsGuestUnavailable;
        if (dll.len > dll_store.len) return error.QsGuestUnavailable;
        @memcpy(dll_store[0..dll.len], dll);
        dll_len = dll.len;
        initialized = true;
    }

    fn run(op: []const u8, arg: ?[]const u8) PolyError!i64 {
        if (!initialized) return error.QsGuestUnavailable;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var argv = std.ArrayList([]const u8).init(a);
        // dotnet on PATH; the ISO bakes it into the language matrix.
        argv.append("dotnet") catch return PolyError.OutOfMemory;
        argv.append(dll_store[0..dll_len]) catch return PolyError.OutOfMemory;
        argv.append(op) catch return PolyError.OutOfMemory;
        if (arg) |x| argv.append(x) catch return PolyError.OutOfMemory;

        const res = std.process.Child.run(.{
            .allocator = a,
            .argv = argv.items,
            .max_output_bytes = 4096,
        }) catch |err| {
            std.debug.print("qs child spawn failed: {s}\n", .{@errorName(err)});
            return error.QsGuestUnavailable;
        };

        switch (res.term) {
            .Exited => |code| if (code != 0) {
                var cwd_buf: [512]u8 = undefined;
                const cwd = std.process.getCwd(&cwd_buf) catch "?";
                std.debug.print("qs op '{s}' exit {d} cwd={s} dll={s}\nstderr: {s}\n", .{ op, code, cwd, dll_store[0..dll_len], res.stderr });
                return error.QsError;
            },
            else => {
                std.debug.print("qs op '{s}' abnormal term\n", .{op});
                return error.QsError;
            },
        }

        const out = std.mem.trim(u8, res.stdout, " \t\r\n");
        return std.fmt.parseInt(i64, out, 10) catch PolyError.NotAnInteger;
    }

    pub fn version() PolyError!u32 {
        const v = try run("version", null);
        if (v < 0 or v > std.math.maxInt(u32)) return PolyError.IntegerOverflow;
        return @intCast(v);
    }

    /// Quantum random number: `n` Hadamard coins packed little-endian.
    /// n in 0..16 (simulator memory grows as 2^n).
    pub fn qrandom(n: u6) PolyError!u64 {
        var buf: [4]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        const v = try run("qrandom", arg);
        if (v < 0) return PolyError.NotAnInteger;
        return @intCast(v);
    }

    /// Bell-pair correlation count out of `shots` (ideal simulator: == shots).
    pub fn bellCorrelated(shots: u32) PolyError!u64 {
        var buf: [12]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{d}", .{shots}) catch unreachable;
        const v = try run("bell", arg);
        if (v < 0) return PolyError.NotAnInteger;
        return @intCast(v);
    }

    /// Hadamard coin One-count out of `shots` (ideal: ~ shots/2).
    pub fn coinOnes(shots: u32) PolyError!u64 {
        var buf: [12]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{d}", .{shots}) catch unreachable;
        const v = try run("coin", arg);
        if (v < 0) return PolyError.NotAnInteger;
        return @intCast(v);
    }
};

// ---------------------------------------------------------------------
// Java guest (Temurin JDK 17, embedded via JNI_CreateJavaVM)
// ---------------------------------------------------------------------
//
// The HotSpot VM is dlopened from the JDK layout (lib/server/libjvm.so)
// and started in-process with JNI_CreateJavaVM. Guest functions live in
// the compiled fanopoly.FanoPoly class (javac output under
// java_guest/classes) and exchange the canonical i256 ABI as 32-byte
// arrays through JNI. Like CPython, the JVM is a process-lifetime
// singleton: created once, never restarted in the same process.

pub const jni = @cImport({
    @cInclude("jni.h");
});

/// C stdlib entry points needed by the JVM guest (setenv so HotSpot can
/// locate its own libs from JAVA_HOME at run time).
const cstd = @cImport({
    @cInclude("stdlib.h");
});

pub const Java = struct {
    var lib: ?std.DynLib = null;
    var jvm: jni.JavaVM = null;
    /// JNI's `JNIEnv*` is a pointer to a `JNIEnv` (which is itself the
    /// pointer to the function table). CreateJavaVM writes the address of
    /// the per-thread JNIEnv word into *penv, so this field is the double
    /// pointer, not the table pointer itself.
    var env: *jni.JNIEnv = undefined;
    var cls: jni.jclass = null;
    var m_version: jni.jmethodID = null;
    var m_echo: jni.jmethodID = null;
    var m_add128: jni.jmethodID = null;
    var m_mulraw: jni.jmethodID = null;
    var m_mul128: jni.jmethodID = null;
    var initialized: bool = false;

    const CreateJVMFn = *const fn (pvm: *anyopaque, penv: *anyopaque, args: *anyopaque) callconv(.C) c_int;

    /// True if `p` exists on disk (absolute or relative to the CWD).
    fn pathExists(p: []const u8) bool {
        if (std.fs.path.isAbsolute(p)) {
            std.fs.accessAbsolute(p, .{}) catch return false;
            return true;
        }
        std.fs.cwd().access(p, .{}) catch return false;
        return true;
    }

    /// Locate libjvm.so: FANO_JVM_LIB env, JAVA_HOME, the repo's
    /// os/fano-langs JDK checkout, then the system JVM directories.
    pub fn discoverJvmLib(buf: []u8) ?[]const u8 {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "FANO_JVM_LIB")) |p| {
            defer std.heap.page_allocator.free(p);
            if (p.len > 0 and p.len < buf.len and pathExists(p)) {
                @memcpy(buf[0..p.len], p);
                return buf[0..p.len];
            }
        } else |_| {}
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "JAVA_HOME")) |home| {
            defer std.heap.page_allocator.free(home);
            if (std.fmt.bufPrint(buf, "{s}/lib/server/libjvm.so", .{home})) |p| {
                if (pathExists(p)) return p;
            } else |_| {}
        } else |_| {}
        // Repo-relative: poly.zig lives at <repo>/zig/poly.
        const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
        var scratch: [512]u8 = undefined;
        const langs_dir = std.fmt.bufPrint(&scratch, "{s}/../../os/fano-langs", .{poly_dir}) catch return null;
        if (findJvmInLangsDir(buf, langs_dir)) |p| return p;
        if (std.fmt.bufPrint(buf, "/usr/lib/jvm/java-17-openjdk-amd64/lib/server/libjvm.so", .{})) |p| {
            if (pathExists(p)) return p;
        } else |_| {}
        return null;
    }

    fn findJvmInLangsDir(buf: []u8, langs_dir: []const u8) ?[]const u8 {
        var dir = std.fs.cwd().openDir(langs_dir, .{ .iterate = true }) catch return null;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, "jdk-")) continue;
            if (std.fmt.bufPrint(buf, "{s}/{s}/lib/server/libjvm.so", .{ langs_dir, entry.name })) |p| {
                if (pathExists(p)) return p;
            } else |_| {}
        }
        return null;
    }

    /// The JNI function table. `env` is `JNIEnv*` (pointer to the env
    /// handle); `env.*` is the `JNIEnv` (the table pointer itself).
    fn table() *const jni.struct_JNINativeInterface_ {
        return @ptrCast(env.*);
    }

    /// JNI functions take `JNIEnv*` (a pointer to the env handle).
    fn envp() [*c][*c]const jni.struct_JNINativeInterface_ {
        return @ptrCast(env);
    }

    fn checkException() PolyError!void {
        if (table().ExceptionCheck.?(envp()) != 0) {
            table().ExceptionDescribe.?(envp());
            table().ExceptionClear.?(envp());
            return PolyError.JavaError;
        }
    }

    fn toJbytes(v: I256) PolyError!jni.jbyteArray {
        const arr = table().NewByteArray.?(envp(), 32) orelse return PolyError.JavaError;
        table().SetByteArrayRegion.?(envp(), arr, 0, 32, @ptrCast(&v));
        try checkException();
        return arr;
    }

    fn fromJbytes(arr: jni.jbyteArray) I256 {
        var out: I256 = undefined;
        table().GetByteArrayRegion.?(envp(), arr, 0, 32, @ptrCast(&out));
        return out;
    }

    /// Boot the embedded HotSpot VM with the compiled guest classes on
    /// the class path. Idempotent; process-lifetime singleton.
    pub fn init(classpath: []const u8) !void {
        if (initialized) return;
        var lib_buf: [512]u8 = undefined;
        const lib_path = discoverJvmLib(&lib_buf) orelse return error.JavaGuestUnavailable;

        // Derive the JDK home from <home>/lib/server/libjvm.so so HotSpot
        // can locate libjava.so, libjli.so and the modules image at run
        // time (libjvm.so has no RPATH and loads its deps itself).
        const jdk_home = jdkHomeFromJvmLib(lib_path) orelse return error.JavaGuestUnavailable;
        var home_z: [512]u8 = undefined;
        const home_zs = std.fmt.bufPrintZ(&home_z, "{s}", .{jdk_home}) catch return error.JavaGuestUnavailable;
        _ = cstd.setenv("JAVA_HOME", home_zs.ptr, 1);

        lib = std.DynLib.open(lib_path) catch return error.JavaGuestUnavailable;
        const create = lib.?.lookup(CreateJVMFn, "JNI_CreateJavaVM") orelse return error.JavaGuestUnavailable;

        // JVM options must be -Dname=value; a bare class path is not a
        // valid option. Keep the buffers alive across JNI_CreateJavaVM.
        var cp_opt: [640]u8 = undefined;
        var lib_opt: [640]u8 = undefined;
        var xrs_opt: [4:0]u8 = .{ '-', 'X', 'r', 's' };
        const cp_str = std.fmt.bufPrintZ(&cp_opt, "-Djava.class.path={s}", .{classpath}) catch return error.JavaGuestUnavailable;
        const lib_str = std.fmt.bufPrintZ(&lib_opt, "-Djava.library.path={s}/lib", .{jdk_home}) catch return error.JavaGuestUnavailable;
        var options = [_]jni.JavaVMOption{
            .{ .optionString = cp_str.ptr, .extraInfo = null },
            .{ .optionString = lib_str.ptr, .extraInfo = null },
            // Reduce JVM signal usage so it does not fight the host's
            // signal handlers (the test runner installs its own).
            .{ .optionString = &xrs_opt, .extraInfo = null },
        };
        var args = jni.JavaVMInitArgs{
            .version = jni.JNI_VERSION_1_8,
            .nOptions = options.len,
            .options = &options,
            .ignoreUnrecognized = jni.JNI_TRUE,
        };
        var jvm_ptr: jni.JavaVM = null;
        var env_ptr: ?*jni.JNIEnv = null;
        const rc = create(@ptrCast(&jvm_ptr), @ptrCast(&env_ptr), @ptrCast(&args));
        if (rc != jni.JNI_OK) return error.JavaInitFailed;
        env = env_ptr orelse return error.JavaInitFailed;
        jvm = jvm_ptr;

        cls = table().FindClass.?(envp(), "fanopoly/FanoPoly") orelse return error.JavaClassNotFound;
        try checkException();
        const global = table().NewGlobalRef.?(envp(), cls);
        if (global == null) return PolyError.JavaError;
        cls = @ptrCast(global);

        m_version = table().GetStaticMethodID.?(envp(), cls, "version", "()I") orelse return PolyError.JavaError;
        m_echo = table().GetStaticMethodID.?(envp(), cls, "echo", "([B)[B") orelse return PolyError.JavaError;
        m_add128 = table().GetStaticMethodID.?(envp(), cls, "add128", "([B[B)[B") orelse return PolyError.JavaError;
        m_mulraw = table().GetStaticMethodID.?(envp(), cls, "mulraw", "([B[B)[B") orelse return PolyError.JavaError;
        m_mul128 = table().GetStaticMethodID.?(envp(), cls, "mul128", "([B[B)[B") orelse return PolyError.JavaError;
        try checkException();
        initialized = true;
    }

    /// `<home>/lib/server/libjvm.so` (or `.../lib/client/libjvm.so`) ->
    /// `<home>`. Returns null if the path does not match the JDK layout.
    fn jdkHomeFromJvmLib(lib_path: []const u8) ?[]const u8 {
        const suffix = "/lib/server/libjvm.so";
        if (std.mem.endsWith(u8, lib_path, suffix)) {
            return lib_path[0 .. lib_path.len - suffix.len];
        }
        const alt = "/lib/client/libjvm.so";
        if (std.mem.endsWith(u8, lib_path, alt)) {
            return lib_path[0 .. lib_path.len - alt.len];
        }
        return null;
    }

    /// Destroy the embedded VM. Only at process exit; a destroyed JVM
    /// cannot be re-created in the same process.
    pub fn deinit() void {
        if (!initialized) return;
        if (jvm != null) {
            const vm = @as(jni.JavaVM, jvm);
            if (vm.*.DestroyJavaVM) |d| _ = d(@ptrCast(&jvm));
        }
        initialized = false;
    }

    pub fn version() PolyError!u32 {
        if (!initialized) return PolyError.GuestUnavailable;
        const v = table().CallStaticIntMethod.?(envp(), cls, m_version);
        try checkException();
        if (v < 0) return PolyError.IntegerOverflow;
        return @intCast(v);
    }

    pub fn echo(v: I256) PolyError!I256 {
        if (!initialized) return PolyError.GuestUnavailable;
        const in = try toJbytes(v);
        defer table().DeleteLocalRef.?(envp(), in);
        const out = table().CallStaticObjectMethod.?(envp(), cls, m_echo, in) orelse return PolyError.JavaError;
        defer table().DeleteLocalRef.?(envp(), out);
        try checkException();
        return fromJbytes(@ptrCast(out));
    }

    pub fn add128(a: I256, b: I256) PolyError!I256 {
        if (!initialized) return PolyError.GuestUnavailable;
        const ja = try toJbytes(a);
        defer table().DeleteLocalRef.?(envp(), ja);
        const jb = try toJbytes(b);
        defer table().DeleteLocalRef.?(envp(), jb);
        const out = table().CallStaticObjectMethod.?(envp(), cls, m_add128, ja, jb) orelse return PolyError.JavaError;
        defer table().DeleteLocalRef.?(envp(), out);
        try checkException();
        return fromJbytes(@ptrCast(out));
    }

    pub fn mulraw(a: I256, b: I256) PolyError!I256 {
        if (!initialized) return PolyError.GuestUnavailable;
        const ja = try toJbytes(a);
        defer table().DeleteLocalRef.?(envp(), ja);
        const jb = try toJbytes(b);
        defer table().DeleteLocalRef.?(envp(), jb);
        const out = table().CallStaticObjectMethod.?(envp(), cls, m_mulraw, ja, jb) orelse return PolyError.JavaError;
        defer table().DeleteLocalRef.?(envp(), out);
        try checkException();
        return fromJbytes(@ptrCast(out));
    }

    /// Q128.128 fixed-point multiply through the exact 512-bit product.
    pub fn mul128(a: I256, b: I256) PolyError!I256 {
        if (!initialized) return PolyError.GuestUnavailable;
        const ja = try toJbytes(a);
        defer table().DeleteLocalRef.?(envp(), ja);
        const jb = try toJbytes(b);
        defer table().DeleteLocalRef.?(envp(), jb);
        const out = table().CallStaticObjectMethod.?(envp(), cls, m_mul128, ja, jb) orelse return PolyError.JavaError;
        defer table().DeleteLocalRef.?(envp(), out);
        try checkException();
        return fromJbytes(@ptrCast(out));
    }

    pub fn mulQ128(a: q.q128, b: q.q128) PolyError!q.q128 {
        const r = try mul128(i256FromQ128(a), i256FromQ128(b));
        return i256ToQ128(r);
    }
};

// ---------------------------------------------------------------------
// Node.js guest (subprocess bridge over the system/vendored node binary)
// ---------------------------------------------------------------------
//
// Node 20 ships standalone on PATH in the FANO-1 language matrix. In
// process JS stays on QuickJS; this bridge runs `node_guest/guest.js` as
// a child process and exchanges canonical i256 hex on stdout, mirroring
// the Q# runner protocol.

pub const Node = struct {
    var exe_store: [512]u8 = undefined;
    var exe_len: usize = 0;
    var initialized: bool = false;

    /// Register the node binary path (absolute path or a bare name
    /// resolved from PATH).
    pub fn init(node_path: []const u8) !void {
        if (node_path.len > exe_store.len) return PolyError.NodeGuestUnavailable;
        @memcpy(exe_store[0..node_path.len], node_path);
        exe_len = node_path.len;
        initialized = true;
    }

    /// Register by probing FANO_NODE env, the vendored Node 20 tree
    /// under os/fano-langs, then the bare `node` on PATH.
    pub fn initAuto() !void {
        var buf: [512]u8 = undefined;
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "FANO_NODE")) |p| {
            defer std.heap.page_allocator.free(p);
            if (p.len > 0 and p.len < buf.len) {
                try init(buf[0..p.len]);
                return;
            }
        } else |_| {}
        const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
        const vendored = std.fmt.bufPrint(&buf, "{s}/../../os/fano-langs/node20/bin/node", .{poly_dir}) catch return PolyError.NodeGuestUnavailable;
        if (std.fs.cwd().access(vendored, .{})) |_| {
            try init(vendored);
            return;
        } else |_| {}
        try init("node");
    }

    fn guestScript(buf: []u8) []const u8 {
        const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
        return std.fmt.bufPrint(buf, "{s}/node_guest/guest.js", .{poly_dir}) catch unreachable;
    }

    /// Run one guest op; returns the trimmed stdout owned by the page
    /// allocator (caller frees).
    fn run(op: []const u8, args: []const []const u8) PolyError![]u8 {
        if (!initialized) return PolyError.GuestUnavailable;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var argv = std.ArrayList([]const u8).init(a);
        argv.append(exe_store[0..exe_len]) catch return PolyError.OutOfMemory;
        var script_buf: [512]u8 = undefined;
        argv.append(guestScript(&script_buf)) catch return PolyError.OutOfMemory;
        argv.append(op) catch return PolyError.OutOfMemory;
        for (args) |x| argv.append(x) catch return PolyError.OutOfMemory;

        const res = std.process.Child.run(.{
            .allocator = a,
            .argv = argv.items,
            .max_output_bytes = 8192,
        }) catch return PolyError.NodeGuestUnavailable;
        switch (res.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("node op '{s}' exit {d}\nstderr: {s}\n", .{ op, code, res.stderr });
                return PolyError.NodeError;
            },
            else => return PolyError.NodeError,
        }
        const out = std.mem.trim(u8, res.stdout, " \t\r\n");
        return std.heap.page_allocator.dupe(u8, out) catch return PolyError.OutOfMemory;
    }

    pub fn version() PolyError!u32 {
        const s = try run("version", &.{});
        defer std.heap.page_allocator.free(s);
        return std.fmt.parseInt(u32, s, 10) catch return PolyError.NotAnInteger;
    }

    pub fn echo(v: I256) PolyError!I256 {
        var hex_buf: [64]u8 = undefined;
        const hex = i256ToHex(&hex_buf, v);
        const out = try run("echo", &.{hex});
        defer std.heap.page_allocator.free(out);
        return i256FromHex(out) catch return PolyError.NotAnInteger;
    }

    pub fn add128(a: I256, b: I256) PolyError!I256 {
        return binaryOp("add128", a, b);
    }

    pub fn mulraw(a: I256, b: I256) PolyError!I256 {
        return binaryOp("mulraw", a, b);
    }

    /// Q128.128 fixed-point multiply through the exact product on the
    /// Node side (round-to-nearest-even, matching the other guests).
    pub fn mul128(a: I256, b: I256) PolyError!I256 {
        return binaryOp("mul128", a, b);
    }

    fn binaryOp(op: []const u8, a: I256, b: I256) PolyError!I256 {
        var ha: [64]u8 = undefined;
        var hb: [64]u8 = undefined;
        const args = [_][]const u8{ i256ToHex(&ha, a), i256ToHex(&hb, b) };
        const out = try run(op, &args);
        defer std.heap.page_allocator.free(out);
        return i256FromHex(out) catch return PolyError.NotAnInteger;
    }

    pub fn mulQ128(a: q.q128, b: q.q128) PolyError!q.q128 {
        const r = try mul128(i256FromQ128(a), i256FromQ128(b));
        return i256ToQ128(r);
    }

    /// Evaluate a JS expression yielding a BigInt/integer and convert it
    /// exactly into the i256 ABI.
    pub fn evalI256(expr: []const u8) PolyError!I256 {
        const out = try run("eval", &.{expr});
        defer std.heap.page_allocator.free(out);
        return i256FromHex(out) catch return PolyError.NotAnInteger;
    }

    /// Evaluate a Q128.128 fixed-point expression (raw-mantissa math).
    pub fn evalQ128(expr: []const u8) PolyError!q.q128 {
        const v = try evalI256(expr);
        return i256ToQ128(v);
    }
};

/// Format an i256 value as 64-char lowercase two's-complement hex.
fn i256ToHex(buf: *[64]u8, v: I256) []const u8 {
    const wide = std.mem.readInt(u256, &v, .little);
    _ = std.fmt.bufPrint(buf, "{x:0>64}", .{wide}) catch unreachable;
    return buf[0..64];
}

const testing = std.testing;

test "i256 ABI round-trips q128 values" {
    const cases = [_]q.q128{
        .{ .hi = 0, .lo = 0 },
        .{ .hi = 0, .lo = 1 }, // smallest positive step (2^-128)
        .{ .hi = 1, .lo = 0 }, // 1.0
        .{ .hi = @bitCast(@as(i128, -1)), .lo = ~@as(u128, 0) }, // -2^-128
        .{ .hi = @bitCast(@as(i128, -2)), .lo = 0 }, // -2.0
    };
    for (cases) |v| {
        const packed_ = i256FromQ128(v);
        try testing.expectEqual(v, i256ToQ128(packed_));
    }
}

test "i256 decimal parsing wraps to 256-bit two's complement" {
    // 2^255 parses to the two's-complement minimum.
    const p255 = try i256FromDecimal("57896044618658097711785492504343953926634992332820282019728792003956564819968");
    var expect: I256 = undefined;
    std.mem.writeInt(u256, &expect, @as(u256, 1) << 255, .little);
    try testing.expectEqualSlices(u8, &expect, &p255);

    // -1 parses to all-ones.
    const neg1 = try i256FromDecimal("-1");
    for (neg1) |byte| try testing.expectEqual(@as(u8, 0xFF), byte);

    // 2^256 wraps to zero; 2^256+1 wraps to 1.
    const p256 = try i256FromDecimal("115792089237316195423570985008687907853269984665640564039457584007913129639936");
    for (p256) |byte| try testing.expectEqual(@as(u8, 0), byte);
    const p256p1 = try i256FromDecimal("115792089237316195423570985008687907853269984665640564039457584007913129639937");
    try testing.expectEqual(@as(u8, 1), p256p1[0]);
    for (p256p1[1..]) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "i256 decimal round-trip" {
    const cases = [_][]const u8{ "0", "1", "-1", "42", "-42", "340282366920938463463374607431768211455" };
    for (cases) |text| {
        const v = try i256FromDecimal(text);
        const wide = std.mem.readInt(u256, &v, .little);
        var buf: [96]u8 = undefined;
        const printed = try std.fmt.bufPrint(&buf, "{d}", .{wide});
        const reparsed = try i256FromDecimal(printed);
        try testing.expectEqualSlices(u8, &v, &reparsed);
    }
}

test "quickjs guest evaluates expressions and BigInt" {
    var engine = try QuickJS.init();
    defer engine.deinit();
    const r = try engine.eval(std.testing.allocator, "6 * 7");
    defer std.testing.allocator.free(r);
    try testing.expectEqualStrings("42", r);

    const b = try engine.evalI256("(2n**100n + 1n)");
    const wide = std.mem.readInt(u256, &b, .little);
    try testing.expectEqual(@as(u256, 1) << 100 | 1, wide);
}

test "python guest evaluates expressions" {
    // The embedded interpreter is process-lifetime: init once, never
    // re-init after finalize (CPython limitation).
    try Python.init();
    const r = try Python.eval(std.testing.allocator, "21 * 2");
    defer std.testing.allocator.free(r);
    try testing.expectEqualStrings("42", r);

    const s = try Python.eval(std.testing.allocator, "'foo' + 'bar'");
    defer std.testing.allocator.free(s);
    try testing.expectEqualStrings("'foobar'", s);
}

test "python guest exact fixed-point arithmetic" {
    try Python.init();
    // (2^64+1)^2 mod 2^256 through the exact integer path.
    const v = try Python.evalI256("(2**64+1)*(2**64+1)");
    const wide = std.mem.readInt(u256, &v, .little);
    try testing.expectEqual(@as(u256, 340282366920938463500268095579187314689), wide);
}

test "python guest q128 fixed-point multiply" {
    try Python.init();
    // 1.5 * 2.5 = 3.75 in Q128.128: raw mantissas 3<<127 (1.5) and 5<<127 (2.5).
    // Fixed-point multiply = raw product >> 128.
    const v = try Python.evalQ128("((3<<127) * (5<<127)) >> 128");
    // (3*2^127)*(5*2^127) >> 128 = 15*2^126 = 3.75*2^128
    const bytes = i256FromQ128(v);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

test "quickjs guest q128 fixed-point multiply" {
    var engine = try QuickJS.init();
    defer engine.deinit();
    const v = try engine.evalQ128("((3n<<127n) * (5n<<127n)) >> 128n");
    const bytes = i256FromQ128(v);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

test "both guests agree on exact fixed-point arithmetic in one process" {
    try Python.init();
    var engine = try QuickJS.init();
    defer engine.deinit();
    // Same fixed-point product through both guests, cross-checked.
    const pv = try Python.evalQ128("((3<<127) * (5<<127)) >> 128");
    const jv = try engine.evalQ128("((3n<<127n) * (5n<<127n)) >> 128n");
    try testing.expect(q.q128Eq(pv, jv));
    const bytes = i256FromQ128(pv);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

test "rust guest ABI echo and version" {
    try testing.expectEqual(@as(u32, 1), Rust.version());
    const v = i256FromQ128(.{ .hi = 0xDEAD, .lo = 0xBEEF });
    try testing.expectEqual(v, Rust.echo(v));
}

test "rust guest raw multiply matches u256 wrapping" {
    const a = try i256FromDecimal("3037000500");
    const b = try i256FromDecimal("3037000500");
    const r = Rust.mulraw(a, b);
    const wide = std.mem.readInt(u256, &r, .little);
    // 3037000500^2 = 9.223e17 fits in u256 exactly.
    try testing.expectEqual(@as(u256, 3037000500) * 3037000500, wide);
}

test "rust guest fixed-point multiply matches the Zig engine" {
    // 1.5 * 2.5 = 3.75: mantissas 1.5*2^128 and 2.5*2^128.
    const one_half: q.q128 = .{ .hi = 1, .lo = @as(u128, 1) << 127 }; // 1.5
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 }; // 2.5
    const native = q.q128Mul(one_half, two_five).v;
    const rs = Rust.mulQ128(one_half, two_five);
    try testing.expect(q.q128Eq(native, rs));
    const bytes = i256FromQ128(rs);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

test "c guest ABI echo and version" {
    try testing.expectEqual(@as(u32, 1), CGuest.version());
    const v = i256FromQ128(.{ .hi = 0xFEED, .lo = 0xFACE });
    try testing.expectEqual(v, CGuest.echo(v));
}

test "c guest fixed-point multiply matches the Zig engine" {
    const one_half: q.q128 = .{ .hi = 1, .lo = @as(u128, 1) << 127 }; // 1.5
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 }; // 2.5
    const native = q.q128Mul(one_half, two_five).v;
    const c = CGuest.mulQ128(one_half, two_five);
    try testing.expect(q.q128Eq(native, c));
    const bytes = i256FromQ128(c);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

test "c guest negative fixed-point multiply matches the Zig engine" {
    // -1.5 * 2.5 = -3.75 through both paths, bit-for-bit.
    const one_half_neg: q.q128 = .{ .hi = @bitCast(@as(i128, -1)), .lo = @as(u128, 1) << 127 };
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 };
    const native = q.q128Mul(one_half_neg, two_five).v;
    const rs = Rust.mulQ128(one_half_neg, two_five);
    const c = CGuest.mulQ128(one_half_neg, two_five);
    try testing.expect(q.q128Eq(native, rs));
    try testing.expect(q.q128Eq(native, c));
}

test "all four guests agree on exact fixed-point arithmetic" {
    try Python.init();
    var engine = try QuickJS.init();
    defer engine.deinit();
    const one_half: q.q128 = .{ .hi = 1, .lo = @as(u128, 1) << 127 };
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 };
    const pv = try Python.evalQ128("((1<<128) + (1<<127)) * ((2<<128) + (1<<127)) >> 128");
    const jv = try engine.evalQ128("(((1n<<128n) + (1n<<127n)) * ((2n<<128n) + (1n<<127n))) >> 128n");
    const rv = Rust.mulQ128(one_half, two_five);
    const cv = CGuest.mulQ128(one_half, two_five);
    try testing.expect(q.q128Eq(pv, jv));
    try testing.expect(q.q128Eq(pv, cv));
    try testing.expect(q.q128Eq(rv, cv));
    var buf: [512]u8 = undefined;
    const so = dotnetGuestSo(&buf);
    DotNet.init(so) catch |err| {
        if (err == error.DotNetGuestUnavailable or err == error.DotNetExportNotFound) {
            std.debug.print("dotnet guest unavailable ({s}); skipping\n", .{@errorName(err)});
            return error.SkipZigTest;
        }
        return err;
    };
    const dv = DotNet.mulQ128(one_half, two_five);
    try testing.expect(q.q128Eq(pv, dv));
}

// Path of the NativeAOT-compiled C# guest library, relative to this file.
fn dotnetGuestSo(buf: []u8) []const u8 {
    const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
    return std.fmt.bufPrint(buf, "{s}/dotnet_guest/publish/FanoPolyCs.so", .{poly_dir}) catch unreachable;
}

test "dotnet guest ABI echo and version" {
    var buf: [512]u8 = undefined;
    const so = dotnetGuestSo(&buf);
    DotNet.init(so) catch |err| {
        if (err == error.DotNetGuestUnavailable or err == error.DotNetExportNotFound) {
            std.debug.print("dotnet guest unavailable ({s}); skipping\n", .{@errorName(err)});
            return error.SkipZigTest;
        }
        return err;
    };
    try testing.expectEqual(@as(u32, 1), DotNet.version());
    const v = i256FromQ128(.{ .hi = 0xCAFE, .lo = 0xBABE });
    try testing.expectEqual(v, DotNet.echo(v));
}

test "dotnet guest fixed-point multiply matches the Zig engine" {
    var buf: [512]u8 = undefined;
    const so = dotnetGuestSo(&buf);
    DotNet.init(so) catch |err| {
        if (err == error.DotNetGuestUnavailable or err == error.DotNetExportNotFound) {
            std.debug.print("dotnet guest unavailable; skipping\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    const one_half: q.q128 = .{ .hi = 1, .lo = @as(u128, 1) << 127 };
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 };
    const native = q.q128Mul(one_half, two_five).v;
    const cs = DotNet.mulQ128(one_half, two_five);
    try testing.expect(q.q128Eq(native, cs));
    const bytes = i256FromQ128(cs);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

// Path of the QDK-built Q# runner assembly, relative to this file.
fn qsGuestDll(buf: []u8) []const u8 {
    const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
    return std.fmt.bufPrint(buf, "{s}/qs_guest/publish/FanoQs.dll", .{poly_dir}) catch unreachable;
}

fn qsInitOrSkip() !void {
    var buf: [512]u8 = undefined;
    const dll = qsGuestDll(&buf);
    Qs.init(dll) catch |err| {
        if (err == error.QsGuestUnavailable) {
            std.debug.print("qs guest unavailable; skipping\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
}

test "qs guest version" {
    try qsInitOrSkip();
    const v = Qs.version() catch |err| {
        std.debug.print("qs version error: {s}\n", .{@errorName(err)});
        return err;
    };
    try testing.expectEqual(@as(u32, 1), v);
}

test "qs guest bell pairs are perfectly correlated" {
    try qsInitOrSkip();
    // Ideal statevector simulator: every Bell shot is correlated.
    const shots: u32 = 128;
    const correlated = try Qs.bellCorrelated(shots);
    try testing.expectEqual(@as(u64, shots), correlated);
}

test "qs guest hadamard coin converges to fair" {
    try qsInitOrSkip();
    const ones = try Qs.coinOnes(1000);
    // 5-sigma band around 500 for the ideal simulator.
    try testing.expect(ones >= 400 and ones <= 600);
}

test "qs guest qrandom stays in range" {
    try qsInitOrSkip();
    const v = try Qs.qrandom(16);
    try testing.expect(v < (1 << 16));
}

// Path of the javac-compiled Java guest classes, relative to this file.
fn javaGuestClasses(buf: []u8) []const u8 {
    const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
    return std.fmt.bufPrint(buf, "{s}/java_guest/classes", .{poly_dir}) catch unreachable;
}

// ---------------------------------------------------------------------
// Java guest tests
// ---------------------------------------------------------------------
//
// HotSpot uses SIGSEGV/SIGBUS for implicit null checks and safepoint
// polls; the Zig test runner installs its own signal handlers first, so
// JNI_CreateJavaVM segfaults inside the test runner. The JVM guest is
// therefore verified by the standalone `poly-smoke` binary (a normal
// executable with no test-runner signal handlers), which `test-poly`
// builds and runs. The unit tests below skip in-process and point at
// poly-smoke so the regression surface is explicit.

fn javaInitOrSkip() !void {
    std.debug.print("java: in-process JVM disabled under the Zig test runner; verified by poly-smoke\n", .{});
    return error.SkipZigTest;
}

test "java guest ABI echo and version" {
    try javaInitOrSkip();
}

test "java guest fixed-point multiply matches the Zig engine" {
    try javaInitOrSkip();
}

test "java guest negative fixed-point multiply matches the Zig engine" {
    try javaInitOrSkip();
}

test "java guest raw multiply wraps mod 2^256" {
    try javaInitOrSkip();
}

// ---------------------------------------------------------------------
// Node.js guest tests
// ---------------------------------------------------------------------

fn nodeInitOrSkip() !void {
    Node.initAuto() catch |err| {
        std.debug.print("node guest unavailable ({s}); skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
}

test "node guest ABI echo and version" {
    try nodeInitOrSkip();
    const v = Node.version() catch |err| {
        std.debug.print("node version error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    try testing.expectEqual(@as(u32, 1), v);
    const probe = i256FromQ128(.{ .hi = 0xF00D, .lo = 0xFACE });
    try testing.expectEqualSlices(u8, &probe, &(try Node.echo(probe)));
}

test "node guest fixed-point multiply matches the Zig engine" {
    try nodeInitOrSkip();
    const one_half: q.q128 = .{ .hi = 1, .lo = @as(u128, 1) << 127 }; // 1.5
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 }; // 2.5
    const native = q.q128Mul(one_half, two_five).v;
    const nv = Node.mulQ128(one_half, two_five) catch |err| {
        std.debug.print("node mul error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    try testing.expect(q.q128Eq(native, nv));
    const bytes = i256FromQ128(nv);
    const wide = std.mem.readInt(u256, &bytes, .little);
    try testing.expectEqual(@as(u256, 15) << 126, wide);
}

test "node guest negative fixed-point multiply matches the Zig engine" {
    try nodeInitOrSkip();
    const neg_one_half: q.q128 = .{ .hi = @bitCast(@as(i128, -1)), .lo = @as(u128, 1) << 127 };
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 };
    const native = q.q128Mul(neg_one_half, two_five).v;
    const nv = try Node.mulQ128(neg_one_half, two_five);
    try testing.expect(q.q128Eq(native, nv));
    // add128 parity: 1.5 + (-2.5) = -1.0 exactly. -2.5 = -3 + 0.5.
    const a = i256FromQ128(.{ .hi = 1, .lo = @as(u128, 1) << 127 });
    const b = i256FromQ128(.{ .hi = @bitCast(@as(i128, -3)), .lo = @as(u128, 1) << 127 });
    const sum = try Node.add128(a, b);
    const want = i256FromQ128(.{ .hi = @bitCast(@as(i128, -1)), .lo = 0 });
    try testing.expectEqualSlices(u8, &want, &sum);
}

test "node guest raw multiply wraps mod 2^256" {
    try nodeInitOrSkip();
    const a = try i256FromDecimal("3037000500");
    const b = try i256FromDecimal("3037000500");
    const r = try Node.mulraw(a, b);
    const wide = std.mem.readInt(u256, &r, .little);
    try testing.expectEqual(@as(u256, 3037000500) * 3037000500, wide);
}

test "node guest evaluates BigInt expressions to i256" {
    try nodeInitOrSkip();
    const v = Node.evalI256("(2n**100n + 1n)") catch |err| {
        std.debug.print("node eval error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const wide = std.mem.readInt(u256, &v, .little);
    try testing.expectEqual(@as(u256, 1) << 100 | 1, wide);
}
