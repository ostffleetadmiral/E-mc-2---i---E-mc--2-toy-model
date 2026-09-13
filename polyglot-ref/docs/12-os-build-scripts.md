# 12 — OS Build Scripts (`os/`)

## Architecture Overview

### Purpose

The OS module builds the bootable FANO-1 ISO: a Slacko64 Puppy Linux base remastered with the FANO-1 engine, the polyglot runtime (`fano-poly` + guests + `fano_langs` toolchains), and the Space Agent desktop shell (kiosk over its own Node server, JWM invisible). The default flow is a base-ISO remaster (no woof-CE from-source build required); the woof-CE path remains as the from-source option.

### Module Structure

| File | Purpose |
|------|---------|
| `build-iso.sh` | Main ISO build pipeline (remaster mode; `--woofce` for the from-source path) |
| `build-llama.sh` | Cross-build llama.cpp for glibc 2.23 (zig cc, CPU-only, SSE4.2+AVX) |
| `fano-langs/fetch.sh` | Checksummed fetch/verify of toolchains + base ISO |
| `fano-models/fetch-model.sh` | Download + verify Qwen2.5 + Qwen3.6 GGUF quants (SHA-256 pinned) |
| `fano-models/qstar-pack.zig` | Chunked qstar model archive tool (pack/unpack/verify) |
| `fano-models/bench-model.sh` | Benchmark harness (ext4/squashfs/holo-fs x mmap/mlock x CPU) |
| `atma-manifest.sh` | ATMA node-parity manifest generator/verifier (base + ADRV) |
| `init-fano` | Puppy boot script (yajna, genesis, karma, services, desktop) |
| `fano-kiosk` | Kiosk-browser launcher for the desktop shell |
| `jwm-invisible.jwmrc` | JWM invisibility config (no tray/pager/taskbar) |
| `test-packaging.sh` | Packaging contract verification |
| `audit-iso-size.sh` | ISO size audit (no hard cap; reports RAM-boot feasibility) |
| `test-iso.sh` | QEMU boot test (interactive + `--auto`) |
| `fano-1-files/` | Staged rootfs package — base layer (build output) |
| `fano-1-adrv/` | Staged ADRV layer — models + agent-zero venv + podman (build output) |
| `agent-zero/` | Agent-zero native runtime source (packaged into base + ADRV) |
| `llama.cpp/` | llama.cpp source tree (cross-built for glibc 2.23) |
| `output/` | Built ISO |

### Dependencies

- **External**: unsquashfs/mksquashfs, xorriso, cpio, gzip, QEMU (testing)
- **Internal**: Zig binaries (`zig/`, `holo-fs/`, `quine-server/`), polyglot runtime (`zig/poly/`), Space Agent (`space-agent/`)

---

## Toolchain Fetch (`fano-langs/fetch.sh`)

Downloads and SHA-256-verifies every artifact into `os/fano-langs/`:

| Artifact | Source | Extracted to |
|----------|--------|--------------|
| Node 20.18.1 (official) | nodejs.org | `node20/` (build machine) |
| Temurin JDK 17 | adoptium.net | `jdk-17.0.20.1+1/` |
| .NET 8 runtime (8.0.31) | builds.dotnet.microsoft.com | `dotnet-runtime-8.0.31/` (SHA-512 from the official release metadata) |
| CPython 3.11.9 standalone | python-build-standalone | `python3.11/` |
| Node 20 glibc-2.17 build | unofficial-builds.nodejs.org | `node20-glibc217/` |
| Slacko64 7.0 base ISO | ibiblio (fallback: archive.org) | `cache/` |

All checksums are pinned in the script; a mismatch aborts the build. `--verify-only` re-checks checksums without downloading.

**Why the glibc-2.17 Node build**: Slacko64 7.0 ships glibc 2.23; the official Node 20 build requires GLIBC_2.28. The `unofficial-builds` project publishes Node 20 compiled for glibc 2.17, which keeps the runtime the Space Agent server needs while running on the base ISO.

---

## Build Pipeline (`build-iso.sh`)

Two modes:

- **remaster** (default): extract the checksum-verified Slacko64 base ISO, unsquash its rootfs, inject the FANO-1 packages, resquash, rebuild with xorriso.
- `--woofce`: full woof-CE from-source build (heavy; the legacy path).

### Pipeline

```
[1]   Build FANO-1 Zig binaries (glibc-2.23 target, standalone CPython linkage)
[2]   Assemble the FANO-1 package (engine + polyglot runtime + Zig toolchain)
[4b]  Package llama.cpp local inference runtime (cross-built, CPU + Vulkan)
[4c]  Package in-ISO models (Qwen2.5-3B + 0.5B Q4_K_M -> ADRV layer)
[4d]  Package agent-zero native runtime (source -> base, venv -> ADRV)
[4e]  Package Podman container runtime (daemonless, rootless -> ADRV)
[3]   Package fano_langs (JRE-trimmed JDK, glibc-2.17 Node, .NET runtime, CPython)
[4]   Package Space Agent (app tree + node_modules, no electron-updater)
[6]   Remaster: extract ISO -> unsquash rootfs -> inject -> ATMA manifest (base)
      -> resquash -> ADRV SFS (models + venv + podman) + ADRV manifest -> xorriso
[7]   Size audit (audit-iso-size.sh)
```

### Rootfs Layout (in the ISO)

```
/usr/lib/fano/            engine binaries + poly runtime tree + guests/
├── fano-poly, poly-smoke, fano-sh, fano-scale, fano-codec, fano-rf
├── poly/                 polyglot runtime sources (guests, vendor)
├── q128_128.zig          canonical numeric core
├── guests/               prebuilt guest artifacts (NativeAOT .so, Q# publish)
├── llama/                llama.cpp runtime (llama-server, llama-cli, shared libs)
├── agent-zero/           agent-zero source (base rootfs); venv lives in ADRV
├── fano-langs/           node20 (glibc-2.17), jdk-17 (JRE-trimmed),
│                         dotnet8, python3.11, fetch.sh
├── space-agent/          Space Agent desktop shell (server + app + deps)
├── zig/                  Zig toolchain (fano-poly build/run works on-device)
└── atma-manifest         SHA-256 node-parity manifest
/etc/init.d/fano-init    boot script (ATMA boot protocol)
/etc/profile.d/fano.sh   polyglot runtime environment
/usr/share/applications/ fano-poly.desktop, fano-sh.desktop
/usr/share/mime/packages/fano.xml   .fanop/.fano MIME types
/etc/system.jwmrc        JWM invisibility config
/usr/bin/fano-kiosk      kiosk-browser launcher for the desktop shell
```

### Usage

```bash
cd os/fano-langs && ./fetch.sh          # fetch + verify toolchains + base ISO
cd os && SKIP_SMALL_MODEL=1 ./build-iso.sh   # build the ISO (no model baked)
# Output: os/output/fano1-slacko64-7.0.iso
```

---

## ATMA Boot Integration (`atma-manifest.sh`, `init-fano`)

The ATMA-FANO-1 spec (docs/16-atma-fano1.md, source `x/Neo-Hinduism.md`) is expressed as real boot-time engineering:

- **Genesis verification** — `os/atma-manifest.sh` generates a SHA-256 manifest of every `/usr/lib/fano` artifact at build time; `init-fano` verifies it at boot (`genesis: node parity verified`) and fails loudly on mismatch (`FANO_GENESIS_STRICT=1` halts).
- **Karma journal** — append-only `/var/lib/fano/karma.log` records every deterministic state transition (service starts, holo-fs mount, parity result).
- **Yajna** — boot-time cleanup of stale `/tmp` and transient state before services start.
- **Nididhyasana** — live service start: holo-fs mount, quine-server, Space Agent desktop shell.

`init-fano` boot order: yajna cleanup → genesis verification → holo-fs mount → quine-server (8080) → Space Agent server (3000, single-user) → hardware detection. Every step is recorded in the karma journal.

---

## Verification

```bash
bash -n os/*.sh && sh -n os/init-fano os/fano-kiosk                  # syntax
bash os/test-packaging.sh                                        # packaging contract
bash os/audit-iso-size.sh                                        # size audit
./os/test-iso.sh os/output/*.iso 2048 --auto                     # QEMU boot test
```

The automated boot test boots the ISO headless (KVM when available), waits for the guest services through QEMU user-net forwarding (host 18080 → guest 8080 quine-server; host 13000 → guest 3000 space-agent), and passes only when both respond. The Slacko64 kernel has no built-in serial console, so the serial log stays empty by design; the HTTP channel is the verification surface.

Verified: `fano1-slacko64-7.0.iso` (0.53 GB) boots to the Puppy desktop with quine-server and the Space Agent desktop shell both reachable.

---

## Integration Points

- **Q128.128 Core** (`zig/`): engine binaries + polyglot runtime (`fano-poly`, `poly-smoke`, poly tree, Zig toolchain)
- **Holo-FS** (`holo-fs/`): mounted at boot by `init-fano`
- **Quine Server** (`quine-server/`): started at boot on port 8080
- **Space Agent** (`space-agent/`): desktop shell server on port 3000; kiosk browser at `/#desktop` via `fano-kiosk`
- **fano_langs** (`os/fano-langs/`): JDK 17 (JRE-trimmed), Node 20 (glibc-2.17), .NET 8 runtime, CPython 3.11
- **llama.cpp** (`os/llama.cpp/`): cross-built for glibc 2.23; `llama-server` started at boot (opt-in via `FANO_LLAMA_ENABLED=1`); in-ISO models (Qwen2.5-3B + 0.5B Q4_K_M) baked into the ADRV layer; larger models (Qwen3.6-27B+) in external storage (see `docs/17-local-inference.md`)
- **ATMA-FANO-1** (`docs/16-atma-fano1.md`): boot-time node-parity verification and the unified subsystem mapping
