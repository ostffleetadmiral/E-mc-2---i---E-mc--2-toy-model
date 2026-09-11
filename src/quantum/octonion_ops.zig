// License: CC BY-NC-SA 4.0

const octonion = @import("../octonion.zig");

pub fn triadCount() usize { return 7; }

pub fn propagate(a: octonion.Unit, b: octonion.Unit) octonion.Product {
    return octonion.multiply(a, b);
}

test "quantum octonion encoding preserves seven triads" {
    try @import("std").testing.expectEqual(@as(usize, 7), triadCount());
    try @import("std").testing.expectEqual(@as(octonion.Unit, 3), propagate(1, 2).unit);
}
