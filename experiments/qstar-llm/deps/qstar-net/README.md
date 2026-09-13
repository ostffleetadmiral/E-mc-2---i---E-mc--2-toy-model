# Qstar-Net

NAT traversal, WebRTC signaling, peer bootstrap, Sybil resistance, and Möbius merge — zero-dependency P2P connectivity toolkit.

## Quick Start

```bash
zig build test          # 68 tests
zig build run           # NAT + bootstrap + Sybil + merge + WebRTC demo
```

## What This Is

Five modules for building P2P systems without external dependencies:

- **NAT traversal** — UDP hole punching with NAT type detection, STUN client, WebRTC fallback, QR relay
- **WebRTC** — SDP, ICE candidates, DTLS fingerprinting, data channel messages
- **Bootstrap** — FaceQR seed discovery using 25 hardcoded E0 nodes
- **Sybil resistance** — Proof of Lattice Work (PoLW) using E0 node hashing
- **Möbius merge** — Conflict resolution for concurrent lattice cell edits

## Usage

```zig
const nat = @import("nat");
const sybil = @import("sybil");
const bootstrap = @import("bootstrap");
const merge = @import("merge");

// NAT type detection
const nat_type = nat.NATType.full_cone;
const can_punch = nat_type.canHolePunch();

// Bootstrap seed
const seed = bootstrap.BootstrapSeed.canonical();

// Sybil challenge
var rng = std.Random.DefaultPrng.init(42);
const challenge = sybil.Challenge.random(&rng, 12, now_ms);
const proof = sybil.solveChallenge(challenge);

// Merge
var ms = merge.MergeSet.init(allocator, .mobius_twist);
defer ms.deinit();
```

## API Reference

### NAT (`nat.zig`)

| Function | Description |
|----------|-------------|
| `NATType.toString()` | Get NAT type name |
| `NATType.canHolePunch()` | Check if hole punching works |
| `Address.new(ip, port)` | Create network address |
| `Address.format(allocator)` | Format as string |

### WebRTC (`webrtc.zig`)

| Constant | Value |
|----------|-------|
| `SDP_MAX_LEN` | 4096 |
| `CHANNEL_MAX_PAYLOAD` | 65535 |
| `DTLS_FINGERPRINT_SIZE` | 32 |

| Type | Description |
|------|-------------|
| `IceCandidate` | ICE candidate with IP, port, priority |
| `DtlsFingerprint` | SHA-256 DTLS fingerprint |
| `DataChannelMsg` | WebRTC data channel message |
| `SdpType` | Offer/answer SDP type |

### Bootstrap (`bootstrap.zig`)

| Function | Description |
|----------|-------------|
| `BootstrapSeed.canonical()` | Get canonical bootstrap seed |
| `seed.validate()` | Validate seed integrity |
| `seed.serialize(allocator)` | Serialize to bytes |
| `BootstrapSeed.deserialize(data)` | Deserialize from bytes |

### Sybil (`sybil.zig`)

| Function | Description |
|----------|-------------|
| `Challenge.random(rng, difficulty, now_ms)` | Generate random challenge |
| `solveChallenge(challenge)` | Solve PoLW challenge |
| `latticeHash(challenge, nonce)` | Hash challenge+nonce |
| `verifyProof(challenge, proof)` | Verify a proof |

### Merge (`merge.zig`)

| Function | Description |
|----------|-------------|
| `MergeSet.init(allocator, strategy)` | Create merge set |
| `resolveConflict(conflict, strategy)` | Resolve a single conflict |
| `MergeStrategy` | `last_write_wins`, `e_value_priority`, `mobius_twist`, `three_way` |

## Modules

| Module | Lines | Tests |
|--------|-------|-------|
| nat.zig | 766 | 17 |
| webrtc.zig | 298 | 10 |
| bootstrap.zig | 570 | 13 |
| sybil.zig | 574 | 14 |
| merge.zig | 575 | 14 |

**Total: 2,783 lines, 68 tests. Zero dependencies (std only).**

## Origin

Extracted from Qstar. Fully standalone, no dependency on Qstar at build time.
