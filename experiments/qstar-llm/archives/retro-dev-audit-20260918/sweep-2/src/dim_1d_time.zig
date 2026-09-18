//! dim_1d_time.zig — 1D Time (Line/Real numbers dimension).
//!
//! The 1D dimension handles token sequences, temporal processing, and character streams.
//! Algebra: Real numbers (U(1) electromagnetism).
//! Purpose: Token sequences, temporal ordering, sequence operations.
//!
//! All arithmetic is integer-only. No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");

/// The 1D time sequence — a sequence of tokens with temporal ordering.
pub const TimeSequence = struct {
    tokens: std.ArrayList(u32),
    allocator: std.mem.Allocator,
    /// Current position in the sequence (temporal index).
    position: u64,

    pub fn init(allocator: std.mem.Allocator) TimeSequence {
        return .{
            .tokens = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
            .position = 0,
        };
    }

    pub fn deinit(self: *TimeSequence) void {
        self.tokens.deinit();
    }

    /// Appends a token to the sequence.
    pub fn append(self: *TimeSequence, token: u32) !void {
        try self.tokens.append(token);
    }

    /// Returns the sequence length.
    pub fn len(self: TimeSequence) usize {
        return self.tokens.items.len;
    }

    /// Returns the token at the given temporal index.
    pub fn at(self: TimeSequence, index: usize) ?u32 {
        if (index >= self.tokens.items.len) return null;
        return self.tokens.items[index];
    }

    /// Advances the temporal position by one step.
    pub fn advance(self: *TimeSequence) void {
        self.position += 1;
    }

    /// Returns the current temporal position.
    pub fn currentPosition(self: TimeSequence) u64 {
        return self.position;
    }

    /// Resets the temporal position to the beginning.
    pub fn reset(self: *TimeSequence) void {
        self.position = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TimeSequence: init and append" {
    var seq = TimeSequence.init(std.testing.allocator);
    defer seq.deinit();
    try seq.append(1);
    try seq.append(2);
    try seq.append(3);
    try std.testing.expect(seq.len() == 3);
}

test "TimeSequence: at returns token at index" {
    var seq = TimeSequence.init(std.testing.allocator);
    defer seq.deinit();
    try seq.append(10);
    try seq.append(20);
    try seq.append(30);
    try std.testing.expect(seq.at(0) == 10);
    try std.testing.expect(seq.at(1) == 20);
    try std.testing.expect(seq.at(2) == 30);
    try std.testing.expect(seq.at(3) == null);
}

test "TimeSequence: advance and position" {
    var seq = TimeSequence.init(std.testing.allocator);
    defer seq.deinit();
    try std.testing.expect(seq.currentPosition() == 0);
    seq.advance();
    try std.testing.expect(seq.currentPosition() == 1);
    seq.advance();
    try std.testing.expect(seq.currentPosition() == 2);
}

test "TimeSequence: reset position" {
    var seq = TimeSequence.init(std.testing.allocator);
    defer seq.deinit();
    seq.advance();
    seq.advance();
    seq.advance();
    try std.testing.expect(seq.currentPosition() == 3);
    seq.reset();
    try std.testing.expect(seq.currentPosition() == 0);
}

test "TimeSequence: empty sequence" {
    var seq = TimeSequence.init(std.testing.allocator);
    defer seq.deinit();
    try std.testing.expect(seq.len() == 0);
    try std.testing.expect(seq.at(0) == null);
}
