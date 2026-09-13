# 16 — ATMA-FANO-1 Structural Mapping

**Document ID:** SPEC-AF1-2026-REV02 (source spec: `x/Neo-Hinduism.md`)
**Scope:** the unified mapping between the Neo-Hindu/Hermetic framework and the concrete FANO-1 subsystems.

The ATMA-FANO-1 framework models the FANO-1 system as a holographic information continuum: reality as an O(1) zero-latency mental continuum, the local node (Atman) reconstructing its internal geometric volume to match the macrocosmic source. This document is the engineering realization of that framework: every Law maps to a concrete, testable mechanism in this repository. No component simulates metaphysics — each mapping is real code with a test command.

## Law → Component Mapping

| Law | Engine Equivalent | Concrete Component | Verification |
|---|---|---|---|
| **Law of the Seed (Karma)** — every cause has its effect | Deterministic Tensor State Transition | Q128.128 engine: every operation is a deterministic state transition, no random noise (`zig/q128_128.zig`); the blockchain ledger applies the same deterministic transition discipline (`blockchain/ledger.zig`, `blockchain/state_*.zig`) | `cd zig && zig build test` (28/28) |
| **Law of the Wheel (Reincarnation)** — iterative lossless re-encoding | The holo codec folds a volume to its core and reconstructs it losslessly, cycling until the state is exactly restored (`zig/holo.zig` fold/unfold round-trips at N ∈ {17,33,65,129,257,513}) | `cd zig && zig build test` (codec round-trip tests) |
| **Law of Assimilation (Nididhyasana)** — live runtime execution | The polyglot runtime compiles theory into executing instructions: C, C++, Rust, C#/.NET, Q#, Python, Java, JavaScript, Zig all execute live against the i256 ABI | `cd zig && zig build && ./zig-out/bin/poly-smoke` |
| **Law of Reverence (Shraddha)** — Tat Tvam Asi / node parity | Every FANO-1 node boots the identical manifest-verified image; the ATMA manifest (SHA-256 of every runtime artifact) is checked at boot | `os/atma-manifest.sh --check` (boot: `genesis: node parity verified`) |
| **Law of Sacrifice (Yajna)** — ego-heap garbage collection | Boot-time cleanup of stale transient state before services start; replaced passing artifacts are archived, never deleted (`/home/admpaul/Desktop/PJ/.archives`) | `os/init-fano` (`yajna`) |
| **Genesis Premise** (Genesis 3:22) — node authorization | Boot-time node-parity verification establishes the local node runs the verified source image | `bash os/atma-manifest.sh --check /usr/lib/fano /usr/lib/fano/atma-manifest` |
| **Inward Divine Spark** (Luke 17:21) — microcosmic reconstruction | The complete global dataset encoded in any sub-volume with O(1) lookup: the holographic codec and its FUSE filesystem | `zig/holo.zig` (fold/unfold, O(1) per cell), `holo-fs/` (mounted at `/mnt/holo-fs` by `os/init-fano`) |

## Boot Sequence (`os/init-fano`)

The ATMA boot protocol runs in order, each step real and logged to the karma journal (`/var/lib/fano/karma.log`):

1. **Yajna** — ego-heap cleanup: stale `/tmp` entries and transient state are deallocated before any service starts.
2. **Genesis verification** — the node-parity manifest (`atma-manifest`, SHA-256 per artifact) is verified; a mismatch is reported loudly (`NODE PARITY FAILURE`) and, under `FANO_GENESIS_STRICT=1`, halts. The ADRV layer (models + venv + podman) is verified separately via `adrv-manifest` when the ADRV SFS is loaded.
3. **Nididhyasana** — live runtime execution: holo-fs mounts, quine-server starts, Space Agent desktop server starts.
4. **Karma journal** — every state transition (mount, service start, parity result) is appended to `/var/lib/fano/karma.log`.

## Subsystem Coverage

| Subsystem | ATMA role |
|---|---|
| `zig/` (Q128.128 engine) | Karma: deterministic tensor state transitions, no random noise |
| `holo-fs/` | The Wheel: lossless re-encoding; the Spark: O(1) reconstruction |
| `blockchain/` | Karma ledger: deterministic state transitions |
| `zig/poly/` (polyglot runtime) | Nididhyasana: theory compiled into live execution |
| `os/` (this doc's home) | Genesis verification + Yajna at boot |
| `quine-server/` | Shraddha: identical source serves every node |
| `space-agent/` | The desktop surface where the node operates |

## Verification

```bash
bash -n os/atma-manifest.sh && bash -n os/init-fano   # syntax
bash os/atma-manifest.sh --generate <fano-home> <out>  # generate base manifest
bash os/atma-manifest.sh --check <fano-home> <manifest> # verify base parity
bash os/atma-manifest.sh --generate-adrv <adrv-dir> <out>  # generate ADRV manifest
bash os/atma-manifest.sh --check-adrv <adrv-dir> <manifest> # verify ADRV parity
bash os/test-packaging.sh                              # packaging contract
```
