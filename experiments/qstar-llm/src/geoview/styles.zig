const std = @import("std");
const hud = @import("hud");

// =============================================================================
// Visual Styles — Color palettes, entity styles, theme management
// =============================================================================
// Centralized style definitions for all geoview visual elements.
// Pure Zig, no external dependencies.

pub const Color = hud.Color;

pub const Theme = enum {
    tactical_green,
    tactical_amber,
    dark_blue,
    high_contrast,
    night_vision,
};

pub const EntityStyle = struct {
    primary_color: Color,
    secondary_color: Color,
    icon_size: f32,
    label_color: Color,
    label_bg: Color,
    glow: bool = false,
    pulse: bool = false,
    line_width: f32 = 1.5,
};

pub const StylePalette = struct {
    theme: Theme,
    background: Color,
    grid_lines: Color,
    text_primary: Color,
    text_secondary: Color,
    accent: Color,
    alert: Color,
    warning: Color,
    success: Color,
    entity_styles: std.AutoHashMap(u8, EntityStyle),

    pub fn init(allocator: std.mem.Allocator, theme: Theme) StylePalette {
        return .{
            .theme = theme,
            .background = switch (theme) {
                .tactical_green => Color.rgb(0.05, 0.1, 0.05),
                .tactical_amber => Color.rgb(0.05, 0.03, 0.0),
                .dark_blue => Color.rgb(0.02, 0.03, 0.08),
                .high_contrast => Color.rgb(0.0, 0.0, 0.0),
                .night_vision => Color.rgb(0.0, 0.02, 0.0),
            },
            .grid_lines = switch (theme) {
                .tactical_green => Color.rgba(0, 0.5, 0, 0.3),
                .tactical_amber => Color.rgba(0.5, 0.3, 0, 0.3),
                .dark_blue => Color.rgba(0.2, 0.3, 0.5, 0.3),
                .high_contrast => Color.rgba(0.3, 0.3, 0.3, 0.5),
                .night_vision => Color.rgba(0, 0.3, 0, 0.2),
            },
            .text_primary = switch (theme) {
                .tactical_green => Color.rgb(0, 1, 0),
                .tactical_amber => Color.rgb(1, 0.75, 0),
                .dark_blue => Color.rgb(0.7, 0.8, 1),
                .high_contrast => Color.rgb(1, 1, 1),
                .night_vision => Color.rgb(0, 0.8, 0),
            },
            .text_secondary = switch (theme) {
                .tactical_green => Color.rgb(0, 0.6, 0),
                .tactical_amber => Color.rgb(0.8, 0.6, 0),
                .dark_blue => Color.rgb(0.5, 0.6, 0.8),
                .high_contrast => Color.rgb(0.7, 0.7, 0.7),
                .night_vision => Color.rgb(0, 0.5, 0),
            },
            .accent = switch (theme) {
                .tactical_green => Color.rgb(0, 1, 0.5),
                .tactical_amber => Color.rgb(1, 0.5, 0),
                .dark_blue => Color.rgb(0.3, 0.6, 1),
                .high_contrast => Color.rgb(1, 1, 0),
                .night_vision => Color.rgb(0.5, 1, 0.5),
            },
            .alert = Color.rgb(1, 0, 0),
            .warning = Color.rgb(1, 1, 0),
            .success = Color.rgb(0, 1, 0),
            .entity_styles = std.AutoHashMap(u8, EntityStyle).init(allocator),
        };
    }

    pub fn deinit(self: *StylePalette) void {
        self.entity_styles.deinit();
    }

    pub fn getEntityStyle(self: *StylePalette, entity_type: u8) EntityStyle {
        return self.entity_styles.get(entity_type) orelse defaultEntityStyle(entity_type);
    }

    pub fn setEntityStyle(self: *StylePalette, entity_type: u8, style: EntityStyle) !void {
        try self.entity_styles.put(entity_type, style);
    }
};

// Entity type codes (match globe_render EntityType)
pub const ENTITY_AIRCRAFT: u8 = 0;
pub const ENTITY_VESSEL: u8 = 1;
pub const ENTITY_SATELLITE: u8 = 2;
pub const ENTITY_GROUND_STATION: u8 = 3;
pub const ENTITY_CAMERA: u8 = 4;
pub const ENTITY_DETECTION: u8 = 5;
pub const ENTITY_ANNOTATION: u8 = 6;

pub fn defaultEntityStyle(entity_type: u8) EntityStyle {
    return switch (entity_type) {
        ENTITY_AIRCRAFT => .{
            .primary_color = Color.rgb(1, 1, 0),
            .secondary_color = Color.rgb(0.5, 0.5, 0),
            .icon_size = 16,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
            .glow = false,
        },
        ENTITY_VESSEL => .{
            .primary_color = Color.rgb(0, 0.5, 1),
            .secondary_color = Color.rgb(0, 0.25, 0.5),
            .icon_size = 14,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
        },
        ENTITY_SATELLITE => .{
            .primary_color = Color.rgb(0.5, 1, 1),
            .secondary_color = Color.rgb(0.25, 0.5, 0.5),
            .icon_size = 12,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
            .glow = true,
        },
        ENTITY_GROUND_STATION => .{
            .primary_color = Color.rgb(0, 1, 0),
            .secondary_color = Color.rgb(0, 0.5, 0),
            .icon_size = 10,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
        },
        ENTITY_CAMERA => .{
            .primary_color = Color.rgb(1, 0.5, 0),
            .secondary_color = Color.rgb(0.5, 0.25, 0),
            .icon_size = 10,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
        },
        ENTITY_DETECTION => .{
            .primary_color = Color.rgb(1, 0, 0),
            .secondary_color = Color.rgb(0.5, 0, 0),
            .icon_size = 14,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
            .pulse = true,
        },
        ENTITY_ANNOTATION => .{
            .primary_color = Color.rgb(1, 1, 1),
            .secondary_color = Color.rgb(0.5, 0.5, 0.5),
            .icon_size = 8,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
        },
        else => .{
            .primary_color = Color.rgb(0.5, 0.5, 0.5),
            .secondary_color = Color.rgb(0.25, 0.25, 0.25),
            .icon_size = 10,
            .label_color = Color.white,
            .label_bg = Color.rgba(0, 0, 0, 0.7),
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

test "styles: Color toHex and fromHex round-trip" {
    const c = Color.rgb(0.5, 0.25, 0.75);
    const hex = c.toHex();
    const back = Color.fromHex(hex);
    try std.testing.expectApproxEqAbs(c.r, back.r, 0.01);
    try std.testing.expectApproxEqAbs(c.g, back.g, 0.01);
    try std.testing.expectApproxEqAbs(c.b, back.b, 0.01);
}

test "styles: Color lerp" {
    const a = Color.rgb(0, 0, 0);
    const b = Color.rgb(1, 1, 1);
    const mid = Color.lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.g, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.b, 1e-6);
}

test "styles: StylePalette tactical_green theme" {
    const allocator = std.testing.allocator;
    var palette = StylePalette.init(allocator, .tactical_green);
    defer palette.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 0), palette.text_primary.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), palette.text_primary.g, 1e-6);
}

test "styles: StylePalette dark_blue theme" {
    const allocator = std.testing.allocator;
    var palette = StylePalette.init(allocator, .dark_blue);
    defer palette.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 0.02), palette.background.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.03), palette.background.g, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), palette.background.b, 1e-6);
}

test "styles: defaultEntityStyle for aircraft" {
    const style = defaultEntityStyle(ENTITY_AIRCRAFT);
    try std.testing.expectApproxEqAbs(@as(f32, 1), style.primary_color.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), style.primary_color.g, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), style.primary_color.b, 1e-6);
}

test "styles: defaultEntityStyle for satellite has glow" {
    const style = defaultEntityStyle(ENTITY_SATELLITE);
    try std.testing.expect(style.glow);
}

test "styles: defaultEntityStyle for detection has pulse" {
    const style = defaultEntityStyle(ENTITY_DETECTION);
    try std.testing.expect(style.pulse);
}

test "styles: StylePalette set and get entity style" {
    const allocator = std.testing.allocator;
    var palette = StylePalette.init(allocator, .tactical_green);
    defer palette.deinit();

    const custom = EntityStyle{
        .primary_color = Color.rgb(1, 0, 1),
        .secondary_color = Color.rgb(0.5, 0, 0.5),
        .icon_size = 20,
        .label_color = Color.rgb(1, 1, 1),
        .label_bg = Color.rgb(0, 0, 0),
        .glow = true,
    };

    try palette.setEntityStyle(ENTITY_AIRCRAFT, custom);
    const retrieved = palette.getEntityStyle(ENTITY_AIRCRAFT);
    try std.testing.expectApproxEqAbs(@as(f32, 1), retrieved.primary_color.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), retrieved.primary_color.g, 1e-6);
    try std.testing.expect(retrieved.glow);
}

test "styles: defaultEntityStyle for unknown type" {
    const style = defaultEntityStyle(99);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), style.primary_color.r, 1e-6);
}
