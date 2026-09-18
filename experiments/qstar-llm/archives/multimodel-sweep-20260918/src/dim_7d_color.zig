//! dim_7d_color.zig — 7D Color (Octonion dimension).
//!
//! The 7D dimension handles octonion channel routing.
//! Algebra: Octonions (SU(3) strong force).
//! Purpose: 7-channel routing, non-associative routing.
//!
//! All arithmetic is integer-only. No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const oct = @import("octonion_math");

/// The 7D color router — routes tokens across 7 octonionic channels.
pub const ColorRouter = struct {
    /// Number of channels (7 for octonions, excluding the real part).
    channel_count: u8,
    /// Current channel selection (0-6).
    current_channel: u3,
    /// Channel activation weights (Q64.64 fixed-point).
    weights: [7]i128,

    pub fn init() ColorRouter {
        return .{
            .channel_count = 7,
            .current_channel = 0,
            .weights = [_]i128{0} ** 7,
        };
    }

    /// Sets the weight for a channel.
    pub fn setWeight(self: *ColorRouter, channel: u3, w: i128) void {
        self.weights[channel] = w;
    }

    /// Returns the weight for a channel.
    pub fn weight(self: ColorRouter, channel: u3) i128 {
        return self.weights[channel];
    }

    /// Routes to the channel with the highest weight.
    pub fn routeToMax(self: *ColorRouter) void {
        var max_weight: i128 = self.weights[0];
        var max_channel: u3 = 0;
        for (1..7) |i| {
            if (self.weights[i] > max_weight) {
                max_weight = self.weights[i];
                max_channel = @intCast(i);
            }
        }
        self.current_channel = max_channel;
    }

    /// Returns the current channel.
    pub fn currentChannel(self: ColorRouter) u3 {
        return self.current_channel;
    }

    /// Resets all weights to zero.
    pub fn reset(self: *ColorRouter) void {
        self.current_channel = 0;
        self.weights = [_]i128{0} ** 7;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ColorRouter: init" {
    const router = ColorRouter.init();
    try std.testing.expect(router.channel_count == 7);
    try std.testing.expect(router.current_channel == 0);
    for (router.weights) |w| try std.testing.expect(w == 0);
}

test "ColorRouter: setWeight and weight" {
    var router = ColorRouter.init();
    router.setWeight(3, 100);
    try std.testing.expect(router.weight(3) == 100);
    try std.testing.expect(router.weight(0) == 0);
}

test "ColorRouter: routeToMax" {
    var router = ColorRouter.init();
    router.setWeight(0, 10);
    router.setWeight(3, 50);
    router.setWeight(5, 30);
    router.routeToMax();
    try std.testing.expect(router.currentChannel() == 3);
}

test "ColorRouter: reset" {
    var router = ColorRouter.init();
    router.setWeight(2, 100);
    router.routeToMax();
    router.reset();
    try std.testing.expect(router.currentChannel() == 0);
    for (router.weights) |w| try std.testing.expect(w == 0);
}

test "ColorRouter: 7 channels (octonionic)" {
    const router = ColorRouter.init();
    // 7 channels = 7 octonionic imaginary units (e1-e7)
    try std.testing.expect(router.channel_count == 7);
}
