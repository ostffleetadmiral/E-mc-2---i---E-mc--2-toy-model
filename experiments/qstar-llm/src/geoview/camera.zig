const std = @import("std");
const math = std.math;
const geo = @import("geo_math");
const render = @import("globe_render");

// =============================================================================
// Camera Controllers — flyTo, orbit, tracked entity, cockpit, dead-reckoning
// =============================================================================
// All camera math uses f64. No external dependencies.
// Builds on globe_render.zig Vec3/Mat4/Camera types.

pub const Vec3 = render.Vec3;
pub const Camera = render.Camera;
pub const Mat4 = render.Mat4;

pub const CameraMode = enum {
    free,
    orbit,
    fly_to,
    tracked,
    cockpit,
};

pub const CameraState = struct {
    position: Vec3,
    heading: f64, // radians
    pitch: f64, // radians
    roll: f64, // radians
    fov: f64, // radians

    pub fn fromCamera(cam: Camera) CameraState {
        return .{
            .position = cam.position,
            .heading = cam.heading,
            .pitch = cam.pitch,
            .roll = cam.roll,
            .fov = cam.fov,
        };
    }

    pub fn applyToCamera(self: CameraState, cam: *Camera) void {
        cam.position = self.position;
        cam.heading = self.heading;
        cam.pitch = self.pitch;
        cam.roll = self.roll;
        cam.fov = self.fov;
    }
};

// =============================================================================
// Easing Functions
// =============================================================================

pub fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) {
        return 4.0 * t * t * t;
    }
    const f = 2.0 * t - 2.0;
    return 0.5 * f * f * f + 1.0;
}

pub fn easeOutQuart(t: f64) f64 {
    const f = 1.0 - t;
    return 1.0 - f * f * f * f;
}

pub fn easeInOutSine(t: f64) f64 {
    return 0.5 * (1.0 - @cos(math.pi * t));
}

pub fn clamp01(t: f64) f64 {
    return @max(0.0, @min(1.0, t));
}

// =============================================================================
// FlyTo Controller
// =============================================================================

pub const FlyToTarget = struct {
    start_pos: Vec3,
    end_pos: Vec3,
    start_heading: f64,
    end_heading: f64,
    start_pitch: f64,
    end_pitch: f64,
    duration: f64, // seconds
    elapsed: f64 = 0,
    easing: EasingFunc = easeInOutCubic,
};

pub const EasingFunc = *const fn (f64) f64;

pub const FlyToController = struct {
    target: ?FlyToTarget = null,

    pub fn flyTo(self: *FlyToController, current: CameraState, dest: CameraState, duration: f64) void {
        self.target = .{
            .start_pos = current.position,
            .end_pos = dest.position,
            .start_heading = current.heading,
            .end_heading = dest.heading,
            .start_pitch = current.pitch,
            .end_pitch = dest.pitch,
            .duration = duration,
            .elapsed = 0,
        };
    }

    pub fn isComplete(self: *const FlyToController) bool {
        if (self.target) |t| {
            return t.elapsed >= t.duration;
        }
        return true;
    }

    pub fn update(self: *FlyToController, dt: f64) ?CameraState {
        if (self.target) |*t| {
            t.elapsed += dt;
            const raw_t = clamp01(t.elapsed / t.duration);
            const eased_t = t.easing(raw_t);

            return .{
                .position = Vec3.lerp(t.start_pos, t.end_pos, eased_t),
                .heading = lerpAngle(t.start_heading, t.end_heading, eased_t),
                .pitch = t.start_pitch + (t.end_pitch - t.start_pitch) * eased_t,
                .roll = 0,
                .fov = 60.0 * math.pi / 180.0,
            };
        }
        return null;
    }

    pub fn cancel(self: *FlyToController) void {
        self.target = null;
    }
};

/// Interpolate angle taking shortest path (handles wraparound)
pub fn lerpAngle(a: f64, b: f64, t: f64) f64 {
    var diff = b - a;
    while (diff > math.pi) diff -= 2.0 * math.pi;
    while (diff < -math.pi) diff += 2.0 * math.pi;
    return a + diff * t;
}

// =============================================================================
// Orbit Controller
// =============================================================================

pub const OrbitController = struct {
    center: Vec3,
    radius: f64,
    azimuth: f64, // radians, horizontal angle
    elevation: f64, // radians, vertical angle
    angular_speed: f64, // radians per second

    pub fn init(center: Vec3, radius: f64) OrbitController {
        return .{
            .center = center,
            .radius = radius,
            .azimuth = 0,
            .elevation = -0.3,
            .angular_speed = 0.1, // ~5.7 deg/s
        };
    }

    pub fn update(self: *OrbitController, dt: f64) CameraState {
        self.azimuth += self.angular_speed * dt;

        const cos_el = @cos(self.elevation);
        const sin_el = @sin(self.elevation);
        const cos_az = @cos(self.azimuth);
        const sin_az = @sin(self.azimuth);

        const offset = Vec3.init(
            self.radius * cos_el * sin_az,
            self.radius * sin_el,
            self.radius * cos_el * cos_az,
        );

        const pos = Vec3.add(self.center, offset);
        const heading = self.azimuth + math.pi;
        const pitch = self.elevation;

        return .{
            .position = pos,
            .heading = heading,
            .pitch = pitch,
            .roll = 0,
            .fov = 60.0 * math.pi / 180.0,
        };
    }

    pub fn setRadius(self: *OrbitController, r: f64) void {
        self.radius = @max(1000.0, r);
    }

    pub fn setSpeed(self: *OrbitController, speed: f64) void {
        self.angular_speed = speed;
    }
};

// =============================================================================
// Tracked Entity Controller
// =============================================================================

pub const PositionCallback = *const fn () Vec3;

pub const TrackedController = struct {
    position_callback: PositionCallback,
    offset: Vec3, // offset from tracked entity
    heading_offset: f64 = 0,
    pitch_offset: f64 = -0.3,
    smoothing: f64 = 0.1, // [0,1], lower = smoother
    last_position: Vec3 = Vec3.init(0, 0, 0),
    initialized: bool = false,

    pub fn init(callback: PositionCallback, offset: Vec3) TrackedController {
        return .{
            .position_callback = callback,
            .offset = offset,
        };
    }

    pub fn update(self: *TrackedController, dt: f64) CameraState {
        _ = dt;
        const target_pos = self.position_callback();

        if (!self.initialized) {
            self.last_position = target_pos;
            self.initialized = true;
        }

        // Smooth follow
        self.last_position = Vec3.lerp(self.last_position, target_pos, self.smoothing);

        const cam_pos = Vec3.add(self.last_position, self.offset);

        // Heading toward target
        const to_target = Vec3.sub(target_pos, cam_pos);
        const heading = math.atan2(to_target.x, -to_target.z);

        return .{
            .position = cam_pos,
            .heading = heading + self.heading_offset,
            .pitch = self.pitch_offset,
            .roll = 0,
            .fov = 60.0 * math.pi / 180.0,
        };
    }
};

// =============================================================================
// Cockpit Controller
// =============================================================================

pub const CockpitController = struct {
    position: Vec3,
    heading: f64,
    pitch: f64,
    roll: f64,
    speed: f64 = 1000.0, // m/s

    pub fn init(position: Vec3, heading: f64) CockpitController {
        return .{
            .position = position,
            .heading = heading,
            .pitch = 0,
            .roll = 0,
        };
    }

    pub fn update(self: *CockpitController, dt: f64) CameraState {
        // Dead-reckoning: move forward along heading
        const ch = @cos(self.heading);
        const sh = @sin(self.heading);
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);

        const forward = Vec3.init(cp * sh, sp, -cp * ch);
        self.position = Vec3.add(self.position, forward.scale(self.speed * dt));

        return .{
            .position = self.position,
            .heading = self.heading,
            .pitch = self.pitch,
            .roll = self.roll,
            .fov = 70.0 * math.pi / 180.0, // wider FOV for cockpit
        };
    }

    pub fn setHeading(self: *CockpitController, heading: f64) void {
        self.heading = heading;
    }

    pub fn setSpeed(self: *CockpitController, speed: f64) void {
        self.speed = @max(0, speed);
    }

    pub fn bank(self: *CockpitController, roll: f64) void {
        self.roll = roll;
    }
};

// =============================================================================
// Dead-Reckoning Interpolation
// =============================================================================

pub const DeadReckoning = struct {
    last_position: Vec3,
    velocity: Vec3,
    last_time: f64,

    pub fn init(position: Vec3, time: f64) DeadReckoning {
        return .{
            .last_position = position,
            .velocity = Vec3.init(0, 0, 0),
            .last_time = time,
        };
    }

    pub fn update(self: *DeadReckoning, measured_pos: Vec3, current_time: f64) void {
        const dt = current_time - self.last_time;
        if (dt > 0) {
            self.velocity = Vec3.sub(measured_pos, self.last_position).scale(1.0 / dt);
        }
        self.last_position = measured_pos;
        self.last_time = current_time;
    }

    pub fn predict(self: *const DeadReckoning, future_time: f64) Vec3 {
        const dt = future_time - self.last_time;
        if (dt <= 0) return self.last_position;
        return Vec3.add(self.last_position, self.velocity.scale(dt));
    }
};

// =============================================================================
// Unified Camera Controller
// =============================================================================

pub const CameraController = struct {
    mode: CameraMode = .free,
    fly_to: FlyToController = .{},
    orbit: ?OrbitController = null,
    tracked: ?TrackedController = null,
    cockpit: ?CockpitController = null,
    current_state: CameraState,

    pub fn init(initial_camera: Camera) CameraController {
        return .{
            .current_state = CameraState.fromCamera(initial_camera),
        };
    }

    pub fn setMode(self: *CameraController, mode: CameraMode) void {
        self.mode = mode;
    }

    pub fn startFlyTo(self: *CameraController, dest: CameraState, duration: f64) void {
        self.mode = .fly_to;
        self.fly_to.flyTo(self.current_state, dest, duration);
    }

    pub fn startOrbit(self: *CameraController, center: Vec3, radius: f64) void {
        self.mode = .orbit;
        self.orbit = OrbitController.init(center, radius);
    }

    pub fn startTracking(self: *CameraController, callback: PositionCallback, offset: Vec3) void {
        self.mode = .tracked;
        self.tracked = TrackedController.init(callback, offset);
    }

    pub fn startCockpit(self: *CameraController, position: Vec3, heading: f64) void {
        self.mode = .cockpit;
        self.cockpit = CockpitController.init(position, heading);
    }

    pub fn update(self: *CameraController, dt: f64) CameraState {
        switch (self.mode) {
            .free => {},
            .fly_to => {
                if (self.fly_to.update(dt)) |state| {
                    self.current_state = state;
                }
                if (self.fly_to.isComplete()) {
                    self.mode = .free;
                }
            },
            .orbit => {
                if (self.orbit) |*o| {
                    self.current_state = o.update(dt);
                }
            },
            .tracked => {
                if (self.tracked) |*t| {
                    self.current_state = t.update(dt);
                }
            },
            .cockpit => {
                if (self.cockpit) |*c| {
                    self.current_state = c.update(dt);
                }
            },
        }
        return self.current_state;
    }

    pub fn applyToCamera(self: *CameraController, cam: *Camera) void {
        self.current_state.applyToCamera(cam);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "camera: easeInOutCubic" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), easeInOutCubic(0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1), easeInOutCubic(1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), easeInOutCubic(0.5), 0.01);
}

test "camera: easeOutQuart" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), easeOutQuart(0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1), easeOutQuart(1), 1e-10);
}

test "camera: easeInOutSine" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), easeInOutSine(0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1), easeInOutSine(1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), easeInOutSine(0.5), 1e-10);
}

test "camera: lerpAngle shortest path" {
    // 350° → 10° should go through 0°, not the long way around
    const a = 350.0 * math.pi / 180.0;
    const b = 10.0 * math.pi / 180.0;
    const mid = lerpAngle(a, b, 0.5);
    // Should be ~0° (or 360°)
    const mid_deg = @mod(mid * 180.0 / math.pi + 360.0, 360.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), mid_deg, 1.0);
}

test "camera: FlyToController interpolation" {
    var controller = FlyToController{};
    const start = CameraState{
        .position = Vec3.init(0, 0, 20_000_000),
        .heading = 0,
        .pitch = -0.5,
        .roll = 0,
        .fov = 60.0 * math.pi / 180.0,
    };
    const dest = CameraState{
        .position = Vec3.init(6378137, 0, 0),
        .heading = math.pi,
        .pitch = -1.0,
        .roll = 0,
        .fov = 60.0 * math.pi / 180.0,
    };

    controller.flyTo(start, dest, 10.0);
    try std.testing.expect(!controller.isComplete());

    // At t=5 (halfway), position should be roughly midpoint
    const state = controller.update(5.0);
    try std.testing.expect(state != null);
    if (state) |s| {
        const expected_z = (20_000_000 + 0) / 2.0;
        try std.testing.expectApproxEqAbs(expected_z, s.position.z, 2_000_000);
    }

    // Complete the flight
    _ = controller.update(5.0);
    try std.testing.expect(controller.isComplete());
}

test "camera: FlyToController cancel" {
    var controller = FlyToController{};
    controller.flyTo(
        .{ .position = Vec3.init(0, 0, 0), .heading = 0, .pitch = 0, .roll = 0, .fov = 1 },
        .{ .position = Vec3.init(100, 0, 0), .heading = 0, .pitch = 0, .roll = 0, .fov = 1 },
        5.0,
    );
    try std.testing.expect(!controller.isComplete());
    controller.cancel();
    try std.testing.expect(controller.isComplete());
}

test "camera: OrbitController circular path" {
    var orbit = OrbitController.init(Vec3.init(0, 0, 0), 10_000_000);
    orbit.angular_speed = math.pi / 2.0; // 90° per second

    const s0 = orbit.update(0.0);
    const s1 = orbit.update(1.0); // 90° later

    // After 90° rotation, x and z should swap (approximately)
    try std.testing.expectApproxEqAbs(s0.position.z, s1.position.x, 1.0);
    try std.testing.expectApproxEqAbs(s0.position.x, -s1.position.z, 1.0);
}

test "camera: OrbitController radius clamp" {
    var orbit = OrbitController.init(Vec3.init(0, 0, 0), 5_000_000);
    orbit.setRadius(500.0); // try to set very small
    try std.testing.expectEqual(@as(f64, 1000.0), orbit.radius);
}

test "camera: CockpitController dead-reckoning" {
    var cockpit = CockpitController.init(Vec3.init(0, 0, 10_000_000), 0);
    cockpit.speed = 1000.0; // 1 km/s

    const s0 = cockpit.update(0.0);
    const s1 = cockpit.update(1.0);

    // After 1 second at heading=0 (north), z should decrease
    try std.testing.expect(s1.position.z < s0.position.z);
    // Distance moved should be ~1000m
    const dist = Vec3.sub(s1.position, s0.position).length();
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), dist, 1.0);
}

test "camera: DeadReckoning predict" {
    var dr = DeadReckoning.init(Vec3.init(0, 0, 0), 0.0);
    dr.update(Vec3.init(100, 0, 0), 1.0); // velocity = 100 m/s in x

    const predicted = dr.predict(2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), predicted.x, 1.0);
}

test "camera: DeadReckoning no movement" {
    var dr = DeadReckoning.init(Vec3.init(1000, 2000, 3000), 10.0);
    dr.update(Vec3.init(1000, 2000, 3000), 11.0); // no movement

    const predicted = dr.predict(12.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), predicted.x, 1e-10);
}

test "camera: CameraController mode switching" {
    const cam = Camera.init(Vec3.init(0, 0, 20_000_000));
    var controller = CameraController.init(cam);

    try std.testing.expectEqual(CameraMode.free, controller.mode);

    controller.startOrbit(Vec3.init(0, 0, 0), 15_000_000);
    try std.testing.expectEqual(CameraMode.orbit, controller.mode);

    controller.startFlyTo(
        .{ .position = Vec3.init(0, 0, 5_000_000), .heading = 0, .pitch = 0, .roll = 0, .fov = 1 },
        5.0,
    );
    try std.testing.expectEqual(CameraMode.fly_to, controller.mode);
}

test "camera: CameraController update applies to camera" {
    const cam = Camera.init(Vec3.init(0, 0, 20_000_000));
    var controller = CameraController.init(cam);

    controller.startCockpit(Vec3.init(0, 0, 10_000_000), 0);

    var test_cam = cam;
    _ = controller.update(1.0);
    controller.applyToCamera(&test_cam);

    // Camera should have moved from cockpit dead-reckoning
    try std.testing.expect(test_cam.position.z < 10_000_000);
}

test "camera: TrackedController follows target" {
    // Test the smoothing logic directly with a simple position callback
    var tracked = TrackedController.init(
        @ptrCast(&struct {
            fn f() Vec3 {
                return Vec3.init(1000, 0, 0);
            }
        }.f),
        Vec3.init(0, 100, 0),
    );
    tracked.smoothing = 1.0; // instant follow

    const state = tracked.update(0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), state.position.x, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), state.position.y, 1.0);
}
