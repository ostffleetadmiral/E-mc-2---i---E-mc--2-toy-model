const std = @import("std");
const geo = @import("geo_math");

// =============================================================================
// OpenSky Flight Tracking — Aircraft state, classification, dead-reckoning
// =============================================================================
// Parses OpenSky Network REST API /states/all responses.
// Pure Zig HTTP client via std.http.Client (graceful failure when offline).

pub const AircraftClass = enum {
    civil,
    military,
    government,
    private,
    helicopter,
    ground_vehicle,
    unknown,
};

pub const Aircraft = struct {
    icao24: []const u8, // ICAO transponder hex address
    callsign: []const u8, // Flight callsign (trimmed)
    origin_country: []const u8,
    lat: f64,
    lon: f64,
    altitude_m: f64, // Barometric altitude in meters
    velocity_mps: f64, // Velocity in m/s
    heading_deg: f64, // True track in degrees
    vertical_rate_mps: f64, // Vertical rate in m/s
    on_ground: bool,
    spi: bool, // Special purpose indicator
    last_contact: f64, // Unix timestamp

    pub fn init(icao24: []const u8) Aircraft {
        return .{
            .icao24 = icao24,
            .callsign = "",
            .origin_country = "",
            .lat = 0,
            .lon = 0,
            .altitude_m = 0,
            .velocity_mps = 0,
            .heading_deg = 0,
            .vertical_rate_mps = 0,
            .on_ground = false,
            .spi = false,
            .last_contact = 0,
        };
    }
};

// Military callsign prefixes (common NATO/US patterns)
const MILITARY_PREFIXES = [_][]const u8{
    "RCH",   // US AMC Reach
    "RRR",   // US AMC
    "SAM",   // US Special Air Mission
    "VIVI",  // US Vice President
    "AF1",   // Air Force One
    "AF2",   // Air Force Two
    "EAM",   // US E-6B Mercury
    "ORDER", // US military orders
    "FORTE", // US military
    "DRAGN", // US military
    "HOMER", // US military
    "HUNT",  // US military
    "REACH", // US AMC Reach
    "CNV",   // US Navy Convoy
    "Navy",  // US Navy
    "RFF",   // Royal Air Force
    "RR",    // Royal Air Force
    "RAF",   // Royal Air Force
    "GAF",   // German Air Force
    "GEZ",   // German Air Force
    "LTT",   // NATO
    "NATO",  // NATO
    "QFA",   // Qantas (sometimes military charter)
};

/// Classify aircraft by callsign prefix
pub fn classifyAircraft(callsign: []const u8) AircraftClass {
    const trimmed = std.mem.trim(u8, callsign, " ");
    if (trimmed.len == 0) return .unknown;

    for (MILITARY_PREFIXES) |prefix| {
        if (trimmed.len >= prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
            return .military;
        }
    }

    // Helicopter callsigns often start with H or have rotor designations
    if (trimmed.len >= 1 and (trimmed[0] == 'H' or trimmed[0] == 'h')) {
        if (std.mem.indexOf(u8, trimmed, "HELO") != null or
            std.mem.indexOf(u8, trimmed, "CHOPPER") != null or
            std.mem.indexOf(u8, trimmed, "ROT") != null)
        {
            return .helicopter;
        }
    }

    return .civil;
}

/// Dead-reckoning: predict future position given current state and time delta
pub fn deadReckonPosition(aircraft: Aircraft, dt_seconds: f64) geo.LatLon {
    const current = geo.LatLon.initAlt(aircraft.lat, aircraft.lon, aircraft.altitude_m);
    if (aircraft.velocity_mps <= 0) return current;

    const distance = aircraft.velocity_mps * dt_seconds;
    return geo.destinationPoint(current, aircraft.heading_deg, distance);
}

/// Parse OpenSky /states/all JSON response into aircraft list
/// Response format: {"time":..., "states": [["icao","callsign","country",lon,lat,...], ...]}
pub fn parseStatesResponse(allocator: std.mem.Allocator, json: []const u8) ![]Aircraft {
    var aircraft_list = std.ArrayList(Aircraft).init(allocator);

    // Find the "states" array
    const states_marker = "\"states\":";
    const states_pos = std.mem.indexOf(u8, json, states_marker) orelse {
        return aircraft_list.toOwnedSlice();
    };

    // Find opening bracket of states array
    const arr_start = std.mem.indexOfScalarPos(u8, json, states_pos, '[') orelse {
        return aircraft_list.toOwnedSlice();
    };

    // Parse each inner array — each state is a JSON array of 17+ values
    var pos = arr_start + 1;
    while (pos < json.len) {
        // Skip whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\n' or json[pos] == '\r' or json[pos] == '\t')) pos += 1;
        if (pos >= json.len or json[pos] == ']') break;

        if (json[pos] != '[') {
            pos += 1;
            continue;
        }

        // Found start of a state array — parse values
        const state_start = pos + 1;
        var depth: u32 = 1;
        pos = state_start;
        while (pos < json.len and depth > 0) {
            if (json[pos] == '[') depth += 1;
            if (json[pos] == ']') depth -= 1;
            if (depth > 0) pos += 1;
        }
        const state_content = json[state_start..pos];
        pos += 1; // skip closing ]

        // Parse the state values
        const ac = parseStateArray(allocator, state_content) catch continue;
        try aircraft_list.append(ac);
    }

    return aircraft_list.toOwnedSlice();
}

/// Parse a single state array: ["icao24","callsign","origin_country",last_pos_update,lon,lat,baro_alt,on_ground,velocity,heading,vertical_rate,...,spi,last_contact]
fn parseStateArray(allocator: std.mem.Allocator, state: []const u8) !Aircraft {
    var values = std.ArrayList([]const u8).init(allocator);
    defer values.deinit();

    // Simple comma-separated value parser (handles null values)
    var pos: usize = 0;
    while (pos < state.len) {
        while (pos < state.len and (state[pos] == ' ' or state[pos] == ',')) pos += 1;
        if (pos >= state.len) break;

        if (state[pos] == '"') {
            // String value
            pos += 1;
            const start = pos;
            while (pos < state.len and state[pos] != '"') pos += 1;
            try values.append(state[start..pos]);
            if (pos < state.len) pos += 1; // skip closing quote
        } else if (state[pos] == 'n' and pos + 3 < state.len and state[pos + 1] == 'u' and state[pos + 2] == 'l' and state[pos + 3] == 'l') {
            try values.append("null");
            pos += 4;
        } else {
            // Number or boolean
            const start = pos;
            while (pos < state.len and state[pos] != ',' and state[pos] != ' ') pos += 1;
            try values.append(state[start..pos]);
        }
    }

    if (values.items.len < 11) return error.InvalidStateArray;

    const icao24 = try allocator.dupe(u8, values.items[0]);
    const callsign_raw = values.items[1];
    const callsign = try allocator.dupe(u8, std.mem.trim(u8, callsign_raw, " "));
    const origin_country = try allocator.dupe(u8, values.items[2]);

    const lon = parseFloatOrZero(values.items[5]);
    const lat = parseFloatOrZero(values.items[6]);
    const baro_alt = parseFloatOrZero(values.items[7]);
    const on_ground = std.mem.eql(u8, values.items[8], "true");
    const velocity = parseFloatOrZero(values.items[9]);
    const heading = parseFloatOrZero(values.items[10]);
    const vertical_rate = if (values.items.len > 11) parseFloatOrZero(values.items[11]) else 0;
    const last_contact = if (values.items.len > 4) parseFloatOrZero(values.items[4]) else 0;

    return .{
        .icao24 = icao24,
        .callsign = callsign,
        .origin_country = origin_country,
        .lat = lat,
        .lon = lon,
        .altitude_m = baro_alt,
        .velocity_mps = velocity,
        .heading_deg = heading,
        .vertical_rate_mps = vertical_rate,
        .on_ground = on_ground,
        .spi = false,
        .last_contact = last_contact,
    };
}

fn parseFloatOrZero(s: []const u8) f64 {
    if (std.mem.eql(u8, s, "null") or s.len == 0) return 0;
    return std.fmt.parseFloat(f64, s) catch 0;
}

/// Fetch aircraft states from OpenSky Network API
/// Returns graceful error when network unavailable
pub fn fetchStates(allocator: std.mem.Allocator, bounds: ?struct { min_lat: f64, max_lat: f64, min_lon: f64, max_lon: f64 }) ![]Aircraft {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = if (bounds) |b| blk: {
        url_buf = std.fmt.bufPrint(&url_buf, "https://opensky-network.org/api/states/all?lamin={d:.4}&lomin={d:.4}&lamax={d:.4}&lomax={d:.4}", .{
            b.min_lat, b.min_lon, b.max_lat, b.max_lon,
        }) catch return error.UrlTooLong;
        break :blk url_buf;
    } else "https://opensky-network.org/api/states/all";

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &response_body },
    }) catch return error.NetworkUnavailable;

    if (result.status != .ok) return error.HttpError;

    return parseStatesResponse(allocator, response_body.items);
}

/// Free aircraft list and all allocated strings
pub fn freeAircraftList(allocator: std.mem.Allocator, list: []Aircraft) void {
    for (list) |ac| {
        allocator.free(ac.icao24);
        allocator.free(ac.callsign);
        allocator.free(ac.origin_country);
    }
    allocator.free(list);
}

// =============================================================================
// Tests
// =============================================================================

test "feed_flights: classifyAircraft civil" {
    try std.testing.expectEqual(AircraftClass.civil, classifyAircraft("UAL123"));
    try std.testing.expectEqual(AircraftClass.civil, classifyAircraft("BAW456"));
    try std.testing.expectEqual(AircraftClass.civil, classifyAircraft("DLH789"));
}

test "feed_flights: classifyAircraft military" {
    try std.testing.expectEqual(AircraftClass.military, classifyAircraft("RCH123"));
    try std.testing.expectEqual(AircraftClass.military, classifyAircraft("SAM2900"));
    try std.testing.expectEqual(AircraftClass.military, classifyAircraft("REACH456"));
    try std.testing.expectEqual(AircraftClass.military, classifyAircraft("AF1"));
}

test "feed_flights: classifyAircraft unknown empty" {
    try std.testing.expectEqual(AircraftClass.unknown, classifyAircraft(""));
    try std.testing.expectEqual(AircraftClass.unknown, classifyAircraft("   "));
}

test "feed_flights: deadReckonPosition stationary" {
    const ac = Aircraft{
        .icao24 = "abc123",
        .callsign = "TEST",
        .origin_country = "United States",
        .lat = 40.0,
        .lon = -74.0,
        .altitude_m = 10000,
        .velocity_mps = 0,
        .heading_deg = 90,
        .vertical_rate_mps = 0,
        .on_ground = false,
        .spi = false,
        .last_contact = 0,
    };

    const predicted = deadReckonPosition(ac, 60.0);
    try std.testing.expectApproxEqAbs(ac.lat, predicted.lat, 1e-10);
    try std.testing.expectApproxEqAbs(ac.lon, predicted.lon, 1e-10);
}

test "feed_flights: deadReckonPosition moving east" {
    const ac = Aircraft{
        .icao24 = "abc123",
        .callsign = "TEST",
        .origin_country = "United States",
        .lat = 0.0,
        .lon = 0.0,
        .altitude_m = 10000,
        .velocity_mps = 250.0, // ~900 km/h
        .heading_deg = 90.0, // East
        .vertical_rate_mps = 0,
        .on_ground = false,
        .spi = false,
        .last_contact = 0,
    };

    const predicted = deadReckonPosition(ac, 60.0); // 1 minute
    // Should have moved east — longitude increases
    try std.testing.expect(predicted.lon > 0);
    // Distance ~15km at equator → lon ~0.135 degrees
    try std.testing.expectApproxEqAbs(@as(f64, 0.135), predicted.lon, 0.01);
}

test "feed_flights: parseStatesResponse" {
    const allocator = std.testing.allocator;
    const json =
        \\{"time":1234567890,"states":[["abc123","UAL123  ","United States",1234567890,1234567890,-74.0,40.7,10000,false,250,90,0,null,null,null,null,true,1234567890],["def456","RCH456","United States",1234567890,1234567890,-73.0,41.0,11000,false,300,85,0,null,null,null,null,false,1234567890]]}
    ;

    const aircraft = try parseStatesResponse(allocator, json);
    defer freeAircraftList(allocator, aircraft);

    try std.testing.expectEqual(@as(usize, 2), aircraft.len);
    try std.testing.expectEqualStrings("abc123", aircraft[0].icao24);
    try std.testing.expectEqualStrings("UAL123", aircraft[0].callsign);
    try std.testing.expectApproxEqAbs(@as(f64, 40.7), aircraft[0].lat, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -74.0), aircraft[0].lon, 1e-10);
    try std.testing.expectEqualStrings("def456", aircraft[1].icao24);
    try std.testing.expectEqualStrings("RCH456", aircraft[1].callsign);
}

test "feed_flights: parseStatesResponse empty" {
    const allocator = std.testing.allocator;
    const json = "{\"time\":1234567890,\"states\":[]}";

    const aircraft = try parseStatesResponse(allocator, json);
    defer allocator.free(aircraft);

    try std.testing.expectEqual(@as(usize, 0), aircraft.len);
}

test "feed_flights: parseStatesResponse no states field" {
    const allocator = std.testing.allocator;
    const json = "{\"time\":1234567890}";

    const aircraft = try parseStatesResponse(allocator, json);
    defer allocator.free(aircraft);

    try std.testing.expectEqual(@as(usize, 0), aircraft.len);
}

test "feed_flights: parseStatesResponse with null values" {
    const allocator = std.testing.allocator;
    const json =
        \\{"time":1234567890,"states":[["abc123","TEST","United States",1234567890,1234567890,null,null,null,true,null,null,null,null,null,null,null,false,1234567890]]}
    ;

    const aircraft = try parseStatesResponse(allocator, json);
    defer freeAircraftList(allocator, aircraft);

    try std.testing.expectEqual(@as(usize, 1), aircraft.len);
    try std.testing.expect(aircraft[0].on_ground);
    try std.testing.expectEqual(@as(f64, 0), aircraft[0].lat);
    try std.testing.expectEqual(@as(f64, 0), aircraft[0].lon);
}
