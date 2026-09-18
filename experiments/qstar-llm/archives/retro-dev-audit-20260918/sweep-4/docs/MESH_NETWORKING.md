# Mesh Networking & Virtual Transport

Qstar-LLM includes a complete virtualized mesh networking stack with 12 transport modes, civilizational collapse recovery, and headless over-the-air operation. All transport modes run as virtual channels over TCP — no physical media required.

---

## Architecture

```
┌──────────────────────────────────────────────┐
│              Virtual Transport Router          │
│         (virtual_transport.zig)                │
│   Selects transport mode, routes data over     │
│   virtual TCP channels                         │
├──────────────────────────────────────────────┤
│  VirtualMeshNode (TCP listener, port 9000)    │
│  • Peer discovery & connection management     │
│  • Store-and-forward queue for offline peers  │
│  • Broadcast to all connected peers           │
│  • X25519 key exchange + XChaCha20-Poly1305   │
├──────────────────────────────────────────────┤
│           12 Virtual Transport Modes           │
│  p2p → wifi → video → qr → polyglot → audio   │
│  → stega → paper → optar → paperback →         │
│    cassette → quine                            │
├──────────────────────────────────────────────┤
│  Mesh Protocol (mesh.zig, mesh_peer.zig)      │
│  • ConnectionManager, TransportRouter          │
│  • OfflineTransportRouter (fallback chain)     │
│  • LatticeCell — cellular mesh topology       │
├──────────────────────────────────────────────┤
│  Relay Router (relay_router.zig)              │
│  • Multi-hop relay routing                     │
│  • Rendezvous discovery                        │
├──────────────────────────────────────────────┤
│  NAT Traversal (nat.zig)                      │
│  • UDP hole punching                           │
│  • STUN client                                 │
│  • QR relay fallback                           │
├──────────────────────────────────────────────┤
│  Collapse Recovery (collapse.zig)             │
│  • QR portal encoding (virtualized)            │
│  • Recursive QR nesting (qr_nest.zig)          │
│  • Degraded mode: quine + paper + cassette    │
└──────────────────────────────────────────────┘
```

## Transport Modes

| Mode | Module | Description | Collapse Active |
|------|--------|-------------|:---:|
| p2p | transport_p2p.zig | X25519 + ChaCha20Poly1305 encrypted packet transport | No |
| wifi | transport_wifi.zig | WiFi CSI frame transport (virtualized as TCP frames) | No |
| video | transport_video.zig | Video frame transport | No |
| qr | transport_qr.zig | QR code transport | No |
| polyglot | transport_polyglot.zig | Multi-format polyglot file transport | No |
| audio | transport_audio.zig | Audio frame transport | No |
| stega | transport_stega.zig | LSB steganography transport (virtualized) | No |
| paper | transport_paperback.zig | Paperback book transport | Yes |
| optar | transport_optar.zig | Optical art transport | No |
| paperback | transport_paperback.zig | Paperback book transport | Yes |
| cassette | transport_cassette.zig | Cassette tape transport | Yes |
| quine | transport_quine.zig | Self-referential HTML quine transport | Yes |

### Fallback Chain

When a transport mode fails, the router degrades to the next available mode:

```
p2p → wifi → video → qr → polyglot → audio → stega → paper → optar → paperback → cassette → quine
```

During civilizational collapse simulation, only **quine**, **paper**, and **cassette** channels remain active — representing physical media that survives infrastructure failure.

## CLI Commands

### Mesh Commands

```bash
# Start a virtual mesh node (headless, listens on TCP port 9000)
qstar mesh start [port]

# Join an existing mesh network
qstar mesh join <host:port>

# Show mesh topology, peer count, transport modes
qstar mesh status

# Broadcast message to all connected peers
qstar mesh broadcast <msg>

# Multi-hop relay to specific peer
qstar mesh relay <peer> <msg>
```

### Transport Commands

```bash
# List available virtual transport modes
qstar transport list

# Send file via specific transport mode
qstar transport send <mode> <file>

# Listen for incoming transport payloads
qstar transport recv
```

### Collapse Commands

```bash
# Simulate civilization collapse (degrade transports to quine + paper + cassette)
qstar collapse simulate

# Show current transport fallback level
qstar collapse status

# Restore all transport modes from collapse
qstar collapse recover
```

### Seed Transport via QR Portals

The Q64.64 agent state (47 KB) can be compressed and transported via QR portals
for collapse scenarios:

```bash
# Compress agent state to seed file
zig build seed
# Output: zig-out/seed/qstar_seed.bin

# Embed seed in universe.html quine
zig build html
# The --seed flag is wired in build.zig; universe.html includes SEED_BASE64

# Transport seed via QR portals
qstar transport send qr zig-out/seed/qstar_seed.bin
```

The seed compression pipeline: Q64.64 state (47 KB) → holographic FFT encode →
gzip compress → QR portal pack (256-byte chunks). The seed can be reconstructed
from QR portals by reversing the pipeline.

## HTTP API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/mesh/status` | Mesh topology JSON (peers, transport, fallback level) |
| POST | `/api/mesh/join` | Join mesh network (host, port in JSON body) |
| GET | `/api/transport/list` | List available transport modes |
| POST | `/api/transport/send` | Send payload via transport mode (mode, payload in JSON body) |

### Example: Mesh Status

```bash
curl http://localhost:11435/api/mesh/status
```

```json
{
  "peer_id": "qstar-server",
  "listen_port": 9000,
  "peers": 0,
  "pending": 0,
  "transport": "p2p",
  "fallback_level": 0,
  "collapse_mode": false,
  "channels": [
    {"mode": "p2p", "active": true},
    {"mode": "wifi", "active": true},
    {"mode": "qr", "active": true},
    {"mode": "quine", "active": true},
    {"mode": "paper", "active": true},
    {"mode": "cassette", "active": true}
  ]
}
```

### Example: Join Mesh

```bash
curl -X POST http://localhost:11435/api/mesh/join \
  -H "Content-Type: application/json" \
  -d '{"host": "192.168.1.50", "port": 9000}'
```

```json
{
  "status": "joined",
  "peer": "192.168.1.50:9000",
  "transport": "p2p",
  "fallback_level": 0
}
```

### Example: Transport Send

```bash
curl -X POST http://localhost:11435/api/transport/send \
  -H "Content-Type: application/json" \
  -d '{"mode": "qr", "payload": "SGVsbG8gV29ybGQ="}'
```

```json
{
  "status": "sent",
  "mode": "qr",
  "bytes": 16,
  "delivered": true
}
```

## Modules

| Module | Lines | Role |
|--------|-------|------|
| virtual_transport.zig | 968 | Virtualized transport layer over TCP, VirtualMeshNode, VirtualTransportRouter |
| mesh.zig | 2,100 | ConnectionManager, TransportRouter, OfflineTransportRouter, LatticeCell |
| mesh_peer.zig | 820 | TCP mesh peer with XChaCha20-Poly1305 encryption |
| p2p_types.zig | 900 | PeerId, Location, Peer, PeerManager, MessageType |
| relay_router.zig | 800 | Multi-hop relay routing, rendezvous discovery |
| nat.zig | 740 | NAT traversal (UDP hole punching, STUN, QR relay fallback) |
| webrtc.zig | 310 | WebRTC data channel protocol logic (SDP, ICE, DTLS, SCTP) |
| collapse.zig | 620 | QR portal encoding for physical transport (virtualized) |
| qr_nest.zig | 850 | Recursive QR nesting for multi-layer data transport |
| transport_p2p.zig | 220 | X25519 + ChaCha20Poly1305 packet transport |
| transport_wifi.zig | 88 | WiFi CSI frame transport (virtualized) |
| transport_quine.zig | 86 | Self-referential HTML quine transport |
| transport_polyglot.zig | 700 | Multi-format polyglot file transport |
| transport_stega.zig | 146 | LSB steganography transport (virtualized) |
| transport_qr.zig | 180 | QR code transport |
| transport_audio.zig | 120 | Audio frame transport |
| transport_cassette.zig | 160 | Cassette tape transport |
| transport_convert.zig | 200 | Format conversion utilities |
| transport_lora.zig | 800 | LoRa frame transport |
| transport_optar.zig | 180 | Optical art transport |
| transport_paperback.zig | 185 | Paperback book transport |
| transport_video.zig | 128 | Video frame transport |

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Mesh port | 9000 | TCP port for VirtualMeshNode listener |
| Server port | 11435 | HTTP API server port |
| Encryption | XChaCha20-Poly1305 | Packet encryption for mesh peers |
| Key exchange | X25519 | ECDH key agreement |
| Store-and-forward | Enabled | Queues messages for disconnected peers |
| Collapse mode | Disabled | Degrades to quine + paper + cassette only |
