//! isg_bridge.zig — Bridge module re-exporting ISG packer and unpacker
//! for use by other modules (e.g., blockchain/isg_storage.zig).
//!
//! This file exists as a single module root so that rgb_packer.zig,
//! rgb_unpacker.zig, and q128_error_correct.zig are all in the same
//! module, avoiding "file exists in multiple modules" errors.

pub const packer = @import("rgb_packer.zig");
pub const unpacker = @import("rgb_unpacker.zig");
pub const ec = @import("q128_error_correct.zig");
