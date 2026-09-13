const std = @import("std");

// =============================================================================
// Traffic Feed — TomTom Traffic API, flow data, incidents
// =============================================================================
// Parses TomTom Traffic API JSON responses for traffic flow and incidents.
// Pure Zig, no external dependencies.

pub const CongestionLevel = enum {
    free_flow,
    light,
    moderate,
    heavy,
    severe,
    unknown,
};

pub const TrafficSegment = struct {
    road_name: []const u8,
    lat: f64,
    lon: f64,
    current_speed_kmph: f64,
    free_flow_speed_kmph: f64,
    current_travel_time: f64, // seconds
    free_flow_travel_time: f64, // seconds
    confidence: f64, // [0,1]
    congestion: CongestionLevel,

    pub fn init(road_name: []const u8) TrafficSegment {
        return .{
            .road_name = road_name,
            .lat = 0,
            .lon = 0,
            .current_speed_kmph = 0,
            .free_flow_speed_kmph = 0,
            .current_travel_time = 0,
            .free_flow_travel_time = 0,
            .confidence = 0,
            .congestion = .unknown,
        };
    }

    /// Speed ratio: current / free_flow (1.0 = no congestion, 0.0 = stopped)
    pub fn speedRatio(self: TrafficSegment) f64 {
        if (self.free_flow_speed_kmph <= 0) return 0;
        return @max(0.0, @min(1.0, self.current_speed_kmph / self.free_flow_speed_kmph));
    }
};

pub const IncidentType = enum {
    accident,
    congestion,
    construction,
    disabled_vehicle,
    lane_closure,
    road_hazard,
    weather,
    road_closure,
    unknown,
};

pub const TrafficIncident = struct {
    id: u32,
    incident_type: IncidentType,
    lat: f64,
    lon: f64,
    description: []const u8,
    delay_seconds: f64, // Estimated delay in seconds
    start_time: f64, // Unix timestamp
    end_time: f64, // Unix timestamp
    road_name: []const u8,
    severity: u8, // 1-4 (1=minor, 4=severe)

    pub fn init(id: u32) TrafficIncident {
        return .{
            .id = id,
            .incident_type = .unknown,
            .lat = 0,
            .lon = 0,
            .description = "",
            .delay_seconds = 0,
            .start_time = 0,
            .end_time = 0,
            .road_name = "",
            .severity = 0,
        };
    }
};

/// Classify congestion level from speed ratio
pub fn classifyCongestion(speed_ratio: f64) CongestionLevel {
    if (speed_ratio >= 0.9) return .free_flow;
    if (speed_ratio >= 0.7) return .light;
    if (speed_ratio >= 0.5) return .moderate;
    if (speed_ratio >= 0.25) return .heavy;
    if (speed_ratio > 0) return .severe;
    return .unknown;
}

/// Classify incident type from TomTom incident category code
pub fn classifyIncident(category: u8) IncidentType {
    return switch (category) {
        1 => .accident,
        2 => .congestion,
        3 => .construction,
        4 => .disabled_vehicle,
        5 => .lane_closure,
        6 => .road_hazard,
        7 => .weather,
        8 => .road_closure,
        else => .unknown,
    };
}

/// Parse TomTom flow segment data from JSON
/// Format: {"flowSegmentData":{"currentSpeed":...,"freeFlowSpeed":...,"currentTravelTime":...,"freeFlowTravelTime":...,"confidence":...,"coordinates":{"coordinate":[{"latitude":...,"longitude":...}, ...]}}}
pub fn parseFlowResponse(allocator: std.mem.Allocator, json: []const u8, road_name: []const u8) !TrafficSegment {
    var segment = TrafficSegment.init(try allocator.dupe(u8, road_name));

    segment.current_speed_kmph = extractFloat(json, "currentSpeed") orelse 0;
    segment.free_flow_speed_kmph = extractFloat(json, "freeFlowSpeed") orelse 0;
    segment.current_travel_time = extractFloat(json, "currentTravelTime") orelse 0;
    segment.free_flow_travel_time = extractFloat(json, "freeFlowTravelTime") orelse 0;
    segment.confidence = extractFloat(json, "confidence") orelse 0;

    // Extract first coordinate
    if (std.mem.indexOf(u8, json, "\"latitude\":")) |lat_pos| {
        const lat_val = std.mem.indexOf(u8, json[lat_pos..], ":") orelse return segment;
        var val_start = lat_pos + lat_val + 1;
        while (val_start < json.len and json[val_start] == ' ') val_start += 1;
        var val_end = val_start;
        while (val_end < json.len and json[val_end] != ',' and json[val_end] != '}') val_end += 1;
        segment.lat = std.fmt.parseFloat(f64, json[val_start..val_end]) catch 0;
    }
    if (std.mem.indexOf(u8, json, "\"longitude\":")) |lon_pos| {
        const lon_val = std.mem.indexOf(u8, json[lon_pos..], ":") orelse return segment;
        var val_start = lon_pos + lon_val + 1;
        while (val_start < json.len and json[val_start] == ' ') val_start += 1;
        var val_end = val_start;
        while (val_end < json.len and json[val_end] != ',' and json[val_end] != '}') val_end += 1;
        segment.lon = std.fmt.parseFloat(f64, json[val_start..val_end]) catch 0;
    }

    segment.congestion = classifyCongestion(segment.speedRatio());

    return segment;
}

/// Parse TomTom incident data from JSON
pub fn parseIncidentsResponse(allocator: std.mem.Allocator, json: []const u8) ![]TrafficIncident {
    var incidents = std.ArrayList(TrafficIncident).init(allocator);

    var pos: usize = 0;
    var id_counter: u32 = 1;

    while (pos < json.len) {
        const obj_start = std.mem.indexOfScalarPos(u8, json, pos, '{') orelse break;
        const obj_end = findMatchingBrace(json, obj_start) orelse break;
        const obj = json[obj_start .. obj_end + 1];
        pos = obj_end + 1;

        // Skip if not an incident object (no "delayInSeconds" or "category")
        if (std.mem.indexOf(u8, obj, "delayInSeconds") == null and
            std.mem.indexOf(u8, obj, "category") == null)
        {
            continue;
        }

        var incident = TrafficIncident.init(id_counter);
        id_counter += 1;

        if (extractFloat(obj, "delayInSeconds")) |delay| {
            incident.delay_seconds = delay;
        }
        if (extractFloat(obj, "latitude")) |lat| {
            incident.lat = lat;
        }
        if (extractFloat(obj, "longitude")) |lon| {
            incident.lon = lon;
        }
        if (extractFloat(obj, "startTime")) |start| {
            incident.start_time = start;
        }
        if (extractFloat(obj, "endTime")) |end| {
            incident.end_time = end;
        }
        if (extractFloat(obj, "severity")) |sev| {
            incident.severity = @intFromFloat(sev);
        }
        if (extractFloat(obj, "category")) |cat| {
            incident.incident_type = classifyIncident(@intFromFloat(cat));
        }

        incident.description = extractString(allocator, obj, "description") catch "";
        incident.road_name = extractString(allocator, obj, "roadName") catch "";

        try incidents.append(incident);
    }

    return incidents.toOwnedSlice();
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

fn extractString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const u8 {
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

/// Free traffic segment
pub fn freeTrafficSegment(allocator: std.mem.Allocator, seg: *TrafficSegment) void {
    allocator.free(seg.road_name);
}

/// Free incident list
pub fn freeIncidentList(allocator: std.mem.Allocator, list: []TrafficIncident) void {
    for (list) |inc| {
        if (inc.description.len > 0) allocator.free(inc.description);
        if (inc.road_name.len > 0) allocator.free(inc.road_name);
    }
    allocator.free(list);
}

// =============================================================================
// Tests
// =============================================================================

test "feed_traffic: classifyCongestion" {
    try std.testing.expectEqual(CongestionLevel.free_flow, classifyCongestion(0.95));
    try std.testing.expectEqual(CongestionLevel.light, classifyCongestion(0.75));
    try std.testing.expectEqual(CongestionLevel.moderate, classifyCongestion(0.55));
    try std.testing.expectEqual(CongestionLevel.heavy, classifyCongestion(0.30));
    try std.testing.expectEqual(CongestionLevel.severe, classifyCongestion(0.10));
    try std.testing.expectEqual(CongestionLevel.unknown, classifyCongestion(0.0));
}

test "feed_traffic: classifyIncident" {
    try std.testing.expectEqual(IncidentType.accident, classifyIncident(1));
    try std.testing.expectEqual(IncidentType.congestion, classifyIncident(2));
    try std.testing.expectEqual(IncidentType.construction, classifyIncident(3));
    try std.testing.expectEqual(IncidentType.road_closure, classifyIncident(8));
    try std.testing.expectEqual(IncidentType.unknown, classifyIncident(99));
}

test "feed_traffic: speedRatio" {
    const seg = TrafficSegment{
        .road_name = "I-95",
        .lat = 40.0,
        .lon = -74.0,
        .current_speed_kmph = 50,
        .free_flow_speed_kmph = 100,
        .current_travel_time = 120,
        .free_flow_travel_time = 60,
        .confidence = 0.9,
        .congestion = .moderate,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), seg.speedRatio(), 1e-10);
}

test "feed_traffic: speedRatio zero free flow" {
    const seg = TrafficSegment{
        .road_name = "Test",
        .lat = 0,
        .lon = 0,
        .current_speed_kmph = 50,
        .free_flow_speed_kmph = 0,
        .current_travel_time = 0,
        .free_flow_travel_time = 0,
        .confidence = 0,
        .congestion = .unknown,
    };
    try std.testing.expectEqual(@as(f64, 0), seg.speedRatio());
}

test "feed_traffic: parseFlowResponse" {
    const allocator = std.testing.allocator;
    const json =
        \\{"flowSegmentData":{"currentSpeed":45.5,"freeFlowSpeed":100.0,"currentTravelTime":120.0,"freeFlowTravelTime":60.0,"confidence":0.95,"coordinates":{"coordinate":[{"latitude":40.7,"longitude":-74.0}]}}}
    ;

    var seg = try parseFlowResponse(allocator, json, "I-95");
    defer freeTrafficSegment(allocator, &seg);

    try std.testing.expectApproxEqAbs(@as(f64, 45.5), seg.current_speed_kmph, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), seg.free_flow_speed_kmph, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 40.7), seg.lat, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -74.0), seg.lon, 1e-10);
    try std.testing.expectEqual(CongestionLevel.heavy, seg.congestion);
}

test "feed_traffic: parseIncidentsResponse" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"id":1,"delayInSeconds":300,"latitude":40.0,"longitude":-74.0,"category":1,"severity":3,"description":"Multi-car accident","roadName":"US-1"},{"id":2,"delayInSeconds":120,"latitude":41.0,"longitude":-73.0,"category":3,"severity":2,"description":"Road work","roadName":"I-95"}]
    ;

    const incidents = try parseIncidentsResponse(allocator, json);
    defer freeIncidentList(allocator, incidents);

    try std.testing.expectEqual(@as(usize, 2), incidents.len);
    try std.testing.expectEqual(IncidentType.accident, incidents[0].incident_type);
    try std.testing.expectApproxEqAbs(@as(f64, 300), incidents[0].delay_seconds, 1e-10);
    try std.testing.expectEqualStrings("Multi-car accident", incidents[0].description);
    try std.testing.expectEqual(IncidentType.construction, incidents[1].incident_type);
}
