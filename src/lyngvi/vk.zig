//! Vulkan, declared by hand, in the subset this renderer actually calls.
//!
//! ## Why not `@cImport("vulkan/vulkan.h")`
//!
//! Because that makes the Vulkan SDK a build dependency of a PDF reader, and
//! it does not have to be one. Vulkan's ABI is frozen: a struct that shipped
//! in 1.0 has the same layout in every driver ever written, and the loader is
//! reached through `vkGetInstanceProcAddr`, which is the one symbol anyone
//! needs to link. Declaring the hundred-odd structures this file uses costs a
//! day once; requiring the SDK costs every person who clones the repository.
//!
//! It also removes the last C dependency from the default build. `fenrir` with
//! no flags links no C library at all, and still opens a window and a device.
//!
//! ## The one rule that keeps this safe
//!
//! Structures **passed to** the driver must be byte-exact, because the driver
//! reads fields at fixed offsets. Structures **filled in by** the driver may
//! be larger than the real thing, because it writes only as many bytes as its
//! own header says the structure has, and trailing space is simply unused.
//!
//! That asymmetry is used deliberately below. `PhysicalDeviceLimits` has over
//! a hundred members, of which this project reads four; transcribing the other
//! hundred is a hundred chances to shift every field after the mistake. So the
//! ones that are read are named, and the rest is a generously oversized tail.
//! Getting *that* wrong in the safe direction wastes half a kilobyte of stack.
//! Getting a `CreateInfo` wrong is a black window, so every one of those is
//! written out in full.
//!
//! Handles come in two kinds and the difference matters to the ABI:
//! dispatchable handles (instance, device, queue, command buffer) are pointers,
//! and non-dispatchable handles are 64-bit integers on *every* platform,
//! including 32-bit ones. Declaring the second kind as a pointer works on x86-64
//! and silently corrupts every structure on a 32-bit build.

const std = @import("std");

// -- handles ----------------------------------------------------------------

pub const Instance = ?*opaque {};
pub const PhysicalDevice = ?*opaque {};
pub const Device = ?*opaque {};
pub const Queue = ?*opaque {};
pub const CommandBuffer = ?*opaque {};

/// Non-dispatchable handles. 64 bits everywhere; see the header.
pub const Handle = u64;
pub const null_handle: Handle = 0;

pub const Semaphore = Handle;
pub const Fence = Handle;
pub const DeviceMemory = Handle;
pub const Buffer = Handle;
pub const Image = Handle;
pub const ImageView = Handle;
pub const ShaderModule = Handle;
pub const Pipeline = Handle;
pub const PipelineLayout = Handle;
pub const PipelineCache = Handle;
pub const RenderPass = Handle;
pub const Framebuffer = Handle;
pub const DescriptorSetLayout = Handle;
pub const DescriptorPool = Handle;
pub const DescriptorSet = Handle;
pub const Sampler = Handle;
pub const CommandPool = Handle;
pub const SurfaceKHR = Handle;
pub const SwapchainKHR = Handle;
pub const DebugUtilsMessengerEXT = Handle;
pub const QueryPool = Handle;

pub const whole_size: u64 = ~@as(u64, 0);
pub const queue_family_ignored: u32 = ~@as(u32, 0);
pub const subpass_external: u32 = ~@as(u32, 0);
pub const max_extension_name_size = 256;
pub const max_description_size = 256;
pub const max_physical_device_name_size = 256;
pub const uuid_size = 16;

/// `VK_MAKE_API_VERSION`. Note the variant field: it is zero for Vulkan
/// itself and nonzero only for derived APIs, and forgetting it is what makes a
/// hand-rolled version macro produce 1.0 on a 1.3 driver.
pub fn makeVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

pub fn versionMajor(v: u32) u32 {
    return (v >> 22) & 0x7f;
}

pub fn versionMinor(v: u32) u32 {
    return (v >> 12) & 0x3ff;
}

pub fn versionPatch(v: u32) u32 {
    return v & 0xfff;
}

pub const api_1_0 = makeVersion(0, 1, 0, 0);
pub const api_1_1 = makeVersion(0, 1, 1, 0);
pub const api_1_2 = makeVersion(0, 1, 2, 0);
pub const api_1_3 = makeVersion(0, 1, 3, 0);

// -- results ----------------------------------------------------------------

pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,
    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    suboptimal_khr = 1000001003,
    error_out_of_date_khr = -1000001004,
    error_incompatible_display_khr = -1000001255,
    error_validation_failed_ext = -1000011001,
    error_full_screen_exclusive_mode_lost_ext = -1000255000,
    _,

    /// True for everything the specification calls a success code, which is
    /// not the same as `== .success`: `suboptimal_khr` means the frame was
    /// presented and the swapchain should be rebuilt afterwards, and treating
    /// it as a failure makes a window flicker every time it is resized.
    pub fn isSuccess(r: Result) bool {
        return @intFromEnum(r) >= 0;
    }
};

pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    SurfaceLost,
    NativeWindowInUse,
    OutOfDate,
    Unknown,
};

/// Turns a result into an error, or into nothing. `suboptimal_khr` is *not* an
/// error here; callers that care ask for the raw result.
pub fn check(r: Result) Error!void {
    if (r.isSuccess()) return;
    return switch (r) {
        .error_out_of_host_memory => error.OutOfHostMemory,
        .error_out_of_device_memory => error.OutOfDeviceMemory,
        .error_initialization_failed => error.InitializationFailed,
        .error_device_lost => error.DeviceLost,
        .error_memory_map_failed => error.MemoryMapFailed,
        .error_layer_not_present => error.LayerNotPresent,
        .error_extension_not_present => error.ExtensionNotPresent,
        .error_feature_not_present => error.FeatureNotPresent,
        .error_incompatible_driver => error.IncompatibleDriver,
        .error_too_many_objects => error.TooManyObjects,
        .error_format_not_supported => error.FormatNotSupported,
        .error_surface_lost_khr => error.SurfaceLost,
        .error_native_window_in_use_khr => error.NativeWindowInUse,
        .error_out_of_date_khr => error.OutOfDate,
        else => error.Unknown,
    };
}

// -- enumerations -----------------------------------------------------------

pub const StructureType = enum(u32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    mapped_memory_range = 6,
    fence_create_info = 8,
    semaphore_create_info = 9,
    query_pool_create_info = 11,
    buffer_create_info = 12,
    image_create_info = 14,
    image_view_create_info = 15,
    shader_module_create_info = 16,
    pipeline_shader_stage_create_info = 18,
    pipeline_vertex_input_state_create_info = 19,
    pipeline_input_assembly_state_create_info = 20,
    pipeline_viewport_state_create_info = 22,
    pipeline_rasterization_state_create_info = 23,
    pipeline_multisample_state_create_info = 24,
    pipeline_color_blend_state_create_info = 26,
    pipeline_dynamic_state_create_info = 27,
    graphics_pipeline_create_info = 28,
    pipeline_layout_create_info = 30,
    sampler_create_info = 31,
    descriptor_set_layout_create_info = 32,
    descriptor_pool_create_info = 33,
    descriptor_set_allocate_info = 34,
    write_descriptor_set = 35,
    framebuffer_create_info = 37,
    render_pass_create_info = 38,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    render_pass_begin_info = 43,
    buffer_memory_barrier = 44,
    image_memory_barrier = 45,
    memory_barrier = 46,
    physical_device_features_2 = 1000059000,
    physical_device_properties_2 = 1000059001,
    swapchain_create_info_khr = 1000001000,
    present_info_khr = 1000001001,
    xlib_surface_create_info_khr = 1000004000,
    xcb_surface_create_info_khr = 1000005000,
    wayland_surface_create_info_khr = 1000006000,
    win32_surface_create_info_khr = 1000009000,
    debug_utils_object_name_info_ext = 1000128000,
    debug_utils_messenger_callback_data_ext = 1000128003,
    debug_utils_messenger_create_info_ext = 1000128004,
    descriptor_set_layout_binding_flags_create_info = 1000161000,
    physical_device_descriptor_indexing_features = 1000161001,
    physical_device_descriptor_indexing_properties = 1000161002,
    descriptor_set_variable_descriptor_count_allocate_info = 1000161003,
    _,
};

pub const Format = enum(u32) {
    undefined = 0,
    r8_unorm = 9,
    r8_srgb = 15,
    r8g8b8a8_unorm = 37,
    r8g8b8a8_srgb = 43,
    b8g8r8a8_unorm = 44,
    b8g8r8a8_srgb = 50,
    a2b10g10r10_unorm_pack32 = 64,
    r16g16b16a16_sfloat = 97,
    _,

    /// Whether the hardware decodes on read and encodes on write for this
    /// format. The fragment shader blends in linear light and relies on it;
    /// see `choose.surfaceFormat` for what happens when nothing sRGB is on
    /// offer.
    pub fn isSrgb(f: Format) bool {
        return switch (f) {
            .r8_srgb, .r8g8b8a8_srgb, .b8g8r8a8_srgb => true,
            else => false,
        };
    }
};

pub const ColorSpaceKHR = enum(u32) {
    srgb_nonlinear = 0,
    _,
};

pub const PresentModeKHR = enum(u32) {
    immediate = 0,
    mailbox = 1,
    fifo = 2,
    fifo_relaxed = 3,
    _,
};

pub const ImageLayout = enum(u32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    shader_read_only_optimal = 5,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    preinitialized = 8,
    present_src_khr = 1000001002,
    _,
};

pub const PhysicalDeviceType = enum(u32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
    _,

    pub fn name(t: PhysicalDeviceType) []const u8 {
        return switch (t) {
            .other => "other",
            .integrated_gpu => "integrated",
            .discrete_gpu => "discrete",
            .virtual_gpu => "virtual",
            .cpu => "software",
            _ => "unknown",
        };
    }
};

pub const DescriptorType = enum(u32) {
    sampler = 0,
    combined_image_sampler = 1,
    sampled_image = 2,
    storage_image = 3,
    uniform_buffer = 6,
    storage_buffer = 7,
    _,
};

pub const SharingMode = enum(u32) { exclusive = 0, concurrent = 1, _ };
pub const ImageType = enum(u32) { @"1d" = 0, @"2d" = 1, @"3d" = 2, _ };
pub const ImageViewType = enum(u32) { @"1d" = 0, @"2d" = 1, @"3d" = 2, cube = 3, _ };
pub const ImageTiling = enum(u32) { optimal = 0, linear = 1, _ };
pub const ComponentSwizzle = enum(u32) { identity = 0, zero = 1, one = 2, r = 3, g = 4, b = 5, a = 6, _ };
pub const Filter = enum(u32) { nearest = 0, linear = 1, _ };
pub const SamplerMipmapMode = enum(u32) { nearest = 0, linear = 1, _ };
pub const SamplerAddressMode = enum(u32) { repeat = 0, mirrored_repeat = 1, clamp_to_edge = 2, clamp_to_border = 3, _ };
pub const BorderColor = enum(u32) { float_transparent_black = 0, int_transparent_black = 1, float_opaque_black = 2, _ };
pub const CompareOp = enum(u32) { never = 0, less = 1, equal = 2, less_or_equal = 3, greater = 4, not_equal = 5, greater_or_equal = 6, always = 7, _ };
pub const PrimitiveTopology = enum(u32) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
    triangle_fan = 5,
    _,
};
pub const PolygonMode = enum(u32) { fill = 0, line = 1, point = 2, _ };
pub const FrontFace = enum(u32) { counter_clockwise = 0, clockwise = 1, _ };
pub const BlendFactor = enum(u32) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    dst_color = 4,
    one_minus_dst_color = 5,
    src_alpha = 6,
    one_minus_src_alpha = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    _,
};
pub const BlendOp = enum(u32) { add = 0, subtract = 1, reverse_subtract = 2, min = 3, max = 4, _ };
pub const LogicOp = enum(u32) { clear = 0, copy = 3, _ };
pub const DynamicState = enum(u32) { viewport = 0, scissor = 1, _ };
pub const AttachmentLoadOp = enum(u32) { load = 0, clear = 1, dont_care = 2, _ };
pub const AttachmentStoreOp = enum(u32) { store = 0, dont_care = 1, _ };
pub const PipelineBindPoint = enum(u32) { graphics = 0, compute = 1, _ };
pub const SubpassContents = enum(u32) { @"inline" = 0, secondary_command_buffers = 1, _ };
pub const CommandBufferLevel = enum(u32) { primary = 0, secondary = 1, _ };
pub const VertexInputRate = enum(u32) { vertex = 0, instance = 1, _ };
pub const IndexType = enum(u32) { uint16 = 0, uint32 = 1, _ };

// -- flag bits --------------------------------------------------------------
//
// Plain `u32` with named constants rather than `packed struct`. A packed
// struct is prettier at the call site and needs every reserved bit named to
// stay the right width, which is a second place to make a mistake for a type
// the driver only ever sees as an integer.

pub const QueueFlags = struct {
    pub const graphics: u32 = 0x1;
    pub const compute: u32 = 0x2;
    pub const transfer: u32 = 0x4;
    pub const sparse_binding: u32 = 0x8;
};

pub const QueryResultFlags = struct {
    pub const result_64: u32 = 0x1;
    pub const wait: u32 = 0x2;
    pub const with_availability: u32 = 0x4;
    pub const partial: u32 = 0x8;
};

pub const MemoryPropertyFlags = struct {
    pub const device_local: u32 = 0x1;
    pub const host_visible: u32 = 0x2;
    pub const host_coherent: u32 = 0x4;
    pub const host_cached: u32 = 0x8;
    pub const lazily_allocated: u32 = 0x10;
};

pub const BufferUsageFlags = struct {
    pub const transfer_src: u32 = 0x1;
    pub const transfer_dst: u32 = 0x2;
    pub const uniform_buffer: u32 = 0x10;
    pub const storage_buffer: u32 = 0x20;
    pub const index_buffer: u32 = 0x40;
    pub const vertex_buffer: u32 = 0x80;
};

pub const ImageUsageFlags = struct {
    pub const transfer_src: u32 = 0x1;
    pub const transfer_dst: u32 = 0x2;
    pub const sampled: u32 = 0x4;
    pub const storage: u32 = 0x8;
    pub const color_attachment: u32 = 0x10;
    pub const transient_attachment: u32 = 0x40;
    pub const input_attachment: u32 = 0x80;
};

pub const ImageAspectFlags = struct {
    pub const color: u32 = 0x1;
    pub const depth: u32 = 0x2;
    pub const stencil: u32 = 0x4;
};

pub const AccessFlags = struct {
    pub const indirect_command_read: u32 = 0x1;
    pub const uniform_read: u32 = 0x8;
    pub const shader_read: u32 = 0x20;
    pub const shader_write: u32 = 0x40;
    pub const color_attachment_read: u32 = 0x80;
    pub const color_attachment_write: u32 = 0x100;
    pub const transfer_read: u32 = 0x800;
    pub const transfer_write: u32 = 0x1000;
    pub const host_read: u32 = 0x2000;
    pub const host_write: u32 = 0x4000;
    pub const memory_read: u32 = 0x8000;
    pub const memory_write: u32 = 0x10000;
};

pub const PipelineStageFlags = struct {
    pub const top_of_pipe: u32 = 0x1;
    pub const draw_indirect: u32 = 0x2;
    pub const vertex_input: u32 = 0x4;
    pub const vertex_shader: u32 = 0x8;
    pub const fragment_shader: u32 = 0x80;
    pub const early_fragment_tests: u32 = 0x100;
    pub const late_fragment_tests: u32 = 0x200;
    pub const color_attachment_output: u32 = 0x400;
    pub const compute_shader: u32 = 0x800;
    pub const transfer: u32 = 0x1000;
    pub const bottom_of_pipe: u32 = 0x2000;
    pub const host: u32 = 0x4000;
    pub const all_graphics: u32 = 0x8000;
    pub const all_commands: u32 = 0x10000;
};

pub const ShaderStageFlags = struct {
    pub const vertex: u32 = 0x1;
    pub const fragment: u32 = 0x10;
    pub const compute: u32 = 0x20;
    pub const all_graphics: u32 = 0x1f;
};

pub const ColorComponentFlags = struct {
    pub const r: u32 = 0x1;
    pub const g: u32 = 0x2;
    pub const b: u32 = 0x4;
    pub const a: u32 = 0x8;
    pub const rgba: u32 = 0xf;
};

pub const CommandPoolCreateFlags = struct {
    pub const transient: u32 = 0x1;
    pub const reset_command_buffer: u32 = 0x2;
};

pub const CommandBufferUsageFlags = struct {
    pub const one_time_submit: u32 = 0x1;
    pub const render_pass_continue: u32 = 0x2;
    pub const simultaneous_use: u32 = 0x4;
};

pub const FenceCreateFlags = struct {
    pub const signaled: u32 = 0x1;
};

pub const SampleCountFlags = struct {
    pub const @"1": u32 = 0x1;
    pub const @"2": u32 = 0x2;
    pub const @"4": u32 = 0x4;
    pub const @"8": u32 = 0x8;
};

pub const SurfaceTransformFlagsKHR = struct {
    pub const identity: u32 = 0x1;
};

pub const CompositeAlphaFlagsKHR = struct {
    pub const @"opaque": u32 = 0x1;
    pub const pre_multiplied: u32 = 0x2;
    pub const post_multiplied: u32 = 0x4;
    pub const inherit: u32 = 0x8;
};

pub const DescriptorPoolCreateFlags = struct {
    pub const free_descriptor_set: u32 = 0x1;
    pub const update_after_bind: u32 = 0x2;
};

pub const DescriptorSetLayoutCreateFlags = struct {
    pub const update_after_bind_pool: u32 = 0x2;
};

pub const DescriptorBindingFlags = struct {
    pub const update_after_bind: u32 = 0x1;
    pub const update_unused_while_pending: u32 = 0x2;
    pub const partially_bound: u32 = 0x4;
    pub const variable_descriptor_count: u32 = 0x8;
};

pub const DebugUtilsMessageSeverityFlagsEXT = struct {
    pub const verbose: u32 = 0x1;
    pub const info: u32 = 0x10;
    pub const warning: u32 = 0x100;
    pub const @"error": u32 = 0x1000;
};

pub const DebugUtilsMessageTypeFlagsEXT = struct {
    pub const general: u32 = 0x1;
    pub const validation: u32 = 0x2;
    pub const performance: u32 = 0x4;
};

// -- small structures -------------------------------------------------------

pub const Offset2D = extern struct { x: i32 = 0, y: i32 = 0 };
pub const Offset3D = extern struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };
pub const Extent2D = extern struct { width: u32 = 0, height: u32 = 0 };
pub const Extent3D = extern struct { width: u32 = 0, height: u32 = 0, depth: u32 = 1 };
pub const Rect2D = extern struct { offset: Offset2D = .{}, extent: Extent2D = .{} };

pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const ClearValue = extern union {
    color: ClearColorValue,
    depth_stencil: extern struct { depth: f32, stencil: u32 },
};

pub const ComponentMapping = extern struct {
    r: ComponentSwizzle = .identity,
    g: ComponentSwizzle = .identity,
    b: ComponentSwizzle = .identity,
    a: ComponentSwizzle = .identity,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: u32,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageSubresourceLayers = extern struct {
    aspect_mask: u32,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const BufferImageCopy = extern struct {
    buffer_offset: u64 = 0,
    /// Zero means "tightly packed to `image_extent`", which is what every
    /// upload here wants and what a nonzero value silently breaks.
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers,
    image_offset: Offset3D = .{},
    image_extent: Extent3D,
};

pub const BufferCopy = extern struct {
    src_offset: u64 = 0,
    dst_offset: u64 = 0,
    size: u64,
};

pub const MemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memory_type_bits: u32,
};

pub const MemoryType = extern struct {
    property_flags: u32,
    heap_index: u32,
};

pub const MemoryHeap = extern struct {
    size: u64,
    flags: u32,
};

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32 = 0,
    memory_types: [32]MemoryType = undefined,
    memory_heap_count: u32 = 0,
    memory_heaps: [16]MemoryHeap = undefined,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: u32,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const ExtensionProperties = extern struct {
    extension_name: [max_extension_name_size]u8,
    spec_version: u32,

    pub fn name(e: *const ExtensionProperties) []const u8 {
        return std.mem.sliceTo(&e.extension_name, 0);
    }
};

pub const LayerProperties = extern struct {
    layer_name: [max_extension_name_size]u8,
    spec_version: u32,
    implementation_version: u32,
    description: [max_description_size]u8,

    pub fn name(l: *const LayerProperties) []const u8 {
        return std.mem.sliceTo(&l.layer_name, 0);
    }
};

/// Named as far as the timestamp period; see the header for why the rest is
/// a blob.
///
/// The fields between are blobs too, sized from the spec's field order: all
/// four-byte values but one `size_t` and three `VkDeviceSize`s, which are
/// named because their width and alignment depend on the target. A test
/// checks the period lands at 424, where every 64-bit header puts it.
///
/// The tail is sized well past `sizeof(VkPhysicalDeviceLimits) +
/// sizeof(VkPhysicalDeviceSparseProperties)`, which is a little over 500
/// bytes. The driver writes what it writes and stops.
pub const PhysicalDeviceLimits = extern struct {
    max_image_dimension_1d: u32,
    max_image_dimension_2d: u32,
    max_image_dimension_3d: u32,
    max_image_dimension_cube: u32,
    max_image_array_layers: u32,
    max_texel_buffer_elements: u32,
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,
    max_push_constants_size: u32,
    max_memory_allocation_count: u32,
    max_sampler_allocation_count: u32,
    buffer_image_granularity: u64,
    sparse_address_space_size: u64,
    max_bound_descriptor_sets: u32,
    max_per_stage_descriptor_samplers: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    max_per_stage_descriptor_storage_buffers: u32,
    max_per_stage_descriptor_sampled_images: u32,
    /// `maxPerStageDescriptorStorageImages` to `viewportSubPixelBits`: 54
    /// four-byte values.
    _to_map_alignment: [216]u8,
    min_memory_map_alignment: usize,
    min_texel_buffer_offset_alignment: u64,
    min_uniform_buffer_offset_alignment: u64,
    min_storage_buffer_offset_alignment: u64,
    /// `minTexelOffset` to `maxSampleMaskWords`: 21 four-byte values.
    _to_timestamps: [84]u8,
    timestamp_compute_and_graphics: u32,
    /// Nanoseconds per timestamp tick.
    timestamp_period: f32,
    _rest: [424]u8,
};

pub const PhysicalDeviceProperties = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [max_physical_device_name_size]u8,
    pipeline_cache_uuid: [uuid_size]u8,
    limits: PhysicalDeviceLimits,
    /// `VkPhysicalDeviceSparseProperties`, five `VkBool32`s, unread here.
    sparse_properties: [8]u32,

    pub fn name(p: *const PhysicalDeviceProperties) []const u8 {
        return std.mem.sliceTo(&p.device_name, 0);
    }

    /// The four vendors worth naming. A number is printed for the rest, which
    /// is more useful than a wrong guess.
    pub fn vendor(p: *const PhysicalDeviceProperties) []const u8 {
        return switch (p.vendor_id) {
            0x1002 => "AMD",
            0x10de => "NVIDIA",
            0x8086 => "Intel",
            0x13b5 => "ARM",
            0x5143 => "Qualcomm",
            0x1010 => "ImgTec",
            0x106b => "Apple",
            0x10005 => "Mesa",
            else => "",
        };
    }
};

/// `VkPhysicalDeviceFeatures`, 55 `VkBool32`s. Passed *in* to `vkCreateDevice`,
/// so unlike the limits above this one has to be exact -- but every field this
/// project needs is false, so it is declared as the array it is. Anything that
/// wants a feature enables it by index through the named constants below,
/// which is checkable in a way that a hundred-field struct literal is not.
pub const PhysicalDeviceFeatures = extern struct {
    bits: [55]u32 = @splat(0),

    pub const robust_buffer_access = 0;
    pub const full_draw_index_uint32 = 1;
    pub const image_cube_array = 2;
    pub const independent_blend = 3;
    pub const geometry_shader = 4;
    pub const sample_rate_shading = 8;
    pub const fill_mode_non_solid = 17;
    pub const wide_lines = 18;
    pub const shader_sampled_image_array_dynamic_indexing = 41;

    pub fn has(f: *const PhysicalDeviceFeatures, comptime which: comptime_int) bool {
        return f.bits[which] != 0;
    }

    pub fn set(f: *PhysicalDeviceFeatures, comptime which: comptime_int, on: bool) void {
        f.bits[which] = @intFromBool(on);
    }
};

pub const PhysicalDeviceFeatures2 = extern struct {
    s_type: StructureType = .physical_device_features_2,
    p_next: ?*anyopaque = null,
    features: PhysicalDeviceFeatures = .{},
};

/// The 1.2 feature struct this renderer actually cares about, chained onto
/// `PhysicalDeviceFeatures2` for the query and onto `DeviceCreateInfo` for the
/// creation. Every field is a `VkBool32`; the order is the specification's.
pub const PhysicalDeviceDescriptorIndexingFeatures = extern struct {
    s_type: StructureType = .physical_device_descriptor_indexing_features,
    p_next: ?*anyopaque = null,
    shader_input_attachment_array_dynamic_indexing: u32 = 0,
    shader_uniform_texel_buffer_array_dynamic_indexing: u32 = 0,
    shader_storage_texel_buffer_array_dynamic_indexing: u32 = 0,
    shader_uniform_buffer_array_non_uniform_indexing: u32 = 0,
    shader_sampled_image_array_non_uniform_indexing: u32 = 0,
    shader_storage_buffer_array_non_uniform_indexing: u32 = 0,
    shader_storage_image_array_non_uniform_indexing: u32 = 0,
    shader_input_attachment_array_non_uniform_indexing: u32 = 0,
    shader_uniform_texel_buffer_array_non_uniform_indexing: u32 = 0,
    shader_storage_texel_buffer_array_non_uniform_indexing: u32 = 0,
    descriptor_binding_uniform_buffer_update_after_bind: u32 = 0,
    descriptor_binding_sampled_image_update_after_bind: u32 = 0,
    descriptor_binding_storage_image_update_after_bind: u32 = 0,
    descriptor_binding_storage_buffer_update_after_bind: u32 = 0,
    descriptor_binding_uniform_texel_buffer_update_after_bind: u32 = 0,
    descriptor_binding_storage_texel_buffer_update_after_bind: u32 = 0,
    descriptor_binding_update_unused_while_pending: u32 = 0,
    descriptor_binding_partially_bound: u32 = 0,
    descriptor_binding_variable_descriptor_count: u32 = 0,
    runtime_descriptor_array: u32 = 0,
};

// -- surface ----------------------------------------------------------------

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32 = 0,
    max_image_count: u32 = 0,
    current_extent: Extent2D = .{},
    min_image_extent: Extent2D = .{},
    max_image_extent: Extent2D = .{},
    max_image_array_layers: u32 = 0,
    supported_transforms: u32 = 0,
    current_transform: u32 = 0,
    supported_composite_alpha: u32 = 0,
    supported_usage_flags: u32 = 0,
};

pub const SurfaceFormatKHR = extern struct {
    format: Format = .undefined,
    color_space: ColorSpaceKHR = .srgb_nonlinear,
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .win32_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};

pub const XcbSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .xcb_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    connection: ?*anyopaque,
    window: u32,
};

pub const XlibSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .xlib_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    dpy: ?*anyopaque,
    window: c_ulong,
};

pub const WaylandSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .wayland_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    display: ?*anyopaque,
    surface: ?*anyopaque,
};

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: StructureType = .swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    surface: SurfaceKHR,
    min_image_count: u32,
    image_format: Format,
    image_color_space: ColorSpaceKHR,
    image_extent: Extent2D,
    image_array_layers: u32 = 1,
    image_usage: u32,
    image_sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
    pre_transform: u32,
    composite_alpha: u32,
    present_mode: PresentModeKHR,
    clipped: u32 = 1,
    old_swapchain: SwapchainKHR = null_handle,
};

pub const PresentInfoKHR = extern struct {
    s_type: StructureType = .present_info_khr,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    p_wait_semaphores: ?[*]const Semaphore = null,
    swapchain_count: u32,
    p_swapchains: [*]const SwapchainKHR,
    p_image_indices: [*]const u32,
    p_results: ?[*]Result = null,
};

// -- creation structures ----------------------------------------------------

pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    p_next: ?*const anyopaque = null,
    p_application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    p_engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    p_application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
    queue_count: u32,
    p_queue_priorities: [*]const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_create_info_count: u32,
    p_queue_create_infos: [*]const DeviceQueueCreateInfo,
    /// Deprecated and ignored by every modern loader, but still part of the
    /// structure, so it still has to be here.
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
    /// Must be null when `PhysicalDeviceFeatures2` is chained through `p_next`,
    /// and passing both is a validation error rather than a merge.
    p_enabled_features: ?*const PhysicalDeviceFeatures = null,
};

pub const DebugUtilsLabelEXT = extern struct {
    s_type: StructureType = .debug_utils_object_name_info_ext,
    p_next: ?*const anyopaque = null,
    p_label_name: ?[*:0]const u8 = null,
    color: [4]f32 = @splat(0),
};

pub const DebugUtilsObjectNameInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_object_name_info_ext,
    p_next: ?*const anyopaque = null,
    object_type: u32 = 0,
    object_handle: u64 = 0,
    p_object_name: ?[*:0]const u8 = null,
};

pub const DebugUtilsMessengerCallbackDataEXT = extern struct {
    s_type: StructureType = .debug_utils_messenger_callback_data_ext,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    p_message_id_name: ?[*:0]const u8 = null,
    message_id_number: i32 = 0,
    p_message: ?[*:0]const u8 = null,
    queue_label_count: u32 = 0,
    p_queue_labels: ?[*]const DebugUtilsLabelEXT = null,
    cmd_buf_label_count: u32 = 0,
    p_cmd_buf_labels: ?[*]const DebugUtilsLabelEXT = null,
    object_count: u32 = 0,
    p_objects: ?[*]const DebugUtilsObjectNameInfoEXT = null,
};

pub const PfnDebugUtilsMessengerCallbackEXT = *const fn (
    severity: u32,
    types: u32,
    data: ?*const DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) u32;

pub const DebugUtilsMessengerCreateInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_messenger_create_info_ext,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    message_severity: u32,
    message_type: u32,
    pfn_user_callback: PfnDebugUtilsMessengerCallbackEXT,
    p_user_data: ?*anyopaque = null,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = .memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: u64,
    memory_type_index: u32,
};

pub const MappedMemoryRange = extern struct {
    s_type: StructureType = .mapped_memory_range,
    p_next: ?*const anyopaque = null,
    memory: DeviceMemory,
    offset: u64 = 0,
    size: u64 = whole_size,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = .buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
};

pub const ImageCreateInfo = extern struct {
    s_type: StructureType = .image_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    image_type: ImageType = .@"2d",
    format: Format,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: u32 = SampleCountFlags.@"1",
    tiling: ImageTiling = .optimal,
    usage: u32,
    sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
    initial_layout: ImageLayout = .undefined,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: StructureType = .image_view_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    image: Image,
    view_type: ImageViewType = .@"2d",
    format: Format,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange,
};

pub const SamplerCreateInfo = extern struct {
    s_type: StructureType = .sampler_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    mipmap_mode: SamplerMipmapMode = .nearest,
    address_mode_u: SamplerAddressMode = .clamp_to_edge,
    address_mode_v: SamplerAddressMode = .clamp_to_edge,
    address_mode_w: SamplerAddressMode = .clamp_to_edge,
    mip_lod_bias: f32 = 0,
    anisotropy_enable: u32 = 0,
    max_anisotropy: f32 = 1,
    compare_enable: u32 = 0,
    compare_op: CompareOp = .never,
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: BorderColor = .float_transparent_black,
    unnormalized_coordinates: u32 = 0,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: StructureType = .shader_module_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    /// Bytes, not words -- one of the few places Vulkan counts in bytes and
    /// then demands a `u32` pointer.
    code_size: usize,
    p_code: [*]const u32,
};

pub const SpecializationInfo = extern struct {
    map_entry_count: u32 = 0,
    p_map_entries: ?*const anyopaque = null,
    data_size: usize = 0,
    p_data: ?*const anyopaque = null,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: StructureType = .pipeline_shader_stage_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: ShaderModule,
    p_name: [*:0]const u8,
    p_specialization_info: ?*const SpecializationInfo = null,
};

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_vertex_input_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    vertex_binding_description_count: u32 = 0,
    p_vertex_binding_descriptions: ?*const anyopaque = null,
    vertex_attribute_description_count: u32 = 0,
    p_vertex_attribute_descriptions: ?*const anyopaque = null,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_input_assembly_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: PrimitiveTopology,
    primitive_restart_enable: u32 = 0,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_viewport_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    viewport_count: u32 = 1,
    p_viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 1,
    p_scissors: ?[*]const Rect2D = null,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_rasterization_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    depth_clamp_enable: u32 = 0,
    rasterizer_discard_enable: u32 = 0,
    polygon_mode: PolygonMode = .fill,
    cull_mode: u32 = 0,
    front_face: FrontFace = .counter_clockwise,
    depth_bias_enable: u32 = 0,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_multisample_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    rasterization_samples: u32 = SampleCountFlags.@"1",
    sample_shading_enable: u32 = 0,
    min_sample_shading: f32 = 0,
    p_sample_mask: ?[*]const u32 = null,
    alpha_to_coverage_enable: u32 = 0,
    alpha_to_one_enable: u32 = 0,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: u32 = 0,
    src_color_blend_factor: BlendFactor = .one,
    dst_color_blend_factor: BlendFactor = .zero,
    color_blend_op: BlendOp = .add,
    src_alpha_blend_factor: BlendFactor = .one,
    dst_alpha_blend_factor: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,
    color_write_mask: u32 = ColorComponentFlags.rgba,
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_color_blend_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    logic_op_enable: u32 = 0,
    logic_op: LogicOp = .copy,
    attachment_count: u32,
    p_attachments: [*]const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32 = @splat(0),
};

pub const PipelineDynamicStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_dynamic_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    dynamic_state_count: u32,
    p_dynamic_states: [*]const DynamicState,
};

pub const PushConstantRange = extern struct {
    stage_flags: u32,
    offset: u32,
    size: u32,
};

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: StructureType = .pipeline_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    set_layout_count: u32 = 0,
    p_set_layouts: ?[*]const DescriptorSetLayout = null,
    push_constant_range_count: u32 = 0,
    p_push_constant_ranges: ?[*]const PushConstantRange = null,
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: StructureType = .graphics_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage_count: u32,
    p_stages: [*]const PipelineShaderStageCreateInfo,
    p_vertex_input_state: ?*const PipelineVertexInputStateCreateInfo,
    p_input_assembly_state: ?*const PipelineInputAssemblyStateCreateInfo,
    p_tessellation_state: ?*const anyopaque = null,
    p_viewport_state: ?*const PipelineViewportStateCreateInfo,
    p_rasterization_state: ?*const PipelineRasterizationStateCreateInfo,
    p_multisample_state: ?*const PipelineMultisampleStateCreateInfo,
    p_depth_stencil_state: ?*const anyopaque = null,
    p_color_blend_state: ?*const PipelineColorBlendStateCreateInfo,
    p_dynamic_state: ?*const PipelineDynamicStateCreateInfo,
    layout: PipelineLayout,
    render_pass: RenderPass,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = null_handle,
    base_pipeline_index: i32 = -1,
};

pub const AttachmentDescription = extern struct {
    flags: u32 = 0,
    format: Format,
    samples: u32 = SampleCountFlags.@"1",
    load_op: AttachmentLoadOp,
    store_op: AttachmentStoreOp,
    stencil_load_op: AttachmentLoadOp = .dont_care,
    stencil_store_op: AttachmentStoreOp = .dont_care,
    initial_layout: ImageLayout,
    final_layout: ImageLayout,
};

pub const AttachmentReference = extern struct {
    attachment: u32,
    layout: ImageLayout,
};

pub const SubpassDescription = extern struct {
    flags: u32 = 0,
    pipeline_bind_point: PipelineBindPoint = .graphics,
    input_attachment_count: u32 = 0,
    p_input_attachments: ?[*]const AttachmentReference = null,
    color_attachment_count: u32 = 0,
    p_color_attachments: ?[*]const AttachmentReference = null,
    p_resolve_attachments: ?[*]const AttachmentReference = null,
    p_depth_stencil_attachment: ?*const AttachmentReference = null,
    preserve_attachment_count: u32 = 0,
    p_preserve_attachments: ?[*]const u32 = null,
};

pub const SubpassDependency = extern struct {
    src_subpass: u32,
    dst_subpass: u32,
    src_stage_mask: u32,
    dst_stage_mask: u32,
    src_access_mask: u32,
    dst_access_mask: u32,
    dependency_flags: u32 = 0,
};

pub const RenderPassCreateInfo = extern struct {
    s_type: StructureType = .render_pass_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    attachment_count: u32 = 0,
    p_attachments: ?[*]const AttachmentDescription = null,
    subpass_count: u32 = 0,
    p_subpasses: ?[*]const SubpassDescription = null,
    dependency_count: u32 = 0,
    p_dependencies: ?[*]const SubpassDependency = null,
};

pub const FramebufferCreateInfo = extern struct {
    s_type: StructureType = .framebuffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    render_pass: RenderPass,
    attachment_count: u32,
    p_attachments: [*]const ImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

pub const RenderPassBeginInfo = extern struct {
    s_type: StructureType = .render_pass_begin_info,
    p_next: ?*const anyopaque = null,
    render_pass: RenderPass,
    framebuffer: Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32 = 0,
    p_clear_values: ?[*]const ClearValue = null,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: DescriptorType,
    descriptor_count: u32,
    stage_flags: u32,
    p_immutable_samplers: ?[*]const Sampler = null,
};

pub const DescriptorSetLayoutBindingFlagsCreateInfo = extern struct {
    s_type: StructureType = .descriptor_set_layout_binding_flags_create_info,
    p_next: ?*const anyopaque = null,
    binding_count: u32,
    p_binding_flags: [*]const u32,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: StructureType = .descriptor_set_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    binding_count: u32,
    p_bindings: [*]const DescriptorSetLayoutBinding,
};

pub const DescriptorPoolSize = extern struct {
    type: DescriptorType,
    descriptor_count: u32,
};

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: StructureType = .descriptor_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    max_sets: u32,
    pool_size_count: u32,
    p_pool_sizes: [*]const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: StructureType = .descriptor_set_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    p_set_layouts: [*]const DescriptorSetLayout,
};

pub const DescriptorSetVariableDescriptorCountAllocateInfo = extern struct {
    s_type: StructureType = .descriptor_set_variable_descriptor_count_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_set_count: u32,
    p_descriptor_counts: [*]const u32,
};

pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: u64 = 0,
    range: u64 = whole_size,
};

pub const DescriptorImageInfo = extern struct {
    sampler: Sampler = null_handle,
    image_view: ImageView = null_handle,
    image_layout: ImageLayout = .undefined,
};

pub const WriteDescriptorSet = extern struct {
    s_type: StructureType = .write_descriptor_set,
    p_next: ?*const anyopaque = null,
    dst_set: DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32 = 0,
    descriptor_count: u32,
    descriptor_type: DescriptorType,
    p_image_info: ?[*]const DescriptorImageInfo = null,
    p_buffer_info: ?[*]const DescriptorBufferInfo = null,
    p_texel_buffer_view: ?[*]const Handle = null,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = .command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = .command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: CommandBufferLevel = .primary,
    command_buffer_count: u32,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = .command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    p_inheritance_info: ?*const anyopaque = null,
};

pub const SubmitInfo = extern struct {
    s_type: StructureType = .submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    p_wait_semaphores: ?[*]const Semaphore = null,
    p_wait_dst_stage_mask: ?[*]const u32 = null,
    command_buffer_count: u32 = 0,
    p_command_buffers: ?[*]const CommandBuffer = null,
    signal_semaphore_count: u32 = 0,
    p_signal_semaphores: ?[*]const Semaphore = null,
};

pub const FenceCreateInfo = extern struct {
    s_type: StructureType = .fence_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const QueryType = enum(u32) {
    occlusion = 0,
    pipeline_statistics = 1,
    timestamp = 2,
    _,
};

pub const QueryPoolCreateInfo = extern struct {
    s_type: StructureType = .query_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    query_type: QueryType,
    query_count: u32,
    pipeline_statistics: u32 = 0,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType = .semaphore_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const MemoryBarrier = extern struct {
    s_type: StructureType = .memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32,
    dst_access_mask: u32,
};

pub const BufferMemoryBarrier = extern struct {
    s_type: StructureType = .buffer_memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32,
    dst_access_mask: u32,
    src_queue_family_index: u32 = queue_family_ignored,
    dst_queue_family_index: u32 = queue_family_ignored,
    buffer: Buffer,
    offset: u64 = 0,
    size: u64 = whole_size,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: StructureType = .image_memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32,
    dst_access_mask: u32,
    old_layout: ImageLayout,
    new_layout: ImageLayout,
    src_queue_family_index: u32 = queue_family_ignored,
    dst_queue_family_index: u32 = queue_family_ignored,
    image: Image,
    subresource_range: ImageSubresourceRange,
};

// -- extension names --------------------------------------------------------

pub const extensions = struct {
    pub const surface = "VK_KHR_surface";
    pub const win32_surface = "VK_KHR_win32_surface";
    pub const xcb_surface = "VK_KHR_xcb_surface";
    pub const xlib_surface = "VK_KHR_xlib_surface";
    pub const wayland_surface = "VK_KHR_wayland_surface";
    pub const swapchain = "VK_KHR_swapchain";
    pub const debug_utils = "VK_EXT_debug_utils";
    pub const descriptor_indexing = "VK_EXT_descriptor_indexing";
    pub const get_physical_device_properties_2 = "VK_KHR_get_physical_device_properties2";
    pub const portability_enumeration = "VK_KHR_portability_enumeration";
};

pub const layers = struct {
    pub const validation = "VK_LAYER_KHRONOS_validation";
};

// -- function pointer types -------------------------------------------------
//
// Named for the function rather than for the type, because every one of them
// is used exactly once, in the dispatch table in `loader.zig`.

pub const PfnVoidFunction = *const fn () callconv(.c) void;
pub const PfnGetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?PfnVoidFunction;
pub const PfnGetDeviceProcAddr = *const fn (Device, [*:0]const u8) callconv(.c) ?PfnVoidFunction;

pub const PfnCreateInstance = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(.c) Result;
pub const PfnDestroyInstance = *const fn (Instance, ?*const anyopaque) callconv(.c) void;
pub const PfnEnumerateInstanceExtensionProperties = *const fn (?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result;
pub const PfnEnumerateInstanceLayerProperties = *const fn (*u32, ?[*]LayerProperties) callconv(.c) Result;
pub const PfnEnumerateInstanceVersion = *const fn (*u32) callconv(.c) Result;

pub const PfnEnumeratePhysicalDevices = *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result;
pub const PfnGetPhysicalDeviceProperties = *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void;
pub const PfnGetPhysicalDeviceFeatures2 = *const fn (PhysicalDevice, *PhysicalDeviceFeatures2) callconv(.c) void;
pub const PfnGetPhysicalDeviceMemoryProperties = *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void;
pub const PfnGetPhysicalDeviceQueueFamilyProperties = *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void;
pub const PfnEnumerateDeviceExtensionProperties = *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result;
pub const PfnCreateDevice = *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *Device) callconv(.c) Result;
pub const PfnDestroyDevice = *const fn (Device, ?*const anyopaque) callconv(.c) void;

pub const PfnDestroySurfaceKHR = *const fn (Instance, SurfaceKHR, ?*const anyopaque) callconv(.c) void;
pub const PfnGetPhysicalDeviceSurfaceSupportKHR = *const fn (PhysicalDevice, u32, SurfaceKHR, *u32) callconv(.c) Result;
pub const PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (PhysicalDevice, SurfaceKHR, *SurfaceCapabilitiesKHR) callconv(.c) Result;
pub const PfnGetPhysicalDeviceSurfaceFormatsKHR = *const fn (PhysicalDevice, SurfaceKHR, *u32, ?[*]SurfaceFormatKHR) callconv(.c) Result;
pub const PfnGetPhysicalDeviceSurfacePresentModesKHR = *const fn (PhysicalDevice, SurfaceKHR, *u32, ?[*]PresentModeKHR) callconv(.c) Result;
pub const PfnCreateWin32SurfaceKHR = *const fn (Instance, *const Win32SurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(.c) Result;
pub const PfnCreateXcbSurfaceKHR = *const fn (Instance, *const XcbSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(.c) Result;
pub const PfnCreateXlibSurfaceKHR = *const fn (Instance, *const XlibSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(.c) Result;
pub const PfnCreateWaylandSurfaceKHR = *const fn (Instance, *const WaylandSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(.c) Result;

pub const PfnCreateDebugUtilsMessengerEXT = *const fn (Instance, *const DebugUtilsMessengerCreateInfoEXT, ?*const anyopaque, *DebugUtilsMessengerEXT) callconv(.c) Result;
pub const PfnDestroyDebugUtilsMessengerEXT = *const fn (Instance, DebugUtilsMessengerEXT, ?*const anyopaque) callconv(.c) void;

pub const PfnGetDeviceQueue = *const fn (Device, u32, u32, *Queue) callconv(.c) void;
pub const PfnDeviceWaitIdle = *const fn (Device) callconv(.c) Result;
pub const PfnQueueSubmit = *const fn (Queue, u32, ?[*]const SubmitInfo, Fence) callconv(.c) Result;
pub const PfnQueueWaitIdle = *const fn (Queue) callconv(.c) Result;
pub const PfnQueuePresentKHR = *const fn (Queue, *const PresentInfoKHR) callconv(.c) Result;

pub const PfnCreateSwapchainKHR = *const fn (Device, *const SwapchainCreateInfoKHR, ?*const anyopaque, *SwapchainKHR) callconv(.c) Result;
pub const PfnDestroySwapchainKHR = *const fn (Device, SwapchainKHR, ?*const anyopaque) callconv(.c) void;
pub const PfnGetSwapchainImagesKHR = *const fn (Device, SwapchainKHR, *u32, ?[*]Image) callconv(.c) Result;
pub const PfnAcquireNextImageKHR = *const fn (Device, SwapchainKHR, u64, Semaphore, Fence, *u32) callconv(.c) Result;

pub const PfnCreateImageView = *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *ImageView) callconv(.c) Result;
pub const PfnDestroyImageView = *const fn (Device, ImageView, ?*const anyopaque) callconv(.c) void;
pub const PfnCreateImage = *const fn (Device, *const ImageCreateInfo, ?*const anyopaque, *Image) callconv(.c) Result;
pub const PfnDestroyImage = *const fn (Device, Image, ?*const anyopaque) callconv(.c) void;
pub const PfnGetImageMemoryRequirements = *const fn (Device, Image, *MemoryRequirements) callconv(.c) void;
pub const PfnBindImageMemory = *const fn (Device, Image, DeviceMemory, u64) callconv(.c) Result;
pub const PfnCreateSampler = *const fn (Device, *const SamplerCreateInfo, ?*const anyopaque, *Sampler) callconv(.c) Result;
pub const PfnDestroySampler = *const fn (Device, Sampler, ?*const anyopaque) callconv(.c) void;

pub const PfnCreateBuffer = *const fn (Device, *const BufferCreateInfo, ?*const anyopaque, *Buffer) callconv(.c) Result;
pub const PfnDestroyBuffer = *const fn (Device, Buffer, ?*const anyopaque) callconv(.c) void;
pub const PfnGetBufferMemoryRequirements = *const fn (Device, Buffer, *MemoryRequirements) callconv(.c) void;
pub const PfnBindBufferMemory = *const fn (Device, Buffer, DeviceMemory, u64) callconv(.c) Result;
pub const PfnAllocateMemory = *const fn (Device, *const MemoryAllocateInfo, ?*const anyopaque, *DeviceMemory) callconv(.c) Result;
pub const PfnFreeMemory = *const fn (Device, DeviceMemory, ?*const anyopaque) callconv(.c) void;
pub const PfnMapMemory = *const fn (Device, DeviceMemory, u64, u64, u32, *?*anyopaque) callconv(.c) Result;
pub const PfnUnmapMemory = *const fn (Device, DeviceMemory) callconv(.c) void;
pub const PfnFlushMappedMemoryRanges = *const fn (Device, u32, [*]const MappedMemoryRange) callconv(.c) Result;

pub const PfnCreateShaderModule = *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *ShaderModule) callconv(.c) Result;
pub const PfnDestroyShaderModule = *const fn (Device, ShaderModule, ?*const anyopaque) callconv(.c) void;
pub const PfnCreatePipelineLayout = *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *PipelineLayout) callconv(.c) Result;
pub const PfnDestroyPipelineLayout = *const fn (Device, PipelineLayout, ?*const anyopaque) callconv(.c) void;
pub const PfnCreateGraphicsPipelines = *const fn (Device, PipelineCache, u32, [*]const GraphicsPipelineCreateInfo, ?*const anyopaque, [*]Pipeline) callconv(.c) Result;
pub const PfnDestroyPipeline = *const fn (Device, Pipeline, ?*const anyopaque) callconv(.c) void;
pub const PfnCreateRenderPass = *const fn (Device, *const RenderPassCreateInfo, ?*const anyopaque, *RenderPass) callconv(.c) Result;
pub const PfnDestroyRenderPass = *const fn (Device, RenderPass, ?*const anyopaque) callconv(.c) void;
pub const PfnCreateFramebuffer = *const fn (Device, *const FramebufferCreateInfo, ?*const anyopaque, *Framebuffer) callconv(.c) Result;
pub const PfnDestroyFramebuffer = *const fn (Device, Framebuffer, ?*const anyopaque) callconv(.c) void;

pub const PfnCreateDescriptorSetLayout = *const fn (Device, *const DescriptorSetLayoutCreateInfo, ?*const anyopaque, *DescriptorSetLayout) callconv(.c) Result;
pub const PfnDestroyDescriptorSetLayout = *const fn (Device, DescriptorSetLayout, ?*const anyopaque) callconv(.c) void;
pub const PfnCreateDescriptorPool = *const fn (Device, *const DescriptorPoolCreateInfo, ?*const anyopaque, *DescriptorPool) callconv(.c) Result;
pub const PfnDestroyDescriptorPool = *const fn (Device, DescriptorPool, ?*const anyopaque) callconv(.c) void;
pub const PfnAllocateDescriptorSets = *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(.c) Result;
pub const PfnUpdateDescriptorSets = *const fn (Device, u32, ?[*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void;

pub const PfnCreateCommandPool = *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *CommandPool) callconv(.c) Result;
pub const PfnDestroyCommandPool = *const fn (Device, CommandPool, ?*const anyopaque) callconv(.c) void;
pub const PfnResetCommandPool = *const fn (Device, CommandPool, u32) callconv(.c) Result;
pub const PfnAllocateCommandBuffers = *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(.c) Result;
pub const PfnFreeCommandBuffers = *const fn (Device, CommandPool, u32, [*]const CommandBuffer) callconv(.c) void;
pub const PfnBeginCommandBuffer = *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result;
pub const PfnEndCommandBuffer = *const fn (CommandBuffer) callconv(.c) Result;

pub const PfnCreateFence = *const fn (Device, *const FenceCreateInfo, ?*const anyopaque, *Fence) callconv(.c) Result;
pub const PfnDestroyFence = *const fn (Device, Fence, ?*const anyopaque) callconv(.c) void;
pub const PfnWaitForFences = *const fn (Device, u32, [*]const Fence, u32, u64) callconv(.c) Result;
pub const PfnResetFences = *const fn (Device, u32, [*]const Fence) callconv(.c) Result;
pub const PfnCreateSemaphore = *const fn (Device, *const SemaphoreCreateInfo, ?*const anyopaque, *Semaphore) callconv(.c) Result;
pub const PfnDestroySemaphore = *const fn (Device, Semaphore, ?*const anyopaque) callconv(.c) void;

pub const PfnCmdBeginRenderPass = *const fn (CommandBuffer, *const RenderPassBeginInfo, SubpassContents) callconv(.c) void;
pub const PfnCmdEndRenderPass = *const fn (CommandBuffer) callconv(.c) void;
pub const PfnCmdBindPipeline = *const fn (CommandBuffer, PipelineBindPoint, Pipeline) callconv(.c) void;
pub const PfnCmdBindDescriptorSets = *const fn (CommandBuffer, PipelineBindPoint, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?[*]const u32) callconv(.c) void;
pub const PfnCmdPushConstants = *const fn (CommandBuffer, PipelineLayout, u32, u32, u32, *const anyopaque) callconv(.c) void;
pub const PfnCmdSetViewport = *const fn (CommandBuffer, u32, u32, [*]const Viewport) callconv(.c) void;
pub const PfnCmdSetScissor = *const fn (CommandBuffer, u32, u32, [*]const Rect2D) callconv(.c) void;
pub const PfnCmdDraw = *const fn (CommandBuffer, u32, u32, u32, u32) callconv(.c) void;
pub const PfnCmdCopyBuffer = *const fn (CommandBuffer, Buffer, Buffer, u32, [*]const BufferCopy) callconv(.c) void;
pub const PfnCmdCopyBufferToImage = *const fn (CommandBuffer, Buffer, Image, ImageLayout, u32, [*]const BufferImageCopy) callconv(.c) void;
pub const PfnCmdCopyImageToBuffer = *const fn (CommandBuffer, Image, ImageLayout, Buffer, u32, [*]const BufferImageCopy) callconv(.c) void;
pub const PfnCmdPipelineBarrier = *const fn (
    CommandBuffer,
    u32,
    u32,
    u32,
    u32,
    ?[*]const MemoryBarrier,
    u32,
    ?[*]const BufferMemoryBarrier,
    u32,
    ?[*]const ImageMemoryBarrier,
) callconv(.c) void;
pub const PfnCreateQueryPool = *const fn (Device, *const QueryPoolCreateInfo, ?*const anyopaque, *QueryPool) callconv(.c) Result;
pub const PfnDestroyQueryPool = *const fn (Device, QueryPool, ?*const anyopaque) callconv(.c) void;
pub const PfnCmdResetQueryPool = *const fn (CommandBuffer, QueryPool, u32, u32) callconv(.c) void;
pub const PfnCmdWriteTimestamp = *const fn (CommandBuffer, u32, QueryPool, u32) callconv(.c) void;
pub const PfnGetQueryPoolResults = *const fn (Device, QueryPool, u32, u32, usize, *anyopaque, u64, u32) callconv(.c) Result;

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "structures passed to the driver have the sizes the ABI fixes" {
    // Only the ones whose layout a mistake would silently corrupt. A wrong
    // size here is a black window with no validation message, because the
    // driver reads the fields it expects at the offsets it expects.
    //
    // The sizes with a pointer in them are checked on 64-bit only, where the
    // numbers are the ones in every Vulkan header; on a 32-bit build the same
    // padding rules apply and produce different totals, and asserting an
    // arithmetic expression rather than a constant would just restate the
    // compiler's own layout back to itself.
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(usize, 64), @sizeOf(InstanceCreateInfo));
        try testing.expectEqual(@as(usize, 40), @sizeOf(DeviceQueueCreateInfo));
        try testing.expectEqual(@as(usize, 72), @sizeOf(DeviceCreateInfo));
        try testing.expectEqual(@as(usize, 104), @sizeOf(SwapchainCreateInfoKHR));
        try testing.expectEqual(@as(usize, 64), @sizeOf(WriteDescriptorSet));
        try testing.expectEqual(@as(usize, 40), @sizeOf(Win32SurfaceCreateInfoKHR));
    }
    // These have no pointers in them and are the same everywhere.
    try testing.expectEqual(@as(usize, 24), @sizeOf(QueueFamilyProperties));
    try testing.expectEqual(@as(usize, 8), @sizeOf(MemoryType));
    try testing.expectEqual(@as(usize, 16), @sizeOf(MemoryHeap));
    try testing.expectEqual(@as(usize, 52), @sizeOf(SurfaceCapabilitiesKHR));
    try testing.expectEqual(@as(usize, 8), @sizeOf(SurfaceFormatKHR));
    try testing.expectEqual(@as(usize, 220), @sizeOf(PhysicalDeviceFeatures));
}

test "non-dispatchable handles are 64 bits on every target" {
    // The one that bites on a 32-bit build: declaring these as pointers makes
    // every structure containing one half a word short.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Buffer));
    try testing.expectEqual(@as(usize, 8), @sizeOf(SwapchainKHR));
    try testing.expectEqual(@as(usize, 8), @sizeOf(DescriptorSet));
}

test "the properties structure is at least as large as the real one" {
    // Filled in by the driver, so larger is safe and smaller is a stack
    // overwrite. `VkPhysicalDeviceProperties` is 824 bytes in the C headers.
    try testing.expect(@sizeOf(PhysicalDeviceProperties) >= 824);
    try testing.expectEqual(@as(usize, 0), @offsetOf(PhysicalDeviceProperties, "api_version"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(PhysicalDeviceProperties, "device_type"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(PhysicalDeviceProperties, "device_name"));

    // What the timestamps are read with, at the spec's offsets. A period read
    // from the wrong place is a plausible float and every GPU time wrong by
    // a constant factor.
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(usize, 296), @offsetOf(PhysicalDeviceProperties, "limits"));
        // Padded from 300 to the `size_t`'s alignment.
        try testing.expectEqual(@as(usize, 304), @offsetOf(PhysicalDeviceLimits, "min_memory_map_alignment"));
        try testing.expectEqual(@as(usize, 336), @offsetOf(PhysicalDeviceLimits, "_to_timestamps"));
        try testing.expectEqual(@as(usize, 420), @offsetOf(PhysicalDeviceLimits, "timestamp_compute_and_graphics"));
        try testing.expectEqual(@as(usize, 424), @offsetOf(PhysicalDeviceLimits, "timestamp_period"));
    }
    try testing.expectEqual(@as(usize, 84), @offsetOf(PhysicalDeviceLimits, "_to_map_alignment"));
}

test "version numbers pack the way the macro does" {
    const v = makeVersion(0, 1, 2, 198);
    try testing.expectEqual(@as(u32, 1), versionMajor(v));
    try testing.expectEqual(@as(u32, 2), versionMinor(v));
    try testing.expectEqual(@as(u32, 198), versionPatch(v));
    try testing.expectEqual(api_1_2, makeVersion(0, 1, 2, 0));
    try testing.expect(api_1_2 > api_1_1);
}

test "suboptimal is a success and out-of-date is not" {
    // The distinction a resize depends on. Treating suboptimal as a failure
    // makes a window flicker; treating out-of-date as a success makes it
    // present into a swapchain the compositor has already thrown away.
    try testing.expect(Result.suboptimal_khr.isSuccess());
    try testing.expect(!Result.error_out_of_date_khr.isSuccess());
    try check(.suboptimal_khr);
    try testing.expectError(error.OutOfDate, check(.error_out_of_date_khr));
    try testing.expectError(error.DeviceLost, check(.error_device_lost));
}

test "the formats the swapchain prefers are the sRGB ones" {
    try testing.expect(Format.b8g8r8a8_srgb.isSrgb());
    try testing.expect(Format.r8g8b8a8_srgb.isSrgb());
    try testing.expect(!Format.b8g8r8a8_unorm.isSrgb());
    try testing.expect(!Format.r8_unorm.isSrgb());
}
