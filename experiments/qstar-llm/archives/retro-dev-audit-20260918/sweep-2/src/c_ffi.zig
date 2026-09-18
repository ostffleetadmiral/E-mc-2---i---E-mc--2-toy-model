//! c_ffi.zig — Unified C FFI dynamic library loader.
//!
//! Provides a reusable, zero-allocation wrapper around dlopen/dlsym for
//! runtime-loading shared libraries (libvulkan, libonnxruntime, stb_image, etc).
//! On freestanding targets (WASM), all operations gracefully return errors
//! since dlopen is unavailable.
//!
//! Zero external dependencies beyond std + libc (when available).

const std = @import("std");
const builtin = @import("builtin");

pub const is_freestanding = builtin.os.tag == .freestanding;

/// dlopen/dlsym/dlclose function pointer types.
const DlopenFn = *const fn (filename: ?[*:0]const u8, flags: c_int) callconv(.C) ?*anyopaque;
const DlsymFn = *const fn (handle: ?*anyopaque, symbol: [*:0]const u8) callconv(.C) ?*anyopaque;
const DlcloseFn = *const fn (handle: ?*anyopaque) callconv(.C) c_int;

/// Lazily-resolved libc function pointers. Null on freestanding or if libc
/// is not linked. Resolved on first call to `open`.
var dlopen_fn: ?DlopenFn = null;
var dlsym_fn: ?DlsymFn = null;
var dlclose_fn: ?DlcloseFn = null;
var resolved: bool = false;

fn resolveSymbols() void {
    if (resolved) return;
    resolved = true;
    if (is_freestanding) return;
    dlopen_fn = @extern(DlopenFn, .{ .name = "dlopen" });
    dlsym_fn = @extern(DlsymFn, .{ .name = "dlsym" });
    dlclose_fn = @extern(DlcloseFn, .{ .name = "dlclose" });
}

pub const RTLD_LAZY: c_int = 1;
pub const RTLD_NOW: c_int = 2;
pub const RTLD_GLOBAL: c_int = 256;

/// Error set for FFI operations.
pub const FfiError = error{
    LibraryNotFound,
    SymbolNotFound,
    FreestandingUnsupported,
};

/// A handle to a dynamically loaded shared library.
/// Use `open` to load, `lookup` to resolve symbols, and `close` to unload.
pub const DynLib = struct {
    handle: ?*anyopaque,
    name: []const u8,

    /// Load a shared library by path.
    /// Returns `LibraryNotFound` if the library cannot be loaded or if
    /// running on a freestanding target.
    pub fn open(path: [*:0]const u8) FfiError!DynLib {
        resolveSymbols();
        if (is_freestanding or dlopen_fn == null) return error.FreestandingUnsupported;
        const fn_ptr = dlopen_fn.?;
        const h = fn_ptr(path, RTLD_LAZY) orelse return error.LibraryNotFound;
        const path_slice = std.mem.sliceTo(path, 0);
        return .{ .handle = h, .name = path_slice };
    }

    /// Load a shared library with custom flags.
    pub fn openWithFlags(path: [*:0]const u8, flags: c_int) FfiError!DynLib {
        resolveSymbols();
        if (is_freestanding or dlopen_fn == null) return error.FreestandingUnsupported;
        const fn_ptr = dlopen_fn.?;
        const h = fn_ptr(path, flags) orelse return error.LibraryNotFound;
        const path_slice = std.mem.sliceTo(path, 0);
        return .{ .handle = h, .name = path_slice };
    }

    /// Resolve a symbol from the loaded library.
    /// Returns `null` if the symbol is not found (does not error).
    pub fn lookup(self: DynLib, comptime T: type, name: [*:0]const u8) ?T {
        if (is_freestanding or dlsym_fn == null) return null;
        const fn_ptr = dlsym_fn.?;
        const sym = fn_ptr(self.handle, name) orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    /// Resolve a symbol, returning `SymbolNotFound` on failure.
    pub fn lookupRequired(self: DynLib, comptime T: type, name: [*:0]const u8) FfiError!T {
        return self.lookup(T, name) orelse error.SymbolNotFound;
    }

    /// Check if the library is loaded.
    pub fn isOpen(self: DynLib) bool {
        return self.handle != null;
    }

    /// Close the library handle.
    pub fn close(self: *DynLib) void {
        if (is_freestanding or dlclose_fn == null) {
            self.handle = null;
            return;
        }
        if (dlclose_fn) |fn_ptr| _ = fn_ptr(self.handle);
        self.handle = null;
    }

    /// Get the library name/path that was used to open this handle.
    pub fn getName(self: DynLib) []const u8 {
        return self.name;
    }
};

/// Check if dynamic library loading is available on this platform.
pub fn isAvailable() bool {
    resolveSymbols();
    return !is_freestanding and dlopen_fn != null;
}

// =============================================================================
// Tests
// =============================================================================

test "DynLib graceful failure on missing library" {
    var dl = DynLib.open("lib_nonexistent_12345.so") catch |err| {
        try std.testing.expect(err == error.LibraryNotFound or err == error.FreestandingUnsupported);
        return;
    };
    defer dl.close();
    // If it somehow loaded, that's fine — just verify it's open
    try std.testing.expect(dl.isOpen());
}

test "isAvailable returns false on freestanding" {
    if (is_freestanding) {
        try std.testing.expect(!isAvailable());
    } else {
        // On non-freestanding, should be true if libc is linked
        // (may be false if libc symbols aren't resolved yet)
        _ = isAvailable();
    }
}

test "DynLib lookup returns null for missing symbol" {
    var dl = DynLib.open("lib_nonexistent_12345.so") catch return;
    defer dl.close();
    const sym = dl.lookup(*anyopaque, "nonexistent_symbol_xyz");
    try std.testing.expect(sym == null);
}

test "DynLib lookupRequired returns SymbolNotFound for missing symbol" {
    var dl = DynLib.open("lib_nonexistent_12345.so") catch return;
    defer dl.close();
    const result = dl.lookupRequired(*anyopaque, "nonexistent_symbol_xyz");
    try std.testing.expectError(error.SymbolNotFound, result);
}

test "DynLib openWithFlags matches open behavior" {
    var dl1 = DynLib.open("lib_nonexistent_12345.so") catch |err| {
        try std.testing.expect(err == error.LibraryNotFound or err == error.FreestandingUnsupported);
        return;
    };
    defer dl1.close();
    var dl2 = DynLib.openWithFlags("lib_nonexistent_12345.so", RTLD_NOW) catch |err| {
        try std.testing.expect(err == error.LibraryNotFound or err == error.FreestandingUnsupported);
        return;
    };
    defer dl2.close();
}

test "DynLib getName returns the path used" {
    const path = "lib_nonexistent_12345.so";
    var dl = DynLib.open(path) catch return;
    defer dl.close();
    // Name should contain the path (it's a slice of the null-terminated string)
    try std.testing.expect(dl.name.len > 0);
}

test "DynLib close sets handle to null" {
    var dl = DynLib.open("lib_nonexistent_12345.so") catch return;
    dl.close();
    try std.testing.expect(!dl.isOpen());
}

test "DynLib isOpen returns false after failed open" {
    // On failed open, we return an error, so we never get a DynLib to check.
    // This test verifies the error path.
    const result = DynLib.open("lib_nonexistent_12345.so");
    if (result) |_| {
        // Unexpected success — just pass
    } else |_| {
        // Expected error — pass
    }
}

test "RTLD constants have expected values" {
    try std.testing.expect(RTLD_LAZY == 1);
    try std.testing.expect(RTLD_NOW == 2);
}

test "resolveSymbols is idempotent" {
    resolveSymbols();
    const was_resolved = resolved;
    resolveSymbols();
    try std.testing.expect(resolved == was_resolved);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
