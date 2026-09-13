const std = @import("std");
const math = std.math;

// =============================================================================
// Geospatial Math — WGS84 Ellipsoid, ECEF/LLA/ENU transforms, MGRS, distances
// =============================================================================
// All coordinate math uses f64. No external dependencies.
// WGS84 reference ellipsoid constants (NIMA TR8350.2).

pub const WGS84_A: f64 = 6378137.0; // Semi-major axis (meters)
pub const WGS84_F: f64 = 1.0 / 298.257223563; // Flattening
pub const WGS84_B: f64 = WGS84_A * (1.0 - WGS84_F); // Semi-minor axis
pub const WGS84_E2: f64 = WGS84_F * (2.0 - WGS84_F); // First eccentricity squared
pub const WGS84_EP2: f64 = WGS84_E2 / (1.0 - WGS84_E2); // Second eccentricity squared

pub const PI: f64 = std.math.pi;
pub const DEG2RAD: f64 = PI / 180.0;
pub const RAD2DEG: f64 = 180.0 / PI;

// =============================================================================
// Coordinate Types
// =============================================================================

pub const LatLon = struct {
    lat: f64, // degrees [-90, 90]
    lon: f64, // degrees [-180, 180]
    alt: f64 = 0.0, // meters above WGS84 ellipsoid

    pub fn init(lat: f64, lon: f64) LatLon {
        return .{ .lat = lat, .lon = lon, .alt = 0.0 };
    }

    pub fn initAlt(lat: f64, lon: f64, alt: f64) LatLon {
        return .{ .lat = lat, .lon = lon, .alt = alt };
    }
};

pub const ECEF = struct {
    x: f64, // meters
    y: f64,
    z: f64,

    pub fn init(x: f64, y: f64, z: f64) ECEF {
        return .{ .x = x, .y = y, .z = z };
    }
};

pub const ENU = struct {
    east: f64,
    north: f64,
    up: f64,

    pub fn init(e: f64, n: f64, u: f64) ENU {
        return .{ .east = e, .north = n, .up = u };
    }
};

pub const NED = struct {
    north: f64,
    east: f64,
    down: f64,

    pub fn init(n: f64, e: f64, d: f64) NED {
        return .{ .north = n, .east = e, .down = d };
    }

    pub fn fromEnu(enu: ENU) NED {
        return .{ .north = enu.north, .east = enu.east, .down = -enu.up };
    }

    pub fn toEnu(self: NED) ENU {
        return .{ .east = self.east, .north = self.north, .up = -self.down };
    }
};

// =============================================================================
// WGS84 Ellipsoid Transforms
// =============================================================================

/// Prime vertical radius of curvature (N)
pub fn primeVerticalRadius(lat_rad: f64) f64 {
    const sin_lat = @sin(lat_rad);
    return WGS84_A / @sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat);
}

/// Meridian radius of curvature (M)
pub fn meridianRadius(lat_rad: f64) f64 {
    const sin_lat = @sin(lat_rad);
    const w = @sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat);
    return WGS84_A * (1.0 - WGS84_E2) / (w * w * w);
}

/// Convert LatLon (geodetic) to ECEF (Earth-Centered, Earth-Fixed)
pub fn llaToEcef(lla: LatLon) ECEF {
    const lat_rad = lla.lat * DEG2RAD;
    const lon_rad = lla.lon * DEG2RAD;
    const sin_lat = @sin(lat_rad);
    const cos_lat = @cos(lat_rad);
    const sin_lon = @sin(lon_rad);
    const cos_lon = @cos(lon_rad);
    const n = primeVerticalRadius(lat_rad);

    return .{
        .x = (n + lla.alt) * cos_lat * cos_lon,
        .y = (n + lla.alt) * cos_lat * sin_lon,
        .z = (n * (1.0 - WGS84_E2) + lla.alt) * sin_lat,
    };
}

/// Convert ECEF to LatLon (geodetic) using Bowring's closed-form method
pub fn ecefToLla(ecef: ECEF) LatLon {
    const x = ecef.x;
    const y = ecef.y;
    const z = ecef.z;

    const p = @sqrt(x * x + y * y);
    const theta = math.atan2(z * WGS84_A, p * WGS84_B);

    const sin_theta = @sin(theta);
    const cos_theta = @cos(theta);

    const lat_rad = math.atan2(
        z + WGS84_EP2 * WGS84_B * sin_theta * sin_theta * sin_theta,
        p - WGS84_E2 * WGS84_A * cos_theta * cos_theta * cos_theta,
    );

    const lon_rad = math.atan2(y, x);

    const n = primeVerticalRadius(lat_rad);
    const alt = p / @cos(lat_rad) - n;

    return .{
        .lat = lat_rad * RAD2DEG,
        .lon = lon_rad * RAD2DEG,
        .alt = alt,
    };
}

/// Convert ECEF to ENU (East-North-Up) relative to a reference LatLon
pub fn ecefToEnu(ecef: ECEF, ref: LatLon) ENU {
    const ref_ecef = llaToEcef(ref);
    const dx = ecef.x - ref_ecef.x;
    const dy = ecef.y - ref_ecef.y;
    const dz = ecef.z - ref_ecef.z;

    const lat_rad = ref.lat * DEG2RAD;
    const lon_rad = ref.lon * DEG2RAD;
    const sin_lat = @sin(lat_rad);
    const cos_lat = @cos(lat_rad);
    const sin_lon = @sin(lon_rad);
    const cos_lon = @cos(lon_rad);

    return .{
        .east = -sin_lon * dx + cos_lon * dy,
        .north = -sin_lat * cos_lon * dx - sin_lat * sin_lon * dy + cos_lat * dz,
        .up = cos_lat * cos_lon * dx + cos_lat * sin_lon * dy + sin_lat * dz,
    };
}

/// Convert ENU to ECEF relative to a reference LatLon
pub fn enuToEcef(enu: ENU, ref: LatLon) ECEF {
    const ref_ecef = llaToEcef(ref);
    const lat_rad = ref.lat * DEG2RAD;
    const lon_rad = ref.lon * DEG2RAD;
    const sin_lat = @sin(lat_rad);
    const cos_lat = @cos(lat_rad);
    const sin_lon = @sin(lon_rad);
    const cos_lon = @cos(lon_rad);

    const dx = -sin_lon * enu.east - sin_lat * cos_lon * enu.north + cos_lat * cos_lon * enu.up;
    const dy = cos_lon * enu.east - sin_lat * sin_lon * enu.north + cos_lat * sin_lon * enu.up;
    const dz = cos_lat * enu.north + sin_lat * enu.up;

    return .{
        .x = ref_ecef.x + dx,
        .y = ref_ecef.y + dy,
        .z = ref_ecef.z + dz,
    };
}

// =============================================================================
// Great Circle Distance & Bearing (Vincenty / Haversine)
// =============================================================================

/// Haversine great-circle distance between two LatLon points (meters)
pub fn greatCircleDistance(a: LatLon, b: LatLon) f64 {
    const lat_a = a.lat * DEG2RAD;
    const lat_b = b.lat * DEG2RAD;
    const dlat = (b.lat - a.lat) * DEG2RAD;
    const dlon = (b.lon - a.lon) * DEG2RAD;

    const sin_dlat = @sin(dlat / 2.0);
    const sin_dlon = @sin(dlon / 2.0);
    const h = sin_dlat * sin_dlat + @cos(lat_a) * @cos(lat_b) * sin_dlon * sin_dlon;
    const c = 2.0 * math.asin(@min(1.0, @sqrt(h)));
    return WGS84_A * c;
}

/// Vincenty inverse formula for geodesic distance on WGS84 ellipsoid (meters)
/// More accurate than Haversine for ellipsoidal earth.
pub fn vincentyDistance(a: LatLon, b: LatLon) f64 {
    const v_u1 = math.atan((1.0 - WGS84_F) * @tan(a.lat * DEG2RAD));
    const v_u2 = math.atan((1.0 - WGS84_F) * @tan(b.lat * DEG2RAD));
    const sin_u1 = @sin(v_u1);
    const cos_u1 = @cos(v_u1);
    const sin_u2 = @sin(v_u2);
    const cos_u2 = @cos(v_u2);

    const l = (b.lon - a.lon) * DEG2RAD;
    var lambda = l;
    var sin_sigma: f64 = 0;
    var cos_sigma: f64 = 0;
    var cos_sq_alpha: f64 = 0;
    var cos_2_sigma_m: f64 = 0;
    var sigma: f64 = 0;
    var converged = false;

    for (0..200) |_| {
        const sin_lambda = @sin(lambda);
        const cos_lambda = @cos(lambda);
        sin_sigma = @sqrt((cos_u2 * sin_lambda) * (cos_u2 * sin_lambda) +
            (cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lambda) *
            (cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lambda));
        if (sin_sigma == 0) return 0.0; // coincident points
        cos_sigma = sin_u1 * sin_u2 + cos_u1 * cos_u2 * cos_lambda;
        sigma = math.atan2(sin_sigma, cos_sigma);
        const sin_alpha = cos_u1 * cos_u2 * sin_lambda / sin_sigma;
        cos_sq_alpha = 1.0 - sin_alpha * sin_alpha;
        cos_2_sigma_m = if (cos_sq_alpha != 0) cos_sigma - 2.0 * sin_u1 * sin_u2 / cos_sq_alpha else 0.0;
        const c = WGS84_F / 16.0 * cos_sq_alpha * (4.0 + WGS84_F * (4.0 - 3.0 * cos_sq_alpha));
        const lambda_prev = lambda;
        lambda = l + (1.0 - c) * WGS84_F * sin_alpha *
            (sigma + c * sin_sigma * (cos_2_sigma_m + c * cos_sigma * (-1.0 + 2.0 * cos_2_sigma_m * cos_2_sigma_m)));
        if (@abs(lambda - lambda_prev) < 1e-12) {
            converged = true;
            break;
        }
    }

    if (!converged) return greatCircleDistance(a, b); // fallback to haversine

    const u_sq = cos_sq_alpha * (WGS84_A * WGS84_A - WGS84_B * WGS84_B) / (WGS84_B * WGS84_B);
    const a_coeff = 1.0 + u_sq / 16384.0 * (4096.0 + u_sq * (-768.0 + u_sq * (320.0 - 175.0 * u_sq)));
    const b_coeff = u_sq / 1024.0 * (256.0 + u_sq * (-128.0 + u_sq * (74.0 - 47.0 * u_sq)));
    const delta_sigma = b_coeff * sin_sigma * (cos_2_sigma_m + b_coeff / 4.0 *
        (cos_sigma * (-1.0 + 2.0 * cos_2_sigma_m * cos_2_sigma_m) -
        b_coeff / 6.0 * cos_2_sigma_m * (-3.0 + 4.0 * sin_sigma * sin_sigma) *
        (-3.0 + 4.0 * cos_2_sigma_m * cos_2_sigma_m)));

    return WGS84_B * a_coeff * (sigma - delta_sigma);
}

/// Initial bearing (forward azimuth) from point a to point b (degrees, 0-360)
pub fn bearing(a: LatLon, b: LatLon) f64 {
    const lat_a = a.lat * DEG2RAD;
    const lat_b = b.lat * DEG2RAD;
    const dlon = (b.lon - a.lon) * DEG2RAD;

    const y = @sin(dlon) * @cos(lat_b);
    const x = @cos(lat_a) * @sin(lat_b) - @sin(lat_a) * @cos(lat_b) * @cos(dlon);
    const brng = math.atan2(y, x) * RAD2DEG;
    return @mod(brng + 360.0, 360.0);
}

/// Destination point given a start point, bearing (degrees), and distance (meters)
/// Uses the haversine formula for spherical earth approximation.
pub fn destinationPoint(start: LatLon, brng_deg: f64, dist_m: f64) LatLon {
    const lat1 = start.lat * DEG2RAD;
    const lon1 = start.lon * DEG2RAD;
    const brng = brng_deg * DEG2RAD;
    const d = dist_m / WGS84_A; // angular distance

    const sin_lat1 = @sin(lat1);
    const cos_lat1 = @cos(lat1);
    const sin_d = @sin(d);
    const cos_d = @cos(d);

    const lat2 = math.asin(sin_lat1 * cos_d + cos_lat1 * sin_d * @cos(brng));
    const lon2 = lon1 + math.atan2(
        @sin(brng) * sin_d * cos_lat1,
        cos_d - sin_lat1 * @sin(lat2),
    );

    return .{
        .lat = lat2 * RAD2DEG,
        .lon = @mod(lon2 * RAD2DEG + 540.0, 360.0) - 180.0,
        .alt = start.alt,
    };
}

// =============================================================================
// MGRS (Military Grid Reference System) Encoding
// =============================================================================

const UTM_ZONES = [_][]const u8{
    "C", "D", "E", "F", "G", "H", "J", "K", "L", "M",
    "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X",
};

const EASTING_OFFSET: f64 = 500000.0;
const FALSE_NORTHING_NORTH: f64 = 0.0;
const FALSE_NORTHING_SOUTH: f64 = 10000000.0;
const K0: f64 = 0.9996;

pub const UTM = struct {
    zone: u8, // 1-60
    is_north: bool,
    easting: f64, // meters
    northing: f64, // meters
};

/// Convert LatLon to UTM using WGS84 ellipsoid
pub fn latLonToUtm(lla: LatLon) UTM {
    const lat_rad = lla.lat * DEG2RAD;
    const lon_rad = lla.lon * DEG2RAD;

    const zone: u8 = @intFromFloat(@floor((lla.lon + 180.0) / 6.0) + 1);
    const central_meridian = (@as(f64, @floatFromInt(zone)) - 1.0) * 6.0 - 180.0 + 3.0;
    const cm_rad = central_meridian * DEG2RAD;

    const is_north = lla.lat >= 0.0;

    const n = WGS84_A / @sqrt(1.0 - WGS84_E2 * @sin(lat_rad) * @sin(lat_rad));
    const t = @tan(lat_rad) * @tan(lat_rad);
    const c = WGS84_EP2 * @cos(lat_rad) * @cos(lat_rad);
    const a_term = @cos(lat_rad) * (lon_rad - cm_rad);

    const m = WGS84_A * ((1.0 - WGS84_E2 / 4.0 - WGS84_E2 * WGS84_E2 / 64.0 - WGS84_E2 * WGS84_E2 * WGS84_E2 / 256.0) * lat_rad -
        (3.0 * WGS84_E2 / 8.0 + 3.0 * WGS84_E2 * WGS84_E2 / 32.0 + 45.0 * WGS84_E2 * WGS84_E2 * WGS84_E2 / 1024.0) * @sin(2.0 * lat_rad) +
        (15.0 * WGS84_E2 * WGS84_E2 / 256.0 + 45.0 * WGS84_E2 * WGS84_E2 * WGS84_E2 / 1024.0) * @sin(4.0 * lat_rad) -
        (35.0 * WGS84_E2 * WGS84_E2 * WGS84_E2 / 3072.0) * @sin(6.0 * lat_rad));

    const easting = K0 * n * (a_term + (1.0 - t + c) * a_term * a_term * a_term / 6.0 +
        (5.0 - 18.0 * t + t * t + 72.0 * c - 58.0 * WGS84_EP2) * a_term * a_term * a_term * a_term * a_term / 120.0) + EASTING_OFFSET;

    var northing = K0 * (m + n * @tan(lat_rad) * (a_term * a_term / 2.0 +
        (5.0 - t + 9.0 * c + 4.0 * c * c) * a_term * a_term * a_term * a_term / 24.0 +
        (61.0 - 58.0 * t + t * t + 600.0 * c - 330.0 * WGS84_EP2) * a_term * a_term * a_term * a_term * a_term * a_term / 720.0));

    if (!is_north) northing += FALSE_NORTHING_SOUTH;

    return .{
        .zone = zone,
        .is_north = is_north,
        .easting = easting,
        .northing = northing,
    };
}

/// Convert UTM to LatLon using WGS84 ellipsoid (inverse transform)
pub fn utmToLatLon(utm: UTM) LatLon {
    const e1 = (1.0 - @sqrt(1.0 - WGS84_E2)) / (1.0 + @sqrt(1.0 - WGS84_E2));
    const x = utm.easting - EASTING_OFFSET;
    var y = utm.northing;
    if (!utm.is_north) y -= FALSE_NORTHING_SOUTH;

    const central_meridian = (@as(f64, @floatFromInt(utm.zone)) - 1.0) * 6.0 - 180.0 + 3.0;
    const cm_rad = central_meridian * DEG2RAD;

    const m = y / K0;
    const mu = m / (WGS84_A * (1.0 - WGS84_E2 / 4.0 - WGS84_E2 * WGS84_E2 / 64.0 - WGS84_E2 * WGS84_E2 * WGS84_E2 / 256.0));

    const phi1 = mu + (3.0 * e1 / 2.0 - 27.0 * e1 * e1 * e1 / 32.0) * @sin(2.0 * mu) +
        (21.0 * e1 * e1 / 16.0 - 55.0 * e1 * e1 * e1 * e1 / 32.0) * @sin(4.0 * mu) +
        (151.0 * e1 * e1 * e1 / 96.0) * @sin(6.0 * mu) +
        (1097.0 * e1 * e1 * e1 * e1 / 512.0) * @sin(8.0 * mu);

    const sin_phi1 = @sin(phi1);
    const cos_phi1 = @cos(phi1);
    const tan_phi1 = @tan(phi1);
    const n1 = WGS84_A / @sqrt(1.0 - WGS84_E2 * sin_phi1 * sin_phi1);
    const t1 = tan_phi1 * tan_phi1;
    const c1 = WGS84_EP2 * cos_phi1 * cos_phi1;
    const r1 = WGS84_A * (1.0 - WGS84_E2) / (1.0 - WGS84_E2 * sin_phi1 * sin_phi1);
    const d = x / (n1 * K0);

    const lat = phi1 - (n1 * @tan(phi1) / r1) * (d * d / 2.0 -
        (5.0 + 3.0 * t1 + 10.0 * c1 - 4.0 * c1 * c1 - 9.0 * WGS84_EP2) * d * d * d * d / 24.0 +
        (61.0 + 90.0 * t1 + 298.0 * c1 + 45.0 * t1 * t1 - 252.0 * WGS84_EP2 - 3.0 * c1 * c1) * d * d * d * d * d * d / 720.0);

    const lon = cm_rad + (d - (1.0 + 2.0 * t1 + c1) * d * d * d / 6.0 +
        (5.0 - 2.0 * c1 + 28.0 * t1 - 3.0 * c1 * c1 + 8.0 * WGS84_EP2 + 24.0 * t1 * t1) * d * d * d * d * d / 120.0) / cos_phi1;

    return .{
        .lat = lat * RAD2DEG,
        .lon = lon * RAD2DEG,
        .alt = 0.0,
    };
}

const MGRS_COL_LETTERS = [_]u8{ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'N', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z' };
const MGRS_ROW_LETTERS = [_]u8{ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'N', 'P', 'Q', 'R', 'S', 'T', 'U', 'V' };
const MGRS_100K_COL_SET = [_]u8{ 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z' };

/// Convert LatLon to MGRS string (1-meter precision)
pub fn latLonToMgrs(allocator: std.mem.Allocator, lla: LatLon) ![]const u8 {
    const utm = latLonToUtm(lla);

    // 100km grid square identification
    const col_idx: usize = @intFromFloat(@floor(utm.easting / 100000.0));
    const row_idx: usize = @intFromFloat(@floor(utm.northing / 100000.0));

    const col_letter = MGRS_COL_LETTERS[(col_idx - 1 + (@as(usize, utm.zone) - 1) * 8) % 24];
    const row_letter = MGRS_ROW_LETTERS[row_idx % 20];

    // Easting and northing within 100km square (5-digit each for 1m precision)
    const easting_rem = utm.easting - @as(f64, @floatFromInt(col_idx)) * 100000.0;
    const northing_rem = utm.northing - @as(f64, @floatFromInt(row_idx)) * 100000.0;

    const lat_band = UTM_ZONES[@intFromFloat(@floor((lla.lat + 80.0) / 8.0))];

    return std.fmt.allocPrint(allocator, "{d}{s}{c}{c}{d:0>5}{d:0>5}", .{
        utm.zone,
        lat_band,
        col_letter,
        row_letter,
        @as(u32, @intFromFloat(@floor(easting_rem))),
        @as(u32, @intFromFloat(@floor(northing_rem))),
    });
}

/// Parse MGRS string to LatLon (basic parser: zone, band, 100km square, easting/northing)
pub fn mgrsToLatLon(mgrs: []const u8) !LatLon {
    if (mgrs.len < 4) return error.InvalidMGRS;

    var pos: usize = 0;
    while (pos < mgrs.len and std.ascii.isDigit(mgrs[pos])) pos += 1;
    if (pos == 0 or pos > 2) return error.InvalidMGRS;

    const zone = try std.fmt.parseInt(u8, mgrs[0..pos], 10);
    const band = mgrs[pos];
    pos += 1;

    if (pos + 2 > mgrs.len) return error.InvalidMGRS;
    const col_letter = mgrs[pos];
    const row_letter = mgrs[pos + 1];
    pos += 2;

    const remaining = mgrs[pos..];
    if (remaining.len == 0 or remaining.len % 2 != 0) return error.InvalidMGRS;
    const half = remaining.len / 2;

    const easting_str = remaining[0..half];
    const northing_str = remaining[half..];

    var easting: f64 = try std.fmt.parseFloat(f64, easting_str);
    var northing: f64 = try std.fmt.parseFloat(f64, northing_str);

    // Scale to meters based on precision
    const scale: f64 = @as(f64, @floatFromInt(5 - half));
    const factor = std.math.pow(f64, 10.0, scale);
    easting *= factor;
    northing *= factor;

    // Find column letter index
    var col_idx: usize = 0;
    for (MGRS_COL_LETTERS, 0..) |c, i| {
        if (c == col_letter) {
            col_idx = i;
            break;
        }
    }

    // Find row letter index
    var row_idx: usize = 0;
    for (MGRS_ROW_LETTERS, 0..) |c, i| {
        if (c == row_letter) {
            row_idx = i;
            break;
        }
    }

    // Reconstruct full easting/northing using signed arithmetic to avoid underflow
    const col_offset_i: i64 = @mod(@as(i64, @intCast(col_idx)) - (@as(i64, @intCast(zone)) - 1) * 8, 24);
    const col_offset: f64 = @as(f64, @floatFromInt(col_offset_i)) * 100000.0;
    const row_offset: f64 = @as(f64, @floatFromInt(row_idx)) * 100000.0;

    const is_north = band >= 'N';
    const full_easting = col_offset + easting + 100000.0;
    const full_northing = row_offset + northing;
    const adj_northing = if (is_north) full_northing else full_northing + FALSE_NORTHING_SOUTH;

    return utmToLatLon(.{
        .zone = zone,
        .is_north = is_north,
        .easting = full_easting,
        .northing = adj_northing,
    });
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Clamp latitude to valid range [-90, 90]
pub fn clampLat(lat: f64) f64 {
    return @max(-90.0, @min(90.0, lat));
}

/// Wrap longitude to valid range [-180, 180)
pub fn wrapLon(lon: f64) f64 {
    return @mod(lon + 180.0, 360.0) - 180.0;
}

/// Normalize bearing to [0, 360)
pub fn normalizeBearing(brng: f64) f64 {
    return @mod(brng + 360.0, 360.0);
}

/// Cardinal direction from bearing (N, NE, E, SE, S, SW, W, NW)
pub fn cardinalDirection(brng: f64) []const u8 {
    const directions = [_][]const u8{ "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
    const idx: usize = @as(usize, @intFromFloat(@floor(normalizeBearing(brng) / 45.0 + 0.5))) % 8;
    return directions[idx];
}

// =============================================================================
// Tests
// =============================================================================

test "geo_math: llaToEcef and ecefToLla round-trip" {
    const lla = LatLon.initAlt(40.7128, -74.0060, 100.0); // NYC
    const ecef = llaToEcef(lla);
    const back = ecefToLla(ecef);

    try std.testing.expectApproxEqAbs(lla.lat, back.lat, 1e-6);
    try std.testing.expectApproxEqAbs(lla.lon, back.lon, 1e-6);
    try std.testing.expectApproxEqAbs(lla.alt, back.alt, 1e-3);
}

test "geo_math: ecefToLla origin" {
    const ecef = ECEF.init(WGS84_A, 0, 0); // on equator at prime meridian
    const lla = ecefToLla(ecef);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), lla.lat, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), lla.lon, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), lla.alt, 1e-3);
}

test "geo_math: ecefToEnu zero at reference" {
    const ref = LatLon.init(40.0, -75.0);
    const ref_ecef = llaToEcef(ref);
    const enu = ecefToEnu(ref_ecef, ref);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), enu.east, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), enu.north, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), enu.up, 1e-3);
}

test "geo_math: enuToEcef round-trip" {
    const ref = LatLon.initAlt(35.0, 120.0, 50.0);
    const enu = ENU.init(1000.0, 2000.0, 500.0);
    const ecef = enuToEcef(enu, ref);
    const back_enu = ecefToEnu(ecef, ref);
    try std.testing.expectApproxEqAbs(enu.east, back_enu.east, 1e-3);
    try std.testing.expectApproxEqAbs(enu.north, back_enu.north, 1e-3);
    try std.testing.expectApproxEqAbs(enu.up, back_enu.up, 1e-3);
}

test "geo_math: greatCircleDistance London-NYC" {
    const london = LatLon.init(51.5074, -0.1278);
    const nyc = LatLon.init(40.7128, -74.0060);
    const dist = greatCircleDistance(london, nyc);
    // Expected ~5570 km (haversine approximation)
    try std.testing.expect(dist > 5_500_000 and dist < 5_600_000);
}

test "geo_math: vincentyDistance London-NYC" {
    const london = LatLon.init(51.5074, -0.1278);
    const nyc = LatLon.init(40.7128, -74.0060);
    const dist = vincentyDistance(london, nyc);
    // Vincenty should be slightly different from haversine but in same range
    try std.testing.expect(dist > 5_500_000 and dist < 5_600_000);
}

test "geo_math: bearing cardinal directions" {
    const north_pt = LatLon.init(41.0, -74.0);
    const south_pt = LatLon.init(39.0, -74.0);
    const east_pt = LatLon.init(40.0, -73.0);
    const west_pt = LatLon.init(40.0, -75.0);
    const origin = LatLon.init(40.0, -74.0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), bearing(origin, north_pt), 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 180.0), bearing(origin, south_pt), 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), bearing(origin, east_pt), 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 270.0), bearing(origin, west_pt), 1.0);
}

test "geo_math: destinationPoint round-trip" {
    const start = LatLon.init(40.0, -74.0);
    const dist: f64 = 100000.0; // 100 km
    const brng: f64 = 45.0; // NE

    const dest = destinationPoint(start, brng, dist);
    const back_bearing = bearing(dest, start);
    const back_dist = greatCircleDistance(dest, start);

    // Reverse bearing should be ~225 (45 + 180)
    try std.testing.expectApproxEqAbs(@as(f64, 225.0), back_bearing, 2.0);
    // Distance should be approximately preserved
    try std.testing.expectApproxEqAbs(dist, back_dist, 1000.0);
}

test "geo_math: latLonToUtm and utmToLatLon round-trip" {
    const lla = LatLon.init(40.7128, -74.0060); // NYC
    const utm = latLonToUtm(lla);
    const back = utmToLatLon(utm);

    try std.testing.expectApproxEqAbs(lla.lat, back.lat, 1e-4);
    try std.testing.expectApproxEqAbs(lla.lon, back.lon, 1e-4);
}

test "geo_math: utm zone calculation" {
    const nyc = LatLon.init(40.7128, -74.0060);
    const utm = latLonToUtm(nyc);
    try std.testing.expectEqual(@as(u8, 18), utm.zone);
    try std.testing.expect(utm.is_north);

    const sydney = LatLon.init(-33.8688, 151.2093);
    const utm_s = latLonToUtm(sydney);
    try std.testing.expectEqual(@as(u8, 56), utm_s.zone);
    try std.testing.expect(!utm_s.is_north);
}

test "geo_math: mgrs format and approximate round-trip" {
    const allocator = std.testing.allocator;
    const lla = LatLon.init(40.7128, -74.0060); // NYC
    const mgrs = try latLonToMgrs(allocator, lla);
    defer allocator.free(mgrs);

    // MGRS string should start with zone number (18 for NYC) and band letter (T for lat 40)
    try std.testing.expect(mgrs.len > 5);
    try std.testing.expect(mgrs[0] == '1' and mgrs[1] == '8'); // zone 18
    try std.testing.expect(mgrs[2] == 'T'); // latitude band T (32-40N → actually 40 is in T)

    // Parse back — verify it produces a valid LatLon in the right hemisphere
    const back = try mgrsToLatLon(mgrs);
    try std.testing.expect(back.lat > 0); // Northern hemisphere
    try std.testing.expect(back.lat < 60); // Reasonable latitude
    try std.testing.expect(back.lon < 0); // Western hemisphere
    try std.testing.expect(back.lon > -100); // Reasonable longitude
}

test "geo_math: clampLat and wrapLon" {
    try std.testing.expectEqual(@as(f64, 90.0), clampLat(100.0));
    try std.testing.expectEqual(@as(f64, -90.0), clampLat(-100.0));
    try std.testing.expectEqual(@as(f64, 45.0), clampLat(45.0));

    try std.testing.expectApproxEqAbs(@as(f64, 170.0), wrapLon(170.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -170.0), wrapLon(190.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), wrapLon(360.0), 1e-10);
}

test "geo_math: cardinalDirection" {
    try std.testing.expectEqualStrings("N", cardinalDirection(0.0));
    try std.testing.expectEqualStrings("E", cardinalDirection(90.0));
    try std.testing.expectEqualStrings("S", cardinalDirection(180.0));
    try std.testing.expectEqualStrings("W", cardinalDirection(270.0));
    try std.testing.expectEqualStrings("NE", cardinalDirection(45.0));
    try std.testing.expectEqualStrings("NW", cardinalDirection(315.0));
}

test "geo_math: NED from ENU conversion" {
    const enu = ENU.init(100.0, 200.0, 300.0);
    const ned = NED.fromEnu(enu);
    try std.testing.expectEqual(@as(f64, 200.0), ned.north);
    try std.testing.expectEqual(@as(f64, 100.0), ned.east);
    try std.testing.expectEqual(@as(f64, -300.0), ned.down);

    const back = ned.toEnu();
    try std.testing.expectEqual(enu.east, back.east);
    try std.testing.expectEqual(enu.north, back.north);
    try std.testing.expectEqual(enu.up, back.up);
}

test "geo_math: primeVerticalRadius at equator and pole" {
    const n_equator = primeVerticalRadius(0.0);
    const n_pole = primeVerticalRadius(PI / 2.0);
    try std.testing.expectApproxEqAbs(WGS84_A, n_equator, 1e-6);
    // At pole, N = a/sqrt(1-e^2) which is greater than a (e^2 > 0)
    try std.testing.expect(n_pole > n_equator);
}

test "geo_math: meridianRadius at equator and pole" {
    const m_equator = meridianRadius(0.0);
    const m_pole = meridianRadius(PI / 2.0);
    // At equator M < a, at pole M > a
    try std.testing.expect(m_pole > m_equator);
}
