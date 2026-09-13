//! opencv_bridge.zig — OpenCV C API bridge for ISG video frame extraction.
//!
//! Uses the OpenCV C API (videoio_c.h) to read/write video files (MP4, AVI).
//! Each frame is extracted as raw RGB24 pixels for the ISG packer/unpacker.
//! The C API is directly callable from Zig via @cImport — no C++ wrapper needed.
//!
//! Prerequisites: libopencv-dev (or opencv4) installed
//! Build: zig build -Dopencv (links against -lopencv_core -lopencv_videoio)

const std = @import("std");

const cv = @cImport({
    @cInclude("opencv2/core/cvdef.h");
    @cInclude("opencv2/videoio/videoio_c.h");
    @cInclude("opencv2/imgproc/imgproc_c.h");
});

/// Frame dimensions.
pub const FrameDim = struct {
    width: u32,
    height: u32,
};

/// Video reader handle.
pub const VideoReader = struct {
    capture: ?*cv.CvCapture = null,
    frame_count: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    fps: f64 = 0.0,

    /// Open a video file for reading.
    pub fn open(path: [*:0]const u8) !VideoReader {
        const cap = cv.cvCreateFileCapture(path) orelse return error.OpenFailed;
        const frame_count: u32 = @intCast(cv.cvGetCaptureProperty(cap, cv.CV_CAP_PROP_FRAME_COUNT));
        const width: u32 = @intCast(cv.cvGetCaptureProperty(cap, cv.CV_CAP_PROP_FRAME_WIDTH));
        const height: u32 = @intCast(cv.cvGetCaptureProperty(cap, cv.CV_CAP_PROP_FRAME_HEIGHT));
        const fps = cv.cvGetCaptureProperty(cap, cv.CV_CAP_PROP_FPS);
        if (width == 0 or height == 0) return error.InvalidVideo;
        return .{
            .capture = cap,
            .frame_count = frame_count,
            .width = width,
            .height = height,
            .fps = fps,
        };
    }

    /// Read the next frame as raw RGB24 bytes (width * height * 3).
    pub fn readFrame(self: *VideoReader, alloc: std.mem.Allocator) !?[]u8 {
        const frame = cv.cvQueryFrame(self.capture) orelse return null;
        // Convert IplImage to RGB24
        const w: u32 = @intCast(frame.width);
        const h: u32 = @intCast(frame.height);
        const buf = try alloc.alloc(u8, w * h * 3);

        // Create a temporary RGB image
        const rgb_frame = cv.cvCreateImage(
            cv.CvSize{ .width = frame.width, .height = frame.height },
            frame.depth,
            3,
        );
        if (rgb_frame == null) {
            alloc.free(buf);
            return error.ConvertFailed;
        }
        defer cv.cvReleaseImage(&rgb_frame);

        cv.cvCvtColor(frame, rgb_frame, cv.CV_BGR2RGB);

        // Copy pixel data
        const channels: u32 = @intCast(rgb_frame.*.nChannels);
        const step: u32 = @intCast(rgb_frame.*.widthStep);
        const data_ptr: [*]u8 = @ptrCast(rgb_frame.*.imageData);

        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const src_offset = y * step + x * channels;
                const dst_offset = (y * w + x) * 3;
                buf[dst_offset] = data_ptr[src_offset];
                buf[dst_offset + 1] = data_ptr[src_offset + 1];
                buf[dst_offset + 2] = data_ptr[src_offset + 2];
            }
        }

        return buf;
    }

    /// Read all frames from the video.
    pub fn readAllFrames(self: *VideoReader, alloc: std.mem.Allocator) ![][]u8 {
        var frames = std.ArrayList([]u8).init(alloc);
        errdefer {
            for (frames.items) |f| alloc.free(f);
            frames.deinit();
        }
        while (try self.readFrame(alloc)) |frame| {
            try frames.append(frame);
        }
        return frames.toOwnedSlice();
    }

    /// Close the video reader.
    pub fn close(self: *VideoReader) void {
        if (self.capture != null) {
            cv.cvReleaseCapture(&self.capture);
            self.capture = null;
        }
    }
};

/// Video writer handle.
pub const VideoWriter = struct {
    writer: ?*cv.CvVideoWriter = null,
    width: u32 = 0,
    height: u32 = 0,
    fps: f64 = 0.0,

    /// Open a video file for writing.
    /// codec: 4-char FourCC code (e.g., "mp4v", "x264", "mpg1")
    pub fn create(
        path: [*:0]const u8,
        width: u32,
        height: u32,
        fps: f64,
        codec: [4]u8,
    ) !VideoWriter {
        const fourcc: c_int = @as(c_int, codec[0]) |
            (@as(c_int, codec[1]) << 8) |
            (@as(c_int, codec[2]) << 16) |
            (@as(c_int, codec[3]) << 24);
        const w = cv.cvCreateVideoWriter(
            path,
            fourcc,
            fps,
            cv.CvSize{
                .width = @intCast(width),
                .height = @intCast(height),
            },
            1, // is_color
        ) orelse return error.WriterCreateFailed;
        return .{
            .writer = w,
            .width = width,
            .height = height,
            .fps = fps,
        };
    }

    /// Write a single RGB24 frame to the video.
    pub fn writeFrame(self: *VideoWriter, frame_data: []const u8) !void {
        const expected_size = self.width * self.height * 3;
        if (frame_data.len < expected_size) return error.FrameTooSmall;

        // Create IplImage from raw RGB data
        const img = cv.cvCreateImage(
            cv.CvSize{
                .width = @intCast(self.width),
                .height = @intCast(self.height),
            },
            cv.IPL_DEPTH_8U,
            3,
        );
        if (img == null) return error.ImageCreateFailed;
        defer cv.cvReleaseImage(&img);

        const channels: u32 = @intCast(img.*.nChannels);
        const step: u32 = @intCast(img.*.widthStep);
        const data_ptr: [*]u8 = @ptrCast(img.*.imageData);

        // Copy RGB data into IplImage (converting RGB to BGR for OpenCV)
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const src_offset = (y * self.width + x) * 3;
                const dst_offset = y * step + x * channels;
                // OpenCV expects BGR, our data is RGB
                data_ptr[dst_offset] = frame_data[src_offset + 2]; // B
                data_ptr[dst_offset + 1] = frame_data[src_offset + 1]; // G
                data_ptr[dst_offset + 2] = frame_data[src_offset]; // R
            }
        }

        if (cv.cvWriteFrame(self.writer, img) < 0) return error.WriteFailed;
    }

    /// Write multiple frames to the video.
    pub fn writeFrames(self: *VideoWriter, frames: []const []const u8) !void {
        for (frames) |frame| try self.writeFrame(frame);
    }

    /// Close the video writer.
    pub fn close(self: *VideoWriter) void {
        if (self.writer != null) {
            cv.cvReleaseVideoWriter(&self.writer);
            self.writer = null;
        }
    }
};

/// Extract all frames from a video file as raw RGB24 byte arrays.
pub fn extractFrames(alloc: std.mem.Allocator, path: []const u8) !struct {
    frames: [][]u8,
    width: u32,
    height: u32,
    fps: f64,
} {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var reader = try VideoReader.open(path_z);
    defer reader.close();
    const frames = try reader.readAllFrames(alloc);
    return .{
        .frames = frames,
        .width = reader.width,
        .height = reader.height,
        .fps = reader.fps,
    };
}

/// Encode raw RGB24 frames into a video file.
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
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var writer = try VideoWriter.create(path_z, width, height, fps, codec);
    defer writer.close();
    try writer.writeFrames(frames);
}

/// Free frames allocated by extractFrames.
pub fn freeFrames(alloc: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |f| alloc.free(f);
    alloc.free(frames);
}

// ─── Tests ─────────────────────────────────────────────────────────────
// Note: These tests require OpenCV to be installed and linked.
// Run with: zig build test -Dopencv

test "FrameDim struct" {
    const dim = FrameDim{ .width = 1920, .height = 1080 };
    try std.testing.expectEqual(@as(u32, 1920), dim.width);
    try std.testing.expectEqual(@as(u32, 1080), dim.height);
}

test "VideoReader and VideoWriter structs compile" {
    // Verify the structs are properly defined
    const reader = VideoReader{};
    try std.testing.expect(reader.capture == null);
    try std.testing.expectEqual(@as(u32, 0), reader.frame_count);

    const writer = VideoWriter{};
    try std.testing.expect(writer.writer == null);
    try std.testing.expectEqual(@as(u32, 0), writer.width);
}
