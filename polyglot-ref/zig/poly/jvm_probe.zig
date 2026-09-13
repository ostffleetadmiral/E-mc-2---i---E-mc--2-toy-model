const std = @import("std");
const poly = @import("poly");

pub fn main() !void {
    var lib_buf: [512]u8 = undefined;
    const lib_path = poly.Java.discoverJvmLib(&lib_buf) orelse {
        std.debug.print("no libjvm found\n", .{});
        return;
    };
    std.debug.print("libjvm: {s}\n", .{lib_path});
    var lib = std.DynLib.open(lib_path) catch |err| {
        std.debug.print("dlopen failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("dlopen ok\n", .{});
    const create = lib.lookup(poly.Java.CreateJVMFn, "JNI_CreateJavaVM") orelse {
        std.debug.print("JNI_CreateJavaVM not found\n", .{});
        return;
    };
    std.debug.print("JNI_CreateJavaVM resolved\n", .{});

    const cp = try std.heap.c_allocator.dupeZ(u8, "/home/projects/Q128.128/zig/poly/java_guest/classes");
    var options = [_]poly.jni.JavaVMOption{
        .{ .optionString = cp.ptr, .extraInfo = null },
    };
    var args = poly.jni.JavaVMInitArgs{
        .version = poly.jni.JNI_VERSION_1_8,
        .nOptions = 1,
        .options = &options,
        .ignoreUnrecognized = poly.jni.JNI_TRUE,
    };
    var jvm_ptr: poly.jni.JavaVM = null;
    var env_ptr: poly.jni.JNIEnv = null;
    std.debug.print("calling JNI_CreateJavaVM...\n", .{});
    const rc = create(@ptrCast(&jvm_ptr), @ptrCast(&env_ptr), @ptrCast(&args));
    std.debug.print("CreateJavaVM rc={d} env={*}\n", .{ rc, env_ptr });
}
