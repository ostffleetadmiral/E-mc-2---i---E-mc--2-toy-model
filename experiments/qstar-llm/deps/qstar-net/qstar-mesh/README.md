# Qstar-Mesh

P2P mesh networking stack — connection management with lattice location routing, interest synchronization, topology maintenance, phase locking, swarm fusion, TLS encryption (XChaCha20-Poly1305), multi-hop relay, peer discovery.

## Quick Start

```bash
zig build test          # 156 tests
zig build run           # connection manager + peer discovery + location demo
```

## Usage

```zig
const mesh = @import("mesh");
const p2p = @import("p2p_types");

// Connection manager
var cm = mesh.ConnectionManager.init(allocator, location, 25, 200, false);
defer cm.deinit();
try cm.addConnection(conn_id, peer_location);
try stdout.print("Connections: {d}\n", .{cm.connectionCount()});

// Peer manager
var pm = p2p.PeerManager.init(allocator);
defer pm.deinit();
pm.addPeer(peer_id, location, conn_id);
```

## API Reference

### Mesh (`mesh.zig`)

| Function | Description |
|----------|-------------|
| `Location.new(v)` | Create lattice location |
| `Location.distance(other)` | Distance to another location |
| `ConnectionManager.init(allocator, loc, min, max, gateway)` | Create connection manager |
| `cm.connectionCount()` | Get active connection count |
| `cm.isBelowMin()` | Check if below minimum connections |
| `cm.isAtMax()` | Check if at maximum connections |
| `cm.addConnection(id, loc)` | Add connection |
| `cm.removeConnection(id)` | Remove connection |

### P2P Types (`p2p_types.zig`)

| Type | Description |
|------|-------------|
| `PeerId` | 32-byte peer identifier |
| `Location` | u128 lattice location |
| `Peer` | Peer with distance, state, connection |
| `PeerManager` | Peer tracking and discovery |

| Function | Description |
|----------|-------------|
| `PeerManager.init(allocator)` | Create peer manager |
| `pm.addPeer(id, location, conn_id)` | Add peer |
| `pm.removePeer(conn_id)` | Remove peer by connection |
| `pm.getById(id)` | Find peer by ID |
| `pm.allPeers()` | Get all peers |

### Relay Router (`relay_router.zig`)

| Function | Description |
|----------|-------------|
| `RelayRouter.init(allocator, own_id)` | Create relay router |
| `router.handleRelayRoute(payload)` | Handle relay route request |
| `router.handleRendezvousReq(...)` | Handle rendezvous request |
| `router.buildRelayPacket(...)` | Build relay packet |
| `router.nextHopForTarget(target_id, exclude)` | Get next hop |

## Modules

| Module | Lines | Tests |
|--------|-------|-------|
| mesh.zig | 2,026 | 63 |
| p2p_types.zig | 934 | 38 |
| relay_router.zig | 763 | 23 |
| mesh_peer.zig | 705 | 5 |
| fixed_point.zig | 677 | 27 |

**Total: ~5,105 lines, 156 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
