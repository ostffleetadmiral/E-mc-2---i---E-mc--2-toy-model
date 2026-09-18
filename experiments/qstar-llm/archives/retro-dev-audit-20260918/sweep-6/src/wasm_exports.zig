//! wasm_exports.zig — WASM export wrapper for universe.html browser embedding
//!
//! Exports a single WASM module with all Qstar capabilities:
//! - Agent inference (ingest, run, decode, generateLongForm)
//! - Tool calling (calculate, lattice_node, quantum_simulate)
//! - Lattice queries (E0 node info, activations)
//! - Fixed-point arithmetic bridge
//!
//! Compiled via: zig build wasm-universe
//! Embedded as base64 in universe.html

const std = @import("std");
const agent_mod = @import("agent");
const fp = @import("fixed_point");
const fp_bridge = @import("fp_bridge");
const build_options = @import("build_options");

// tools_mod and lattice_mod are only needed when tool_execute and lattice query
// exports are present (full and esp32 variants). Device-lite excludes them.
const tools_mod = if (!build_options.device_lite) @import("tools") else void;
const lattice_mod = if (!build_options.device_lite) @import("lattice") else void;

// ─── Persistent allocator (WASM linear memory) ───────────────────────────────
// Browser build: GeneralPurposeAllocator (growable — learns the full corpus).
// ESP32 build: fixed 48 KB buffer (bounded SRAM — corpus arrives via SD in Phase 5).
// Device-lite build: fixed 32 KB buffer (reduced corpus, fits ~171 KB free heap).

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var agent_heap: [if (build_options.esp32) (if (build_options.device_lite) 16 * 1024 else 48 * 1024) else 0]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var allocator_ready = false;

fn getAllocator() std.mem.Allocator {
    if (!allocator_ready) {
        if (build_options.esp32) {
            fba = std.heap.FixedBufferAllocator.init(&agent_heap);
            allocator = fba.allocator();
        } else {
            allocator = gpa.allocator();
        }
        allocator_ready = true;
    }
    return allocator;
}

// ─── Persistent agent instance ───────────────────────────────────────────────

var agent: ?agent_mod.Agent = null;
var agent_initialized = false;

fn ensureAgent() void {
    if (!agent_initialized) {
        agent = agent_mod.Agent.init(getAllocator(), 0, fp.ONE);
        agent_initialized = true;
    }
}

// ─── Input buffer (JavaScript writes strings here before calling exports) ────

var input_buf: [if (build_options.esp32) (if (build_options.device_lite) 2048 else 4096) else 16384]u8 = undefined;

/// Get a writable pointer to the input buffer.
/// JavaScript writes UTF-8 bytes here, then passes the length to export functions.
export fn qstar_get_input_ptr() [*]u8 {
    return &input_buf;
}

// ─── Output buffer (WASM export reads this) ──────────────────────────────────

var output_buf: [if (build_options.esp32) (if (build_options.device_lite) 2048 else 4096) else 16384]u8 = undefined;
var output_len: usize = 0;

// ─── Exported functions ──────────────────────────────────────────────────────

/// Initialize the agent. Call once at startup.
export fn qstar_init() void {
    ensureAgent();
}

/// Ingest a prompt string into the agent's lattice.
/// Returns 0 on success, -1 on error.
export fn qstar_ingest(ptr: [*]const u8, len: usize) i32 {
    ensureAgent();
    const prompt = ptr[0..len];
    agent.?.ingest(prompt) catch return -1;
    return 0;
}

/// Run agent inference for N steps.
export fn qstar_run(steps: u32) void {
    ensureAgent();
    agent.?.run(@intCast(steps)) catch {};
}

/// Decode agent state to text. Returns pointer to output buffer.
/// Use qstar_output_len() to get the length.
export fn qstar_decode() [*]const u8 {
    ensureAgent();
    const text = agent.?.decode(getAllocator()) catch {
        output_len = 0;
        return &output_buf;
    };
    defer getAllocator().free(text);
    const copy_len = @min(text.len, output_buf.len);
    @memcpy(output_buf[0..copy_len], text[0..copy_len]);
    output_len = copy_len;
    return &output_buf;
}

/// Generate long-form response. Returns pointer to output buffer.
export fn qstar_generate_long_form(ptr: [*]const u8, len: usize) [*]const u8 {
    ensureAgent();
    const prompt = ptr[0..len];
    const text = agent.?.generateLongForm(prompt, getAllocator()) catch {
        output_len = 0;
        return &output_buf;
    };
    defer getAllocator().free(text);
    const copy_len = @min(text.len, output_buf.len);
    @memcpy(output_buf[0..copy_len], text[0..copy_len]);
    output_len = copy_len;
    return &output_buf;
}

/// Get the length of the last output buffer.
export fn qstar_output_len() usize {
    return output_len;
}

/// Get the agent's E0 activation at index i (downscaled to Q32.32 for WASM interface).
export fn qstar_get_activation(i: usize) i64 {
    ensureAgent();
    if (i >= agent_mod.E0_NODE_COUNT) return 0;
    return fp_bridge.downscaleSaturating(agent.?.state.activations[i][0]);
}

/// Get the number of E0 nodes.
export fn qstar_e0_count() usize {
    return agent_mod.E0_NODE_COUNT;
}

/// Execute a tool call. Returns pointer to JSON result.
/// tool_name: "calculate", "lattice_node", "quantum_simulate"
/// args_json: JSON arguments string
/// Not available in device-lite build (tools module excluded for size).
export fn qstar_tool_execute(tool_ptr: [*]const u8, tool_len: usize, args_ptr: [*]const u8, args_len: usize) [*]const u8 {
    if (build_options.device_lite) {
        output_len = 0;
        return &output_buf;
    }
    const tool_name = tool_ptr[0..tool_len];
    const args_json = args_ptr[0..args_len];

    var reg = tools_mod.ToolRegistry.init(getAllocator());
    defer reg.deinit();

    const call = tools_mod.ToolCall{
        .id = "wasm",
        .name = tool_name,
        .arguments_json = args_json,
    };

    const result = reg.execute(call) catch {
        const err = "{\"error\":\"execution_failed\"}";
        @memcpy(output_buf[0..err.len], err);
        output_len = err.len;
        return &output_buf;
    };
    defer getAllocator().free(result);

    const copy_len = @min(result.len, output_buf.len);
    @memcpy(output_buf[0..copy_len], result[0..copy_len]);
    output_len = copy_len;
    return &output_buf;
}

/// Get the E0 node index for coordinates (x, y, z). Returns -1 if not an E0 node.
export fn qstar_get_e0_index(x: u32, y: u32, z: u32) i64 {
    if (build_options.device_lite) return -1;
    const idx = lattice_mod.e0NodeIndex(x, y, z) orelse return -1;
    return @intCast(idx);
}

/// Get the E0 value (0-7) at lattice coordinates (x, y, z) for a given level.
export fn qstar_get_e_value(x: u32, y: u32, z: u32, level: u8) u32 {
    if (build_options.device_lite) return 0;
    return @intCast(lattice_mod.computeEValue(x, y, z, level));
}

/// Check if a node at (x, y, z) is on the boundary of the lattice at a given level.
export fn qstar_is_boundary(x: u32, y: u32, z: u32, level: u8) bool {
    if (build_options.device_lite) return false;
    return lattice_mod.isBoundaryCoord(x, y, z, level);
}

/// Get the Q32.32 fixed-point ONE value (downscaled from Q64.64 for WASM interface).
export fn qstar_fp_one() i64 {
    return fp_bridge.downscaleSaturating(fp.ONE);
}

/// Convert a fixed-point Q32.32 value to a float64.
export fn qstar_fp_to_f64(val: i64) f64 {
    return @as(f64, @floatFromInt(val)) / @as(f64, @floatFromInt(@as(i64, 1) << 32));
}

/// Deinit the agent (cleanup).
export fn qstar_deinit() void {
    if (agent_initialized) {
        agent.?.deinit();
        agent = null;
        agent_initialized = false;
    }
}

/// Reset agent state (clear activations, output tokens, cycle). Keeps agent alive.
export fn qstar_reset() void {
    ensureAgent();
    agent.?.state.reset();
}

/// Get version string.
export fn qstar_version() [*]const u8 {
    const ver = "3.0.0-qstar";
    @memcpy(output_buf[0..ver.len], ver);
    output_len = ver.len;
    return &output_buf;
}

/// Learn from text (self-training). Text is written to input buffer.
/// Returns the number of new sentences learned.
export fn qstar_learn_from_text(ptr: [*]const u8, len: usize) usize {
    ensureAgent();
    const text = ptr[0..len];
    return agent.?.learnFromText(text) catch 0;
}

/// Get the number of sentences in the agent's corpus.
export fn qstar_get_corpus_sentence_count() usize {
    ensureAgent();
    return agent.?.getCorpusSentenceCount();
}

/// Save the agent's dynamic corpus to the output buffer.
/// Returns pointer to output buffer. Use qstar_output_len() for length.
export fn qstar_save_corpus() [*]const u8 {
    ensureAgent();
    var fbs = std.io.fixedBufferStream(&output_buf);
    agent.?.saveCorpus(fbs.writer()) catch {
        output_len = 0;
        return &output_buf;
    };
    output_len = fbs.pos;
    return &output_buf;
}

/// Load corpus data from a buffer into the agent's dynamic corpus.
/// ptr/len point to the corpus bytes. Returns number of bytes loaded.
export fn qstar_load_corpus(ptr: [*]const u8, len: usize) usize {
    ensureAgent();
    const data = ptr[0..len];
    var fbs = std.io.fixedBufferStream(data);
    return agent.?.loadCorpus(fbs.reader()) catch 0;
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
