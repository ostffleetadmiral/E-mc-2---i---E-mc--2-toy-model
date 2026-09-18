const std = @import("std");

// =============================================================================
// HUD Renderer — Compass, scale bar, coordinate readout, status panels
// =============================================================================
// Generates HUD overlay elements for the God's Eye View display.
// Pure Zig, no external dependencies. Output is element lists for the
// rendering layer (Vulkan/WGSL) to draw.

pub const HudElementType = enum {
    compass,
    scale_bar,
    coordinate_readout,
    status_panel,
    alert_banner,
    crosshair,
    minimap,
    legend,
};

pub const HudAnchor = enum {
    top_left,
    top_center,
    top_right,
    center,
    bottom_left,
    bottom_center,
    bottom_right,
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn toHex(self: Color) u32 {
        const ri: u32 = @intFromFloat(@max(0, @min(255, self.r * 255)));
        const gi: u32 = @intFromFloat(@max(0, @min(255, self.g * 255)));
        const bi: u32 = @intFromFloat(@max(0, @min(255, self.b * 255)));
        const ai: u32 = @intFromFloat(@max(0, @min(255, self.a * 255)));
        return (ai << 24) | (ri << 16) | (gi << 8) | bi;
    }

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
            .a = @as(f32, @floatFromInt((hex >> 24) & 0xFF)) / 255.0,
        };
    }

    pub fn lerp(a: Color, b: Color, t: f32) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }

    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const yellow = Color{ .r = 1, .g = 1, .b = 0, .a = 1 };
    pub const cyan = Color{ .r = 0, .g = 1, .b = 1, .a = 1 };
    pub const amber = Color{ .r = 1, .g = 0.75, .b = 0, .a = 1 };
};

pub const HudElement = struct {
    element_type: HudElementType,
    anchor: HudAnchor,
    x_offset: f64, // pixels from anchor
    y_offset: f64,
    width: f64,
    height: f64,
    color: Color,
    text: []const u8 = "",
    owns_text: bool = false,
    visible: bool = true,
    z_order: u32 = 0,
};

pub const CompassData = struct {
    heading_deg: f64,
    pitch_deg: f64,
    roll_deg: f64,
};

pub const ScaleBarData = struct {
    meters_per_pixel: f64,
    screen_width_px: f64,
};

pub const CoordinateData = struct {
    lat: f64,
    lon: f64,
    alt_m: f64,
    mgrs: []const u8 = "",
};

pub const StatusData = struct {
    fps: f64,
    entity_count: usize,
    visible_count: usize,
    feed_status: []const u8 = "",
    camera_mode: []const u8 = "",
};

pub const HudRenderer = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayList(HudElement),
    screen_width: f64,
    screen_height: f64,

    pub fn init(allocator: std.mem.Allocator, screen_width: f64, screen_height: f64) HudRenderer {
        return .{
            .allocator = allocator,
            .elements = std.ArrayList(HudElement).init(allocator),
            .screen_width = screen_width,
            .screen_height = screen_height,
        };
    }

    pub fn deinit(self: *HudRenderer) void {
        for (self.elements.items) |el| {
            if (el.owns_text and el.text.len > 0) {
                self.allocator.free(el.text);
            }
        }
        self.elements.deinit();
    }

    pub fn addElement(self: *HudRenderer, element: HudElement) !void {
        try self.elements.append(element);
    }

    pub fn clear(self: *HudRenderer) void {
        for (self.elements.items) |el| {
            if (el.owns_text and el.text.len > 0) {
                self.allocator.free(el.text);
            }
        }
        self.elements.clearRetainingCapacity();
    }

    /// Build compass HUD element from heading data
    pub fn buildCompass(self: *HudRenderer, data: CompassData) !void {
        const heading_str = try std.fmt.allocPrint(self.allocator, "{d:.0}° {s}", .{
            data.heading_deg,
            cardinalDirection(data.heading_deg),
        });
        try self.addElement(.{
            .element_type = .compass,
            .anchor = .top_center,
            .x_offset = 0,
            .y_offset = 10,
            .width = 200,
            .height = 40,
            .color = Color.green,
            .text = heading_str,
            .owns_text = true,
            .z_order = 10,
        });
    }

    /// Build scale bar element
    pub fn buildScaleBar(self: *HudRenderer, data: ScaleBarData) !void {
        // Choose a nice round number for the scale bar
        const target_px = 150.0;
        const target_meters = target_px * data.meters_per_pixel;
        const nice_meters = niceNumber(target_meters);
        const bar_px = nice_meters / data.meters_per_pixel;

        const label = if (nice_meters >= 1000)
            try std.fmt.allocPrint(self.allocator, "{d:.1} km", .{nice_meters / 1000.0})
        else
            try std.fmt.allocPrint(self.allocator, "{d:.0} m", .{nice_meters});

        try self.addElement(.{
            .element_type = .scale_bar,
            .anchor = .bottom_left,
            .x_offset = 20,
            .y_offset = -30,
            .width = bar_px,
            .height = 20,
            .color = Color.white,
            .text = label,
            .owns_text = true,
            .z_order = 5,
        });
    }

    /// Build coordinate readout
    pub fn buildCoordinateReadout(self: *HudRenderer, data: CoordinateData) !void {
        const text = if (data.mgrs.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}\n{d:.6}°, {d:.6}°\nAlt: {d:.0}m", .{
                data.mgrs, data.lat, data.lon, data.alt_m,
            })
        else
            try std.fmt.allocPrint(self.allocator, "{d:.6}°, {d:.6}°\nAlt: {d:.0}m", .{
                data.lat, data.lon, data.alt_m,
            });

        try self.addElement(.{
            .element_type = .coordinate_readout,
            .anchor = .top_left,
            .x_offset = 10,
            .y_offset = 10,
            .width = 250,
            .height = 60,
            .color = Color.cyan,
            .text = text,
            .owns_text = true,
            .z_order = 8,
        });
    }

    /// Build status panel
    pub fn buildStatusPanel(self: *HudRenderer, data: StatusData) !void {
        const text = try std.fmt.allocPrint(self.allocator, "FPS: {d:.0}\nEntities: {d}\nVisible: {d}\nFeeds: {s}\nCamera: {s}", .{
            data.fps,
            data.entity_count,
            data.visible_count,
            data.feed_status,
            data.camera_mode,
        });

        try self.addElement(.{
            .element_type = .status_panel,
            .anchor = .top_right,
            .x_offset = -10,
            .y_offset = 10,
            .width = 200,
            .height = 100,
            .color = Color.amber,
            .text = text,
            .owns_text = true,
            .z_order = 8,
        });
    }

    /// Build alert banner
    pub fn buildAlert(self: *HudRenderer, message: []const u8, severity: AlertSeverity) !void {
        const color: Color = switch (severity) {
            .info => Color.cyan,
            .warning => Color.yellow,
            .critical => Color.red,
        };

        try self.addElement(.{
            .element_type = .alert_banner,
            .anchor = .bottom_center,
            .x_offset = 0,
            .y_offset = -60,
            .width = 400,
            .height = 30,
            .color = color,
            .text = message,
            .z_order = 20,
        });
    }

    /// Build crosshair at screen center
    pub fn buildCrosshair(self: *HudRenderer) !void {
        try self.addElement(.{
            .element_type = .crosshair,
            .anchor = .center,
            .x_offset = 0,
            .y_offset = 0,
            .width = 20,
            .height = 20,
            .color = Color.rgba(0, 1, 0, 0.5),
            .z_order = 15,
        });
    }

    /// Get all visible elements sorted by z_order
    pub fn getVisibleElements(self: *HudRenderer, allocator: std.mem.Allocator) ![]HudElement {
        var visible = std.ArrayList(HudElement).init(allocator);
        for (self.elements.items) |el| {
            if (el.visible) try visible.append(el);
        }
        // Sort by z_order
        std.mem.sort(HudElement, visible.items, {}, struct {
            fn lessThan(_: void, a: HudElement, b: HudElement) bool {
                return a.z_order < b.z_order;
            }
        }.lessThan);
        return visible.toOwnedSlice();
    }
};

pub const AlertSeverity = enum {
    info,
    warning,
    critical,
};

fn cardinalDirection(brng: f64) []const u8 {
    const directions = [_][]const u8{ "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
    const idx: usize = @as(usize, @intFromFloat(@floor(@mod(brng + 360.0, 360.0) / 45.0 + 0.5))) % 8;
    return directions[idx];
}

/// Find a "nice" round number close to the target (1, 2, 5, 10, 20, 50, ...)
fn niceNumber(target: f64) f64 {
    if (target <= 0) return 1;
    const exp = @floor(@log10(target));
    const fraction = target / std.math.pow(f64, 10.0, exp);
    var nice: f64 = undefined;
    if (fraction < 1.5) {
        nice = 1.0;
    } else if (fraction < 3.0) {
        nice = 2.0;
    } else if (fraction < 7.0) {
        nice = 5.0;
    } else {
        nice = 10.0;
    }
    return nice * std.math.pow(f64, 10.0, exp);
}

// =============================================================================
// Tests
// =============================================================================

test "hud: Color constants" {
    try std.testing.expectEqual(@as(f32, 1.0), Color.white.r);
    try std.testing.expectEqual(@as(f32, 0.0), Color.black.r);
    try std.testing.expectEqual(@as(f32, 0.0), Color.green.r);
    try std.testing.expectEqual(@as(f32, 1.0), Color.green.g);
}

test "hud: HudRenderer add and clear" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.addElement(.{
        .element_type = .compass,
        .anchor = .top_center,
        .x_offset = 0,
        .y_offset = 10,
        .width = 200,
        .height = 40,
        .color = Color.green,
    });

    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
    hud.clear();
    try std.testing.expectEqual(@as(usize, 0), hud.elements.items.len);
}

test "hud: buildCompass" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.buildCompass(.{ .heading_deg = 45.0, .pitch_deg = -10.0, .roll_deg = 0.0 });

    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
    const el = hud.elements.items[0];
    try std.testing.expectEqual(HudElementType.compass, el.element_type);
    try std.testing.expect(el.text.len > 0);
}

test "hud: buildScaleBar" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.buildScaleBar(.{ .meters_per_pixel = 100.0, .screen_width_px = 1920 });

    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
    const el = hud.elements.items[0];
    try std.testing.expectEqual(HudElementType.scale_bar, el.element_type);
}

test "hud: buildCoordinateReadout" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.buildCoordinateReadout(.{ .lat = 40.7128, .lon = -74.006, .alt_m = 100 });

    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
    const el = hud.elements.items[0];
    try std.testing.expectEqual(HudElementType.coordinate_readout, el.element_type);
}

test "hud: buildStatusPanel" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.buildStatusPanel(.{
        .fps = 60.0,
        .entity_count = 150,
        .visible_count = 42,
        .feed_status = "nominal",
        .camera_mode = "orbit",
    });

    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
    const el = hud.elements.items[0];
    try std.testing.expectEqual(HudElementType.status_panel, el.element_type);
}

test "hud: buildAlert" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.buildAlert("INTRUSION DETECTED", .critical);

    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
    const el = hud.elements.items[0];
    try std.testing.expectEqual(HudElementType.alert_banner, el.element_type);
    try std.testing.expectEqual(Color.red, el.color);
}

test "hud: buildCrosshair" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.buildCrosshair();
    try std.testing.expectEqual(@as(usize, 1), hud.elements.items.len);
}

test "hud: getVisibleElements sorted by z_order" {
    const allocator = std.testing.allocator;
    var hud = HudRenderer.init(allocator, 1920, 1080);
    defer hud.deinit();

    try hud.addElement(.{ .element_type = .crosshair, .anchor = .center, .x_offset = 0, .y_offset = 0, .width = 10, .height = 10, .color = Color.white, .z_order = 15 });
    try hud.addElement(.{ .element_type = .compass, .anchor = .top_center, .x_offset = 0, .y_offset = 0, .width = 100, .height = 30, .color = Color.green, .z_order = 5 });
    try hud.addElement(.{ .element_type = .legend, .anchor = .bottom_right, .x_offset = 0, .y_offset = 0, .width = 150, .height = 100, .color = Color.amber, .z_order = 10, .visible = false });

    const visible = try hud.getVisibleElements(allocator);
    defer allocator.free(visible);

    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expect(visible[0].z_order <= visible[1].z_order);
    try std.testing.expectEqual(@as(u32, 5), visible[0].z_order);
    try std.testing.expectEqual(@as(u32, 15), visible[1].z_order);
}

test "hud: niceNumber" {
    try std.testing.expectApproxEqAbs(@as(f64, 100), niceNumber(123), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 200), niceNumber(234), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 500), niceNumber(567), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), niceNumber(890), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), niceNumber(0.5), 1e-10);
}
