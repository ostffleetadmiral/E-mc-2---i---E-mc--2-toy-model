// ============================================================================
// NEURALEAK CONSTANTS — Entropy Stream
// ============================================================================
//
// Provides the EntropyStream struct used by the neuraleak system to carry
// environmental RF entropy (Wi-Fi jitter, timing deltas, RSSI) into the
// 8-element correlation vector that maps to octonion dimensions.
//
// All values use integer representations:
//   jitter_factor: scaled by 1000 (e.g., 0.37 → 370)
//   timing_delta_us: microseconds as i64 (e.g., 80.0 → 80)
//   rssi_dbm: centi-dBm as i32 (e.g., -62.0 → -6200)
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

/// RF entropy stream from hardware measurements.
/// Used to construct the 8-element per-face correlation vector.
/// All fields are integer-scaled to avoid floating point in core.
pub const EntropyStream = struct {
    jitter_factor_milli: i32, // jitter_factor * 1000 (e.g., 0.37 → 370)
    timing_delta_us: i64, // microseconds directly
    rssi_centi_dbm: i32, // RSSI * 100 (e.g., -62.0 dBm → -6200)
    timestamp_us: i64,
};

/// Default zero entropy stream (no environmental correlation).
pub fn zeroEntropy() EntropyStream {
    return .{
        .jitter_factor_milli = 0,
        .timing_delta_us = 0,
        .rssi_centi_dbm = 0,
        .timestamp_us = 0,
    };
}

/// Validate that an entropy stream has physically reasonable values.
pub fn validateEntropy(entropy: EntropyStream) bool {
    // Jitter factor is typically 0.0 to 2.0 (0 to 2000 milli)
    if (entropy.jitter_factor_milli < 0 or entropy.jitter_factor_milli > 10_000) return false;
    // Timing delta is typically 0 to 10000 microseconds
    if (entropy.timing_delta_us < 0 or entropy.timing_delta_us > 100_000) return false;
    // RSSI is typically -100 to 0 dBm (-10000 to 0 centi-dBm)
    if (entropy.rssi_centi_dbm < -12_000 or entropy.rssi_centi_dbm > 1_000) return false;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "zeroEntropy produces all-zero stream" {
    const e = zeroEntropy();
    try std.testing.expectEqual(@as(i32, 0), e.jitter_factor_milli);
    try std.testing.expectEqual(@as(i64, 0), e.timing_delta_us);
    try std.testing.expectEqual(@as(i32, 0), e.rssi_centi_dbm);
    try std.testing.expectEqual(@as(i64, 0), e.timestamp_us);
}

test "validateEntropy accepts reasonable values" {
    const e = EntropyStream{
        .jitter_factor_milli = 370, // 0.37
        .timing_delta_us = 80,
        .rssi_centi_dbm = -6200, // -62.0 dBm
        .timestamp_us = 1000000,
    };
    try std.testing.expect(validateEntropy(e));
}

test "validateEntropy rejects unreasonable values" {
    try std.testing.expect(!validateEntropy(.{
        .jitter_factor_milli = -1000, // -1.0
        .timing_delta_us = 0,
        .rssi_centi_dbm = 0,
        .timestamp_us = 0,
    }));
    try std.testing.expect(!validateEntropy(.{
        .jitter_factor_milli = 0,
        .timing_delta_us = 200_000,
        .rssi_centi_dbm = 0,
        .timestamp_us = 0,
    }));
    try std.testing.expect(!validateEntropy(.{
        .jitter_factor_milli = 0,
        .timing_delta_us = 0,
        .rssi_centi_dbm = -20_000, // -200.0 dBm
        .timestamp_us = 0,
    }));
}

test "validateEntropy accepts boundary values" {
    // Maximum jitter = 10.0 → 10000 milli
    try std.testing.expect(validateEntropy(.{
        .jitter_factor_milli = 10_000,
        .timing_delta_us = 0,
        .rssi_centi_dbm = 0,
        .timestamp_us = 0,
    }));
    // Maximum timing = 100000 us
    try std.testing.expect(validateEntropy(.{
        .jitter_factor_milli = 0,
        .timing_delta_us = 100_000,
        .rssi_centi_dbm = 0,
        .timestamp_us = 0,
    }));
    // Minimum RSSI = -120.0 dBm → -12000 centi-dBm
    try std.testing.expect(validateEntropy(.{
        .jitter_factor_milli = 0,
        .timing_delta_us = 0,
        .rssi_centi_dbm = -12_000,
        .timestamp_us = 0,
    }));
}

test "entropy stream fields are integers (no f64)" {
    const e = EntropyStream{
        .jitter_factor_milli = 370,
        .timing_delta_us = 80,
        .rssi_centi_dbm = -6200,
        .timestamp_us = 1000000,
    };
    // Verify all fields are integer types
    try std.testing.expect(@TypeOf(e.jitter_factor_milli) == i32);
    try std.testing.expect(@TypeOf(e.timing_delta_us) == i64);
    try std.testing.expect(@TypeOf(e.rssi_centi_dbm) == i32);
    try std.testing.expect(@TypeOf(e.timestamp_us) == i64);
}
