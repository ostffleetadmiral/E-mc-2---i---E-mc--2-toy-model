//! gqa_bind.zig — HF tensor-name binding for the generic GQA+MoE family
//! (qwen3_moe / olmoe). Mirrors bind.zig's plan-resolve-load flow on the
//! generic st.zig name→tensor map; nothing here touches the K3 schema.
//!
//! Two storage forms, exactly like bind.zig:
//!   WIDE  — elementwise vectors (norms): widened to q128 in the blob.
//!   NARROW — matrices (proj/router/experts): checkpoint bytes kept
//!            (bf16 on released weights; f32 on the oracle fixture).
//! Resident experts for phase A; a streamed expert source is the follow-up.

const std = @import("std");
const fp = @import("fixed_point");
const k3 = @import("k3");
const st = @import("st");
const gqa_cfg = @import("gqa_cfg");

pub const Q = k3.Q128;
pub const QSlice = []Q;
pub const QConst = k3.Q128Slice;
pub const Wdt = k3.Wdt;

/// One classic expert FFN: gate/up are [inter][hidden], down is
/// [hidden][inter]. Pointers are raw storage rows in `wdt` format.
pub const GqaExpert = struct {
    gate: ?*const anyopaque = null,
    up: ?*const anyopaque = null,
    down: ?*const anyopaque = null,
    // Streamed mode keeps tensor metadata only; payloads are loaded into the
    // reusable buffers in GqaWeights immediately before expertFfn.
    gate_t: ?*const st.Tensor = null,
    up_t: ?*const st.Tensor = null,
    down_t: ?*const st.Tensor = null,
};

/// One decoder layer: GQA attention + either MoE or dense MLP.
pub const GqaLayerW = struct {
    in_norm: QConst = &.{},
    post_norm: QConst = &.{},

    wq: ?*const anyopaque = null, // [n_heads*head_dim][hidden]
    wk: ?*const anyopaque = null, // [n_kv*head_dim][hidden]
    wv: ?*const anyopaque = null, // [n_kv*head_dim][hidden]
    wo: ?*const anyopaque = null, // [hidden][n_heads*head_dim]
    q_norm: QConst = &.{}, // [head_dim] per-head (qwen3) or [n_heads*head_dim]
    k_norm: QConst = &.{}, // full-width (olmoe) — empty when use_qk_norm is off
    attn_wdt: Wdt = .f32,

    router: ?*const anyopaque = null, // [n_experts][hidden] (mlp.gate / mlp.router)
    router_wdt: Wdt = .f32,
    experts: []GqaExpert = &.{},
    shared_expert: ?GqaExpert = null,
    shared_gate_w: ?*const anyopaque = null, // [1][hidden] scalar sigmoid gate (qwen3_moe)
    expert_wdt: Wdt = .f32,

    dense_gate: ?*const anyopaque = null, // [dense_inter][hidden]
    dense_up: ?*const anyopaque = null,
    dense_down: ?*const anyopaque = null, // [hidden][dense_inter]
    dense_wdt: Wdt = .f32,

    is_moe: bool = false,
};

pub const GqaWeights = struct {
    embed: ?*const anyopaque = null, // [vocab][hidden]
    embed_wdt: Wdt = .f32,
    final_norm: QConst = &.{}, // [hidden]
    lm_head: ?*const anyopaque = null, // [vocab][hidden]; embed when tied
    lm_head_wdt: Wdt = .f32,
    layers: []GqaLayerW = &.{},

    blob: []u8 = &.{}, // owning allocation
    layer_mem: []GqaLayerW = &.{},
    expert_mem: []GqaExpert = &.{},
    // qk-norm weight geometry, probed at bind: per-head (qwen3, width
    // head_dim) vs full-span (olmoe, width n_heads*head_dim). Uniform across
    // layers in every shipped checkpoint of both families.
    qk_norm_wide: bool = false,
    streamed_experts: bool = false,
    stream_st: ?*const st.St = null,
    stream_buf: []u8 = &.{}, // three max-sized bf16/f32 matrix buffers
    stream_stride: usize = 0,
};

// ------------------------------------------------------------------ plan ----

const NameBuf = 160;

const Dest = union(enum) {
    vec: *QConst, // widen to q128
    mat: *?*const anyopaque, // raw bytes; wdt written to wdt_slot
};

const Req = struct {
    name: [NameBuf]u8 = undefined,
    name_len: usize = 0,
    dest: Dest = .{ .vec = undefined },
    wdt_slot: ?*Wdt = null, // mat only: published storage tag
    want: i64 = -1, // numel expectation; -1 = unchecked
    narrow: bool = false,
    optional: bool = false,
    t: ?*const st.Tensor = null,
    off: usize = 0,

    fn nm(q: *const Req) []const u8 {
        return q.name[0..q.name_len];
    }
};

const Plan = struct {
    r: std.ArrayList(Req),
    bad: usize = 0,
};

fn req(p: *Plan, dest: Dest, wdt_slot: ?*Wdt, narrow: bool, optional: bool, want: i64, comptime fmt: []const u8, args: anytype) void {
    const q = p.r.addOne() catch {
        std.debug.print("gqa_bind: out of memory\n", .{});
        p.bad += 1;
        return;
    };
    const s = std.fmt.bufPrint(&q.name, fmt, args) catch {
        std.debug.print("gqa_bind: tensor name truncated\n", .{});
        p.bad += 1;
        return;
    };
    q.name_len = s.len;
    q.dest = dest;
    q.wdt_slot = wdt_slot;
    q.want = want;
    q.narrow = narrow;
    q.optional = optional;
    q.t = null;
    q.off = 0;
}

fn reqw(p: *Plan, dest: *QConst, want: i64, comptime fmt: []const u8, args: anytype) void {
    req(p, .{ .vec = dest }, null, false, false, want, fmt, args);
}
fn reqm(p: *Plan, dest: *?*const anyopaque, slot: *Wdt, want: i64, comptime fmt: []const u8, args: anytype) void {
    req(p, .{ .mat = dest }, slot, true, false, want, fmt, args);
}
fn reqopt(p: *Plan, dest: *QConst, want: i64, comptime fmt: []const u8, args: anytype) void {
    req(p, .{ .vec = dest }, null, false, true, want, fmt, args);
}
fn reqmo(p: *Plan, dest: *?*const anyopaque, slot: *Wdt, want: i64, comptime fmt: []const u8, args: anytype) void {
    req(p, .{ .mat = dest }, slot, true, true, want, fmt, args);
}

fn alignTo(x: usize, a: usize) usize {
    return std.mem.alignForward(usize, x, a);
}

fn elemBytes(q: *const Req) usize {
    if (q.narrow) return 2;
    return switch (q.dest) {
        .mat => 4,
        .vec => @sizeOf(Q),
    };
}
fn elemAlign(q: *const Req) usize {
    if (q.narrow) return 8;
    return switch (q.dest) {
        .mat => 8,
        .vec => @alignOf(Q),
    };
}

fn planResolve(p: *Plan, s: *const st.St) i64 {
    var off: usize = 0;
    for (p.r.items) |*q| {
        q.t = s.find(q.nm());
        if (q.t == null) {
            if (q.optional) continue;
            std.debug.print("gqa_bind: missing tensor {s}\n", .{q.nm()});
            p.bad += 1;
            continue;
        }
        const have = q.t.?.numel();
        if (q.want >= 0 and have != q.want) {
            std.debug.print("gqa_bind: {s} has {d} elements, engine expects {d}\n", .{ q.nm(), have, q.want });
            p.bad += 1;
            continue;
        }
        // narrow only when the checkpoint really stores bf16
        if (q.narrow and q.t.?.dtype != .bf16) q.narrow = false;
        off = alignTo(off, elemAlign(q));
        q.off = off;
        off += @as(usize, @intCast(have)) * elemBytes(q);
    }
    return if (p.bad > 0) -1 else @intCast(off);
}

fn widenQ128(src: []const u8, dtype: st.Dtype, dst: []Q) bool {
    switch (dtype) {
        .f32 => {
            if (src.len < dst.len * 4) return false;
            for (dst, 0..) |*d, i| {
                const bits = std.mem.readInt(u32, src[i * 4 ..][0..4], .little);
                d.* = Q.fromF32Bits(bits) catch return false;
            }
            return true;
        },
        .bf16 => {
            if (src.len < dst.len * 2) return false;
            for (dst, 0..) |*d, i| {
                const h = std.mem.readInt(u16, src[i * 2 ..][0..2], .little);
                d.* = k3.q128FromBf16(h) catch return false;
            }
            return true;
        },
        else => return false,
    }
}

fn widenF32(src: []const u8, dtype: st.Dtype, dst: []u8) bool {
    switch (dtype) {
        .f32 => {
            if (src.len < dst.len) return false;
            @memcpy(dst[0..dst.len], src);
            return true;
        },
        .bf16 => {
            if (src.len * 2 != dst.len) return false;
            var i: usize = 0;
            while (i < dst.len / 4) : (i += 1) {
                const h = std.mem.readInt(u16, src[i * 2 ..][0..2], .little);
                std.mem.writeInt(u32, dst[i * 4 ..][0..4], k3.bf16ToF32Bits(h), .little);
            }
            return true;
        },
        else => return false,
    }
}

fn planLoad(alloc: std.mem.Allocator, p: *Plan, s: *const st.St, blob: []u8) i32 {
    for (p.r.items) |*q| {
        const t = q.t orelse continue; // absent optionals were skipped
        const dst = blob[q.off..];
        if (q.narrow) {
            if (s.read(t, dst[0..@intCast(t.nbytes)]) != @as(usize, @intCast(t.nbytes))) {
                std.debug.print("gqa_bind: short read of {s}\n", .{q.nm()});
                return -1;
            }
        } else {
            const raw = alloc.alloc(u8, @intCast(t.nbytes)) catch return -1;
            defer alloc.free(raw);
            if (s.read(t, raw) != @as(usize, @intCast(t.nbytes))) {
                std.debug.print("gqa_bind: short read of {s}\n", .{q.nm()});
                return -1;
            }
            const n: usize = @intCast(t.numel());
            switch (q.dest) {
                .vec => {
                    const qd: []Q = @as([*]Q, @ptrCast(@alignCast(dst.ptr)))[0..n];
                    if (!widenQ128(raw, t.dtype, qd)) {
                        std.debug.print("gqa_bind: {s} dtype cannot widen\n", .{q.nm()});
                        return -1;
                    }
                },
                .mat => {
                    if (!widenF32(raw, t.dtype, dst[0 .. n * 4])) {
                        std.debug.print("gqa_bind: {s} dtype cannot widen\n", .{q.nm()});
                        return -1;
                    }
                },
            }
        }
        switch (q.dest) {
            .mat => |dp| {
                dp.* = @ptrCast(dst.ptr);
                if (q.wdt_slot) |slot| slot.* = if (q.narrow) .bf16 else .f32;
            },
            .vec => |dp| {
                const n: usize = @intCast(t.numel());
                dp.* = @as([*]const Q, @ptrCast(@alignCast(dst.ptr)))[0..n];
            },
        }
    }
    return 0;
}

// ------------------------------------------------------------------ bind ----

const PRE = "model.";

fn planLayer(p: *Plan, c: *const gqa_cfg.GqaCfg, L: i32, lw: *GqaLayerW, qk_wide: bool) void {
    const H: i64 = c.hidden;
    const qh: i64 = @as(i64, c.n_heads) * c.head_dim;
    const kvh: i64 = @as(i64, c.n_kv) * c.head_dim;

    reqw(p, &lw.in_norm, H, PRE ++ "layers.{d}.input_layernorm.weight", .{L});
    reqw(p, &lw.post_norm, H, PRE ++ "layers.{d}.post_attention_layernorm.weight", .{L});

    reqm(p, &lw.wq, &lw.attn_wdt, qh * H, PRE ++ "layers.{d}.self_attn.q_proj.weight", .{L});
    reqm(p, &lw.wk, &lw.attn_wdt, kvh * H, PRE ++ "layers.{d}.self_attn.k_proj.weight", .{L});
    reqm(p, &lw.wv, &lw.attn_wdt, kvh * H, PRE ++ "layers.{d}.self_attn.v_proj.weight", .{L});
    reqm(p, &lw.wo, &lw.attn_wdt, H * qh, PRE ++ "layers.{d}.self_attn.o_proj.weight", .{L});
    if (c.use_qk_norm) {
        const nw: i64 = if (qk_wide) qh else c.head_dim;
        reqw(p, &lw.q_norm, nw, PRE ++ "layers.{d}.self_attn.q_norm.weight", .{L});
        reqw(p, &lw.k_norm, nw, PRE ++ "layers.{d}.self_attn.k_norm.weight", .{L});
    }
}

fn planMoe(p: *Plan, c: *const gqa_cfg.GqaCfg, L: i32, lw: *GqaLayerW, experts: []GqaExpert, stream: bool) void {
    const H: i64 = c.hidden;
    const I: i64 = c.moe_inter;
    // Qwen3-MoE names the router mlp.gate; OLMoE names it mlp.router.
    // Emit the primary name; resolution falls back to the alias below.
    // Qwen3-MoE names the router mlp.gate; OLMoE names it mlp.router —
    // routerAliasFix below retries the alias before resolution fails.
    reqm(p, &lw.router, &lw.router_wdt, @as(i64, c.n_experts) * H, PRE ++ "layers.{d}.mlp.gate.weight", .{L});
    if (!stream) {
        for (experts, 0..) |*e, ei| {
            reqm(p, &e.gate, &lw.expert_wdt, I * H, PRE ++ "layers.{d}.mlp.experts.{d}.gate_proj.weight", .{ L, ei });
            reqm(p, &e.up, &lw.expert_wdt, I * H, PRE ++ "layers.{d}.mlp.experts.{d}.up_proj.weight", .{ L, ei });
            reqm(p, &e.down, &lw.expert_wdt, H * I, PRE ++ "layers.{d}.mlp.experts.{d}.down_proj.weight", .{ L, ei });
        }
    }
    if (c.shared_inter > 0) {
        // Assign the payload first so the req dests point into lw (stable
        // memory inside w.layers), never into a local.
        lw.shared_expert = .{};
        const se = &lw.shared_expert.?;
        const SI: i64 = c.shared_inter;
        reqm(p, &se.gate, &lw.expert_wdt, SI * H, PRE ++ "layers.{d}.mlp.shared_expert.gate_proj.weight", .{L});
        reqm(p, &se.up, &lw.expert_wdt, SI * H, PRE ++ "layers.{d}.mlp.shared_expert.up_proj.weight", .{L});
        reqm(p, &se.down, &lw.expert_wdt, H * SI, PRE ++ "layers.{d}.mlp.shared_expert.down_proj.weight", .{L});
        // The scalar shared-expert gate exists iff the checkpoint carries it
        // (qwen3_moe always does; an absent tensor means ungated).
        reqmo(p, &lw.shared_gate_w, &lw.expert_wdt, H, PRE ++ "layers.{d}.mlp.shared_expert_gate.weight", .{L});
    }
}

fn planDense(p: *Plan, c: *const gqa_cfg.GqaCfg, L: i32, lw: *GqaLayerW) void {
    const H: i64 = c.hidden;
    const I: i64 = c.dense_inter;
    reqm(p, &lw.dense_gate, &lw.dense_wdt, I * H, PRE ++ "layers.{d}.mlp.gate_proj.weight", .{L});
    reqm(p, &lw.dense_up, &lw.dense_wdt, I * H, PRE ++ "layers.{d}.mlp.up_proj.weight", .{L});
    reqm(p, &lw.dense_down, &lw.dense_wdt, H * I, PRE ++ "layers.{d}.mlp.down_proj.weight", .{L});
}

/// OLMoE names the router mlp.router.weight — fix up reqs that resolved
/// to nothing under the qwen3 spelling by retrying the alias. Operates on
/// the name buffers before resolution so it stays one pass.
fn routerAliasFix(p: *Plan, s: *const st.St) void {
    for (p.r.items) |*q| {
        if (q.dest != .mat) continue;
        if (!std.mem.endsWith(u8, q.nm(), ".mlp.gate.weight")) continue;
        if (s.find(q.nm()) != null) continue;
        var alt: [NameBuf]u8 = undefined;
        const base = q.nm();
        const suffix = ".mlp.gate.weight";
        const stem = base[0 .. base.len - suffix.len];
        const altname = std.fmt.bufPrint(&alt, "{s}.mlp.router.weight", .{stem}) catch continue;
        if (s.find(altname) == null) continue;
        @memcpy(q.name[0..altname.len], altname);
        q.name_len = altname.len;
    }
}

fn resolveStreamRefs(w: *GqaWeights, s: *const st.St) !usize {
    var max_bytes: usize = 0;
    for (w.layers, 0..) |*lw, li| {
        if (!lw.is_moe) continue;
        for (lw.experts, 0..) |*e, ei| {
            var name: [NameBuf]u8 = undefined;
            const l = std.fmt.bufPrint(&name, PRE ++ "layers.{d}.mlp.experts.{d}.gate_proj.weight", .{ li, ei }) catch return error.BadStructure;
            e.gate_t = s.find(l) orelse return error.BadStructure;
            const u = std.fmt.bufPrint(&name, PRE ++ "layers.{d}.mlp.experts.{d}.up_proj.weight", .{ li, ei }) catch return error.BadStructure;
            e.up_t = s.find(u) orelse return error.BadStructure;
            const d = std.fmt.bufPrint(&name, PRE ++ "layers.{d}.mlp.experts.{d}.down_proj.weight", .{ li, ei }) catch return error.BadStructure;
            e.down_t = s.find(d) orelse return error.BadStructure;
            max_bytes = @max(max_bytes, @as(usize, @intCast(e.gate_t.?.nbytes)));
            max_bytes = @max(max_bytes, @as(usize, @intCast(e.up_t.?.nbytes)));
            max_bytes = @max(max_bytes, @as(usize, @intCast(e.down_t.?.nbytes)));
            // Streamed matrices bypass reqm(), so publish their actual
            // checkpoint dtype explicitly; default .f32 would reinterpret
            // every bf16 payload as twice as many f32 values.
            lw.expert_wdt = switch (e.gate_t.?.dtype) {
                .bf16 => .bf16,
                .f32 => .f32,
                else => return error.BadStructure,
            };
        }
    }
    return max_bytes;
}

/// Load one streamed expert's three matrix payloads into reusable buffers.
pub fn loadStreamExpert(w: *GqaWeights, layer: usize, expert: usize, out: *GqaExpert) !void {
    if (!w.streamed_experts or w.stream_st == null) return error.InvalidValue;
    const src = &w.layers[layer].experts[expert];
    const tensors = [_]?*const st.Tensor{ src.gate_t, src.up_t, src.down_t };
    const dsts = [_]usize{ 0, w.stream_stride, w.stream_stride * 2 };
    for (tensors, dsts) |t, off| {
        const tensor = t orelse return error.BadStructure;
        const n: usize = @intCast(tensor.nbytes);
        if (n > w.stream_stride) return error.BadStructure;
        if (w.stream_st.?.read(tensor, w.stream_buf[off..][0..n]) != n) return error.Io;
    }
    out.* = .{
        .gate = @ptrCast(w.stream_buf.ptr),
        .up = @ptrCast(w.stream_buf.ptr + w.stream_stride),
        .down = @ptrCast(w.stream_buf.ptr + 2 * w.stream_stride),
    };
}

/// Load + bind all tensors for cfg. The returned GqaWeights owns a single
/// blob; caller frees via `deinit`.
pub fn bind(alloc: std.mem.Allocator, s: *const st.St, c: *const gqa_cfg.GqaCfg) !GqaWeights {
    return bindMode(alloc, s, c, false);
}

/// Bind non-expert matrices resident and retain safetensor references for
/// experts. This keeps a full classic-MoE checkpoint within memory: only one
/// expert's three bf16 matrices is materialized during an FFN call.
pub fn bindStreamed(alloc: std.mem.Allocator, s: *const st.St, c: *const gqa_cfg.GqaCfg) !GqaWeights {
    return bindMode(alloc, s, c, true);
}

fn bindMode(alloc: std.mem.Allocator, s: *const st.St, c: *const gqa_cfg.GqaCfg, stream: bool) !GqaWeights {
    var w = GqaWeights{};
    w.streamed_experts = stream;
    w.stream_st = if (stream) s else null;
    errdefer {
        if (w.blob.len > 0) alloc.free(w.blob);
        if (w.layer_mem.len > 0) alloc.free(w.layer_mem);
        if (w.expert_mem.len > 0) alloc.free(w.expert_mem);
        if (w.stream_buf.len > 0) alloc.free(w.stream_buf);
    }

    const nl: usize = @intCast(c.n_layers);
    const ne: usize = @intCast(c.n_experts);
    w.layers = try alloc.alloc(GqaLayerW, nl);
    w.layer_mem = w.layers;
    @memset(w.layers, .{});
    w.expert_mem = try alloc.alloc(GqaExpert, nl * ne);
    @memset(w.expert_mem, .{});

    var p = Plan{ .r = std.ArrayList(Req).init(alloc) };
    defer p.r.deinit();
    const H: i64 = c.hidden;
    const V: i64 = c.vocab;

    // qk-norm geometry is per-checkpoint: qwen3 ships [head_dim] per-head
    // gains; olmoe ships [n_heads*head_dim] and norms the whole q/k span at
    // once. Probe layer 0 — the shape is uniform within a checkpoint.
    if (c.use_qk_norm) {
        const hd: i64 = c.head_dim;
        const qh: i64 = @as(i64, c.n_heads) * c.head_dim;
        if (s.find(PRE ++ "layers.0.self_attn.q_norm.weight")) |t| {
            const n = t.numel();
            if (n == hd) {
                w.qk_norm_wide = false;
            } else if (n == qh) {
                w.qk_norm_wide = true;
            } else {
                std.debug.print("gqa_bind: q_norm numel {d} matches neither " ++
                    "per-head ({d}) nor full-span ({d})\n", .{ n, hd, qh });
                return error.BadStructure;
            }
        }
        // absent: resolution below reports it as a missing required tensor.
    }

    reqm(&p, &w.embed, &w.embed_wdt, V * H, PRE ++ "embed_tokens.weight", .{});
    reqw(&p, &w.final_norm, H, PRE ++ "norm.weight", .{});
    if (c.tie_embed) {
        w.lm_head = w.embed;
        w.lm_head_wdt = w.embed_wdt;
    } else {
        reqm(&p, &w.lm_head, &w.lm_head_wdt, V * H, "lm_head.weight", .{});
    }

    for (w.layers, 0..) |*lw, li| {
        const L: i32 = @intCast(li);
        planLayer(&p, c, L, lw, w.qk_norm_wide);
        lw.is_moe = c.isMoe(L);
        if (lw.is_moe) {
            lw.experts = w.expert_mem[li * ne .. (li + 1) * ne];
            planMoe(&p, c, L, lw, lw.experts, stream);
        } else {
            planDense(&p, c, L, lw);
        }
    }
    if (p.bad > 0) return error.BadStructure;

    routerAliasFix(&p, s);

    if (stream) {
        w.stream_stride = try resolveStreamRefs(&w, s);
        if (w.stream_stride == 0) return error.BadStructure;
        w.stream_buf = try alloc.alloc(u8, w.stream_stride * 3);
    }

    const total = planResolve(&p, s);
    if (total < 0) return error.BadStructure;

    w.blob = try alloc.alignedAlloc(u8, @alignOf(Q), @intCast(total));
    if (planLoad(alloc, &p, s, w.blob) != 0) return error.BadStructure;
    if (c.tie_embed) {
        w.lm_head = w.embed; // publish after embed was resolved
        w.lm_head_wdt = w.embed_wdt;
    }
    return w;
}

pub fn deinit(w: *GqaWeights, alloc: std.mem.Allocator) void {
    if (w.blob.len > 0) alloc.free(w.blob);
    if (w.layer_mem.len > 0) alloc.free(w.layer_mem);
    if (w.expert_mem.len > 0) alloc.free(w.expert_mem);
    if (w.stream_buf.len > 0) alloc.free(w.stream_buf);
    w.* = .{};
}

// ---------------------------------------------------------------- tests ----

test "bind refuses a store missing the contract tensors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = "{\"unrelated\":{\"dtype\":\"BF16\",\"shape\":[2],\"data_offsets\":[0,4]}}";
    var filebuf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&filebuf);
    fbs.writer().writeInt(u64, header.len, .little) catch unreachable;
    fbs.writer().writeAll(header) catch unreachable;
    fbs.writer().writeAll(&[_]u8{ 0, 0, 0, 0 }) catch unreachable;
    try tmp.dir.writeFile(.{ .sub_path = "x.safetensors", .data = fbs.getWritten() });
    const dpath = try tmp.dir.realpathAlloc(aa, ".");
    var s = try st.St.open(aa, dpath);
    defer s.close();
    const c = gqa_cfg.GqaCfg{
        .hidden = 4,
        .n_layers = 1,
        .vocab = 4,
        .n_heads = 1,
        .n_kv = 1,
        .head_dim = 4,
        .use_qk_norm = false,
        .n_experts = 2,
        .topk = 1,
        .moe_inter = 4,
        .dense_inter = 4,
    };
    try std.testing.expectError(error.BadStructure, bind(aa, &s, &c));
}
