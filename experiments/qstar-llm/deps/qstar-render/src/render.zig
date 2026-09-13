//! render.zig — Purified WebGPU ECS renderer.
//!
//! Extracted from Orillusion (TypeScript) to pure Zig + WGSL.
//! No npm, no TypeScript, no external dependencies beyond std.
//!
//! Architecture:
//!   Entity = Object3D (scene graph node)
//!   Component = behavior attached to entity (Transform, Camera, Light, Material)
//!   RenderGraph = DAG of render passes (topological sort)
//!   Forward+ pipeline: Depth → HiZ → Shadow → Color → Sky → Post → Present

const std = @import("std");
const fp = @import("fixed_point");

// Inlined from lattice.zig for self-containment (checkpoint 5)
const BASE_EDGE: u32 = 15;
fn latticeEdge(level: u8) u32 {
    return BASE_EDGE * (@as(u32, 1) << @intCast(level));
}

// =============================================================================
// Math: Vector3, Vector4, Matrix4, Quaternion
// =============================================================================

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(dot(a, a));
    }

    pub fn normalize(a: Vec3) Vec3 {
        const len = length(a);
        if (len < 1e-10) return .{};
        return scale(a, 1.0 / len);
    }

    pub fn distance(a: Vec3, b: Vec3) f32 {
        return length(sub(a, b));
    }
};

pub const Vec4 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    pub fn new(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
};

pub const Quat = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub fn identity() Quat {
        return .{};
    }

    pub fn fromEuler(x: f32, y: f32, z: f32) Quat {
        const cx = @cos(x * 0.5);
        const sx = @sin(x * 0.5);
        const cy = @cos(y * 0.5);
        const sy = @sin(y * 0.5);
        const cz = @cos(z * 0.5);
        const sz = @sin(z * 0.5);
        return .{
            .x = sx * cy * cz - cx * sy * sz,
            .y = cx * sy * cz + sx * cy * sz,
            .z = cx * cy * sz - sx * sy * cz,
            .w = cx * cy * cz + sx * sy * sz,
        };
    }
};

/// 4×4 matrix stored column-major (WebGPU convention).
pub const Mat4 = struct {
    m: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },

    pub fn identity() Mat4 {
        return .{};
    }

    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov * 0.5);
        const range = far - near;
        return .{
            .m = .{
                f / aspect, 0, 0, 0,
                0, f, 0, 0,
                0, 0, far / range, 1,
                0, 0, -(far * near) / range, 0,
            },
        };
    }

    pub fn orthoOffCenter(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        const rml = right - left;
        const tmb = top - bottom;
        const fmn = far - near;
        return .{
            .m = .{
                2.0 / rml, 0, 0, 0,
                0, 2.0 / tmb, 0, 0,
                0, 0, -2.0 / fmn, 0,
                -(right + left) / rml, -(top + bottom) / tmb, -(far + near) / fmn, 1,
            },
        };
    }

    pub fn translation(x: f32, y: f32, z: f32) Mat4 {
        return .{
            .m = .{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                x, y, z, 1,
            },
        };
    }

    pub fn scaling(x: f32, y: f32, z: f32) Mat4 {
        return .{
            .m = .{
                x, 0, 0, 0,
                0, y, 0, 0,
                0, 0, z, 0,
                0, 0, 0, 1,
            },
        };
    }

    pub fn rotation(q: Quat) Mat4 {
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;
        return .{
            .m = .{
                1 - 2 * (yy + zz), 2 * (xy + wz),     2 * (xz - wy),     0,
                2 * (xy - wz),     1 - 2 * (xx + zz), 2 * (yz + wx),     0,
                2 * (xz + wy),     2 * (yz - wx),     1 - 2 * (xx + yy), 0,
                0,                 0,                 0,                 1,
            },
        };
    }

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = .{};
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                result.m[col * 4 + row] = sum;
            }
        }
        return result;
    }

    pub fn invert(self: Mat4) Mat4 {
        var inv: Mat4 = .{};
        const m = self.m;
        inv.m[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv.m[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv.m[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv.m[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        const det = m[0] * inv.m[0] + m[1] * inv.m[1] + m[2] * inv.m[2] + m[3] * inv.m[3];
        if (@abs(det) < 1e-10) return identity();
        const inv_det = 1.0 / det;
        for (0..16) |i| inv.m[i] *= inv_det;
        return inv;
    }
};

// =============================================================================
// ECS: Entity, Component, Scene Graph
// =============================================================================

pub const EntityId = u32;

pub const ComponentType = enum {
    transform,
    camera,
    light,
    material,
    render_node,
    custom,
};

pub const Component = struct {
    type: ComponentType,
    entity: EntityId,
    enabled: bool = true,
};

/// Transform component: position, rotation, scale, world matrix.
pub const Transform = struct {
    base: Component,
    local_pos: Vec3 = .{},
    local_rot: Quat = .{},
    local_scale: Vec3 = .{ .x = 1, .y = 1, .z = 1 },
    world_matrix: Mat4 = .{},
    dirty: bool = true,
    parent: ?EntityId = null,
    depth_order: u32 = 0,

    pub fn updateWorldMatrix(self: *Transform, parent_world: ?Mat4) void {
        var local = Mat4.translation(self.local_pos.x, self.local_pos.y, self.local_pos.z);
        local = Mat4.multiply(local, Mat4.rotation(self.local_rot));
        local = Mat4.multiply(local, Mat4.scaling(self.local_scale.x, self.local_scale.y, self.local_scale.z));

        if (parent_world) |pw| {
            self.world_matrix = Mat4.multiply(pw, local);
        } else {
            self.world_matrix = local;
        }
        self.dirty = false;
    }
};

/// Entity in the scene graph.
pub const Entity = struct {
    id: EntityId,
    name: []const u8,
    parent: ?EntityId = null,
    children: std.ArrayList(EntityId),
    transform: Transform,
    visible: bool = true,
    visible_layer: u32 = 0xFFFFFFFF,

    pub fn deinit(self: *Entity) void {
        self.children.deinit();
    }
};

/// Scene graph: collection of entities.
pub const Scene = struct {
    entities: std.AutoHashMap(EntityId, Entity),
    next_id: EntityId = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{
            .entities = std.AutoHashMap(EntityId, Entity).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scene) void {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.entities.deinit();
    }

    pub fn createEntity(self: *Scene, name: []const u8) !EntityId {
        const id = self.next_id;
        self.next_id += 1;
        try self.entities.put(id, Entity{
            .id = id,
            .name = name,
            .children = std.ArrayList(EntityId).init(self.allocator),
            .transform = .{
                .base = .{ .type = .transform, .entity = id },
            },
        });
        return id;
    }

    pub fn addChild(self: *Scene, parent: EntityId, child: EntityId) !void {
        const parent_entry = self.entities.getPtr(parent) orelse return error.EntityNotFound;
        try parent_entry.children.append(child);
        const child_entry = self.entities.getPtr(child) orelse return error.EntityNotFound;
        child_entry.parent = parent;
        child_entry.transform.parent = parent;
        child_entry.transform.depth_order = parent_entry.transform.depth_order + 1;
        child_entry.transform.dirty = true;
    }

    pub fn getEntity(self: *Scene, id: EntityId) ?*Entity {
        return self.entities.getPtr(id);
    }

    /// Recursively update world matrices from root to leaves.
    pub fn updateTransforms(self: *Scene) void {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.parent == null) {
                self.updateTransformRecursive(entry.key_ptr.*, null);
            }
        }
    }

    fn updateTransformRecursive(self: *Scene, id: EntityId, parent_world: ?Mat4) void {
        const entity = self.entities.getPtr(id) orelse return;
        if (entity.transform.dirty or parent_world != null) {
            entity.transform.updateWorldMatrix(parent_world);
        }
        const world = entity.transform.world_matrix;
        for (entity.children.items) |child| {
            self.updateTransformRecursive(child, world);
        }
    }
};

// =============================================================================
// Camera
// =============================================================================

pub const CameraType = enum { perspective, ortho };

pub const Camera = struct {
    base: Component,
    cam_type: CameraType = .perspective,
    fov: f32 = 60.0,
    aspect: f32 = 1.0,
    near: f32 = 0.1,
    far: f32 = 5000.0,
    projection: Mat4 = .{},
    view_matrix: Mat4 = .{},
    culling_mask: u32 = 0xFFFFFFFF,

    pub fn updateProjection(self: *Camera) void {
        switch (self.cam_type) {
            .perspective => {
                self.projection = Mat4.perspective(
                    self.fov * std.math.pi / 180.0,
                    self.aspect,
                    self.near,
                    self.far,
                );
            },
            .ortho => {
                self.projection = Mat4.orthoOffCenter(-1, 1, -1, 1, self.near, self.far);
            },
        }
    }

    pub fn updateView(self: *Camera, world_matrix: Mat4) void {
        self.view_matrix = world_matrix.invert();
    }
};

// =============================================================================
// Light
// =============================================================================

pub const LightType = enum { directional, point, spot };

pub const Light = struct {
    base: Component,
    light_type: LightType = .directional,
    color: Vec3 = .{ .x = 1, .y = 1, .z = 1 },
    intensity: f32 = 1.0,
    range: f32 = 100.0,
};

// =============================================================================
// Material
// =============================================================================

pub const Material = struct {
    base: Component,
    shader_name: []const u8 = "default",
    base_color: Vec4 = .{ .x = 1, .y = 1, .z = 1, .w = 1 },
    roughness: f32 = 0.5,
    metallic: f32 = 0.0,
    wireframe: bool = false,
};

// =============================================================================
// Render Graph: DAG of render passes
// =============================================================================

pub const PassId = u32;

pub const PassType = enum {
    pre_depth,
    hiz,
    shadow,
    point_shadow,
    reflection,
    gi,
    color,
    sky,
    post,
    gui,
    cluster_lighting,
    motion_vector,
};

/// A render pass in the graph.
pub const RenderPass = struct {
    id: PassId,
    name: []const u8,
    pass_type: PassType,
    reads: std.ArrayList([]const u8),
    writes: std.ArrayList([]const u8),
    enabled: bool = true,
    insert_order: u32,

    pub fn deinit(self: *RenderPass) void {
        self.reads.deinit();
        self.writes.deinit();
    }
};

/// Render graph: DAG of passes with topological sort.
pub const RenderGraph = struct {
    passes: std.ArrayList(RenderPass),
    allocator: std.mem.Allocator,
    compiled_order: std.ArrayList(PassId),
    dirty: bool = true,
    next_insert: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{
            .passes = std.ArrayList(RenderPass).init(allocator),
            .allocator = allocator,
            .compiled_order = std.ArrayList(PassId).init(allocator),
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        for (self.passes.items) |*pass| pass.deinit();
        self.passes.deinit();
        self.compiled_order.deinit();
    }

    pub fn addPass(self: *RenderGraph, name: []const u8, pass_type: PassType) !PassId {
        const id: PassId = @intCast(self.passes.items.len);
        try self.passes.append(.{
            .id = id,
            .name = name,
            .pass_type = pass_type,
            .reads = std.ArrayList([]const u8).init(self.allocator),
            .writes = std.ArrayList([]const u8).init(self.allocator),
            .insert_order = self.next_insert,
        });
        self.next_insert += 1;
        self.dirty = true;
        return id;
    }

    pub fn addRead(self: *RenderGraph, pass_id: PassId, resource: []const u8) !void {
        try self.passes.items[pass_id].reads.append(resource);
        self.dirty = true;
    }

    pub fn addWrite(self: *RenderGraph, pass_id: PassId, resource: []const u8) !void {
        try self.passes.items[pass_id].writes.append(resource);
        self.dirty = true;
    }

    /// Topological sort: order passes so that all reads of a resource
    /// come after its writer. Ties broken by insertion order.
    pub fn compile(self: *RenderGraph) !void {
        if (!self.dirty) return;
        self.compiled_order.clearRetainingCapacity();

        const n = self.passes.items.len;
        if (n == 0) {
            self.dirty = false;
            return;
        }

        // Build adjacency: pass A must come before pass B if B reads
        // a resource that A writes.
        var in_degree = try self.allocator.alloc(u32, n);
        defer self.allocator.free(in_degree);
        @memset(in_degree, 0);

        var adj = try self.allocator.alloc(std.ArrayList(PassId), n);
        defer {
            for (adj) |*list| list.deinit();
            self.allocator.free(adj);
        }
        for (adj) |*list| list.* = std.ArrayList(PassId).init(self.allocator);

        for (self.passes.items) |reader| {
            for (reader.reads.items) |resource| {
                for (self.passes.items) |writer| {
                    if (writer.id == reader.id) continue;
                    for (writer.writes.items) |w_res| {
                        if (std.mem.eql(u8, w_res, resource)) {
                            try adj[writer.id].append(reader.id);
                            in_degree[reader.id] += 1;
                        }
                    }
                }
            }
        }

        // Kahn's algorithm with insertion-order tiebreak
        var queue = std.ArrayList(PassId).init(self.allocator);
        defer queue.deinit();
        for (0..n) |i| {
            if (in_degree[i] == 0) try queue.append(@intCast(i));
        }

        while (queue.items.len > 0) {
            // Find lowest insert_order among zero-in-degree
            var min_idx: usize = 0;
            for (1..queue.items.len) |i| {
                if (self.passes.items[queue.items[i]].insert_order <
                    self.passes.items[queue.items[min_idx]].insert_order)
                {
                    min_idx = i;
                }
            }
            const pass_id = queue.swapRemove(min_idx);
            try self.compiled_order.append(pass_id);

            for (adj[pass_id].items) |dependent| {
                in_degree[dependent] -= 1;
                if (in_degree[dependent] == 0) try queue.append(dependent);
            }
        }

        if (self.compiled_order.items.len != n) return error.CyclicDependency;
        self.dirty = false;
    }

    pub fn getCompiledOrder(self: *RenderGraph) []const PassId {
        return self.compiled_order.items;
    }
};

// =============================================================================
// View: pairs a Camera with a Scene and viewport
// =============================================================================

pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const View = struct {
    camera: ?*Camera = null,
    scene: ?*Scene = null,
    viewport: Viewport = .{},
    enabled: bool = true,
};

// =============================================================================
// Engine: ties everything together
// =============================================================================

pub const EngineConfig = struct {
    z_prepass: bool = true,
    shadows: bool = true,
    gi: bool = false,
    msaa: u32 = 0,
    tonemap: bool = true,
};

pub const Engine = struct {
    config: EngineConfig,
    graph: RenderGraph,
    views: std.ArrayList(View),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) Engine {
        return .{
            .config = config,
            .graph = RenderGraph.init(allocator),
            .views = std.ArrayList(View).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.graph.deinit();
        self.views.deinit();
    }

    /// Build the Forward+ pass graph.
    pub fn setupForwardPipeline(self: *Engine) !void {
        // Cluster lighting first
        _ = try self.graph.addPass("ClusterLighting", .cluster_lighting);

        // Z-prepass (gated)
        if (self.config.z_prepass) {
            _ = try self.graph.addPass("PreDepth", .pre_depth);
        }

        // Hi-Z depth pyramid
        _ = try self.graph.addPass("HiZ", .hiz);

        // Motion vectors
        _ = try self.graph.addPass("MotionVector", .motion_vector);

        // Shadows
        if (self.config.shadows) {
            _ = try self.graph.addPass("Shadow", .shadow);
            _ = try self.graph.addPass("PointShadow", .point_shadow);
        }

        // Reflection
        _ = try self.graph.addPass("Reflection", .reflection);

        // GI (gated)
        if (self.config.gi) {
            _ = try self.graph.addPass("GI", .gi);
        }

        // Main color pass
        _ = try self.graph.addPass("Color", .color);

        // Sky
        _ = try self.graph.addPass("Sky", .sky);

        // Post-processing
        _ = try self.graph.addPass("Post", .post);

        // Present to canvas
        _ = try self.graph.addPass("GUI", .gui);

        // Set up resource dependencies
        const passes = self.graph.passes.items;
        for (passes) |*pass| {
            switch (pass.pass_type) {
                .hiz => {
                    if (self.config.z_prepass) try self.graph.addRead(pass.id, "depth_buffer");
                    try self.graph.addWrite(pass.id, "hiz_pyramid");
                },
                .shadow => {
                    try self.graph.addWrite(pass.id, "shadow_map");
                },
                .color => {
                    if (self.config.z_prepass) try self.graph.addRead(pass.id, "depth_buffer");
                    try self.graph.addRead(pass.id, "shadow_map");
                    try self.graph.addWrite(pass.id, "color_buffer");
                },
                .sky => {
                    try self.graph.addRead(pass.id, "depth_buffer");
                    try self.graph.addWrite(pass.id, "color_buffer");
                },
                .post => {
                    try self.graph.addRead(pass.id, "color_buffer");
                    try self.graph.addWrite(pass.id, "post_buffer");
                },
                .gui => {
                    try self.graph.addRead(pass.id, "post_buffer");
                    try self.graph.addWrite(pass.id, "present");
                },
                else => {},
            }
        }

        try self.graph.compile();
    }

    pub fn addView(self: *Engine, view: View) !void {
        try self.views.append(view);
    }
};

// =============================================================================
// Lattice Geometry: torus from Smith chart cross-sections
// =============================================================================

/// Generates torus vertices for the lattice at a given level.
/// The torus cross-section is derived from Smith chart impedance circles.
pub fn latticeTorusVertices(allocator: std.mem.Allocator, level: u8) ![]Vec3 {
    const edge = latticeEdge(level);
    const major_radius: f32 = @floatFromInt(edge / 2);
    const minor_radius: f32 = @floatFromInt(edge / 4);
    const segments: u32 = 64;
    const rings: u32 = 32;

    var vertices = try allocator.alloc(Vec3, segments * rings);
    var idx: usize = 0;

    var ring: u32 = 0;
    while (ring < rings) : (ring += 1) {
        const v: f32 = @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));
        const phi = v * 2.0 * std.math.pi;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);

        var seg: u32 = 0;
        while (seg < segments) : (seg += 1) {
            const u: f32 = @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(segments));
            const theta = u * 2.0 * std.math.pi;
            const cos_theta = @cos(theta);
            const sin_theta = @sin(theta);

            vertices[idx] = .{
                .x = (major_radius + minor_radius * cos_phi) * cos_theta,
                .y = minor_radius * sin_phi,
                .z = (major_radius + minor_radius * cos_phi) * sin_theta,
            };
            idx += 1;
        }
    }

    return vertices;
}

// =============================================================================
// Smith Chart Torus Visualization
// =============================================================================

/// Number of elastic sail points on the Smith chart (3 conjugate pairs).
pub const NUM_SAIL_POINTS: usize = 6;

/// A single elastic sail point on the Smith chart torus.
/// Each point represents an impedance state that deforms as E0 nodes fire.
pub const SailPoint = struct {
    gamma_r: f32,
    gamma_i: f32,
    impedance: f32,
    activation: f32,
};

/// Smith chart uniform data for WGSL shader (must match struct in render.wgsl).
pub const SmithChartUniform = struct {
    time: f32,
    major_radius: f32,
    minor_radius: f32,
    num_sail_points: u32,
    sail_points: [6]@Vector(4, f32),
    fusion_scale: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },

    pub fn fromSailPoints(time: f32, major: f32, minor: f32, points: []const SailPoint, fusion_scale: f32) SmithChartUniform {
        var sp: [6]@Vector(4, f32) = .{
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
        };
        const n = @min(points.len, NUM_SAIL_POINTS);
        for (0..n) |i| {
            sp[i] = .{ points[i].gamma_r, points[i].gamma_i, points[i].impedance, points[i].activation };
        }
        return .{
            .time = time,
            .major_radius = major,
            .minor_radius = minor,
            .num_sail_points = @intCast(n),
            .sail_points = sp,
            .fusion_scale = fusion_scale,
        };
    }
};

/// Converts impedance Z to reflection coefficient Γ = (Z - Z₀) / (Z + Z₀).
pub fn impedanceToGamma(z: f32, z0: f32) struct { r: f32, i: f32 } {
    if (z + z0 == 0) return .{ .r = 1.0, .i = 0.0 };
    const gamma = (z - z0) / (z + z0);
    return .{ .r = gamma, .i = 0.0 };
}

/// Converts impedance with reactive component to reflection coefficient.
/// Z = R + jX, Z₀ = reference impedance.
/// Γ = (Z - Z₀) / (Z + Z₀) = ((R-Z₀) + jX) / ((R+Z₀) + jX)
pub fn impedanceComplexToGamma(r: f32, x: f32, z0: f32) struct { gr: f32, gi: f32 } {
    const denom = (r + z0) * (r + z0) + x * x;
    if (denom == 0) return .{ .gr = 1.0, .gi = 0.0 };
    const gr = ((r - z0) * (r + z0) + x * x) / denom;
    const gi = (2.0 * x * z0) / denom;
    return .{ .gr = gr, .gi = gi };
}

/// Maps 421 E0 node activations (7 channels) to 6 sail points.
/// Each sail point aggregates ~70 E0 nodes (421/6 ≈ 70).
/// The 7th channel is the observer (center of Smith chart).
pub fn e0ActivationsToSailPoints(activations: []const [7]f32) [NUM_SAIL_POINTS]SailPoint {
    var points: [NUM_SAIL_POINTS]SailPoint = undefined;
    const nodes_per_point = activations.len / NUM_SAIL_POINTS;
    const z0: f32 = 50.0;

    for (0..NUM_SAIL_POINTS) |i| {
        var total_r: f32 = 0;
        var total_x: f32 = 0;
        var total_activation: f32 = 0;
        const start = i * nodes_per_point;
        const end = if (i == NUM_SAIL_POINTS - 1) activations.len else start + nodes_per_point;
        for (start..end) |n| {
            const node = activations[n];
            total_r += node[0] * 100.0;
            total_x += node[1] * 50.0;
            total_activation += node[2];
        }
        const count: f32 = @floatFromInt(end - start);
        const avg_r = total_r / count;
        const avg_x = total_x / count;
        const avg_act = total_activation / count;
        const gamma = impedanceComplexToGamma(avg_r, avg_x, z0);
        points[i] = .{
            .gamma_r = gamma.gr,
            .gamma_i = gamma.gi,
            .impedance = avg_r,
            .activation = avg_act,
        };
    }
    return points;
}

/// Generates a unit sphere vertex buffer for instanced sail point rendering.
/// Returns 24 vertices forming a low-poly sphere (octahedron subdivision).
pub fn unitSphereVertices(allocator: std.mem.Allocator) ![]Vec3 {
    var verts = try allocator.alloc(Vec3, 24);
    const t: f32 = 0.57735026919;
    const s: f32 = 0.70710678118;

    verts[0] = Vec3.new(t, t, t);
    verts[1] = Vec3.new(t, t, -t);
    verts[2] = Vec3.new(t, -t, t);
    verts[3] = Vec3.new(t, -t, -t);
    verts[4] = Vec3.new(-t, t, t);
    verts[5] = Vec3.new(-t, t, -t);
    verts[6] = Vec3.new(-t, -t, t);
    verts[7] = Vec3.new(-t, -t, -t);
    verts[8] = Vec3.new(s, 0, 0);
    verts[9] = Vec3.new(-s, 0, 0);
    verts[10] = Vec3.new(0, s, 0);
    verts[11] = Vec3.new(0, -s, 0);
    verts[12] = Vec3.new(0, 0, s);
    verts[13] = Vec3.new(0, 0, -s);
    verts[14] = Vec3.new(t, t, 0);
    verts[15] = Vec3.new(t, -t, 0);
    verts[16] = Vec3.new(-t, t, 0);
    verts[17] = Vec3.new(-t, -t, 0);
    verts[18] = Vec3.new(0, t, t);
    verts[19] = Vec3.new(0, t, -t);
    verts[20] = Vec3.new(0, -t, t);
    verts[21] = Vec3.new(0, -t, -t);
    verts[22] = Vec3.new(t, 0, t);
    verts[23] = Vec3.new(t, 0, -t);

    return verts;
}

/// Generates index buffer for the unit sphere (12 triangles from octahedron).
pub fn unitSphereIndices(allocator: std.mem.Allocator) ![]u16 {
    const tris = [_][3]u16{
        .{ 0, 8, 14 }, .{ 0, 14, 10 }, .{ 0, 10, 18 }, .{ 0, 18, 22 }, .{ 0, 22, 8 },
        .{ 1, 14, 8 }, .{ 1, 10, 14 }, .{ 1, 19, 10 }, .{ 1, 23, 19 }, .{ 1, 8, 23 },
        .{ 2, 22, 18 }, .{ 2, 18, 11 }, .{ 2, 11, 20 }, .{ 2, 20, 15 }, .{ 2, 15, 22 },
        .{ 3, 23, 8 }, .{ 3, 19, 23 }, .{ 3, 11, 19 }, .{ 3, 21, 11 }, .{ 3, 15, 21 },
        .{ 4, 16, 9 }, .{ 4, 10, 16 }, .{ 4, 18, 10 }, .{ 4, 9, 18 },
        .{ 5, 9, 16 }, .{ 5, 16, 10 }, .{ 5, 10, 19 }, .{ 5, 19, 9 },
        .{ 6, 9, 17 }, .{ 6, 17, 11 }, .{ 6, 11, 20 }, .{ 6, 20, 9 },
        .{ 7, 17, 9 }, .{ 7, 9, 19 }, .{ 7, 19, 11 }, .{ 7, 11, 17 },
    };
    var indices = try allocator.alloc(u16, tris.len * 3);
    for (tris, 0..) |tri, i| {
        indices[i * 3] = tri[0];
        indices[i * 3 + 1] = tri[1];
        indices[i * 3 + 2] = tri[2];
    }
    return indices;
}

/// Generates Smith chart torus vertices for the WGSL vertex shader.
/// The torus has 128 segments × 64 rings = 8,192 vertices.
pub fn smithChartTorusVertexCount() usize {
    return 128 * 64;
}

/// Generates fusion reactor background torus vertices.
/// 64 segments × 32 rings = 2,048 vertices.
pub fn fusionTorusVertexCount() usize {
    return 64 * 32;
}

// =============================================================================
// Procedural s=5 → s=7 E0 Seed Expansion
// =============================================================================

/// Number of E0 nodes in the base lattice (inlined from lattice.zig).
pub const E0_NODE_COUNT: usize = 421;

/// Expansion factor from s=5 to s=7: 8^(7-5) = 64.
pub const SEED_EXPANSION_FACTOR: u32 = 64;

/// A single E0 node seed entry for GPU expansion.
pub const E0SeedNode = struct {
    x: u32,
    y: u32,
    z: u32,
    activation: i64, // Q32.32 fixed-point
};

/// E0 seed buffer for compute shader input.
pub const E0SeedBuffer = struct {
    nodes: [E0_NODE_COUNT]E0SeedNode,
    level: u8 = 5,
    target_level: u8 = 7,

    pub fn empty() E0SeedBuffer {
        return .{ .nodes = [_]E0SeedNode{.{ .x = 0, .y = 0, .z = 0, .activation = 0 }} ** E0_NODE_COUNT };
    }
};

/// An expanded cell at the target lattice level.
pub const ExpandedCell = struct {
    x: f32,
    y: f32,
    z: f32,
    activation: f32,
    e_value: u3,
    is_boundary: bool,
};

/// Computes the lattice edge at a given level (inlined from lattice.zig).
fn latticeEdgeForLevel(level: u8) u32 {
    return 15 * (@as(u32, 1) << @intCast(level));
}

/// Computes the e-value for a cell at the target level (inlined from lattice.zig).
fn computeEValueForCell(x: u32, y: u32, z: u32, edge: u32) u3 {
    const dx = @min(x, edge - 1 - x);
    const dy = @min(y, edge - 1 - y);
    const half = edge / 2;
    const dz = if (z >= half) z - half else half - z;
    const raw: i64 = 6 + @as(i64, dz) - @as(i64, dx) - @as(i64, dy);
    const modded = @mod(raw, 8);
    return @intCast(modded);
}

/// Checks if a cell is on the boundary of the lattice.
fn isCellBoundary(x: u32, y: u32, z: u32, edge: u32) bool {
    return x == 0 or x == edge - 1 or y == 0 or y == edge - 1 or z == 0 or z == edge - 1;
}

/// Expands a single E0 node into sub-cells at the target level.
/// Each E0 node at level s generates 4^3 = 64 sub-cells at level s+2.
pub fn expandNode(node: E0SeedNode, target_edge: u32, expansion_factor: u32, out: []ExpandedCell) void {
    const scale = target_edge / 15;
    const sub_step = scale / 4;

    const subX_count: u32 = 4;
    const subY_count: u32 = 4;
    const subZ_count: u32 = 4;
    _ = expansion_factor;

    var idx: u32 = 0;
    var sz: u32 = 0;
    while (sz < subZ_count) : (sz += 1) {
        var sy: u32 = 0;
        while (sy < subY_count) : (sy += 1) {
            var sx: u32 = 0;
            while (sx < subX_count) : (sx += 1) {
                const cell_x = node.x * scale + sx * sub_step;
                const cell_y = node.y * scale + sy * sub_step;
                const cell_z = node.z * scale + sz * sub_step;

                const e_val = computeEValueForCell(cell_x, cell_y, cell_z, target_edge);
                const is_bnd = isCellBoundary(cell_x, cell_y, cell_z, target_edge);

                const nf: f32 = @floatFromInt(target_edge);
                out[idx] = .{
                    .x = (@as(f32, @floatFromInt(cell_x)) / nf) * 2.0 - 1.0,
                    .y = (@as(f32, @floatFromInt(cell_y)) / nf) * 2.0 - 1.0,
                    .z = (@as(f32, @floatFromInt(cell_z)) / nf) * 2.0 - 1.0,
                    .activation = @as(f32, @floatFromInt(node.activation)) / @as(f32, @floatFromInt(fp.ONE)),
                    .e_value = e_val,
                    .is_boundary = is_bnd,
                };
                idx += 1;
            }
        }
    }
}

/// Expands all 421 E0 nodes from s=5 to s=7, producing 421 × 64 = 26,944 cells.
pub fn expandSeed(allocator: std.mem.Allocator, seed: E0SeedBuffer) ![]ExpandedCell {
    const total = E0_NODE_COUNT * SEED_EXPANSION_FACTOR;
    var cells = try allocator.alloc(ExpandedCell, total);
    errdefer allocator.free(cells);

    const target_edge = latticeEdgeForLevel(seed.target_level);

    for (0..E0_NODE_COUNT) |i| {
        const offset = i * SEED_EXPANSION_FACTOR;
        expandNode(seed.nodes[i], target_edge, SEED_EXPANSION_FACTOR, cells[offset .. offset + SEED_EXPANSION_FACTOR]);
    }

    return cells;
}

/// Frustum culling: filters expanded cells to only those within the camera view.
/// Returns a subset of cells that pass the frustum test.
pub fn frustumCull(allocator: std.mem.Allocator, cells: []const ExpandedCell, camera_pos: Vec3, camera_dir: Vec3, fov: f32, aspect: f32) ![]ExpandedCell {
    var visible = std.ArrayList(ExpandedCell).init(allocator);
    errdefer visible.deinit();

    const cos_half_fov = @cos(fov * 0.5 * std.math.pi / 180.0);
    const tan_half_fov = @tan(fov * 0.5 * std.math.pi / 180.0);
    const right = Vec3.normalize(Vec3.cross(camera_dir, Vec3.new(0, 1, 0)));
    const up = Vec3.normalize(Vec3.cross(right, camera_dir));

    for (cells) |cell| {
        const cell_pos = Vec3.new(cell.x, cell.y, cell.z);
        const to_cell = Vec3.sub(cell_pos, camera_pos);
        const dist = Vec3.length(to_cell);
        if (dist < 0.001) {
            try visible.append(cell);
            continue;
        }
        const dir_to_cell = Vec3.scale(to_cell, 1.0 / dist);
        const dot_forward = Vec3.dot(dir_to_cell, camera_dir);
        if (dot_forward < cos_half_fov) continue;

        const dot_right = Vec3.dot(dir_to_cell, right);
        const dot_up = Vec3.dot(dir_to_cell, up);
        const max_right = tan_half_fov * aspect;
        if (@abs(dot_right) > max_right) continue;
        if (@abs(dot_up) > tan_half_fov) continue;

        try visible.append(cell);
    }

    return visible.toOwnedSlice();
}

/// Generates a unit cube (24 vertices, 36 indices) for instanced cell rendering.
pub fn unitCubeVertices(allocator: std.mem.Allocator) ![]Vec3 {
    var verts = try allocator.alloc(Vec3, 24);
    const s: f32 = 0.5;
    verts[0] = Vec3.new(-s, -s, -s); verts[1] = Vec3.new(s, -s, -s);
    verts[2] = Vec3.new(s, s, -s); verts[3] = Vec3.new(-s, s, -s);
    verts[4] = Vec3.new(-s, -s, s); verts[5] = Vec3.new(s, -s, s);
    verts[6] = Vec3.new(s, s, s); verts[7] = Vec3.new(-s, s, s);
    verts[8] = Vec3.new(-s, -s, -s); verts[9] = Vec3.new(-s, s, -s);
    verts[10] = Vec3.new(-s, s, s); verts[11] = Vec3.new(-s, -s, s);
    verts[12] = Vec3.new(s, -s, -s); verts[13] = Vec3.new(s, s, -s);
    verts[14] = Vec3.new(s, s, s); verts[15] = Vec3.new(s, -s, s);
    verts[16] = Vec3.new(-s, -s, -s); verts[17] = Vec3.new(-s, -s, s);
    verts[18] = Vec3.new(s, -s, s); verts[19] = Vec3.new(s, -s, -s);
    verts[20] = Vec3.new(-s, s, -s); verts[21] = Vec3.new(-s, s, s);
    verts[22] = Vec3.new(s, s, s); verts[23] = Vec3.new(s, s, -s);
    return verts;
}

pub fn unitCubeIndices(allocator: std.mem.Allocator) ![]u16 {
    var indices = try allocator.alloc(u16, 36);
    const tris = [_][3]u16{
        .{ 0, 1, 2 }, .{ 0, 2, 3 },   // back
        .{ 4, 5, 6 }, .{ 4, 6, 7 },   // front
        .{ 8, 9, 10 }, .{ 8, 10, 11 }, // left
        .{ 12, 13, 14 }, .{ 12, 14, 15 }, // right
        .{ 16, 17, 18 }, .{ 16, 18, 19 }, // bottom
        .{ 20, 21, 22 }, .{ 20, 22, 23 }, // top
    };
    for (tris, 0..) |tri, i| {
        indices[i * 3] = tri[0];
        indices[i * 3 + 1] = tri[1];
        indices[i * 3 + 2] = tri[2];
    }
    return indices;
}

/// Total expanded cell count for s=5 → s=7.
pub fn expandedCellCount() usize {
    return E0_NODE_COUNT * SEED_EXPANSION_FACTOR;
}

/// Compression ratio: s=7 full grid vs s=5 seed expansion.
/// Full s=7: 1920³ = 7,077,888,000 nodes.
/// Seed: 421 × 64 = 26,944 cells.
/// Ratio: 7,077,888,000 / 26,944 = 262,683:1
pub fn seedCompressionRatio() u64 {
    const full_s7: u64 = 1920 * 1920 * 1920;
    const seed_cells: u64 = E0_NODE_COUNT * SEED_EXPANSION_FACTOR;
    return full_s7 / seed_cells;
}

// =============================================================================
// LOD: Level of detail selection based on lattice level
// =============================================================================

pub const LODLevel = enum {
    point,
    cube,
    voxel,
    ray_march,
};

/// Selects LOD based on lattice level s.
/// s=0-2: point, s=3-4: cube, s=5-6: voxel, s=7+: ray-march
pub fn selectLOD(level: u8) LODLevel {
    return switch (level) {
        0, 1, 2 => .point,
        3, 4 => .cube,
        5, 6 => .voxel,
        else => .ray_march,
    };
}

// =============================================================================
// Render Governor: binary mode (continuous/idle) with ref-counted holds
// Ported from gods-eye-view/src/renderGovernor.js
// =============================================================================

pub const RenderMode = enum { continuous, idle };

pub const RenderRequestRecord = struct {
    reason: []const u8,
    at_ms: u64,
};

pub const RenderGovernor = struct {
    allocator: std.mem.Allocator,
    installed: bool = false,
    holds: std.StringHashMap(void),
    recent_requests: std.ArrayList(RenderRequestRecord),
    mode: RenderMode = .idle,
    /// Monotonic clock for request timestamps.
    clock_ms: u64 = 0,

    const RECENT_REQUEST_CAP: usize = 16;

    pub fn init(allocator: std.mem.Allocator) RenderGovernor {
        return .{
            .allocator = allocator,
            .holds = std.StringHashMap(void).init(allocator),
            .recent_requests = std.ArrayList(RenderRequestRecord).init(allocator),
        };
    }

    pub fn deinit(self: *RenderGovernor) void {
        // Free duplicated owner keys
        var it = self.holds.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.holds.deinit();
        // Free reason strings in recent requests
        for (self.recent_requests.items) |req| {
            self.allocator.free(req.reason);
        }
        self.recent_requests.deinit();
    }

    /// Install the governor. Idempotent.
    pub fn install(self: *RenderGovernor) void {
        self.installed = true;
        self.applyMode();
    }

    /// Uninstall the governor (for testing).
    pub fn uninstall(self: *RenderGovernor) void {
        self.installed = false;
    }

    /// Register a continuous-render hold. Idempotent per owner.
    pub fn holdContinuous(self: *RenderGovernor, owner_id: []const u8) !void {
        if (owner_id.len == 0) return;
        if (!self.holds.contains(owner_id)) {
            const key = try self.allocator.dupe(u8, owner_id);
            try self.holds.put(key, {});
        }
        self.applyMode();
    }

    /// Release a hold. Safe when never held.
    pub fn releaseContinuous(self: *RenderGovernor, owner_id: []const u8) void {
        if (owner_id.len == 0) return;
        if (self.holds.fetchRemove(owner_id)) |kv| {
            self.allocator.free(kv.key);
        }
        self.applyMode();
    }

    /// One-shot render request for a discrete scene mutation.
    /// In continuous mode, this is a no-op. In idle mode, it records the request.
    pub fn requestRender(self: *RenderGovernor, reason: []const u8) !void {
        if (!self.installed) return;
        if (self.holds.count() == 0) {
            const reason_copy = try self.allocator.dupe(u8, reason);
            try self.recent_requests.append(.{
                .reason = reason_copy,
                .at_ms = self.clock_ms,
            });
            if (self.recent_requests.items.len > RECENT_REQUEST_CAP) {
                const oldest = self.recent_requests.orderedRemove(0);
                self.allocator.free(oldest.reason);
            }
        }
    }

    /// Advance the internal clock.
    pub fn tick(self: *RenderGovernor, dt_ms: u64) void {
        self.clock_ms +%= dt_ms;
    }

    /// Get the current render mode.
    pub fn currentMode(self: *const RenderGovernor) RenderMode {
        return self.mode;
    }

    /// Check if a specific owner has an active hold.
    pub fn hasHold(self: *const RenderGovernor, owner_id: []const u8) bool {
        return self.holds.contains(owner_id);
    }

    /// Number of active holds.
    pub fn holdCount(self: *const RenderGovernor) usize {
        return self.holds.count();
    }

    /// Get recent render request reasons (for diagnostics).
    pub fn recentRequestReasons(self: *const RenderGovernor, allocator: std.mem.Allocator) ![][]const u8 {
        var result = try allocator.alloc([]const u8, self.recent_requests.items.len);
        for (self.recent_requests.items, 0..) |req, i| {
            result[i] = req.reason;
        }
        return result;
    }

    /// Reset all state (for testing).
    pub fn reset(self: *RenderGovernor) void {
        var it = self.holds.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.holds.clearRetainingCapacity();
        for (self.recent_requests.items) |req| {
            self.allocator.free(req.reason);
        }
        self.recent_requests.clearRetainingCapacity();
        self.installed = false;
        self.mode = .idle;
        self.clock_ms = 0;
    }

    /// Apply the current mode based on holds count.
    fn applyMode(self: *RenderGovernor) void {
        if (!self.installed) return;
        const should_be_continuous = self.holds.count() > 0;
        const new_mode: RenderMode = if (should_be_continuous) .continuous else .idle;
        if (new_mode == self.mode) return;
        self.mode = new_mode;
        // When entering idle, we would request one settling frame.
        // In the Zig renderer, this is handled by the engine's render loop.
    }
};

// =============================================================================
// Cockpit Math: slew-limited heading, ground-safe height, compass utilities
// Ported from gods-eye-view/src/cockpitMath.js
// =============================================================================

/// Normalize a heading into [0, 360) range.
pub fn normalizeHeading(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return @mod(@mod(value, 360.0) + 360.0, 360.0);
}

/// Advance a displayed heading along the shortest arc without exceeding a slew rate.
pub fn slewHeading(current: f32, target: f32, max_step_deg: f32) f32 {
    const from = normalizeHeading(current);
    const to = normalizeHeading(target);
    if (!std.math.isFinite(max_step_deg) or max_step_deg <= 0) return from;
    const delta = @mod(to - from + 540.0, 360.0) - 180.0;
    const step = std.math.clamp(delta, -max_step_deg, max_step_deg);
    return normalizeHeading(from + step);
}

/// Keep the camera above the ground surface.
pub fn groundSafeHeight(proposed: f32, ground: f32, clearance: f32) f32 {
    if (!std.math.isFinite(proposed)) return proposed;
    if (!std.math.isFinite(ground)) return proposed;
    const clr = if (std.math.isFinite(clearance)) @max(0.0, clearance) else 0.0;
    return @max(proposed, ground + clr);
}

/// Return whether a throttled UI update is due.
pub fn uiUpdateDue(now_ms: u64, last_update_ms: u64, interval_ms: u64) bool {
    if (interval_ms == 0) return false;
    if (last_update_ms == 0 or now_ms < last_update_ms) return true;
    return now_ms - last_update_ms >= interval_ms;
}

/// Return whether a surface wait window has elapsed.
pub fn surfaceWaitExpired(now_ms: u64, started_ms: u64, timeout_ms: u64) bool {
    return now_ms - started_ms >= timeout_ms;
}

/// Format a compass heading as a cardinal/intercardinal label.
pub fn formatCompassLabel(heading: f32) []const u8 {
    const normalized = normalizeHeading(heading);
    const labels = [_]struct { deg: f32, label: []const u8 }{
        .{ .deg = 0, .label = "N" },
        .{ .deg = 45, .label = "NE" },
        .{ .deg = 90, .label = "E" },
        .{ .deg = 135, .label = "SE" },
        .{ .deg = 180, .label = "S" },
        .{ .deg = 225, .label = "SW" },
        .{ .deg = 270, .label = "W" },
        .{ .deg = 315, .label = "NW" },
    };
    for (labels) |l| {
        // Compute shortest angular distance (handles wraparound)
        var diff = @abs(normalized - l.deg);
        if (diff > 180.0) diff = 360.0 - diff;
        if (diff < 22.5) return l.label;
    }
    return "---";
}

/// Choose a readable altitude-tape interval for the current flight level.
pub fn altitudeRulerStep(altitude_ft: f32) f32 {
    if (!std.math.isFinite(altitude_ft)) return 500;
    const alt = @max(0.0, altitude_ft);
    if (alt < 5000) return 100;
    if (alt < 15000) return 250;
    return 500;
}

// =============================================================================
// Tests
// =============================================================================

test "Vec3 basic operations" {
    const a = Vec3.new(1, 2, 3);
    const b = Vec3.new(4, 5, 6);
    const sum = Vec3.add(a, b);
    try std.testing.expectEqual(@as(f32, 5), sum.x);
    try std.testing.expectEqual(@as(f32, 7), sum.y);
    try std.testing.expectEqual(@as(f32, 9), sum.z);

    const cross = Vec3.cross(a, b);
    try std.testing.expectEqual(@as(f32, -3), cross.x);
    try std.testing.expectEqual(@as(f32, 6), cross.y);
    try std.testing.expectEqual(@as(f32, -3), cross.z);
}

test "Mat4 perspective produces valid matrix" {
    const m = Mat4.perspective(60.0 * std.math.pi / 180.0, 16.0 / 9.0, 0.1, 1000.0);
    try std.testing.expect(m.m[0] != 0);
    try std.testing.expect(m.m[5] != 0);
    try std.testing.expect(m.m[10] != 0);
}

test "Mat4 invert identity" {
    const m = Mat4.identity();
    const inv = m.invert();
    try std.testing.expectApproxEqAbs(@as(f32, 1), inv.m[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), inv.m[5], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), inv.m[10], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), inv.m[15], 1e-5);
}

test "scene graph create and parent" {
    const allocator = std.testing.allocator;
    var scene = Scene.init(allocator);
    defer scene.deinit();

    const parent = try scene.createEntity("parent");
    const child = try scene.createEntity("child");
    try scene.addChild(parent, child);

    const child_entity = scene.getEntity(child).?;
    try std.testing.expectEqual(parent, child_entity.parent.?);
    try std.testing.expectEqual(@as(u32, 1), child_entity.transform.depth_order);
}

test "scene graph update transforms" {
    const allocator = std.testing.allocator;
    var scene = Scene.init(allocator);
    defer scene.deinit();

    const parent_id = try scene.createEntity("parent");
    const parent = scene.getEntity(parent_id).?;
    parent.transform.local_pos = Vec3.new(10, 0, 0);
    parent.transform.dirty = true;

    const child_id = try scene.createEntity("child");
    try scene.addChild(parent_id, child_id);
    const child = scene.getEntity(child_id).?;
    child.transform.local_pos = Vec3.new(0, 5, 0);
    child.transform.dirty = true;

    scene.updateTransforms();

    try std.testing.expectApproxEqAbs(@as(f32, 10), parent.transform.world_matrix.m[12], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), child.transform.world_matrix.m[12], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), child.transform.world_matrix.m[13], 1e-5);
}

test "render graph topological sort" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const depth = try graph.addPass("Depth", .pre_depth);
    const color = try graph.addPass("Color", .color);
    const post = try graph.addPass("Post", .post);

    try graph.addWrite(depth, "depth_buffer");
    try graph.addRead(color, "depth_buffer");
    try graph.addWrite(color, "color_buffer");
    try graph.addRead(post, "color_buffer");
    try graph.addWrite(post, "post_buffer");

    try graph.compile();

    const order = graph.getCompiledOrder();
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqual(depth, order[0]);
    try std.testing.expectEqual(color, order[1]);
    try std.testing.expectEqual(post, order[2]);
}

test "render graph cycle detection" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const a = try graph.addPass("A", .color);
    const b = try graph.addPass("B", .color);

    try graph.addWrite(a, "res1");
    try graph.addRead(b, "res1");
    try graph.addWrite(b, "res2");
    try graph.addRead(a, "res2");

    try std.testing.expectError(error.CyclicDependency, graph.compile());
}

test "engine forward pipeline setup" {
    const allocator = std.testing.allocator;
    var engine = Engine.init(allocator, .{});
    defer engine.deinit();

    try engine.setupForwardPipeline();

    const order = engine.graph.getCompiledOrder();
    try std.testing.expect(order.len > 0);
}

test "lattice torus vertices" {
    const allocator = std.testing.allocator;
    const vertices = try latticeTorusVertices(allocator, 0);
    defer allocator.free(vertices);

    try std.testing.expectEqual(@as(usize, 64 * 32), vertices.len);
}

test "LOD selection by lattice level" {
    try std.testing.expectEqual(LODLevel.point, selectLOD(0));
    try std.testing.expectEqual(LODLevel.point, selectLOD(2));
    try std.testing.expectEqual(LODLevel.cube, selectLOD(3));
    try std.testing.expectEqual(LODLevel.cube, selectLOD(4));
    try std.testing.expectEqual(LODLevel.voxel, selectLOD(5));
    try std.testing.expectEqual(LODLevel.voxel, selectLOD(6));
    try std.testing.expectEqual(LODLevel.ray_march, selectLOD(7));
}

test "camera perspective projection" {
    var cam = Camera{
        .base = .{ .type = .camera, .entity = 0 },
        .fov = 90.0,
        .aspect = 2.0,
        .near = 1.0,
        .far = 100.0,
    };
    cam.updateProjection();
    try std.testing.expect(cam.projection.m[0] != 0);
    try std.testing.expect(cam.projection.m[5] != 0);
}

test "Smith chart: impedance to gamma (matched)" {
    const g = impedanceToGamma(50.0, 50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.r, 1e-5);
}

test "Smith chart: impedance to gamma (open circuit)" {
    const g = impedanceToGamma(1e9, 50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.r, 1e-3);
}

test "Smith chart: impedance to gamma (short circuit)" {
    const g = impedanceToGamma(0.0, 50.0);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), g.r, 1e-5);
}

test "Smith chart: complex impedance to gamma" {
    const g = impedanceComplexToGamma(50.0, 50.0, 50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), g.gr, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), g.gi, 1e-4);
}

test "Smith chart: complex impedance matched (no reactance)" {
    const g = impedanceComplexToGamma(50.0, 0.0, 50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.gr, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.gi, 1e-5);
}

test "Smith chart: E0 activations to sail points" {
    var activations: [421][7]f32 = undefined;
    for (0..421) |i| {
        activations[i] = .{
            @as(f32, @floatFromInt(i % 7)) * 0.1,
            @as(f32, @floatFromInt(i % 5)) * 0.05,
            @as(f32, @floatFromInt(i % 3)) * 0.3,
            0.5, 0.3, 0.2, 0.1,
        };
    }
    const points = e0ActivationsToSailPoints(&activations);
    try std.testing.expectEqual(@as(usize, 6), points.len);

    for (points) |p| {
        try std.testing.expect(p.gamma_r >= -1.0 and p.gamma_r <= 1.0);
        try std.testing.expect(p.gamma_i >= -1.0 and p.gamma_i <= 1.0);
        try std.testing.expect(p.activation >= 0.0);
    }
}

test "Smith chart: unit sphere vertices" {
    const allocator = std.testing.allocator;
    const verts = try unitSphereVertices(allocator);
    defer allocator.free(verts);
    try std.testing.expectEqual(@as(usize, 24), verts.len);

    for (verts) |v| {
        const len = Vec3.length(v);
        try std.testing.expect(len > 0.5 and len < 1.0);
    }
}

test "Smith chart: unit sphere indices" {
    const allocator = std.testing.allocator;
    const indices = try unitSphereIndices(allocator);
    defer allocator.free(indices);
    try std.testing.expectEqual(@as(usize, 108), indices.len);
}

test "Smith chart: torus vertex counts" {
    try std.testing.expectEqual(@as(usize, 128 * 64), smithChartTorusVertexCount());
    try std.testing.expectEqual(@as(usize, 64 * 32), fusionTorusVertexCount());
}

test "Smith chart: uniform from sail points" {
    var points: [6]SailPoint = undefined;
    for (0..6) |i| {
        points[i] = .{
            .gamma_r = @as(f32, @floatFromInt(i)) * 0.1,
            .gamma_i = @as(f32, @floatFromInt(i)) * 0.05,
            .impedance = 50.0,
            .activation = 0.5,
        };
    }
    const uniform = SmithChartUniform.fromSailPoints(1.5, 10.0, 3.0, &points, 100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), uniform.time, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), uniform.major_radius, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), uniform.minor_radius, 1e-5);
    try std.testing.expectEqual(@as(u32, 6), uniform.num_sail_points);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), uniform.fusion_scale, 1e-5);
}

test "E0 seed expansion: cell count" {
    try std.testing.expectEqual(@as(usize, 421 * 64), expandedCellCount());
}

test "E0 seed expansion: expand all nodes" {
    const allocator = std.testing.allocator;
    var seed = E0SeedBuffer.empty();
    for (0..421) |i| {
        seed.nodes[i] = .{
            .x = @intCast(i % 15),
            .y = @intCast((i / 15) % 15),
            .z = @intCast((i / 225) % 15),
            .activation = fp.div(fp.fromInt(1), fp.fromInt(2)),
        };
    }
    const cells = try expandSeed(allocator, seed);
    defer allocator.free(cells);

    try std.testing.expectEqual(@as(usize, 421 * 64), cells.len);

    for (cells) |cell| {
        try std.testing.expect(cell.x >= -1.0 and cell.x <= 1.0);
        try std.testing.expect(cell.y >= -1.0 and cell.y <= 1.0);
        try std.testing.expect(cell.z >= -1.0 and cell.z <= 1.0);
        try std.testing.expect(cell.e_value >= 0 and cell.e_value <= 7);
    }
}

test "E0 seed expansion: single node" {
    var out: [64]ExpandedCell = undefined;
    const node = E0SeedNode{ .x = 7, .y = 7, .z = 7, .activation = fp.ONE };
    expandNode(node, 1920, 64, &out);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0].activation, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[63].activation, 1e-3);

    for (out) |cell| {
        try std.testing.expect(cell.e_value >= 0 and cell.e_value <= 7);
    }
}

test "E0 seed expansion: frustum culling" {
    const allocator = std.testing.allocator;
    var seed = E0SeedBuffer.empty();
    for (0..421) |i| {
        seed.nodes[i] = .{
            .x = @intCast(i % 15),
            .y = @intCast((i / 15) % 15),
            .z = @intCast((i / 225) % 15),
            .activation = fp.div(fp.fromInt(1), fp.fromInt(2)),
        };
    }
    const cells = try expandSeed(allocator, seed);
    defer allocator.free(cells);

    const cam_pos = Vec3.new(0, 0, 3);
    const cam_dir = Vec3.new(0, 0, -1);
    const visible = try frustumCull(allocator, cells, cam_pos, cam_dir, 90.0, 1.5);
    defer allocator.free(visible);

    try std.testing.expect(visible.len > 0);
    try std.testing.expect(visible.len <= cells.len);
}

test "E0 seed expansion: unit cube geometry" {
    const allocator = std.testing.allocator;
    const verts = try unitCubeVertices(allocator);
    defer allocator.free(verts);
    try std.testing.expectEqual(@as(usize, 24), verts.len);

    const indices = try unitCubeIndices(allocator);
    defer allocator.free(indices);
    try std.testing.expectEqual(@as(usize, 36), indices.len);
}

test "E0 seed expansion: compression ratio" {
    const ratio = seedCompressionRatio();
    try std.testing.expect(ratio > 200_000);
    try std.testing.expect(ratio < 300_000);
}

// =============================================================================
// Render Governor tests
// =============================================================================

test "render governor: initial state is idle and not installed" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    try std.testing.expectEqual(RenderMode.idle, gov.currentMode());
    try std.testing.expect(!gov.installed);
    try std.testing.expectEqual(@as(usize, 0), gov.holdCount());
}

test "render governor: hold switches to continuous mode" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("flights");
    try std.testing.expectEqual(RenderMode.continuous, gov.currentMode());
    try std.testing.expect(gov.hasHold("flights"));
    try std.testing.expectEqual(@as(usize, 1), gov.holdCount());
}

test "render governor: release switches back to idle" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("traffic");
    try std.testing.expectEqual(RenderMode.continuous, gov.currentMode());
    gov.releaseContinuous("traffic");
    try std.testing.expectEqual(RenderMode.idle, gov.currentMode());
    try std.testing.expect(!gov.hasHold("traffic"));
}

test "render governor: double hold is idempotent" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("flights");
    try gov.holdContinuous("flights");
    try std.testing.expectEqual(@as(usize, 1), gov.holdCount());
}

test "render governor: release without hold is safe" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    gov.releaseContinuous("nonexistent");
    try std.testing.expectEqual(@as(usize, 0), gov.holdCount());
    try std.testing.expectEqual(RenderMode.idle, gov.currentMode());
}

test "render governor: multiple holds keep continuous until all released" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("flights");
    try gov.holdContinuous("traffic");
    try gov.holdContinuous("style-anim");
    try std.testing.expectEqual(RenderMode.continuous, gov.currentMode());
    try std.testing.expectEqual(@as(usize, 3), gov.holdCount());

    gov.releaseContinuous("flights");
    try std.testing.expectEqual(RenderMode.continuous, gov.currentMode());
    try std.testing.expectEqual(@as(usize, 2), gov.holdCount());

    gov.releaseContinuous("traffic");
    gov.releaseContinuous("style-anim");
    try std.testing.expectEqual(RenderMode.idle, gov.currentMode());
}

test "render governor: requestRender records in idle mode" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.requestRender("layer-tick");
    try gov.requestRender("slider-change");
    const reasons = try gov.recentRequestReasons(std.testing.allocator);
    defer std.testing.allocator.free(reasons);
    try std.testing.expectEqual(@as(usize, 2), reasons.len);
    try std.testing.expectEqualStrings("layer-tick", reasons[0]);
    try std.testing.expectEqualStrings("slider-change", reasons[1]);
}

test "render governor: requestRender is no-op in continuous mode" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("flights");
    try gov.requestRender("layer-tick");
    const reasons = try gov.recentRequestReasons(std.testing.allocator);
    defer std.testing.allocator.free(reasons);
    try std.testing.expectEqual(@as(usize, 0), reasons.len);
}

test "render governor: requestRender is no-op when not installed" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    try gov.requestRender("test");
    const reasons = try gov.recentRequestReasons(std.testing.allocator);
    defer std.testing.allocator.free(reasons);
    try std.testing.expectEqual(@as(usize, 0), reasons.len);
}

test "render governor: recent requests capped at 16" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    for (0..20) |i| {
        const reason = try std.fmt.allocPrint(std.testing.allocator, "req-{d}", .{i});
        defer std.testing.allocator.free(reason);
        try gov.requestRender(reason);
    }
    const reasons = try gov.recentRequestReasons(std.testing.allocator);
    defer std.testing.allocator.free(reasons);
    try std.testing.expectEqual(@as(usize, 16), reasons.len);
    // Should keep the most recent 16 (req-4 through req-19)
    try std.testing.expectEqualStrings("req-4", reasons[0]);
    try std.testing.expectEqualStrings("req-19", reasons[15]);
}

test "render governor: tick advances clock" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.tick(100);
    gov.tick(200);
    try std.testing.expectEqual(@as(u64, 300), gov.clock_ms);
}

test "render governor: reset clears all state" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("flights");
    try gov.requestRender("test");
    gov.reset();
    try std.testing.expect(!gov.installed);
    try std.testing.expectEqual(@as(usize, 0), gov.holdCount());
    try std.testing.expectEqual(RenderMode.idle, gov.currentMode());
}

test "render governor: empty owner_id is ignored" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    gov.install();
    try gov.holdContinuous("");
    try std.testing.expectEqual(@as(usize, 0), gov.holdCount());
    gov.releaseContinuous("");
    // Should not crash
}

test "render governor: hold before install applies on install" {
    var gov = RenderGovernor.init(std.testing.allocator);
    defer gov.deinit();
    try gov.holdContinuous("flights");
    try std.testing.expectEqual(RenderMode.idle, gov.currentMode()); // Not installed yet
    gov.install();
    try std.testing.expectEqual(RenderMode.continuous, gov.currentMode());
}

// =============================================================================
// Cockpit Math tests
// =============================================================================

test "cockpit math: normalizeHeading" {
    try std.testing.expectEqual(@as(f32, 0), normalizeHeading(0));
    try std.testing.expectEqual(@as(f32, 90), normalizeHeading(90));
    try std.testing.expectEqual(@as(f32, 0), normalizeHeading(360));
    try std.testing.expectEqual(@as(f32, 270), normalizeHeading(-90));
    try std.testing.expectEqual(@as(f32, 180), normalizeHeading(540));
}

test "cockpit math: normalizeHeading NaN returns 0" {
    try std.testing.expectEqual(@as(f32, 0), normalizeHeading(std.math.nan(f32)));
}

test "cockpit math: slewHeading shortest arc" {
    // Moving from 350 to 10 should go through 0 (shortest arc = +20)
    const result = slewHeading(350, 10, 15);
    try std.testing.expect(result > 350 or result < 20);
}

test "cockpit math: slewHeading respects max step" {
    // 0 to 90 with max step 10 should give 10
    const result = slewHeading(0, 90, 10);
    try std.testing.expectEqual(@as(f32, 10), result);
}

test "cockpit math: slewHeading zero max step returns current" {
    const result = slewHeading(45, 90, 0);
    try std.testing.expectEqual(@as(f32, 45), result);
}

test "cockpit math: groundSafeHeight enforces clearance" {
    const result = groundSafeHeight(100, 200, 50);
    try std.testing.expectEqual(@as(f32, 250), result);
}

test "cockpit math: groundSafeHeight preserves proposed when above ground" {
    const result = groundSafeHeight(500, 100, 50);
    try std.testing.expectEqual(@as(f32, 500), result);
}

test "cockpit math: groundSafeHeight NaN ground preserves proposed" {
    const result = groundSafeHeight(300, std.math.nan(f32), 50);
    try std.testing.expectEqual(@as(f32, 300), result);
}

test "cockpit math: uiUpdateDue returns true on first call" {
    try std.testing.expect(uiUpdateDue(1000, 0, 500));
}

test "cockpit math: uiUpdateDue returns false within interval" {
    try std.testing.expect(!uiUpdateDue(1300, 1000, 500));
}

test "cockpit math: uiUpdateDue returns true after interval" {
    try std.testing.expect(uiUpdateDue(1500, 1000, 500));
}

test "cockpit math: surfaceWaitExpired" {
    try std.testing.expect(surfaceWaitExpired(6000, 1000, 5000));
    try std.testing.expect(!surfaceWaitExpired(4000, 1000, 5000));
}

test "cockpit math: formatCompassLabel" {
    try std.testing.expectEqualStrings("N", formatCompassLabel(0));
    try std.testing.expectEqualStrings("E", formatCompassLabel(90));
    try std.testing.expectEqualStrings("S", formatCompassLabel(180));
    try std.testing.expectEqualStrings("W", formatCompassLabel(270));
    try std.testing.expectEqualStrings("NE", formatCompassLabel(45));
    try std.testing.expectEqualStrings("N", formatCompassLabel(350)); // Close to N
}

test "cockpit math: altitudeRulerStep" {
    try std.testing.expectEqual(@as(f32, 100), altitudeRulerStep(1000));
    try std.testing.expectEqual(@as(f32, 250), altitudeRulerStep(10000));
    try std.testing.expectEqual(@as(f32, 500), altitudeRulerStep(20000));
    try std.testing.expectEqual(@as(f32, 500), altitudeRulerStep(std.math.nan(f32)));
}
