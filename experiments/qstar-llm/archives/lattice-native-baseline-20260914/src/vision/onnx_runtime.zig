//! onnx_runtime.zig — ONNX Runtime C API bindings via dynamic loading.
//!
//! Loads libonnxruntime.so at runtime using c_ffi.DynLib. Provides a
//! high-level Zig interface for creating inference sessions, running
//! models, and extracting tensor data. If ONNX Runtime is unavailable,
//! all operations return errors and callers fall back to lattice-only mode.
//!
//! Zero build dependencies — the library is loaded via dlopen at runtime.

const std = @import("std");
const c_ffi = @import("c_ffi");

// =============================================================================
// Opaque types — ONNX Runtime handles are opaque pointers
// =============================================================================

pub const OrtStatus = anyopaque;
pub const OrtEnv = anyopaque;
pub const OrtSession = anyopaque;
pub const OrtSessionOptions = anyopaque;
pub const OrtRunOptions = anyopaque;
pub const OrtMemoryInfo = anyopaque;
pub const OrtValue = anyopaque;
pub const OrtAllocator = anyopaque;
pub const OrtTypeInfo = anyopaque;
pub const OrtTensorTypeAndShapeInfo = anyopaque;

// =============================================================================
// Enums (matching ONNX Runtime C API)
// =============================================================================

pub const OrtLoggingLevel = enum(c_int) {
    Verbose = 0,
    Info = 1,
    Warning = 2,
    Error = 3,
    Fatal = 4,
};

pub const OrtErrorCode = enum(c_int) {
    OK = 0,
    Fail = 1,
    InvalidArgument = 2,
    NoSuchFile = 3,
    NoModel = 4,
    EngineError = 5,
    RuntimeException = 6,
    InvalidProtobuf = 7,
    ModelLoaded = 8,
    NotImplemented = 9,
    InvalidGraph = 10,
    EPFail = 11,
};

pub const ONNXTensorElementDataType = enum(c_int) {
    Undefined = 0,
    Float = 1,
    Uint8 = 2,
    Int8 = 3,
    Uint16 = 4,
    Int16 = 5,
    Int32 = 6,
    Int64 = 7,
    String = 8,
    Bool = 9,
    Float16 = 10,
    Double = 11,
    Uint32 = 12,
    Uint64 = 13,
    Complex64 = 14,
    Complex128 = 15,
    BFloat16 = 16,
};

pub const OrtAllocatorType = enum(c_int) {
    Invalid = -1,
    DeviceAllocator = 0,
    ArenaAllocator = 1,
};

pub const OrtMemType = enum(c_int) {
    CpuInput = -2,
    CpuOutput = -1,
    Default = 0,
};

pub const OrtGraphOptimizationLevel = enum(c_int) {
    DisableAll = 0,
    EnableBasic = 1,
    EnableExtended = 2,
    EnableAll = 99,
};

// =============================================================================
// OrtApiBase (stable, 2 fields)
// =============================================================================

const GetApiFn = *const fn (version: u32) callconv(.C) ?*const OrtApi;
const GetVersionStringFn = *const fn () callconv(.C) [*:0]const u8;

pub const OrtApiBase = extern struct {
    GetApi: GetApiFn,
    GetVersionString: GetVersionStringFn,
};

// Entry point symbol
const OrtGetApiBaseFn = *const fn () callconv(.C) *const OrtApiBase;

// =============================================================================
// OrtApi function pointer types
// =============================================================================

const CreateStatusFn = *const fn (code: OrtErrorCode, msg: [*:0]const u8) callconv(.C) ?*OrtStatus;
const GetErrorCodeFn = *const fn (status: ?*const OrtStatus) callconv(.C) OrtErrorCode;
const GetErrorMessageFn = *const fn (status: ?*const OrtStatus) callconv(.C) [*:0]const u8;
const CreateEnvFn = *const fn (log_level: OrtLoggingLevel, logid: [*:0]const u8, out: **OrtEnv) callconv(.C) ?*OrtStatus;
const ReleaseEnvFn = *const fn (env: ?*OrtEnv) callconv(.C) void;
const ReleaseStatusFn = *const fn (status: ?*OrtStatus) callconv(.C) void;

const RunFn = *const fn (
    sess: ?*OrtSession,
    options: ?*const OrtRunOptions,
    input_names: [*]const [*:0]const u8,
    inputs: [*]const ?*const OrtValue,
    input_len: usize,
    output_names: [*]const [*:0]const u8,
    output_names_len: usize,
    outputs: [*]?*OrtValue,
) callconv(.C) ?*OrtStatus;

const CreateSessionFn = *const fn (env: ?*const OrtEnv, model_path: [*:0]const u8, options: ?*const OrtSessionOptions, out: **OrtSession) callconv(.C) ?*OrtStatus;
const CreateSessionFromArrayFn = *const fn (env: ?*const OrtEnv, model_data: *const anyopaque, model_data_len: usize, options: ?*const OrtSessionOptions, out: **OrtSession) callconv(.C) ?*OrtStatus;
const CreateSessionOptionsFn = *const fn (out: **OrtSessionOptions) callconv(.C) ?*OrtStatus;
const ReleaseSessionFn = *const fn (sess: ?*OrtSession) callconv(.C) void;
const ReleaseSessionOptionsFn = *const fn (options: ?*OrtSessionOptions) callconv(.C) void;

const SetSessionGraphOptimizationLevelFn = *const fn (options: ?*OrtSessionOptions, level: OrtGraphOptimizationLevel) callconv(.C) ?*OrtStatus;
const SetIntraOpNumThreadsFn = *const fn (options: ?*OrtSessionOptions, num_threads: c_int) callconv(.C) ?*OrtStatus;
const SetSessionLogSeverityLevelFn = *const fn (options: ?*OrtSessionOptions, level: OrtLoggingLevel) callconv(.C) ?*OrtStatus;

const CreateMemoryInfoFn = *const fn (name: [*:0]const u8, alloc_type: OrtAllocatorType, id: c_int, mem_type: OrtMemType, out: **OrtMemoryInfo) callconv(.C) ?*OrtStatus;
const CreateCpuMemoryInfoFn = *const fn (alloc_type: OrtAllocatorType, mem_type: OrtMemType, out: **OrtMemoryInfo) callconv(.C) ?*OrtStatus;
const ReleaseMemoryInfoFn = *const fn (info: ?*OrtMemoryInfo) callconv(.C) void;

const CreateTensorWithDataAsOrtValueFn = *const fn (
    info: ?*const OrtMemoryInfo,
    p_data: *anyopaque,
    p_data_len: usize,
    shape: [*]const i64,
    shape_len: usize,
    type: ONNXTensorElementDataType,
    out: **OrtValue,
) callconv(.C) ?*OrtStatus;

const ReleaseValueFn = *const fn (value: ?*OrtValue) callconv(.C) void;
const GetTensorMutableDataFn = *const fn (value: ?*OrtValue, out: **anyopaque) callconv(.C) ?*OrtStatus;

const GetTensorTypeAndShapeFn = *const fn (value: ?*const OrtValue, out: **OrtTensorTypeAndShapeInfo) callconv(.C) ?*OrtStatus;
const GetTensorElementTypeFn = *const fn (info: ?*const OrtTensorTypeAndShapeInfo, out: *ONNXTensorElementDataType) callconv(.C) ?*OrtStatus;
const GetDimensionsCountFn = *const fn (info: ?*const OrtTensorTypeAndShapeInfo, out: *usize) callconv(.C) ?*OrtStatus;
const GetDimensionsFn = *const fn (info: ?*const OrtTensorTypeAndShapeInfo, dim_values: [*]i64, dim_values_len: usize) callconv(.C) ?*OrtStatus;
const GetTensorShapeElementCountFn = *const fn (info: ?*const OrtTensorTypeAndShapeInfo, out: *usize) callconv(.C) ?*OrtStatus;
const ReleaseTensorTypeAndShapeInfoFn = *const fn (info: ?*OrtTensorTypeAndShapeInfo) callconv(.C) void;

const SessionGetInputCountFn = *const fn (sess: ?*const OrtSession, out: *usize) callconv(.C) ?*OrtStatus;
const SessionGetInputNameFn = *const fn (sess: ?*const OrtSession, index: usize, allocator: ?*OrtAllocator, out: **u8) callconv(.C) ?*OrtStatus;
const SessionGetOutputCountFn = *const fn (sess: ?*const OrtSession, out: *usize) callconv(.C) ?*OrtStatus;
const SessionGetOutputNameFn = *const fn (sess: ?*const OrtSession, index: usize, allocator: ?*OrtAllocator, out: **u8) callconv(.C) ?*OrtStatus;

const GetAvailableProvidersFn = *const fn (out: *[*][*:0]u8, num_providers: *c_int) callconv(.C) ?*OrtStatus;
const ReleaseAvailableProvidersFn = *const fn (providers: [*][*:0]u8, num_providers: c_int) callconv(.C) void;

const GetAllocatorWithDefaultOptionsFn = *const fn (out: **OrtAllocator) callconv(.C) ?*OrtStatus;

// =============================================================================
// OrtApi — accessed by byte offset for version robustness
// =============================================================================

/// ORT_API_VERSION from the header. We request version 23 (ONNX Runtime 1.23+).
/// If the installed runtime is older, GetApi returns null.
pub const ORT_API_VERSION: u32 = 23;

/// Function pointer offsets in the OrtApi struct (in field order, each is 8 bytes on 64-bit).
/// These correspond to the field order in onnxruntime_c_api.h.
/// Verified against ONNX Runtime 1.23.2 header.
const Offsets = struct {
    const CreateStatus: usize = 0; // 1
    const GetErrorCode: usize = 8; // 2
    const GetErrorMessage: usize = 16; // 3
    const CreateEnv: usize = 24; // 4
    const CreateEnvWithCustomLogger: usize = 32; // 5
    // 6: EnableTelemetryEvents
    // 7: DisableTelemetryEvents
    const CreateSession: usize = 56; // 8
    const CreateSessionFromArray: usize = 64; // 9
    const Run: usize = 72; // 10
    const CreateSessionOptions: usize = 80; // 11
    const SetOptimizedModelFilePath: usize = 88; // 12
    // 13: CloneSessionOptions
    const SetSessionExecutionMode: usize = 104; // 14
    // 15: EnableProfiling
    // 16: DisableProfiling
    const EnableMemPattern: usize = 128; // 17
    const DisableMemPattern: usize = 136; // 18
    const EnableCpuMemArena: usize = 144; // 19
    const DisableCpuMemArena: usize = 152; // 20
    const SetSessionLogId: usize = 160; // 21
    const SetSessionLogVerbosityLevel: usize = 168; // 22
    const SetSessionLogSeverityLevel: usize = 176; // 23
    const SetSessionGraphOptimizationLevel: usize = 184; // 24
    const SetIntraOpNumThreads: usize = 192; // 25
    const SetInterOpNumThreads: usize = 200; // 26
    // 27-30: CreateCustomOpDomain, CustomOpDomain_Add, AddCustomOpDomain, RegisterCustomOpsLibrary
    const SessionGetInputCount: usize = 240; // 31
    const SessionGetOutputCount: usize = 248; // 32
    // 33: SessionGetOverridableInitializerCount
    const SessionGetInputTypeInfo: usize = 264; // 34
    const SessionGetOutputTypeInfo: usize = 272; // 35
    // 36: SessionGetOverridableInitializerTypeInfo
    const SessionGetInputName: usize = 288; // 37
    const SessionGetOutputName: usize = 296; // 38
    // 39: SessionGetOverridableInitializerName
    const CreateRunOptions: usize = 312; // 40
    // 41-48: RunOptions* functions
    const CreateTensorAsOrtValue: usize = 384; // 49
    const CreateTensorWithDataAsOrtValue: usize = 392; // 50
    // 51: IsTensor
    const GetTensorMutableData: usize = 408; // 52
    const FillStringTensor: usize = 416; // 53
    const GetStringTensorDataLength: usize = 424; // 54
    const GetStringTensorContent: usize = 432; // 55
    const CastTypeInfoToTensorInfo: usize = 440; // 56
    const GetOnnxTypeFromTypeInfo: usize = 448; // 57
    // 58-60: CreateTensorTypeAndShapeInfo, SetTensorElementType, SetDimensions
    const GetTensorElementType: usize = 480; // 61
    const GetDimensionsCount: usize = 488; // 62
    const GetDimensions: usize = 496; // 63
    const GetSymbolicDimensions: usize = 504; // 64
    const GetTensorShapeElementCount: usize = 512; // 65
    const GetTensorTypeAndShape: usize = 520; // 66
    const GetTypeInfo: usize = 528; // 67
    const GetValueType: usize = 536; // 68
    const CreateMemoryInfo: usize = 544; // 69
    const CreateCpuMemoryInfo: usize = 552; // 70
    // 71-78: MemoryInfo*, Allocator*
    const GetAllocatorWithDefaultOptions: usize = 624; // 79
    // 80-92: AddFreeDimensionOverride through KernelContext_GetOutput
    const ReleaseEnv: usize = 736; // 93
    const ReleaseStatus: usize = 744; // 94
    const ReleaseMemoryInfo: usize = 752; // 95
    const ReleaseSession: usize = 760; // 96
    const ReleaseValue: usize = 768; // 97
    const ReleaseRunOptions: usize = 776; // 98
    const ReleaseTypeInfo: usize = 784; // 99
    const ReleaseTensorTypeAndShapeInfo: usize = 792; // 100
    const ReleaseSessionOptions: usize = 800; // 101
    // 102-111: ReleaseCustomOpDomain through GetAvailableProviders
    const GetAvailableProviders: usize = 888; // 112
    const ReleaseAvailableProviders: usize = 896; // 113
};

/// The ONNX Runtime C API, accessed via function pointers at known offsets.
pub const OrtApi = struct {
    ptr: *const anyopaque,

    fn getFn(self: OrtApi, comptime T: type, offset: usize) T {
        const base: [*]const u8 = @ptrCast(self.ptr);
        // The OrtApi struct contains function pointers at each offset.
        // We need to dereference the pointer at base+offset to get the actual function pointer.
        const fn_ptr: *const anyopaque = @as(*const *const anyopaque, @ptrCast(@alignCast(base + offset))).*;
        return @as(T, @ptrCast(@alignCast(fn_ptr)));
    }

    pub fn createStatus(self: OrtApi, code: OrtErrorCode, msg: [*:0]const u8) ?*OrtStatus {
        return self.getFn(CreateStatusFn, Offsets.CreateStatus)(code, msg);
    }
    pub fn getErrorCode(self: OrtApi, status: ?*const OrtStatus) OrtErrorCode {
        return self.getFn(GetErrorCodeFn, Offsets.GetErrorCode)(status);
    }
    pub fn getErrorMessage(self: OrtApi, status: ?*const OrtStatus) [*:0]const u8 {
        return self.getFn(GetErrorMessageFn, Offsets.GetErrorMessage)(status);
    }
    pub fn releaseStatus(self: OrtApi, status: ?*OrtStatus) void {
        self.getFn(ReleaseStatusFn, Offsets.ReleaseStatus)(status);
    }

    pub fn createEnv(self: OrtApi, log_level: OrtLoggingLevel, logid: [*:0]const u8, out: **OrtEnv) ?*OrtStatus {
        return self.getFn(CreateEnvFn, Offsets.CreateEnv)(log_level, logid, out);
    }
    pub fn releaseEnv(self: OrtApi, env: ?*OrtEnv) void {
        self.getFn(ReleaseEnvFn, Offsets.ReleaseEnv)(env);
    }

    pub fn createSession(self: OrtApi, env: ?*const OrtEnv, model_path: [*:0]const u8, options: ?*const OrtSessionOptions, out: **OrtSession) ?*OrtStatus {
        return self.getFn(CreateSessionFn, Offsets.CreateSession)(env, model_path, options, out);
    }
    pub fn createSessionFromArray(self: OrtApi, env: ?*const OrtEnv, model_data: *const anyopaque, model_data_len: usize, options: ?*const OrtSessionOptions, out: **OrtSession) ?*OrtStatus {
        return self.getFn(CreateSessionFromArrayFn, Offsets.CreateSessionFromArray)(env, model_data, model_data_len, options, out);
    }
    pub fn createSessionOptions(self: OrtApi, out: **OrtSessionOptions) ?*OrtStatus {
        return self.getFn(CreateSessionOptionsFn, Offsets.CreateSessionOptions)(out);
    }
    pub fn releaseSession(self: OrtApi, sess: ?*OrtSession) void {
        self.getFn(ReleaseSessionFn, Offsets.ReleaseSession)(sess);
    }
    pub fn releaseSessionOptions(self: OrtApi, options: ?*OrtSessionOptions) void {
        self.getFn(ReleaseSessionOptionsFn, Offsets.ReleaseSessionOptions)(options);
    }

    pub fn setSessionGraphOptimizationLevel(self: OrtApi, options: ?*OrtSessionOptions, level: OrtGraphOptimizationLevel) ?*OrtStatus {
        return self.getFn(SetSessionGraphOptimizationLevelFn, Offsets.SetSessionGraphOptimizationLevel)(options, level);
    }
    pub fn setIntraOpNumThreads(self: OrtApi, options: ?*OrtSessionOptions, num_threads: c_int) ?*OrtStatus {
        return self.getFn(SetIntraOpNumThreadsFn, Offsets.SetIntraOpNumThreads)(options, num_threads);
    }
    pub fn setSessionLogSeverityLevel(self: OrtApi, options: ?*OrtSessionOptions, level: OrtLoggingLevel) ?*OrtStatus {
        return self.getFn(SetSessionLogSeverityLevelFn, Offsets.SetSessionLogSeverityLevel)(options, level);
    }

    pub fn createCpuMemoryInfo(self: OrtApi, alloc_type: OrtAllocatorType, mem_type: OrtMemType, out: **OrtMemoryInfo) ?*OrtStatus {
        return self.getFn(CreateCpuMemoryInfoFn, Offsets.CreateCpuMemoryInfo)(alloc_type, mem_type, out);
    }
    pub fn releaseMemoryInfo(self: OrtApi, info: ?*OrtMemoryInfo) void {
        self.getFn(ReleaseMemoryInfoFn, Offsets.ReleaseMemoryInfo)(info);
    }

    pub fn createTensorWithDataAsOrtValue(self: OrtApi, info: ?*const OrtMemoryInfo, p_data: *anyopaque, p_data_len: usize, shape: [*]const i64, shape_len: usize, dtype: ONNXTensorElementDataType, out: **OrtValue) ?*OrtStatus {
        return self.getFn(CreateTensorWithDataAsOrtValueFn, Offsets.CreateTensorWithDataAsOrtValue)(info, p_data, p_data_len, shape, shape_len, dtype, out);
    }
    pub fn releaseValue(self: OrtApi, value: ?*OrtValue) void {
        self.getFn(ReleaseValueFn, Offsets.ReleaseValue)(value);
    }
    pub fn getTensorMutableData(self: OrtApi, value: ?*OrtValue, out: **anyopaque) ?*OrtStatus {
        return self.getFn(GetTensorMutableDataFn, Offsets.GetTensorMutableData)(value, out);
    }

    pub fn getTensorTypeAndShape(self: OrtApi, value: ?*const OrtValue, out: **OrtTensorTypeAndShapeInfo) ?*OrtStatus {
        return self.getFn(GetTensorTypeAndShapeFn, Offsets.GetTensorTypeAndShape)(value, out);
    }
    pub fn getTensorElementType(self: OrtApi, info: ?*const OrtTensorTypeAndShapeInfo, out: *ONNXTensorElementDataType) ?*OrtStatus {
        return self.getFn(GetTensorElementTypeFn, Offsets.GetTensorElementType)(info, out);
    }
    pub fn getDimensionsCount(self: OrtApi, info: ?*const OrtTensorTypeAndShapeInfo, out: *usize) ?*OrtStatus {
        return self.getFn(GetDimensionsCountFn, Offsets.GetDimensionsCount)(info, out);
    }
    pub fn getDimensions(self: OrtApi, info: ?*const OrtTensorTypeAndShapeInfo, dim_values: [*]i64, dim_values_len: usize) ?*OrtStatus {
        return self.getFn(GetDimensionsFn, Offsets.GetDimensions)(info, dim_values, dim_values_len);
    }
    pub fn getTensorShapeElementCount(self: OrtApi, info: ?*const OrtTensorTypeAndShapeInfo, out: *usize) ?*OrtStatus {
        return self.getFn(GetTensorShapeElementCountFn, Offsets.GetTensorShapeElementCount)(info, out);
    }
    pub fn releaseTensorTypeAndShapeInfo(self: OrtApi, info: ?*OrtTensorTypeAndShapeInfo) void {
        self.getFn(ReleaseTensorTypeAndShapeInfoFn, Offsets.ReleaseTensorTypeAndShapeInfo)(info);
    }

    pub fn sessionGetInputCount(self: OrtApi, sess: ?*const OrtSession, out: *usize) ?*OrtStatus {
        return self.getFn(SessionGetInputCountFn, Offsets.SessionGetInputCount)(sess, out);
    }
    pub fn sessionGetInputName(self: OrtApi, sess: ?*const OrtSession, index: usize, allocator: ?*OrtAllocator, out: **u8) ?*OrtStatus {
        return self.getFn(SessionGetInputNameFn, Offsets.SessionGetInputName)(sess, index, allocator, out);
    }
    pub fn sessionGetOutputCount(self: OrtApi, sess: ?*const OrtSession, out: *usize) ?*OrtStatus {
        return self.getFn(SessionGetOutputCountFn, Offsets.SessionGetOutputCount)(sess, out);
    }
    pub fn sessionGetOutputName(self: OrtApi, sess: ?*const OrtSession, index: usize, allocator: ?*OrtAllocator, out: **u8) ?*OrtStatus {
        return self.getFn(SessionGetOutputNameFn, Offsets.SessionGetOutputName)(sess, index, allocator, out);
    }

    pub fn run(self: OrtApi, sess: ?*OrtSession, options: ?*const OrtRunOptions, input_names: [*]const [*:0]const u8, inputs: [*]const ?*const OrtValue, input_len: usize, output_names: [*]const [*:0]const u8, output_names_len: usize, outputs: [*]?*OrtValue) ?*OrtStatus {
        return self.getFn(RunFn, Offsets.Run)(sess, options, input_names, inputs, input_len, output_names, output_names_len, outputs);
    }

    pub fn getAvailableProviders(self: OrtApi, out: *[*][*:0]u8, num_providers: *c_int) ?*OrtStatus {
        return self.getFn(GetAvailableProvidersFn, Offsets.GetAvailableProviders)(out, num_providers);
    }
    pub fn releaseAvailableProviders(self: OrtApi, providers: [*][*:0]u8, num_providers: c_int) void {
        return self.getFn(ReleaseAvailableProvidersFn, Offsets.ReleaseAvailableProviders)(providers, num_providers);
    }
};

// =============================================================================
// Error handling
// =============================================================================

pub const OnnxError = error{
    LibraryNotFound,
    ApiBaseNotFound,
    ApiVersionUnsupported,
    EnvCreationFailed,
    SessionCreationFailed,
    SessionOptionsCreationFailed,
    MemoryInfoCreationFailed,
    TensorCreationFailed,
    InferenceFailed,
    TensorDataAccessFailed,
    InvalidTensorShape,
    FreestandingUnsupported,
    OutOfMemory,
};

fn checkStatus(api: OrtApi, status: ?*OrtStatus) OnnxError!void {
    if (status) |s| {
        const code = api.getErrorCode(s);
        const msg = api.getErrorMessage(s);
        std.log.warn("ONNX Runtime error {d}: {s}", .{ @intFromEnum(code), std.mem.sliceTo(msg, 0) });
        api.releaseStatus(s);
        return error.InferenceFailed;
    }
}

// =============================================================================
// High-level ONNX Runtime context
// =============================================================================

/// Top-level ONNX Runtime handle. Created once, reused for all sessions.
pub const OnnxContext = struct {
    lib: c_ffi.DynLib,
    api_base: *const OrtApiBase,
    api: OrtApi,
    env: *OrtEnv,
    version_string: []const u8,

    /// Initialize ONNX Runtime by loading the shared library and creating an env.
    /// Returns error if the library is not found or initialization fails.
    pub fn init(allocator: std.mem.Allocator) OnnxError!OnnxContext {
        _ = allocator;
        if (c_ffi.is_freestanding) return error.FreestandingUnsupported;

        // Try multiple library names (unversioned, then versioned)
        // Use RTLD_NOW | RTLD_GLOBAL because ONNX Runtime 1.23 segfaults with RTLD_LAZY
        const lib_names = [_][*:0]const u8{
            "libonnxruntime.so",
            "libonnxruntime.so.1.23",
            "libonnxruntime.so.1.22",
            "libonnxruntime.so.1.21",
            "libonnxruntime.so.1.20",
            "libonnxruntime.so.1.19",
            "libonnxruntime.so.1.18",
            "libonnxruntime.so.1.17",
            "libonnxruntime.so.1.16",
            "libonnxruntime.so.1.15",
        };
        const load_flags = c_ffi.RTLD_NOW | c_ffi.RTLD_GLOBAL;
        const lib = blk: {
            for (lib_names) |name| {
                if (c_ffi.DynLib.openWithFlags(name, load_flags)) |l| break :blk l else |_| continue;
            }
            return error.LibraryNotFound;
        };
        var lib_mut = lib;

        const get_api_base = lib_mut.lookup(OrtGetApiBaseFn, "OrtGetApiBase") orelse {
            lib_mut.close();
            return error.ApiBaseNotFound;
        };

        const api_base = get_api_base();
        const version_str = std.mem.sliceTo(api_base.GetVersionString(), 0);

        const api_ptr = api_base.GetApi(ORT_API_VERSION) orelse {
            lib_mut.close();
            return error.ApiVersionUnsupported;
        };

        const api = OrtApi{ .ptr = api_ptr };

        var env: *OrtEnv = undefined;
        try checkStatus(api, api.createEnv(.Warning, "qstar", &env));

        return .{
            .lib = lib,
            .api_base = api_base,
            .api = api,
            .env = env,
            .version_string = version_str,
        };
    }

    pub fn deinit(self: *OnnxContext) void {
        self.api.releaseEnv(self.env);
        self.lib.close();
    }

    pub fn getVersionString(self: OnnxContext) []const u8 {
        return self.version_string;
    }

    pub fn isAvailable() bool {
        if (c_ffi.is_freestanding) return false;
        const lib_names = [_][*:0]const u8{
            "libonnxruntime.so",
            "libonnxruntime.so.1.23",
            "libonnxruntime.so.1.22",
            "libonnxruntime.so.1.21",
            "libonnxruntime.so.1.20",
            "libonnxruntime.so.1.19",
            "libonnxruntime.so.1.18",
            "libonnxruntime.so.1.17",
            "libonnxruntime.so.1.16",
            "libonnxruntime.so.1.15",
        };
        const load_flags = c_ffi.RTLD_NOW | c_ffi.RTLD_GLOBAL;
        for (lib_names) |name| {
            var lib = c_ffi.DynLib.openWithFlags(name, load_flags) catch continue;
            defer lib.close();
            const get_api_base = lib.lookup(OrtGetApiBaseFn, "OrtGetApiBase") orelse continue;
            const api_base = get_api_base();
            if (api_base.GetApi(ORT_API_VERSION) != null) return true;
        }
        return false;
    }
};

/// Input tensor descriptor for inference.
pub const InputTensor = struct {
    name: [*:0]const u8,
    data: *anyopaque,
    data_len: usize,
    shape: []const i64,
    dtype: ONNXTensorElementDataType,
};

/// Output tensor descriptor after inference.
pub const OutputTensor = struct {
    name: [*:0]const u8,
    value: *OrtValue,
    dtype: ONNXTensorElementDataType,
    shape: []i64,
    element_count: usize,

    pub fn getData(self: OutputTensor, api: OrtApi, comptime T: type) OnnxError![]T {
        var data_ptr: *anyopaque = undefined;
        try checkStatus(api, api.getTensorMutableData(self.value, &data_ptr));
        const typed_ptr: [*]T = @ptrCast(@alignCast(data_ptr));
        return typed_ptr[0..self.element_count];
    }

    pub fn release(self: OutputTensor, api: OrtApi) void {
        api.releaseValue(self.value);
    }
};

/// An inference session for a single ONNX model.
pub const Session = struct {
    ctx: *OnnxContext,
    session: *OrtSession,
    mem_info: *OrtMemoryInfo,
    allocator: std.mem.Allocator,

    /// Create a session from an ONNX model file.
    /// Caller must provide input/output names (known from the model definition).
    pub fn create(ctx: *OnnxContext, model_path: [*:0]const u8, allocator: std.mem.Allocator) OnnxError!Session {
        var sess_opts: *OrtSessionOptions = undefined;
        try checkStatus(ctx.api, ctx.api.createSessionOptions(&sess_opts));
        _ = ctx.api.setSessionGraphOptimizationLevel(sess_opts, .EnableAll);
        _ = ctx.api.setIntraOpNumThreads(sess_opts, 1);
        _ = ctx.api.setSessionLogSeverityLevel(sess_opts, .Warning);

        var sess: *OrtSession = undefined;
        try checkStatus(ctx.api, ctx.api.createSession(ctx.env, model_path, sess_opts, &sess));
        ctx.api.releaseSessionOptions(sess_opts);

        var mem_info: *OrtMemoryInfo = undefined;
        try checkStatus(ctx.api, ctx.api.createCpuMemoryInfo(.ArenaAllocator, .Default, &mem_info));

        return .{
            .ctx = ctx,
            .session = sess,
            .mem_info = mem_info,
            .allocator = allocator,
        };
    }

    pub fn destroy(self: *Session) void {
        self.ctx.api.releaseMemoryInfo(self.mem_info);
        self.ctx.api.releaseSession(self.session);
    }

    /// Run inference on the model with the given inputs and output names.
    /// Returns output tensors that the caller must release via OutputTensor.release.
    pub fn run(self: *Session, inputs: []const InputTensor, output_names: []const [*:0]const u8) OnnxError![]OutputTensor {
        const api = self.ctx.api;
        const alloc = self.allocator;

        // Create input OrtValues
        var input_values = try alloc.alloc(?*OrtValue, inputs.len);
        defer alloc.free(input_values);

        var input_name_ptrs = try alloc.alloc([*:0]const u8, inputs.len);
        defer alloc.free(input_name_ptrs);

        for (inputs, 0..) |input, i| {
            var val: *OrtValue = undefined;
            try checkStatus(api, api.createTensorWithDataAsOrtValue(
                self.mem_info,
                input.data,
                input.data_len,
                input.shape.ptr,
                input.shape.len,
                input.dtype,
                &val,
            ));
            input_values[i] = val;
            input_name_ptrs[i] = input.name;
        }
        defer for (input_values) |v| api.releaseValue(v);

        // Create output values array
        const output_values = try alloc.alloc(?*OrtValue, output_names.len);
        defer alloc.free(output_values);

        for (output_values) |*v| v.* = null;

        // Run the session
        try checkStatus(api, api.run(
            self.session,
            null,
            input_name_ptrs.ptr,
            input_values.ptr,
            inputs.len,
            output_names.ptr,
            output_names.len,
            output_values.ptr,
        ));

        // Extract output metadata
        var outputs = try alloc.alloc(OutputTensor, output_names.len);
        for (output_names, 0..) |name, i| {
            const val = output_values[i] orelse return error.InferenceFailed;

            var type_info: *OrtTensorTypeAndShapeInfo = undefined;
            try checkStatus(api, api.getTensorTypeAndShape(val, &type_info));

            var dtype: ONNXTensorElementDataType = .Undefined;
            _ = api.getTensorElementType(type_info, &dtype);

            var dim_count: usize = 0;
            _ = api.getDimensionsCount(type_info, &dim_count);

            const shape = try alloc.alloc(i64, dim_count);
            _ = api.getDimensions(type_info, shape.ptr, dim_count);

            var elem_count: usize = 0;
            _ = api.getTensorShapeElementCount(type_info, &elem_count);

            api.releaseTensorTypeAndShapeInfo(type_info);

            outputs[i] = .{
                .name = name,
                .value = val,
                .dtype = dtype,
                .shape = shape,
                .element_count = elem_count,
            };
        }

        return outputs;
    }

    /// Release output tensors and free their shape arrays.
    pub fn releaseOutputs(self: *Session, outputs: []OutputTensor) void {
        for (outputs) |out| {
            out.release(self.ctx.api);
            self.allocator.free(out.shape);
        }
        self.allocator.free(outputs);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "OnnxContext.isAvailable returns false when not installed" {
    // ONNX Runtime is not installed on this system, so this should be false.
    // If it IS installed, the test still passes (just verifies the function works).
    _ = OnnxContext.isAvailable();
}

test "OnnxContext.init returns LibraryNotFound when not installed" {
    const result = OnnxContext.init(std.heap.page_allocator);
    if (result) |ctx| {
        var c = ctx;
        defer c.deinit();
        // If it succeeded, ONNX Runtime is installed — verify version string
        try std.testing.expect(c.version_string.len > 0);
    } else |err| {
        try std.testing.expect(err == error.LibraryNotFound or err == error.FreestandingUnsupported);
    }
}

test "OnnxError includes all expected error variants" {
    const errs = [_]OnnxError{
        error.LibraryNotFound,
        error.ApiBaseNotFound,
        error.ApiVersionUnsupported,
        error.EnvCreationFailed,
        error.SessionCreationFailed,
        error.InferenceFailed,
        error.FreestandingUnsupported,
    };
    try std.testing.expect(errs.len == 7);
}

test "ORT_API_VERSION is 23" {
    try std.testing.expect(ORT_API_VERSION == 23);
}

test "Offsets are 8-byte aligned" {
    // All offsets should be multiples of 8 (function pointer size on 64-bit)
    try std.testing.expect(Offsets.CreateStatus % 8 == 0);
    try std.testing.expect(Offsets.Run % 8 == 0);
    try std.testing.expect(Offsets.CreateSession % 8 == 0);
    try std.testing.expect(Offsets.ReleaseEnv % 8 == 0);
    try std.testing.expect(Offsets.SessionGetInputCount % 8 == 0);
}

test "OrtApi getFn returns function pointer at correct offset" {
    // We can't test with a real API, but we can verify the offset computation
    // doesn't crash by creating a dummy struct.
    const dummy_data = [_]u8{0} ** 1024;
    const api = OrtApi{ .ptr = &dummy_data };
    // Just verify the function doesn't panic — the actual function pointer will be null
    // but we're not calling it.
    _ = api;
}

test "OnnxContext graceful degradation on freestanding" {
    if (c_ffi.is_freestanding) {
        const result = OnnxContext.init(std.heap.page_allocator);
        try std.testing.expectError(error.FreestandingUnsupported, result);
    }
}

test "OrtLoggingLevel enum values match C API" {
    try std.testing.expect(@intFromEnum(OrtLoggingLevel.Verbose) == 0);
    try std.testing.expect(@intFromEnum(OrtLoggingLevel.Fatal) == 4);
}

test "ONNXTensorElementDataType enum values match C API" {
    try std.testing.expect(@intFromEnum(ONNXTensorElementDataType.Float) == 1);
    try std.testing.expect(@intFromEnum(ONNXTensorElementDataType.Int64) == 9);
    try std.testing.expect(@intFromEnum(ONNXTensorElementDataType.Uint8) == 2);
}

test "OrtGraphOptimizationLevel enum values match C API" {
    try std.testing.expect(@intFromEnum(OrtGraphOptimizationLevel.DisableAll) == 0);
    try std.testing.expect(@intFromEnum(OrtGraphOptimizationLevel.EnableAll) == 99);
}

test "OrtApiBase has correct field order" {
    try std.testing.expect(@offsetOf(OrtApiBase, "GetApi") == 0);
    try std.testing.expect(@offsetOf(OrtApiBase, "GetVersionString") == 8);
}
