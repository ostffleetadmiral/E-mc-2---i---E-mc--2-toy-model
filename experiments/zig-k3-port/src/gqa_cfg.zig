//! gqa_cfg.zig — strict HF-style config reader for the generic GQA+MoE
//! architecture family (qwen3_moe, olmoe; qwen3_next/qwen3_5_moe parse but
//! stay gated until the DeltaNet phase lands).
//!
//! Same law as cfg.zig: AN ABSENT REQUIRED FIELD IS AN ERROR, NEVER A
//! DEFAULT. Missing keys are collected and reported together — a config we
//! cannot fully understand would silently produce a different model.
//!
//! Llama4 fields are accepted (parse) but the extra attention machinery they
//! enable (chunked attention, interleaved NoPE, temperature tuning) is
//! refused: nonzero values are an error, not a silent skip.

const std = @import("std");
const json = @import("json");
const fp = @import("fixed_point");

pub const Error = error{
    MissingFields,
    BadStructure,
    UnsupportedFeature,
    OutOfMemory,
    BadNumber,
};

pub const Diag = struct {
    buf: std.BoundedArray(u8, 4096) = .{},
    missing: std.BoundedArray([]const u8, 40) = .{},
    nmissing: u32 = 0,

    pub fn writer(self: *Diag) std.BoundedArray(u8, 4096).Writer {
        return self.buf.writer();
    }
};

pub const ModelType = enum { qwen3_moe, olmoe, qwen3_next, qwen3_5_moe };
pub const RouterMode = enum { softmax, sigmoid_topk };
pub const HybridLayer = enum { linear_attention, full_attention };

pub const GqaCfg = struct {
    model_type: ModelType = .qwen3_moe,

    hidden: i32 = 0,
    n_layers: i32 = 0,
    vocab: i32 = 0,
    rms_eps: fp.Q128_128 = .{ .raw = 0 },
    max_pos: i32 = 0,

    n_heads: i32 = 0,
    n_kv: i32 = 0,
    head_dim: i32 = 0, // explicit on qwen3; olmoe derives hidden/n_heads
    rope_theta: fp.Q128_128 = .{ .raw = 0 },
    partial_rotary: fp.Q128_128 = .{ .raw = 1 << 128 }, // 1.0 = full
    use_qk_norm: bool = true,

    n_experts: i32 = 0,
    topk: i32 = 0,
    moe_inter: i32 = 0,
    shared_inter: i32 = 0, // 0 = no shared expert (olmoe)
    shared_gate: bool = false, // olmoe lacks shared_expert_gate
    norm_topk: bool = false,
    router: RouterMode = .softmax,
    routed_scale: fp.Q128_128 = .{ .raw = 1 << 128 },

    dense_inter: i32 = 0,
    first_dense: i32 = 0,
    sparse_step: i32 = 1,
    mlp_only: [MAX_LAYERS]i32 = std.mem.zeroes([MAX_LAYERS]i32),
    n_mlp_only: i32 = 0,

    tie_embed: bool = false,

    pub const MAX_LAYERS = 128;

    /// MoE layer iff not dense. HF rule (Qwen3Moe / OLMoE):
    ///   sparse = l >= first_dense and l % sparse_step == 0 and l !in mlp_only
    pub fn isMoe(c: *const GqaCfg, layer: i32) bool {
        if (layer < c.first_dense) return false;
        if (c.sparse_step > 0 and @mod(layer, c.sparse_step) != 0) return false;
        for (0..@intCast(c.n_mlp_only)) |i| {
            if (c.mlp_only[i] == layer) return false;
        }
        return true;
    }

    /// Rotary width in elements: head_dim * partial_rotary, rounded to even
    /// (HF requires the factor to keep head_dim*factor even).
    pub fn rotDim(c: *const GqaCfg) usize {
        const hd: i64 = c.head_dim;
        // partial_rotary is a small dyadic in practice (1.0, 0.25): multiply
        // in q128 then truncate — exact for the shipped values.
        const num: i256 = @as(i256, hd) * c.partial_rotary.raw;
        return @intCast(num >> 128);
    }
};

pub const VisionCfg = struct {
    depth: i32 = 0,
    hidden: i32 = 0,
    intermediate: i32 = 0,
    heads: i32 = 0,
    channels: i32 = 0,
    patch: i32 = 0,
    temporal_patch: i32 = 0,
    spatial_merge: i32 = 0,
    positions: i32 = 0,
    output_hidden: i32 = 0,
    hidden_act_gelu_tanh: bool = false,
    rope_theta: fp.Q128_128 = .{ .raw = 0 },
    image_token: i32 = 0,
    video_token: i32 = 0,
    vision_start: i32 = 0,
    vision_end: i32 = 0,
};

pub const Qwen35Cfg = struct {
    text: GqaCfg = .{},
    vision: VisionCfg = .{},
    layers: [GqaCfg.MAX_LAYERS]HybridLayer = [_]HybridLayer{.linear_attention} ** GqaCfg.MAX_LAYERS,
    n_layers: usize = 0,
    linear_key_heads: i32 = 0,
    linear_value_heads: i32 = 0,
    linear_key_dim: i32 = 0,
    linear_value_dim: i32 = 0,
    conv_kernel: i32 = 0,
    output_gate: bool = false,
    mrope: [3]i32 = .{ 0, 0, 0 },
    mrope_interleaved: bool = false,

    pub fn isLinear(c: *const Qwen35Cfg, layer: usize) bool {
        return c.layers[layer] == .linear_attention;
    }
};

const Src = struct {
    txt: ?*const json.Value, // text_config (multimodal wraps) or null
    root: *const json.Value,
    diag: *Diag,

    fn find(s: *const Src, primary: []const u8, alias: ?[]const u8) ?*const json.Value {
        const objs = [2]?*const json.Value{ s.txt, s.root };
        const names = [2]?[]const u8{ primary, alias };
        for (objs) |o| {
            const obj = o orelse continue;
            for (names) |nm| {
                const name = nm orelse continue;
                if (json.get(obj, name)) |v| return v;
            }
        }
        return null;
    }

    fn nested(s: *const Src, parent: []const u8, key: []const u8) ?*const json.Value {
        const p = s.find(parent, null) orelse return null;
        return json.get(p, key);
    }

    fn miss(s: *Src, name: []const u8) void {
        if (s.diag.missing.len < 40) s.diag.missing.append(name) catch {};
        s.diag.nmissing += 1;
    }

    fn i(s: *Src, primary: []const u8, alias: ?[]const u8) i32 {
        const v = s.find(primary, alias) orelse {
            s.miss(primary);
            return 0;
        };
        const n = v.asInt() catch {
            s.miss(primary);
            return 0;
        };
        return std.math.cast(i32, n) orelse {
            s.miss(primary);
            return 0;
        };
    }

    fn f(s: *Src, primary: []const u8, alias: ?[]const u8) fp.Q128_128 {
        const v = s.find(primary, alias) orelse {
            s.miss(primary);
            return .{ .raw = 0 };
        };
        return v.asQ128() catch {
            s.miss(primary);
            return .{ .raw = 0 };
        };
    }

    fn b(s: *Src, primary: []const u8, alias: ?[]const u8, dflt: bool) bool {
        const v = s.find(primary, alias) orelse return dflt;
        return switch (v.*) {
            .bool_v => |bv| bv,
            .num => (v.asInt() catch return dflt) != 0,
            else => dflt,
        };
    }

    /// Optional int with a real default.
    fn oi(s: *Src, primary: []const u8, alias: ?[]const u8, dflt: i32) i32 {
        const v = s.find(primary, alias) orelse return dflt;
        const n = v.asInt() catch return dflt;
        return std.math.cast(i32, n) orelse dflt;
    }

    /// Optional float with a real default.
    fn of(s: *Src, primary: []const u8, dflt: fp.Q128_128) fp.Q128_128 {
        const v = s.find(primary, null) orelse return dflt;
        return v.asQ128() catch dflt;
    }

    /// Optional int array into out[]; returns count.
    fn arr(s: *Src, name: []const u8, out: []i32) usize {
        const v = s.find(name, null) orelse return 0;
        if (v.* != .arr) return 0;
        var n: usize = 0;
        for (v.arr) |item| {
            if (n >= out.len) break;
            const k = item.asInt() catch continue;
            out[n] = std.math.cast(i32, k) orelse continue;
            n += 1;
        }
        return n;
    }
};

/// Load the HF config object into c. `root` is the document root; for
/// multimodal wraps (qwen3_5_moe) the text fields live under "text_config".
pub fn load(c: *GqaCfg, root: *const json.Value, whence: []const u8, diag: *Diag) Error!void {
    c.* = .{};
    diag.buf.len = 0;
    diag.missing.len = 0;
    diag.nmissing = 0;

    var s = Src{ .root = root, .txt = null, .diag = diag };
    // model_type may sit at root or inside text_config.
    var mt = s.find("model_type", null);
    var mt_str: []const u8 = "";
    if (mt) |v| if (v.* == .str) {
        mt_str = v.str;
    };
    if (mt_str.len == 0 and root.* == .obj) {
        if (json.get(root, "text_config")) |tc| {
            s.txt = tc;
            mt = s.find("model_type", null);
            if (mt) |v| if (v.* == .str) {
                mt_str = v.str;
            };
        }
    } else if (root.* == .obj) {
        // Text-only configs still may carry a text_config; look anyway so
        // fields can resolve from either level.
        s.txt = json.get(root, "text_config");
    }
    if (mt_str.len == 0) {
        s.miss("model_type");
    } else if (std.mem.eql(u8, mt_str, "qwen3_moe")) {
        c.model_type = .qwen3_moe;
    } else if (std.mem.eql(u8, mt_str, "olmoe")) {
        c.model_type = .olmoe;
    } else if (std.mem.eql(u8, mt_str, "qwen3_next")) {
        c.model_type = .qwen3_next;
    } else if (std.mem.eql(u8, mt_str, "qwen3_5_moe")) {
        c.model_type = .qwen3_5_moe;
    } else if (std.mem.eql(u8, mt_str, "llama4")) {
        diag.writer().print("gqa_cfg: {s}: model_type llama4 needs chunked/interleaved " ++
            "attention — unsupported on this build\n", .{whence}) catch {};
        return error.UnsupportedFeature;
    } else {
        diag.writer().print("gqa_cfg: {s}: model_type \"{s}\" is not a supported " ++
            "GQA+MoE architecture\n", .{ whence, mt_str }) catch {};
        return error.UnsupportedFeature;
    }

    // Phase-B families parse their shared GQA+MoE fields but the DeltaNet /
    // hybrid layer machinery is not built yet — refuse cleanly.
    if (c.model_type == .qwen3_next or c.model_type == .qwen3_5_moe) {
        diag.writer().print("gqa_cfg: {s}: {s} is a Gated-DeltaNet hybrid — " ++
            "supported in phase B, not this build\n", .{ whence, mt_str }) catch {};
        return error.UnsupportedFeature;
    }

    c.hidden = s.i("hidden_size", null);
    c.n_layers = s.i("num_hidden_layers", null);
    c.vocab = s.i("vocab_size", null);
    // rms_norm_eps has a published HF default per model_type (OlmoeConfig
    // 1e-5, Qwen3MoeConfig 1e-6). Using the documented default for an absent
    // field is schema, not guesswork — still noted in the diagnostic.
    if (s.find("rms_norm_eps", null) == null) {
        c.rms_eps = switch (c.model_type) {
            .olmoe => fp.Q128_128.fromInt(1).div(fp.Q128_128.fromInt(100000)) catch .{ .raw = 0 },
            else => fp.Q128_128.fromInt(1).div(fp.Q128_128.fromInt(1000000)) catch .{ .raw = 0 },
        };
        diag.writer().print("gqa_cfg: note: rms_norm_eps absent, using the HF-documented " ++
            "{s} default\n", .{mt_str}) catch {};
    } else {
        c.rms_eps = s.f("rms_norm_eps", null);
    }
    c.max_pos = s.i("max_position_embeddings", null);

    c.n_heads = s.i("num_attention_heads", null);
    c.n_kv = s.i("num_key_value_heads", null);
    // qwen3 ships explicit head_dim; olmoe derives it (hidden/n_heads).
    const hd = s.find("head_dim", null);
    if (hd != null) {
        c.head_dim = s.i("head_dim", null);
    } else if (c.n_heads > 0) {
        c.head_dim = @divTrunc(c.hidden, c.n_heads);
    } else {
        s.miss("head_dim");
    }
    c.rope_theta = s.f("rope_theta", null);
    c.partial_rotary = s.of("partial_rotary_factor", .{ .raw = @as(i256, 1) << 128 });
    c.use_qk_norm = s.b("use_qk_norm", "qk_norm", switch (c.model_type) {
        .qwen3_moe, .qwen3_next, .qwen3_5_moe => true,
        .olmoe => true, // olmoe ships q_norm/k_norm weights
    });

    c.n_experts = s.i("num_experts", "num_local_experts");
    c.topk = s.i("num_experts_per_tok", "num_experts_per_token");
    // Qwen3-MoE ships moe_intermediate_size; OLMoE reuses intermediate_size
    // for the expert FFN (it has no dense MLP). Try the specific name first.
    if (s.find("moe_intermediate_size", null) != null) {
        c.moe_inter = s.i("moe_intermediate_size", null);
    } else if (s.find("intermediate_size", null) != null) {
        diag.writer().print("gqa_cfg: note: moe_intermediate_size absent, using " ++
            "intermediate_size ({s} schema)\n", .{mt_str}) catch {};
        c.moe_inter = s.i("intermediate_size", null);
    } else {
        c.moe_inter = s.i("moe_intermediate_size", null);
    }
    c.shared_inter = s.oi("shared_expert_intermediate_size", null, 0);
    c.shared_gate = s.b("shared_expert_gate", null, c.shared_inter > 0 and c.model_type == .qwen3_moe);
    c.norm_topk = s.b("norm_topk_prob", null, c.model_type == .olmoe);
    c.router = .softmax;
    c.routed_scale = s.of("routed_scaling_factor", .{ .raw = @as(i256, 1) << 128 });

    c.dense_inter = s.i("intermediate_size", null);
    c.first_dense = s.oi("first_k_dense_replace", "first_k_dense", 0);
    c.sparse_step = s.oi("decoder_sparse_step", null, 1);
    var mlp_only: [GqaCfg.MAX_LAYERS]i32 = std.mem.zeroes([GqaCfg.MAX_LAYERS]i32);
    const nm = s.arr("mlp_only_layers", mlp_only[0..]);
    c.mlp_only = mlp_only;
    c.n_mlp_only = @intCast(nm);

    c.tie_embed = s.b("tie_word_embeddings", null, false);

    if (diag.nmissing != 0) {
        const w = diag.writer();
        w.print("gqa_cfg: {s} is missing {d} required field(s):\n", .{ whence, diag.nmissing }) catch {};
        for (diag.missing.constSlice()) |m| w.print("    {s}\n", .{m}) catch {};
        w.print("  refusing to substitute defaults: a config this reader cannot\n" ++
            "  fully understand would silently produce a DIFFERENT model.\n", .{}) catch {};
        return error.MissingFields;
    }

    const w = diag.writer();
    if (c.hidden <= 0 or c.n_layers <= 0 or c.vocab <= 0) {
        w.print("gqa_cfg: {s} has non-positive hidden/layers/vocab\n", .{whence}) catch {};
        return error.BadStructure;
    }
    if (c.n_kv <= 0 or c.n_heads <= 0 or @mod(c.n_heads, c.n_kv) != 0) {
        w.print("gqa_cfg: {s} needs num_attention_heads divisible by num_key_value_heads\n", .{whence}) catch {};
        return error.BadStructure;
    }
    if (c.head_dim <= 0 or (c.head_dim * c.n_heads != c.hidden)) {
        // HF allows head_dim*n_heads != hidden (Qwen3: 16*128=2048==2048 ok;
        // some variants pad). Refuse only when head_dim is nonsense, else
        // warn through the structural check on q_proj shape at bind time.
        if (c.head_dim <= 0) {
            w.print("gqa_cfg: {s} has non-positive head_dim\n", .{whence}) catch {};
            return error.BadStructure;
        }
    }
    if (c.topk <= 0 or c.topk > c.n_experts) {
        w.print("gqa_cfg: {s} selects top-{d} of {d} experts\n", .{ whence, c.topk, c.n_experts }) catch {};
        return error.BadStructure;
    }
    // Llama4-style attention knobs: parsed fields that must be absent/zero.
    if (s.find("attention_chunk_size", null)) |v| {
        const n = v.asInt() catch 0;
        if (n != 0) {
            w.print("gqa_cfg: {s} sets attention_chunk_size — chunked attention " ++
                "unsupported on this build\n", .{whence}) catch {};
            return error.UnsupportedFeature;
        }
    }
    if (s.find("no_rope_layer_interval", null)) |v| {
        const n = v.asInt() catch 0;
        if (n != 0) {
            w.print("gqa_cfg: {s} sets no_rope_layer_interval — interleaved-NoPE " ++
                "attention unsupported on this build\n", .{whence}) catch {};
            return error.UnsupportedFeature;
        }
    }
    // hidden_act must be silu — any other activation silently produces a
    // different model.
    if (s.find("hidden_act", null)) |v| {
        if (v.* != .str or !std.mem.eql(u8, v.str, "silu")) {
            w.print("gqa_cfg: {s}: hidden_act must be \"silu\"\n", .{whence}) catch {};
            return error.UnsupportedFeature;
        }
    }
    // rope_scaling: absent/null/default type is fine; any real scaling
    // recipe (linear, yarn, llama3, dynamic) changes position encoding.
    if (s.find("rope_scaling", null)) |v| {
        if (v.* == .obj) {
            const rt = json.get(v, "type") orelse json.get(v, "rope_type");
            const ok = rt == null or (rt.?.* == .str and std.mem.eql(u8, rt.?.str, "default"));
            if (!ok) {
                w.print("gqa_cfg: {s}: rope_scaling with non-default type unsupported\n", .{whence}) catch {};
                return error.UnsupportedFeature;
            }
        } else if (v.* == .num) {
            const n = v.asInt() catch 0;
            if (n != 0) {
                w.print("gqa_cfg: {s}: numeric rope_scaling unsupported\n", .{whence}) catch {};
                return error.UnsupportedFeature;
            }
        }
    }
    // clip_qkv (olmoe carries the key, null in the released model): a clamp
    // on q/k/v projections we do not implement.
    if (s.find("clip_qkv", null)) |v| {
        if (v.* == .num) {
            const n = v.asF64() catch 0;
            if (n != 0) {
                w.print("gqa_cfg: {s}: clip_qkv unsupported\n", .{whence}) catch {};
                return error.UnsupportedFeature;
            }
        }
    }
    // attention_bias: false on qwen3_moe/olmoe; true would need bias adds.
    if (s.b("attention_bias", null, false)) {
        w.print("gqa_cfg: {s}: attention_bias=true unsupported\n", .{whence}) catch {};
        return error.UnsupportedFeature;
    }
    return;
}

/// Read and parse a config file, then load it. The arena must outlive the
/// returned GqaCfg's use.
pub fn loadFile(c: *GqaCfg, arena: std.mem.Allocator, path: []const u8, diag: *Diag) !void {
    const txt = std.fs.cwd().readFileAlloc(arena, path, 1 << 28) catch |e| {
        diag.writer().print("{s}: {s}\n", .{ path, @errorName(e) }) catch {};
        return error.BadStructure;
    };
    const root = json.parse(arena, txt) catch {
        diag.writer().print("{s}: not valid JSON\n", .{path}) catch {};
        return error.BadStructure;
    };
    return load(c, root, path, diag);
}

fn jsonInt(o: *const json.Value, key: []const u8) !i32 {
    const v = json.get(o, key) orelse return error.MissingFields;
    return std.math.cast(i32, try v.asInt()) orelse error.BadNumber;
}

/// Parse the complete Qwen3.5 multimodal wrapper. This remains separate from
/// load(): classic GQA/OLMoE semantics must not inherit hybrid defaults.
pub fn loadQwen35(c: *Qwen35Cfg, root: *const json.Value, whence: []const u8, diag: *Diag) !void {
    _ = whence;
    c.* = .{};
    diag.buf.len = 0;
    diag.missing.len = 0;
    diag.nmissing = 0;
    if (root.* != .obj) return error.BadStructure;
    const mt = json.get(root, "model_type") orelse return error.BadStructure;
    if (mt.* != .str or !std.mem.eql(u8, mt.str, "qwen3_5_moe")) return error.UnsupportedFeature;
    const tc = json.get(root, "text_config") orelse return error.MissingFields;
    const vc = json.get(root, "vision_config") orelse return error.MissingFields;
    var s = Src{ .root = root, .txt = tc, .diag = diag };
    c.text.model_type = .qwen3_5_moe;
    c.text.hidden = s.i("hidden_size", null);
    c.text.n_layers = s.i("num_hidden_layers", null);
    c.text.vocab = s.i("vocab_size", null);
    c.text.rms_eps = s.f("rms_norm_eps", null);
    c.text.max_pos = s.i("max_position_embeddings", null);
    c.text.n_heads = s.i("num_attention_heads", null);
    c.text.n_kv = s.i("num_key_value_heads", null);
    c.text.head_dim = s.i("head_dim", null);
    c.text.n_experts = s.i("num_experts", null);
    c.text.topk = s.i("num_experts_per_tok", null);
    c.text.moe_inter = s.i("moe_intermediate_size", null);
    c.text.shared_inter = s.i("shared_expert_intermediate_size", null);
    c.text.norm_topk = true;
    c.text.router = .softmax;
    c.text.tie_embed = s.b("tie_word_embeddings", null, false);
    c.text.use_qk_norm = true;
    c.text.dense_inter = c.text.moe_inter;
    c.linear_key_heads = s.i("linear_num_key_heads", null);
    c.linear_value_heads = s.i("linear_num_value_heads", null);
    c.linear_key_dim = s.i("linear_key_head_dim", null);
    c.linear_value_dim = s.i("linear_value_head_dim", null);
    c.conv_kernel = s.i("linear_conv_kernel_dim", null);
    c.output_gate = s.b("attn_output_gate", null, false);
    if (s.nested("rope_parameters", "rope_theta")) |v| c.text.rope_theta = v.asQ128() catch .{ .raw = 0 } else s.miss("rope_parameters.rope_theta");
    if (s.nested("rope_parameters", "partial_rotary_factor")) |v| c.text.partial_rotary = v.asQ128() catch .{ .raw = 0 } else s.miss("rope_parameters.partial_rotary_factor");
    if (s.nested("rope_parameters", "mrope_section")) |v| {
        if (v.* != .arr or v.arr.len != 3) return error.BadStructure;
        for (v.arr, 0..) |item, i| c.mrope[i] = std.math.cast(i32, item.asInt() catch return error.BadStructure) orelse return error.BadStructure;
    } else return error.MissingFields;
    c.mrope_interleaved = if (s.nested("rope_parameters", "mrope_interleaved")) |v| switch (v.*) {
        .bool_v => |b| b,
        else => false,
    } else false;
    const lt = json.get(tc, "layer_types") orelse return error.MissingFields;
    if (lt.* != .arr or lt.arr.len != @as(usize, @intCast(@max(c.text.n_layers, 0)))) return error.BadStructure;
    c.n_layers = lt.arr.len;
    for (lt.arr, 0..) |item, i| {
        if (item.* != .str) return error.BadStructure;
        if (std.mem.eql(u8, item.str, "linear_attention")) c.layers[i] = .linear_attention else if (std.mem.eql(u8, item.str, "full_attention")) c.layers[i] = .full_attention else return error.UnsupportedFeature;
    }
    c.vision.depth = jsonInt(vc, "depth") catch return error.MissingFields;
    c.vision.hidden = jsonInt(vc, "hidden_size") catch return error.MissingFields;
    c.vision.intermediate = jsonInt(vc, "intermediate_size") catch return error.MissingFields;
    c.vision.heads = jsonInt(vc, "num_heads") catch return error.MissingFields;
    c.vision.channels = jsonInt(vc, "in_channels") catch return error.MissingFields;
    c.vision.patch = jsonInt(vc, "patch_size") catch return error.MissingFields;
    c.vision.temporal_patch = jsonInt(vc, "temporal_patch_size") catch return error.MissingFields;
    c.vision.spatial_merge = jsonInt(vc, "spatial_merge_size") catch return error.MissingFields;
    c.vision.positions = jsonInt(vc, "num_position_embeddings") catch return error.MissingFields;
    c.vision.output_hidden = jsonInt(vc, "out_hidden_size") catch return error.MissingFields;
    c.vision.hidden_act_gelu_tanh = if (json.get(vc, "hidden_act")) |v| v.* == .str and std.mem.eql(u8, v.str, "gelu_pytorch_tanh") else return error.UnsupportedFeature;
    // Qwen3-VL vision configuration omits rope_parameters in the released
    // wrapper; the official vision config supplies the axial 10000 default.
    c.vision.rope_theta = fp.Q128_128.fromInt(10_000);
    c.vision.image_token = jsonInt(root, "image_token_id") catch return error.MissingFields;
    c.vision.video_token = jsonInt(root, "video_token_id") catch return error.MissingFields;
    c.vision.vision_start = jsonInt(root, "vision_start_token_id") catch return error.MissingFields;
    c.vision.vision_end = jsonInt(root, "vision_end_token_id") catch return error.MissingFields;
    if (c.vision.output_hidden != c.text.hidden or c.vision.depth <= 0) return error.BadStructure;
}

/// Peek at model_type without loading — the CLI dispatch hook: routes to
/// the K3 reader for kimi_k3, here for the GQA+MoE family.
pub fn peekModelType(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const txt = try std.fs.cwd().readFileAlloc(arena, path, 1 << 28);
    const root = try json.parse(arena, txt);
    if (root.* != .obj) return error.BadStructure;
    if (json.get(root, "model_type")) |v| {
        if (v.* == .str) return v.str;
    }
    if (json.get(root, "text_config")) |tc| {
        if (json.get(tc, "model_type")) |v| {
            if (v.* == .str) return v.str;
        }
    }
    return error.BadStructure;
}

// ---------------------------------------------------------------- tests ----

test "qwen3_moe shape: required fields and sparse map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\{"model_type":"qwen3_moe","hidden_size":128,"num_hidden_layers":4,
        \\ "vocab_size":256,"rms_norm_eps":1e-6,"max_position_embeddings":512,
        \\ "num_attention_heads":4,"num_key_value_heads":2,"head_dim":32,
        \\ "rope_theta":1000000.0,"num_experts":8,"num_experts_per_tok":2,
        \\ "moe_intermediate_size":64,"shared_expert_intermediate_size":128,
        \\ "norm_topk_prob":true,"decoder_sparse_step":1,
        \\ "first_k_dense_replace":1,"intermediate_size":96,
        \\ "tie_word_embeddings":false,"hidden_act":"silu"}
    ;
    const root = try json.parse(arena.allocator(), doc);
    var c: GqaCfg = undefined;
    var diag = Diag{};
    try load(&c, root, "synthetic-qwen3moe", &diag);
    try std.testing.expectEqual(@as(i32, 128), c.hidden);
    try std.testing.expectEqual(@as(i32, 4), c.n_layers);
    try std.testing.expectEqual(@as(i32, 2), c.n_kv);
    try std.testing.expectEqual(@as(usize, 32), c.rotDim());
    try std.testing.expect(!c.isMoe(0));
    try std.testing.expect(c.isMoe(1) and c.isMoe(3));
}

test "olmoe shape: local-experts alias, no shared expert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\{"model_type":"olmoe","hidden_size":96,"num_hidden_layers":2,
        \\ "vocab_size":256,"rms_norm_eps":1e-5,"max_position_embeddings":512,
        \\ "num_attention_heads":4,"num_key_value_heads":4,
        \\ "rope_theta":10000.0,"num_local_experts":8,"num_experts_per_tok":2,
        \\ "moe_intermediate_size":64,"norm_topk_prob":true,
        \\ "first_k_dense_replace":0,"intermediate_size":192,
        \\ "tie_word_embeddings":true,"hidden_act":"silu"}
    ;
    const root = try json.parse(arena.allocator(), doc);
    var c: GqaCfg = undefined;
    var diag = Diag{};
    try load(&c, root, "synthetic-olmoe", &diag);
    try std.testing.expectEqual(@as(i32, 8), c.n_experts);
    try std.testing.expectEqual(@as(i32, 24), c.head_dim); // derived
    try std.testing.expect(c.isMoe(0)); // first_dense=0 -> all sparse
    try std.testing.expect(c.tie_embed);
}

test "qwen35 nested multimodal contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\{"model_type":"qwen3_5_moe","image_token_id":10,"video_token_id":11,
        \\"vision_start_token_id":12,"vision_end_token_id":13,
        \\       "text_config":{"model_type":"qwen3_5_moe_text","hidden_size":2048,
        \\       "num_hidden_layers":4,"vocab_size":256,"rms_norm_eps":1e-6,
        \\       "max_position_embeddings":1024,"num_attention_heads":16,"num_key_value_heads":2,
        \\       "head_dim":256,"num_experts":8,"num_experts_per_tok":2,"moe_intermediate_size":64,
        \\       "shared_expert_intermediate_size":64,"linear_num_key_heads":16,
        \\       "linear_num_value_heads":32,"linear_key_head_dim":128,"linear_value_head_dim":128,
        \\       "linear_conv_kernel_dim":4,"attn_output_gate":true,
        \\       "rope_parameters":{"rope_theta":10000000,"partial_rotary_factor":0.25,
        \\       "mrope_section":[11,11,10],"mrope_interleaved":true},
        \\       "layer_types":["linear_attention","linear_attention","linear_attention","full_attention"]},
        \\       "vision_config":{"depth":27,"hidden_size":1152,"intermediate_size":4304,
        \\       "num_heads":16,"in_channels":3,"patch_size":16,"temporal_patch_size":2,
        \\       "spatial_merge_size":2,"num_position_embeddings":2304,"out_hidden_size":2048,
        \\       "hidden_act":"gelu_pytorch_tanh"}}
    ;
    const root = try json.parse(arena.allocator(), doc);
    var c: Qwen35Cfg = undefined;
    var diag = Diag{};
    try loadQwen35(&c, root, "synthetic-qwen35", &diag);
    try std.testing.expectEqual(@as(usize, 4), c.n_layers);
    try std.testing.expect(c.isLinear(0));
    try std.testing.expect(!c.isLinear(3));
    try std.testing.expectEqual(@as(i32, 27), c.vision.depth);
    try std.testing.expect(c.output_gate and c.mrope_interleaved);
}

test "qwen35 real config if staged" {
    const path = "tests/fixtures/qwen3.5-35b-a3b/config.json";
    const file = std.fs.cwd().openFile(path, .{}) catch return error.SkipZigTest;
    defer file.close();
    const text = try file.readToEndAlloc(std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(text);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try json.parse(arena.allocator(), text);
    var c: Qwen35Cfg = undefined;
    var diag = Diag{};
    try loadQwen35(&c, root, path, &diag);
    try std.testing.expectEqual(@as(usize, 40), c.n_layers);
    try std.testing.expectEqual(@as(i32, 27), c.vision.depth);
    try std.testing.expectEqual(HybridLayer.full_attention, c.layers[3]);
}

test "refusals: missing fields, llama4, hybrid phase-B" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var c: GqaCfg = undefined;
    var diag = Diag{};

    // missing most fields
    const thin = try json.parse(aa, "{\"model_type\":\"qwen3_moe\"}");
    try std.testing.expectError(Error.MissingFields, load(&c, thin, "thin", &diag));

    // llama4 refused outright
    const l4 = try json.parse(aa, "{\"model_type\":\"llama4\"}");
    try std.testing.expectError(Error.UnsupportedFeature, load(&c, l4, "l4", &diag));

    // hybrid parses the shared fields but is phase-B gated
    const hyb = try json.parse(aa, "{\"model_type\":\"qwen3_5_moe\"}");
    try std.testing.expectError(Error.UnsupportedFeature, load(&c, hyb, "hyb", &diag));
}
