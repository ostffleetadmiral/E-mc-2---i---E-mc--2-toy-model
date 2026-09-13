# Qstar-VFS

Distributed virtual file system — LRU cache with pinning, access histogram, prefetch, trace recording, ring-buffer streaming, multi-node distributed storage with consistent hashing, replication, and quorum.

## Quick Start

```bash
zig build test          # 83 tests
zig build run           # cache + serialization + distributed demo
```

## Usage

```zig
const vfs = @import("vfs_bridge");

var bridge = vfs.VFSBridge.init(allocator);
defer bridge.deinit();

// Create and store a lattice page
const key = vfs.PageKey.init(0, 1, 2, 3);
var page = vfs.LatticePage.init(key, now_ms);
const bytes = try page.serialize(allocator);
const restored = try vfs.LatticePage.deserialize(bytes, now_ms);

// LRU cache with pinning
var cache = vfs.VFSCache.init(allocator, 256);
defer cache.deinit();
try cache.put(page);
const hit = cache.get(key, now_ms);
```

## API Reference

### VFSBridge (`vfs_bridge.zig`)

| Function | Description |
|----------|-------------|
| `VFSBridge.init(allocator)` | Create VFS bridge |
| `bridge.tick(dt_ms)` | Advance time |
| `bridge.saveAgentState(...)` | Save agent state to VFS |
| `bridge.loadAgentState(...)` | Load agent state from VFS |
| `bridge.hasAgentState()` | Check if agent state exists |
| `bridge.clearAgentState()` | Clear agent state |

### VFSCache (`vfs_bridge.zig`)

| Function | Description |
|----------|-------------|
| `VFSCache.init(allocator, capacity)` | Create LRU cache |
| `cache.put(page)` | Insert page |
| `cache.get(key, now_ms)` | Retrieve page (updates LRU) |
| `cache.pin(key)` | Pin page (prevent eviction) |
| `cache.unpin(key)` | Unpin page |
| `cache.hotPages(n)` | Get hottest pages |
| `cache.effectiveHitRate()` | Get hit rate |

### LatticePage (`vfs_bridge.zig`)

| Function | Description |
|----------|-------------|
| `LatticePage.init(key, now_ms)` | Create page |
| `page.serialize(allocator)` | Serialize to bytes |
| `LatticePage.deserialize(data, now_ms)` | Deserialize from bytes |

### VFS Distributed (`vfs_distributed.zig`)

| Constant | Value |
|----------|-------|
| `MAX_NODES` | 64 |
| `MAX_REPLICAS` | 4 |
| `HEARTBEAT_TIMEOUT_MS` | 5000 |

| Type | Description |
|------|-------------|
| `NodeRegistry` | Node management with status tracking |
| `ConsistencyLevel` | `one`, `quorum`, `all` |
| `Placement` | Replica placement strategy |

## Modules

| Module | Lines | Tests |
|--------|-------|-------|
| vfs_bridge.zig | 1,548 | 24 |
| vfs_streaming.zig | 539 | 15 |
| vfs_distributed.zig | 421 | 17 |
| fixed_point.zig | 677 | 27 |

**Total: ~3,185 lines, 83 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
