const std = @import("std");

// =============================================================================
// USGS Earthquake Feed — GeoJSON parsing, magnitude filtering
// =============================================================================
// Parses USGS Earthquake Hazards Program GeoJSON feed.
// Pure Zig, no external dependencies.

pub const Earthquake = struct {
    id: []const u8, // USGS event ID
    magnitude: f64, // Moment magnitude (Mw)
    depth_km: f64, // Depth in kilometers
    lat: f64,
    lon: f64,
    place: []const u8, // Human-readable location description
    time_ms: f64, // Unix timestamp in milliseconds
    url: []const u8, // USGS event URL
    felt_reports: u32 = 0,
    tsunami_warning: bool = false,
    significance: u32 = 0, // USGS significance score

    pub fn init(id: []const u8) Earthquake {
        return .{
            .id = id,
            .magnitude = 0,
            .depth_km = 0,
            .lat = 0,
            .lon = 0,
            .place = "",
            .time_ms = 0,
            .url = "",
        };
    }
};

/// Fetch earthquakes from USGS API
/// timeframe: "hour", "day", "week", "month" — maps to USGS feed URLs
pub fn fetchEarthquakes(allocator: std.mem.Allocator, timeframe: []const u8) ![]Earthquake {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_{s}.geojson", .{timeframe}) catch return error.UrlTooLong;

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &response_body },
    }) catch return error.NetworkUnavailable;

    if (result.status != .ok) return error.HttpError;

    return parseGeoJson(allocator, response_body.items);
}

/// Parse USGS GeoJSON earthquake feed
/// Format: {"type":"FeatureCollection","features":[{"type":"Feature","id":"...","properties":{"mag":...,"place":"...","time":...,"url":"...","tsunami":...,"sig":...,"felt":...},"geometry":{"type":"Point","coordinates":[lon,lat,depth]}}, ...]}
pub fn parseGeoJson(allocator: std.mem.Allocator, json: []const u8) ![]Earthquake {
    var earthquakes = std.ArrayList(Earthquake).init(allocator);

    var pos: usize = 0;
    while (pos < json.len) {
        // Find next "Feature" object
        const feature_pos = std.mem.indexOfPos(u8, json, pos, "\"type\":\"Feature\"") orelse break;

        // Find the opening brace before this
        var brace_start = feature_pos;
        while (brace_start > 0 and json[brace_start] != '{') brace_start -= 1;

        // Find matching closing brace
        const brace_end = findMatchingBrace(json, brace_start) orelse break;
        const feature = json[brace_start .. brace_end + 1];
        pos = brace_end + 1;

        const eq = parseFeature(allocator, feature) catch continue;
        try earthquakes.append(eq);
    }

    return earthquakes.toOwnedSlice();
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

fn parseFeature(allocator: std.mem.Allocator, feature: []const u8) !Earthquake {
    // Extract ID
    const id = extractJsonString(allocator, feature, "id") catch try allocator.dupe(u8, "unknown");

    // Extract properties section
    const props_pos = std.mem.indexOf(u8, feature, "\"properties\":") orelse return error.MissingProperties;
    const props_start = std.mem.indexOfScalarPos(u8, feature, props_pos, '{') orelse return error.MissingProperties;
    const props_end = findMatchingBrace(feature, props_start) orelse return error.MissingProperties;
    const props = feature[props_start .. props_end + 1];

    // Extract geometry section
    const geom_pos = std.mem.indexOf(u8, feature, "\"geometry\":") orelse return error.MissingGeometry;
    const geom_start = std.mem.indexOfScalarPos(u8, feature, geom_pos, '{') orelse return error.MissingGeometry;
    const geom_end = findMatchingBrace(feature, geom_start) orelse return error.MissingGeometry;
    const geom = feature[geom_start .. geom_end + 1];

    // Parse properties
    const magnitude = extractJsonFloat(props, "mag") orelse 0;
    const place = extractJsonString(allocator, props, "place") catch try allocator.dupe(u8, "");
    const time_ms = extractJsonFloat(props, "time") orelse 0;
    const url = extractJsonString(allocator, props, "url") catch try allocator.dupe(u8, "");
    const felt = extractJsonFloat(props, "felt") orelse 0;
    const tsunami = extractJsonBool(props, "tsunami");
    const sig = extractJsonFloat(props, "sig") orelse 0;

    // Parse geometry coordinates: [lon, lat, depth]
    const coords = extractCoordinates(geom);

    return .{
        .id = id,
        .magnitude = magnitude,
        .depth_km = coords.depth,
        .lat = coords.lat,
        .lon = coords.lon,
        .place = place,
        .time_ms = time_ms,
        .url = url,
        .felt_reports = @intFromFloat(@max(0, felt)),
        .tsunami_warning = tsunami,
        .significance = @intFromFloat(@max(0, sig)),
    };
}

fn extractCoordinates(geom: []const u8) struct { lon: f64, lat: f64, depth: f64 } {
    const coords_pos = std.mem.indexOf(u8, geom, "\"coordinates\":") orelse return .{ .lon = 0, .lat = 0, .depth = 0 };
    const arr_start = std.mem.indexOfScalarPos(u8, geom, coords_pos, '[') orelse return .{ .lon = 0, .lat = 0, .depth = 0 };
    const arr_end = std.mem.indexOfScalarPos(u8, geom, arr_start, ']') orelse return .{ .lon = 0, .lat = 0, .depth = 0 };
    const coords_str = geom[arr_start + 1 .. arr_end];

    var parts = std.mem.splitScalar(u8, coords_str, ',');
    const lon = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse "0", " ")) catch 0;
    const lat = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse "0", " ")) catch 0;
    const depth = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse "0", " ")) catch 0;

    return .{ .lon = lon, .lat = lat, .depth = depth };
}

fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const u8 {
    var key_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return error.KeyTooLong;
    const pos = std.mem.indexOf(u8, json, search) orelse return error.KeyNotFound;
    var start = pos + search.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\n')) start += 1;
    if (start >= json.len or json[start] != '"') return error.NotAString;
    start += 1;
    var end = start;
    while (end < json.len and json[end] != '"') end += 1;
    return allocator.dupe(u8, json[start..end]);
}

fn extractJsonFloat(json: []const u8, key: []const u8) ?f64 {
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

fn extractJsonBool(json: []const u8, key: []const u8) bool {
    var key_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return false;
    const pos = std.mem.indexOf(u8, json, search) orelse return false;
    var start = pos + search.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\n')) start += 1;
    if (start < json.len and std.mem.startsWith(u8, json[start..], "true")) return true;
    return false;
}

/// Filter earthquakes by minimum magnitude
pub fn filterByMagnitude(allocator: std.mem.Allocator, earthquakes: []const Earthquake, min_mag: f64) ![]Earthquake {
    var result = std.ArrayList(Earthquake).init(allocator);
    for (earthquakes) |eq| {
        if (eq.magnitude >= min_mag) {
            try result.append(eq);
        }
    }
    return result.toOwnedSlice();
}

/// Free earthquake list
pub fn freeEarthquakeList(allocator: std.mem.Allocator, list: []Earthquake) void {
    for (list) |eq| {
        allocator.free(eq.id);
        allocator.free(eq.place);
        allocator.free(eq.url);
    }
    allocator.free(list);
}

// =============================================================================
// Tests
// =============================================================================

test "feed_earthquakes: parseGeoJson single feature" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type":"FeatureCollection","features":[
        \\{"type":"Feature","id":"us7000abcd","properties":{"mag":5.6,"place":"10km S of City","time":1700000000000,"url":"https://earthquake.usgs.gov/eventpage/us7000abcd","tsunami":false,"sig":500,"felt":10},
        \\"geometry":{"type":"Point","coordinates":[-74.0,40.0,10.0]}}
        \\]}
    ;

    const earthquakes = try parseGeoJson(allocator, json);
    defer freeEarthquakeList(allocator, earthquakes);

    try std.testing.expectEqual(@as(usize, 1), earthquakes.len);
    try std.testing.expectEqualStrings("us7000abcd", earthquakes[0].id);
    try std.testing.expectApproxEqAbs(@as(f64, 5.6), earthquakes[0].magnitude, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), earthquakes[0].lat, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -74.0), earthquakes[0].lon, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), earthquakes[0].depth_km, 1e-10);
    try std.testing.expectEqualStrings("10km S of City", earthquakes[0].place);
}

test "feed_earthquakes: parseGeoJson multiple features" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type":"FeatureCollection","features":[
        \\{"type":"Feature","id":"eq1","properties":{"mag":3.2,"place":"Place A","time":1000,"url":"http://a","tsunami":false,"sig":100,"felt":5},"geometry":{"type":"Point","coordinates":[1.0,2.0,5.0]}},
        \\{"type":"Feature","id":"eq2","properties":{"mag":6.1,"place":"Place B","time":2000,"url":"http://b","tsunami":true,"sig":800,"felt":50},"geometry":{"type":"Point","coordinates":[3.0,4.0,15.0]}}
        \\]}
    ;

    const earthquakes = try parseGeoJson(allocator, json);
    defer freeEarthquakeList(allocator, earthquakes);

    try std.testing.expectEqual(@as(usize, 2), earthquakes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), earthquakes[0].magnitude, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 6.1), earthquakes[1].magnitude, 1e-10);
    try std.testing.expect(earthquakes[1].tsunami_warning);
    try std.testing.expect(!earthquakes[0].tsunami_warning);
}

test "feed_earthquakes: parseGeoJson empty" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"FeatureCollection\",\"features\":[]}";

    const earthquakes = try parseGeoJson(allocator, json);
    defer allocator.free(earthquakes);

    try std.testing.expectEqual(@as(usize, 0), earthquakes.len);
}

test "feed_earthquakes: filterByMagnitude" {
    const allocator = std.testing.allocator;
    const earthquakes = [_]Earthquake{
        .{ .id = "a", .magnitude = 2.0, .depth_km = 5, .lat = 0, .lon = 0, .place = "", .time_ms = 0, .url = "" },
        .{ .id = "b", .magnitude = 5.5, .depth_km = 10, .lat = 0, .lon = 0, .place = "", .time_ms = 0, .url = "" },
        .{ .id = "c", .magnitude = 4.0, .depth_km = 15, .lat = 0, .lon = 0, .place = "", .time_ms = 0, .url = "" },
        .{ .id = "d", .magnitude = 7.2, .depth_km = 20, .lat = 0, .lon = 0, .place = "", .time_ms = 0, .url = "" },
    };

    const filtered = try filterByMagnitude(allocator, &earthquakes, 5.0);
    defer allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("b", filtered[0].id);
    try std.testing.expectEqualStrings("d", filtered[1].id);
}
