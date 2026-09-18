const std = @import("std");

// =============================================================================
// Annotation System — Persistent labels, pins, measurement tools
// =============================================================================
// Manages user-created annotations on the globe: pins, labels, routes,
// measurements, and areas. Pure Zig, no external dependencies.

pub const AnnotationType = enum {
    pin,
    label,
    route,
    area,
    measurement,
    freehand,
};

pub const Pin = struct {
    id: u32,
    lat: f64,
    lon: f64,
    title: []const u8,
    description: []const u8,
    color: [3]f32 = .{ 1, 0, 0 },
    icon: []const u8 = "pin",
};

pub const Route = struct {
    id: u32,
    waypoints: []Waypoint,
    name: []const u8,
    color: [3]f32 = .{ 0, 1, 1 },
    line_width: f32 = 2.0,
    show_distance: bool = true,
};

pub const Waypoint = struct {
    lat: f64,
    lon: f64,
    alt_m: f64 = 0,
    label: []const u8 = "",
};

pub const Measurement = struct {
    id: u32,
    from_lat: f64,
    from_lon: f64,
    to_lat: f64,
    to_lon: f64,
    distance_m: f64,
    bearing_deg: f64,
};

pub const Annotation = union(AnnotationType) {
    pin: Pin,
    label: Pin, // same as pin but no icon
    route: Route,
    area: Route, // closed route
    measurement: Measurement,
    freehand: Route, // freehand drawing as a route
};

pub const AnnotationStore = struct {
    allocator: std.mem.Allocator,
    annotations: std.ArrayList(Annotation),
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) AnnotationStore {
        return .{
            .allocator = allocator,
            .annotations = std.ArrayList(Annotation).init(allocator),
        };
    }

    pub fn deinit(self: *AnnotationStore) void {
        self.clear();
        self.annotations.deinit();
    }

    pub fn addPin(self: *AnnotationStore, lat: f64, lon: f64, title: []const u8, description: []const u8) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.annotations.append(.{ .pin = .{
            .id = id,
            .lat = lat,
            .lon = lon,
            .title = try self.allocator.dupe(u8, title),
            .description = try self.allocator.dupe(u8, description),
        } });
        return id;
    }

    pub fn addRoute(self: *AnnotationStore, waypoints: []const Waypoint, name: []const u8) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        const wp_copy = try self.allocator.alloc(Waypoint, waypoints.len);
        for (waypoints, 0..) |wp, i| {
            wp_copy[i] = .{
                .lat = wp.lat,
                .lon = wp.lon,
                .alt_m = wp.alt_m,
                .label = if (wp.label.len > 0) try self.allocator.dupe(u8, wp.label) else "",
            };
        }
        try self.annotations.append(.{ .route = .{
            .id = id,
            .waypoints = wp_copy,
            .name = try self.allocator.dupe(u8, name),
        } });
        return id;
    }

    pub fn addMeasurement(self: *AnnotationStore, from_lat: f64, from_lon: f64, to_lat: f64, to_lon: f64, distance_m: f64, bearing_deg: f64) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.annotations.append(.{ .measurement = .{
            .id = id,
            .from_lat = from_lat,
            .from_lon = from_lon,
            .to_lat = to_lat,
            .to_lon = to_lon,
            .distance_m = distance_m,
            .bearing_deg = bearing_deg,
        } });
        return id;
    }

    pub fn remove(self: *AnnotationStore, id: u32) void {
        var i: usize = 0;
        while (i < self.annotations.items.len) {
            const ann = self.annotations.items[i];
            const ann_id = switch (ann) {
                .pin => |p| p.id,
                .label => |p| p.id,
                .route => |r| r.id,
                .area => |r| r.id,
                .measurement => |m| m.id,
                .freehand => |r| r.id,
            };
            if (ann_id == id) {
                self.freeAnnotation(ann);
                _ = self.annotations.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clear(self: *AnnotationStore) void {
        for (self.annotations.items) |ann| {
            self.freeAnnotation(ann);
        }
        self.annotations.clearRetainingCapacity();
    }

    fn freeAnnotation(self: *AnnotationStore, ann: Annotation) void {
        switch (ann) {
            .pin => |p| {
                self.allocator.free(p.title);
                self.allocator.free(p.description);
            },
            .label => |p| {
                self.allocator.free(p.title);
                self.allocator.free(p.description);
            },
            .route, .area, .freehand => |r| {
                for (r.waypoints) |wp| {
                    if (wp.label.len > 0) self.allocator.free(wp.label);
                }
                self.allocator.free(r.waypoints);
                self.allocator.free(r.name);
            },
            .measurement => {},
        }
    }

    pub fn count(self: *AnnotationStore) usize {
        return self.annotations.items.len;
    }

    pub fn getAnnotations(self: *AnnotationStore) []const Annotation {
        return self.annotations.items;
    }

    /// Export annotations to GeoJSON
    pub fn exportGeoJson(self: *AnnotationStore, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try buf.appendSlice("{\"type\":\"FeatureCollection\",\"features\":[");
        var first = true;

        for (self.annotations.items) |ann| {
            if (!first) try buf.appendSlice(",");
            first = false;

            switch (ann) {
                .pin => |p| {
                    try std.fmt.format(buf.writer(), "{{\"type\":\"Feature\",\"id\":{d},\"geometry\":{{\"type\":\"Point\",\"coordinates\":[{d:.6},{d:.6}]}}}}", .{ p.id, p.lon, p.lat });
                },
                .label => |p| {
                    try std.fmt.format(buf.writer(), "{{\"type\":\"Feature\",\"id\":{d},\"geometry\":{{\"type\":\"Point\",\"coordinates\":[{d:.6},{d:.6}]}}}}", .{ p.id, p.lon, p.lat });
                },
                .route => |r| {
                    try buf.appendSlice("{\"type\":\"Feature\",\"id\":");
                    try std.fmt.format(buf.writer(), "{d}", .{r.id});
                    try buf.appendSlice(",\"geometry\":{\"type\":\"LineString\",\"coordinates\":[");
                    for (r.waypoints, 0..) |wp, i| {
                        if (i > 0) try buf.appendSlice(",");
                        try std.fmt.format(buf.writer(), "[{d:.6},{d:.6}]", .{ wp.lon, wp.lat });
                    }
                    try buf.appendSlice("]}}");
                },
                .measurement => |m| {
                    try std.fmt.format(buf.writer(), "{{\"type\":\"Feature\",\"id\":{d},\"geometry\":{{\"type\":\"LineString\",\"coordinates\":[[{d:.6},{d:.6}],[{d:.6},{d:.6}]]}}}}", .{ m.id, m.from_lon, m.from_lat, m.to_lon, m.to_lat });
                },
                else => {},
            }
        }

        try buf.appendSlice("]}");
        return buf.toOwnedSlice();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "annotation: addPin" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    const id = try store.addPin(40.7128, -74.006, "NYC", "New York City");
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "annotation: addRoute" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    const waypoints = [_]Waypoint{
        .{ .lat = 40.0, .lon = -74.0, .label = "Start" },
        .{ .lat = 41.0, .lon = -73.0, .label = "End" },
    };

    const id = try store.addRoute(&waypoints, "Test Route");
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "annotation: addMeasurement" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    const id = try store.addMeasurement(40.0, -74.0, 41.0, -73.0, 130000, 45);
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "annotation: remove" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    const id = try store.addPin(40.0, -74.0, "Test", "Desc");
    try std.testing.expectEqual(@as(usize, 1), store.count());

    store.remove(id);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "annotation: clear" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    _ = try store.addPin(40.0, -74.0, "A", "Desc A");
    _ = try store.addPin(41.0, -73.0, "B", "Desc B");
    try std.testing.expectEqual(@as(usize, 2), store.count());

    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "annotation: exportGeoJson" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    _ = try store.addPin(40.7128, -74.006, "NYC", "New York City");

    const json = try store.exportGeoJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "{\"type\":\"FeatureCollection\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "40.712800") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "-74.006000") != null);
}

test "annotation: exportGeoJson with route" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    const waypoints = [_]Waypoint{
        .{ .lat = 40.0, .lon = -74.0 },
        .{ .lat = 41.0, .lon = -73.0 },
    };
    _ = try store.addRoute(&waypoints, "Route 1");

    const json = try store.exportGeoJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "LineString") != null);
}

test "annotation: multiple annotations" {
    const allocator = std.testing.allocator;
    var store = AnnotationStore.init(allocator);
    defer store.deinit();

    _ = try store.addPin(40.0, -74.0, "Pin1", "Desc1");
    _ = try store.addPin(41.0, -73.0, "Pin2", "Desc2");
    _ = try store.addMeasurement(40.0, -74.0, 41.0, -73.0, 130000, 45);

    try std.testing.expectEqual(@as(usize, 3), store.count());
}
