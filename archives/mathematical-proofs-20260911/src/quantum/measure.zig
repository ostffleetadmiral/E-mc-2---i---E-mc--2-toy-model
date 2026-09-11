const fixed = @import("../fixed_point.zig");
const simulator = @import("simulator.zig");

pub fn deterministicBasisMeasurement(value: fixed.Q128) u1 {
    return if (value.raw >= fixed.Scale / 2) 1 else 0;
}

pub fn measureOne(sim: simulator.Simulator) u1 {
    return deterministicBasisMeasurement(sim.probabilityOne());
}

test "basis measurement is deterministic" {
    var sim = simulator.Simulator.zero();
    try @import("std").testing.expectEqual(@as(u1, 0), measureOne(sim));
    sim.applyX();
    try @import("std").testing.expectEqual(@as(u1, 1), measureOne(sim));
}
