const std = @import("std");
const geo = @import("geo_math");

// =============================================================================
// CCTV Camera Management — Camera registry, snapshot fetching, viewshed
// =============================================================================
// Manages public CCTV camera positions, statuses, and viewshed calculations.
// Pure Zig, no external dependencies.

pub const CameraStatus = enum {
    online,
    offline,
    degraded,
    maintenance,
    unknown,
};

pub const CctvCamera = struct {
    id: []const u8,
    name: []const u8,
    lat: f64,
    lon: f64,
    altitude_m: f64 = 0,
    heading_deg: f64 = 0, // Camera heading (0 = north)
    fov_deg: f64 = 90, // Field of view in degrees
    range_km: f64 = 10, // Maximum visible range in km
    source: []const u8 = "", // URL or feed source
    status: CameraStatus = .unknown,
    last_update: f64 = 0,

    pub fn init(id: []const u8, name: []const u8, lat: f64, lon: f64) CctvCamera {
        return .{ .id = id, .name = name, .lat = lat, .lon = lon };
    }
};

/// A polygon point for viewshed representation
pub const PolygonPoint = struct {
    lat: f64,
    lon: f64,
};

/// Calculate viewshed polygon for a camera (simplified: circular sector)
/// Returns a list of polygon points defining the visible area
pub fn calculateViewshed(allocator: std.mem.Allocator, camera: CctvCamera, num_points: u32) ![]PolygonPoint {
    var points = try allocator.alloc(PolygonPoint, num_points + 1);
    const half_fov = camera.fov_deg / 2.0;
    const start_angle = camera.heading_deg - half_fov;
    const angle_step = camera.fov_deg / @as(f64, @floatFromInt(num_points));

    for (0..num_points) |i| {
        const angle = start_angle + @as(f64, @floatFromInt(i)) * angle_step;
        const dest = geo.destinationPoint(
            geo.LatLon.init(camera.lat, camera.lon),
            angle,
            camera.range_km * 1000.0,
        );
        points[i] = .{ .lat = dest.lat, .lon = dest.lon };
    }
    // Close the polygon
    points[num_points] = .{ .lat = camera.lat, .lon = camera.lon };

    return points;
}

/// Check if a point is within a camera's viewshed
pub fn isPointInViewshed(camera: CctvCamera, lat: f64, lon: f64) bool {
    const point = geo.LatLon.init(lat, lon);
    const cam_pos = geo.LatLon.init(camera.lat, camera.lon);
    const distance = geo.greatCircleDistance(cam_pos, point);

    if (distance > camera.range_km * 1000.0) return false;

    const bearing_to_point = geo.bearing(cam_pos, point);
    const angle_diff = angleDistance(bearing_to_point, camera.heading_deg);

    return angle_diff <= camera.fov_deg / 2.0;
}

/// Angular distance between two bearings (0-180 degrees)
fn angleDistance(a: f64, b: f64) f64 {
    var diff = @abs(a - b);
    if (diff > 180.0) diff = 360.0 - diff;
    return diff;
}

/// Load cameras from a JSON config file
/// Format: [{"id":"cam1","name":"Camera 1","lat":40.0,"lon":-74.0,"heading":45,"fov":90,"range":15,"source":"http://...","status":"online"}, ...]
pub fn loadCameras(allocator: std.mem.Allocator, json: []const u8) ![]CctvCamera {
    var cameras = std.ArrayList(CctvCamera).init(allocator);

    var pos: usize = 0;
    while (pos < json.len) {
        const obj_start = std.mem.indexOfScalarPos(u8, json, pos, '{') orelse break;
        const obj_end = findMatchingBrace(json, obj_start) orelse break;
        const obj = json[obj_start .. obj_end + 1];
        pos = obj_end + 1;

        const id = extractString(allocator, obj, "id") catch continue;
        const name = extractString(allocator, obj, "name") catch continue;
        const lat = extractFloat(obj, "lat") orelse continue;
        const lon = extractFloat(obj, "lon") orelse continue;

        var cam = CctvCamera.init(id, name, lat, lon);
        cam.heading_deg = extractFloat(obj, "heading") orelse 0;
        cam.fov_deg = extractFloat(obj, "fov") orelse 90;
        cam.range_km = extractFloat(obj, "range") orelse 10;
        cam.altitude_m = extractFloat(obj, "altitude") orelse 0;
        cam.source = extractString(allocator, obj, "source") catch "";
        const status_str = extractString(allocator, obj, "status") catch "";
        defer if (status_str.len > 0) allocator.free(status_str);
        cam.status = parseStatus(status_str);

        try cameras.append(cam);
    }

    return cameras.toOwnedSlice();
}

fn parseStatus(s: []const u8) CameraStatus {
    if (std.mem.eql(u8, s, "online")) return .online;
    if (std.mem.eql(u8, s, "offline")) return .offline;
    if (std.mem.eql(u8, s, "degraded")) return .degraded;
    if (std.mem.eql(u8, s, "maintenance")) return .maintenance;
    return .unknown;
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    for (start..json.len) |i| {
        if (json[i] == '{') depth += 1;
        if (json[i] == '}') { depth -= 1; if (depth == 0) return i; }
    }
    return null;
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

fn extractFloat(json: []const u8, key: []const u8) ?f64 {
    var key_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    var start = pos + search.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\n')) start += 1;
    if (start >= json.len or std.mem.startsWith(u8, json[start..], "null")) return null;
    var end = start;
    while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ' ') end += 1;
    return std.fmt.parseFloat(f64, json[start..end]) catch null;
}

/// Free camera list
pub fn freeCameraList(allocator: std.mem.Allocator, list: []CctvCamera) void {
    for (list) |cam| {
        allocator.free(cam.id);
        allocator.free(cam.name);
        if (cam.source.len > 0) allocator.free(cam.source);
    }
    allocator.free(list);
}

/// Serialize camera registry to JSON
pub fn camerasToJson(allocator: std.mem.Allocator, cameras: []const CctvCamera) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("[");
    for (cameras, 0..) |cam, i| {
        if (i > 0) try buf.appendSlice(",");
        try std.fmt.format(buf.writer(), "{{\"id\":\"{s}\",\"name\":\"{s}\",\"lat\":{d:.6},\"lon\":{d:.6},\"heading\":{d:.1},\"fov\":{d:.1},\"range\":{d:.1},\"status\":\"{s}\"}}", .{
            cam.id, cam.name, cam.lat, cam.lon, cam.heading_deg, cam.fov_deg, cam.range_km, @tagName(cam.status),
        });
    }
    try buf.appendSlice("]");
    return buf.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "feed_cctv: calculateViewshed produces polygon" {
    const allocator = std.testing.allocator;
    const cam = CctvCamera{
        .id = "cam1",
        .name = "Test Camera",
        .lat = 40.0,
        .lon = -74.0,
        .heading_deg = 0, // North
        .fov_deg = 90,
        .range_km = 10,
    };

    const polygon = try calculateViewshed(allocator, cam, 8);
    defer allocator.free(polygon);

    // 8 points + 1 closing point = 9
    try std.testing.expectEqual(@as(usize, 9), polygon.len);
    // Last point should be camera position (closing the polygon)
    try std.testing.expectApproxEqAbs(cam.lat, polygon[8].lat, 1e-6);
    try std.testing.expectApproxEqAbs(cam.lon, polygon[8].lon, 1e-6);
}

test "feed_cctv: isPointInViewshed within range and angle" {
    const cam = CctvCamera{
        .id = "cam1",
        .name = "Test",
        .lat = 40.0,
        .lon = -74.0,
        .heading_deg = 0, // North
        .fov_deg = 90,
        .range_km = 10,
    };

    // Point 5km north — should be visible
    try std.testing.expect(isPointInViewshed(cam, 40.04, -74.0));
}

test "feed_cctv: isPointInViewshed outside angle" {
    const cam = CctvCamera{
        .id = "cam1",
        .name = "Test",
        .lat = 40.0,
        .lon = -74.0,
        .heading_deg = 0, // North
        .fov_deg = 90,
        .range_km = 10,
    };

    // Point 5km south — outside FOV (heading north, FOV 90 = ±45°)
    try std.testing.expect(!isPointInViewshed(cam, 39.96, -74.0));
}

test "feed_cctv: isPointInViewshed outside range" {
    const cam = CctvCamera{
        .id = "cam1",
        .name = "Test",
        .lat = 40.0,
        .lon = -74.0,
        .heading_deg = 0,
        .fov_deg = 90,
        .range_km = 5, // Only 5km range
    };

    // Point 10km north — beyond range
    try std.testing.expect(!isPointInViewshed(cam, 40.1, -74.0));
}

test "feed_cctv: loadCameras from JSON" {
    const allocator = std.testing.allocator;
    const json = "[{\"id\":\"cam1\",\"name\":\"Camera 1\",\"lat\":40.0,\"lon\":-74.0,\"heading\":45,\"fov\":90,\"range\":15,\"source\":\"http://example.com/cam1\",\"status\":\"online\"},{\"id\":\"cam2\",\"name\":\"Camera 2\",\"lat\":41.0,\"lon\":-73.0,\"heading\":180,\"fov\":60,\"range\":8,\"status\":\"offline\"}]";

    const cameras = try loadCameras(allocator, json);
    defer freeCameraList(allocator, cameras);

    try std.testing.expectEqual(@as(usize, 2), cameras.len);
    try std.testing.expectEqualStrings("cam1", cameras[0].id);
    try std.testing.expectEqualStrings("Camera 1", cameras[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 45), cameras[0].heading_deg, 1e-10);
    try std.testing.expectEqual(CameraStatus.online, cameras[0].status);
    try std.testing.expectEqual(CameraStatus.offline, cameras[1].status);
}

test "feed_cctv: loadCameras empty" {
    const allocator = std.testing.allocator;
    const cameras = try loadCameras(allocator, "[]");
    defer allocator.free(cameras);
    try std.testing.expectEqual(@as(usize, 0), cameras.len);
}

test "feed_cctv: camerasToJson round-trip" {
    const allocator = std.testing.allocator;
    const cameras = [_]CctvCamera{
        .{ .id = "cam1", .name = "Test", .lat = 40.0, .lon = -74.0, .heading_deg = 0, .fov_deg = 90, .range_km = 10, .status = .online },
    };

    const json = try camerasToJson(allocator, &cameras);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"cam1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lat\":40.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"online\"") != null);
}

test "feed_cctv: parseStatus" {
    try std.testing.expectEqual(CameraStatus.online, parseStatus("online"));
    try std.testing.expectEqual(CameraStatus.offline, parseStatus("offline"));
    try std.testing.expectEqual(CameraStatus.degraded, parseStatus("degraded"));
    try std.testing.expectEqual(CameraStatus.maintenance, parseStatus("maintenance"));
    try std.testing.expectEqual(CameraStatus.unknown, parseStatus("xyz"));
}
