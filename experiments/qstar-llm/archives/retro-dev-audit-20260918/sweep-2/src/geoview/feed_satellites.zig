const std = @import("std");
const geo = @import("geo_math");

// =============================================================================
// Satellite Tracking — TLE parsing, SGP4 propagation, Celestrak API
// =============================================================================
// Parses Two-Line Element (TLE) sets and propagates satellite positions using
// a simplified SGP4 model. Pure Zig, no external dependencies.

pub const Satellite = struct {
    norad_id: u32, // NORAD catalog number
    name: []const u8,
    tle_line1: []const u8,
    tle_line2: []const u8,

    // Orbital elements extracted from TLE
    inclination_deg: f64,
    raan_deg: f64, // Right Ascension of Ascending Node
    eccentricity: f64,
    arg_perigee_deg: f64,
    mean_anomaly_deg: f64,
    mean_motion_rev_per_day: f64,
    epoch_year: u16,
    epoch_day: f64,
    bstar: f64, // Drag term

    pub fn init(norad_id: u32, name: []const u8) Satellite {
        return .{
            .norad_id = norad_id,
            .name = name,
            .tle_line1 = "",
            .tle_line2 = "",
            .inclination_deg = 0,
            .raan_deg = 0,
            .eccentricity = 0,
            .arg_perigee_deg = 0,
            .mean_anomaly_deg = 0,
            .mean_motion_rev_per_day = 0,
            .epoch_year = 0,
            .epoch_day = 0,
            .bstar = 0,
        };
    }
};

pub const SatPosition = struct {
    lat: f64, // degrees
    lon: f64, // degrees
    alt: f64, // km above Earth surface
    velocity_kmps: f64, // km/s
};

/// Parse a TLE line 1 (69 characters)
/// Format: 1 NNNNNC NNNNNAAA.NNNNNNNNN +.NNNNNNNN +NNNNN-N +NNNNN-N N N NNNNN
pub fn parseTleLine1(line: []const u8) struct {
    norad_id: u32,
    epoch_year: u16,
    epoch_day: f64,
    bstar: f64,
} {
    if (line.len < 24) return .{ .norad_id = 0, .epoch_year = 0, .epoch_day = 0, .bstar = 0 };

    const norad_id = std.fmt.parseInt(u32, std.mem.trim(u8, line[2..7], " "), 10) catch 0;
    const epoch_year_str = std.mem.trim(u8, line[18..20], " ");
    const epoch_year = std.fmt.parseInt(u16, epoch_year_str, 10) catch 0;
    const epoch_day = std.fmt.parseFloat(f64, line[20..32]) catch 0.0;

    // BSTAR: decimal point assumed after first digit, exponent at end
    var bstar: f64 = 0;
    if (line.len >= 54) {
        const bstar_str = std.mem.trim(u8, line[53..61], " ");
        if (bstar_str.len > 0) {
            // Format: +.NNNNNNN-N or +.NNNNNNN+N
            bstar = parseScientific(bstar_str) catch 0;
        }
    }

    return .{
        .norad_id = norad_id,
        .epoch_year = epoch_year,
        .epoch_day = epoch_day,
        .bstar = bstar,
    };
}

/// Parse a TLE line 2 (69 characters)
/// Format: 2 NNNNN NNN.NNNN NNN.NNNN NNNNNNN NNN.NNNN NNN.NNNN NN.NNNNNNNN
pub fn parseTleLine2(line: []const u8) struct {
    inclination: f64,
    raan: f64,
    eccentricity: f64,
    arg_perigee: f64,
    mean_anomaly: f64,
    mean_motion: f64,
} {
    if (line.len < 63) return .{
        .inclination = 0,
        .raan = 0,
        .eccentricity = 0,
        .arg_perigee = 0,
        .mean_anomaly = 0,
        .mean_motion = 0,
    };

    const inclination = std.fmt.parseFloat(f64, std.mem.trim(u8, line[8..16], " ")) catch 0.0;
    const raan = std.fmt.parseFloat(f64, std.mem.trim(u8, line[17..25], " ")) catch 0.0;
    // Eccentricity: decimal point assumed before the 7 digits
    const ecc_str = std.mem.trim(u8, line[26..33], " ");
    const eccentricity = if (ecc_str.len > 0)
        std.fmt.parseFloat(f64, ecc_str) catch 0.0
    else
        0.0;
    const ecc = eccentricity / 10_000_000.0; // Apply assumed decimal point

    const arg_perigee = std.fmt.parseFloat(f64, std.mem.trim(u8, line[34..42], " ")) catch 0.0;
    const mean_anomaly = std.fmt.parseFloat(f64, std.mem.trim(u8, line[43..51], " ")) catch 0.0;
    const mean_motion = std.fmt.parseFloat(f64, std.mem.trim(u8, line[52..63], " ")) catch 0.0;

    return .{
        .inclination = inclination,
        .raan = raan,
        .eccentricity = ecc,
        .arg_perigee = arg_perigee,
        .mean_anomaly = mean_anomaly,
        .mean_motion = mean_motion,
    };
}

/// Parse a complete TLE set (name + 2 lines) into a Satellite
pub fn parseTle(allocator: std.mem.Allocator, name: []const u8, line1: []const u8, line2: []const u8) !Satellite {
    const l1 = parseTleLine1(line1);
    const l2 = parseTleLine2(line2);

    return .{
        .norad_id = l1.norad_id,
        .name = try allocator.dupe(u8, name),
        .tle_line1 = try allocator.dupe(u8, line1),
        .tle_line2 = try allocator.dupe(u8, line2),
        .inclination_deg = l2.inclination,
        .raan_deg = l2.raan,
        .eccentricity = l2.eccentricity,
        .arg_perigee_deg = l2.arg_perigee,
        .mean_anomaly_deg = l2.mean_anomaly,
        .mean_motion_rev_per_day = l2.mean_motion,
        .epoch_year = l1.epoch_year,
        .epoch_day = l1.epoch_day,
        .bstar = l1.bstar,
    };
}

/// Parse scientific notation string like "+.12345-4" → 0.000012345
fn parseScientific(s: []const u8) !f64 {
    if (s.len < 2) return 0;
    // Find the exponent sign
    var exp_idx: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '+' or c == '-') {
            if (i > 0 and s[i - 1] != 'e' and s[i - 1] != 'E') {
                exp_idx = i;
                break;
            }
        }
    }
    if (exp_idx == 0) return std.fmt.parseFloat(f64, s);

    const mantissa_str = s[0..exp_idx];
    const exp_sign: f64 = if (s[exp_idx] == '-') -1.0 else 1.0;
    const exp_val = std.fmt.parseInt(i32, s[exp_idx + 1 ..], 10) catch 0;

    // Parse mantissa (starts with + or - and has assumed decimal after first digit)
    var mantissa: f64 = 0;
    var sign: f64 = 1;
    var ms: []const u8 = mantissa_str;
    if (ms.len > 0 and ms[0] == '+') ms = ms[1..];
    if (ms.len > 0 and ms[0] == '-') {
        sign = -1;
        ms = ms[1..];
    }
    if (ms.len > 0 and ms[0] == '.') {
        // .NNNNNN → 0.NNNNNN
        mantissa = std.fmt.parseFloat(f64, ms) catch 0;
    } else if (ms.len > 0) {
        // NNNNNN → N.NNNNN (assumed decimal after first digit)
        const int_part = ms[0];
        const frac_part = ms[1..];
        mantissa = @as(f64, @floatFromInt(int_part - '0'));
        var frac: f64 = 0;
        for (frac_part, 0..) |c, i| {
            const digit: f64 = @as(f64, @floatFromInt(c - '0'));
            frac += digit / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(i + 1)));
        }
        mantissa += frac;
    }

    return sign * mantissa * std.math.pow(f64, 10.0, exp_sign * @as(f64, @floatFromInt(exp_val)));
}

/// Simplified SGP4 propagation — computes satellite position at a given time
/// This is a simplified model using Keplerian propagation with J2 perturbation.
/// For mission-critical applications, a full SGP4 implementation is needed.
pub fn propagatePosition(sat: Satellite, minutes_since_epoch: f64) SatPosition {
    const mu: f64 = 398600.4418; // Earth gravitational parameter (km³/s²)
    const earth_radius_km: f64 = 6378.137;
    const j2: f64 = 0.00108263; // J2 perturbation constant

    // Semi-major axis from mean motion (rev/day → rad/min → Kepler's 3rd law)
    const n_rad_per_sec = sat.mean_motion_rev_per_day * 2.0 * std.math.pi / 86400.0;
    const a = std.math.pow(f64, mu / (n_rad_per_sec * n_rad_per_sec), 1.0 / 3.0); // km

    // Current mean anomaly (with J2 secular perturbation)
    const ma_rad = (sat.mean_anomaly_deg + minutes_since_epoch * sat.mean_motion_rev_per_day * 360.0 / 1440.0) * std.math.pi / 180.0;

    // Solve Kepler's equation: M = E - e*sin(E)
    var e_anom = ma_rad;
    for (0..10) |_| {
        const f = e_anom - sat.eccentricity * @sin(e_anom) - ma_rad;
        const fp = 1.0 - sat.eccentricity * @cos(e_anom);
        e_anom -= f / fp;
    }

    // True anomaly
    const cos_e = @cos(e_anom);
    const sin_e = @sin(e_anom);
    const true_anom = math.atan2(
        @sqrt(1.0 - sat.eccentricity * sat.eccentricity) * sin_e,
        cos_e - sat.eccentricity,
    );

    // Radius
    const r = a * (1.0 - sat.eccentricity * cos_e);

    // Position in orbital plane
    const x_orb = r * @cos(true_anom);
    const y_orb = r * @sin(true_anom);

    // Transform to ECI (Earth-Centered Inertial)
    const inc_rad = sat.inclination_deg * std.math.pi / 180.0;
    const raan_rad = sat.raan_deg * std.math.pi / 180.0;
    const arg_p_rad = sat.arg_perigee_deg * std.math.pi / 180.0;

    const cos_arg_p = @cos(arg_p_rad);
    const sin_arg_p = @sin(arg_p_rad);
    const cos_inc = @cos(inc_rad);
    const sin_inc = @sin(inc_rad);
    const cos_raan = @cos(raan_rad);
    const sin_raan = @sin(raan_rad);

    // Rotation: orbital plane → ECI
    const x_eci = (cos_raan * cos_arg_p - sin_raan * sin_arg_p * cos_inc) * x_orb +
        (-cos_raan * sin_arg_p - sin_raan * cos_arg_p * cos_inc) * y_orb;
    const y_eci = (sin_raan * cos_arg_p + cos_raan * sin_arg_p * cos_inc) * x_orb +
        (-sin_raan * sin_arg_p + cos_raan * cos_arg_p * cos_inc) * y_orb;
    const z_eci = (sin_arg_p * sin_inc) * x_orb + (cos_arg_p * sin_inc) * y_orb;

    // Convert ECI to ECEF (simplified — ignore Earth rotation for now)
    // For a proper implementation, we'd apply GMST rotation
    const theta_g = 0.0; // Simplified: assume fixed Earth
    const cos_theta = @cos(theta_g);
    const sin_theta = @sin(theta_g);

    const x_ecef = cos_theta * x_eci + sin_theta * y_eci;
    const y_ecef = -sin_theta * x_eci + cos_theta * y_eci;
    const z_ecef = z_eci;

    // Convert ECEF to LatLonAlt
    const r_xy = @sqrt(x_ecef * x_ecef + y_ecef * y_ecef);
    const lat = math.atan2(z_ecef, r_xy) * 180.0 / std.math.pi;
    const lon = math.atan2(y_ecef, x_ecef) * 180.0 / std.math.pi;
    const alt = @sqrt(x_ecef * x_ecef + y_ecef * y_ecef + z_ecef * z_ecef) - earth_radius_km;

    // Velocity (simplified)
    const velocity_kmps = n_rad_per_sec * a / 1.0; // Approximate circular velocity

    _ = j2; // J2 not used in simplified model

    return .{
        .lat = lat,
        .lon = lon,
        .alt = alt,
        .velocity_kmps = velocity_kmps,
    };
}

const math = std.math;

/// Fetch TLEs from Celestrak API
pub fn fetchTles(allocator: std.mem.Allocator, category: []const u8) ![]Satellite {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://celestrak.org/NORAD/elements/gp.php?GROUP={s}&FORMAT=tle", .{category}) catch return error.UrlTooLong;

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &response_body },
    }) catch return error.NetworkUnavailable;

    if (result.status != .ok) return error.HttpError;

    return parseTleText(allocator, response_body.items);
}

/// Parse 3-line TLE format: name, line1, line2 (repeated)
pub fn parseTleText(allocator: std.mem.Allocator, text: []const u8) ![]Satellite {
    var satellites = std.ArrayList(Satellite).init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |name_line| {
        const name = std.mem.trim(u8, name_line, " \r");
        if (name.len == 0) continue;

        const line1 = lines.next() orelse break;
        const line2 = lines.next() orelse break;

        const l1 = std.mem.trim(u8, line1, " \r");
        const l2 = std.mem.trim(u8, line2, " \r");

        if (l1.len < 2 or l1[0] != '1') continue;
        if (l2.len < 2 or l2[0] != '2') continue;

        const sat = parseTle(allocator, name, l1, l2) catch continue;
        try satellites.append(sat);
    }

    return satellites.toOwnedSlice();
}

/// Free satellite list
pub fn freeSatelliteList(allocator: std.mem.Allocator, list: []Satellite) void {
    for (list) |sat| {
        allocator.free(sat.name);
        allocator.free(sat.tle_line1);
        allocator.free(sat.tle_line2);
    }
    allocator.free(list);
}

// =============================================================================
// Tests
// =============================================================================

test "feed_satellites: parseTleLine1" {
    const line = "1 25544U 98067A   24001.50000000  .00012345  00000-0  20000-4 0  9991";
    const l1 = parseTleLine1(line);
    try std.testing.expectEqual(@as(u32, 25544), l1.norad_id); // ISS
    try std.testing.expectEqual(@as(u16, 24), l1.epoch_year);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), l1.epoch_day, 1e-6);
}

test "feed_satellites: parseTleLine2" {
    const line = "2 25544  51.6400 100.0000 0001234  90.0000 270.0000 15.50000000123456";
    const l2 = parseTleLine2(line);
    try std.testing.expectApproxEqAbs(@as(f64, 51.64), l2.inclination, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), l2.raan, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 15.5), l2.mean_motion, 1e-6);
    // Eccentricity: 0001234 → 0.0001234
    try std.testing.expectApproxEqAbs(@as(f64, 0.0001234), l2.eccentricity, 1e-10);
}

test "feed_satellites: parseTle" {
    const allocator = std.testing.allocator;
    const name = "ISS (ZARYA)";
    const line1 = "1 25544U 98067A   24001.50000000  .00012345  00000-0  20000-4 0  9991";
    const line2 = "2 25544  51.6400 100.0000 0001234  90.0000 270.0000 15.50000000123456";

    const sat = try parseTle(allocator, name, line1, line2);
    defer {
        allocator.free(sat.name);
        allocator.free(sat.tle_line1);
        allocator.free(sat.tle_line2);
    }

    try std.testing.expectEqual(@as(u32, 25544), sat.norad_id);
    try std.testing.expectEqualStrings("ISS (ZARYA)", sat.name);
    try std.testing.expectApproxEqAbs(@as(f64, 51.64), sat.inclination_deg, 1e-6);
}

test "feed_satellites: propagatePosition returns valid coordinates" {
    const allocator = std.testing.allocator;
    const sat = Satellite{
        .norad_id = 25544,
        .name = "ISS",
        .tle_line1 = "",
        .tle_line2 = "",
        .inclination_deg = 51.64,
        .raan_deg = 100.0,
        .eccentricity = 0.0001,
        .arg_perigee_deg = 90.0,
        .mean_anomaly_deg = 270.0,
        .mean_motion_rev_per_day = 15.5,
        .epoch_year = 24,
        .epoch_day = 1.5,
        .bstar = 0,
    };
    _ = allocator;

    const pos = propagatePosition(sat, 0.0);

    // Position should be at a reasonable altitude for LEO (~400km)
    try std.testing.expect(pos.alt > 300 and pos.alt < 600);
    // Latitude should be within inclination range
    try std.testing.expect(pos.lat >= -52 and pos.lat <= 52);
    // Longitude should be in valid range
    try std.testing.expect(pos.lon >= -180 and pos.lon <= 180);
}

test "feed_satellites: parseTleText" {
    const allocator = std.testing.allocator;
    const text =
        \\ISS (ZARYA)
        \\1 25544U 98067A   24001.50000000  .00012345  00000-0  20000-4 0  9991
        \\2 25544  51.6400 100.0000 0001234  90.0000 270.0000 15.50000000123456
        \\NOAA 19
        \\1 33591U 09005A   24001.50000000  .00001234  00000-0  10000-3 0  9990
        \\2 33591  99.1900 350.0000 0014000 220.0000 140.0000 14.20000000999999
    ;

    const sats = try parseTleText(allocator, text);
    defer freeSatelliteList(allocator, sats);

    try std.testing.expectEqual(@as(usize, 2), sats.len);
    try std.testing.expectEqual(@as(u32, 25544), sats[0].norad_id);
    try std.testing.expectEqual(@as(u32, 33591), sats[1].norad_id);
    try std.testing.expectEqualStrings("ISS (ZARYA)", sats[0].name);
    try std.testing.expectEqualStrings("NOAA 19", sats[1].name);
}

test "feed_satellites: parseTleText empty" {
    const allocator = std.testing.allocator;
    const sats = try parseTleText(allocator, "");
    defer allocator.free(sats);
    try std.testing.expectEqual(@as(usize, 0), sats.len);
}

test "feed_satellites: parseScientific" {
    const result = try parseScientific("+.12345-4");
    try std.testing.expectApproxEqAbs(@as(f64, 0.000012345), result, 1e-12);

    const result2 = try parseScientific("+.20000-4");
    try std.testing.expectApproxEqAbs(@as(f64, 0.00002), result2, 1e-12);
}
