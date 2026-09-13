# 10 — Holographic FUSE FS (`holo-fs/`)

## Architecture Overview

### Purpose

The holo-fs module implements a FUSE filesystem that transparently stores files as holographically compressed chunks. Files are split into 16³-node grids (256 KB each), compressed via the holographic codec (`holo.zig`), and stored on disk. An LRU cache holds decompressed chunks in memory for fast access. The filesystem communicates directly with the Linux kernel's `/dev/fuse` interface — no libfuse dependency.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `main.zig` | 596 | FUSE main loop: mount, read/write, directory operations |
| `store.zig` | 504 | Hologram storage layer: chunking, compression, LRU cache |
| `fuse_proto.zig` | 277 | FUSE kernel protocol constants and structures |
| `build.zig` | 60 | Build system: executable + tests |

### Dependencies

- **Internal**: `q128_128` module, `holo` module (from `../zig/`)
- **External**: Linux `/dev/fuse` (kernel FUSE driver)

---

## Storage Layer (`store.zig`)

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `CHUNK_NODES` | 4096 | 16³ nodes per chunk |
| `CHUNK_BYTES` | 262144 | 256 KB per chunk (4096 × 64 bytes) |
| `MAX_CACHE_CHUNKS` | 64 | 64 × 256 KB = 16 MB LRU cache |

### Types

```zig
pub const FileMeta = struct {
    inode: u64,
    size: u64,
    mode: u32,
    nlink: u32,
    uid: u32, gid: u32,
    atime: i64, mtime: i64, ctime: i64,
    chunk_count: u32,
    chunk_ids: []u64,
};

pub const Store = struct {
    files: StringHashMap(FileMeta),     // Path → metadata
    inodes: AutoHashMap(u64, []const u8), // Inode → path
    cache: AutoHashMap(u64, CacheEntry), // Hologram ID → decompressed data
    cache_order: ArrayList(u64),        // LRU eviction order
    next_hologram_id: u64,
    next_inode: u64,
};
```

### Chunking Pipeline

```
File write → split into 256 KB chunks → fold each via holo.zig → store on disk
File read  → load hologram from disk → unfold via holo.zig → LRU cache → return bytes
```

### LRU Cache

- **Capacity**: 64 chunks (16 MB)
- **Eviction**: When cache is full, evict least-recently-used entry
- **Dirty tracking**: Modified chunks marked dirty, written back on eviction
- **Access counter**: Monotonic counter for LRU ordering

### Key Operations

| Operation | Description |
|-----------|-------------|
| `createFile` | Create new file metadata, allocate inode |
| `writeData` | Chunk data, fold each chunk, store holograms |
| `readData` | Load hologram, unfold, cache, return bytes |
| `deleteFile` | Remove file + all associated holograms |
| `getMeta` | Retrieve file metadata by path |
| `listDir` | List files in a directory path |

---

## FUSE Protocol (`fuse_proto.zig`)

### Supported Opcodes

| Opcode | ID | Handler |
|--------|----|---------|
| `FUSE_INIT` | 26 | Protocol version negotiation |
| `FUSE_LOOKUP` | 1 | Path → inode lookup |
| `FUSE_GETATTR` | 3 | File attributes |
| `FUSE_MKNOD` | 8 | Create file node |
| `FUSE_MKDIR` | 9 | Create directory |
| `FUSE_UNLINK` | 10 | Delete file |
| `FUSE_RMDIR` | 11 | Delete directory |
| `FUSE_OPEN` | 14 | Open file |
| `FUSE_READ` | 15 | Read data |
| `FUSE_WRITE` | 16 | Write data |
| `FUSE_STATFS` | 17 | Filesystem statistics |
| `FUSE_RELEASE` | 18 | Close file |
| `FUSE_OPENDIR` | 27 | Open directory |
| `FUSE_READDIR` | 28 | Read directory entries |
| `FUSE_RELEASEDIR` | 29 | Close directory |
| `FUSE_CREATE` | 30 | Create + open file |

### Protocol Structures

```zig
pub const FuseInHeader = extern struct { len, opcode, unique, nodeid, uid, gid, pid, padding };
pub const FuseOutHeader = extern struct { len, err, unique };
pub const FuseAttr = extern struct { ino, size, blocks, atime, mtime, ctime, ... mode, nlink, uid, gid, ... };
pub const FuseEntryOut = extern struct { nodeid, generation, attr, ... };
```

---

## FUSE Main Loop (`main.zig`)

### Mount Process

```
1. Open /dev/fuse
2. Mount FUSE filesystem at mountpoint via mount() syscall
3. Read FUSE requests from /dev/fuse fd
4. Dispatch by opcode to handler functions
5. Send response back via /dev/fuse fd
```

### Filesystem State

```zig
const Fs = struct {
    alloc: Allocator,
    store: Store,
    fuse_fd: fd_t,
    inodes: AutoHashMap(u64, InodeEntry),  // Inode → path + is_dir
    next_inode: u64,
    uid: u32,
    gid: u32,
};
```

### Inode Management

- Root inode = 1 (always exists)
- Inodes allocated sequentially from 2
- Each inode maps to a path string and directory flag
- Parent inodes tracked for hierarchy

### Read/Write Flow

**Write**:
1. Receive `FUSE_WRITE` with data at offset
2. Determine which chunk(s) the write spans
3. Read existing chunk from store (if partial write)
4. Merge new data into chunk
5. Fold chunk via `holo.zig` → store hologram
6. Update file metadata (size, mtime)
7. Return bytes written

**Read**:
1. Receive `FUSE_READ` with offset + size
2. Determine which chunk(s) the read spans
3. Check LRU cache for decompressed chunk
4. If miss: load hologram from disk, unfold, cache
5. Copy requested bytes from chunk(s)
6. Return data

---

## Build Configuration (`build.zig`)

### Targets

| Target | Type | Description |
|--------|------|-------------|
| `holo-fs` | Executable | FUSE filesystem binary |
| `test-proto` | Test | FUSE protocol tests |
| `test-store` | Test | Hologram store tests |
| `test` | Test step | All tests |

### Build Commands

```bash
cd holo-fs/ && zig build         # Build holo-fs binary
cd holo-fs/ && zig build test     # Run tests
```

### Usage

```bash
holo-fs <mountpoint> [store-dir]
# Example: holo-fs /mnt/holo-fs /var/lib/holo-fs-store
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Fixed-point arithmetic for holographic codec
- **Holographic Codec** (`zig/holo.zig`): 16³ → folded hologram compression
- **OS Build** (`os/`): holo-fs mounted at boot via `init-fano`
- **Quine Server** (`quine-server/`): Document persistence on holo-fs
- **VFS Interceptor** (`vfs/`): Model proxy serves from holo-fs
- **Kernel** (`kernel/`): FUSE module loaded at boot (`modprobe fuse`)

**ATMA mapping:** The Inward Divine Spark — the complete dataset encoded in any sub-volume, O(1) reconstruction (see docs/16-atma-fano1.md).
