const std = @import("std");
const geo = @import("geo_math");

// =============================================================================
// AIS Vessel Tracking — Vessel state, type classification, navigation status
// =============================================================================
// Parses AIS vessel data from HTTP/JSON APIs (e.g., AISHub, MarineTraffic).
// Pure Zig, no external dependencies.

pub const NavigationStatus = enum {
    under_way_engine,
    at_anchor,
    not_under_command,
    restricted_manoeuvrability,
    constrained_by_draught,
    moored,
    aground,
    engaged_in_fishing,
    under_way_sailing,
    reserved_hsc,
    reserved_wing,
    reserved,
    unknown,
};

pub const VesselType = enum {
    cargo,
    tanker,
    passenger,
    fishing,
    pleasure_craft,
    tug,
    pilot,
    sar,
    military,
    law_enforcement,
    medical,
    other,
    unknown,
};

pub const Vessel = struct {
    mmsi: u32, // Maritime Mobile Service Identity (9 digits)
    name: []const u8,
    lat: f64,
    lon: f64,
    speed_knots: f64, // Speed over ground in knots
    course_deg: f64, // Course over ground in degrees
    heading_deg: f64, // True heading in degrees
    nav_status: NavigationStatus,
    vessel_type: VesselType,
    imo: u32 = 0, // International Maritime Organization number
    callsign: []const u8 = "",
    destination: []const u8 = "",
    eta: []const u8 = "",
    draught: f64 = 0, // Maximum present static draught in meters
    timestamp: f64 = 0,

    pub fn init(mmsi: u32) Vessel {
        return .{
            .mmsi = mmsi,
            .name = "",
            .lat = 0,
            .lon = 0,
            .speed_knots = 0,
            .course_deg = 0,
            .heading_deg = 0,
            .nav_status = .unknown,
            .vessel_type = .unknown,
        };
    }
};

/// Classify vessel type from AIS type code (0-255)
pub fn classifyVesselType(type_code: u8) VesselType {
    return switch (type_code) {
        0 => .unknown,
        20...29 => .cargo, // Wing in ground
        30...39 => .fishing,
        40...49 => .pleasure_craft,
        50...59 => .pilot,
        60...69 => .sar, // Search and Rescue
        70...79 => .cargo,
        80...89 => .tanker,
        90...99 => .other,
        100...109 => .cargo,
        110...119 => .passenger,
        120...129 => .cargo,
        130...139 => .cargo,
        140...149 => .other,
        150...159 => .other,
        160...169 => .other,
        170...179 => .other,
        180...189 => .other,
        190...199 => .other,
        200...209 => .other,
        210...219 => .other,
        220...229 => .other,
        230...239 => .other,
        240...249 => .other,
        250...255 => .other,
        else => .unknown,
    };
}

/// Parse navigation status from AIS message code (0-15)
pub fn parseNavigationStatus(code: u8) NavigationStatus {
    return switch (code) {
        0 => .under_way_engine,
        1 => .at_anchor,
        2 => .not_under_command,
        3 => .restricted_manoeuvrability,
        4 => .constrained_by_draught,
        5 => .moored,
        6 => .aground,
        7 => .engaged_in_fishing,
        8 => .under_way_sailing,
        9 => .reserved_hsc,
        10 => .reserved_wing,
        11...14 => .reserved,
        else => .unknown,
    };
}

/// Dead-reckoning: predict future vessel position
pub fn deadReckonPosition(vessel: Vessel, dt_hours: f64) geo.LatLon {
    const current = geo.LatLon.init(vessel.lat, vessel.lon);
    if (vessel.speed_knots <= 0) return current;

    // 1 knot = 1 nautical mile per hour = 1852 meters per hour
    const distance_m = vessel.speed_knots * 1852.0 * dt_hours;
    return geo.destinationPoint(current, vessel.course_deg, distance_m);
}

/// Parse a JSON array of vessels from an AIS API response
/// Expected format: [{"mmsi":123456789,"name":"VESSEL","lat":40.0,"lon":-74.0,...}, ...]
pub fn parseVesselsResponse(allocator: std.mem.Allocator, json: []const u8) ![]Vessel {
    var vessels = std.ArrayList(Vessel).init(allocator);

    var pos: usize = 0;
    while (pos < json.len) {
        // Find next object start
        const obj_start = std.mem.indexOfScalarPos(u8, json, pos, '{') orelse break;
        const obj_end = findMatchingBrace(json, obj_start) orelse break;
        const obj = json[obj_start .. obj_end + 1];
        pos = obj_end + 1;

        const vessel = parseVesselObject(allocator, obj) catch continue;
        try vessels.append(vessel);
    }

    return vessels.toOwnedSlice();
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    for (start..json.len) |i| {
        if (json[i] == '{') depth += 1;
        if (json[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn parseVesselObject(allocator: std.mem.Allocator, obj: []const u8) !Vessel {
    const mmsi = extractInt(obj, "mmsi") orelse return error.MissingMMSI;

    var vessel = Vessel.init(@intCast(mmsi));
    vessel.name = extractString(allocator, obj, "name") catch "";
    vessel.lat = extractFloat(obj, "lat") orelse 0;
    vessel.lon = extractFloat(obj, "lon") orelse 0;
    vessel.speed_knots = extractFloat(obj, "speed") orelse extractFloat(obj, "sog") orelse 0;
    vessel.course_deg = extractFloat(obj, "course") orelse extractFloat(obj, "cog") orelse 0;
    vessel.heading_deg = extractFloat(obj, "heading") orelse extractFloat(obj, "hdg") orelse 0;
    vessel.draught = extractFloat(obj, "draught") orelse 0;

    if (extractInt(obj, "nav_status")) |status| {
        vessel.nav_status = parseNavigationStatus(@intCast(status));
    }
    if (extractInt(obj, "type")) |vtype| {
        vessel.vessel_type = classifyVesselType(@intCast(vtype));
    }

    return vessel;
}

fn extractString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const u8 {
    var key_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return error.KeyTooLong;
    const pos = std.mem.indexOf(u8, json, search) orelse return error.KeyNotFound;
    const val_start = pos + search.len;

    if (val_start >= json.len) return error.KeyNotFound;

    if (json[val_start] == '"') {
        const str_start = val_start + 1;
        var end = str_start;
        while (end < json.len and json[end] != '"') end += 1;
        return allocator.dupe(u8, json[str_start..end]);
    }
    return error.NotAString;
}

fn extractFloat(json: []const u8, key: []const u8) ?f64 {
    var key_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    var start = pos + search.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\n')) start += 1;
    if (start >= json.len) return null;
    if (std.mem.startsWith(u8, json[start..], "null")) return null;

    var end = start;
    while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ' ') end += 1;
    return std.fmt.parseFloat(f64, json[start..end]) catch null;
}

fn extractInt(json: []const u8, key: []const u8) ?i64 {
    const val = extractFloat(json, key) orelse return null;
    return @intFromFloat(val);
}

/// Free vessel list and allocated strings
pub fn freeVesselList(allocator: std.mem.Allocator, list: []Vessel) void {
    for (list) |v| {
        if (v.name.len > 0) allocator.free(v.name);
    }
    allocator.free(list);
}

// =============================================================================
// Tests
// =============================================================================

test "feed_vessels: classifyVesselType" {
    try std.testing.expectEqual(VesselType.tanker, classifyVesselType(80));
    try std.testing.expectEqual(VesselType.cargo, classifyVesselType(70));
    try std.testing.expectEqual(VesselType.passenger, classifyVesselType(110));
    try std.testing.expectEqual(VesselType.fishing, classifyVesselType(30));
    try std.testing.expectEqual(VesselType.unknown, classifyVesselType(0));
}

test "feed_vessels: parseNavigationStatus" {
    try std.testing.expectEqual(NavigationStatus.under_way_engine, parseNavigationStatus(0));
    try std.testing.expectEqual(NavigationStatus.at_anchor, parseNavigationStatus(1));
    try std.testing.expectEqual(NavigationStatus.moored, parseNavigationStatus(5));
    try std.testing.expectEqual(NavigationStatus.engaged_in_fishing, parseNavigationStatus(7));
    try std.testing.expectEqual(NavigationStatus.unknown, parseNavigationStatus(15));
}

test "feed_vessels: deadReckonPosition stationary" {
    const vessel = Vessel{
        .mmsi = 123456789,
        .name = "TEST",
        .lat = 40.0,
        .lon = -74.0,
        .speed_knots = 0,
        .course_deg = 90,
        .heading_deg = 90,
        .nav_status = .moored,
        .vessel_type = .cargo,
    };

    const predicted = deadReckonPosition(vessel, 1.0);
    try std.testing.expectApproxEqAbs(vessel.lat, predicted.lat, 1e-10);
    try std.testing.expectApproxEqAbs(vessel.lon, predicted.lon, 1e-10);
}

test "feed_vessels: deadReckonPosition moving" {
    const vessel = Vessel{
        .mmsi = 123456789,
        .name = "TEST",
        .lat = 0.0,
        .lon = 0.0,
        .speed_knots = 10.0, // 10 knots
        .course_deg = 90.0, // East
        .heading_deg = 90.0,
        .nav_status = .under_way_engine,
        .vessel_type = .cargo,
    };

    const predicted = deadReckonPosition(vessel, 1.0); // 1 hour
    // 10 nm = 18520 m → lon ~0.167 degrees at equator
    try std.testing.expect(predicted.lon > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.167), predicted.lon, 0.01);
}

test "feed_vessels: parseVesselsResponse" {
    const allocator = std.testing.allocator;
    const json = "[{\"mmsi\":123456789,\"name\":\"TESTVESSEL\",\"lat\":40.0,\"lon\":-74.0,\"speed\":12.5,\"course\":45,\"heading\":46,\"type\":70,\"nav_status\":0}]";

    const vessels = try parseVesselsResponse(allocator, json);
    defer freeVesselList(allocator, vessels);

    try std.testing.expectEqual(@as(usize, 1), vessels.len);
    try std.testing.expectEqual(@as(u32, 123456789), vessels[0].mmsi);
    try std.testing.expectEqualStrings("TESTVESSEL", vessels[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), vessels[0].lat, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), vessels[0].speed_knots, 1e-10);
    try std.testing.expectEqual(VesselType.cargo, vessels[0].vessel_type);
    try std.testing.expectEqual(NavigationStatus.under_way_engine, vessels[0].nav_status);
}

test "feed_vessels: parseVesselsResponse multiple" {
    const allocator = std.testing.allocator;
    const json = "[{\"mmsi\":111,\"name\":\"A\",\"lat\":1,\"lon\":2,\"speed\":0,\"course\":0,\"heading\":0},{\"mmsi\":222,\"name\":\"B\",\"lat\":3,\"lon\":4,\"speed\":5,\"course\":90,\"heading\":90}]";

    const vessels = try parseVesselsResponse(allocator, json);
    defer freeVesselList(allocator, vessels);

    try std.testing.expectEqual(@as(usize, 2), vessels.len);
    try std.testing.expectEqual(@as(u32, 111), vessels[0].mmsi);
    try std.testing.expectEqual(@as(u32, 222), vessels[1].mmsi);
}

test "feed_vessels: parseVesselsResponse empty" {
    const allocator = std.testing.allocator;
    const json = "[]";

    const vessels = try parseVesselsResponse(allocator, json);
    defer allocator.free(vessels);

    try std.testing.expectEqual(@as(usize, 0), vessels.len);
}
