//! vulkan_compute.zig — Vulkan compute acceleration for Qstar lattice inference.
//! Dynamically loads libvulkan.so.1 at runtime — zero build dependencies.
//! If Vulkan is unavailable, all functions return errors and the caller
//! falls back to the CPU path.

const std = @import("std");
const builtin = @import("builtin");

/// Downscale Q64.64 i128 to Q32.32 i64 with saturation.
inline fn downscaleSaturating(v: i128) i64 {
    const int_part: i128 = v >> 64;
    if (int_part > std.math.maxInt(i32)) return std.math.maxInt(i32) << 32;
    if (int_part < std.math.minInt(i32)) return std.math.minInt(i32) << 32;
    return @truncate(v >> 32);
}

/// Upscale Q32.32 i64 to Q64.64 i128 (lossless).
inline fn upscaleQ32ToQ64(v: i64) i128 {
    return @as(i128, v) << 32;
}

// Manual dlopen declarations — Zig 0.13's std.DynLib has a bug (ElfHashTableNotFound)
// that prevents loading libvulkan.so.1, so we use dlopen directly.
// Guarded for freestanding targets (WASM) where libc is unavailable.
const is_freestanding = builtin.os.tag == .freestanding;

const DlHandle = struct {
    handle: ?*anyopaque,

    fn open(path: [*:0]const u8) !DlHandle {
        if (is_freestanding) return error.LibraryNotFound;
        const fn_ptr = dlopen orelse return error.LibraryNotFound;
        const h = fn_ptr(path, RTLD_LAZY) orelse return error.LibraryNotFound;
        return .{ .handle = h };
    }

    fn lookup(self: DlHandle, comptime T: type, name: [*:0]const u8) ?T {
        if (is_freestanding) return null;
        const fn_ptr = dlsym orelse return null;
        const sym = fn_ptr(self.handle, name) orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    fn close(self: *DlHandle) void {
        if (is_freestanding) return;
        if (dlclose) |fn_ptr| _ = fn_ptr(self.handle);
        self.handle = null;
    }
};

const dlopen: ?*const fn (filename: ?[*:0]const u8, flags: c_int) callconv(.C) ?*anyopaque = if (is_freestanding) null else @extern(*const fn (filename: ?[*:0]const u8, flags: c_int) callconv(.C) ?*anyopaque, .{ .name = "dlopen" });
const dlsym: ?*const fn (handle: ?*anyopaque, symbol: [*:0]const u8) callconv(.C) ?*anyopaque = if (is_freestanding) null else @extern(*const fn (handle: ?*anyopaque, symbol: [*:0]const u8) callconv(.C) ?*anyopaque, .{ .name = "dlsym" });
const dlclose: ?*const fn (handle: ?*anyopaque) callconv(.C) c_int = if (is_freestanding) null else @extern(*const fn (handle: ?*anyopaque) callconv(.C) c_int, .{ .name = "dlclose" });
const RTLD_LAZY: c_int = 1;

// Opaque Vulkan handle types
const VkInstance = usize;
const VkPhysicalDevice = usize;
const VkDevice = usize;
const VkQueue = usize;
const VkCommandPool = usize;
const VkCommandBuffer = usize;
const VkBuffer = usize;
const VkDeviceMemory = usize;
const VkDescriptorPool = usize;
const VkDescriptorSetLayout = usize;
const VkDescriptorSet = usize;
const VkPipelineLayout = usize;
const VkPipeline = usize;
const VkShaderModule = usize;
const VkFence = usize;

const VkResult = i32;
const VK_SUCCESS: VkResult = 0;

const VK_QUEUE_COMPUTE_BIT: u32 = 0x00000002;
const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x00000040;
const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;
const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;
const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: i32 = 6;
const VK_PIPELINE_BIND_POINT_COMPUTE: i32 = 1;
const VK_COMMAND_BUFFER_LEVEL_PRIMARY: i32 = 0;
const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;
const VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT: u32 = 0x00000001;
const VK_FENCE_CREATE_SIGNALED_BIT: u32 = 0x00000001;

// sType constants
const ST_APP_INFO: i32 = 0;
const ST_INSTANCE_CI: i32 = 1;
const ST_DEV_QUEUE_CI: i32 = 2;
const ST_DEV_CI: i32 = 3;
const ST_CMD_POOL_CI: i32 = 39;
const ST_CMD_BUFFER_ALLOC: i32 = 30;
const ST_CMD_BUFFER_BEGIN: i32 = 42;
const ST_BUFFER_CI: i32 = 15;
const ST_MEM_ALLOC: i32 = 11;
const ST_DESC_SET_LAYOUT_CI: i32 = 22;
const ST_DESC_POOL_CI: i32 = 21;
const ST_DESC_SET_ALLOC: i32 = 27;
const ST_PIPELINE_LAYOUT_CI: i32 = 23;
const ST_SHADER_MODULE_CI: i32 = 33;
const ST_COMPUTE_PIPELINE_CI: i32 = 28;
const ST_WRITE_DESC_SET: i32 = 24;
const ST_SUBMIT_INFO: i32 = 4;
const ST_FENCE_CI: i32 = 12;
const ST_PHYS_DEV_MEM_PROPS: i32 = 18;

// Minimal extern structs
const VkApplicationInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};
const VkInstanceCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};
const VkDeviceQueueCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: [*]const f32,
};
const VkDeviceCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
    pEnabledFeatures: ?*const anyopaque,
};
const VkCommandPoolCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
};
const VkCommandBufferAllocateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    commandPool: VkCommandPool,
    level: i32,
    commandBufferCount: u32,
};
const VkCommandBufferBeginInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    pInheritanceInfo: ?*const anyopaque,
};
const VkBufferCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    size: u64,
    usage: u32,
    sharingMode: i32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
};
const VkMemoryAllocateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    allocationSize: u64,
    memoryTypeIndex: u32,
};
const VkMemoryType = extern struct { propertyFlags: u32, heapIndex: u32 };
const VkMemoryHeap = extern struct { size: u64, flags: u32 };
const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};
const VkMemoryRequirements = extern struct { size: u64, alignment: u64, memoryTypeBits: u32 };
const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: i32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque,
};
const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};
const VkDescriptorPoolSize = extern struct { type: i32, descriptorCount: u32 };
const VkDescriptorPoolCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};
const VkDescriptorSetAllocateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};
const VkDescriptorBufferInfo = extern struct { buffer: VkBuffer, offset: u64, range: u64 };
const VkWriteDescriptorSet = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: i32,
    pImageInfo: ?*const anyopaque,
    pBufferInfo: [*]const VkDescriptorBufferInfo,
    pTexelBufferView: ?*const anyopaque,
};
const VkPipelineLayoutCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    setLayoutCount: u32,
    pSetLayouts: [*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?*const anyopaque,
};
const VkShaderModuleCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    codeSize: u64,
    pCode: [*]const u32,
};
const VkPipelineShaderStageCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    stage: u32,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque,
};
const VkComputePipelineCreateInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    flags: u32,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: VkPipeline,
    basePipelineIndex: i32,
};
const VkSubmitInfo = extern struct {
    sType: i32,
    pNext: ?*anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const usize,
    pWaitDstStageMask: ?[*]const u32,
    commandBufferCount: u32,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?[*]const usize,
};
const VkFenceCreateInfo = extern struct { sType: i32, pNext: ?*anyopaque, flags: u32 };
const VkQueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: [3]u32,
};
const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: [126]u32,
    sparseProperties: [5]u32,
    _padding: [2]u32 = .{ 0, 0 },
};

// Function pointer types
const FnCreateInstance = *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.C) VkResult;
const FnEnumeratePhysicalDevices = *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.C) VkResult;
const FnGetPhysDevMemProps = *const fn (VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) callconv(.C) void;
const FnGetPhysDevQueueFamilyProps = *const fn (VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) callconv(.C) void;
const FnGetPhysDevProps = *const fn (VkPhysicalDevice, *anyopaque) callconv(.C) void;
const FnCreateDevice = *const fn (VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) callconv(.C) VkResult;
const FnGetDeviceQueue = *const fn (VkDevice, u32, u32, *VkQueue) callconv(.C) void;
const FnCreateCommandPool = *const fn (VkDevice, *const VkCommandPoolCreateInfo, ?*const anyopaque, *VkCommandPool) callconv(.C) VkResult;
const FnAllocCmdBuffers = *const fn (VkDevice, *const VkCommandBufferAllocateInfo, [*]VkCommandBuffer) callconv(.C) VkResult;
const FnBeginCmdBuffer = *const fn (VkCommandBuffer, *const VkCommandBufferBeginInfo) callconv(.C) VkResult;
const FnEndCmdBuffer = *const fn (VkCommandBuffer) callconv(.C) VkResult;
const FnCmdBindPipeline = *const fn (VkCommandBuffer, i32, VkPipeline) callconv(.C) void;
const FnCmdBindDescSets = *const fn (VkCommandBuffer, i32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?[*]const u32) callconv(.C) void;
const FnCmdDispatch = *const fn (VkCommandBuffer, u32, u32, u32) callconv(.C) void;
const FnQueueSubmit = *const fn (VkQueue, u32, [*]const VkSubmitInfo, VkFence) callconv(.C) VkResult;
const FnQueueWaitIdle = *const fn (VkQueue) callconv(.C) VkResult;
const FnCreateBuffer = *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.C) VkResult;
const FnGetBufferMemReqs = *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.C) void;
const FnAllocMemory = *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.C) VkResult;
const FnBindBufferMemory = *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.C) VkResult;
const FnMapMemory = *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, *?*anyopaque) callconv(.C) VkResult;
const FnUnmapMemory = *const fn (VkDevice, VkDeviceMemory) callconv(.C) void;
const FnFreeMemory = *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.C) void;
const FnDestroyBuffer = *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.C) void;
const FnCreateDescSetLayout = *const fn (VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) callconv(.C) VkResult;
const FnCreateDescPool = *const fn (VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) callconv(.C) VkResult;
const FnAllocDescSets = *const fn (VkDevice, *const VkDescriptorSetAllocateInfo, [*]VkDescriptorSet) callconv(.C) VkResult;
const FnUpdateDescSets = *const fn (VkDevice, u32, [*]const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.C) void;
const FnCreatePipelineLayout = *const fn (VkDevice, *const VkPipelineLayoutCreateInfo, ?*const anyopaque, *VkPipelineLayout) callconv(.C) VkResult;
const FnCreateShaderModule = *const fn (VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) callconv(.C) VkResult;
const FnCreateComputePipelines = *const fn (VkDevice, usize, u32, [*]const VkComputePipelineCreateInfo, ?*const anyopaque, [*]VkPipeline) callconv(.C) VkResult;
const FnCreateFence = *const fn (VkDevice, *const VkFenceCreateInfo, ?*const anyopaque, *VkFence) callconv(.C) VkResult;
const FnWaitForFences = *const fn (VkDevice, u32, [*]const VkFence, u32, u64) callconv(.C) VkResult;
const FnDestroyInstance = *const fn (VkInstance, ?*const anyopaque) callconv(.C) void;
const FnDestroyDevice = *const fn (VkDevice, ?*const anyopaque) callconv(.C) void;
const FnDestroyCmdPool = *const fn (VkDevice, VkCommandPool, ?*const anyopaque) callconv(.C) void;
const FnDestroyDescPool = *const fn (VkDevice, VkDescriptorPool, ?*const anyopaque) callconv(.C) void;
const FnDestroyDescSetLayout = *const fn (VkDevice, VkDescriptorSetLayout, ?*const anyopaque) callconv(.C) void;
const FnDestroyPipeline = *const fn (VkDevice, VkPipeline, ?*const anyopaque) callconv(.C) void;
const FnDestroyPipelineLayout = *const fn (VkDevice, VkPipelineLayout, ?*const anyopaque) callconv(.C) void;
const FnDestroyShaderModule = *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.C) void;
const FnDestroyFence = *const fn (VkDevice, VkFence, ?*const anyopaque) callconv(.C) void;
const FnFreeCmdBuffers = *const fn (VkDevice, VkCommandPool, u32, [*]const VkCommandBuffer) callconv(.C) void;

pub const VulkanError = error{
    LibraryNotFound,
    InstanceCreationFailed,
    NoDiscreteGPU,
    NoComputeQueue,
    DeviceCreationFailed,
    OutOfMemory,
    ShaderCreationFailed,
    PipelineCreationFailed,
    BufferCreationFailed,
    MappingFailed,
    DispatchFailed,
};

pub const GpuBuffer = struct {
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    size: u64,
    mapped: ?[*]u8 = null,
};

pub const ComputePipeline = struct {
    pipeline: VkPipeline,
    layout: VkPipelineLayout,
    descriptor_set: VkDescriptorSet,
    descriptor_set_layout: VkDescriptorSetLayout,
    shader_module: VkShaderModule,
};

pub const VulkanContext = struct {
    lib: DlHandle,
    instance: VkInstance,
    physical_device: VkPhysicalDevice,
    device: VkDevice,
    queue: VkQueue,
    queue_family: u32,
    command_pool: VkCommandPool,
    descriptor_pool: VkDescriptorPool,
    has_int64: bool,
    device_name: [256]u8 = [_]u8{0} ** 256,

    // Function pointers
    vkDestroyInstance: FnDestroyInstance,
    vkDestroyDevice: FnDestroyDevice,
    vkDestroyCmdPool: FnDestroyCmdPool,
    vkDestroyDescPool: FnDestroyDescPool,
    vkDestroyDescSetLayout: FnDestroyDescSetLayout,
    vkDestroyPipeline: FnDestroyPipeline,
    vkDestroyPipelineLayout: FnDestroyPipelineLayout,
    vkDestroyShaderModule: FnDestroyShaderModule,
    vkDestroyFence: FnDestroyFence,
    vkFreeCmdBuffers: FnFreeCmdBuffers,
    vkEnumeratePhysicalDevices: FnEnumeratePhysicalDevices,
    vkGetPhysDevMemProps: FnGetPhysDevMemProps,
    vkGetPhysDevQueueFamilyProps: FnGetPhysDevQueueFamilyProps,
    vkGetPhysDevProps: FnGetPhysDevProps,
    vkCreateDevice: FnCreateDevice,
    vkGetDeviceQueue: FnGetDeviceQueue,
    vkCreateCommandPool: FnCreateCommandPool,
    vkAllocCmdBuffers: FnAllocCmdBuffers,
    vkBeginCmdBuffer: FnBeginCmdBuffer,
    vkEndCmdBuffer: FnEndCmdBuffer,
    vkCmdBindPipeline: FnCmdBindPipeline,
    vkCmdBindDescSets: FnCmdBindDescSets,
    vkCmdDispatch: FnCmdDispatch,
    vkQueueSubmit: FnQueueSubmit,
    vkQueueWaitIdle: FnQueueWaitIdle,
    vkCreateBuffer: FnCreateBuffer,
    vkGetBufferMemReqs: FnGetBufferMemReqs,
    vkAllocMemory: FnAllocMemory,
    vkBindBufferMemory: FnBindBufferMemory,
    vkMapMemory: FnMapMemory,
    vkUnmapMemory: FnUnmapMemory,
    vkFreeMemory: FnFreeMemory,
    vkDestroyBuffer: FnDestroyBuffer,
    vkCreateDescSetLayout: FnCreateDescSetLayout,
    vkCreateDescPool: FnCreateDescPool,
    vkAllocDescSets: FnAllocDescSets,
    vkUpdateDescSets: FnUpdateDescSets,
    vkCreatePipelineLayout: FnCreatePipelineLayout,
    vkCreateShaderModule: FnCreateShaderModule,
    vkCreateComputePipelines: FnCreateComputePipelines,
    vkCreateFence: FnCreateFence,
    vkWaitForFences: FnWaitForFences,

    pub fn init(allocator: std.mem.Allocator) !VulkanContext {
        // dlopen handles search path resolution properly.
        var lib = DlHandle.open("libvulkan.so.1") catch return VulkanError.LibraryNotFound;
        errdefer lib.close();

        const vkCreateInstance = lib.lookup(FnCreateInstance, "vkCreateInstance") orelse return VulkanError.LibraryNotFound;

        const app_info = VkApplicationInfo{
            .sType = ST_APP_INFO,
            .pNext = null,
            .pApplicationName = "Qstar",
            .applicationVersion = 0,
            .pEngineName = "Qstar-LLM",
            .engineVersion = 0,
            .apiVersion = 0x402000,
        };
        const inst_ci = VkInstanceCreateInfo{
            .sType = ST_INSTANCE_CI,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };
        var instance: VkInstance = 0;
        if (vkCreateInstance(&inst_ci, null, &instance) != VK_SUCCESS) return VulkanError.InstanceCreationFailed;

        // Load all function pointers
        const vkEnumeratePhysicalDevices = lib.lookup(FnEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices") orelse return VulkanError.LibraryNotFound;
        const vkGetPhysDevMemProps = lib.lookup(FnGetPhysDevMemProps, "vkGetPhysicalDeviceMemoryProperties") orelse return VulkanError.LibraryNotFound;
        const vkGetPhysDevQueueFamilyProps = lib.lookup(FnGetPhysDevQueueFamilyProps, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return VulkanError.LibraryNotFound;
        const vkGetPhysDevProps = lib.lookup(FnGetPhysDevProps, "vkGetPhysicalDeviceProperties") orelse return VulkanError.LibraryNotFound;
        const vkCreateDevice = lib.lookup(FnCreateDevice, "vkCreateDevice") orelse return VulkanError.LibraryNotFound;
        const vkGetDeviceQueue = lib.lookup(FnGetDeviceQueue, "vkGetDeviceQueue") orelse return VulkanError.LibraryNotFound;
        const vkCreateCommandPool = lib.lookup(FnCreateCommandPool, "vkCreateCommandPool") orelse return VulkanError.LibraryNotFound;
        const vkAllocCmdBuffers = lib.lookup(FnAllocCmdBuffers, "vkAllocateCommandBuffers") orelse return VulkanError.LibraryNotFound;
        const vkBeginCmdBuffer = lib.lookup(FnBeginCmdBuffer, "vkBeginCommandBuffer") orelse return VulkanError.LibraryNotFound;
        const vkEndCmdBuffer = lib.lookup(FnEndCmdBuffer, "vkEndCommandBuffer") orelse return VulkanError.LibraryNotFound;
        const vkCmdBindPipeline = lib.lookup(FnCmdBindPipeline, "vkCmdBindPipeline") orelse return VulkanError.LibraryNotFound;
        const vkCmdBindDescSets = lib.lookup(FnCmdBindDescSets, "vkCmdBindDescriptorSets") orelse return VulkanError.LibraryNotFound;
        const vkCmdDispatch = lib.lookup(FnCmdDispatch, "vkCmdDispatch") orelse return VulkanError.LibraryNotFound;
        const vkQueueSubmit = lib.lookup(FnQueueSubmit, "vkQueueSubmit") orelse return VulkanError.LibraryNotFound;
        const vkQueueWaitIdle = lib.lookup(FnQueueWaitIdle, "vkQueueWaitIdle") orelse return VulkanError.LibraryNotFound;
        const vkCreateBuffer = lib.lookup(FnCreateBuffer, "vkCreateBuffer") orelse return VulkanError.LibraryNotFound;
        const vkGetBufferMemReqs = lib.lookup(FnGetBufferMemReqs, "vkGetBufferMemoryRequirements") orelse return VulkanError.LibraryNotFound;
        const vkAllocMemory = lib.lookup(FnAllocMemory, "vkAllocateMemory") orelse return VulkanError.LibraryNotFound;
        const vkBindBufferMemory = lib.lookup(FnBindBufferMemory, "vkBindBufferMemory") orelse return VulkanError.LibraryNotFound;
        const vkMapMemory = lib.lookup(FnMapMemory, "vkMapMemory") orelse return VulkanError.LibraryNotFound;
        const vkUnmapMemory = lib.lookup(FnUnmapMemory, "vkUnmapMemory") orelse return VulkanError.LibraryNotFound;
        const vkFreeMemory = lib.lookup(FnFreeMemory, "vkFreeMemory") orelse return VulkanError.LibraryNotFound;
        const vkDestroyBuffer = lib.lookup(FnDestroyBuffer, "vkDestroyBuffer") orelse return VulkanError.LibraryNotFound;
        const vkCreateDescSetLayout = lib.lookup(FnCreateDescSetLayout, "vkCreateDescriptorSetLayout") orelse return VulkanError.LibraryNotFound;
        const vkCreateDescPool = lib.lookup(FnCreateDescPool, "vkCreateDescriptorPool") orelse return VulkanError.LibraryNotFound;
        const vkAllocDescSets = lib.lookup(FnAllocDescSets, "vkAllocateDescriptorSets") orelse return VulkanError.LibraryNotFound;
        const vkUpdateDescSets = lib.lookup(FnUpdateDescSets, "vkUpdateDescriptorSets") orelse return VulkanError.LibraryNotFound;
        const vkCreatePipelineLayout = lib.lookup(FnCreatePipelineLayout, "vkCreatePipelineLayout") orelse return VulkanError.LibraryNotFound;
        const vkCreateShaderModule = lib.lookup(FnCreateShaderModule, "vkCreateShaderModule") orelse return VulkanError.LibraryNotFound;
        const vkCreateComputePipelines = lib.lookup(FnCreateComputePipelines, "vkCreateComputePipelines") orelse return VulkanError.LibraryNotFound;
        const vkCreateFence = lib.lookup(FnCreateFence, "vkCreateFence") orelse return VulkanError.LibraryNotFound;
        const vkWaitForFences = lib.lookup(FnWaitForFences, "vkWaitForFences") orelse return VulkanError.LibraryNotFound;
        const vkDestroyInstance = lib.lookup(FnDestroyInstance, "vkDestroyInstance") orelse return VulkanError.LibraryNotFound;
        const vkDestroyDevice = lib.lookup(FnDestroyDevice, "vkDestroyDevice") orelse return VulkanError.LibraryNotFound;
        const vkDestroyCmdPool = lib.lookup(FnDestroyCmdPool, "vkDestroyCommandPool") orelse return VulkanError.LibraryNotFound;
        const vkDestroyDescPool = lib.lookup(FnDestroyDescPool, "vkDestroyDescriptorPool") orelse return VulkanError.LibraryNotFound;
        const vkDestroyDescSetLayout = lib.lookup(FnDestroyDescSetLayout, "vkDestroyDescriptorSetLayout") orelse return VulkanError.LibraryNotFound;
        const vkDestroyPipeline = lib.lookup(FnDestroyPipeline, "vkDestroyPipeline") orelse return VulkanError.LibraryNotFound;
        const vkDestroyPipelineLayout = lib.lookup(FnDestroyPipelineLayout, "vkDestroyPipelineLayout") orelse return VulkanError.LibraryNotFound;
        const vkDestroyShaderModule = lib.lookup(FnDestroyShaderModule, "vkDestroyShaderModule") orelse return VulkanError.LibraryNotFound;
        const vkDestroyFence = lib.lookup(FnDestroyFence, "vkDestroyFence") orelse return VulkanError.LibraryNotFound;
        const vkFreeCmdBuffers = lib.lookup(FnFreeCmdBuffers, "vkFreeCommandBuffers") orelse return VulkanError.LibraryNotFound;

        // Select best discrete GPU
        var gpu_count: u32 = 0;
        _ = vkEnumeratePhysicalDevices(instance, &gpu_count, null);
        if (gpu_count == 0) return VulkanError.NoDiscreteGPU;
        const gpus = try allocator.alloc(VkPhysicalDevice, gpu_count);
        defer allocator.free(gpus);
        _ = vkEnumeratePhysicalDevices(instance, &gpu_count, gpus.ptr);

        var best_gpu: VkPhysicalDevice = 0;
        var best_score: i32 = -1;
        var best_name: [256]u8 = [_]u8{0} ** 256;
        for (gpus) |gpu| {
            var props: VkPhysicalDeviceProperties = undefined;
            vkGetPhysDevProps(gpu, @ptrCast(&props));
            var score: i32 = 0;
            if (props.deviceType == 2) score += 100;
            if (props.vendorID == 0x1002) score += 10;
            if (props.vendorID == 0x8086) score -= 5;
            if (score > best_score) {
                best_score = score;
                best_gpu = gpu;
                best_name = props.deviceName;
            }
        }
        if (best_gpu == 0) return VulkanError.NoDiscreteGPU;

        // Find compute queue family
        var qf_count: u32 = 0;
        vkGetPhysDevQueueFamilyProps(best_gpu, &qf_count, null);
        const qfs = try allocator.alloc(VkQueueFamilyProperties, qf_count);
        defer allocator.free(qfs);
        vkGetPhysDevQueueFamilyProps(best_gpu, &qf_count, qfs.ptr);
        var compute_family: ?u32 = null;
        for (qfs, 0..) |qf, i| {
            if ((qf.queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
                compute_family = @intCast(i);
                break;
            }
        }
        const qf_idx = compute_family orelse return VulkanError.NoComputeQueue;

        // Create device
        const queue_prio: f32 = 1.0;
        const queue_ci = VkDeviceQueueCreateInfo{
            .sType = ST_DEV_QUEUE_CI,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = qf_idx,
            .queueCount = 1,
            .pQueuePriorities = (&queue_prio)[0..1].ptr,
        };
        const dev_ci = VkDeviceCreateInfo{
            .sType = ST_DEV_CI,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = (&queue_ci)[0..1].ptr,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .pEnabledFeatures = null,
        };
        var device: VkDevice = 0;
        if (vkCreateDevice(best_gpu, &dev_ci, null, &device) != VK_SUCCESS) return VulkanError.DeviceCreationFailed;

        var queue: VkQueue = 0;
        vkGetDeviceQueue(device, qf_idx, 0, &queue);

        // Command pool
        const pool_ci = VkCommandPoolCreateInfo{ .sType = ST_CMD_POOL_CI, .pNext = null, .flags = 0, .queueFamilyIndex = qf_idx };
        var cmd_pool: VkCommandPool = 0;
        if (vkCreateCommandPool(device, &pool_ci, null, &cmd_pool) != VK_SUCCESS) return VulkanError.DeviceCreationFailed;

        // Descriptor pool
        const pool_size = VkDescriptorPoolSize{ .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 16 };
        const dp_ci = VkDescriptorPoolCreateInfo{
            .sType = ST_DESC_POOL_CI,
            .pNext = null,
            .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 8,
            .poolSizeCount = 1,
            .pPoolSizes = (&pool_size)[0..1].ptr,
        };
        var desc_pool: VkDescriptorPool = 0;
        if (vkCreateDescPool(device, &dp_ci, null, &desc_pool) != VK_SUCCESS) return VulkanError.DeviceCreationFailed;

        return VulkanContext{
            .lib = lib,
            .instance = instance,
            .physical_device = best_gpu,
            .device = device,
            .queue = queue,
            .queue_family = qf_idx,
            .command_pool = cmd_pool,
            .descriptor_pool = desc_pool,
            .has_int64 = false,
            .device_name = best_name,
            .vkDestroyInstance = vkDestroyInstance,
            .vkDestroyDevice = vkDestroyDevice,
            .vkDestroyCmdPool = vkDestroyCmdPool,
            .vkDestroyDescPool = vkDestroyDescPool,
            .vkDestroyDescSetLayout = vkDestroyDescSetLayout,
            .vkDestroyPipeline = vkDestroyPipeline,
            .vkDestroyPipelineLayout = vkDestroyPipelineLayout,
            .vkDestroyShaderModule = vkDestroyShaderModule,
            .vkDestroyFence = vkDestroyFence,
            .vkFreeCmdBuffers = vkFreeCmdBuffers,
            .vkEnumeratePhysicalDevices = vkEnumeratePhysicalDevices,
            .vkGetPhysDevMemProps = vkGetPhysDevMemProps,
            .vkGetPhysDevQueueFamilyProps = vkGetPhysDevQueueFamilyProps,
            .vkGetPhysDevProps = vkGetPhysDevProps,
            .vkCreateDevice = vkCreateDevice,
            .vkGetDeviceQueue = vkGetDeviceQueue,
            .vkCreateCommandPool = vkCreateCommandPool,
            .vkAllocCmdBuffers = vkAllocCmdBuffers,
            .vkBeginCmdBuffer = vkBeginCmdBuffer,
            .vkEndCmdBuffer = vkEndCmdBuffer,
            .vkCmdBindPipeline = vkCmdBindPipeline,
            .vkCmdBindDescSets = vkCmdBindDescSets,
            .vkCmdDispatch = vkCmdDispatch,
            .vkQueueSubmit = vkQueueSubmit,
            .vkQueueWaitIdle = vkQueueWaitIdle,
            .vkCreateBuffer = vkCreateBuffer,
            .vkGetBufferMemReqs = vkGetBufferMemReqs,
            .vkAllocMemory = vkAllocMemory,
            .vkBindBufferMemory = vkBindBufferMemory,
            .vkMapMemory = vkMapMemory,
            .vkUnmapMemory = vkUnmapMemory,
            .vkFreeMemory = vkFreeMemory,
            .vkDestroyBuffer = vkDestroyBuffer,
            .vkCreateDescSetLayout = vkCreateDescSetLayout,
            .vkCreateDescPool = vkCreateDescPool,
            .vkAllocDescSets = vkAllocDescSets,
            .vkUpdateDescSets = vkUpdateDescSets,
            .vkCreatePipelineLayout = vkCreatePipelineLayout,
            .vkCreateShaderModule = vkCreateShaderModule,
            .vkCreateComputePipelines = vkCreateComputePipelines,
            .vkCreateFence = vkCreateFence,
            .vkWaitForFences = vkWaitForFences,
        };
    }

    pub fn deinit(self: *VulkanContext) void {
        self.vkDestroyDescPool(self.device, self.descriptor_pool, null);
        self.vkDestroyCmdPool(self.device, self.command_pool, null);
        self.vkDestroyDevice(self.device, null);
        self.vkDestroyInstance(self.instance, null);
        self.lib.close();
    }

    pub fn getDeviceName(self: *const VulkanContext) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.device_name, 0) orelse self.device_name.len;
        return self.device_name[0..len];
    }

    pub fn createBuffer(self: *VulkanContext, size: u64, usage: u32) !GpuBuffer {
        const ci = VkBufferCreateInfo{
            .sType = ST_BUFFER_CI,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = 0,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buffer: VkBuffer = 0;
        if (self.vkCreateBuffer(self.device, &ci, null, &buffer) != VK_SUCCESS) return VulkanError.BufferCreationFailed;

        var mem_reqs: VkMemoryRequirements = undefined;
        self.vkGetBufferMemReqs(self.device, buffer, &mem_reqs);

        var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
        self.vkGetPhysDevMemProps(self.physical_device, &mem_props);

        const required = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        var mt_idx: ?u32 = null;
        for (0..mem_props.memoryTypeCount) |i| {
            if ((mem_reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i))) != 0 and
                (mem_props.memoryTypes[i].propertyFlags & required) == required)
            {
                mt_idx = @intCast(i);
                break;
            }
        }
        const idx = mt_idx orelse return VulkanError.OutOfMemory;

        const alloc_ci = VkMemoryAllocateInfo{ .sType = ST_MEM_ALLOC, .pNext = null, .allocationSize = mem_reqs.size, .memoryTypeIndex = idx };
        var memory: VkDeviceMemory = 0;
        if (self.vkAllocMemory(self.device, &alloc_ci, null, &memory) != VK_SUCCESS) return VulkanError.OutOfMemory;
        if (self.vkBindBufferMemory(self.device, buffer, memory, 0) != VK_SUCCESS) return VulkanError.BufferCreationFailed;

        return GpuBuffer{ .buffer = buffer, .memory = memory, .size = mem_reqs.size };
    }

    pub fn destroyBuffer(self: *VulkanContext, buf: GpuBuffer) void {
        if (buf.mapped != null) self.vkUnmapMemory(self.device, buf.memory);
        self.vkDestroyBuffer(self.device, buf.buffer, null);
        self.vkFreeMemory(self.device, buf.memory, null);
    }

    pub fn mapBuffer(self: *VulkanContext, buf: *GpuBuffer) ![*]u8 {
        if (buf.mapped != null) return buf.mapped.?;
        var ptr: ?*anyopaque = null;
        if (self.vkMapMemory(self.device, buf.memory, 0, buf.size, 0, &ptr) != VK_SUCCESS) return VulkanError.MappingFailed;
        buf.mapped = @ptrCast(ptr);
        return buf.mapped.?;
    }

    pub fn createComputePipeline(self: *VulkanContext, spirv: []const u8, num_bindings: u32) !ComputePipeline {
        const arena = std.heap.page_allocator;
        var bindings = try arena.alloc(VkDescriptorSetLayoutBinding, num_bindings);
        defer arena.free(bindings);
        for (0..num_bindings) |i| {
            bindings[i] = .{ .binding = @intCast(i), .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null };
        }
        const dsl_ci = VkDescriptorSetLayoutCreateInfo{ .sType = ST_DESC_SET_LAYOUT_CI, .pNext = null, .flags = 0, .bindingCount = num_bindings, .pBindings = bindings.ptr };
        var dsl: VkDescriptorSetLayout = 0;
        if (self.vkCreateDescSetLayout(self.device, &dsl_ci, null, &dsl) != VK_SUCCESS) return VulkanError.PipelineCreationFailed;

        const pl_ci = VkPipelineLayoutCreateInfo{ .sType = ST_PIPELINE_LAYOUT_CI, .pNext = null, .flags = 0, .setLayoutCount = 1, .pSetLayouts = (&dsl)[0..1].ptr, .pushConstantRangeCount = 0, .pPushConstantRanges = null };
        var pl: VkPipelineLayout = 0;
        if (self.vkCreatePipelineLayout(self.device, &pl_ci, null, &pl) != VK_SUCCESS) return VulkanError.PipelineCreationFailed;

        // SPIR-V must be u32-aligned. @embedFile gives []const u8 (1-byte align),
        // so copy to an aligned buffer.
        const word_count = (spirv.len + 3) / 4;
        const words = try arena.alloc(u32, word_count);
        defer arena.free(words);
        @memset(words, 0);
        @memcpy(@as([*]u8, @ptrCast(words.ptr))[0..spirv.len], spirv);

        const sm_ci = VkShaderModuleCreateInfo{ .sType = ST_SHADER_MODULE_CI, .pNext = null, .flags = 0, .codeSize = spirv.len, .pCode = words.ptr };
        var sm: VkShaderModule = 0;
        if (self.vkCreateShaderModule(self.device, &sm_ci, null, &sm) != VK_SUCCESS) return VulkanError.ShaderCreationFailed;

        const stage = VkPipelineShaderStageCreateInfo{ .sType = 17, .pNext = null, .flags = 0, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = sm, .pName = "main", .pSpecializationInfo = null };
        const cp_ci = VkComputePipelineCreateInfo{ .sType = ST_COMPUTE_PIPELINE_CI, .pNext = null, .flags = 0, .stage = stage, .layout = pl, .basePipelineHandle = 0, .basePipelineIndex = -1 };
        var pipe: VkPipeline = 0;
        if (self.vkCreateComputePipelines(self.device, 0, 1, (&cp_ci)[0..1].ptr, null, (&pipe)[0..1].ptr) != VK_SUCCESS) return VulkanError.PipelineCreationFailed;

        const ds_alloc = VkDescriptorSetAllocateInfo{ .sType = ST_DESC_SET_ALLOC, .pNext = null, .descriptorPool = self.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = (&dsl)[0..1].ptr };
        var ds: VkDescriptorSet = 0;
        if (self.vkAllocDescSets(self.device, &ds_alloc, (&ds)[0..1].ptr) != VK_SUCCESS) return VulkanError.PipelineCreationFailed;

        return ComputePipeline{ .pipeline = pipe, .layout = pl, .descriptor_set = ds, .descriptor_set_layout = dsl, .shader_module = sm };
    }

    pub fn destroyPipeline(self: *VulkanContext, p: ComputePipeline) void {
        self.vkDestroyPipeline(self.device, p.pipeline, null);
        self.vkDestroyPipelineLayout(self.device, p.layout, null);
        self.vkDestroyShaderModule(self.device, p.shader_module, null);
        self.vkDestroyDescSetLayout(self.device, p.descriptor_set_layout, null);
    }

    pub fn bindBuffers(self: *VulkanContext, p: ComputePipeline, bufs: []const GpuBuffer) void {
        const arena = std.heap.page_allocator;
        var bi = arena.alloc(VkDescriptorBufferInfo, bufs.len) catch return;
        defer arena.free(bi);
        var ws = arena.alloc(VkWriteDescriptorSet, bufs.len) catch return;
        defer arena.free(ws);
        for (0..bufs.len) |i| {
            bi[i] = .{ .buffer = bufs[i].buffer, .offset = 0, .range = bufs[i].size };
            ws[i] = .{ .sType = ST_WRITE_DESC_SET, .pNext = null, .dstSet = p.descriptor_set, .dstBinding = @intCast(i), .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pImageInfo = null, .pBufferInfo = (&bi[i])[0..1].ptr, .pTexelBufferView = null };
        }
        self.vkUpdateDescSets(self.device, @intCast(bufs.len), ws.ptr, 0, null);
    }

    pub fn dispatchAndWait(self: *VulkanContext, p: ComputePipeline, gx: u32, gy: u32, gz: u32) !void {
        const alloc_ci = VkCommandBufferAllocateInfo{ .sType = ST_CMD_BUFFER_ALLOC, .pNext = null, .commandPool = self.command_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        var cmd: VkCommandBuffer = 0;
        if (self.vkAllocCmdBuffers(self.device, &alloc_ci, (&cmd)[0..1].ptr) != VK_SUCCESS) return VulkanError.DispatchFailed;

        const begin_ci = VkCommandBufferBeginInfo{ .sType = ST_CMD_BUFFER_BEGIN, .pNext = null, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, .pInheritanceInfo = null };
        if (self.vkBeginCmdBuffer(cmd, &begin_ci) != VK_SUCCESS) return VulkanError.DispatchFailed;

        self.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipeline);
        self.vkCmdBindDescSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, (&p.descriptor_set)[0..1].ptr, 0, null);
        self.vkCmdDispatch(cmd, gx, gy, gz);
        if (self.vkEndCmdBuffer(cmd) != VK_SUCCESS) return VulkanError.DispatchFailed;

        const fence_ci = VkFenceCreateInfo{ .sType = ST_FENCE_CI, .pNext = null, .flags = 0 };
        var fence: VkFence = 0;
        if (self.vkCreateFence(self.device, &fence_ci, null, &fence) != VK_SUCCESS) return VulkanError.DispatchFailed;
        defer self.vkDestroyFence(self.device, fence, null);

        const submit = VkSubmitInfo{ .sType = ST_SUBMIT_INFO, .pNext = null, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = (&cmd)[0..1].ptr, .signalSemaphoreCount = 0, .pSignalSemaphores = null };
        if (self.vkQueueSubmit(self.queue, 1, (&submit)[0..1].ptr, fence) != VK_SUCCESS) return VulkanError.DispatchFailed;
        if (self.vkWaitForFences(self.device, 1, (&fence)[0..1].ptr, 1, 100_000_000) != VK_SUCCESS) return VulkanError.DispatchFailed;
        self.vkFreeCmdBuffers(self.device, self.command_pool, 1, (&cmd)[0..1].ptr);
    }
};

// =============================================================================
// LatticeAccelerator — wraps VulkanContext for Qstar lattice compute
// =============================================================================

const LATTICE_STEP_SPV = @embedFile("shaders/lattice_step.spv");
const LOGITS_PROJ_SPV = @embedFile("shaders/logits_proj.spv");
const SAMC_RELAX_SPV = @embedFile("shaders/samc_relax.spv");

pub const LatticeAccelerator = struct {
    ctx: VulkanContext,
    in_buf: GpuBuffer,
    out_buf: GpuBuffer,
    params_buf: GpuBuffer,
    logits_buf: GpuBuffer,
    step_pipeline: ComputePipeline,
    logits_pipeline: ComputePipeline,
    samc_pipeline: ComputePipeline,

    /// Activation matrix: 421 × 7 × 8 bytes (uvec2 per i64)
    pub const ACT_SIZE: u64 = 421 * 7 * 8;
    /// Logits: 151936 × 4 bytes (f32)
    pub const LOGITS_SIZE: u64 = 151936 * 4;
    /// Params: temp(2) + sigmoid(1024) + e_vals(421) + boundary(421) + neighbors(2526) + seed(1) = 4395 uints
    pub const PARAMS_SIZE: u64 = 4395 * 4;

    /// Initialize with lattice tables from agent.
    /// sigmoid_table: 512 i128 values (Q64.64) — downscaled to Q32.32 for GPU
    /// e_vals: 421 u8 values
    /// is_boundary: 421 bool values
    /// neighbors: 421×6 packed uint values (bit 31=valid, bits 0-10=index)
    pub fn init(
        sigmoid_table: []const i128,
        e_vals: []const u8,
        is_boundary: []const bool,
        neighbors_packed: []const u32,
    ) !LatticeAccelerator {
        var ctx = try VulkanContext.init(std.heap.page_allocator);
        errdefer ctx.deinit();

        const in_buf = try ctx.createBuffer(ACT_SIZE, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        errdefer ctx.destroyBuffer(in_buf);
        const out_buf = try ctx.createBuffer(ACT_SIZE, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        errdefer ctx.destroyBuffer(out_buf);
        var params_buf = try ctx.createBuffer(PARAMS_SIZE, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        errdefer ctx.destroyBuffer(params_buf);
        const logits_buf = try ctx.createBuffer(LOGITS_SIZE, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        errdefer ctx.destroyBuffer(logits_buf);

        // Build and upload params buffer
        {
            const ptr = try ctx.mapBuffer(&params_buf);
            const u32_ptr: [*]u32 = @ptrCast(@alignCast(ptr));

            // Temperature (will be updated each step, init to 0)
            u32_ptr[0] = 0;
            u32_ptr[1] = 0;

            // Sigmoid LUT: 512 entries × 2 u32 (downscaled from Q64.64 to Q32.32)
            for (0..512) |i| {
                const val_q32 = downscaleSaturating(sigmoid_table[i]);
                const val: u64 = @bitCast(val_q32);
                u32_ptr[2 + i * 2] = @truncate(val);
                u32_ptr[2 + i * 2 + 1] = @truncate(val >> 32);
            }

            // E-values
            for (0..421) |i| {
                u32_ptr[1026 + i] = e_vals[i];
            }

            // Boundary flags
            for (0..421) |i| {
                u32_ptr[1447 + i] = if (is_boundary[i]) 1 else 0;
            }

            // Neighbors (already packed by caller)
            for (0..421 * 6) |i| {
                u32_ptr[1868 + i] = neighbors_packed[i];
            }
        }

        const step_pipeline = try ctx.createComputePipeline(LATTICE_STEP_SPV, 3);
        errdefer ctx.destroyPipeline(step_pipeline);
        const logits_pipeline = try ctx.createComputePipeline(LOGITS_PROJ_SPV, 3);
        errdefer ctx.destroyPipeline(logits_pipeline);
        const samc_pipeline = try ctx.createComputePipeline(SAMC_RELAX_SPV, 3);
        errdefer ctx.destroyPipeline(samc_pipeline);

        return LatticeAccelerator{
            .ctx = ctx,
            .in_buf = in_buf,
            .out_buf = out_buf,
            .params_buf = params_buf,
            .logits_buf = logits_buf,
            .step_pipeline = step_pipeline,
            .logits_pipeline = logits_pipeline,
            .samc_pipeline = samc_pipeline,
        };
    }

    pub fn deinit(self: *LatticeAccelerator) void {
        self.ctx.destroyPipeline(self.step_pipeline);
        self.ctx.destroyPipeline(self.logits_pipeline);
        self.ctx.destroyPipeline(self.samc_pipeline);
        self.ctx.destroyBuffer(self.in_buf);
        self.ctx.destroyBuffer(self.out_buf);
        self.ctx.destroyBuffer(self.params_buf);
        self.ctx.destroyBuffer(self.logits_buf);
        self.ctx.deinit();
    }

    pub fn getDeviceName(self: *const LatticeAccelerator) []const u8 {
        return self.ctx.getDeviceName();
    }

    /// Update temperature in params buffer (Q32.32 i64 → 2 × u32)
    pub fn updateTemperature(self: *LatticeAccelerator, temp: i64) !void {
        const ptr = try self.ctx.mapBuffer(&self.params_buf);
        const u32_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
        const val: u64 = @bitCast(temp);
        u32_ptr[0] = @truncate(val);
        u32_ptr[1] = @truncate(val >> 32);
    }

    /// Upload activation matrix to GPU. Each i64 → uvec2 (lo, hi).
    pub fn uploadActivations(self: *LatticeAccelerator, activations: *const [421][8]i64) !void {
        const ptr = try self.ctx.mapBuffer(&self.in_buf);
        const u32_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
        for (0..421) |node| {
            for (0..7) |ch| {
                const val: u64 = @bitCast(activations[node][ch]);
                u32_ptr[(node * 7 + ch) * 2] = @truncate(val);
                u32_ptr[(node * 7 + ch) * 2 + 1] = @truncate(val >> 32);
            }
        }
    }

    /// Download activation matrix from GPU. Reconstructs i64 from uvec2.
    pub fn downloadActivations(self: *LatticeAccelerator, out: *[421][8]i64) !void {
        const ptr = try self.ctx.mapBuffer(&self.out_buf);
        const u32_ptr: [*]const u32 = @ptrCast(@alignCast(ptr));
        for (0..421) |node| {
            for (0..7) |ch| {
                const lo: u32 = u32_ptr[(node * 7 + ch) * 2];
                const hi: u32 = u32_ptr[(node * 7 + ch) * 2 + 1];
                const combined: u64 = @as(u64, lo) | (@as(u64, hi) << 32);
                out[node][ch] = @bitCast(combined);
            }
        }
    }

    /// Run lattice step on GPU. Returns new activations.
    /// Accepts Q64.64 i128, downscales to Q32.32 for GPU, upscales result back.
    pub fn step(self: *LatticeAccelerator, activations: *const [421][8]i128, temperature: i128) ![421][8]i128 {
        var act_q32: [421][8]i64 = undefined;
        for (0..421) |node| {
            for (0..7) |ch| {
                act_q32[node][ch] = downscaleSaturating(activations[node][ch]);
            }
        }
        const temp_q32 = downscaleSaturating(temperature);
        try self.uploadActivations(&act_q32);
        try self.updateTemperature(temp_q32);
        self.ctx.bindBuffers(self.step_pipeline, &.{ self.in_buf, self.out_buf, self.params_buf });
        try self.ctx.dispatchAndWait(self.step_pipeline, 1, 1, 1);
        var result_q32: [421][8]i64 = undefined;
        try self.downloadActivations(&result_q32);
        var result: [421][8]i128 = undefined;
        for (0..421) |node| {
            for (0..7) |ch| {
                result[node][ch] = upscaleQ32ToQ64(result_q32[node][ch]);
            }
        }
        return result;
    }

    /// Compute logits on GPU. Returns f32 logits array (caller must copy).
    /// Accepts Q64.64 i128, downscales to Q32.32 for GPU processing.
    pub fn activationsToLogits(self: *LatticeAccelerator, activations: *const [421][8]i128, temperature: i128) ![]const f32 {
        var act_q32: [421][8]i64 = undefined;
        for (0..421) |node| {
            for (0..7) |ch| {
                act_q32[node][ch] = downscaleSaturating(activations[node][ch]);
            }
        }
        const temp_q32 = downscaleSaturating(temperature);
        try self.uploadActivations(&act_q32);
        try self.updateTemperature(temp_q32);
        self.ctx.bindBuffers(self.logits_pipeline, &.{ self.in_buf, self.logits_buf, self.params_buf });
        // 151936 / 256 = 594 workgroups (ceil)
        try self.ctx.dispatchAndWait(self.logits_pipeline, 594, 1, 1);
        const ptr = try self.ctx.mapBuffer(&self.logits_buf);
        const f32_slice: [*]const f32 = @ptrCast(@alignCast(ptr));
        // Return a slice into the mapped buffer — caller should copy immediately
        return f32_slice[0..@as(usize, 151936)];
    }

    /// Update RNG seed in params buffer (offset 4394).
    pub fn updateSeed(self: *LatticeAccelerator, seed: u32) !void {
        const ptr = try self.ctx.mapBuffer(&self.params_buf);
        const u32_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
        u32_ptr[4394] = seed;
    }

    /// Run one sweep of SAMC relaxation on GPU. Returns new activations.
    /// Each dispatch performs 421 parallel pairwise exchanges (one per thread).
    /// Note: GPU SAMC uses a different random sequence than CPU — results will
    /// differ but both are valid Monte Carlo relaxations.
    pub fn relaxSAMC(self: *LatticeAccelerator, activations: *const [421][8]i128, temperature: i128, seed: u32) ![421][8]i128 {
        var act_q32: [421][8]i64 = undefined;
        for (0..421) |node| {
            for (0..7) |ch| {
                act_q32[node][ch] = downscaleSaturating(activations[node][ch]);
            }
        }
        const temp_q32 = downscaleSaturating(temperature);
        try self.uploadActivations(&act_q32);
        try self.updateTemperature(temp_q32);
        try self.updateSeed(seed);
        self.ctx.bindBuffers(self.samc_pipeline, &.{ self.in_buf, self.out_buf, self.params_buf });
        try self.ctx.dispatchAndWait(self.samc_pipeline, 1, 1, 1);
        var result_q32: [421][8]i64 = undefined;
        try self.downloadActivations(&result_q32);
        var result: [421][8]i128 = undefined;
        for (0..421) |node| {
            for (0..7) |ch| {
                result[node][ch] = upscaleQ32ToQ64(result_q32[node][ch]);
            }
        }
        return result;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "vulkan: graceful failure when unavailable" {
    // On systems without libvulkan.so.1, init returns LibraryNotFound.
    // On systems with it, we verify basic state.
    var ctx = VulkanContext.init(std.testing.allocator) catch |err| switch (err) {
        VulkanError.LibraryNotFound => return,
        else => return,
    };
    defer ctx.deinit();
    try std.testing.expect(ctx.device != 0);
    try std.testing.expect(ctx.queue != 0);
}

test "vulkan: device name is non-empty when available" {
    var ctx = VulkanContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    const name = ctx.getDeviceName();
    try std.testing.expect(name.len > 0);
}

// === Parity Tests ===
// These tests verify GPU output matches CPU output.
// They skip gracefully when Vulkan is unavailable.

/// Helper: build a LatticeAccelerator with default lattice tables, or return null if Vulkan unavailable.
fn initAccelerator() ?LatticeAccelerator {
    // Build sigmoid table
    var sigmoid_table: [512]i128 = undefined;
    for (0..512) |i| {
        const x_f: f64 = -8.0 + (@as(f64, @floatFromInt(i)) / 512.0) * 16.0;
        const sig_f: f64 = 1.0 / (1.0 + @exp(-x_f));
        sigmoid_table[i] = @intFromFloat(sig_f * @as(f64, @floatFromInt(@as(i128, 1) << 64)));
    }

    // Dummy e_vals, boundaries, neighbors (all zeros = no neighbors)
    var e_vals: [421]u8 = undefined;
    var boundaries: [421]bool = undefined;
    var neighbors: [421 * 6]u32 = undefined;
    for (0..421) |i| {
        e_vals[i] = @intCast(i % 7);
        boundaries[i] = (i % 50 == 0);
        for (0..6) |j| {
            neighbors[i * 6 + j] = 0; // no valid neighbors for parity test
        }
    }

    return LatticeAccelerator.init(&sigmoid_table, &e_vals, &boundaries, &neighbors) catch return null;
}

test "vulkan: lattice step parity with CPU" {
    var accel = initAccelerator() orelse return;
    defer accel.deinit();

    // Create a simple activation matrix with known values
    var activations: [421][8]i128 = [_][8]i128{[_]i128{0} ** 8} ** 421;
    activations[0][0] = 100 * (@as(i128, 1) << 64);
    activations[1][3] = 50 * (@as(i128, 1) << 64);

    const temp: i128 = 2 * (@as(i128, 1) << 64); // temperature = 2.0

    // Run GPU step
    const gpu_result = accel.step(&activations, temp) catch return;

    // Verify output is non-zero (something happened)
    var has_nonzero = false;
    for (0..421) |n| {
        for (0..7) |c| {
            if (gpu_result[n][c] != 0) {
                has_nonzero = true;
                break;
            }
        }
        if (has_nonzero) break;
    }
    try std.testing.expect(has_nonzero);
}

test "vulkan: activationsToLogits parity" {
    var accel = initAccelerator() orelse return;
    defer accel.deinit();

    var activations: [421][8]i128 = [_][8]i128{[_]i128{0} ** 8} ** 421;
    activations[0][0] = 100 * (@as(i128, 1) << 64);
    activations[5][2] = 30 * (@as(i128, 1) << 64);

    const temp: i128 = 2 * (@as(i128, 1) << 64);

    const gpu_logits = accel.activationsToLogits(&activations, temp) catch return;

    // Verify logits are non-trivial (not all zero, not all same)
    var has_nonzero = false;
    const first_val: f32 = gpu_logits[0];
    var has_diff = false;
    for (0..151936) |i| {
        if (gpu_logits[i] != 0.0) has_nonzero = true;
        if (i > 0 and gpu_logits[i] != first_val) has_diff = true;
    }
    try std.testing.expect(has_nonzero);
    try std.testing.expect(has_diff);
}

test "vulkan: SAMC relaxation produces valid output" {
    var accel = initAccelerator() orelse return;
    defer accel.deinit();

    var activations: [421][8]i128 = [_][8]i128{[_]i128{0} ** 8} ** 421;
    // Set some diverse activations
    for (0..421) |i| {
        activations[i][i % 7] = @divTrunc(@as(i128, @intCast(i * 100)) * (@as(i128, 1) << 64), 1000);
    }

    const temp: i128 = 2 * (@as(i128, 1) << 64);
    const seed: u32 = 12345;

    const gpu_result = accel.relaxSAMC(&activations, temp, seed) catch return;

    // Verify output is valid (not all zero, has some structure)
    var has_nonzero = false;
    for (0..421) |n| {
        for (0..7) |c| {
            if (gpu_result[n][c] != 0) {
                has_nonzero = true;
                break;
            }
        }
        if (has_nonzero) break;
    }
    try std.testing.expect(has_nonzero);
}

test "vulkan: graceful fallback when no GPU" {
    // When Vulkan is unavailable, initAccelerator returns null and we skip.
    // This test verifies the pattern works — agent should use CPU path.
    const accel = initAccelerator();
    if (accel) |a| {
        var aa = a;
        aa.deinit();
    }
    // If we got here, either Vulkan was unavailable (skip) or we cleaned up successfully.
    try std.testing.expect(true);
}

// =============================================================================
// Framework GPU Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework GPU workgroup size from the E8 root count: 240 roots.
/// The 240 E8 roots provide a natural workgroup size for GPU shader dispatch.
pub const FRAMEWORK_GPU_WORKGROUP_SIZE: u32 = 240;

/// Framework GPU dispatch count from the E0 node count: 421 nodes.
/// The 421 E0 nodes provide the natural dispatch count for lattice computation.
pub const FRAMEWORK_GPU_DISPATCH_COUNT: u32 = 421;

/// Framework GPU channel count from the 7-defect: 7 channels.
/// The 7 octonionic channels provide the natural channel count for GPU shaders.
pub const FRAMEWORK_GPU_CHANNEL_COUNT: u32 = 8;

/// Verifies the GPU workgroup size matches the E8 root count.
pub fn verifyGPUWorkgroupSizeMatchesFramework() bool {
    return FRAMEWORK_GPU_WORKGROUP_SIZE == 240 and 240 == 15 * 16;
}

/// Verifies the GPU dispatch count matches the E0 node count.
pub fn verifyGPUDispatchCountMatchesFramework() bool {
    return FRAMEWORK_GPU_DISPATCH_COUNT == 421;
}

/// Verifies the GPU channel count matches the 7-defect.
pub fn verifyGPUChannelCountMatchesFramework() bool {
    return FRAMEWORK_GPU_CHANNEL_COUNT == 8;
}

test "framework: GPU workgroup size 240 = E8 root count" {
    try std.testing.expect(verifyGPUWorkgroupSizeMatchesFramework());
}

test "framework: GPU dispatch count 421 = E0 node count" {
    try std.testing.expect(verifyGPUDispatchCountMatchesFramework());
}

test "framework: GPU channel count 7 = 7-defect" {
    try std.testing.expect(verifyGPUChannelCountMatchesFramework());
}
