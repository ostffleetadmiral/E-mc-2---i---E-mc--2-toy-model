//! fano_rf_main.zig - fano-rf: RF energy harvesting link-budget CLI.
//!
//! Commands:
//!   friis <pt_dbm> <gt> <gr> <f_hz> <d_m>   Friis received power
//!   noise <t_k> <bw_hz>                     Johnson-Nyquist floor
//!   rect <pr_w> <rs_ohm> <stages> <vd_mv>   Greinacher DC output
//!   cpu [loop_area_cm2] [dist_cm]           CPU clock EMI scenario
//!   budget                                  ambient vs near-field comparison

const std = @import("std");
const Q = @import("q128_128");
const rf = @import("rf_harvest");

fn printSci(w: anytype, v: f64) !void {
    try w.print("{e}", .{v});
}

fn cmdFriis(pt_dbm: i32, gt: u128, gr: u128, f_hz: u128, d_m: Q.q128) !void {
    const w = std.io.getStdOut().writer();
    const r = rf.friisReceivedW(pt_dbm, gt, gr, f_hz, d_m);
    try w.print("Friis: Pt={d} dBm  Gt={d}  Gr={d}  f={d} Hz  d=", .{ pt_dbm, gt, gr, f_hz });
    try printSci(w, Q.toFloat(d_m));
    try w.print(" m\n  Pr = ", .{});
    try printSci(w, Q.toFloat(r.pr_w));
    try w.print(" W  (far-field: {})\n", .{r.far_field});
}

fn cmdNoise(t_k: Q.q128, bw_hz: Q.q128) !void {
    const w = std.io.getStdOut().writer();
    const p = Q.toFloat(rf.johnsonNoiseW(t_k, bw_hz));
    try w.print("Johnson-Nyquist: T=", .{});
    try printSci(w, Q.toFloat(t_k));
    try w.print(" K  B=", .{});
    try printSci(w, Q.toFloat(bw_hz));
    try w.print(" Hz\n  P_noise = ", .{});
    try printSci(w, p);
    try w.print(" W\n", .{});
}

fn cmdRect(pr_w: Q.q128, rs: Q.q128, n: u32, vd: Q.q128) !void {
    const w = std.io.getStdOut().writer();
    const vdc = Q.toFloat(rf.greinacherVdc(pr_w, rs, n, vd));
    try w.print("Greinacher {d}-stage: Vdc = {d:.4} V (Rs = {d:.0} ohm, Vd = {d:.3} V)\n", .{ n, vdc, Q.toFloat(rs), Q.toFloat(vd) });
}

fn cmdCpu(area_cm2: f64, dist_cm: f64) !void {
    const w = std.io.getStdOut().writer();
    // 3 GHz clock harmonic, 20 mA switching current, loop antenna.
    const i = Q.q128FromRatio(2, 100);
    const area = Q.q128FromF64(area_cm2 * 1e-4);
    const r = Q.q128FromF64(dist_cm / 100.0);
    const emf = rf.nearFieldLoopEmf(i, 3_000_000_000, area, r);
    const p = rf.nearFieldLoopPowerW(emf, Q.q128FromI64(100));
    const day = rf.harvestJ(p, Q.q128FromI64(86400));
    try w.print("CPU clock EMI (3 GHz, 20 mA, {d:.2} cm^2 loop at {d:.1} cm):\n", .{ area_cm2, dist_cm });
    try w.print("  EMF      = {d:.4} V\n", .{Q.toFloat(emf)});
    try w.print("  P_load   = ", .{});
    try printSci(w, Q.toFloat(p));
    try w.print(" W  (matched 100 ohm loop)\n", .{});
    try w.print("  E_day    = ", .{});
    try printSci(w, Q.toFloat(day));
    try w.print(" J/day\n", .{});
}

fn cmdBudget() !void {
    const w = std.io.getStdOut().writer();
    try w.print("Energy budget comparison (Q128.128 exact):\n", .{});
    // Ambient RF: 0.1 uW/cm^2 urban density (GSM base station vicinity),
    // 25 cm^2 rectenna aperture, 40% RF-dc efficiency (Imperial College 2013).
    const s_amb = Q.q128FromRatio(1, 10_000_000); // 1e-7 W/m^2
    const a_gsm = Q.q128FromRatio(25, 10000); // 25 cm^2 = 2.5e-3 m^2
    const p_gsm = Q.q128Mul(s_amb, a_gsm).v;
    const e_gsm = rf.harvestJ(p_gsm, Q.q128FromI64(86400));
    try w.print("  ambient RF (0.1 uW/cm^2, 25 cm^2, 40%): P  = ", .{});
    try printSci(w, Q.toFloat(p_gsm));
    try w.print(" W   E_day = ", .{});
    try printSci(w, Q.toFloat(e_gsm));
    try w.print(" J\n", .{});
    // CPU clock near-field (1 cm^2 loop at 2 cm).
    const i = Q.q128FromRatio(2, 100);
    const area = Q.q128FromRatio(1, 10000);
    const r = Q.q128FromRatio(2, 100);
    const emf = rf.nearFieldLoopEmf(i, 3_000_000_000, area, r);
    const p_cpu = rf.nearFieldLoopPowerW(emf, Q.q128FromI64(100));
    const e_cpu = rf.harvestJ(p_cpu, Q.q128FromI64(86400));
    try w.print("  CPU clock near-field:   P  = ", .{});
    try printSci(w, Q.toFloat(p_cpu));
    try w.print(" W   E_day = ", .{});
    try printSci(w, Q.toFloat(e_cpu));
    try w.print(" J\n", .{});
    // Noise floor for a 1 MHz rectifier bandwidth at 290 K.
    const pn = rf.johnsonNoiseW(Q.q128FromI64(290), Q.q128FromRatio(1_000_000, 1));
    try w.print("  Johnson-Nyquist floor:  P  = ", .{});
    try printSci(w, Q.toFloat(pn));
    try w.print(" W (290 K, 1 MHz)\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const w = std.io.getStdOut().writer();

    if (args.len < 2) {
        try w.print(
            \\fano-rf - RF energy harvesting link budgets (Q128.128)
            \\  friis <pt_dbm> <gt> <gr> <f_hz> <d_m>   received power
            \\  noise <t_k> <bw_hz>                     Johnson-Nyquist floor
            \\  rect <pr_w> <rs> <stages> <vd_mv>       Greinacher DC output
            \\  cpu [area_cm2]                          CPU clock EMI estimate
            \\  budget                                  source comparison
            \\
        , .{});
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "friis") and args.len >= 7) {
        const pt = try std.fmt.parseInt(i32, args[2], 10);
        const gt = try std.fmt.parseInt(u128, args[3], 10);
        const gr = try std.fmt.parseInt(u128, args[4], 10);
        const f = try std.fmt.parseInt(u128, args[5], 10);
        const d = try std.fmt.parseFloat(f64, args[6]);
        return cmdFriis(pt, gt, gr, f, Q.q128FromF64(d));
    }
    if (std.mem.eql(u8, cmd, "noise") and args.len >= 4) {
        const t = try std.fmt.parseFloat(f64, args[2]);
        const bw = try std.fmt.parseFloat(f64, args[3]);
        return cmdNoise(Q.q128FromF64(t), Q.q128FromF64(bw));
    }
    if (std.mem.eql(u8, cmd, "rect") and args.len >= 6) {
        const pr = try std.fmt.parseFloat(f64, args[2]);
        const rs = try std.fmt.parseFloat(f64, args[3]);
        const n = try std.fmt.parseInt(u32, args[4], 10);
        const vd = try std.fmt.parseFloat(f64, args[5]);
        return cmdRect(Q.q128FromF64(pr), Q.q128FromF64(rs), n, Q.q128FromF64(vd / 1000.0));
    }
    if (std.mem.eql(u8, cmd, "cpu")) {
        const area: f64 = if (args.len >= 3) try std.fmt.parseFloat(f64, args[2]) else 1.0;
        const dist: f64 = if (args.len >= 4) try std.fmt.parseFloat(f64, args[3]) else 2.0;
        return cmdCpu(area, dist);
    }
    if (std.mem.eql(u8, cmd, "budget")) return cmdBudget();
    try w.print("unknown command: {s}\n", .{cmd});
    return error.Usage;
}
