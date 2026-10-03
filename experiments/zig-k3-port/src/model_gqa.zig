//! model_gqa.zig — the generic GQA+MoE model runner (qwen3_moe / olmoe).
//! Parallel to model.zig, not a mutation of it: K3 keeps its KDA/MLA
//! engine; this file owns the classic transformer stack.
//!
//! Ownership contract mirrors model.forwardInc: the caller supplies h,
//! scratch, and the per-layer KV caches; nothing is allocated inside.
//! forward (prompt) is forwardInc at cached=0 — the causal write-then-
//! attend per position makes full and incremental paths the same code,
//! so incremental-vs-full parity holds by construction.
//!
//! HF dataflow per decoder layer (Qwen3MoeDecoderLayer / OlmoEDecoderLayer):
//!   h = h + attn(rmsnorm(h, in_norm))
//!   h = h + mlp(rmsnorm(h, post_norm))
//!   attn: q,k,v = W{x}·x; per-head RMSNorm(q,k); RoPE(q,k) at pos;
//!         causal GQA over the kv cache; o = Wo·attn
//!   mlp (MoE): router logits = W_gate·x; top-k of softmax probs;
//!         y = Σ_k w_k·expert_k(x) [+ shared_expert(x)]
//!   mlp (dense): y = W_down·(silu(W_gate·x) ⊙ W_up·x)
//! Head: logits = W_lm_head·rmsnorm(h_last, final_norm).

const std = @import("std");
const fp = @import("fixed_point");
const k3 = @import("k3");
const ops = @import("ops");
const gqa_cfg = @import("gqa_cfg");
const gqa_ops = @import("gqa_ops");
const gqa_attn = @import("gqa_attn");
const gqa_bind = @import("gqa_bind");
const model = @import("model");
const st = @import("st");
const json = @import("json");

pub const Q = k3.Q128;
pub const QSlice = []Q;
pub const QConst = k3.Q128Slice;
pub const GqaCfg = gqa_cfg.GqaCfg;
pub const GqaWeights = gqa_bind.GqaWeights;

const zero = Q.zero;
const one = Q.one;

/// Scratch layout offsets — one contiguous caller-owned q128 slab.
const Scratch = struct {
    x: QSlice, // [E]  normed input
    q: QSlice, // [nh*hd]
    kv: QSlice, // [2*nkv*hd] fresh k|v for this position
    att: QSlice, // [nh*hd] attention output
    y: QSlice, // [E]  mlp output accumulator
    tmp: QSlice, // [E]  one expert's output
    ffn: QSlice, // [2*imax] gate|up workspace
    rlog: QSlice, // [n_experts] router logits
    rprob: QSlice, // [n_experts] router prob scratch
    score: QSlice, // [cap] attention scores
};

/// Total q128 scratch elements a forward call needs.
pub fn scratchNeed(c: *const GqaCfg, cap: usize) usize {
    const E: usize = @intCast(c.hidden);
    const qh: usize = @intCast(c.n_heads * c.head_dim);
    const kvh: usize = @intCast(c.n_kv * c.head_dim);
    const imax: usize = @intCast(@max(@max(c.moe_inter, c.dense_inter), c.shared_inter));
    return E + qh + 2 * kvh + qh + E + E + 2 * imax + 2 * @as(usize, @intCast(c.n_experts)) + cap;
}

fn scratchMap(c: *const GqaCfg, cap: usize, s: QSlice) Scratch {
    const E: usize = @intCast(c.hidden);
    const qh: usize = @intCast(c.n_heads * c.head_dim);
    const kvh: usize = @intCast(c.n_kv * c.head_dim);
    const imax: usize = @intCast(@max(@max(c.moe_inter, c.dense_inter), c.shared_inter));
    const ne: usize = @intCast(c.n_experts);
    var off: usize = 0;
    var sc: Scratch = undefined;
    sc.x = s[off..][0..E];
    off += E;
    sc.q = s[off..][0..qh];
    off += qh;
    sc.kv = s[off..][0 .. 2 * kvh];
    off += 2 * kvh;
    sc.att = s[off..][0..qh];
    off += qh;
    sc.y = s[off..][0..E];
    off += E;
    sc.tmp = s[off..][0..E];
    off += E;
    sc.ffn = s[off..][0 .. 2 * imax];
    off += 2 * imax;
    sc.rlog = s[off..][0..ne];
    off += ne;
    sc.rprob = s[off..][0..ne];
    off += ne;
    sc.score = s[off..][0..cap];
    return sc;
}

/// Gather one embedding row into q128 h. embed stays in checkpoint dtype
/// (bf16 released, f32 fixture) — conversion is exact either way.
fn embedRow(dst: QSlice, embed: ?*const anyopaque, wdt: k3.Wdt, id: usize, E: usize) !void {
    switch (wdt) {
        .bf16 => {
            const row: [*]const u16 = @ptrCast(@alignCast(embed.?));
            for (0..E) |i| dst[i] = try k3.q128FromBf16(row[id * E + i]);
        },
        .f32 => {
            const row: [*]const u32 = @ptrCast(@alignCast(embed.?));
            for (0..E) |i| dst[i] = try Q.fromF32Bits(row[id * E + i]);
        },
        else => return error.InvalidValue,
    }
}

/// h[pos] += W·x for every row — the residual update. W is [E][E_in].
fn residualAdd(h: QSlice, y: QConst) !void {
    for (h, y) |*o, v| o.* = try o.*.add(v);
}

/// One position of the attention block: project, qk-norm, rope, cache
/// append, causal attend, out-project, residual.
fn attnPos(
    lw: *const gqa_bind.GqaLayerW,
    c: *const GqaCfg,
    qk_wide: bool, // olmoe: one RMS over the whole q/k span; qwen3: per-head
    htok: QSlice, // [E] residual stream for this position
    pos: usize,
    kc: QSlice,
    vc: QSlice,
    sc: *const Scratch,
) !void {
    const E: usize = @intCast(c.hidden);
    const nh: usize = @intCast(c.n_heads);
    const nkv: usize = @intCast(c.n_kv);
    const hd: usize = @intCast(c.head_dim);
    const qh = nh * hd;
    const kvh = nkv * hd;
    const rot = c.rotDim();

    try ops.rmsnorm(sc.x, htok, lw.in_norm, c.rms_eps);
    try ops.mmw(sc.q, sc.x, lw.wq, lw.attn_wdt, E, qh);
    const kf = sc.kv[0..kvh];
    const vf = sc.kv[kvh..][0..kvh];
    try ops.mmw(kf, sc.x, lw.wk, lw.attn_wdt, E, kvh);
    try ops.mmw(vf, sc.x, lw.wv, lw.attn_wdt, E, kvh);

    if (c.use_qk_norm) {
        if (qk_wide) {
            try ops.rmsnorm(sc.q, sc.q, lw.q_norm, c.rms_eps);
            try ops.rmsnorm(kf, kf, lw.k_norm, c.rms_eps);
        } else {
            try gqa_ops.qkNorm(sc.q, lw.q_norm, c.rms_eps, hd);
            try gqa_ops.qkNorm(kf, lw.k_norm, c.rms_eps, hd);
        }
    }
    for (0..nh) |hi| try gqa_ops.ropeApply(sc.q[hi * hd ..][0..hd], pos, c.rope_theta, rot);
    for (0..nkv) |hi| try gqa_ops.ropeApply(kf[hi * hd ..][0..hd], pos, c.rope_theta, rot);

    // append this position, then attend over [0, pos]
    @memcpy(kc[pos * kvh ..][0..kvh], kf);
    @memcpy(vc[pos * kvh ..][0..kvh], vf);
    try gqa_attn.gqaAttnStep(sc.att, sc.q, kc, vc, pos, nh, nkv, hd, sc.score);

    try ops.mmw(sc.tmp, sc.att, lw.wo, lw.attn_wdt, qh, E);
    try residualAdd(htok, sc.tmp);
}

/// One position of the MLP block (MoE or dense) + residual.
fn mlpPos(
    w: *gqa_bind.GqaWeights,
    layer: usize,
    lw: *const gqa_bind.GqaLayerW,
    c: *const GqaCfg,
    htok: QSlice,
    sc: *const Scratch,
) !void {
    const E: usize = @intCast(c.hidden);
    try ops.rmsnorm(sc.x, htok, lw.post_norm, c.rms_eps);

    if (lw.is_moe) {
        const ne: usize = @intCast(c.n_experts);
        try ops.mmw(sc.rlog, sc.x, lw.router, lw.router_wdt, E, ne);
        var idx: [64]usize = undefined; // topk <= 64 on every shipped config
        const tk: usize = @intCast(c.topk);
        var wt: [64]Q = undefined;
        try gqa_ops.routerTopK(idx[0..tk], wt[0..tk], sc.rlog, tk, c.router, c.norm_topk, c.routed_scale, sc.rprob);

        @memset(sc.y, zero);
        const I: usize = @intCast(c.moe_inter);
        for (0..tk) |k| {
            var streamed: gqa_bind.GqaExpert = .{};
            const e = if (w.streamed_experts) blk: {
                try gqa_bind.loadStreamExpert(w, layer, idx[k], &streamed);
                break :blk &streamed;
            } else &lw.experts[idx[k]];
            try gqa_ops.expertFfn(sc.tmp, sc.x, e.gate, e.up, e.down, lw.expert_wdt, E, I, sc.ffn);
            for (sc.y, sc.tmp) |*o, v| o.* = try o.*.add(try wt[k].mul(v));
        }
        if (lw.shared_expert) |se| {
            const SI: usize = @intCast(c.shared_inter);
            try gqa_ops.expertFfn(sc.tmp, sc.x, se.gate, se.up, se.down, lw.expert_wdt, E, SI, sc.ffn);
            // Qwen3-MoE gates the shared expert with sigmoid(gate_w·x) — a
            // [1][hidden] row producing one scalar per token.
            var gate = one;
            if (lw.shared_gate_w) |sgw| {
                try ops.mmw(sc.rprob[0..1], sc.x, sgw, lw.expert_wdt, E, 1);
                gate = try ops.sigmoidQ(sc.rprob[0]);
            }
            for (sc.y, sc.tmp) |*o, v| o.* = try o.*.add(try gate.mul(v));
        }
    } else {
        const I: usize = @intCast(c.dense_inter);
        try gqa_ops.expertFfn(sc.y, sc.x, lw.dense_gate, lw.dense_up, lw.dense_down, lw.dense_wdt, E, I, sc.ffn);
    }
    try residualAdd(htok, sc.y);
}

/// Full forward: logits[t*vocab..] for every position. Same call path as
/// forwardInc with cached=0 — kept as a separate entry because callers
/// (oracle parity, prompt eval) want all-position logits.
pub fn forward(
    w: *GqaWeights,
    c: *const GqaCfg,
    ids: []const usize,
    logits: QSlice, // [T][vocab]
    h: QSlice, // [T][hidden]
    scratch: QSlice,
    kc: []QSlice, // per-layer [cap][nkv*hd]
    vc: []QSlice,
    cap: usize,
) !void {
    try inc(w, c, ids, 0, h, scratch, kc, vc, cap, logits, true);
}

/// Incremental decode: nT new tokens whose absolute positions start at
/// `cached`. Logits for the last new position only.
pub fn forwardInc(
    w: *GqaWeights,
    c: *const GqaCfg,
    ids: []const usize, // the nT new ids
    cached: usize,
    logits: QSlice, // [vocab]
    h: QSlice, // [nT][hidden]
    scratch: QSlice,
    kc: []QSlice,
    vc: []QSlice,
    cap: usize,
) !void {
    try inc(w, c, ids, cached, h, scratch, kc, vc, cap, logits, false);
}

fn inc(
    w: *GqaWeights,
    c: *const GqaCfg,
    ids: []const usize,
    cached: usize,
    h: QSlice,
    scratch: QSlice,
    kc: []QSlice,
    vc: []QSlice,
    cap: usize,
    logits: QSlice,
    all_logits: bool,
) !void {
    const E: usize = @intCast(c.hidden);
    const V: usize = @intCast(c.vocab);
    const nT = ids.len;
    if (cached + nT > cap) return error.InvalidValue;
    const sc = scratchMap(c, cap, scratch);

    for (0..nT) |t| {
        try embedRow(h[t * E ..][0..E], w.embed, w.embed_wdt, ids[t], E);
    }
    for (w.layers, 0..) |*lw, L| {
        for (0..nT) |t| {
            try attnPos(lw, c, w.qk_norm_wide, h[t * E ..][0..E], cached + t, kc[L], vc[L], &sc);
            try mlpPos(w, L, lw, c, h[t * E ..][0..E], &sc);
        }
    }

    const nrm = sc.x;
    const ts: usize = if (all_logits) nT else nT - 1;
    for (ts..nT) |t| {
        try ops.rmsnorm(nrm, h[t * E ..][0..E], w.final_norm, c.rms_eps);
        const dst = if (all_logits) logits[t * V ..][0..V] else logits[0..V];
        try ops.mmw(dst, nrm, w.lm_head, w.lm_head_wdt, E, V);
    }
}

pub fn argmax(v: []const Q) usize {
    return model.argmax(v);
}

// ---------------------------------------------------------------- tests ----

test "scratchMap covers scratchNeed" {
    const c = GqaCfg{
        .hidden = 64,
        .n_heads = 4,
        .n_kv = 2,
        .head_dim = 16,
        .n_experts = 8,
        .topk = 2,
        .moe_inter = 32,
        .dense_inter = 48,
        .shared_inter = 0,
    };
    const cap = 16;
    var buf = [_]Q{zero} ** 8192;
    const need = scratchNeed(&c, cap);
    try std.testing.expect(need <= buf.len);
    const sc = scratchMap(&c, cap, buf[0..need]);
    try std.testing.expectEqual(@as(usize, 64), sc.x.len);
    try std.testing.expectEqual(cap, sc.score.len);
}

// THE PHASE-A GATE: run the torch-generated tiny qwen3_moe fixture
// (tests/fixtures/gqa_tiny, written by sidecar/qwen3_moe_ref.py) through
// the q128 stack and hold the C-parity contract: logits within 0.01,
// argmax exact, generated ids exact.
test "gqa oracle: tiny qwen3_moe fixture end-to-end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = "tests/fixtures/gqa_tiny";

    var c = GqaCfg{};
    var diag = gqa_cfg.Diag{};
    gqa_cfg.loadFile(&c, aa, dir ++ "/config.json", &diag) catch {
        std.debug.print("{s}\n", .{diag.buf.constSlice()});
        return error.BadStructure;
    };

    var s = try st.St.open(aa, dir);
    defer s.close();
    var w = try gqa_bind.bind(std.testing.allocator, &s, &c);
    defer gqa_bind.deinit(&w, std.testing.allocator);

    // expected.json: {prompt: [ids], logits: [vocab f64], gen_ids: [N]}
    const etxt = try std.fs.cwd().readFileAlloc(aa, dir ++ "/expected.json", 1 << 24);
    const root = try json.parse(aa, etxt);
    const exp_logits = json.get(root, "logits").?;
    const prompt_v = json.get(root, "prompt").?;
    const gen_v = json.get(root, "gen_ids").?;
    const np = prompt_v.arr.len;
    const ngen = gen_v.arr.len;
    const V: usize = @intCast(c.vocab);
    try std.testing.expectEqual(V, exp_logits.arr.len);

    const E: usize = @intCast(c.hidden);
    const cap = np + ngen + 1;
    const kvh: usize = @intCast(c.n_kv * c.head_dim);
    const nl: usize = @intCast(c.n_layers);

    const h = try std.testing.allocator.alloc(Q, cap * E);
    defer std.testing.allocator.free(h);
    const scratch = try std.testing.allocator.alloc(Q, scratchNeed(&c, cap));
    defer std.testing.allocator.free(scratch);
    const kcb = try std.testing.allocator.alloc(Q, nl * cap * kvh);
    defer std.testing.allocator.free(kcb);
    const vcb = try std.testing.allocator.alloc(Q, nl * cap * kvh);
    defer std.testing.allocator.free(vcb);
    const kc = try std.testing.allocator.alloc([]Q, nl);
    defer std.testing.allocator.free(kc);
    const vc = try std.testing.allocator.alloc([]Q, nl);
    defer std.testing.allocator.free(vc);
    for (0..nl) |L| {
        kc[L] = kcb[L * cap * kvh ..][0 .. cap * kvh];
        vc[L] = vcb[L * cap * kvh ..][0 .. cap * kvh];
    }
    const logits = try std.testing.allocator.alloc(Q, V);
    defer std.testing.allocator.free(logits);
    const idsbuf = try std.testing.allocator.alloc(usize, cap);
    defer std.testing.allocator.free(idsbuf);
    for (prompt_v.arr, 0..) |v, i| idsbuf[i] = @intCast(try v.asInt());

    // prompt eval
    try forwardInc(&w, &c, idsbuf[0..np], 0, logits, h[0 .. np * E], scratch, kc, vc, cap);
    var worst: f64 = 0;
    for (exp_logits.arr, 0..) |v, i| {
        const d = @abs(logits[i].toF64() - try v.asF64());
        if (d > worst) worst = d;
    }
    if (worst > 0.01) {
        std.debug.print("gqa oracle: worst logit deviation {d}\n", .{worst});
        return error.TestFailed;
    }
    // argmax + greedy chain: every generated id must match the oracle
    var next = argmax(logits);
    var cur = np;
    for (0..ngen) |gi| {
        const want: usize = @intCast(try gen_v.arr[gi].asInt());
        try std.testing.expectEqual(want, next);
        idsbuf[0] = next;
        try forwardInc(&w, &c, idsbuf[0..1], cur, logits, h[0..E], scratch, kc, vc, cap);
        next = argmax(logits);
        cur += 1;
    }
}
