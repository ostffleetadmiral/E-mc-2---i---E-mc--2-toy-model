//! poly_smoke.zig - standalone smoke test for the polyglot runtime.
//! Same build environment as the poly tests, but a normal executable so
//! crashes can be debugged outside the test runner.

const std = @import("std");
const poly = @import("poly.zig");
const q = @import("../q128_128.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // QuickJS first: eval, BigInt, fixed-point product.
    var engine = try poly.QuickJS.init();
    defer engine.deinit();
    const r = try engine.eval(alloc, "6 * 7");
    defer alloc.free(r);
    std.debug.print("quickjs eval: {s}\n", .{r});

    const b = try engine.evalI256("(2n**100n + 1n)");
    const bw = std.mem.readInt(u256, &b, .little);
    std.debug.print("quickjs i256: 2^100+1 = {d} (ok={})\n", .{ bw, bw == (@as(u256, 1) << 100 | 1) });

    const jv = try engine.evalQ128("((3n<<127n) * (5n<<127n)) >> 128n");
    const jb = poly.i256FromQ128(jv);
    const jw = std.mem.readInt(u256, &jb, .little);
    std.debug.print("quickjs q128: 1.5*2.5 = {d} (ok={})\n", .{ jw, jw == (@as(u256, 15) << 126) });

    // Python second: same checks in one process.
    try poly.Python.init();
    const p = try poly.Python.eval(alloc, "21 * 2");
    defer alloc.free(p);
    std.debug.print("python eval: {s}\n", .{p});

    const pv = try poly.Python.evalQ128("((3<<127) * (5<<127)) >> 128");
    const pb = poly.i256FromQ128(pv);
    const pw = std.mem.readInt(u256, &pb, .little);
    std.debug.print("python q128: 1.5*2.5 = {d} (ok={})\n", .{ pw, pw == (@as(u256, 15) << 126) });

    // Rust guest: staticlib on the i256 C ABI.
    const one_half: q.q128 = .{ .hi = 1, .lo = @as(u128, 1) << 127 };
    const two_five: q.q128 = .{ .hi = 2, .lo = @as(u128, 1) << 127 };
    const rv = poly.Rust.mulQ128(one_half, two_five);
    const rb = poly.i256FromQ128(rv);
    const rw = std.mem.readInt(u256, &rb, .little);
    std.debug.print("rust q128: 1.5*2.5 = {d} (ok={})\n", .{ rw, rw == (@as(u256, 15) << 126) });

    // C guest: same fixed-point product.
    const cv = poly.CGuest.mulQ128(one_half, two_five);
    const cb = poly.i256FromQ128(cv);
    const cw = std.mem.readInt(u256, &cb, .little);
    std.debug.print("c q128: 1.5*2.5 = {d} (ok={})\n", .{ cw, cw == (@as(u256, 15) << 126) });

    // All four guests must agree bit-for-bit.
    std.debug.print("guests agree: js+py={} rs={} c={}\n", .{
        q.q128Eq(jv, pv),
        q.q128Eq(jv, rv) and q.q128Eq(jv, cv),
        q.q128Eq(pv, cv),
    });

    // C#/.NET guest: NativeAOT .so, dlopened.
    var so_buf: [512]u8 = undefined;
    const poly_dir = std.fs.path.dirname(@src().file) orelse ".";
    const so = std.fmt.bufPrint(&so_buf, "{s}/dotnet_guest/publish/FanoPolyCs.so", .{poly_dir}) catch unreachable;
    if (poly.DotNet.init(so)) {
        const dv = poly.DotNet.mulQ128(one_half, two_five);
        const db = poly.i256FromQ128(dv);
        const dw = std.mem.readInt(u256, &db, .little);
        std.debug.print("dotnet q128: 1.5*2.5 = {d} (ok={})\n", .{ dw, dw == (@as(u256, 15) << 126) });
        std.debug.print("dotnet agrees: {}\n", .{q.q128Eq(dv, pv)});
    } else |err| {
        std.debug.print("dotnet guest unavailable ({s}); skipped\n", .{@errorName(err)});
    }

    // Q# guest: QDK-built runner via subprocess bridge.
    var dll_buf: [512]u8 = undefined;
    const dll = std.fmt.bufPrint(&dll_buf, "{s}/qs_guest/publish/FanoQs.dll", .{poly_dir}) catch unreachable;
    if (poly.Qs.init(dll)) {
        const bell = try poly.Qs.bellCorrelated(128);
        const coin = try poly.Qs.coinOnes(1000);
        const rnd = try poly.Qs.qrandom(16);
        std.debug.print("qs bell: 128/128 correlated={}\n", .{bell == 128});
        std.debug.print("qs coin: {d}/1000 ones (ok={})\n", .{ coin, coin >= 400 and coin <= 600 });
        std.debug.print("qs qrandom(16): {d} (ok={})\n", .{ rnd, rnd < (1 << 16) });
    } else |err| {
        std.debug.print("qs guest unavailable ({s}); skipped\n", .{@errorName(err)});
    }

    // Java guest: HotSpot embedded via JNI_CreateJavaVM.
    var cp_buf: [512]u8 = undefined;
    const cp = std.fmt.bufPrint(&cp_buf, "{s}/java_guest/classes", .{poly_dir}) catch unreachable;
    if (poly.Java.init(cp)) {
        const jver = try poly.Java.version();
        const jmul = try poly.Java.mulQ128(one_half, two_five);
        const jbytes = poly.i256FromQ128(jmul);
        const jwide = std.mem.readInt(u256, &jbytes, .little);
        std.debug.print("java version: {d}\n", .{jver});
        std.debug.print("java q128: 1.5*2.5 = {d} (ok={})\n", .{ jwide, jwide == (@as(u256, 15) << 126) });
        std.debug.print("java agrees: {}\n", .{q.q128Eq(jmul, pv)});
    } else |err| {
        std.debug.print("java guest unavailable ({s}); skipped\n", .{@errorName(err)});
    }

    // Node.js guest: subprocess bridge over the bundled Node 20 runtime.
    poly.Node.initAuto() catch |err| {
        std.debug.print("node guest unavailable ({s}); skipped\n", .{@errorName(err)});
        return;
    };
    const nver = poly.Node.version() catch |err| {
        std.debug.print("node version error ({s}); skipped\n", .{@errorName(err)});
        return;
    };
    const nmul = try poly.Node.mulQ128(one_half, two_five);
    const nbytes = poly.i256FromQ128(nmul);
    const nwide = std.mem.readInt(u256, &nbytes, .little);
    std.debug.print("node version: {d}\n", .{nver});
    std.debug.print("node q128: 1.5*2.5 = {d} (ok={})\n", .{ nwide, nwide == (@as(u256, 15) << 126) });
    std.debug.print("node agrees: {}\n", .{q.q128Eq(nmul, pv)});

    // Node raw multiply wraps mod 2^256.
    const nra = try poly.i256FromDecimal("3037000500");
    const nrb = try poly.i256FromDecimal("3037000500");
    const nrr = try poly.Node.mulraw(nra, nrb);
    const nrw = std.mem.readInt(u256, &nrr, .little);
    std.debug.print("node raw: 3037000500^2 = {d} (ok={})\n", .{ nrw, nrw == @as(u256, 3037000500) * 3037000500 });
}
