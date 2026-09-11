const std = @import("std");
const values = @import("codata_values.zig");

pub fn relativeError(actual: f64, expected: f64) f64 {
    return @abs(actual - expected) / @abs(expected);
}

test "CODATA alpha relationship" {
    try std.testing.expectApproxEqAbs(values.alpha, 1.0 / values.alpha_inverse, 1e-15);
}

test "classical electron radius and Thomson relation" {
    const derived = (8.0 * std.math.pi / 3.0) * values.electron_classical_radius * values.electron_classical_radius;
    try std.testing.expect(relativeError(derived, values.thomson_cross_section) < 1e-9);
}

pub fn validateCsv() !usize {
    const file = try std.fs.cwd().openFile("../mound_triad_results.csv", .{});
    defer file.close();
    const data = try file.readToEndAlloc(std.heap.page_allocator, 4 * 1024 * 1024);
    defer std.heap.page_allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next() orelse return error.MissingHeader;
    var rows: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        var values_seen: [10][]const u8 = undefined;
        var count: usize = 0;
        while (fields.next()) |field| {
            if (count >= values_seen.len) return error.InvalidColumnCount;
            values_seen[count] = field;
            count += 1;
        }
        if (count != 10) return error.InvalidColumnCount;
        const a = try std.fmt.parseInt(i32, values_seen[5], 10);
        const b = try std.fmt.parseInt(i32, values_seen[6], 10);
        const c = try std.fmt.parseInt(i32, values_seen[7], 10);
        const expected = try std.fmt.parseFloat(f64, values_seen[8]);
        const calculated = @import("verify_triad.zig").triad(a, b, c);
        try std.testing.expectApproxEqRel(expected, calculated, 1e-12);
        rows += 1;
    }
    return rows;
}

test "all 145 CSV triad rows are parseable and reproducible" {
    try std.testing.expectEqual(@as(usize, 145), try validateCsv());
}
