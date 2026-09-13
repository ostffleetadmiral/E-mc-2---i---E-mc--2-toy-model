//! video_io.zig — Write and read raw RGB video frames to/from files.
//!
//! Raw RGB format: a sequence of frames, each frame_width × frame_height × 3 bytes
//! (RGB 24-bit, no compression). This can be piped to FFmpeg for MP4 encoding:
//!   isg-rgb pack input.bin /dev/stdout | ffmpeg -f rawvideo -pix_fmt rgb24 \
//!     -s 1920x1080 -i - -c:v libx264 output.mp4
//!
//! And for unpacking from MP4:
//!   ffmpeg -i input.mp4 -f rawvideo -pix_fmt rgb24 - | isg-rgb unpack /dev/stdin output.bin

const std = @import("std");

/// Write raw RGB frames to a file.
pub fn writeFrames(
    frames: []const []const u8,
    path: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    for (frames) |frame| {
        try file.writeAll(frame);
    }
}

/// Read raw RGB frames from a file.
pub fn readFrames(
    alloc: std.mem.Allocator,
    path: []const u8,
    frame_width: u32,
    frame_height: u32,
    frame_count: u32,
) ![][]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const frame_size = @as(usize, frame_width) * frame_height * 3;
    var frames = try alloc.alloc([]u8, frame_count);
    errdefer alloc.free(frames);

    for (frames, 0..) |*frame, i| {
        frame.* = try alloc.alloc(u8, frame_size);
        errdefer {
            for (frames[0..i]) |f| alloc.free(f);
        }
        const n = try file.readAll(frame.*);
        if (n != frame_size) {
            for (frames[0..i]) |f| alloc.free(f);
            alloc.free(frame.*);
            alloc.free(frames);
            return error.IncompleteFrame;
        }
    }

    return frames;
}

/// Read raw RGB frames from a file, auto-detecting frame count from file size.
pub fn readFramesAuto(
    alloc: std.mem.Allocator,
    path: []const u8,
    frame_width: u32,
    frame_height: u32,
) ![][]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const frame_size = @as(usize, frame_width) * frame_height * 3;
    const file_size = try file.getEndPos();
    const frame_count = file_size / frame_size;
    if (file_size % frame_size != 0) return error.PartialFrame;

    return readFrames(alloc, path, frame_width, frame_height, @intCast(frame_count));
}

/// Free frames allocated by readFrames or readFramesAuto.
pub fn freeFrames(alloc: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |frame| alloc.free(frame);
    alloc.free(frames);
}

/// Write a single frame as a PNG-like raw image (for testing/debugging).
/// Format: width(4) + height(4) + raw RGB data.
pub fn writeRawImage(
    frame: []const u8,
    frame_width: u32,
    frame_height: u32,
    path: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], frame_width, .little);
    std.mem.writeInt(u32, hdr[4..8], frame_height, .little);
    try file.writeAll(&hdr);
    try file.writeAll(frame);
}

/// Read a raw image file (width + height + RGB data).
pub fn readRawImage(
    alloc: std.mem.Allocator,
    path: []const u8,
    frame_width: *u32,
    frame_height: *u32,
) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hdr: [8]u8 = undefined;
    const n = try file.readAll(&hdr);
    if (n != 8) return error.ShortHeader;
    frame_width.* = std.mem.readInt(u32, hdr[0..4], .little);
    frame_height.* = std.mem.readInt(u32, hdr[4..8], .little);

    const frame_size = @as(usize, frame_width.*) * frame_height.* * 3;
    const data = try alloc.alloc(u8, frame_size);
    errdefer alloc.free(data);
    const read = try file.readAll(data);
    if (read != frame_size) {
        alloc.free(data);
        return error.IncompleteImage;
    }
    return data;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "write and read frames round-trip" {
    const alloc = std.testing.allocator;
    const frame_size = 4 * 4 * 3;
    const frames = try alloc.alloc([]u8, 2);
    defer {
        for (frames) |f| alloc.free(f);
        alloc.free(frames);
    }
    for (frames, 0..) |*f, i| {
        f.* = try alloc.alloc(u8, frame_size);
        @memset(f.*, @intCast(i));
    }

    var const_frames = try alloc.alloc([]const u8, 2);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    const tmp_path = "/tmp/isg_test_video.raw";
    try writeFrames(const_frames, tmp_path);

    const read = try readFramesAuto(alloc, tmp_path, 4, 4);
    defer freeFrames(alloc, read);

    try std.testing.expectEqual(@as(usize, 2), read.len);
    try std.testing.expectEqualSlices(u8, frames[0], read[0]);
    try std.testing.expectEqualSlices(u8, frames[1], read[1]);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "writeRawImage and readRawImage round-trip" {
    const alloc = std.testing.allocator;
    const w: u32 = 8;
    const h: u32 = 8;
    var frame: [8 * 8 * 3]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    const tmp_path = "/tmp/isg_test_image.raw";
    try writeRawImage(&frame, w, h, tmp_path);

    var rw: u32 = 0;
    var rh: u32 = 0;
    const data = try readRawImage(alloc, tmp_path, &rw, &rh);
    defer alloc.free(data);

    try std.testing.expectEqual(w, rw);
    try std.testing.expectEqual(h, rh);
    try std.testing.expectEqualSlices(u8, &frame, data);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "readFramesAuto detects partial frame" {
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/isg_test_partial.raw";
    const file = try std.fs.cwd().createFile(tmp_path, .{});
    try file.writeAll(&[_]u8{ 1, 2, 3, 4, 5 }); // 5 bytes, not a multiple of 4*4*3=48
    file.close();

    const result = readFramesAuto(alloc, tmp_path, 4, 4);
    try std.testing.expectError(error.PartialFrame, result);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}
