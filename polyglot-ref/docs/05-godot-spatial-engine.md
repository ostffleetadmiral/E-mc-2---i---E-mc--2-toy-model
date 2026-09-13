# 05 — Godot Spatial Engine (`godot/`)

## Architecture Overview

### Purpose

The Godot module provides the spatial rendering and interaction layer for FANO-1 OS. It bridges Godot 4's rendering pipeline with Q128.128 fixed-point math, replacing all double-precision floats with deterministic 256-bit arithmetic. The module implements three core systems: GDExtension type registration, 3D Gaussian Splatting clouds, and Infinite Corridors as a recursive spatial database.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `gdextension.zig` | 320 | Q128.128 types for Godot: Vector3Q, QuatQ, TransformQ, Variant interop |
| `gaussian_splat.zig` | 359 | 3D Gaussian ellipsoid clouds with Q128.128 coordinates, spatial filtering |
| `corridor.zig` | 376 | Infinite Corridor: recursive 6-directional address space (6^N nodes) |
| `scene_bridge.zig` | 347 | Scene tree control bridge: JSON command protocol for Space Agent |
| `build.zig` | 55 | Build system: test targets |

### Dependencies

- **Internal**: `q128_128` module (from `../zig/q128_128.zig`)
- **External**: None (pure Zig; Godot C ABI linked at runtime)

### Design Principles

1. **Q128.128 everywhere**: All spatial coordinates, transforms, and covariance matrices use `q128` fixed-point. Float conversion (`q128ToF64`/`f64ToQ128`) is lossy and used only for GPU rendering output.
2. **Deterministic geometry**: Vector operations (add, sub, scale, dot, length) use exact Q128.128 arithmetic — no floating-point drift across hardware.
3. **Recursive address space**: Infinite Corridors provide 6^N addressable segments, making the 3D scene itself a database.
4. **JSON command protocol**: Space Agent communicates scene modifications via serialized JSON commands over WebSockets.

---

## API Reference

### `gdextension.zig`

#### Types

```zig
pub const Vector3Q = struct {
    x: q128, y: q128, z: q128,
    // Methods: zero(), one(), add(), sub(), scale(), dot(), lengthSq(), eql()
    // Conversions: toFloat3() -> [3]f64, fromFloat3([3]f64) -> Vector3Q
};

pub const QuatQ = struct {
    x: q128, y: q128, z: q128, w: q128,
    // Methods: identity(), eql()
};

pub const TransformQ = struct {
    basis: [3][3]q128,
    origin: Vector3Q,
    // Methods: identity(), translate(), applyPoint(), eql()
};

pub const VariantType = enum(u8) {
    nil = 0, bool_ = 1, int_ = 2, float_ = 3, string = 4,
    vector3q = 100, quatq = 101, transformq = 102, gaussian_splat = 103,
};
```

#### Conversion Functions

```zig
pub fn q128ToF64(v: q128) f64    // Lossy: for rendering only
pub fn f64ToQ128(f: f64) q128    // Lossy: for input only
pub fn packVector3Q(v: Vector3Q) [96]u8   // 3×(16+16) bytes, little-endian
pub fn unpackVector3Q(buf: []const u8) !Vector3Q
```

#### Test Coverage (14 tests)

| Test | Description |
|------|-------------|
| `Vector3Q zero and one` | Identity vectors |
| `Vector3Q add and sub` | Component-wise arithmetic |
| `Vector3Q scale` | Scalar multiplication |
| `Vector3Q dot product` | Inner product |
| `Vector3Q lengthSq` | Squared magnitude |
| `Vector3Q eql` | Equality comparison |
| `QuatQ identity` | Identity quaternion |
| `TransformQ identity` | Identity transform |
| `TransformQ translate` | Origin translation |
| `TransformQ applyPoint` | Point transformation with translation |
| `TransformQ eql` | Transform equality |
| `pack/unpack round-trip` | Serialization round-trip |
| `q128ToF64/f64ToQ128` | Float conversion round-trip |
| `VariantType enum` | Custom type tag values |

---

### `gaussian_splat.zig`

#### Types

```zig
pub const Splat = struct {
    position: Vector3Q,           // Center in Q128.128 world space
    cov_xx, cov_yy, cov_zz: q128, // Diagonal covariance
    cov_xy, cov_xz, cov_yz: q128, // Off-diagonal covariance
    opacity: q128,                // [0, 1] in Q128.128
    color_r, color_g, color_b: u8, // RGB [0, 255]
    // Methods: default(), serialize() -> [132]u8
};

pub const SplatCloud = struct {
    splats: ArrayList(Splat),
    // Methods: init(), deinit(), count(), add(), get(), remove(),
    //          boundingBox(), filterInRange(), merge(), serialize(), deserialize()
};
```

#### Key Functions

```zig
pub fn generateGrid(alloc: Allocator, n: u32) !SplatCloud  // n³ splat grid
```

#### Spatial Operations

- **boundingBox**: Computes min/max Q128.128 bounds across all splats
- **filterInRange**: Frustum culling — returns splats within a Q128.128 bounding box
- **merge**: Combines two clouds (appendSlice)
- **serialize/deserialize**: Binary format: `[8-byte count][132-byte splat × N]`

#### Test Coverage (10 tests)

| Test | Description |
|------|-------------|
| `Splat default` | Default splat at origin, spherical covariance |
| `SplatCloud add and count` | Append + count |
| `SplatCloud get and remove` | Index access + swapRemove |
| `SplatCloud boundingBox` | Min/max bounds |
| `SplatCloud boundingBox empty` | Zero splats → zero bounds |
| `SplatCloud filterInRange` | Bounding box filter |
| `SplatCloud merge` | Cloud combination |
| `SplatCloud serialize/deserialize` | Binary round-trip |
| `generateGrid n³` | Grid generation produces n³ splats |
| `generateGrid boundingBox` | Grid bounds correct |

---

### `corridor.zig`

#### Types

```zig
pub const Direction = enum(u3) { north, south, east, west, up, down };

pub const CorridorAddress = struct {
    path: []Direction,  // Path from root
    // Methods: depth(), parent(), child(), isRoot(), eql(), toString(), fromString(), hash()
};

pub const CorridorSegment = struct {
    address: CorridorAddress,
    world_position: Vector3Q,
    world_rotation: QuatQ,
    data_hash: [32]u8,
    data_size: u64,
    child_count: u6,
};

pub const InfiniteCorridor = struct {
    segments: AutoHashMap(u64, CorridorSegment),
    // Methods: init(), deinit(), count(), insert(), lookup(), exists(), remove(), walkPath()
};
```

#### Address Space

- **6-directional**: N/S/E/W/U/D — each segment has 6 children
- **Total addressable space**: 6^N for depth N (1, 6, 36, 216, 1296, ...)
- **World position**: Accumulated unit vectors along path (Q128.128 exact)
- **Hashing**: Wyhash of direction bytes for HashMap key

#### Key Functions

```zig
pub fn computeWorldPosition(addr: CorridorAddress) Vector3Q  // Sum of unit vectors
pub fn addressSpaceSize(depth: u32) u64  // 6^depth
```

#### Test Coverage (15 tests)

| Test | Description |
|------|-------------|
| `CorridorAddress root` | Empty path = root |
| `child and parent` | Hierarchy navigation |
| `eql` | Address comparison |
| `toString/fromString` | String round-trip ("NESWUD") |
| `fromString rejects invalid` | Bad direction chars |
| `hash deterministic` | Same path → same hash |
| `hash differs` | Different paths → different hashes |
| `computeWorldPosition root` | Origin = (0,0,0) |
| `computeWorldPosition north` | N → (0,1,0) |
| `computeWorldPosition NNE` | N+N+E → (1,2,0) |
| `addressSpaceSize` | 6^0=1, 6^1=6, 6^2=36, 6^3=216 |
| `InfiniteCorridor insert/lookup` | Segment storage |
| `InfiniteCorridor remove` | Segment deletion |
| `InfiniteCorridor count` | Segment counting |

---

### `scene_bridge.zig`

#### Types

```zig
pub const OpType = enum(u8) {
    add_node, remove_node, move_node, set_property, set_transform,
    set_visible, load_scene, save_scene, call_method, connect_signal,
};

pub const SceneCommand = struct {
    op: OpType,
    node_path: []const u8,
    node_type, property_name, property_value: []const u8,
    transform: ?TransformQ,
    visible: bool,
    method_name, signal_name, target_node, target_method: []const u8,
    // Method: toJson() -> []u8
};

pub const CommandQueue = struct {
    commands: ArrayList(SceneCommand),
    // Methods: init(), deinit(), enqueue(), dequeue(), count(), toJsonArray(), clear()
};

pub const SceneTreeState = struct {
    nodes: StringHashMap(NodeInfo),
    // Methods: init(), deinit(), addNode(), removeNode(), getNode(), nodeCount(),
    //          setTransform(), setVisible()
};
```

#### Key Functions

```zig
pub fn applyCommand(state: *SceneTreeState, cmd: SceneCommand) !void
pub fn opName(op: OpType) []const u8
```

#### Protocol

Commands serialized as JSON, transmitted over WebSockets to a local daemon that applies them to the live Godot scene tree. The `SceneTreeState` mirrors the Godot scene tree locally for validation and tracking.

#### Test Coverage (12 tests)

| Test | Description |
|------|-------------|
| `opName` | Enum → string mapping |
| `SceneCommand toJson add_node` | JSON serialization with node type |
| `SceneCommand toJson set_visible` | JSON with boolean |
| `CommandQueue enqueue/dequeue` | FIFO queue |
| `CommandQueue toJsonArray` | Array serialization |
| `CommandQueue clear` | Queue reset |
| `SceneTreeState addNode/getNode` | Node registration |
| `SceneTreeState removeNode` | Node deletion |
| `SceneTreeState setTransform/setVisible` | Property updates |
| `applyCommand add_node` | Command application |
| `applyCommand remove_node` | Command application |
| `applyCommand set_visible` | Command application |

---

## Build Configuration (`build.zig`)

### Test Targets

| Name | Source | Description |
|------|--------|-------------|
| `test-gdextension` | `gdextension.zig` | Q128.128 Godot types |
| `test-gaussian-splat` | `gaussian_splat.zig` | Splat clouds |
| `test-corridor` | `corridor.zig` | Infinite corridors |
| `test-scene-bridge` | `scene_bridge.zig` | Scene tree control |

### Build Commands

```bash
cd godot/ && zig build test
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Fixed-point arithmetic for all spatial math
- **Space Agent** (`space-agent/`): WebSocket client for scene_bridge commands
- **Quine HTML** (`quine.html/`): Web-based rendering alternative
- **VFS Interceptor** (`vfs/`): Folded models rendered as Gaussian splats
- **ISG Transcoder** (`isg/`): RGB video data as splat textures
