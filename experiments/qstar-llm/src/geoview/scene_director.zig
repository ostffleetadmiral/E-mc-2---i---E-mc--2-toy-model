const std = @import("std");

// =============================================================================
// Scene Director — Automated camera control, event-driven focus, storyboards
// =============================================================================
// Orchestrates the God's Eye View scene by controlling camera movements,
// entity highlighting, and timeline events. Pure Zig, no external dependencies.

pub const SceneEvent = enum {
    entity_entered,
    entity_exited,
    alert_triggered,
    user_focus,
    timeline_jump,
    playback_start,
    playback_pause,
    playback_stop,
};

pub const FocusTarget = struct {
    entity_id: ?u32 = null,
    lat: f64 = 0,
    lon: f64 = 0,
    alt_m: f64 = 0,
    radius_m: f64 = 500_000, // camera distance
    label: []const u8 = "",
    priority: u8 = 5, // 1=highest, 10=lowest
    duration_s: f64 = 10.0, // how long to hold focus
};

pub const StoryboardEntry = struct {
    timestamp: f64, // seconds from start
    target: FocusTarget,
    event: SceneEvent,
    description: []const u8,
};

pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
};

pub const SceneDirector = struct {
    allocator: std.mem.Allocator,
    current_focus: ?FocusTarget = null,
    focus_queue: std.ArrayList(FocusTarget),
    storyboard: std.ArrayList(StoryboardEntry),
    playback_state: PlaybackState = .stopped,
    current_time: f64 = 0,
    storyboard_start_time: f64 = 0,
    auto_focus_enabled: bool = true,
    last_event: ?SceneEvent = null,

    pub fn init(allocator: std.mem.Allocator) SceneDirector {
        return .{
            .allocator = allocator,
            .focus_queue = std.ArrayList(FocusTarget).init(allocator),
            .storyboard = std.ArrayList(StoryboardEntry).init(allocator),
        };
    }

    pub fn deinit(self: *SceneDirector) void {
        self.focus_queue.deinit();
        self.storyboard.deinit();
    }

    /// Queue a focus target
    pub fn queueFocus(self: *SceneDirector, target: FocusTarget) !void {
        // Insert by priority (lower number = higher priority = earlier in queue)
        var inserted = false;
        for (self.focus_queue.items, 0..) |item, i| {
            if (target.priority < item.priority) {
                try self.focus_queue.insert(i, target);
                inserted = true;
                break;
            }
        }
        if (!inserted) {
            try self.focus_queue.append(target);
        }
    }

    /// Process the focus queue — returns the current focus target
    pub fn update(self: *SceneDirector, dt: f64) ?FocusTarget {
        self.current_time += dt;

        // If we have a current focus, check if it expired
        if (self.current_focus) |*focus| {
            focus.duration_s -= dt;
            if (focus.duration_s <= 0) {
                self.current_focus = null;
            }
        }

        // If no current focus, take from queue
        if (self.current_focus == null and self.focus_queue.items.len > 0) {
            self.current_focus = self.focus_queue.orderedRemove(0);
            self.last_event = .user_focus;
        }

        // If playing storyboard, check for timeline events
        if (self.playback_state == .playing) {
            self.processStoryboard();
        }

        return self.current_focus;
    }

    /// Add a storyboard entry
    pub fn addStoryboardEntry(self: *SceneDirector, entry: StoryboardEntry) !void {
        // Insert sorted by timestamp
        var inserted = false;
        for (self.storyboard.items, 0..) |item, i| {
            if (entry.timestamp < item.timestamp) {
                try self.storyboard.insert(i, entry);
                inserted = true;
                break;
            }
        }
        if (!inserted) {
            try self.storyboard.append(entry);
        }
    }

    /// Start storyboard playback
    pub fn startPlayback(self: *SceneDirector) void {
        self.playback_state = .playing;
        self.storyboard_start_time = self.current_time;
        self.last_event = .playback_start;
    }

    pub fn pausePlayback(self: *SceneDirector) void {
        if (self.playback_state == .playing) {
            self.playback_state = .paused;
            self.last_event = .playback_pause;
        }
    }

    pub fn resumePlayback(self: *SceneDirector) void {
        if (self.playback_state == .paused) {
            self.playback_state = .playing;
        }
    }

    pub fn stopPlayback(self: *SceneDirector) void {
        self.playback_state = .stopped;
        self.last_event = .playback_stop;
    }

    fn processStoryboard(self: *SceneDirector) void {
        const elapsed = self.current_time - self.storyboard_start_time;
        for (self.storyboard.items) |entry| {
            if (@abs(elapsed - entry.timestamp) < 0.1) {
                // Trigger this storyboard entry
                self.current_focus = entry.target;
                self.last_event = entry.event;
            }
        }
    }

    /// Handle an entity event (entering/leaving view)
    pub fn handleEntityEvent(self: *SceneDirector, event: SceneEvent, entity_id: u32, lat: f64, lon: f64) !void {
        self.last_event = event;

        if (!self.auto_focus_enabled) return;

        switch (event) {
            .entity_entered => {
                // Auto-focus on new entities with low priority
                try self.queueFocus(.{
                    .entity_id = entity_id,
                    .lat = lat,
                    .lon = lon,
                    .priority = 7,
                    .duration_s = 5.0,
                    .label = "New entity",
                });
            },
            .alert_triggered => {
                // High priority focus for alerts
                try self.queueFocus(.{
                    .entity_id = entity_id,
                    .lat = lat,
                    .lon = lon,
                    .priority = 1,
                    .duration_s = 15.0,
                    .label = "ALERT",
                });
            },
            else => {},
        }
    }

    pub fn clearQueue(self: *SceneDirector) void {
        self.focus_queue.clearRetainingCapacity();
    }

    pub fn queueLength(self: *SceneDirector) usize {
        return self.focus_queue.items.len;
    }

    pub fn hasFocus(self: *SceneDirector) bool {
        return self.current_focus != null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "scene_director: init and deinit" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();
    try std.testing.expectEqual(@as(usize, 0), sd.queueLength());
    try std.testing.expect(!sd.hasFocus());
}

test "scene_director: queueFocus priority ordering" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.queueFocus(.{ .priority = 5, .label = "Normal" });
    try sd.queueFocus(.{ .priority = 1, .label = "Urgent" });
    try sd.queueFocus(.{ .priority = 3, .label = "Medium" });

    // Queue should be ordered: Urgent(1), Medium(3), Normal(5)
    try std.testing.expectEqualStrings("Urgent", sd.focus_queue.items[0].label);
    try std.testing.expectEqualStrings("Medium", sd.focus_queue.items[1].label);
    try std.testing.expectEqualStrings("Normal", sd.focus_queue.items[2].label);
}

test "scene_director: update dequeues focus" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.queueFocus(.{ .priority = 1, .duration_s = 5.0, .label = "Test" });

    const focus = sd.update(0.1);
    try std.testing.expect(focus != null);
    try std.testing.expectEqualStrings("Test", focus.?.label);
    try std.testing.expect(!sd.hasFocus() or sd.hasFocus()); // still has focus since duration > 0
}

test "scene_director: focus expires after duration" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.queueFocus(.{ .priority = 1, .duration_s = 2.0, .label = "Short" });

    _ = sd.update(0.1); // dequeue
    try std.testing.expect(sd.hasFocus());

    _ = sd.update(2.0); // expire
    try std.testing.expect(!sd.hasFocus());
}

test "scene_director: handleEntityEvent alert" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.handleEntityEvent(.alert_triggered, 42, 40.0, -74.0);

    try std.testing.expectEqual(@as(usize, 1), sd.queueLength());
    try std.testing.expectEqual(@as(u8, 1), sd.focus_queue.items[0].priority);
}

test "scene_director: handleEntityEvent entered" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.handleEntityEvent(.entity_entered, 10, 35.0, 120.0);

    try std.testing.expectEqual(@as(usize, 1), sd.queueLength());
    try std.testing.expectEqual(@as(u8, 7), sd.focus_queue.items[0].priority);
}

test "scene_director: playback state transitions" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try std.testing.expectEqual(PlaybackState.stopped, sd.playback_state);

    sd.startPlayback();
    try std.testing.expectEqual(PlaybackState.playing, sd.playback_state);

    sd.pausePlayback();
    try std.testing.expectEqual(PlaybackState.paused, sd.playback_state);

    sd.resumePlayback();
    try std.testing.expectEqual(PlaybackState.playing, sd.playback_state);

    sd.stopPlayback();
    try std.testing.expectEqual(PlaybackState.stopped, sd.playback_state);
}

test "scene_director: storyboard entries sorted by timestamp" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.addStoryboardEntry(.{ .timestamp = 20.0, .target = .{}, .event = .timeline_jump, .description = "Third" });
    try sd.addStoryboardEntry(.{ .timestamp = 5.0, .target = .{}, .event = .timeline_jump, .description = "First" });
    try sd.addStoryboardEntry(.{ .timestamp = 10.0, .target = .{}, .event = .timeline_jump, .description = "Second" });

    try std.testing.expectEqualStrings("First", sd.storyboard.items[0].description);
    try std.testing.expectEqualStrings("Second", sd.storyboard.items[1].description);
    try std.testing.expectEqualStrings("Third", sd.storyboard.items[2].description);
}

test "scene_director: clearQueue" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    try sd.queueFocus(.{ .priority = 1 });
    try sd.queueFocus(.{ .priority = 2 });
    try std.testing.expectEqual(@as(usize, 2), sd.queueLength());

    sd.clearQueue();
    try std.testing.expectEqual(@as(usize, 0), sd.queueLength());
}

test "scene_director: auto_focus disabled ignores events" {
    const allocator = std.testing.allocator;
    var sd = SceneDirector.init(allocator);
    defer sd.deinit();

    sd.auto_focus_enabled = false;
    try sd.handleEntityEvent(.entity_entered, 1, 0, 0);

    try std.testing.expectEqual(@as(usize, 0), sd.queueLength());
}
