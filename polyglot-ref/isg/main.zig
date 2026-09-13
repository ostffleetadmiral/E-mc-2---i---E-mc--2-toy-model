//! main.zig — ISG RGB transcoder CLI.
//!
//! Usage:
//!   isg-rgb pack     <input> <output> [--width 1920] [--height 1080] [--block-scale 4]
//!   isg-rgb unpack   <input> <output> [--width 1920] [--height 1080]
//!   isg-rgb pack-mp4 <input> <output.mp4> [--width 1920] [--height 1080] [--block-scale 4] [--fps 30] [--codec mp4v]
//!   isg-rgb unpack-mp4 <input.mp4> <output>
//!   isg-rgb info     <input>
//!
//! Pack:       Converts a binary file into raw RGB video frames.
//! Unpack:     Converts raw RGB video frames back into the original file.
//! Pack-mp4:   Packs binary file and encodes as MP4 video via OpenCV.
//! Unpack-mp4: Decodes MP4 video via OpenCV and unpacks to original file.
//! Info:       Reads and displays the header from a packed video file.
//!
//! The raw RGB output can also be piped to FFmpeg for MP4 encoding:
//!   isg-rgb pack input.bin /dev/stdout | ffmpeg -f rawvideo -pix_fmt rgb24 \
//!     -s 1920x1080 -i - -c:v libx264 output.mp4

const std = @import("std");
const ec = @import("q128_error_correct.zig");
const packer = @import("rgb_packer.zig");
const unpacker = @import("rgb_unpacker.zig");
const video = @import("video_io.zig");
const opencv = @import("opencv");

fn printUsage() void {
    const usage =
        \\Usage:
        \\  isg-rgb pack       <input> <output> [--width W] [--height H] [--block-scale B]
        \\  isg-rgb unpack     <input> <output> [--width W] [--height H]
        \\  isg-rgb pack-mp4   <input> <output.mp4> [--width W] [--height H] [--block-scale B] [--fps F] [--codec CCCC]
        \\  isg-rgb unpack-mp4 <input.mp4> <output>
        \\  isg-rgb info       <input>
        \\
        \\Commands:
        \\  pack       Pack a binary file into raw RGB video frames
        \\  unpack     Unpack raw RGB video frames back into the original file
        \\  pack-mp4   Pack and encode as MP4 video via OpenCV
        \\  unpack-mp4 Decode MP4 via OpenCV and unpack to original file
        \\  info       Display header info from a packed video file
        \\
        \\Options:
        \\  --width W        Frame width in pixels (default: 1920)
        \\  --height H       Frame height in pixels (default: 1080)
        \\  --block-scale B  Block scale for lossy compression resilience (default: 4)
        \\  --fps F          Video FPS for MP4 encoding (default: 30)
        \\  --codec CCCC     FourCC codec code (default: mp4v)
        \\
        \\Examples:
        \\  isg-rgb pack model.bin output.raw --width 1920 --height 1080 --block-scale 4
        \\  isg-rgb unpack output.raw model_recovered.bin --width 1920 --height 1080
        \\  isg-rgb pack-mp4 model.bin output.mp4 --width 1920 --height 1080 --fps 30
        \\  isg-rgb unpack-mp4 output.mp4 model_recovered.bin
        \\  isg-rgb info output.raw
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn loadFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(alloc, 1 << 40); // 1 TB max
}

fn cmdPack(
    alloc: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    cfg: packer.PackConfig,
) !void {
    std.debug.print("Packing {s} → {s}\n", .{ input_path, output_path });
    std.debug.print("  Frame: {d}×{d}, block_scale: {d}\n", .{ cfg.frame_width, cfg.frame_height, cfg.block_scale });

    const data = try loadFile(alloc, input_path);
    defer alloc.free(data);
    std.debug.print("  Payload: {d} bytes ({d:.2} MB)\n", .{ data.len, @as(f64, @floatFromInt(data.len)) / 1e6 });

    const frames = try packer.pack(alloc, data, cfg);
    defer packer.freeFrames(alloc, frames);

    std.debug.print("  Frames: {d}\n", .{frames.len});

    // Convert to const slices
    var const_frames = try alloc.alloc([]const u8, frames.len);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    try video.writeFrames(const_frames, output_path);

    const total_size = frames.len * @as(usize, cfg.frame_width) * cfg.frame_height * 3;
    const ratio = if (data.len > 0) @as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(data.len)) else 0;
    std.debug.print("  Output: {d} bytes ({d:.2} MB), expansion ratio: {d:.2}x\n", .{ total_size, @as(f64, @floatFromInt(total_size)) / 1e6, ratio });
    std.debug.print("  Done.\n", .{});
}

fn cmdUnpack(
    alloc: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    frame_width: u32,
    frame_height: u32,
) !void {
    std.debug.print("Unpacking {s} → {s}\n", .{ input_path, output_path });
    std.debug.print("  Frame: {d}×{d}\n", .{ frame_width, frame_height });

    const frames = try video.readFramesAuto(alloc, input_path, frame_width, frame_height);
    defer video.freeFrames(alloc, frames);

    std.debug.print("  Frames read: {d}\n", .{frames.len});

    var const_frames = try alloc.alloc([]const u8, frames.len);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    const result = try unpacker.unpack(alloc, const_frames);
    defer unpacker.freeUnpackResult(alloc, result);

    std.debug.print("  Payload: {d} bytes\n", .{result.data.len});
    std.debug.print("  Checksum: {s}\n", .{if (result.checksum_valid) "VALID ✓" else "INVALID ✗"});
    std.debug.print("  Corrupted blocks: {d}/{d}\n", .{ result.corrupted_blocks, result.total_blocks });

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(result.data);

    std.debug.print("  Written to {s}\n", .{output_path});

    if (!result.checksum_valid) {
        std.debug.print("  WARNING: Checksum mismatch! Data may be corrupted.\n", .{});
        return error.ChecksumMismatch;
    }
    std.debug.print("  Done.\n", .{});
}

fn cmdInfo(alloc: std.mem.Allocator, input_path: []const u8) !void {
    const file = try std.fs.cwd().openFile(input_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    // Try common frame sizes to detect dimensions
    const common_sizes = [_]struct { w: u32, h: u32 }{
        .{ .w = 1920, .h = 1080 },
        .{ .w = 1280, .h = 720 },
        .{ .w = 640, .h = 480 },
        .{ .w = 64, .h = 64 },
        .{ .w = 32, .h = 32 },
        .{ .w = 16, .h = 16 },
    };

    var frame_w: u32 = 0;
    var frame_h: u32 = 0;
    for (common_sizes) |dim| {
        const frame_size = @as(usize, dim.w) * dim.h * 3;
        if (file_size >= frame_size and file_size % frame_size == 0) {
            frame_w = dim.w;
            frame_h = dim.h;
            break;
        }
    }

    if (frame_w == 0) {
        // Try square frame
        const total_pixels = file_size / 3;
        const side = @as(u32, @intCast(std.math.sqrt(total_pixels)));
        if (side * side * 3 == file_size) {
            frame_w = side;
            frame_h = side;
        }
    }

    if (frame_w == 0) {
        std.debug.print("Error: Cannot determine frame dimensions from file size ({d} bytes)\n", .{file_size});
        return error.UnknownFrameSize;
    }

    const frame_size = @as(usize, frame_w) * frame_h * 3;
    const frame_buf = try alloc.alloc(u8, frame_size);
    defer alloc.free(frame_buf);
    const n = try file.readAll(frame_buf);
    if (n != frame_size) {
        std.debug.print("Error: Could not read full frame\n", .{});
        return error.ShortFrame;
    }

    // Try common block scales
    const candidate_scales = [_]u32{ 1, 2, 4, 8, 16 };
    var h: ec.Header = undefined;
    var found = false;
    for (candidate_scales) |bs| {
        if (frame_w % bs != 0 or frame_h % bs != 0) continue;
        const candidate = unpacker.parseHeader(frame_buf, frame_w, bs);
        if (ec.validateHeader(&candidate)) {
            h = candidate;
            found = true;
            break;
        }
    }

    if (!found) {
        std.debug.print("Error: Could not parse valid header from first frame\n", .{});
        return error.InvalidHeader;
    }

    std.debug.print("=== ISG RGB File Info ===\n", .{});
    std.debug.print("  Magic:          {s}\n", .{&h.magic});
    std.debug.print("  Version:        {d}\n", .{h.version});
    std.debug.print("  Payload size:   {d} bytes ({d:.2} MB)\n", .{ h.payload_size, @as(f64, @floatFromInt(h.payload_size)) / 1e6 });
    std.debug.print("  Frame size:     {d}×{d}\n", .{ h.frame_width, h.frame_height });
    std.debug.print("  Block scale:   {d}\n", .{h.block_scale});
    std.debug.print("  Frame count:    {d}\n", .{h.frame_count});
    std.debug.print("  Header valid:   {s}\n", .{if (ec.validateHeader(&h)) "YES ✓" else "NO ✗"});

    const expected_size = @as(u64, h.frame_count) * h.frame_width * h.frame_height * 3;
    std.debug.print("  File size:      {d} bytes ({d:.2} MB)\n", .{ file_size, @as(f64, @floatFromInt(file_size)) / 1e6 });
    std.debug.print("  Expected size:  {d} bytes ({d:.2} MB)\n", .{ expected_size, @as(f64, @floatFromInt(expected_size)) / 1e6 });
}

fn cmdPackMp4(
    alloc: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    cfg: packer.PackConfig,
    fps: f64,
    codec: [4]u8,
) !void {
    std.debug.print("Packing {s} → {s} (MP4)\n", .{ input_path, output_path });
    std.debug.print("  Frame: {d}×{d}, block_scale: {d}, fps: {d:.1}, codec: {s}{s}{s}{s}\n", .{
        cfg.frame_width, cfg.frame_height, cfg.block_scale, fps,
        &[_]u8{codec[0]}, &[_]u8{codec[1]}, &[_]u8{codec[2]}, &[_]u8{codec[3]},
    });

    const data = try loadFile(alloc, input_path);
    defer alloc.free(data);
    std.debug.print("  Payload: {d} bytes ({d:.2} MB)\n", .{ data.len, @as(f64, @floatFromInt(data.len)) / 1e6 });

    const frames = try packer.pack(alloc, data, cfg);
    defer packer.freeFrames(alloc, frames);

    std.debug.print("  Frames: {d}\n", .{frames.len});

    var const_frames = try alloc.alloc([]const u8, frames.len);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    try opencv.encodeVideo(alloc, const_frames, cfg.frame_width, cfg.frame_height, fps, output_path, codec);

    std.debug.print("  MP4 written to {s}\n", .{output_path});
    std.debug.print("  Done.\n", .{});
}

fn cmdUnpackMp4(
    alloc: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    std.debug.print("Unpacking {s} → {s} (MP4)\n", .{ input_path, output_path });

    const result = try opencv.extractFrames(alloc, input_path);
    defer opencv.freeFrames(alloc, result.frames);

    std.debug.print("  Frames decoded: {d}\n", .{result.frames.len});
    std.debug.print("  Frame size: {d}×{d}, fps: {d:.1}\n", .{ result.width, result.height, result.fps });

    var const_frames = try alloc.alloc([]const u8, result.frames.len);
    defer alloc.free(const_frames);
    for (result.frames, 0..) |f, i| const_frames[i] = f;

    const unpack_result = try unpacker.unpack(alloc, const_frames);
    defer unpacker.freeUnpackResult(alloc, unpack_result);

    std.debug.print("  Payload: {d} bytes\n", .{unpack_result.data.len});
    std.debug.print("  Checksum: {s}\n", .{if (unpack_result.checksum_valid) "VALID ✓" else "INVALID ✗"});
    std.debug.print("  Corrupted blocks: {d}/{d}\n", .{ unpack_result.corrupted_blocks, unpack_result.total_blocks });

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(unpack_result.data);

    std.debug.print("  Written to {s}\n", .{output_path});

    if (!unpack_result.checksum_valid) {
        std.debug.print("  WARNING: Checksum mismatch! Data may be corrupted.\n", .{});
        return error.ChecksumMismatch;
    }
    std.debug.print("  Done.\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "pack")) {
        if (args.len < 4) {
            std.debug.print("Error: pack requires <input> <output>\n", .{});
            printUsage();
            return;
        }
        const input_path = args[2];
        const output_path = args[3];

        var cfg = packer.PackConfig{};
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
                cfg.frame_width = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid width\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--height") and i + 1 < args.len) {
                cfg.frame_height = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid height\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--block-scale") and i + 1 < args.len) {
                cfg.block_scale = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid block-scale\n", .{});
                    return;
                };
                i += 1;
            }
        }

        cmdPack(alloc, input_path, output_path, cfg) catch |err| {
            std.debug.print("Pack error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "unpack")) {
        if (args.len < 4) {
            std.debug.print("Error: unpack requires <input> <output>\n", .{});
            printUsage();
            return;
        }
        const input_path = args[2];
        const output_path = args[3];

        var frame_width: u32 = 1920;
        var frame_height: u32 = 1080;
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
                frame_width = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid width\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--height") and i + 1 < args.len) {
                frame_height = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid height\n", .{});
                    return;
                };
                i += 1;
            }
        }

        cmdUnpack(alloc, input_path, output_path, frame_width, frame_height) catch |err| {
            std.debug.print("Unpack error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "pack-mp4")) {
        if (args.len < 4) {
            std.debug.print("Error: pack-mp4 requires <input> <output.mp4>\n", .{});
            printUsage();
            return;
        }
        const input_path = args[2];
        const output_path = args[3];

        var cfg = packer.PackConfig{};
        var fps: f64 = 30.0;
        var codec: [4]u8 = .{ 'm', 'p', '4', 'v' };
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
                cfg.frame_width = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid width\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--height") and i + 1 < args.len) {
                cfg.frame_height = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid height\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--block-scale") and i + 1 < args.len) {
                cfg.block_scale = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Error: invalid block-scale\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--fps") and i + 1 < args.len) {
                fps = std.fmt.parseFloat(f64, args[i + 1]) catch 30.0;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--codec") and i + 1 < args.len) {
                const codec_str = args[i + 1];
                if (codec_str.len >= 4) {
                    codec[0] = codec_str[0];
                    codec[1] = codec_str[1];
                    codec[2] = codec_str[2];
                    codec[3] = codec_str[3];
                }
                i += 1;
            }
        }

        cmdPackMp4(alloc, input_path, output_path, cfg, fps, codec) catch |err| {
            std.debug.print("Pack-mp4 error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "unpack-mp4")) {
        if (args.len < 4) {
            std.debug.print("Error: unpack-mp4 requires <input.mp4> <output>\n", .{});
            printUsage();
            return;
        }
        const input_path = args[2];
        const output_path = args[3];

        cmdUnpackMp4(alloc, input_path, output_path) catch |err| {
            std.debug.print("Unpack-mp4 error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "info")) {
        if (args.len < 3) {
            std.debug.print("Error: info requires <input>\n", .{});
            printUsage();
            return;
        }
        cmdInfo(alloc, args[2]) catch |err| {
            std.debug.print("Info error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
        printUsage();
    }
}
