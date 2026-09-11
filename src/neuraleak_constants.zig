// ============================================================================
// NEURALEAK CONSTANTS — Entropy Stream
// ============================================================================
//
// Provides the EntropyStream struct used by the neuraleak system to carry
// environmental RF entropy (Wi-Fi jitter, timing deltas, RSSI) into the
// 8-element correlation vector that maps to octonion dimensions.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

/// RF entropy stream from hardware measurements.
/// Used to construct the 8-element per-face correlation vector.
pub const EntropyStream = struct {
    jitter_factor: f64,
    timing_delta_us: f64,
    rssi_dbm: f64,
    timestamp_us: i64,
};

/// Default zero entropy stream (no environmental correlation).
pub fn zeroEntropy() EntropyStream {
    return .{
        .jitter_factor = 0.0,
        .timing_delta_us = 0.0,
        .rssi_dbm = 0.0,
        .timestamp_us = 0,
    };
}

/// Validate that an entropy stream has physically reasonable values.
pub fn validateEntropy(entropy: EntropyStream) bool {
    // Jitter factor is typically 0.0 to 2.0
    if (entropy.jitter_factor < 0.0 or entropy.jitter_factor > 10.0) return false;
    // Timing delta is typically 0 to 10000 microseconds
    if (entropy.timing_delta_us < 0.0 or entropy.timing_delta_us > 100_000.0) return false;
    // RSSI is typically -100 to 0 dBm
    if (entropy.rssi_dbm < -120.0 or entropy.rssi_dbm > 10.0) return false;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "zeroEntropy produces all-zero stream" {
    const e = zeroEntropy();
    try std.testing.expectEqual(@as(f64, 0.0), e.jitter_factor);
    try std.testing.expectEqual(@as(f64, 0.0), e.timing_delta_us);
    try std.testing.expectEqual(@as(f64, 0.0), e.rssi_dbm);
    try std.testing.expectEqual(@as(i64, 0), e.timestamp_us);
}

test "validateEntropy accepts reasonable values" {
    const e = EntropyStream{
        .jitter_factor = 0.37,
        .timing_delta_us = 80.0,
        .rssi_dbm = -62.0,
        .timestamp_us = 1000000,
    };
    try std.testing.expect(validateEntropy(e));
}

test "validateEntropy rejects unreasonable values" {
    try std.testing.expect(!validateEntropy(.{
        .jitter_factor = -1.0,
        .timing_delta_us = 0.0,
        .rssi_dbm = 0.0,
        .timestamp_us = 0,
    }));
    try std.testing.expect(!validateEntropy(.{
        .jitter_factor = 0.0,
        .timing_delta_us = 200_000.0,
        .rssi_dbm = 0.0,
        .timestamp_us = 0,
    }));
    try std.testing.expect(!validateEntropy(.{
        .jitter_factor = 0.0,
        .timing_delta_us = 0.0,
        .rssi_dbm = -200.0,
        .timestamp_us = 0,
    }));
}
