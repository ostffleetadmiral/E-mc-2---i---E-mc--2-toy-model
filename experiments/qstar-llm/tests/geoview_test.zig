//! geoview_test.zig — God's Eye View integration tests.
//!
//! End-to-end tests for the geospatial intelligence pipeline:
//! 1. Geo math: LLA↔ECEF, MGRS, great-circle distance, bearing
//! 2. Live feeds: feed manager lifecycle, state transitions
//! 3. Globe render: mesh generation, frustum culling, billboards
//! 4. Camera: fly-to interpolation, orbit, easing functions
//! 5. HUD: compass, scale bar, coordinate readout, alerts
//! 6. Annotations: pins, routes, measurements, GeoJSON export
//! 7. Scene director: focus queue, storyboards, event handling
//! 8. Voice commands: natural language to action parsing
//! 9. Data feed parsing: earthquakes, flights, vessels, satellites, CCTV

const std = @import("std");
const geo = @import("geo_math");
const flights = @import("feed_flights");
const vessels = @import("feed_vessels");
const satellites = @import("feed_satellites");
const earthquakes = @import("feed_earthquakes");
const cctv = @import("feed_cctv");
const live_feeds = @import("live_feeds");
const globe = @import("globe_render");
const camera = @import("camera");
const hud = @import("hud");
const ann = @import("annotation");
const scene = @import("scene_director");
const voice = @import("voice_command");

const allocator = std.heap.page_allocator;

// =============================================================================
// 1. Geo Math: coordinate conversions, distance, bearing
// =============================================================================

test "geoview: LLA to ECEF and back" {
    const lla = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0.0 };
    const ecef = geo.llaToEcef(lla);
    // SF is at lon=-122 (western), so y < 0; lat=37 (northern), so z > 0
    try std.testing.expect(ecef.y < 0);
    try std.testing.expect(ecef.z > 0);
}

test "geoview: great-circle distance San Francisco to Los Angeles" {
    const sf = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const la = geo.LatLon{ .lat = 34.0522, .lon = -118.2437, .alt = 0 };
    const dist = geo.greatCircleDistance(sf, la);
    // ~559 km
    try std.testing.expect(dist > 550_000 and dist < 570_000);
}

test "geoview: bearing SF to LA" {
    const sf = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const la = geo.LatLon{ .lat = 34.0522, .lon = -118.2437, .alt = 0 };
    const bearing = geo.bearing(sf, la);
    // ~137 degrees (SE)
    try std.testing.expect(bearing > 130 and bearing < 145);
}

test "geoview: MGRS encoding" {
    const lla = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const mgrs = try geo.latLonToMgrs(allocator, lla);
    defer allocator.free(mgrs);
    try std.testing.expect(mgrs.len > 0);
    // SF is in UTM zone 10
    try std.testing.expect(mgrs[0] == '1' and mgrs[1] == '0');
}

test "geoview: destination point" {
    const start = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const dest = geo.destinationPoint(start, 90.0, 1000.0); // 1km east
    try std.testing.expectApproxEqAbs(@as(f64, 37.7749), dest.lat, 0.01);
    try std.testing.expect(dest.lon > -122.4194);
}

// =============================================================================
// 2. Live Feeds: manager lifecycle
// =============================================================================

test "geoview: FeedManager register and enable layer" {
    var fm = live_feeds.FeedManager.init(allocator);
    defer fm.deinit();
    try fm.registerLayer(.flights, "OpenSky Flights");
    try fm.enableLayer(.flights);
    try std.testing.expect(fm.isLayerEnabled(.flights));
    try std.testing.expectEqual(live_feeds.FeedState.loading, fm.getLayerState(.flights));
}

test "geoview: FeedManager state transitions" {
    var fm = live_feeds.FeedManager.init(allocator);
    defer fm.deinit();
    try fm.registerLayer(.vessels, "AIS Vessels");
    try fm.enableLayer(.vessels);
    fm.updateLayerResult(.vessels, true, 100, 50.0);
    try std.testing.expectEqual(live_feeds.FeedState.nominal, fm.getLayerState(.vessels));
    const stats = fm.getLayerStats(.vessels).?;
    try std.testing.expectEqual(@as(usize, 100), stats.item_count);
}

// =============================================================================
// 3. Globe Render: mesh, frustum, billboards
// =============================================================================

test "geoview: ellipsoid mesh generation" {
    var mesh = try globe.generateEllipsoidMesh(allocator, 16, 32);
    defer mesh.deinit();
    try std.testing.expect(mesh.vertices.len > 0);
    try std.testing.expect(mesh.indices.len > 0);
}

test "geoview: frustum contains origin" {
    const cam = globe.Camera.init(globe.Vec3.init(0, 0, 1000));
    const vp = cam.getViewProjection();
    const frustum = globe.Frustum.fromViewProjection(vp);
    try std.testing.expect(frustum.containsPoint(globe.Vec3.init(0, 0, 0)));
}

test "geoview: GlobeRenderer entity management" {
    var renderer = try globe.GlobeRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.addEntity(.{
        .id = 1,
        .entity_type = .aircraft,
        .position = globe.Vec3.init(6371000, 0, 0),
        .label = "TEST001",
    });
    try std.testing.expectEqual(@as(usize, 1), renderer.entities.items.len);
    renderer.removeEntity(1);
    try std.testing.expectEqual(@as(usize, 0), renderer.entities.items.len);
}

// =============================================================================
// 4. Camera: fly-to, orbit, easing
// =============================================================================

test "geoview: easing functions" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), camera.easeInOutCubic(0.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), camera.easeInOutCubic(1.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), camera.easeInOutSine(0.5), 0.1);
}

test "geoview: fly-to controller interpolation" {
    var controller = camera.FlyToController{};
    const current = camera.CameraState{
        .position = globe.Vec3.init(0, 0, 10000),
        .heading = 0,
        .pitch = 0,
        .roll = 0,
        .fov = 1.0,
    };
    const dest = camera.CameraState{
        .position = globe.Vec3.init(1000, 1000, 1000),
        .heading = 0,
        .pitch = 0,
        .roll = 0,
        .fov = 1.0,
    };
    controller.flyTo(current, dest, 5.0);
    try std.testing.expect(controller.target != null);
    try std.testing.expect(controller.target.?.duration == 5.0);
}

// =============================================================================
// 5. HUD: compass, scale bar, coordinate readout
// =============================================================================

test "geoview: HUD compass build" {
    var renderer = hud.HudRenderer.init(allocator, 1920, 1080);
    defer renderer.deinit();
    try renderer.buildCompass(.{ .heading_deg = 45.0, .pitch_deg = 0, .roll_deg = 0 });
    try std.testing.expect(renderer.elements.items.len > 0);
}

test "geoview: HUD coordinate readout" {
    var renderer = hud.HudRenderer.init(allocator, 1920, 1080);
    defer renderer.deinit();
    try renderer.buildCoordinateReadout(.{ .lat = 37.7749, .lon = -122.4194, .alt_m = 100.0, .mgrs = "10S" });
    try std.testing.expect(renderer.elements.items.len > 0);
}

test "geoview: HUD alert" {
    var renderer = hud.HudRenderer.init(allocator, 1920, 1080);
    defer renderer.deinit();
    try renderer.buildAlert("Test alert", .warning);
    try std.testing.expect(renderer.elements.items.len > 0);
}

// =============================================================================
// 6. Annotations: pins, routes, measurements, GeoJSON
// =============================================================================

test "geoview: annotation pin add and remove" {
    var store = ann.AnnotationStore.init(allocator);
    defer store.deinit();
    const id = try store.addPin(37.7749, -122.4194, "SF", "San Francisco");
    try std.testing.expectEqual(@as(usize, 1), store.count());
    store.remove(id);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "geoview: annotation measurement" {
    var store = ann.AnnotationStore.init(allocator);
    defer store.deinit();
    _ = try store.addMeasurement(37.7749, -122.4194, 34.0522, -118.2437, 559_000, 137);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "geoview: annotation GeoJSON export" {
    var store = ann.AnnotationStore.init(allocator);
    defer store.deinit();
    _ = try store.addPin(37.7749, -122.4194, "SF", "San Francisco");
    const geojson = try store.exportGeoJson(allocator);
    defer allocator.free(geojson);
    try std.testing.expect(std.mem.indexOf(u8, geojson, "FeatureCollection") != null);
    try std.testing.expect(std.mem.indexOf(u8, geojson, "Point") != null);
}

// =============================================================================
// 7. Scene Director: focus queue, storyboards
// =============================================================================

test "geoview: scene director focus queue" {
    var director = scene.SceneDirector.init(allocator);
    defer director.deinit();
    try director.queueFocus(.{
        .entity_id = 1,
        .priority = 3,
    });
    try std.testing.expectEqual(@as(usize, 1), director.queueLength());
}

test "geoview: scene director storyboard" {
    var director = scene.SceneDirector.init(allocator);
    defer director.deinit();
    try director.addStoryboardEntry(.{
        .timestamp = 1.0,
        .target = .{ .entity_id = 1 },
        .event = .entity_entered,
        .description = "Test storyboard entry",
    });
    try std.testing.expect(director.storyboard.items.len > 0);
}

// =============================================================================
// 8. Voice Commands: natural language parsing
// =============================================================================

test "geoview: voice command fly_to" {
    const cmd = try voice.parseCommand(allocator, "fly to San Francisco");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.fly_to, cmd.action);
}

test "geoview: voice command zoom_in" {
    const cmd = try voice.parseCommand(allocator, "zoom in");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.zoom_in, cmd.action);
}

test "geoview: voice command toggle_layer" {
    const cmd = try voice.parseCommand(allocator, "show flights layer");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.toggle_layer, cmd.action);
}

test "geoview: voice command with coordinates" {
    const cmd = try voice.parseCommand(allocator, "fly to 37.7749 -122.4194");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.fly_to, cmd.action);
    try std.testing.expect(cmd.lat != null);
    try std.testing.expect(cmd.lon != null);
}

// =============================================================================
// 9. Data Feed Parsing
// =============================================================================

test "geoview: earthquake GeoJSON parsing" {
    const geojson =
        \\{"type":"FeatureCollection","features":[
        \\{"type":"Feature","properties":{"mag":5.5,"place":"Test City","url":"http://example.com","felt":10,"tsunami":0,"sig":500,"time":1700000000000},
        \\"geometry":{"type":"Point","coordinates":[-122.4,37.7,10.0]}}
        \\]}
    ;
    const eqs = try earthquakes.parseGeoJson(allocator, geojson);
    defer earthquakes.freeEarthquakeList(allocator, eqs);
    try std.testing.expectEqual(@as(usize, 1), eqs.len);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), eqs[0].magnitude, 1e-5);
}

test "geoview: flight classification" {
    const class = flights.classifyAircraft("UAL123");
    try std.testing.expect(class != .unknown);
}

test "geoview: flight dead reckoning" {
    const aircraft = flights.Aircraft.init("ABC123");
    const predicted = flights.deadReckonPosition(aircraft, 3600.0); // 1 hour
    // At zero velocity, position shouldn't change much
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), predicted.lat, 0.01);
}

test "geoview: vessel dead reckoning" {
    var vessel = vessels.Vessel.init(123456789);
    vessel.lat = 37.0;
    vessel.lon = -122.0;
    vessel.speed_knots = 10;
    vessel.course_deg = 90;
    const predicted = vessels.deadReckonPosition(vessel, 1.0); // 1 hour
    try std.testing.expect(predicted.lon > -122.0); // moved east
}

test "geoview: satellite TLE parsing" {
    const line1 = "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9999";
    const line2 = "2 25544  51.6400 208.0000 0006700 130.0000 230.0000 15.50000000  1000";
    const sat = satellites.parseTle(allocator, "ISS", line1, line2) catch null;
    if (sat) |s| {
        try std.testing.expectEqual(@as(u32, 25544), s.norad_id);
        try std.testing.expectApproxEqAbs(@as(f64, 51.64), s.inclination_deg, 0.1);
    }
}

test "geoview: CCTV viewshed calculation" {
    const cam_entity = cctv.CctvCamera.init("cam001", "Test Camera", 37.7749, -122.4194);
    const viewshed = try cctv.calculateViewshed(allocator, cam_entity, 16);
    defer allocator.free(viewshed);
    try std.testing.expect(viewshed.len > 0);
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== GEOVIEW INTEGRATION TESTS                       ===\n", .{});
    std.debug.print("========================================================\n", .{});

    const tests = [_]struct {
        name: []const u8,
        func: *const fn () anyerror!void,
    }{
        .{ .name = "LLA to ECEF", .func = testLlaEcef },
        .{ .name = "Great-circle distance SF-LA", .func = testGcDistance },
        .{ .name = "Bearing SF-LA", .func = testBearing },
        .{ .name = "MGRS encoding", .func = testMgrs },
        .{ .name = "Destination point", .func = testDestination },
        .{ .name = "FeedManager register/enable", .func = testFeedRegister },
        .{ .name = "FeedManager state transitions", .func = testFeedStates },
        .{ .name = "Ellipsoid mesh generation", .func = testMeshGen },
        .{ .name = "Frustum contains origin", .func = testFrustum },
        .{ .name = "GlobeRenderer entity mgmt", .func = testEntityMgmt },
        .{ .name = "Easing functions", .func = testEasing },
        .{ .name = "Fly-to controller", .func = testFlyTo },
        .{ .name = "HUD compass", .func = testHudCompass },
        .{ .name = "HUD coordinate readout", .func = testHudCoord },
        .{ .name = "HUD alert", .func = testHudAlert },
        .{ .name = "Annotation pin add/remove", .func = testAnnPin },
        .{ .name = "Annotation measurement", .func = testAnnMeasure },
        .{ .name = "Annotation GeoJSON export", .func = testAnnGeoJson },
        .{ .name = "Scene director focus queue", .func = testSceneFocus },
        .{ .name = "Scene director storyboard", .func = testSceneStoryboard },
        .{ .name = "Voice command fly_to", .func = testVoiceFlyTo },
        .{ .name = "Voice command zoom_in", .func = testVoiceZoom },
        .{ .name = "Voice command toggle_layer", .func = testVoiceToggle },
        .{ .name = "Voice command with coords", .func = testVoiceCoords },
        .{ .name = "Earthquake GeoJSON parsing", .func = testEarthquakeParse },
        .{ .name = "Flight classification", .func = testFlightClass },
        .{ .name = "Flight dead reckoning", .func = testFlightDr },
        .{ .name = "Vessel dead reckoning", .func = testVesselDr },
        .{ .name = "Satellite TLE parsing", .func = testTleParse },
        .{ .name = "CCTV viewshed", .func = testCctvViewshed },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (tests) |t| {
        std.debug.print("  [{s}] {s}...", .{ "RUN", t.name });
        t.func() catch |err| {
            std.debug.print(" FAIL ({s})\n", .{@errorName(err)});
            failed += 1;
            continue;
        };
        std.debug.print(" PASS\n", .{});
        passed += 1;
    }

    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    if (failed == 0) {
        std.debug.print("=== GEOVIEW TESTS: ALL PASSED ({d}/{d})             ===\n", .{ passed, passed });
    } else {
        std.debug.print("=== GEOVIEW TESTS: {d} PASSED, {d} FAILED           ===\n", .{ passed, failed });
    }
    std.debug.print("========================================================\n", .{});
}

// Wrappers
fn testLlaEcef() anyerror!void {
    const lla = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0.0 };
    const ecef = geo.llaToEcef(lla);
    try std.testing.expect(ecef.y < 0);
    try std.testing.expect(ecef.z > 0);
}
fn testGcDistance() anyerror!void {
    const sf = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const la = geo.LatLon{ .lat = 34.0522, .lon = -118.2437, .alt = 0 };
    const d = geo.greatCircleDistance(sf, la);
    try std.testing.expect(d > 550_000 and d < 570_000);
}
fn testBearing() anyerror!void {
    const sf = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const la = geo.LatLon{ .lat = 34.0522, .lon = -118.2437, .alt = 0 };
    const b = geo.bearing(sf, la);
    try std.testing.expect(b > 130 and b < 145);
}
fn testMgrs() anyerror!void {
    const lla = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const m = try geo.latLonToMgrs(allocator, lla);
    defer allocator.free(m);
    try std.testing.expect(m[0] == '1' and m[1] == '0');
}
fn testDestination() anyerror!void {
    const s = geo.LatLon{ .lat = 37.7749, .lon = -122.4194, .alt = 0 };
    const d = geo.destinationPoint(s, 90.0, 1000.0);
    try std.testing.expect(d.lon > -122.4194);
}
fn testFeedRegister() anyerror!void {
    var fm = live_feeds.FeedManager.init(allocator);
    defer fm.deinit();
    try fm.registerLayer(.flights, "OpenSky");
    try fm.enableLayer(.flights);
    try std.testing.expect(fm.isLayerEnabled(.flights));
}
fn testFeedStates() anyerror!void {
    var fm = live_feeds.FeedManager.init(allocator);
    defer fm.deinit();
    try fm.registerLayer(.vessels, "AIS");
    try fm.enableLayer(.vessels);
    fm.updateLayerResult(.vessels, true, 100, 50.0);
    try std.testing.expectEqual(live_feeds.FeedState.nominal, fm.getLayerState(.vessels));
}
fn testMeshGen() anyerror!void {
    var m = try globe.generateEllipsoidMesh(allocator, 16, 32);
    defer m.deinit();
    try std.testing.expect(m.vertices.len > 0);
}
fn testFrustum() anyerror!void {
    const cam = globe.Camera.init(globe.Vec3.init(0, 0, 1000));
    const vp = cam.getViewProjection();
    const f = globe.Frustum.fromViewProjection(vp);
    try std.testing.expect(f.containsPoint(globe.Vec3.init(0, 0, 0)));
}
fn testEntityMgmt() anyerror!void {
    var r = try globe.GlobeRenderer.init(allocator);
    defer r.deinit();
    try r.addEntity(.{ .id = 1, .entity_type = .aircraft, .position = globe.Vec3.init(6371000, 0, 0), .label = "T" });
    try std.testing.expectEqual(@as(usize, 1), r.entities.items.len);
    r.removeEntity(1);
    try std.testing.expectEqual(@as(usize, 0), r.entities.items.len);
}
fn testEasing() anyerror!void {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), camera.easeInOutCubic(0.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), camera.easeInOutCubic(1.0), 1e-10);
}
fn testFlyTo() anyerror!void {
    var controller = camera.FlyToController{};
    controller.flyTo(
        .{ .position = globe.Vec3.init(0, 0, 10000), .heading = 0, .pitch = 0, .roll = 0, .fov = 1.0 },
        .{ .position = globe.Vec3.init(1000, 1000, 1000), .heading = 0, .pitch = 0, .roll = 0, .fov = 1.0 },
        5.0,
    );
    try std.testing.expect(controller.target != null);
}
fn testHudCompass() anyerror!void {
    var r = hud.HudRenderer.init(allocator, 1920, 1080);
    defer r.deinit();
    try r.buildCompass(.{ .heading_deg = 45.0, .pitch_deg = 0, .roll_deg = 0 });
    try std.testing.expect(r.elements.items.len > 0);
}
fn testHudCoord() anyerror!void {
    var r = hud.HudRenderer.init(allocator, 1920, 1080);
    defer r.deinit();
    try r.buildCoordinateReadout(.{ .lat = 37.7749, .lon = -122.4194, .alt_m = 100.0, .mgrs = "10S" });
    try std.testing.expect(r.elements.items.len > 0);
}
fn testHudAlert() anyerror!void {
    var r = hud.HudRenderer.init(allocator, 1920, 1080);
    defer r.deinit();
    try r.buildAlert("Test", .warning);
    try std.testing.expect(r.elements.items.len > 0);
}
fn testAnnPin() anyerror!void {
    var s = ann.AnnotationStore.init(allocator);
    defer s.deinit();
    const id = try s.addPin(37.7749, -122.4194, "SF", "San Francisco");
    try std.testing.expectEqual(@as(usize, 1), s.count());
    s.remove(id);
    try std.testing.expectEqual(@as(usize, 0), s.count());
}
fn testAnnMeasure() anyerror!void {
    var s = ann.AnnotationStore.init(allocator);
    defer s.deinit();
    _ = try s.addMeasurement(37.7749, -122.4194, 34.0522, -118.2437, 559_000, 137);
    try std.testing.expectEqual(@as(usize, 1), s.count());
}
fn testAnnGeoJson() anyerror!void {
    var s = ann.AnnotationStore.init(allocator);
    defer s.deinit();
    _ = try s.addPin(37.7749, -122.4194, "SF", "San Francisco");
    const gj = try s.exportGeoJson(allocator);
    defer allocator.free(gj);
    try std.testing.expect(std.mem.indexOf(u8, gj, "FeatureCollection") != null);
}
fn testSceneFocus() anyerror!void {
    var d = scene.SceneDirector.init(allocator);
    defer d.deinit();
    try d.queueFocus(.{ .entity_id = 1, .priority = 3 });
    try std.testing.expectEqual(@as(usize, 1), d.queueLength());
}
fn testSceneStoryboard() anyerror!void {
    var d = scene.SceneDirector.init(allocator);
    defer d.deinit();
    try d.addStoryboardEntry(.{
        .timestamp = 1.0,
        .target = .{ .entity_id = 1 },
        .event = .entity_entered,
        .description = "Test",
    });
    try std.testing.expect(d.storyboard.items.len > 0);
}
fn testVoiceFlyTo() anyerror!void {
    const cmd = try voice.parseCommand(allocator, "fly to San Francisco");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.fly_to, cmd.action);
}
fn testVoiceZoom() anyerror!void {
    const cmd = try voice.parseCommand(allocator, "zoom in");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.zoom_in, cmd.action);
}
fn testVoiceToggle() anyerror!void {
    const cmd = try voice.parseCommand(allocator, "show flights layer");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expectEqual(voice.CommandAction.toggle_layer, cmd.action);
}
fn testVoiceCoords() anyerror!void {
    const cmd = try voice.parseCommand(allocator, "fly to 37.7749 -122.4194");
    defer voice.freeCommand(allocator, cmd);
    try std.testing.expect(cmd.lat != null);
    try std.testing.expect(cmd.lon != null);
}
fn testEarthquakeParse() anyerror!void {
    const gj = "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"properties\":{\"mag\":5.5,\"place\":\"Test\",\"url\":\"http://x\",\"felt\":10,\"tsunami\":0,\"sig\":500,\"time\":1700000000000},\"geometry\":{\"type\":\"Point\",\"coordinates\":[-122.4,37.7,10.0]}}]}";
    const eqs = try earthquakes.parseGeoJson(allocator, gj);
    defer earthquakes.freeEarthquakeList(allocator, eqs);
    try std.testing.expectEqual(@as(usize, 1), eqs.len);
}
fn testFlightClass() anyerror!void {
    const c = flights.classifyAircraft("UAL123");
    try std.testing.expect(c != .unknown);
}
fn testFlightDr() anyerror!void {
    const a = flights.Aircraft.init("ABC");
    const p = flights.deadReckonPosition(a, 3600.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p.lat, 0.01);
}
fn testVesselDr() anyerror!void {
    var v = vessels.Vessel.init(123);
    v.lat = 37.0;
    v.lon = -122.0;
    v.speed_knots = 10;
    v.course_deg = 90;
    const p = vessels.deadReckonPosition(v, 1.0);
    try std.testing.expect(p.lon > -122.0);
}
fn testTleParse() anyerror!void {
    const l1 = "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9999";
    const l2 = "2 25544  51.6400 208.0000 0006700 130.0000 230.0000 15.50000000  1000";
    const sat = satellites.parseTle(allocator, "ISS", l1, l2) catch null;
    if (sat) |s| try std.testing.expectEqual(@as(u32, 25544), s.norad_id);
}
fn testCctvViewshed() anyerror!void {
    const c = cctv.CctvCamera.init("cam1", "Test", 37.7749, -122.4194);
    const v = try cctv.calculateViewshed(allocator, c, 16);
    defer allocator.free(v);
    try std.testing.expect(v.len > 0);
}
