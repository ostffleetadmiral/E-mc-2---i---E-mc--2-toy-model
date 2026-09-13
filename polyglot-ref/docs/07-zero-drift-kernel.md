# 07 — Zero-Drift Kernel (`kernel/`)

## Architecture Overview

### Purpose

The kernel module implements a freestanding x86_64 operating system kernel written entirely in Zig. It boots via multiboot1, transitions from 32-bit protected mode to 64-bit long mode, initializes hardware (GDT/IDT/PIC/PIT), provides a bump heap allocator, and runs the FANO-sh kernel shell as PID 1 with Q128.128 arithmetic and holographic codec as first-class kernel services.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `main.zig` | 483 | Full kernel: boot stub, console, GDT/IDT, PIT, heap, FANO-sh shell |
| `boot.s` | 108 | Assembly boot: long-mode segment loads, BSS zeroing, kmain entry |
| `linker.ld` | 29 | Linker script: multiboot1 at 1 MiB, long mode layout |

### Dependencies

- **Internal**: `q128_128` module (from `../zig/q128_128.zig`)
- **External**: None (freestanding, no libc)

### Boot Sequence

```
1. Multiboot1 header loaded by GRUB at 1 MiB
2. _start (32-bit protected mode):
   a. Save multiboot info pointer
   b. Build page tables: identity map 1 GiB with 2 MiB pages
   c. Load CR3 (PML4 base)
   d. Enable PAE (CR4)
   e. Enable LME (EFER MSR)
   f. Enable paging (CR0)
   g. Load GDT, far jump to 64-bit code segment
3. start64 (64-bit long mode):
   a. Load data segment registers
   b. Set stack pointer (64 KiB stack)
   c. Call kmain()
4. kmain():
   a. Clear VGA text buffer
   b. Initialize serial port (COM1, 115200 baud)
   c. Print banner
   d. initInterrupts() — GDT, IDT, PIC remap, PIT 100 Hz
   e. FrameAlloc.init() — physical frame allocator
   f. shell() — FANO-sh interactive shell (PID 1, never returns)
```

---

## Subsystems

### Boot Stub (comptime inline assembly)

The entire boot sequence is embedded as inline assembly at compile time:

- **Multiboot header**: Magic `0x1BADB002`, flags `0x10003`, checksum `-(magic + flags)`
- **Page tables**: PML4 → PDPT → PD with 512 × 2 MiB entries (1 GiB identity mapped)
- **GDT**: Null + 64-bit code (0x00AF9A) + 64-bit data (0x00CF92)
- **Stack**: 64 KiB static allocation

### Console I/O

#### Serial (COM1)

```zig
const Serial = struct {
    const COM1: u16 = 0x3F8;
    fn init() void     // 115200 baud, 8N1
    fn putc(c: u8) void
    fn getc() ?u8      // Non-blocking read
    fn puts(s: []const u8) void
};
```

#### VGA Text Mode

```zig
const Vga = struct {
    const BUF: usize = 0xB8000;
    var row: usize = 0;
    var col: usize = 0;
    fn putc(c: u8) void  // White-on-black, 80×25
    fn puts(s: []const u8) void
    fn clear() void
};
```

#### Kernel Print

```zig
fn kprint(comptime fmt: []const u8, args: anytype) void
// Formats to 512-byte buffer, outputs to both Serial and VGA
```

### Interrupt System

#### GDT (5 entries)

| Index | Type | Access | Granularity |
|-------|------|--------|-------------|
| 0 | Null | — | — |
| 1 | Kernel code | 0x9A | 0xAF |
| 2 | Kernel data | 0x92 | 0xCF |
| 3 | User code | 0x9A | 0xAF |
| 4 | User data | 0x92 | 0xCF |

#### IDT (256 entries)

| Vector | Handler | Description |
|--------|---------|-------------|
| 32 | `irq0Handler` | PIT timer tick (100 Hz) |
| 33 | `irq1Handler` | Keyboard scancode (serial is primary) |
| 128 | `syscallHandler` | int 0x80 syscall layer |

#### PIC Remap

8259 PIC remapped to vectors 32–47 (ICW1: 0x11, ICW2: 0x20/0x28, ICW3: 0x04/0x02, ICW4: 0x01).

#### PIT Timer

Channel 0, mode 3 (square wave), 100 Hz: `div = 1193182 / 100 = 11932`.

#### Syscall Layer (int 0x80)

| Syscall | rax | Args | Return |
|---------|-----|------|--------|
| q128_add | 1 | rbx, rcx (i64) | rax:rdx (128-bit signed sum) |
| q128_mul | 2 | rbx, rcx (i64) | rax:rdx (128-bit signed product) |

The syscall returns the integer portion (bits 255..128 of the Q128.128 result) in rax:rdx. Full 256-bit Q128.128 arithmetic is available via the kernel shell (`q128 1+1`, `q128 2*3`) which uses the freestanding `q128_kernel.zig` module directly.

### Memory Management

#### Physical Frame Allocator

```zig
const FrameAlloc = struct {
    var next_frame: u64 = 0x300000;  // After kernel + tables
    var frames_left: u64 = 0;
    fn init(mem_upper_kb: u64) void
    fn alloc() ?u64                   // Bump allocator, 4 KiB frames
};
```

#### Bump Heap

```zig
const Heap = struct {
    var base: usize = 0x4000000;      // 64 MiB physical (identity-mapped)
    var offset: usize = 0;
    const size: usize = 16 * 1024 * 1024;  // 16 MiB
    pub const Allocator: std.mem.Allocator;
};
```

- 16 MiB heap at 64 MiB physical, identity-mapped
- Bump allocator: no free, no coalesce
- Implements `std.mem.Allocator` interface for Zig standard library compatibility

### FANO-sh Kernel Shell

The shell is PID 1 — it never returns. Reads commands from serial console.

#### Commands

| Command | Description |
|---------|-------------|
| `help` | Print command list |
| `info` | Kernel + memory info (ticks, heap usage) |
| `uptime` | Ticks since boot (100 Hz → seconds) |
| `q128 1+1` | Q128.128 arithmetic demo |
| `holo` | Holographic codec demo (fold/unfold 17³ grid) |
| `pivot` | RamseyIdentity: E=mc² ↔ i ↔ E=mc⁻² |

#### `holo` Command

Creates a 17³ holographic grid filled with Q128.128 value 2.5, prints cell data at various unfold levels.

```zig
const HoloGrid = struct {
    n: u32,
    data: []HoloCell,
    const HoloCell = extern struct {
        re_hi: u128, re_lo: u128, im_hi: u128, im_lo: u128
    };
};
```

#### `pivot` Command

Demonstrates the Ramsey identity transform:
1. Compute `E_f = m × c²` (Q128.128 multiplication)
2. Print pivot rotation: re → 0 exactly (information stored as pure imaginary)
3. Print `E_i = m × c⁻²`
4. Verify `E_f / E_i = c⁴` (conservation)

---

## Linker Script (`linker.ld`)

```
ENTRY(_start)

SECTIONS {
    . = 1M;
    .boot   : ALIGN(4K) { KEEP(*(.multiboot)) KEEP(*(.boot.text)) }
    .text   : ALIGN(4K) { KEEP(*(.text.boot64)) *(.text*) }
    .rodata : ALIGN(4K) { *(.rodata*) }
    .data   : ALIGN(4K) { *(.data*) }
    .bss    : ALIGN(4K) { __bss_start = .; *(COMMON) *(.bss*) __bss_end = .; }
    _kernel_end = .;
}
```

- Kernel loaded at 1 MiB physical
- `.boot` section contains multiboot header and 32-bit boot code
- `.text` section contains 64-bit kernel code
- BSS boundaries exported via `__bss_start` / `__bss_end`

---

## Build

The kernel is built as part of the OS ISO build process. See `os/build-iso.sh` for the full build pipeline.

### Standalone Build (for testing)

```bash
# Compile kernel (requires freestanding target)
zig build-exe kernel/main.zig -target x86_64-freestanding -T kernel/linker.ld
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Imported as `q128_128` module for shell arithmetic
- **OS Build** (`os/`): Kernel packaged into the base rootfs SFS for ISO build
- **Runtime** (`runtime/`): Hardware detection for kernel auto-scaling
- **VFS Interceptor** (`vfs/`): Kernel shell can invoke holographic folding
- **Holo-FS** (`holo-fs/`): FUSE filesystem mounts on kernel heap
- **FANO-sh** (`zig/fano_sh.zig`): Shell language interpreter (kernel uses simplified inline version)

**ATMA mapping:** Law of the Wheel — iterative lossless re-encoding across runtime instances (see docs/16-atma-fano1.md).
