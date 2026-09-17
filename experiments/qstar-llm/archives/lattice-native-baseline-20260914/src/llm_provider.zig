//! llm_provider.zig — Unified LLM provider selection via .env
//!
//! Reads LLM_PROVIDER from .env to determine which backend to use for all
//! LLM calls (training, benchmarking, judging, heartbeat).
//!
//! Supported values:
//!   local  — Ollama on 127.0.0.1:11434 (default)
//!   remote — Ollama on OLLAMA_HOST:OLLAMA_PORT from .env
//!   openai — OpenAI API (requires OPENAI_API_KEY)
//!
//! Additional .env keys:
//!   LLM_PROVIDER       — "local" | "remote" | "openai" (default: local)
//!   OLLAMA_HOST        — Host for remote Ollama (default: 127.0.0.1)
//!   OLLAMA_PORT        — Port for remote Ollama (default: 11434)
//!   OLLAMA_MODEL       — Model name for Ollama (default: qwen2.5:3b)
//!   OPENAI_API_KEY     — API key for OpenAI
//!   OPENAI_MODEL       — Model name for OpenAI (default: gpt-4o-mini)
//!   JUDGE_MODEL        — Override model for judge calls (default: same as provider)
//!   JUDGE_HOST         — Override host for judge Ollama (default: same as provider)
//!   JUDGE_PORT         — Override port for judge Ollama (default: same as provider)

const std = @import("std");
const ollama = @import("ollama_client");
const openai = @import("openai_client");
const env_loader = @import("env_loader");

pub const Provider = enum {
    local,
    remote,
    openai,
};

pub const LlmConfig = struct {
    provider: Provider = .local,
    ollama: ollama.OllamaConfig = .{},
    openai: ?openai.OpenAIConfig = null,
    judge_ollama: ?ollama.OllamaConfig = null,
    judge_openai: ?openai.OpenAIConfig = null,
};

/// Loads LLM configuration from .env file.
/// Caller does not need to free anything — strings are duped with page_allocator.
pub fn loadFromEnv(allocator: std.mem.Allocator) LlmConfig {
    var loader = env_loader.EnvLoader.init(allocator);
    defer loader.deinit();
    loader.loadFile(".env") catch return .{};

    const page = std.heap.page_allocator;

    // Determine provider
    var provider: Provider = .local;
    if (loader.get("LLM_PROVIDER")) |p| {
        if (std.mem.eql(u8, p, "remote")) {
            provider = .remote;
        } else if (std.mem.eql(u8, p, "openai")) {
            provider = .openai;
        } else if (std.mem.eql(u8, p, "local")) {
            provider = .local;
        }
    }

    // Build Ollama config
    var ollama_cfg = ollama.OllamaConfig{};
    if (loader.get("OLLAMA_HOST")) |h| {
        ollama_cfg.host = page.dupe(u8, h) catch ollama_cfg.host;
    }
    if (loader.get("OLLAMA_PORT")) |p| {
        ollama_cfg.port = std.fmt.parseInt(u16, p, 10) catch ollama_cfg.port;
    }
    if (loader.get("OLLAMA_MODEL")) |m| {
        ollama_cfg.model = page.dupe(u8, m) catch ollama_cfg.model;
    }

    // For local provider, force 127.0.0.1
    if (provider == .local) {
        ollama_cfg.host = "127.0.0.1";
        ollama_cfg.port = 11434;
    }

    // Build OpenAI config
    var openai_cfg: ?openai.OpenAIConfig = null;
    if (loader.get("OPENAI_API_KEY")) |key| {
        if (key.len > 0) {
            const duped_key = page.dupe(u8, key) catch return .{};
            openai_cfg = openai.OpenAIConfig{ .api_key = duped_key };
            if (loader.get("OPENAI_MODEL")) |m| {
                openai_cfg.?.model = page.dupe(u8, m) catch openai_cfg.?.model;
            }
        }
    }

    // Build judge config (defaults to same as provider, with optional overrides)
    var judge_ollama: ?ollama.OllamaConfig = null;
    var judge_openai: ?openai.OpenAIConfig = null;

    if (loader.get("JUDGE_HOST")) |jh| {
        judge_ollama = ollama.OllamaConfig{
            .host = page.dupe(u8, jh) catch ollama_cfg.host,
            .port = ollama_cfg.port,
            .model = ollama_cfg.model,
        };
        if (loader.get("JUDGE_PORT")) |jp| {
            judge_ollama.?.port = std.fmt.parseInt(u16, jp, 10) catch ollama_cfg.port;
        }
        if (loader.get("JUDGE_MODEL")) |jm| {
            judge_ollama.?.model = page.dupe(u8, jm) catch ollama_cfg.model;
        }
    } else if (loader.get("JUDGE_MODEL")) |jm| {
        judge_ollama = ollama.OllamaConfig{
            .host = ollama_cfg.host,
            .port = ollama_cfg.port,
            .model = page.dupe(u8, jm) catch ollama_cfg.model,
        };
    }

    if (openai_cfg != null) {
        judge_openai = openai_cfg;
        if (loader.get("JUDGE_MODEL")) |jm| {
            judge_openai.?.model = page.dupe(u8, jm) catch judge_openai.?.model;
        }
    }

    return .{
        .provider = provider,
        .ollama = ollama_cfg,
        .openai = openai_cfg,
        .judge_ollama = judge_ollama,
        .judge_openai = judge_openai,
    };
}

/// Returns the active Ollama config based on provider setting.
/// For local: forces 127.0.0.1:11434. For remote: uses .env values.
/// For openai: returns null (Ollama not used).
pub fn activeOllama(config: LlmConfig) ?ollama.OllamaConfig {
    return switch (config.provider) {
        .local, .remote => config.ollama,
        .openai => null,
    };
}

/// Returns the active OpenAI config based on provider setting.
/// For openai: returns the config. For local/remote: returns null.
pub fn activeOpenAI(config: LlmConfig) ?openai.OpenAIConfig {
    return switch (config.provider) {
        .openai => config.openai,
        .local, .remote => null,
    };
}

/// Returns the judge Ollama config, falling back to the active Ollama config.
pub fn judgeOllama(config: LlmConfig) ?ollama.OllamaConfig {
    if (config.judge_ollama) |jc| return jc;
    return activeOllama(config);
}

/// Returns the judge OpenAI config, falling back to the active OpenAI config.
pub fn judgeOpenAI(config: LlmConfig) ?openai.OpenAIConfig {
    if (config.judge_openai) |jc| return jc;
    return activeOpenAI(config);
}

/// Returns a human-readable description of the active provider.
pub fn providerDescription(config: LlmConfig) []const u8 {
    return switch (config.provider) {
        .local => "Ollama (local 127.0.0.1:11434)",
        .remote => "Ollama (remote)",
        .openai => "OpenAI API",
    };
}

test "llm_provider: default config is local" {
    const config = LlmConfig{};
    try std.testing.expect(config.provider == .local);
    try std.testing.expect(activeOllama(config) != null);
    try std.testing.expect(activeOpenAI(config) == null);
}

test "llm_provider: openai provider returns openai config" {
    const config = LlmConfig{
        .provider = .openai,
        .openai = openai.OpenAIConfig{ .api_key = "test-key", .model = "gpt-4o-mini" },
    };
    try std.testing.expect(activeOllama(config) == null);
    try std.testing.expect(activeOpenAI(config) != null);
    try std.testing.expectEqualStrings("gpt-4o-mini", activeOpenAI(config).?.model);
}

test "llm_provider: remote provider returns ollama config" {
    const config = LlmConfig{
        .provider = .remote,
        .ollama = ollama.OllamaConfig{ .host = "192.168.1.100", .port = 8080, .model = "llama3:8b" },
    };
    try std.testing.expect(activeOllama(config) != null);
    try std.testing.expectEqualStrings("192.168.1.100", activeOllama(config).?.host);
    try std.testing.expectEqual(@as(u16, 8080), activeOllama(config).?.port);
    try std.testing.expect(activeOpenAI(config) == null);
}

test "llm_provider: judge falls back to active config" {
    const config = LlmConfig{
        .provider = .remote,
        .ollama = ollama.OllamaConfig{ .host = "10.0.0.5", .port = 11434, .model = "qwen2.5:3b" },
    };
    const jc = judgeOllama(config).?;
    try std.testing.expectEqualStrings("10.0.0.5", jc.host);
    try std.testing.expectEqualStrings("qwen2.5:3b", jc.model);
}

test "llm_provider: judge override takes precedence" {
    const config = LlmConfig{
        .provider = .remote,
        .ollama = ollama.OllamaConfig{ .host = "10.0.0.5", .port = 11434, .model = "qwen2.5:3b" },
        .judge_ollama = ollama.OllamaConfig{ .host = "127.0.0.1", .port = 11434, .model = "llama3:8b" },
    };
    const jc = judgeOllama(config).?;
    try std.testing.expectEqualStrings("127.0.0.1", jc.host);
    try std.testing.expectEqualStrings("llama3:8b", jc.model);
}

test "llm_provider: providerDescription returns correct string" {
    try std.testing.expectEqualStrings("Ollama (local 127.0.0.1:11434)", providerDescription(.{ .provider = .local }));
    try std.testing.expectEqualStrings("Ollama (remote)", providerDescription(.{ .provider = .remote }));
    try std.testing.expectEqualStrings("OpenAI API", providerDescription(.{ .provider = .openai }));
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
