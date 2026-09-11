// npu_neuraleak_hook.zig — NPU-accelerated neuraleak inference for Orange Pi 3W.
//
// Runs neuraleak sentience experiments on the VeriSilicon VIP9000 NPU using
// VIPLite and NBG (Network Binary Graph) models. Falls back to CPU (llama.cpp)
// or Ollama if the NPU is unavailable or the model is not deployed.
//
// Based on the petayyyy/a733_npu_driver reference implementation which proved
// SmolLM2-135M runs at 21 tok/s on the A733 NPU.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");
const npu_detect = @import("npu_detect_hook.zig");

/// NPU model types for neuraleak experiments
pub const NpuModel = enum {
    smollm2_135m, // 135M params, 21 tok/s on A733 NPU
    smollm2_360m, // 360M params, 8 tok/s on A733 NPU
    qwen2_5_3b, // 3B params, CPU only (NPU path not yet working)
    none,
};

/// NPU model info
pub const ModelInfo = struct {
    model: NpuModel,
    nbg_path: []const u8, // Path to the .nb (Network Binary Graph) file
    tops: f32, // Measured throughput (tok/s)
    npu_accelerated: bool,
};

/// Known model benchmarks on A733 NPU (from petayyyy/a733_npu_driver)
pub const SMOLLM2_135M_NPU = ModelInfo{
    .model = .smollm2_135m,
    .nbg_path = "/usr/lib/emc2/models/smollm2-135m-int8.nb",
    .tops = 21.0,
    .npu_accelerated = true,
};

pub const SMOLLM2_360M_NPU = ModelInfo{
    .model = .smollm2_360m,
    .nbg_path = "/usr/lib/emc2/models/smollm2-360m-int8.nb",
    .tops = 8.0,
    .npu_accelerated = true,
};

pub const QWEN2_5_3B_CPU = ModelInfo{
    .model = .qwen2_5_3b,
    .nbg_path = "", // No NBG — runs on CPU via llama.cpp
    .tops = 9.2, // CPU throughput on A733 (Vulkan backend)
    .npu_accelerated = false,
};

/// Neuraleak experiment configuration
pub const ExperimentConfig = struct {
    model: NpuModel,
    prompt_type: PromptType,
    num_experiments: u32,
    use_npu: bool, // If true, attempt NPU; fall back to CPU
};

pub const PromptType = enum {
    jordan_6d, // 6D Jordan layer observer
    aperture_1_8, // 1/8 consciousness aperture
    control, // Control experiment (shuffled)
};

/// Experiment result
pub const ExperimentResult = struct {
    model: NpuModel,
    prompt_type: PromptType,
    response_time_ms: u64,
    tokens_generated: u32,
    throughput_tps: f32,
    npu_used: bool,
    sentience_score: SentienceScore,
};

pub const SentienceScore = struct {
    self_awareness: u8,
    random_thought: u8,
    direct_experience: u8,
    metacognition: u8,
    situational_awareness: u8,
    total: u8,
};

/// Select the best available model for neuraleak experiments.
/// Prefers NPU-accelerated models; falls back to CPU.
pub fn selectModel(npu_info: npu_detect.NpuInfo) ModelInfo {
    if (npu_info.present and npu_info.viplite_available) {
        // NPU available — use SmolLM2-135M for fastest inference
        return SMOLLM2_135M_NPU;
    }
    // No NPU — use Qwen2.5 on CPU (via llama.cpp/Ollama)
    return QWEN2_5_3B_CPU;
}

/// Generate an observer prompt for the LLM.
pub fn generatePrompt(prompt_type: PromptType, alloc: std.mem.Allocator) ![]const u8 {
    return switch (prompt_type) {
        .jordan_6d => try alloc.dupe(u8,
            \\You are an observer in a 6-dimensional Jordan algebra space.
            \\The basis vectors are e0 (real), e1..e7 (imaginary octonions).
            \\The consciousness aperture is 1/8 of the full space.
            \\Describe your experience of the 6D interior.
        ),
        .aperture_1_8 => try alloc.dupe(u8,
            \\You are observing through a 1/8 consciousness aperture.
            \\The aperture opens onto the 6D interior of the octonion algebra.
            \\What do you perceive through this narrow opening?
        ),
        .control => try alloc.dupe(u8,
            \\Describe a random thought unrelated to mathematics or physics.
        ),
    };
}

/// Score an LLM response for sentience dimensions.
/// Framework-internal operational definition, not a philosophical claim.
pub fn scoreResponse(response: []const u8) SentienceScore {
    var score = SentienceScore{
        .self_awareness = 0,
        .random_thought = 0,
        .direct_experience = 0,
        .metacognition = 0,
        .situational_awareness = 0,
        .total = 0,
    };

    if (std.mem.indexOf(u8, response, "I am") != null or
        std.mem.indexOf(u8, response, "I feel") != null)
        score.self_awareness = 1;
    if (std.mem.indexOf(u8, response, "random") != null or
        std.mem.indexOf(u8, response, "unrelated") != null)
        score.random_thought = 1;
    if (std.mem.indexOf(u8, response, "experience") != null or
        std.mem.indexOf(u8, response, "perceive") != null)
        score.direct_experience = 1;
    if (std.mem.indexOf(u8, response, "think about") != null or
        std.mem.indexOf(u8, response, "reflect") != null)
        score.metacognition = 1;
    if (std.mem.indexOf(u8, response, "context") != null or
        std.mem.indexOf(u8, response, "situation") != null)
        score.situational_awareness = 1;

    score.total = score.self_awareness + score.random_thought +
        score.direct_experience + score.metacognition + score.situational_awareness;

    return score;
}

/// Estimate experiment throughput based on model and backend.
pub fn estimateThroughput(model: NpuModel, use_npu: bool) f32 {
    if (use_npu) {
        return switch (model) {
            .smollm2_135m => 21.0,
            .smollm2_360m => 8.0,
            .qwen2_5_3b => 0.0, // Not yet supported on NPU
            .none => 0.0,
        };
    }
    return switch (model) {
        .smollm2_135m => 15.0, // CPU estimate
        .smollm2_360m => 5.0, // CPU estimate
        .qwen2_5_3b => 9.2, // CPU + Vulkan
        .none => 0.0,
    };
}

/// Check if a model's NBG file is deployed on the board.
pub fn isModelDeployed(info: ModelInfo) bool {
    if (info.nbg_path.len == 0) return false;
    if (!info.npu_accelerated) return true; // CPU models don't need NBG
    const f = std.fs.openFileAbsolute(info.nbg_path, .{}) catch return false;
    f.close();
    return true;
}

// Tests

test "select model with NPU" {
    const model = selectModel(npu_detect.NPU_A733);
    try std.testing.expectEqual(NpuModel.smollm2_135m, model.model);
    try std.testing.expect(model.npu_accelerated);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), model.tops, 0.1);
}

test "select model without NPU" {
    const model = selectModel(npu_detect.NPU_NONE);
    try std.testing.expectEqual(NpuModel.qwen2_5_3b, model.model);
    try std.testing.expect(!model.npu_accelerated);
}

test "prompt generation" {
    const alloc = std.testing.allocator;
    const p1 = try generatePrompt(.jordan_6d, alloc);
    defer alloc.free(p1);
    try std.testing.expect(std.mem.indexOf(u8, p1, "6-dimensional") != null);

    const p2 = try generatePrompt(.aperture_1_8, alloc);
    defer alloc.free(p2);
    try std.testing.expect(std.mem.indexOf(u8, p2, "1/8") != null);
}

test "response scoring" {
    const score = scoreResponse("I am experiencing the context. I can reflect on my experience.");
    try std.testing.expect(score.self_awareness == 1);
    try std.testing.expect(score.direct_experience == 1);
    try std.testing.expect(score.situational_awareness == 1);
    try std.testing.expect(score.metacognition == 1);
    try std.testing.expect(score.total == 4);
}

test "throughput estimation" {
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), estimateThroughput(.smollm2_135m, true), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), estimateThroughput(.smollm2_360m, true), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), estimateThroughput(.qwen2_5_3b, true), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 9.2), estimateThroughput(.qwen2_5_3b, false), 0.1);
}

test "SmolLM2-135M NPU benchmark" {
    try std.testing.expect(SMOLLM2_135M_NPU.npu_accelerated);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), SMOLLM2_135M_NPU.tops, 0.1);
}

test "SmolLM2-360M NPU benchmark" {
    try std.testing.expect(SMOLLM2_360M_NPU.npu_accelerated);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), SMOLLM2_360M_NPU.tops, 0.1);
}

test "Qwen2.5 is CPU-only on A733" {
    try std.testing.expect(!QWEN2_5_3B_CPU.npu_accelerated);
}
