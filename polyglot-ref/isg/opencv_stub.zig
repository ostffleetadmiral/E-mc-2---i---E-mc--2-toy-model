//! opencv_stub.zig — Stub for OpenCV bridge when OpenCV is not installed.
//! Provides the same API as opencv_bridge.zig but returns errors.

const std = @import("std");

pub fn extractFrames(alloc: std.mem.Allocator, path: []const u8) !struct {
    frames: [][]u8,
    width: u32,
    height: u32,
    fps: f64,
} {
    _ = alloc;
    _ = path;
    return error.OpenCVNotAvailable;
}

pub fn freeFrames(alloc: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |f| alloc.free(f);
    alloc.free(frames);
}

pub fn encodeVideo(
    alloc: std.mem.Allocator,
    frames: []const []const u8,
    width: u32,
    height: u32,
    fps: f64,
    path: []const u8,
    codec: [4]u8,
) !void {
    _ = alloc;
    _ = frames;
    _ = width;
    _ = height;
    _ = fps;
    _ = path;
    _ = codec;
    return error.OpenCVNotAvailable;
}
