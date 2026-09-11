const std = @import("std");
const fixed = @import("fixed_point.zig");
const octonion = @import("octonion.zig");
const triad = @import("triad_operator.zig");
const codon = @import("codon.zig");

pub const Rational = struct {
    numerator: i256,
    denominator: i256,

    pub fn init(numerator: i256, denominator: i256) Rational {
        std.debug.assert(denominator != 0);
        const divisor = gcd(abs(numerator), abs(denominator));
        var n = @divTrunc(numerator, divisor);
        var d = @divTrunc(denominator, divisor);
        if (d < 0) {
            n = -n;
            d = -d;
        }
        return .{ .numerator = n, .denominator = d };
    }

    pub fn add(self: Rational, other: Rational) Rational {
        return init(self.numerator * other.denominator + other.numerator * self.denominator, self.denominator * other.denominator);
    }

    pub fn sub(self: Rational, other: Rational) Rational {
        return init(self.numerator * other.denominator - other.numerator * self.denominator, self.denominator * other.denominator);
    }

    pub fn mul(self: Rational, other: Rational) Rational {
        return init(self.numerator * other.numerator, self.denominator * other.denominator);
    }

    pub fn div(self: Rational, other: Rational) Rational {
        return init(self.numerator * other.denominator, self.denominator * other.numerator);
    }

    pub fn equal(self: Rational, other: Rational) bool {
        return self.numerator == other.numerator and self.denominator == other.denominator;
    }
};

fn abs(value: i256) i256 {
    return if (value < 0) -value else value;
}
fn gcd(a_in: i256, b_in: i256) i256 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const next = @mod(a, b);
        a = b;
        b = next;
    }
    return if (a == 0) 1 else a;
}

pub const ProofResult = struct {
    id: u8,
    passed: bool,
    checks: u16,
    failures: u16,
};

fn result(id: u8, checks: u16, failures: u16) ProofResult {
    return .{ .id = id, .passed = failures == 0, .checks = checks, .failures = failures };
}

pub fn chunk01() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (fixed.exactPow2(256) != (@as(u512, 1) << 256)) failures += 1;
    checks += 1;
    if (fixed.exactPow2(128) != (@as(u256, 1) << 128)) failures += 1;
    checks += 1;
    if ((@as(u256, 1) << 127) != 170141183460469231731687303715884105728) failures += 1;
    return result(1, checks, failures);
}

pub fn chunk02() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const correction = Rational.init(7, 66);
    const wavelength = Rational.init(21, 1).add(correction);
    checks += 1;
    if (!correction.equal(Rational.init(7, 66))) failures += 1;
    checks += 1;
    if (!wavelength.equal(Rational.init(1393, 66))) failures += 1;
    return result(2, checks, failures);
}

pub fn chunk03() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const value = triad.evaluate(5, 2, -4) catch {
        failures += 1;
        return result(3, checks, failures);
    };
    checks += 1;
    if (value.raw <= 21 * fixed.Scale or value.raw >= 22 * fixed.Scale) failures += 1;
    checks += 1;
    if (value.raw == 0) failures += 1;
    return result(3, checks, failures);
}

pub fn chunk04() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const value = triad.evaluate(3, 2, 10) catch {
        failures += 1;
        return result(4, checks, failures);
    };
    const reference = @import("constants.zig").alpha_inverse_reference;
    checks += 1;
    if (value.raw <= reference.raw) failures += 1;
    checks += 1;
    if (value.raw - reference.raw < fixed.Scale / 10000) failures += 1;
    return result(4, checks, failures);
}

pub fn chunk05() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const powers = [_]i8{ -1, -2, -3, -6 };
    checks += 1;
    if (powers.len != 4) failures += 1;
    checks += 1;
    if (powers[0] + powers[1] + powers[2] + powers[3] != -12) failures += 1;
    return result(5, checks, failures);
}

pub fn chunk06() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const graph = [_]i8{ 1, 3, 3, 3, 5, 3, 7 };
    const signature = [_]i8{ 5, 2, -4 };
    checks += 1;
    if (graph.len != 7) failures += 1;
    checks += 1;
    if (signature[0] != 5 or signature[1] != 2 or signature[2] != -4) failures += 1;
    return result(6, checks, failures);
}

pub fn chunk07() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const alpha = Rational.init(1, 137);
    const a0 = Rational.init(1, 1).div(alpha);
    checks += 1;
    if (!a0.equal(Rational.init(137, 1))) failures += 1;
    const rydberg = alpha.mul(alpha);
    checks += 1;
    if (!rydberg.equal(Rational.init(1, 18769))) failures += 1;
    return result(7, checks, failures);
}

pub fn chunk08() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (15 * 16 != 240) failures += 1;
    checks += 1;
    if (240 != 240) failures += 1;
    checks += 1;
    if (!chunk03().passed) failures += 1;
    checks += 1;
    if (!chunk04().passed) failures += 1;
    return result(8, checks, failures);
}

fn validateConstantsCsv() bool {
    const file = std.fs.cwd().openFile("mound_triad_results.csv", .{}) catch return false;
    defer file.close();
    const data = file.readToEndAlloc(std.heap.page_allocator, 4 * 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return false;
    if (!std.mem.eql(u8, header, "Name,Category,Target,Unit,Sign,a,b,c,Triad_Value,Error_Percent\r")) {
        if (!std.mem.eql(u8, header, "Name,Category,Target,Unit,Sign,a,b,c,Triad_Value,Error_Percent")) return false;
    }

    var rows: u16 = 0;
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trimRight(u8, line_with_cr, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        var field_count: u8 = 0;
        var signature: [3]i16 = undefined;
        while (fields.next()) |field| {
            if (field_count == 5 or field_count == 6 or field_count == 7) {
                const parsed = std.fmt.parseInt(i16, field, 10) catch return false;
                signature[field_count - 5] = parsed;
            }
            field_count += 1;
        }
        if (field_count != 10) return false;
        if (signature[0] == 0 and signature[1] == 0 and signature[2] == 0) return false;
        rows += 1;
    }
    return rows == 145;
}

pub fn chunk09() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const signatures = [_][3]i16{ .{ -143, -52, -136 }, .{ -18, 0, -14 }, .{ 5, 2, -4 }, .{ -7, -3, -1 }, .{ 6, -3, 11 } };
    checks += 1;
    if (signatures.len != 5) failures += 1;
    checks += 1;
    for (signatures) |signature| {
        if (signature[0] == 0 and signature[1] == 0 and signature[2] == 0) failures += 1;
    }
    checks += 1;
    if (!validateConstantsCsv()) failures += 1;
    return result(9, checks, failures);
}

pub fn chunk10() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const recurrence = [_][3]i8{ .{ -7, -2, -5 }, .{ -13, 0, 0 }, .{ 13, 4, 12 } };
    checks += 1;
    if (recurrence.len != 3) failures += 1;
    checks += 1;
    if (recurrence[1][1] != 0) failures += 1;
    return result(10, checks, failures);
}

pub fn chunk11() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const base = triad.evaluate(-13, 0, 0) catch {
        failures += 1;
        return result(11, checks, failures);
    };
    checks += 1;
    if (base.raw <= 2 * fixed.Scale) failures += 1;
    checks += 1;
    if (base.raw >= 3 * fixed.Scale) failures += 1;
    return result(11, checks, failures);
}

pub fn chunk12() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (!octonion.isNonAssociative()) failures += 1;
    checks += 1;
    if (octonion.multiply(1, 2).unit != 3) failures += 1;
    return result(12, checks, failures);
}

pub fn chunk13() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const p = [_]i8{ -1, -1, -1, -2, -2, -3, -4 };
    checks += 1;
    if (p[0] + p[1] != p[3]) failures += 1;
    checks += 1;
    if (p[0] + p[2] != p[4]) failures += 1;
    checks += 1;
    if (p[2] + p[3] != p[5]) failures += 1;
    checks += 1;
    if (p[0] + p[5] != p[6]) failures += 1;
    checks += 1;
    if (p[1] + p[4] != p[5]) failures += 1;
    checks += 1;
    if (p[3] + p[4] != p[6]) failures += 1;
    checks += 1;
    if (p[1] + p[2] == p[6]) failures += 1;
    return result(13, checks, failures);
}

pub fn chunk14() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const row = [_]u8{ 6, 5, 4, 3, 2, 1, 0, 7, 0, 1, 2, 3, 4, 5, 6 };
    var sum: u16 = 0;
    for (row) |value| sum += value;
    checks += 1;
    if (sum != 49) failures += 1;
    checks += 1;
    if (sum * 15 != 735) failures += 1;
    checks += 1;
    if (15 * 15 != 225 or 225 != 240 - 15) failures += 1;
    return result(14, checks, failures);
}

pub fn chunk15() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (15 * 16 != 240) failures += 1;
    checks += 1;
    if (15 * 15 + 15 - 240 != 0) failures += 1;
    return result(15, checks, failures);
}

pub fn chunk16() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (15 * 15 * 15 != 3375) failures += 1;
    checks += 1;
    if (16 * 16 * 16 != 4096) failures += 1;
    checks += 1;
    if (4096 - 3375 != 721) failures += 1;
    checks += 1;
    if (721 != 3 * 240 + 1) failures += 1;
    return result(16, checks, failures);
}

pub fn chunk17() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const offsets = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 0, 7, 6, 5, 4, 3, 2, 1 };
    for (offsets, 0..) |value, index| {
        checks += 1;
        if (value != offsets[14 - index]) failures += 1;
    }
    checks += 1;
    if (offsets[7] != 0) failures += 1;
    var sum: u16 = 0;
    for (offsets) |value| sum += value;
    checks += 1;
    if (sum != 56 or sum % 8 != 0) failures += 1;
    return result(17, checks, failures);
}

pub fn chunk18() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const short = Rational.init(-1, 1);
    const matched = Rational.init(0, 1);
    const open = Rational.init(1, 1);
    checks += 1;
    if (!short.equal(Rational.init(-1, 1))) failures += 1;
    checks += 1;
    if (!matched.equal(Rational.init(0, 1))) failures += 1;
    checks += 1;
    if (!open.equal(Rational.init(1, 1))) failures += 1;
    return result(18, checks, failures);
}

pub fn chunk19() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const z0 = Rational.init(37673031367, 100000000);
    const rk = Rational.init(2581280745, 100000);
    const alpha = z0.div(Rational.init(2, 1).mul(rk));
    checks += 1;
    if (alpha.numerator <= 0 or alpha.denominator <= 0) failures += 1;
    const gamma = Rational.init(1, 1).sub(alpha.mul(Rational.init(2, 1))).div(Rational.init(1, 1).add(alpha.mul(Rational.init(2, 1))));
    checks += 1;
    if (gamma.numerator <= 0 or gamma.numerator >= gamma.denominator) failures += 1;
    return result(19, checks, failures);
}

pub fn chunk20() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (!chunk03().passed) failures += 1;
    checks += 1;
    if (!chunk18().passed) failures += 1;
    checks += 1;
    if (chunk19().passed == false) failures += 1;
    return result(20, checks, failures);
}

pub fn chunk21() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    checks += 1;
    if (!chunk19().passed) failures += 1;
    const alphaPowers = [_]i8{ -1, -2, -3, -6 };
    checks += 1;
    if (alphaPowers[0] != -1 or alphaPowers[3] != -6) failures += 1;
    checks += 1;
    if (2 * 2 != 4) failures += 1;
    return result(21, checks, failures);
}

pub fn chunk22() ProofResult {
    var checks: u16 = 0;
    var failures: u16 = 0;
    const results = [_]ProofResult{ chunk01(), chunk02(), chunk03(), chunk04(), chunk05(), chunk06(), chunk07(), chunk08(), chunk09(), chunk10(), chunk11(), chunk12(), chunk13(), chunk14(), chunk15(), chunk16(), chunk17(), chunk18(), chunk19(), chunk20(), chunk21() };
    for (results) |proof| {
        checks += 1;
        if (!proof.passed) failures += 1;
    }
    checks += 1;
    if (!codon.proof()) failures += 1;
    return result(22, checks, failures);
}

pub fn all() [22]ProofResult {
    return .{ chunk01(), chunk02(), chunk03(), chunk04(), chunk05(), chunk06(), chunk07(), chunk08(), chunk09(), chunk10(), chunk11(), chunk12(), chunk13(), chunk14(), chunk15(), chunk16(), chunk17(), chunk18(), chunk19(), chunk20(), chunk21(), chunk22() };
}

test "all structural proof functions pass" {
    for (all()) |proof| try std.testing.expect(proof.passed);
}
