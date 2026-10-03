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
};

/// One decoder layer: GQA attention + either MoE or dense MLP.
pub const GqaLayerW = struct {
    in_norm: QConst = &.{},
    post_norm: QConst = &.{},

    wq: ?*const anyopaque = null, // [n_heads*head_dim][hidden]
    wk: ?*const anyopaque = null, // [n_kv*head_dim][hidden]
    wv: ?*const anyopaque = null, // [n_kv*head_dim][hidden]
    wo: ?*const anyopaque = null, // [hidden][n_heads*head_dim]
    q_norm: QConst = &.{}, // [head_dim] — empty when use_qk_norm is off
    k_norm: QConst = &.{},
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

fn planLayer(p: *Plan, c: *const gqa_cfg.GqaCfg, L: i32, lw: *GqaLayerW) void {
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
        reqw(p, &lw.q_norm, c.head_dim, PRE ++ "layers.{d}.self_attn.q_norm.weight", .{L});
        reqw(p, &lw.k_norm, c.head_dim, PRE ++ "layers.{d}.self_attn.k_norm.weight", .{L});
    }
}

fn planMoe(p: *Plan, c: *const gqa_cfg.GqaCfg, L: i32, lw: *GqaLayerW, experts: []GqaExpert) void {
    const H: i64 = c.hidden;
    const I: i64 = c.moe_inter;
    // Qwen3-MoE names the router mlp.gate; OLMoE names it mlp.router.
    // Emit the primary name; resolution falls back to the alias below.
    // Qwen3-MoE names the router mlp.gate; OLMoE names it mlp.router —
    // routerAliasFix below retries the alias before resolution fails.
    reqm(p, &lw.router, &lw.router_wdt, @as(i64, c.n_experts) * H, PRE ++ "layers.{d}.mlp.gate.weight", .{L});
    for (experts, 0..) |*e, ei| {
        reqm(p, &e.gate, &lw.expert_wdt, I * H, PRE ++ "layers.{d}.mlp.experts.{d}.gate_proj.weight", .{ L, ei });
        reqm(p, &e.up, &lw.expert_wdt, I * H, PRE ++ "layers.{d}.mlp.experts.{d}.up_proj.weight", .{ L, ei });
        reqm(p, &e.down, &lw.expert_wdt, H * I, PRE ++ "layers.{d}.mlp.experts.{d}.down_proj.weight", .{ L, ei });
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

/// Load + bind all tensors for cfg. The returned GqaWeights owns a single
/// blob; caller frees via `deinit`.
pub fn bind(alloc: std.mem.Allocator, s: *const st.St, c: *const gqa_cfg.GqaCfg) !GqaWeights {
    var w = GqaWeights{};
    errdefer {
        if (w.blob.len > 0) alloc.free(w.blob);
        if (w.layer_mem.len > 0) alloc.free(w.layer_mem);
        if (w.expert_mem.len > 0) alloc.free(w.expert_mem);
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
        planLayer(&p, c, L, lw);
        lw.is_moe = c.isMoe(L);
        if (lw.is_moe) {
            lw.experts = w.expert_mem[li * ne .. (li + 1) * ne];
            planMoe(&p, c, L, lw, lw.experts);
        } else {
            planDense(&p, c, L, lw);
        }
    }
    if (p.bad > 0) return error.BadStructure;

    routerAliasFix(&p, s);

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
    w.* = .{};
}
