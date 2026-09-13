# Qstar-Render

Zero-dependency WebGPU rendering engine — Forward+ pipeline, ECS, topological sort render graph, Smith chart torus, fusion reactor visualization, render governor. Includes WGSL shaders for rendering and compute.

## Quick Start

```bash
zig build test          # 82 tests
zig build run           # Vec3 + Mat4 + quaternion + ECS demo
```

## Usage

```zig
const render = @import("render");

// Vector math
const v = render.Vec3.new(1.0, 2.0, 3.0);
const len = render.Vec3.length(v);
const n = render.Vec3.normalize(v);

// Matrix transforms
const proj = render.Mat4.perspective(60.0, 16.0/9.0, 0.1, 100.0);
const trans = render.Mat4.translation(5.0, 0.0, 0.0);
const mvp = render.Mat4.multiply(proj, trans);

// Quaternion rotation
const q = render.Quat.fromEuler(0.0, 90.0, 0.0);
const rot = render.Mat4.rotation(q);

// ECS
var ecs = render.ECS.init(allocator);
defer ecs.deinit();
const entity = ecs.createEntity();
```

## API Reference

### Vector Math

| Function | Description |
|----------|-------------|
| `Vec3.new(x, y, z)` | Create 3D vector |
| `Vec3.add/sub(a, b)` | Vector addition/subtraction |
| `Vec3.scale(v, s)` | Scale vector |
| `Vec3.dot(a, b)` | Dot product |
| `Vec3.cross(a, b)` | Cross product |
| `Vec3.length(v)` | Vector length |
| `Vec3.normalize(v)` | Normalize vector |
| `Vec3.distance(a, b)` | Distance between vectors |

### Matrix Transforms

| Function | Description |
|----------|-------------|
| `Mat4.identity()` | Identity matrix |
| `Mat4.perspective(fov, aspect, near, far)` | Perspective projection |
| `Mat4.translation(x, y, z)` | Translation matrix |
| `Mat4.scaling(x, y, z)` | Scaling matrix |
| `Mat4.rotation(q)` | Rotation from quaternion |
| `Mat4.multiply(a, b)` | Matrix multiplication |
| `Mat4.invert(m)` | Matrix inverse |

### Quaternion

| Function | Description |
|----------|-------------|
| `Quat.identity()` | Identity quaternion |
| `Quat.fromEuler(x, y, z)` | From Euler angles |

### ECS

| Function | Description |
|----------|-------------|
| `ECS.init(allocator)` | Create ECS |
| `ecs.createEntity()` | Create entity |
| `ecs.entityCount()` | Get entity count |

## Modules

| Module | Lines | Tests |
|--------|-------|-------|
| render.zig | 1,928 | 27 |
| fixed_point.zig | 677 | 27 |
| shaders/render.wgsl | 618 | — |
| shaders/compute.wgsl | 477 | — |

**Total: ~3,700 lines, 82 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
