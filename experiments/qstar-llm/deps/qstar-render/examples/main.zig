//! Qstar-Render Example — Vec3 math, Mat4 transforms, ECS, render graph.

const std = @import("std");
const render = @import("render");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Render — WebGPU Rendering Engine\n", .{});
    try stdout.print("=======================================\n\n", .{});

    // Vec3 math
    try stdout.print("Vector Math:\n", .{});
    const v1 = render.Vec3.new(1.0, 2.0, 3.0);
    const v2 = render.Vec3.new(4.0, 5.0, 6.0);
    const sum = render.Vec3.add(v1, v2);
    try stdout.print("  v1 + v2 = ({d:.1}, {d:.1}, {d:.1})\n", .{ sum.x, sum.y, sum.z });
    const cross = render.Vec3.cross(v1, v2);
    try stdout.print("  v1 × v2 = ({d:.1}, {d:.1}, {d:.1})\n", .{ cross.x, cross.y, cross.z });
    const dist = render.Vec3.distance(v1, v2);
    try stdout.print("  |v1 - v2| = {d:.4}\n", .{dist});

    // Mat4 transforms
    try stdout.print("\nMatrix Transforms:\n", .{});
    const proj = render.Mat4.perspective(60.0, 16.0 / 9.0, 0.1, 100.0);
    try stdout.print("  Perspective projection created (FOV=60°)\n", .{});
    const trans = render.Mat4.translation(5.0, 0.0, 0.0);
    try stdout.print("  Translation matrix created (5,0,0)\n", .{});
    const mvp = render.Mat4.multiply(proj, trans);
    _ = mvp;
    try stdout.print("  MVP = proj × trans computed\n", .{});

    // Quaternion
    try stdout.print("\nQuaternion:\n", .{});
    const q = render.Quat.fromEuler(0.0, 90.0, 0.0);
    try stdout.print("  From Euler (0°, 90°, 0°): ({d:.4}, {d:.4}, {d:.4}, {d:.4})\n", .{ q.x, q.y, q.z, q.w });
    const rot = render.Mat4.rotation(q);
    _ = rot;
    try stdout.print("  Rotation matrix from quaternion computed\n", .{});

    // Scene
    try stdout.print("\nScene:\n", .{});
    var scene = render.Scene.init(allocator);
    defer scene.deinit();
    try stdout.print("  Scene created\n", .{});
    try stdout.print("  Entity type: EntityId = u32\n", .{});

    try stdout.print("\nShaders: render.wgsl, compute.wgsl included\n", .{});
    try stdout.print("\nDone.\n", .{});
}
