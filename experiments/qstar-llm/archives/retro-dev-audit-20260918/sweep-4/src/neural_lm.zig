//! neural_lm.zig — Tiny neural language model backend via ONNX Runtime.
//!
//! This is an f64/f32 SIDECAR module. ONNX inference runs in float32/float16.
//! Logits are returned as f32 at the sidecar boundary. The caller (agent.zig)
//! converts to Q128.128 at the core boundary.
//!
//! Architecture: Qwen3-0.6B (28 layers, 8 KV heads, 128 head_dim, vocab 151936)
//! Model format: ONNX q4f16 (4-bit quantized weights, float16 KV cache)
//!
//! Integration mode: HYBRID
//!   - Neural LM provides base logits (fluency/naturalness)
//!   - Lattice provides topical bias (domain knowledge from corpus)
//!   - Combined in agent.sampledStep via applyNeuralLogits

const std = @import("std");
const onnx = @import("onnx_runtime");
const c_ffi = @import("c_ffi");

// =============================================================================
// Model constants (Qwen3-0.6B)
// =============================================================================

pub const NUM_LAYERS: u32 = 28;
pub const NUM_KV_HEADS: u32 = 8;
pub const HEAD_DIM: u32 = 128;
pub const VOCAB_SIZE: u32 = 151936;
pub const MAX_SEQ_LEN: usize = 4096;

// KV cache element count per layer per type (key or value)
// Shape: [1, 8, seq_len, 128]
fn kvElementCount(seq_len: usize) usize {
    return 1 * NUM_KV_HEADS * seq_len * HEAD_DIM;
}

// KV cache byte size per layer per type
fn kvByteSize(seq_len: usize) usize {
    return kvElementCount(seq_len) * @sizeOf(f16);
}

// Total KV cache size for all layers (key + value)
fn totalKvByteSize(seq_len: usize) usize {
    return NUM_LAYERS * 2 * kvByteSize(seq_len);
}

// =============================================================================
// NeuralLM — ONNX-based neural language model with KV cache
// =============================================================================

pub const NeuralLM = struct {
    ctx: *onnx.OnnxContext,
    session: onnx.Session,
    allocator: std.mem.Allocator,

    // KV cache: for each layer, key and value
    // Shape: [1, 8, seq_len, 128] in float16
    kv_keys: [][]f16,
    kv_values: [][]f16,
    kv_seq_len: usize,

    // Pre-allocated input/output name arrays (null-terminated)
    input_names: []const [*:0]const u8,
    output_names: []const [*:0]const u8,
    input_name_storage: std.ArrayList([:0]u8),
    output_name_storage: std.ArrayList([:0]u8),

    // Pre-allocated input shapes
    input_shapes: []onnx.InputTensor,
    kv_shapes: [][]i64,

    // Scratch buffers for inputs
    input_ids_buf: []i64,
    attention_mask_buf: []i64,
    position_ids_buf: []i64,

    // Logits output buffer
    logits_buf: []f32,

    // Whether the model is initialized
    initialized: bool,

    /// Initialize the neural LM by loading the ONNX model.
    /// model_path must be a null-terminated string pointing to the .onnx file.
    pub fn init(allocator: std.mem.Allocator, model_path: [:0]const u8) !NeuralLM {
        // Create ONNX context
        var ctx = try allocator.create(onnx.OnnxContext);
        ctx.* = onnx.OnnxContext.init(allocator) catch |err| {
            allocator.destroy(ctx);
            return err;
        };

        // Create session
        const session = onnx.Session.create(ctx, model_path, allocator) catch |err| {
            ctx.deinit();
            allocator.destroy(ctx);
            return err;
        };

        var self = NeuralLM{
            .ctx = ctx,
            .session = session,
            .allocator = allocator,
            .kv_keys = try allocator.alloc([]f16, NUM_LAYERS),
            .kv_values = try allocator.alloc([]f16, NUM_LAYERS),
            .kv_seq_len = 0,
            .input_names = &.{},
            .output_names = &.{},
            .input_name_storage = std.ArrayList([:0]u8).init(allocator),
            .output_name_storage = std.ArrayList([:0]u8).init(allocator),
            .input_shapes = &.{},
            .kv_shapes = &.{},
            .input_ids_buf = &.{},
            .attention_mask_buf = &.{},
            .position_ids_buf = &.{},
            .logits_buf = &.{},
            .initialized = false,
        };

        // Initialize empty KV cache
        for (0..NUM_LAYERS) |i| {
            self.kv_keys[i] = try allocator.alloc(f16, 0);
            self.kv_values[i] = try allocator.alloc(f16, 0);
        }

        // Build input/output name arrays
        try self.buildNameArrays();

        // Pre-allocate logits buffer
        self.logits_buf = try allocator.alloc(f32, VOCAB_SIZE);

        // Pre-allocate scratch buffers for single-token generation
        self.input_ids_buf = try allocator.alloc(i64, 1);
        self.attention_mask_buf = try allocator.alloc(i64, MAX_SEQ_LEN);
        self.position_ids_buf = try allocator.alloc(i64, 1);

        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *NeuralLM) void {
        // Free KV cache
        for (0..NUM_LAYERS) |i| {
            self.allocator.free(self.kv_keys[i]);
            self.allocator.free(self.kv_values[i]);
        }
        self.allocator.free(self.kv_keys);
        self.allocator.free(self.kv_values);

        // Free name storage
        for (self.input_name_storage.items) |name| self.allocator.free(name);
        for (self.output_name_storage.items) |name| self.allocator.free(name);
        self.input_name_storage.deinit();
        self.output_name_storage.deinit();

        // Free shapes
        if (self.input_shapes.len > 0) self.allocator.free(self.input_shapes);
        if (self.kv_shapes.len > 0) {
            for (self.kv_shapes) |shape| self.allocator.free(shape);
            self.allocator.free(self.kv_shapes);
        }

        // Free scratch buffers
        if (self.input_ids_buf.len > 0) self.allocator.free(self.input_ids_buf);
        if (self.attention_mask_buf.len > 0) self.allocator.free(self.attention_mask_buf);
        if (self.position_ids_buf.len > 0) self.allocator.free(self.position_ids_buf);
        if (self.logits_buf.len > 0) self.allocator.free(self.logits_buf);

        // Destroy session and context
        self.session.destroy();
        self.ctx.deinit();
        self.allocator.destroy(self.ctx);
    }

    /// Build the 59 input names and 57 output names as null-terminated strings.
    fn buildNameArrays(self: *NeuralLM) !void {
        // Input names: input_ids, attention_mask, position_ids, past_key_values.{0..27}.key, past_key_values.{0..27}.value
        const static_input_names = [_][]const u8{ "input_ids", "attention_mask", "position_ids" };
        for (static_input_names) |name| {
            const owned = try self.allocator.dupeZ(u8, name);
            try self.input_name_storage.append(owned);
        }
        for (0..NUM_LAYERS) |layer| {
            // past_key_values.{layer}.key
            const key_name = try std.fmt.allocPrintZ(self.allocator, "past_key_values.{d}.key", .{layer});
            try self.input_name_storage.append(key_name);
            // past_key_values.{layer}.value
            const val_name = try std.fmt.allocPrintZ(self.allocator, "past_key_values.{d}.value", .{layer});
            try self.input_name_storage.append(val_name);
        }

        // Output names: logits, present.{0..27}.key, present.{0..27}.value
        const logits_name = try self.allocator.dupeZ(u8, "logits");
        try self.output_name_storage.append(logits_name);
        for (0..NUM_LAYERS) |layer| {
            const key_name = try std.fmt.allocPrintZ(self.allocator, "present.{d}.key", .{layer});
            try self.output_name_storage.append(key_name);
            const val_name = try std.fmt.allocPrintZ(self.allocator, "present.{d}.value", .{layer});
            try self.output_name_storage.append(val_name);
        }

        // Build pointer arrays
        const input_ptrs = try self.allocator.alloc([*:0]const u8, self.input_name_storage.items.len);
        for (self.input_name_storage.items, 0..) |name, i| {
            input_ptrs[i] = name.ptr;
        }
        self.input_names = input_ptrs;

        const output_ptrs = try self.allocator.alloc([*:0]const u8, self.output_name_storage.items.len);
        for (self.output_name_storage.items, 0..) |name, i| {
            output_ptrs[i] = name.ptr;
        }
        self.output_names = output_ptrs;
    }

    /// Reset the KV cache to start a new generation.
    pub fn reset(self: *NeuralLM) void {
        for (0..NUM_LAYERS) |i| {
            // Free old cache and allocate empty
            if (self.kv_keys[i].len > 0) self.allocator.free(self.kv_keys[i]);
            if (self.kv_values[i].len > 0) self.allocator.free(self.kv_values[i]);
            self.kv_keys[i] = self.allocator.alloc(f16, 0) catch return;
            self.kv_values[i] = self.allocator.alloc(f16, 0) catch return;
        }
        self.kv_seq_len = 0;
    }

    /// Process a prompt (first forward pass with empty KV cache).
    /// Returns logits for the last token position.
    /// The KV cache is updated to contain all prompt tokens.
    pub fn processPrompt(self: *NeuralLM, input_ids: []const i64) ![]f32 {
        if (input_ids.len == 0) return error.EmptyInput;
        if (input_ids.len > MAX_SEQ_LEN) return error.SequenceTooLong;

        const seq_len = input_ids.len;

        // Build input tensors
        var inputs = try self.allocator.alloc(onnx.InputTensor, self.input_names.len);
        defer self.allocator.free(inputs);

        // input_ids: [1, seq_len] int64
        var input_ids_shape = [_]i64{ 1, @intCast(seq_len) };
        inputs[0] = .{
            .name = self.input_names[0],
            .data = @constCast(input_ids.ptr),
            .data_len = seq_len * @sizeOf(i64),
            .shape = &input_ids_shape,
            .dtype = .Int64,
        };

        // attention_mask: [1, seq_len] int64 (all 1s)
        const attention_mask = try self.allocator.alloc(i64, seq_len);
        defer self.allocator.free(attention_mask);
        for (attention_mask) |*v| v.* = 1;
        var mask_shape = [_]i64{ 1, @intCast(seq_len) };
        inputs[1] = .{
            .name = self.input_names[1],
            .data = attention_mask.ptr,
            .data_len = seq_len * @sizeOf(i64),
            .shape = &mask_shape,
            .dtype = .Int64,
        };

        // position_ids: [1, seq_len] int64 (0, 1, ..., seq_len-1)
        const position_ids = try self.allocator.alloc(i64, seq_len);
        defer self.allocator.free(position_ids);
        for (position_ids, 0..) |*v, i| v.* = @intCast(i);
        var pos_shape = [_]i64{ 1, @intCast(seq_len) };
        inputs[2] = .{
            .name = self.input_names[2],
            .data = position_ids.ptr,
            .data_len = seq_len * @sizeOf(i64),
            .shape = &pos_shape,
            .dtype = .Int64,
        };

        // KV cache inputs: empty [1, 8, 0, 128] (batch_size=1, seq_len=0)
        var empty_kv_shape = [_]i64{ 1, @intCast(NUM_KV_HEADS), 0, @intCast(HEAD_DIM) };
        var empty_kv_data: [0]f16 = .{};
        for (0..NUM_LAYERS) |layer| {
            const key_idx = 3 + layer * 2;
            const val_idx = 4 + layer * 2;
            inputs[key_idx] = .{
                .name = self.input_names[key_idx],
                .data = @ptrCast(&empty_kv_data),
                .data_len = 0,
                .shape = &empty_kv_shape,
                .dtype = .Float16,
            };
            inputs[val_idx] = .{
                .name = self.input_names[val_idx],
                .data = @ptrCast(&empty_kv_data),
                .data_len = 0,
                .shape = &empty_kv_shape,
                .dtype = .Float16,
            };
        }

        // Run inference
        const outputs = try self.session.run(inputs, self.output_names);
        defer self.session.releaseOutputs(outputs);

        // Extract logits: [1, seq_len, vocab_size] → take last position
        const logits_data = try outputs[0].getData(self.ctx.api, f32);
        const last_token_offset = (seq_len - 1) * VOCAB_SIZE;
        @memcpy(self.logits_buf, logits_data[last_token_offset .. last_token_offset + VOCAB_SIZE]);

        // Extract and store KV cache from present outputs
        try self.updateKvCache(outputs, seq_len);

        return self.logits_buf;
    }

    /// Generate logits for the next token (single-token forward pass with KV cache).
    /// Returns logits [vocab_size] as f32.
    /// The KV cache is updated to include the new token.
    pub fn nextTokenLogits(self: *NeuralLM, token_id: i64) ![]f32 {
        if (self.kv_seq_len == 0) return error.CacheEmpty;
        if (self.kv_seq_len >= MAX_SEQ_LEN) return error.SequenceTooLong;

        const new_seq_len = self.kv_seq_len + 1;

        // Build input tensors
        var inputs = try self.allocator.alloc(onnx.InputTensor, self.input_names.len);
        defer self.allocator.free(inputs);

        // input_ids: [1, 1] int64
        self.input_ids_buf[0] = token_id;
        var input_ids_shape = [_]i64{ 1, 1 };
        inputs[0] = .{
            .name = self.input_names[0],
            .data = self.input_ids_buf.ptr,
            .data_len = @sizeOf(i64),
            .shape = &input_ids_shape,
            .dtype = .Int64,
        };

        // attention_mask: [1, new_seq_len] int64 (all 1s)
        for (self.attention_mask_buf[0..new_seq_len]) |*v| v.* = 1;
        var mask_shape = [_]i64{ 1, @intCast(new_seq_len) };
        inputs[1] = .{
            .name = self.input_names[1],
            .data = self.attention_mask_buf.ptr,
            .data_len = new_seq_len * @sizeOf(i64),
            .shape = &mask_shape,
            .dtype = .Int64,
        };

        // position_ids: [1, 1] int64 (kv_seq_len)
        self.position_ids_buf[0] = @intCast(self.kv_seq_len);
        var pos_shape = [_]i64{ 1, 1 };
        inputs[2] = .{
            .name = self.input_names[2],
            .data = self.position_ids_buf.ptr,
            .data_len = @sizeOf(i64),
            .shape = &pos_shape,
            .dtype = .Int64,
        };

        // KV cache inputs: [1, 8, kv_seq_len, 128]
        var kv_shape = [_]i64{ 1, @intCast(NUM_KV_HEADS), @intCast(self.kv_seq_len), @intCast(HEAD_DIM) };
        for (0..NUM_LAYERS) |layer| {
            const key_idx = 3 + layer * 2;
            const val_idx = 4 + layer * 2;
            inputs[key_idx] = .{
                .name = self.input_names[key_idx],
                .data = self.kv_keys[layer].ptr,
                .data_len = self.kv_keys[layer].len * @sizeOf(f16),
                .shape = &kv_shape,
                .dtype = .Float16,
            };
            inputs[val_idx] = .{
                .name = self.input_names[val_idx],
                .data = self.kv_values[layer].ptr,
                .data_len = self.kv_values[layer].len * @sizeOf(f16),
                .shape = &kv_shape,
                .dtype = .Float16,
            };
        }

        // Run inference
        const outputs = try self.session.run(inputs, self.output_names);
        defer self.session.releaseOutputs(outputs);

        // Extract logits: [1, 1, vocab_size]
        const logits_data = try outputs[0].getData(self.ctx.api, f32);
        @memcpy(self.logits_buf, logits_data[0..VOCAB_SIZE]);

        // Update KV cache
        try self.updateKvCache(outputs, new_seq_len);

        return self.logits_buf;
    }

    /// Update KV cache from present key/value outputs.
    fn updateKvCache(self: *NeuralLM, outputs: []onnx.OutputTensor, new_seq_len: usize) !void {
        for (0..NUM_LAYERS) |layer| {
            const key_out_idx = 1 + layer * 2;
            const val_out_idx = 2 + layer * 2;

            // Get present key
            const present_key = try outputs[key_out_idx].getData(self.ctx.api, f16);
            // Free old cache and store new
            if (self.kv_keys[layer].len > 0) self.allocator.free(self.kv_keys[layer]);
            self.kv_keys[layer] = try self.allocator.dupe(f16, present_key);

            // Get present value
            const present_val = try outputs[val_out_idx].getData(self.ctx.api, f16);
            if (self.kv_values[layer].len > 0) self.allocator.free(self.kv_values[layer]);
            self.kv_values[layer] = try self.allocator.dupe(f16, present_val);
        }
        self.kv_seq_len = new_seq_len;
    }

    /// Check if ONNX Runtime is available on this system.
    pub fn isAvailable() bool {
        return onnx.OnnxContext.isAvailable();
    }

    /// Get current KV cache sequence length.
    pub fn cacheLen(self: *const NeuralLM) usize {
        return self.kv_seq_len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "neural_lm: isAvailable detects ONNX Runtime" {
    // This test just checks if the library is loadable, doesn't require a model
    _ = NeuralLM.isAvailable();
}

test "neural_lm: kvElementCount computes correctly" {
    try std.testing.expectEqual(@as(usize, 0), kvElementCount(0));
    try std.testing.expectEqual(@as(usize, 1024), kvElementCount(1));
    try std.testing.expectEqual(@as(usize, 2048), kvElementCount(2));
    try std.testing.expectEqual(@as(usize, 1024 * 128), kvElementCount(128));
}

test "neural_lm: kvByteSize computes correctly" {
    try std.testing.expectEqual(@as(usize, 0), kvByteSize(0));
    try std.testing.expectEqual(@as(usize, 2048), kvByteSize(1));
    try std.testing.expectEqual(@as(usize, 4096), kvByteSize(2));
}

test "neural_lm: totalKvByteSize computes correctly" {
    // 28 layers × 2 (key+value) × 1024 elements × 2 bytes = 114688 bytes per token
    try std.testing.expectEqual(@as(usize, 28 * 2 * 2048), totalKvByteSize(1));
    try std.testing.expectEqual(@as(usize, 0), totalKvByteSize(0));
}
