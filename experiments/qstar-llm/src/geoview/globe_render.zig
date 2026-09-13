const std = @import("std");
const math = std.math;

// =============================================================================
// 3D Globe Renderer — WGS84 ellipsoid mesh, billboard entities, frustum culling
// =============================================================================
// Pure Zig math for mesh generation, camera, and projection.
// Vulkan/WGSL integration deferred to Phase 9 — this module provides the
// geometry and scene-graph data structures.

pub const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn init(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f64) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f64 {
        return @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    }

    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        if (len == 0) return .{ .x = 0, .y = 0, .z = 0 };
        return a.scale(1.0 / len);
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f64) Vec3 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
        };
    }
};

pub const Vec4 = struct {
    x: f64,
    y: f64,
    z: f64,
    w: f64,

    pub fn init(x: f64, y: f64, z: f64, w: f64) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
};

pub const Mat4 = struct {
    m: [16]f64, // column-major

    pub fn identity() Mat4 {
        return .{ .m = [_]f64{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f64 = 0;
                for (0..4) |k| {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                result.m[col * 4 + row] = sum;
            }
        }
        return result;
    }

    pub fn multiplyVec(m: Mat4, v: Vec4) Vec4 {
        return .{
            .x = m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z + m.m[12] * v.w,
            .y = m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z + m.m[13] * v.w,
            .z = m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z + m.m[14] * v.w,
            .w = m.m[3] * v.x + m.m[7] * v.y + m.m[11] * v.z + m.m[15] * v.w,
        };
    }

    pub fn translation(x: f64, y: f64, z: f64) Mat4 {
        return .{ .m = [_]f64{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        } };
    }

    pub fn scaling(sx: f64, sy: f64, sz: f64) Mat4 {
        return .{ .m = [_]f64{
            sx, 0,  0,  0,
            0,  sy, 0,  0,
            0,  0,  sz, 0,
            0,  0,  0,  1,
        } };
    }

    pub fn rotationY(angle_rad: f64) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{ .m = [_]f64{
            c, 0, -s, 0,
            0, 1, 0,  0,
            s, 0, c,  0,
            0, 0, 0,  1,
        } };
    }

    pub fn rotationX(angle_rad: f64) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{ .m = [_]f64{
            1, 0,  0, 0,
            0, c,  s, 0,
            0, -s, c, 0,
            0, 0,  0, 1,
        } };
    }

    pub fn rotationZ(angle_rad: f64) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{ .m = [_]f64{
            c,  s, 0, 0,
            -s, c, 0, 0,
            0,  0, 1, 0,
            0,  0, 0, 1,
        } };
    }

    /// Perspective projection matrix
    pub fn perspective(fov_rad: f64, aspect: f64, near: f64, far: f64) Mat4 {
        const f = 1.0 / @tan(fov_rad / 2.0);
        const nf = 1.0 / (near - far);
        return .{ .m = [_]f64{
            f / aspect, 0, 0,           0,
            0,          f, 0,           0,
            0,          0, (far + near) * nf, -1,
            0,          0, 2 * far * near * nf, 0,
        } };
    }

    /// Look-at view matrix (right-handed)
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = Vec3.normalize(Vec3.sub(center, eye));
        const s = Vec3.normalize(Vec3.cross(f, up));
        const u = Vec3.cross(s, f);

        return .{ .m = [_]f64{
            s.x, u.x, -f.x, 0,
            s.y, u.y, -f.y, 0,
            s.z, u.z, -f.z, 0,
            -Vec3.dot(s, eye), -Vec3.dot(u, eye), Vec3.dot(f, eye), 1,
        } };
    }
};

// =============================================================================
// Camera
// =============================================================================

pub const Camera = struct {
    position: Vec3,
    heading: f64, // radians, 0 = north
    pitch: f64, // radians, 0 = horizon, positive = up
    roll: f64, // radians
    fov: f64, // radians
    aspect: f64,
    near_plane: f64,
    far_plane: f64,

    pub fn init(position: Vec3) Camera {
        return .{
            .position = position,
            .heading = 0,
            .pitch = -0.5, // looking slightly down
            .roll = 0,
            .fov = 60.0 * math.pi / 180.0,
            .aspect = 16.0 / 9.0,
            .near_plane = 100.0,
            .far_plane = 100_000_000.0, // 100,000 km for space view
        };
    }

    pub fn getViewMatrix(self: Camera) Mat4 {
        const ch = @cos(self.heading);
        const sh = @sin(self.heading);
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);

        const forward = Vec3.init(cp * sh, sp, -cp * ch);
        const target = Vec3.add(self.position, forward);
        const up = Vec3.init(0, 1, 0);
        return Mat4.lookAt(self.position, target, up);
    }

    pub fn getProjectionMatrix(self: Camera) Mat4 {
        return Mat4.perspective(self.fov, self.aspect, self.near_plane, self.far_plane);
    }

    pub fn getViewProjection(self: Camera) Mat4 {
        return Mat4.multiply(self.getProjectionMatrix(), self.getViewMatrix());
    }
};

// =============================================================================
// Globe Mesh Generation
// =============================================================================

pub const Vertex = struct {
    position: Vec3,
    normal: Vec3,
    uv: [2]f64, // texture coordinates [0,1]
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }
};

const WGS84_A_F: f64 = 6378137.0;
const WGS84_B_F: f64 = 6356752.314245;

/// Generate a WGS84 ellipsoid mesh with given segment counts
pub fn generateEllipsoidMesh(allocator: std.mem.Allocator, lat_segments: u32, lon_segments: u32) !Mesh {
    const vertex_count = (lat_segments + 1) * (lon_segments + 1);
    const index_count = lat_segments * lon_segments * 6;

    var vertices = try allocator.alloc(Vertex, vertex_count);
    var indices = try allocator.alloc(u32, index_count);

    var vi: usize = 0;
    var lat_i: u32 = 0;
    while (lat_i <= lat_segments) : (lat_i += 1) {
        const lat = -90.0 + 180.0 * @as(f64, @floatFromInt(lat_i)) / @as(f64, @floatFromInt(lat_segments));
        const lat_rad = lat * math.pi / 180.0;
        const cos_lat = @cos(lat_rad);
        const sin_lat = @sin(lat_rad);

        var lon_i: u32 = 0;
        while (lon_i <= lon_segments) : (lon_i += 1) {
            const lon = -180.0 + 360.0 * @as(f64, @floatFromInt(lon_i)) / @as(f64, @floatFromInt(lon_segments));
            const lon_rad = lon * math.pi / 180.0;
            const cos_lon = @cos(lon_rad);
            const sin_lon = @sin(lon_rad);

            const x = WGS84_A_F * cos_lat * cos_lon;
            const y = WGS84_B_F * sin_lat;
            const z = WGS84_A_F * cos_lat * sin_lon;

            const pos = Vec3.init(x, y, z);
            const normal = Vec3.normalize(pos);

            vertices[vi] = .{
                .position = pos,
                .normal = normal,
                .uv = .{
                    @as(f64, @floatFromInt(lon_i)) / @as(f64, @floatFromInt(lon_segments)),
                    @as(f64, @floatFromInt(lat_i)) / @as(f64, @floatFromInt(lat_segments)),
                },
            };
            vi += 1;
        }
    }

    var ii: usize = 0;
    lat_i = 0;
    while (lat_i < lat_segments) : (lat_i += 1) {
        var lon_i: u32 = 0;
        while (lon_i < lon_segments) : (lon_i += 1) {
            const v0 = lat_i * (lon_segments + 1) + lon_i;
            const v1 = v0 + 1;
            const v2 = v0 + (lon_segments + 1);
            const v3 = v2 + 1;

            indices[ii] = v0;
            indices[ii + 1] = v2;
            indices[ii + 2] = v1;
            indices[ii + 3] = v1;
            indices[ii + 4] = v2;
            indices[ii + 5] = v3;
            ii += 6;
        }
    }

    return .{
        .vertices = vertices,
        .indices = indices,
        .allocator = allocator,
    };
}

// =============================================================================
// Entities & Billboards
// =============================================================================

pub const EntityType = enum {
    aircraft,
    vessel,
    satellite,
    ground_station,
    camera,
    detection,
    annotation,
};

pub const Entity = struct {
    id: u32,
    entity_type: EntityType,
    position: Vec3, // ECEF or LLA-derived world position
    label: []const u8,
    heading: f64 = 0,
    scale: f64 = 1.0,
    visible: bool = true,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

pub const Billboard = struct {
    entity_id: u32,
    screen_x: f64, // NDC [-1, 1]
    screen_y: f64,
    screen_size: f64, // pixels
    visible: bool,
    behind_globe: bool,
};

// =============================================================================
// Frustum Culling
// =============================================================================

pub const Frustum = struct {
    // 6 planes: left, right, bottom, top, near, far
    // Each plane: ax + by + cz + d = 0, normal points inward
    planes: [6][4]f64,

    /// Extract frustum planes from view-projection matrix
    pub fn fromViewProjection(vp: Mat4) Frustum {
        const m = vp.m;
        return .{
            .planes = .{
                .{ m[3] + m[0], m[7] + m[4], m[11] + m[8], m[15] + m[12] }, // left
                .{ m[3] - m[0], m[7] - m[4], m[11] - m[8], m[15] - m[12] }, // right
                .{ m[3] + m[1], m[7] + m[5], m[11] + m[9], m[15] + m[13] }, // bottom
                .{ m[3] - m[1], m[7] - m[5], m[11] - m[9], m[15] - m[13] }, // top
                .{ m[2], m[6], m[10], m[14] }, // near
                .{ m[3] - m[2], m[7] - m[6], m[11] - m[10], m[15] - m[14] }, // far
            },
        };
    }

    /// Test if a point is inside the frustum
    pub fn containsPoint(self: Frustum, p: Vec3) bool {
        for (self.planes) |plane| {
            const dist = plane[0] * p.x + plane[1] * p.y + plane[2] * p.z + plane[3];
            if (dist < 0) return false;
        }
        return true;
    }

    /// Test if a sphere (center + radius) intersects the frustum
    pub fn containsSphere(self: Frustum, center: Vec3, radius: f64) bool {
        for (self.planes) |plane| {
            const dist = plane[0] * center.x + plane[1] * center.y + plane[2] * center.z + plane[3];
            if (dist < -radius) return false;
        }
        return true;
    }
};

// =============================================================================
// Globe Renderer
// =============================================================================

pub const GlobeRenderer = struct {
    allocator: std.mem.Allocator,
    mesh: Mesh,
    entities: std.ArrayList(Entity),
    camera: Camera,
    earth_radius: f64,

    pub fn init(allocator: std.mem.Allocator) !GlobeRenderer {
        const mesh = try generateEllipsoidMesh(allocator, 64, 128);
        return .{
            .allocator = allocator,
            .mesh = mesh,
            .entities = std.ArrayList(Entity).init(allocator),
            .camera = Camera.init(Vec3.init(0, 0, 20_000_000)), // 20,000 km away
            .earth_radius = WGS84_A_F,
        };
    }

    pub fn deinit(self: *GlobeRenderer) void {
        self.mesh.deinit();
        self.entities.deinit();
    }

    pub fn addEntity(self: *GlobeRenderer, entity: Entity) !void {
        try self.entities.append(entity);
    }

    pub fn removeEntity(self: *GlobeRenderer, id: u32) void {
        var i: usize = 0;
        while (i < self.entities.items.len) {
            if (self.entities.items[i].id == id) {
                _ = self.entities.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Cull entities against camera frustum, return visible entity IDs
    pub fn cullEntities(self: *GlobeRenderer, allocator: std.mem.Allocator) ![]u32 {
        const vp = self.camera.getViewProjection();
        const frustum = Frustum.fromViewProjection(vp);

        var visible = std.ArrayList(u32).init(allocator);
        for (self.entities.items) |entity| {
            if (!entity.visible) continue;
            if (frustum.containsPoint(entity.position)) {
                try visible.append(entity.id);
            }
        }
        return visible.toOwnedSlice();
    }

    /// Project a 3D world position to screen-space NDC coordinates
    pub fn projectToScreen(self: *GlobeRenderer, world_pos: Vec3) struct { x: f64, y: f64, z: f64, visible: bool } {
        const vp = self.camera.getViewProjection();
        const clip = vp.multiplyVec(Vec4.init(world_pos.x, world_pos.y, world_pos.z, 1.0));

        if (clip.w == 0) return .{ .x = 0, .y = 0, .z = 0, .visible = false };

        const ndc_x = clip.x / clip.w;
        const ndc_y = clip.y / clip.w;
        const ndc_z = clip.z / clip.w;

        const visible = ndc_x >= -1 and ndc_x <= 1 and ndc_y >= -1 and ndc_y <= 1 and ndc_z >= -1 and ndc_z <= 1;

        return .{ .x = ndc_x, .y = ndc_y, .z = ndc_z, .visible = visible };
    }

    /// Check if a point is occluded by the globe (behind the earth)
    pub fn isBehindGlobe(self: *GlobeRenderer, point: Vec3) bool {
        const cam_to_point = Vec3.sub(point, self.camera.position);
        const cam_to_point_len = cam_to_point.length();
        if (cam_to_point_len == 0) return false;

        const dir = cam_to_point.scale(1.0 / cam_to_point_len);
        // Ray-sphere intersection with earth sphere centered at origin
        const oc = self.camera.position;
        const b = 2.0 * Vec3.dot(oc, dir);
        const c = Vec3.dot(oc, oc) - self.earth_radius * self.earth_radius;
        const discriminant = b * b - 4.0 * c;

        if (discriminant < 0) return false; // ray doesn't hit earth

        const sqrt_d = @sqrt(discriminant);
        const t2 = (-b + sqrt_d) / 2.0;

        // If the point is farther than the far intersection, it's behind the globe
        const point_dist = cam_to_point_len;
        return t2 > 0 and point_dist > t2;
    }

    /// Generate billboards for visible entities
    pub fn generateBillboards(self: *GlobeRenderer, allocator: std.mem.Allocator) ![]Billboard {
        var billboards = std.ArrayList(Billboard).init(allocator);
        for (self.entities.items) |entity| {
            if (!entity.visible) continue;
            const proj = self.projectToScreen(entity.position);
            if (!proj.visible) continue;

            const behind = self.isBehindGlobe(entity.position);
            try billboards.append(.{
                .entity_id = entity.id,
                .screen_x = proj.x,
                .screen_y = proj.y,
                .screen_size = 16.0 * entity.scale,
                .visible = !behind,
                .behind_globe = behind,
            });
        }
        return billboards.toOwnedSlice();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "globe_render: Vec3 operations" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(4, 5, 6);

    try std.testing.expectEqual(@as(f64, 5), Vec3.add(a, b).x);
    try std.testing.expectEqual(@as(f64, 32), Vec3.dot(a, b));
    try std.testing.expectEqual(@as(f64, -3), Vec3.cross(a, b).x);

    const norm = Vec3.normalize(Vec3.init(3, 0, 4));
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), norm.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), norm.z, 1e-10);
}

test "globe_render: Mat4 identity multiply" {
    const id = Mat4.identity();
    const t = Mat4.translation(10, 20, 30);
    const result = Mat4.multiply(id, t);
    // Translation should be preserved
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.m[12], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 20), result.m[13], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 30), result.m[14], 1e-10);
}

test "globe_render: Mat4 multiplyVec with translation" {
    const t = Mat4.translation(10, 20, 30);
    const v = Vec4.init(1, 2, 3, 1);
    const result = t.multiplyVec(v);
    try std.testing.expectApproxEqAbs(@as(f64, 11), result.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 22), result.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 33), result.z, 1e-10);
}

test "globe_render: generateEllipsoidMesh vertex count" {
    const allocator = std.testing.allocator;
    var mesh = try generateEllipsoidMesh(allocator, 10, 20);
    defer mesh.deinit();

    // (10+1) * (20+1) = 231 vertices
    try std.testing.expectEqual(@as(usize, 231), mesh.vertices.len);
    // 10 * 20 * 6 = 1200 indices
    try std.testing.expectEqual(@as(usize, 1200), mesh.indices.len);
}

test "globe_render: generateEllipsoidMesh vertex positions on ellipsoid" {
    const allocator = std.testing.allocator;
    var mesh = try generateEllipsoidMesh(allocator, 4, 8);
    defer mesh.deinit();

    // Check first vertex (lat=-90, south pole)
    const v0 = mesh.vertices[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0), v0.position.x, 1e-3);
    try std.testing.expectApproxEqAbs(-WGS84_B_F, v0.position.y, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0), v0.position.z, 1e-3);
}

test "globe_render: frustum containsPoint" {
    const camera = Camera.init(Vec3.init(0, 0, 20_000_000));
    const vp = camera.getViewProjection();
    const frustum = Frustum.fromViewProjection(vp);

    // Origin (earth center) should be in front of camera
    try std.testing.expect(frustum.containsPoint(Vec3.init(0, 0, 0)));
}

test "globe_render: frustum culls behind camera" {
    const camera = Camera.init(Vec3.init(0, 0, 20_000_000));
    const vp = camera.getViewProjection();
    const frustum = Frustum.fromViewProjection(vp);

    // Point far behind camera should be culled
    try std.testing.expect(!frustum.containsPoint(Vec3.init(0, 0, 100_000_000)));
}

test "globe_render: GlobeRenderer add and remove entity" {
    const allocator = std.testing.allocator;
    var renderer = try GlobeRenderer.init(allocator);
    defer renderer.deinit();

    try renderer.addEntity(.{
        .id = 1,
        .entity_type = .aircraft,
        .position = Vec3.init(6378137, 0, 0),
        .label = "TEST001",
    });

    try std.testing.expectEqual(@as(usize, 1), renderer.entities.items.len);

    renderer.removeEntity(1);
    try std.testing.expectEqual(@as(usize, 0), renderer.entities.items.len);
}

test "globe_render: projectToScreen center is visible" {
    const allocator = std.testing.allocator;
    var renderer = try GlobeRenderer.init(allocator);
    defer renderer.deinit();

    const proj = renderer.projectToScreen(Vec3.init(0, 0, 0));
    try std.testing.expect(proj.visible);
    // Origin projects to center-ish; x should be ~0 since camera is on z-axis
    try std.testing.expectApproxEqAbs(@as(f64, 0), proj.x, 0.1);
}

test "globe_render: isBehindGlobe for near and far points" {
    const allocator = std.testing.allocator;
    var renderer = try GlobeRenderer.init(allocator);
    defer renderer.deinit();

    // Point on near side of earth (facing camera)
    const near_point = Vec3.init(0, 0, 6378137); // surface point toward camera
    try std.testing.expect(!renderer.isBehindGlobe(near_point));

    // Point clearly behind the globe from camera at z=20M
    const deep_far = Vec3.init(0, 0, -10_000_000);
    try std.testing.expect(renderer.isBehindGlobe(deep_far));
}

test "globe_render: generateBillboards for visible entities" {
    const allocator = std.testing.allocator;
    var renderer = try GlobeRenderer.init(allocator);
    defer renderer.deinit();

    try renderer.addEntity(.{
        .id = 1,
        .entity_type = .aircraft,
        .position = Vec3.init(0, 0, 6378137),
        .label = "NEAR",
    });
    try renderer.addEntity(.{
        .id = 2,
        .entity_type = .aircraft,
        .position = Vec3.init(0, 0, -6378137),
        .label = "FAR",
    });

    const billboards = try renderer.generateBillboards(allocator);
    defer allocator.free(billboards);

    // Both should project to screen, but far one should be marked behind globe
    try std.testing.expectEqual(@as(usize, 2), billboards.len);
    try std.testing.expect(!billboards[0].behind_globe or !billboards[1].behind_globe);
}

test "globe_render: Vec3 lerp" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(10, 20, 30);
    const mid = Vec3.lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10), mid.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 15), mid.z, 1e-10);
}

test "globe_render: Mat4 perspective produces valid projection" {
    const p = Mat4.perspective(60.0 * math.pi / 180.0, 16.0 / 9.0, 1.0, 1000.0);
    // Diagonal elements should be non-zero
    try std.testing.expect(p.m[0] != 0);
    try std.testing.expect(p.m[5] != 0);
    // Far/near should produce valid z scaling
    try std.testing.expect(p.m[10] != 0);
}

test "globe_render: Mat4 lookAt produces correct orientation" {
    const eye = Vec3.init(0, 0, 10);
    const center = Vec3.init(0, 0, 0);
    const up = Vec3.init(0, 1, 0);
    const view = Mat4.lookAt(eye, center, up);

    // Transform a point at origin — should be at view origin (0,0,0) in view space
    const v = view.multiplyVec(Vec4.init(0, 0, 0, 1));
    try std.testing.expectApproxEqAbs(@as(f64, 0), v.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), v.y, 1e-10);
    // The origin should be 10 units in front of the camera (z = -10 in right-handed)
    try std.testing.expectApproxEqAbs(@as(f64, -10), v.z, 1e-10);
}
