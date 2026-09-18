const std = @import("std");

// =============================================================================
// Voice Command Integration — Natural language to geoview command parsing
// =============================================================================
// Parses voice/text commands into geoview actions (camera moves, layer toggles,
// annotations, measurements). Pure Zig, no external dependencies.

pub const CommandAction = enum {
    fly_to,
    zoom_in,
    zoom_out,
    toggle_layer,
    focus_entity,
    measure_distance,
    add_pin,
    set_camera_mode,
    clear_annotations,
    unknown,
};

pub const ParsedCommand = struct {
    action: CommandAction,
    lat: ?f64 = null,
    lon: ?f64 = null,
    layer_name: []const u8 = "",
    entity_id: ?u32 = null,
    label: []const u8 = "",
    camera_mode: []const u8 = "",
    raw_text: []const u8 = "",
};

/// Parse a natural language command into a structured ParsedCommand
pub fn parseCommand(allocator: std.mem.Allocator, text: []const u8) !ParsedCommand {
    const lower = try std.ascii.allocLowerString(allocator, text);
    defer allocator.free(lower);

    var cmd = ParsedCommand{
        .action = .unknown,
        .raw_text = try allocator.dupe(u8, text),
    };

    // Fly to / go to / navigate to
    if (std.mem.indexOf(u8, lower, "fly to") != null or
        std.mem.indexOf(u8, lower, "go to") != null or
        std.mem.indexOf(u8, lower, "navigate to") != null)
    {
        cmd.action = .fly_to;
        // Try to extract coordinates
        if (extractCoordinates(lower)) |coords| {
            cmd.lat = coords.lat;
            cmd.lon = coords.lon;
        }
        // Try to extract place name
        if (extractAfterKeyword(text, "to")) |place| {
            cmd.label = try allocator.dupe(u8, place);
        }
        return cmd;
    }

    // Zoom
    if (std.mem.indexOf(u8, lower, "zoom in") != null) {
        cmd.action = .zoom_in;
        return cmd;
    }
    if (std.mem.indexOf(u8, lower, "zoom out") != null) {
        cmd.action = .zoom_out;
        return cmd;
    }

    // Toggle layer
    if (std.mem.indexOf(u8, lower, "show") != null or
        std.mem.indexOf(u8, lower, "hide") != null or
        std.mem.indexOf(u8, lower, "toggle") != null)
    {
        const layer = extractLayerName(lower);
        if (layer.len > 0) {
            cmd.action = .toggle_layer;
            cmd.layer_name = try allocator.dupe(u8, layer);
            return cmd;
        }
    }

    // Focus entity
    if (std.mem.indexOf(u8, lower, "focus on") != null or
        std.mem.indexOf(u8, lower, "track") != null)
    {
        cmd.action = .focus_entity;
        // Try to extract entity ID
        if (extractNumber(lower)) |id| {
            cmd.entity_id = id;
        }
        return cmd;
    }

    // Measure distance
    if (std.mem.indexOf(u8, lower, "measure") != null or
        std.mem.indexOf(u8, lower, "distance") != null)
    {
        cmd.action = .measure_distance;
        if (extractCoordinates(lower)) |coords| {
            cmd.lat = coords.lat;
            cmd.lon = coords.lon;
        }
        return cmd;
    }

    // Add pin / marker
    if (std.mem.indexOf(u8, lower, "add pin") != null or
        std.mem.indexOf(u8, lower, "add marker") != null or
        std.mem.indexOf(u8, lower, "mark") != null)
    {
        cmd.action = .add_pin;
        if (extractCoordinates(lower)) |coords| {
            cmd.lat = coords.lat;
            cmd.lon = coords.lon;
        }
        if (extractAfterKeyword(text, "pin")) |label| {
            cmd.label = try allocator.dupe(u8, label);
        } else if (extractAfterKeyword(text, "marker")) |label| {
            cmd.label = try allocator.dupe(u8, label);
        }
        return cmd;
    }

    // Camera mode
    if (std.mem.indexOf(u8, lower, "camera mode") != null or
        std.mem.indexOf(u8, lower, "orbit mode") != null or
        std.mem.indexOf(u8, lower, "cockpit") != null)
    {
        cmd.action = .set_camera_mode;
        if (std.mem.indexOf(u8, lower, "orbit") != null) {
            cmd.camera_mode = try allocator.dupe(u8, "orbit");
        } else if (std.mem.indexOf(u8, lower, "cockpit") != null) {
            cmd.camera_mode = try allocator.dupe(u8, "cockpit");
        } else if (std.mem.indexOf(u8, lower, "fly") != null) {
            cmd.camera_mode = try allocator.dupe(u8, "fly");
        } else if (std.mem.indexOf(u8, lower, "track") != null) {
            cmd.camera_mode = try allocator.dupe(u8, "track");
        }
        return cmd;
    }

    // Clear annotations
    if (std.mem.indexOf(u8, lower, "clear") != null and
        (std.mem.indexOf(u8, lower, "annotation") != null or
            std.mem.indexOf(u8, lower, "marker") != null or
            std.mem.indexOf(u8, lower, "pin") != null))
    {
        cmd.action = .clear_annotations;
        return cmd;
    }

    return cmd;
}

/// Free command allocated strings
pub fn freeCommand(allocator: std.mem.Allocator, cmd: ParsedCommand) void {
    allocator.free(cmd.raw_text);
    if (cmd.label.len > 0) allocator.free(cmd.label);
    if (cmd.layer_name.len > 0) allocator.free(cmd.layer_name);
    if (cmd.camera_mode.len > 0) allocator.free(cmd.camera_mode);
}

fn extractCoordinates(text: []const u8) ?struct { lat: f64, lon: f64 } {
    // Look for patterns like "40.7 -74.0" or "lat 40.7 lon -74.0"
    if (std.mem.indexOf(u8, text, "lat")) |p| {
        const rest = text[p..];
        const lat = parseFloatAfter(rest) orelse return null;
        if (std.mem.indexOf(u8, text, "lon")) |lp| {
            const lon_rest = text[lp..];
            const lon = parseFloatAfter(lon_rest) orelse return null;
            return .{ .lat = lat, .lon = lon };
        }
    }

    // Try to find two consecutive numbers
    var num_count: u32 = 0;
    var lat: f64 = 0;
    var it = std.mem.tokenizeAny(u8, text, " ,;:");
    while (it.next()) |tok| {
        const f = std.fmt.parseFloat(f64, tok) catch continue;
        if (num_count == 0) {
            lat = f;
            num_count += 1;
        } else if (num_count == 1) {
            return .{ .lat = lat, .lon = f };
        }
    }
    return null;
}

fn parseFloatAfter(text: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, text, " ,;:");
    while (it.next()) |tok| {
        return std.fmt.parseFloat(f64, tok) catch continue;
    }
    return null;
}

fn extractLayerName(text: []const u8) []const u8 {
    const layers = [_][]const u8{ "flights", "vessels", "satellites", "earthquakes", "traffic", "cctv" };
    for (layers) |layer| {
        if (std.mem.indexOf(u8, text, layer) != null) return layer;
    }
    return "";
}

fn extractAfterKeyword(text: []const u8, keyword: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, keyword)) |p| {
        const rest = std.mem.trim(u8, text[p + keyword.len ..], " ,.;");
        if (rest.len > 0) return rest;
    }
    return null;
}

fn extractNumber(text: []const u8) ?u32 {
    var it = std.mem.tokenizeAny(u8, text, " ,;:");
    while (it.next()) |tok| {
        return std.fmt.parseInt(u32, tok, 10) catch continue;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "voice_command: parse fly_to with coordinates" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Fly to 40.7 -74.0");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.fly_to, cmd.action);
    try std.testing.expect(cmd.lat != null);
    try std.testing.expectApproxEqAbs(@as(f64, 40.7), cmd.lat.?, 1e-10);
}

test "voice_command: parse zoom in" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Zoom in");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.zoom_in, cmd.action);
}

test "voice_command: parse zoom out" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Zoom out");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.zoom_out, cmd.action);
}

test "voice_command: parse toggle layer" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Show flights layer");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.toggle_layer, cmd.action);
    try std.testing.expectEqualStrings("flights", cmd.layer_name);
}

test "voice_command: parse focus entity" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Focus on entity 42");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.focus_entity, cmd.action);
    try std.testing.expectEqual(@as(u32, 42), cmd.entity_id.?);
}

test "voice_command: parse measure distance" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Measure distance to 40.0 -74.0");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.measure_distance, cmd.action);
}

test "voice_command: parse add pin" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Add pin at 40.7 -74.0 New York");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.add_pin, cmd.action);
    try std.testing.expect(cmd.lat != null);
}

test "voice_command: parse camera mode orbit" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Set camera mode to orbit");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.set_camera_mode, cmd.action);
    try std.testing.expectEqualStrings("orbit", cmd.camera_mode);
}

test "voice_command: parse camera mode cockpit" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Switch to cockpit view");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.set_camera_mode, cmd.action);
    try std.testing.expectEqualStrings("cockpit", cmd.camera_mode);
}

test "voice_command: parse clear annotations" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "Clear all annotations");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.clear_annotations, cmd.action);
}

test "voice_command: unknown command" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "What is the weather today?");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.unknown, cmd.action);
}

test "voice_command: case insensitive" {
    const allocator = std.testing.allocator;
    const cmd = try parseCommand(allocator, "FLY TO 40.7 -74.0");
    defer freeCommand(allocator, cmd);

    try std.testing.expectEqual(CommandAction.fly_to, cmd.action);
}
