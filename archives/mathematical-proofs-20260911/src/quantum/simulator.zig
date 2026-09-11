const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");
const gates = @import("gates.zig");

pub const Simulator = struct {
    amplitudes: [2]state.Complex,

    pub fn zero() Simulator {
        return .{ .amplitudes = .{ state.Complex.one, state.Complex.zero } };
    }

    pub fn applyHadamard(self: *Simulator) void {
        self.amplitudes = gates.hadamard(self.amplitudes);
    }

    pub fn applyX(self: *Simulator) void {
        self.amplitudes = gates.pauliX(self.amplitudes);
    }

    pub fn applyPhaseI(self: *Simulator) void {
        self.amplitudes = gates.phaseI(self.amplitudes);
    }

    pub fn normSquared(self: Simulator) fixed.Q128 {
        return self.amplitudes[0].normSquared().add(self.amplitudes[1].normSquared());
    }

    pub fn probabilityOne(self: Simulator) fixed.Q128 {
        return self.amplitudes[1].normSquared();
    }
};

test "simulator executes a reversible X operation" {
    var simulator = Simulator.zero();
    simulator.applyX();
    simulator.applyX();
    try @import("std").testing.expectEqual(@as(i256, 0), simulator.probabilityOne().raw);
    try @import("std").testing.expectEqual(fixed.Scale, simulator.normSquared().raw);
}
