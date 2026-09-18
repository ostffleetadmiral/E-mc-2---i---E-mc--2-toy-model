//! Modality taxonomy for the multimodel lattice.
//!
//! Every supported AI modality is a *route* through the 0D–10D dimensional
//! stack: an ordered set of lattice dimensions the modality's data traverses
//! during conditioning, denoising, and rendering. This module is the single
//! source of truth for modality↔dimension binding; `model_registry.zig`
//! attaches models to modalities, and `weight_distill.detectFamily` attaches
//! tensors to architectures.
//!
//! All logic is integer-only — routes are dimension indices (u8).

const std = @import("std");

/// The AI modalities Qstar covers. Each maps to a dimensional route (see
/// `route`). `unknown` is the fallback for unclassified artifacts.
pub const Modality = enum(u8) {
    text_to_text, // LLM generation → 5D language → 6D evaluation
    text_to_image, // T2I diffusion (SDXL, FLUX, SD3) → latent denoise → splat render
    image_to_image, // I2I diffusion → latent edit
    text_to_video, // T2V diffusion (Wan, CogVideoX, Hunyuan, LTX) → temporal denoise
    image_to_video, // I2V continuation → temporal denoise
    audio_to_video, // Audio-conditioned avatar (LongCat) → 1D resample → 7D gate
    speech_to_text, // Whisper encoder → 1D spectral → 5D decode
    text_embedding, // CLIP/T5/UMT5 text encoding → 5D conditioning vector
    image_embedding, // CLIP vision encoder → 7D channel embedding
    video_embedding, // Video understanding → 1D+7D embedding
    latent_codec, // VAE encode/decode → 3D spatial compression
    adapter, // LoRA/DMD adapter → 10D coupling modifier
    unknown,
};

/// A modality's route through the dimensional stack. `primary` is the
/// dimension that owns the modality's core computation; `path` lists the
/// dimensions traversed in order (padded with 255 = NONE).
pub const Route = struct {
    primary: u8,
    path: [8]u8,
    len: u8,

    pub const NONE: u8 = 255;

    pub fn dims(self: Route) []const u8 {
        return self.path[0..self.len];
    }
};

fn mkRoute(primary: u8, ds: []const u8) Route {
    var r = Route{ .primary = primary, .path = [_]u8{Route.NONE} ** 8, .len = @intCast(ds.len) };
    for (ds, 0..) |d, i| r.path[i] = d;
    return r;
}

/// Dimensional route per modality:
/// - text_to_text:     5D language → 6D metacognitive evaluation
/// - text_to_image:    5D text → 3D latent → 8D denoise → 7D channel → 10D closure
/// - image_to_image:   3D latent → 8D denoise → 7D → 10D
/// - text_to_video:    5D text → 1D temporal → 3D latent → 8D denoise → 7D → 10D
/// - image_to_video:   3D first-frame → 1D temporal → 8D → 7D → 10D
/// - audio_to_video:   1D audio resample → 7D adaLN gate → 3D → 8D → 10D
/// - speech_to_text:   1D spectral → 5D decode
/// - text_embedding:   5D
/// - image_embedding:  7D channel space
/// - video_embedding:  1D temporal → 7D
/// - latent_codec:     3D spatial fold
/// - adapter:          10D coupling (modifies another route's weights)
pub fn route(m: Modality) Route {
    return switch (m) {
        .text_to_text => mkRoute(5, &.{ 5, 6 }),
        .text_to_image => mkRoute(3, &.{ 5, 3, 8, 7, 10 }),
        .image_to_image => mkRoute(3, &.{ 3, 8, 7, 10 }),
        .text_to_video => mkRoute(1, &.{ 5, 1, 3, 8, 7, 10 }),
        .image_to_video => mkRoute(1, &.{ 3, 1, 8, 7, 10 }),
        .audio_to_video => mkRoute(7, &.{ 1, 7, 3, 8, 10 }),
        .speech_to_text => mkRoute(1, &.{ 1, 5 }),
        .text_embedding => mkRoute(5, &.{5}),
        .image_embedding => mkRoute(7, &.{7}),
        .video_embedding => mkRoute(1, &.{ 1, 7 }),
        .latent_codec => mkRoute(3, &.{3}),
        .adapter => mkRoute(10, &.{10}),
        .unknown => mkRoute(Route.NONE, &.{}),
    };
}

/// Stable lowercase identifier for the modality (used in registry.json and
/// CLI output).
pub fn name(m: Modality) []const u8 {
    return @tagName(m);
}

/// Parses a registry/CLI modality string back to the enum. Unknown strings
/// map to `.unknown` rather than erroring so partial registries still load.
pub fn parse(s: []const u8) Modality {
    inline for (@typeInfo(Modality).Enum.fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return .unknown;
}

/// Does this modality produce rendered output (image/video) through the
/// denoise → splat path? Used by the CLI to pick `image-demo` vs `avatar-demo`.
pub fn renders(m: Modality) bool {
    return switch (m) {
        .text_to_image, .image_to_image, .text_to_video, .image_to_video, .audio_to_video => true,
        else => false,
    };
}

/// Does this modality ingest text conditioning (needs a text_encoder seed)?
pub fn textConditioned(m: Modality) bool {
    return switch (m) {
        .text_to_text, .text_to_image, .text_to_video, .text_embedding => true,
        else => false,
    };
}

/// Does this modality ingest audio conditioning (Whisper/adaLN path)?
pub fn audioConditioned(m: Modality) bool {
    return m == .audio_to_video or m == .speech_to_text;
}

// =============================================================================
// Tests
// =============================================================================

test "route: every modality has a well-formed route" {
    inline for (@typeInfo(Modality).Enum.fields) |f| {
        const m: Modality = @enumFromInt(f.value);
        const r = route(m);
        if (m == .unknown) {
            try std.testing.expectEqual(@as(u8, 0), r.len);
            continue;
        }
        try std.testing.expect(r.len > 0);
        try std.testing.expect(r.primary != Route.NONE);
        // Primary must appear in the path, dims must be in 0..=10.
        var found = false;
        for (r.dims()) |d| {
            try std.testing.expect(d <= 10);
            if (d == r.primary) found = true;
        }
        try std.testing.expect(found);
        // Padding must be NONE.
        for (r.path[r.len..]) |d| try std.testing.expectEqual(Route.NONE, d);
    }
}

test "routes: modality paths match the documented stack" {
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 3, 8, 7, 10 }, route(.text_to_video).dims());
    try std.testing.expectEqualSlices(u8, &.{ 1, 7, 3, 8, 10 }, route(.audio_to_video).dims());
    try std.testing.expectEqual(@as(u8, 10), route(.adapter).primary);
    try std.testing.expectEqual(@as(u8, 3), route(.latent_codec).primary);
}

test "parse/name round-trip" {
    inline for (@typeInfo(Modality).Enum.fields) |f| {
        const m: Modality = @enumFromInt(f.value);
        try std.testing.expectEqual(m, parse(name(m)));
    }
    try std.testing.expectEqual(Modality.unknown, parse("not_a_modality"));
}

test "renders/textConditioned/audioConditioned partition the space" {
    try std.testing.expect(renders(.text_to_image));
    try std.testing.expect(renders(.audio_to_video));
    try std.testing.expect(!renders(.text_embedding));
    try std.testing.expect(textConditioned(.text_to_image));
    try std.testing.expect(!textConditioned(.image_to_video));
    try std.testing.expect(audioConditioned(.audio_to_video));
    try std.testing.expect(audioConditioned(.speech_to_text));
    try std.testing.expect(!audioConditioned(.text_to_image));
}
