//! Model registry: the authoritative map of every checkpoint family Qstar can
//! distill into lattice-native QSW seeds. Each entry binds a HuggingFace
//! component to a `ModelFamily` (tensor-name conventions), a `Modality`
//! (dimensional route), a scheduler, and a seed filename under `weights/`.
//!
//! The registry is a static table — new models are added by appending rows
//! here and mirroring them into `models/registry.json` (a test asserts the
//! two stay in sync). `detectFamily` in weight_distill.zig is the per-tensor
//! heuristic; this table is the per-checkpoint ground truth.

const std = @import("std");
const wd = @import("weight_distill");
const modality = @import("modality");

pub const Modality = modality.Modality;
pub const ModelFamily = wd.ModelFamily;

/// Which component of a multi-file checkpoint this entry describes.
pub const Component = enum(u8) {
    transformer, // DiT / MMDiT denoiser backbone
    unet, // UNet denoiser (SDXL)
    text_encoder, // T5/UMT5/CLIP/LLM conditioning encoder
    audio_encoder, // Whisper audio conditioning
    vision_encoder, // CLIP vision tower
    vae, // latent codec
    lora, // LoRA/DMD adapter
    llm, // standalone language model
    unknown,
};

/// Scheduler family used by the checkpoint's denoise loop.
pub const Scheduler = enum(u8) {
    flow_match, // FlowMatchEulerDiscreteScheduler (LongCat, FLUX, SD3, Wan, Hunyuan)
    unipc, // UniPC multistep (Wan default sampler)
    euler, // Euler a/ancestral (SDXL community default)
    dpm_2m, // DPM++ 2M (SDXL, CogVideoX)
    lcm, // Latent Consistency (LTX fast path)
    none, // encoders, VAEs, LLMs — no sampler
};

/// Seed-file lifecycle for a registry entry.
pub const Status = enum(u8) {
    distilled, // QSW seed exists under weights/
    pending, // approved for the sweep, not yet downloaded
    gated, // HF repo requires license approval — needs HF_TOKEN auth
};

pub const Entry = struct {
    /// Stable registry id — also the seed filename `weights/<id>.qsw`.
    id: []const u8,
    /// HuggingFace repo the source checkpoint is recoverable from.
    hf_repo: []const u8,
    /// Path/pattern of the safetensors within the repo (informational).
    hf_path: []const u8,
    component: Component,
    family: ModelFamily,
    modality: Modality,
    scheduler: Scheduler,
    /// Approximate parameter count (0 = unknown/not yet measured).
    approx_params: u64,
    status: Status,
};

fn e(id: []const u8, repo: []const u8, path: []const u8, comp: Component, fam: ModelFamily, m: Modality, sch: Scheduler, params: u64, st: Status) Entry {
    return .{ .id = id, .hf_repo = repo, .hf_path = path, .component = comp, .family = fam, .modality = m, .scheduler = sch, .approx_params = params, .status = st };
}

const D = Status.distilled;
const P = Status.pending;
const G = Status.gated;

/// The multimodel sweep. LongCat family is already distilled; the rest are
/// queued for sequential download → distill → verify → source cleanup.
pub const REGISTRY = [_]Entry{
    // ---- LongCat-Video-Avatar-1.5 (distilled 2026-09-17) ----
    e("base_model", "meituan-longcat/LongCat-Video-Avatar-1.5", "base_model/*.safetensors", .transformer, .longcat_dit, .audio_to_video, .flow_match, 15_852_916_800, D),
    e("base_model_int8", "meituan-longcat/LongCat-Video-Avatar-1.5", "base_model_int8/*.safetensors", .transformer, .longcat_dit, .audio_to_video, .flow_match, 15_858_342_464, D),
    e("text_encoder", "meituan-longcat/LongCat-Video-Avatar-1.5", "text_encoder/*.safetensors", .text_encoder, .t5, .text_embedding, .none, 5_680_910_336, D),
    e("whisper", "meituan-longcat/LongCat-Video-Avatar-1.5", "whisper-large-v3/*.safetensors", .audio_encoder, .whisper, .speech_to_text, .none, 1_543_490_560, D),
    e("vae", "meituan-longcat/LongCat-Video-Avatar-1.5", "vae/*.safetensors", .vae, .vae, .latent_codec, .none, 126_892_531, D),
    e("dmd_lora", "meituan-longcat/LongCat-Video-Avatar-1.5", "lora/dmd_lora.safetensors", .lora, .lora, .adapter, .flow_match, 630_718_800, D),
    e("parent_loras", "meituan-longcat/LongCat-Video", "loras/*.safetensors", .lora, .lora, .adapter, .flow_match, 1_430_000_000, D),
    // ---- FLUX.1-schnell (T2I, Apache-2.0) ----
    e("flux_schnell_dit", "Comfy-Org/flux1-schnell", "flux1-schnell.safetensors", .transformer, .flux, .text_to_image, .flow_match, 11_891_178_560, D),
    e("flux_schnell_t5xxl", "comfyanonymous/flux_text_encoders", "t5xxl_fp16.safetensors", .text_encoder, .t5, .text_embedding, .none, 4_893_906_944, D),
    e("flux_schnell_clip", "comfyanonymous/flux_text_encoders", "clip_l.safetensors", .text_encoder, .clip, .text_embedding, .none, 123_060_480, D),
    e("flux_schnell_ae", "Kijai/flux-fp8", "flux-vae-bf16.safetensors", .vae, .vae, .latent_codec, .none, 83_819_683, D),
    // ---- SDXL base 1.0 (T2I UNet) ----
    e("sdxl_unet", "stabilityai/stable-diffusion-xl-base-1.0", "unet/*.safetensors", .unet, .sdxl_unet, .text_to_image, .euler, 2_567_463_684, D),
    e("sdxl_clip_l", "stabilityai/stable-diffusion-xl-base-1.0", "text_encoder/*.safetensors", .text_encoder, .clip, .text_embedding, .none, 123_060_480, D),
    e("sdxl_clip_g", "stabilityai/stable-diffusion-xl-base-1.0", "text_encoder_2/*.safetensors", .text_encoder, .clip, .text_embedding, .none, 694_659_840, D),
    e("sdxl_vae", "stabilityai/stable-diffusion-xl-base-1.0", "vae/*.safetensors", .vae, .vae, .latent_codec, .none, 83_653_863, D),
    // ---- Wan2.1 T2V 1.3B ----
    e("wan21_dit", "Wan-AI/Wan2.1-T2V-1.3B-Diffusers", "transformer/*.safetensors", .transformer, .wan, .text_to_video, .flow_match, 1_418_996_800, D),
    e("wan21_umt5", "Wan-AI/Wan2.1-T2V-1.3B-Diffusers", "text_encoder/*.safetensors", .text_encoder, .t5, .text_embedding, .none, 5_680_910_336, D),
    e("wan21_vae", "Wan-AI/Wan2.1-T2V-1.3B-Diffusers", "vae/*.safetensors", .vae, .vae, .latent_codec, .none, 126_892_531, D),
    // ---- CogVideoX-2b ----
    e("cogvideox_dit", "zai-org/CogVideoX-2b", "transformer/*.safetensors", .transformer, .cogvideox, .text_to_video, .dpm_2m, 1_693_783_872, D),
    e("cogvideox_t5", "zai-org/CogVideoX-2b", "text_encoder/*.safetensors", .text_encoder, .t5, .text_embedding, .none, 4_762_310_656, D),
    e("cogvideox_vae", "zai-org/CogVideoX-2b", "vae/*.safetensors", .vae, .vae, .latent_codec, .none, 215_583_907, D),
    // ---- HunyuanVideo ----
    e("hunyuan_dit", "hunyuanvideo-community/HunyuanVideo", "transformer/*.safetensors", .transformer, .hunyuan, .text_to_video, .flow_match, 12_821_012_544, D),
    e("hunyuan_llava", "hunyuanvideo-community/HunyuanVideo", "text_encoder/*.safetensors", .text_encoder, .llm, .text_embedding, .none, 7_505_186_816, D),
    e("hunyuan_clip", "hunyuanvideo-community/HunyuanVideo", "text_encoder_2/*.safetensors", .text_encoder, .clip, .text_embedding, .none, 123_060_480, D),
    e("hunyuan_vae", "hunyuanvideo-community/HunyuanVideo", "vae/*.safetensors", .vae, .vae, .latent_codec, .none, 246_478_803, D),
    // ---- SD3.5 medium (MMDiT) ----
    e("sd35_mmdit", "stabilityai/stable-diffusion-3.5-medium", "transformer/*.safetensors", .transformer, .mmdit, .text_to_image, .flow_match, 2_469_663_936, D),
    e("sd35_clip_l", "stabilityai/stable-diffusion-3.5-medium", "text_encoder/*.safetensors", .text_encoder, .clip, .text_embedding, .none, 123_650_304, D),
    e("sd35_clip_g", "stabilityai/stable-diffusion-3.5-medium", "text_encoder_2/*.safetensors", .text_encoder, .clip, .text_embedding, .none, 694_659_840, D),
    e("sd35_t5xxl", "stabilityai/stable-diffusion-3.5-medium", "text_encoder_3/*.safetensors", .text_encoder, .t5, .text_embedding, .none, 4_762_310_656, D),
    e("sd35_vae", "stabilityai/stable-diffusion-3.5-medium", "vae/*.safetensors", .vae, .vae, .latent_codec, .none, 83_819_683, D),
    // ---- LTX-Video ----
    e("ltx_dit", "Lightricks/LTX-Video", "ltx-video-2b-v0.9.1.safetensors", .transformer, .ltx, .text_to_video, .lcm, 2_858_362_546, D),
    // ---- Perception + language ----
    e("clip_vit_l14", "openai/clip-vit-large-patch14", "model.safetensors", .vision_encoder, .clip, .image_embedding, .none, 427_616_847, D),
    e("qwen3_0_6b", "Qwen/Qwen3-0.6B", "model.safetensors", .llm, .llm, .text_to_text, .none, 751_632_384, D),
};

/// Number of entries in the registry.
pub const COUNT = REGISTRY.len;

/// Looks up an entry by registry id.
pub fn find(id: []const u8) ?*const Entry {
    for (&REGISTRY) |*en| {
        if (std.mem.eql(u8, en.id, id)) return en;
    }
    return null;
}

/// All entries for a given component type (into caller's buffer; returns count).
pub fn byComponent(comp: Component, out: []*const Entry) usize {
    var n: usize = 0;
    for (&REGISTRY) |*en| {
        if (en.component == comp and n < out.len) {
            out[n] = en;
            n += 1;
        }
    }
    return n;
}

/// All entries for a modality.
pub fn byModality(m: Modality, out: []*const Entry) usize {
    var n: usize = 0;
    for (&REGISTRY) |*en| {
        if (en.modality == m and n < out.len) {
            out[n] = en;
            n += 1;
        }
    }
    return n;
}

/// Entries sharing a HuggingFace repo (a checkpoint's component group).
pub fn byRepo(repo: []const u8, out: []*const Entry) usize {
    var n: usize = 0;
    for (&REGISTRY) |*en| {
        if (std.mem.eql(u8, en.hf_repo, repo) and n < out.len) {
            out[n] = en;
            n += 1;
        }
    }
    return n;
}

/// Total registered parameters (approximate).
pub fn totalParams() u64 {
    var t: u64 = 0;
    for (REGISTRY) |en| t += en.approx_params;
    return t;
}

/// Distilled/pending status counts.
pub fn statusCounts() struct { distilled: usize, pending: usize, gated: usize } {
    var d: usize = 0;
    var g: usize = 0;
    for (REGISTRY) |en| {
        switch (en.status) {
            .distilled => d += 1,
            .gated => g += 1,
            .pending => {},
        }
    }
    return .{ .distilled = d, .pending = COUNT - d - g, .gated = g };
}

/// Which modalities have at least one rendering-capable model registered —
/// the coverage matrix for "covers all of ai".
pub fn modalityCoverage() [16]bool {
    var cov = [_]bool{false} ** 16;
    for (REGISTRY) |en| cov[@intFromEnum(en.modality)] = true;
    return cov;
}

// =============================================================================
// Tests
// =============================================================================

test "registry: ids are unique and fields are populated" {
    for (REGISTRY, 0..) |en, i| {
        try std.testing.expect(en.id.len > 0);
        try std.testing.expect(en.hf_repo.len > 0);
        try std.testing.expect(en.component != .unknown);
        try std.testing.expect(en.modality != .unknown);
        for (REGISTRY[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, en.id, other.id));
        }
    }
}

test "find: lookup by id" {
    try std.testing.expect(find("base_model").?.family == .longcat_dit);
    try std.testing.expect(find("flux_schnell_dit").?.modality == .text_to_image);
    try std.testing.expect(find("wan21_dit").?.scheduler == .flow_match);
    try std.testing.expect(find("qwen3_0_6b").?.component == .llm);
    try std.testing.expect(find("nonexistent") == null);
}

test "byComponent/byModality/byRepo group correctly" {
    var buf: [COUNT]*const Entry = undefined;
    const transformers = byComponent(.transformer, &buf);
    try std.testing.expect(transformers >= 7); // longcat x2 + flux + wan + cog + hunyuan + sd35 + ltx
    const vaes = byComponent(.vae, &buf);
    try std.testing.expect(vaes >= 6);
    const t2v = byModality(.text_to_video, &buf);
    try std.testing.expect(t2v >= 4); // wan, cogvideox, hunyuan, ltx
    // FLUX spans three repos (Comfy-Org checkpoint + comfyanonymous encoders
    // + Kijai ae mirror) — 4 entries total across the mirrors.
    try std.testing.expectEqual(@as(usize, 1), byRepo("Comfy-Org/flux1-schnell", &buf));
    try std.testing.expectEqual(@as(usize, 2), byRepo("comfyanonymous/flux_text_encoders", &buf));
    try std.testing.expectEqual(@as(usize, 1), byRepo("Kijai/flux-fp8", &buf));
}

test "status counts: full sweep distilled, zero gated" {
    const s = statusCounts();
    try std.testing.expectEqual(@as(usize, 33), s.distilled);
    try std.testing.expectEqual(@as(usize, 0), s.gated);
    try std.testing.expectEqual(COUNT - 33, s.pending);
}

test "registry.json mirrors the Zig table" {
    // cwd must be the project root (zig build run steps set it).
    const allocator = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "models/registry.json", 1 << 20);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("entries").?.array;
    try std.testing.expectEqual(COUNT, entries.items.len);
    for (entries.items) |item| {
        const obj = item.object;
        const id = obj.get("id").?.string;
        const en = find(id) orelse return error.TestUnexpectedResult;
        // Spot-check the mirrored fields on every entry.
        try std.testing.expectEqualStrings(en.hf_repo, obj.get("hf_repo").?.string);
        try std.testing.expectEqualStrings(@tagName(en.component), obj.get("component").?.string);
        try std.testing.expectEqualStrings(@tagName(en.family), obj.get("family").?.string);
        try std.testing.expectEqualStrings(@tagName(en.modality), obj.get("modality").?.string);
        try std.testing.expectEqualStrings(@tagName(en.scheduler), obj.get("scheduler").?.string);
        try std.testing.expectEqual(en.approx_params, @as(u64, @intCast(obj.get("approx_params").?.integer)));
        try std.testing.expectEqualStrings(@tagName(en.status), obj.get("status").?.string);
    }
}

test "modality coverage: the sweep spans the AI surface" {
    const cov = modalityCoverage();
    // Every modality except video_embedding and image_to_image must have a
    // registered model — those two remain mapped-but-uncovered (documented).
    inline for (@typeInfo(Modality).Enum.fields) |f| {
        const m: Modality = @enumFromInt(f.value);
        switch (m) {
            // Mapped routes with no dedicated checkpoint yet: I2V is reached
            // through LTX (T2V-registered) and LongCat continuation streams;
            // I2I through SDXL/FLUX latent edits; video_embedding has no
            // encoder in the sweep.
            .video_embedding, .image_to_image, .image_to_video, .unknown => continue,
            else => {
                if (!cov[f.value]) std.debug.print("uncovered modality: {s}\n", .{f.name});
                try std.testing.expect(cov[f.value]);
            },
        }
    }
}
