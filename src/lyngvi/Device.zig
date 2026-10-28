//! The instance, the physical device, the logical device, and the surface.
//!
//! Everything created once and kept for the life of the program. The swapchain
//! is not here, because it is created several times -- every resize -- and
//! mixing the two is how a resize ends up destroying something it should not.
//!
//! ## The decisions, and where they are
//!
//! None of the judgement is in this file. Which format, which present mode,
//! which memory type, which queue family, which of two GPUs: all of it lives
//! in `choose.zig`, as functions over the arrays Vulkan returns, tested
//! against the awkward cases without a device. What is left here is the part
//! that genuinely needs a driver -- asking, allocating, and cleaning up in the
//! reverse order.
//!
//! ## What is asked for, and what is merely preferred
//!
//! Required: a graphics queue, a queue that can present to the window's
//! surface, and `VK_KHR_swapchain`. That is the whole list. A device that
//! cannot do those three is not a candidate.
//!
//! Preferred, and detected rather than demanded: descriptor indexing. With it,
//! an instance can name any texture and the frame is one draw call. Without
//! it, `DrawList.textureRuns` splits the frame into runs of one texture and
//! everything still draws -- eighteen calls instead of one for the demo
//! interface. The class of device that lacks it is exactly the class of device
//! someone will try to read a PDF on, so it is a preference and not a
//! requirement.
//!
//! Validation layers are off unless asked for. They are worth an order of
//! magnitude in startup time and are the only reason anyone finds out that a
//! semaphore was reused, so `fenrir view --validate` exists.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Window = @import("Window.zig");
const choose = @import("choose.zig");
const loader = @import("loader.zig");
const vk = @import("vk.zig");

const Device = @This();

pub const Error = error{
    NoVulkanLoader,
    MissingEntryPoint,
    NoSurfaceExtension,
    SurfaceCreationFailed,
    NoSuitableDevice,
} || vk.Error || Allocator.Error;

pub const Options = struct {
    /// Turns on `VK_LAYER_KHRONOS_validation` and `VK_EXT_debug_utils`. Off by
    /// default: the layers cost most of a second at startup and are only
    /// installed with the SDK.
    validation: bool = false,
    /// A substring of the device name to prefer, for machines with two GPUs
    /// where the interesting one is not the one that scores highest.
    prefer: ?[]const u8 = null,
    application_name: [:0]const u8 = "fenrir",
};

/// What a device offers, gathered once so the renderer does not have to ask
/// again and the CLI can print it.
pub const Report = struct {
    name: [vk.max_physical_device_name_size]u8,
    name_len: usize,
    vendor: []const u8,
    kind: vk.PhysicalDeviceType,
    api_version: u32,
    driver_version: u32,
    descriptor_indexing: bool,
    swapchain: bool,
    /// Bytes in the largest device-local heap, which is the number people mean
    /// by "how much video memory".
    vram: u64,
    score: ?u32,

    pub fn deviceName(r: *const Report) []const u8 {
        return r.name[0..r.name_len];
    }
};

gpa: Allocator,
lib: loader.Library,

instance: vk.Instance = null,
it: loader.InstanceTable = undefined,
messenger: vk.DebugUtilsMessengerEXT = vk.null_handle,

surface: vk.SurfaceKHR = vk.null_handle,

physical: vk.PhysicalDevice = null,
properties: vk.PhysicalDeviceProperties = undefined,
memory: vk.PhysicalDeviceMemoryProperties = .{},
families: choose.Families = undefined,

handle: vk.Device = null,
dt: loader.DeviceTable = undefined,
graphics_queue: vk.Queue = null,
present_queue: vk.Queue = null,

/// True when the single-draw-call path is legal on this device.
descriptor_indexing: bool = false,
/// The API version the instance was created with, which caps what can be
/// asked of the device.
api_version: u32 = vk.api_1_0,

// -- creation ---------------------------------------------------------------

pub fn init(gpa: Allocator, window: Window, options: Options) Error!Device {
    var d: Device = .{ .gpa = gpa, .lib = try .open() };
    errdefer d.lib.close();

    const native = window.native();
    try d.createInstance(native, options);
    errdefer d.it.destroyInstance(d.instance, null);

    if (options.validation) d.createMessenger();

    try d.createSurface(native);
    errdefer if (d.it.destroySurfaceKHR) |f| f(d.instance, d.surface, null);

    try d.pickPhysical(options);
    try d.createLogical();

    return d;
}

pub fn deinit(d: *Device) void {
    if (d.handle != null) {
        _ = d.dt.deviceWaitIdle(d.handle);
        d.dt.destroyDevice(d.handle, null);
    }
    if (d.surface != vk.null_handle) {
        if (d.it.destroySurfaceKHR) |f| f(d.instance, d.surface, null);
    }
    if (d.messenger != vk.null_handle) {
        if (d.it.destroyDebugUtilsMessengerEXT) |f| f(d.instance, d.messenger, null);
    }
    if (d.instance != null) d.it.destroyInstance(d.instance, null);
    d.lib.close();
    d.* = undefined;
}

fn createInstance(d: *Device, native: Window.Native, options: Options) Error!void {
    const gpa = d.gpa;

    const available = try d.lib.instanceExtensions(gpa);
    defer gpa.free(available);

    var wanted: std.ArrayList([*:0]const u8) = .empty;
    defer wanted.deinit(gpa);

    if (!hasExtension(available, vk.extensions.surface)) return error.NoSurfaceExtension;
    try wanted.append(gpa, vk.extensions.surface);

    const platform = Window.Native.extensionFor(native);
    if (!hasExtension(available, platform)) return error.NoSurfaceExtension;
    // The names in `vk.extensions` are Zig string literals, which are already
    // NUL-terminated; the platform one comes back as a slice, so it is looked
    // up in the same table rather than allocated.
    try wanted.append(gpa, platformExtensionZ(native));

    var layers: std.ArrayList([*:0]const u8) = .empty;
    defer layers.deinit(gpa);

    if (options.validation) {
        const layer_list = try d.lib.instanceLayers(gpa);
        defer gpa.free(layer_list);
        for (layer_list) |l| {
            if (std.mem.eql(u8, l.name(), vk.layers.validation)) {
                try layers.append(gpa, vk.layers.validation);
                break;
            }
        }
        if (hasExtension(available, vk.extensions.debug_utils)) {
            try wanted.append(gpa, vk.extensions.debug_utils);
        }
    }

    // Ask for the highest version the loader admits to, capped at what this
    // renderer knows how to use. A 1.0 loader rejects anything higher outright
    // rather than clamping, which is why the cap is applied here and not
    // hopefully.
    const loader_version = d.lib.apiVersion();
    d.api_version = if (loader_version >= vk.api_1_2)
        vk.api_1_2
    else if (loader_version >= vk.api_1_1)
        vk.api_1_1
    else
        vk.api_1_0;

    const app: vk.ApplicationInfo = .{
        .p_application_name = options.application_name,
        .application_version = vk.makeVersion(0, 0, 1, 0),
        .p_engine_name = "gleipnir",
        .engine_version = vk.makeVersion(0, 0, 1, 0),
        .api_version = d.api_version,
    };

    const info: vk.InstanceCreateInfo = .{
        .p_application_info = &app,
        .enabled_layer_count = @intCast(layers.items.len),
        .pp_enabled_layer_names = if (layers.items.len == 0) null else layers.items.ptr,
        .enabled_extension_count = @intCast(wanted.items.len),
        .pp_enabled_extension_names = wanted.items.ptr,
    };

    try vk.check(d.lib.global.createInstance(&info, null, &d.instance));
    d.it = try d.lib.loadInstance(d.instance);
}

fn platformExtensionZ(native: Window.Native) [*:0]const u8 {
    return switch (native) {
        .win32 => vk.extensions.win32_surface,
        .xcb => vk.extensions.xcb_surface,
        .xlib => vk.extensions.xlib_surface,
        .wayland => vk.extensions.wayland_surface,
    };
}

fn hasExtension(list: []const vk.ExtensionProperties, wanted: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.name(), wanted)) return true;
    }
    return false;
}

fn debugCallback(
    severity: u32,
    types: u32,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) u32 {
    _ = user_data;
    const d = data orelse return 0;
    const text = if (d.p_message) |m| std.mem.span(m) else "(no message)";
    const kind: []const u8 = if (types & vk.DebugUtilsMessageTypeFlagsEXT.validation != 0)
        "validation"
    else if (types & vk.DebugUtilsMessageTypeFlagsEXT.performance != 0)
        "performance"
    else
        "general";
    const level: []const u8 = if (severity & vk.DebugUtilsMessageSeverityFlagsEXT.@"error" != 0)
        "error"
    else
        "warning";
    std.debug.print("vulkan {s} {s}: {s}\n", .{ kind, level, text });
    // Always zero. Returning nonzero aborts the call that produced the
    // message, which is a debugging tool and not a policy.
    return 0;
}

fn createMessenger(d: *Device) void {
    const create = d.it.createDebugUtilsMessengerEXT orelse return;
    const s = vk.DebugUtilsMessageSeverityFlagsEXT;
    const t = vk.DebugUtilsMessageTypeFlagsEXT;
    const info: vk.DebugUtilsMessengerCreateInfoEXT = .{
        // Warnings and errors only. The verbose level reports every object
        // creation, which is thousands of lines before the first frame.
        .message_severity = s.warning | s.@"error",
        .message_type = t.general | t.validation | t.performance,
        .pfn_user_callback = debugCallback,
    };
    _ = create(d.instance, &info, null, &d.messenger);
}

fn createSurface(d: *Device, native: Window.Native) Error!void {
    switch (native) {
        .win32 => |w| {
            const f = d.it.createWin32SurfaceKHR orelse return error.NoSurfaceExtension;
            const info: vk.Win32SurfaceCreateInfoKHR = .{ .hinstance = w.hinstance, .hwnd = w.hwnd };
            vk.check(f(d.instance, &info, null, &d.surface)) catch return error.SurfaceCreationFailed;
        },
        .xcb => |w| {
            const f = d.it.createXcbSurfaceKHR orelse return error.NoSurfaceExtension;
            const info: vk.XcbSurfaceCreateInfoKHR = .{ .connection = w.connection, .window = w.window };
            vk.check(f(d.instance, &info, null, &d.surface)) catch return error.SurfaceCreationFailed;
        },
        .xlib => |w| {
            const f = d.it.createXlibSurfaceKHR orelse return error.NoSurfaceExtension;
            const info: vk.XlibSurfaceCreateInfoKHR = .{ .dpy = w.display, .window = w.window };
            vk.check(f(d.instance, &info, null, &d.surface)) catch return error.SurfaceCreationFailed;
        },
        .wayland => |w| {
            const f = d.it.createWaylandSurfaceKHR orelse return error.NoSurfaceExtension;
            const info: vk.WaylandSurfaceCreateInfoKHR = .{ .display = w.display, .surface = w.surface };
            vk.check(f(d.instance, &info, null, &d.surface)) catch return error.SurfaceCreationFailed;
        },
    }
}

/// Everything worth knowing about one physical device, with the surface taken
/// into account when there is one. Shared by the picker and by `fenrir view
/// --probe`, so what the CLI prints is what the picker used.
fn inspect(d: *Device, physical: vk.PhysicalDevice) Error!struct { report: Report, families: ?choose.Families } {
    var props: vk.PhysicalDeviceProperties = undefined;
    d.it.getPhysicalDeviceProperties(physical, &props);

    var mem: vk.PhysicalDeviceMemoryProperties = .{};
    d.it.getPhysicalDeviceMemoryProperties(physical, &mem);

    var vram: u64 = 0;
    var h: u32 = 0;
    while (h < mem.memory_heap_count) : (h += 1) {
        if (mem.memory_heaps[h].flags & vk.MemoryPropertyFlags.device_local != 0) {
            vram = @max(vram, mem.memory_heaps[h].size);
        }
    }

    var n: u32 = 0;
    _ = d.it.enumerateDeviceExtensionProperties(physical, null, &n, null);
    const exts = try d.gpa.alloc(vk.ExtensionProperties, n);
    defer d.gpa.free(exts);
    if (n != 0) _ = d.it.enumerateDeviceExtensionProperties(physical, null, &n, exts.ptr);

    const has_swapchain = hasExtension(exts[0..n], vk.extensions.swapchain);
    const indexing = d.queryDescriptorIndexing(physical, props.api_version, exts[0..n]);

    var families: ?choose.Families = null;
    if (d.surface != vk.null_handle) {
        var fam_count: u32 = 0;
        d.it.getPhysicalDeviceQueueFamilyProperties(physical, &fam_count, null);
        const fams = try d.gpa.alloc(vk.QueueFamilyProperties, fam_count);
        defer d.gpa.free(fams);
        d.it.getPhysicalDeviceQueueFamilyProperties(physical, &fam_count, fams.ptr);

        // One bit per family. Sixty-four is far more than any device has --
        // the most anyone ships is about eight -- and a bitmask keeps
        // `choose.queueFamilies` free of the surface it would otherwise need.
        var support: u64 = 0;
        if (d.it.getPhysicalDeviceSurfaceSupportKHR) |supported| {
            for (fams[0..@min(fam_count, 64)], 0..) |_, i| {
                var ok: u32 = 0;
                _ = supported(physical, @intCast(i), d.surface, &ok);
                if (ok != 0) support |= @as(u64, 1) << @intCast(i);
            }
        }
        families = choose.queueFamilies(fams[0..fam_count], support);
    }

    var report: Report = .{
        .name = props.device_name,
        .name_len = props.name().len,
        .vendor = props.vendor(),
        .kind = props.device_type,
        .api_version = props.api_version,
        .driver_version = props.driver_version,
        .descriptor_indexing = indexing,
        .swapchain = has_swapchain,
        .vram = vram,
        .score = null,
    };
    if (families != null) {
        report.score = choose.scoreDevice(&props, has_swapchain, indexing);
    }
    return .{ .report = report, .families = families };
}

/// Descriptor indexing is core in 1.2 and an extension before it, and the
/// extension being present is not the same as the feature being supported --
/// which is the distinction that turns into a device-lost on somebody's
/// laptop. Both are checked.
fn queryDescriptorIndexing(
    d: *Device,
    physical: vk.PhysicalDevice,
    device_api: u32,
    exts: []const vk.ExtensionProperties,
) bool {
    const core = device_api >= vk.api_1_2;
    if (!core and !hasExtension(exts, vk.extensions.descriptor_indexing)) return false;

    const query = d.it.getPhysicalDeviceFeatures2 orelse return false;
    var indexing: vk.PhysicalDeviceDescriptorIndexingFeatures = .{};
    var features: vk.PhysicalDeviceFeatures2 = .{ .p_next = &indexing };
    query(physical, &features);

    // The three the fragment shader actually needs: an unbounded array, an
    // index the compiler cannot prove uniform, and a set that may have holes
    // in it because not every texture slot is filled every frame.
    return indexing.runtime_descriptor_array != 0 and
        indexing.shader_sampled_image_array_non_uniform_indexing != 0 and
        indexing.descriptor_binding_partially_bound != 0;
}

fn pickPhysical(d: *Device, options: Options) Error!void {
    var n: u32 = 0;
    try vk.check(d.it.enumeratePhysicalDevices(d.instance, &n, null));
    if (n == 0) return error.NoSuitableDevice;

    const devices = try d.gpa.alloc(vk.PhysicalDevice, n);
    defer d.gpa.free(devices);
    try vk.check(d.it.enumeratePhysicalDevices(d.instance, &n, devices.ptr));

    var best: ?vk.PhysicalDevice = null;
    var best_score: u32 = 0;
    var best_families: choose.Families = undefined;
    var best_indexing = false;

    for (devices[0..n]) |candidate| {
        const seen = try d.inspect(candidate);
        const families = seen.families orelse continue;
        var score = seen.report.score orelse continue;

        // A name match outranks everything, because someone who typed
        // `--gpu llvmpipe` meant it.
        if (options.prefer) |want| {
            if (std.mem.indexOf(u8, seen.report.deviceName(), want) != null) score +|= 100_000;
        }

        if (best == null or score > best_score) {
            best = candidate;
            best_score = score;
            best_families = families;
            best_indexing = seen.report.descriptor_indexing;
        }
    }

    d.physical = best orelse return error.NoSuitableDevice;
    d.families = best_families;
    d.descriptor_indexing = best_indexing;
    d.it.getPhysicalDeviceProperties(d.physical, &d.properties);
    d.it.getPhysicalDeviceMemoryProperties(d.physical, &d.memory);
}

fn createLogical(d: *Device) Error!void {
    const priority: [1]f32 = .{1};
    var queues: [2]vk.DeviceQueueCreateInfo = undefined;
    var queue_count: u32 = 1;
    queues[0] = .{
        .queue_family_index = d.families.graphics,
        .queue_count = 1,
        .p_queue_priorities = &priority,
    };
    // Two entries only when the families really differ: listing the same
    // family twice is a validation error, not a duplicate.
    if (!d.families.shared()) {
        queues[1] = .{
            .queue_family_index = d.families.present,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        };
        queue_count = 2;
    }

    var extensions: [2][*:0]const u8 = undefined;
    var extension_count: u32 = 1;
    extensions[0] = vk.extensions.swapchain;
    if (d.descriptor_indexing and d.properties.api_version < vk.api_1_2) {
        extensions[1] = vk.extensions.descriptor_indexing;
        extension_count = 2;
    }

    var indexing: vk.PhysicalDeviceDescriptorIndexingFeatures = .{
        .shader_sampled_image_array_non_uniform_indexing = 1,
        .descriptor_binding_partially_bound = 1,
        .descriptor_binding_variable_descriptor_count = 1,
        .runtime_descriptor_array = 1,
    };
    var features: vk.PhysicalDeviceFeatures2 = .{
        .p_next = if (d.descriptor_indexing) &indexing else null,
    };

    const info: vk.DeviceCreateInfo = .{
        // `pNext` and `pEnabledFeatures` are mutually exclusive: passing both
        // is rejected rather than merged.
        .p_next = if (d.it.getPhysicalDeviceFeatures2 != null) &features else null,
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &queues,
        .enabled_extension_count = extension_count,
        .pp_enabled_extension_names = &extensions,
        .p_enabled_features = if (d.it.getPhysicalDeviceFeatures2 == null) &features.features else null,
    };

    try vk.check(d.it.createDevice(d.physical, &info, null, &d.handle));
    d.dt = try d.it.loadDevice(d.handle);

    d.dt.getDeviceQueue(d.handle, d.families.graphics, 0, &d.graphics_queue);
    d.dt.getDeviceQueue(d.handle, d.families.present, 0, &d.present_queue);
}

// -- use --------------------------------------------------------------------

pub fn name(d: *const Device) []const u8 {
    return d.properties.name();
}

pub fn waitIdle(d: *Device) void {
    _ = d.dt.deviceWaitIdle(d.handle);
}

pub fn surfaceCapabilities(d: *Device) Error!vk.SurfaceCapabilitiesKHR {
    const f = d.it.getPhysicalDeviceSurfaceCapabilitiesKHR orelse return error.NoSurfaceExtension;
    var caps: vk.SurfaceCapabilitiesKHR = .{};
    try vk.check(f(d.physical, d.surface, &caps));
    return caps;
}

pub fn surfaceFormats(d: *Device, gpa: Allocator) Error![]vk.SurfaceFormatKHR {
    const f = d.it.getPhysicalDeviceSurfaceFormatsKHR orelse return error.NoSurfaceExtension;
    var n: u32 = 0;
    _ = f(d.physical, d.surface, &n, null);
    const out = try gpa.alloc(vk.SurfaceFormatKHR, n);
    errdefer gpa.free(out);
    if (n != 0) try vk.check(f(d.physical, d.surface, &n, out.ptr));
    return out[0..n];
}

pub fn surfacePresentModes(d: *Device, gpa: Allocator) Error![]vk.PresentModeKHR {
    const f = d.it.getPhysicalDeviceSurfacePresentModesKHR orelse return error.NoSurfaceExtension;
    var n: u32 = 0;
    _ = f(d.physical, d.surface, &n, null);
    const out = try gpa.alloc(vk.PresentModeKHR, n);
    errdefer gpa.free(out);
    if (n != 0) try vk.check(f(d.physical, d.surface, &n, out.ptr));
    return out[0..n];
}

/// A buffer and the memory under it, allocated together.
///
/// One allocation per buffer is the wrong shape for a real engine -- drivers
/// cap the number of allocations, sometimes at four thousand -- and exactly
/// right here, where the total is one instance buffer, one staging buffer, and
/// one image. A suballocator would be more code than the thing it manages.
pub const Buffer = struct {
    handle: vk.Buffer = vk.null_handle,
    memory: vk.DeviceMemory = vk.null_handle,
    size: u64 = 0,
    /// Non-null for host-visible buffers, which are mapped once at creation
    /// and never unmapped. Mapping per frame is a driver call and a page-table
    /// update to obtain a pointer that was already valid.
    mapped: ?[*]u8 = null,
    /// Whether writes are visible to the device without an explicit flush.
    coherent: bool = true,
    /// Which of the device's memory types it landed in: what
    /// `choose.memoryType` settled for, which is not always what was
    /// preferred, and the only way to find out afterwards which it was.
    memory_type: u32 = 0,

    pub fn slice(b: Buffer) []u8 {
        return (b.mapped orelse return &.{})[0..b.size];
    }
};

pub fn createBuffer(
    d: *Device,
    size: u64,
    usage: u32,
    required: u32,
    preferred: u32,
) Error!Buffer {
    var b: Buffer = .{ .size = size };

    const info: vk.BufferCreateInfo = .{ .size = size, .usage = usage };
    try vk.check(d.dt.createBuffer(d.handle, &info, null, &b.handle));
    errdefer d.dt.destroyBuffer(d.handle, b.handle, null);

    var req: vk.MemoryRequirements = undefined;
    d.dt.getBufferMemoryRequirements(d.handle, b.handle, &req);

    const index = choose.memoryType(&d.memory, req.memory_type_bits, required, preferred) orelse
        return error.FeatureNotPresent;
    b.memory_type = index;

    const alloc: vk.MemoryAllocateInfo = .{
        .allocation_size = req.size,
        .memory_type_index = index,
    };
    try vk.check(d.dt.allocateMemory(d.handle, &alloc, null, &b.memory));
    errdefer d.dt.freeMemory(d.handle, b.memory, null);

    try vk.check(d.dt.bindBufferMemory(d.handle, b.handle, b.memory, 0));

    const flags = d.memory.memory_types[index].property_flags;
    if (flags & vk.MemoryPropertyFlags.host_visible != 0) {
        var ptr: ?*anyopaque = null;
        try vk.check(d.dt.mapMemory(d.handle, b.memory, 0, vk.whole_size, 0, &ptr));
        b.mapped = @ptrCast(ptr);
        b.coherent = flags & vk.MemoryPropertyFlags.host_coherent != 0;
    }
    return b;
}

pub fn destroyBuffer(d: *Device, b: *Buffer) void {
    if (b.handle != vk.null_handle) d.dt.destroyBuffer(d.handle, b.handle, null);
    if (b.memory != vk.null_handle) d.dt.freeMemory(d.handle, b.memory, null);
    b.* = .{};
}

/// Makes a host write visible to the device on a non-coherent heap. A no-op on
/// the coherent memory almost every desktop reports, and not optional on the
/// hardware that does not: without it the GPU reads whatever was in the buffer
/// last frame, which looks like a one-frame lag rather than like a bug.
pub fn flush(d: *Device, b: Buffer, offset: u64, size: u64) void {
    if (b.coherent or b.memory == vk.null_handle) return;
    const atom = 256; // conservative; `nonCoherentAtomSize` is at most this.
    const start = offset - offset % atom;
    var length = size + (offset - start);
    length = (length + atom - 1) / atom * atom;
    const range: vk.MappedMemoryRange = .{
        .memory = b.memory,
        .offset = start,
        .size = @min(length, b.size - start),
    };
    _ = d.dt.flushMappedMemoryRanges(d.handle, 1, @ptrCast(&range));
}

// -- probing ----------------------------------------------------------------

/// Enumerates the devices without creating one, for `fenrir view --probe`.
///
/// Made with no surface, so it works on a machine with no display and reports
/// what a headless build would see. Queue families are not evaluated for the
/// same reason -- presentation support is a property of a surface -- which is
/// why `Report.score` is null here and set during a real pick.
pub fn probe(gpa: Allocator, options: Options) Error![]Report {
    var d: Device = .{ .gpa = gpa, .lib = try .open() };
    defer d.lib.close();

    const available = try d.lib.instanceExtensions(gpa);
    defer gpa.free(available);

    var wanted: std.ArrayList([*:0]const u8) = .empty;
    defer wanted.deinit(gpa);
    if (hasExtension(available, vk.extensions.get_physical_device_properties_2)) {
        try wanted.append(gpa, vk.extensions.get_physical_device_properties_2);
    }

    const loader_version = d.lib.apiVersion();
    const app: vk.ApplicationInfo = .{
        .p_application_name = options.application_name,
        .api_version = if (loader_version >= vk.api_1_2) vk.api_1_2 else vk.api_1_0,
    };
    const info: vk.InstanceCreateInfo = .{
        .p_application_info = &app,
        .enabled_extension_count = @intCast(wanted.items.len),
        .pp_enabled_extension_names = if (wanted.items.len == 0) null else wanted.items.ptr,
    };
    try vk.check(d.lib.global.createInstance(&info, null, &d.instance));
    d.it = try d.lib.loadInstance(d.instance);
    defer d.it.destroyInstance(d.instance, null);

    var n: u32 = 0;
    try vk.check(d.it.enumeratePhysicalDevices(d.instance, &n, null));
    const handles = try gpa.alloc(vk.PhysicalDevice, n);
    defer gpa.free(handles);
    if (n != 0) try vk.check(d.it.enumeratePhysicalDevices(d.instance, &n, handles.ptr));

    const out = try gpa.alloc(Report, n);
    errdefer gpa.free(out);
    for (handles[0..n], 0..) |h, i| out[i] = (try d.inspect(h)).report;
    return out[0..n];
}

/// The loader's own version, without creating anything at all. Null when there
/// is no loader to ask.
pub fn loaderVersion() ?u32 {
    var lib = loader.Library.open() catch return null;
    defer lib.close();
    return lib.apiVersion();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "an extension list is searched by name, not by prefix" {
    var list: [2]vk.ExtensionProperties = undefined;
    list[0] = .{ .extension_name = undefined, .spec_version = 1 };
    list[1] = .{ .extension_name = undefined, .spec_version = 1 };
    @memset(&list[0].extension_name, 0);
    @memset(&list[1].extension_name, 0);
    @memcpy(list[0].extension_name[0..14], "VK_KHR_surface");
    @memcpy(list[1].extension_name[0..16], "VK_KHR_swapchain");

    try testing.expect(hasExtension(&list, "VK_KHR_surface"));
    try testing.expect(hasExtension(&list, "VK_KHR_swapchain"));
    // The trap a prefix match would fall into: `VK_KHR_surface` is a prefix of
    // several real extension names, including `VK_KHR_surface_protected_capabilities`.
    try testing.expect(!hasExtension(&list, "VK_KHR_surface_protected_capabilities"));
    try testing.expect(!hasExtension(&list, "VK_KHR_win32_surface"));
}

test "each windowing system asks for its own surface extension" {
    const win32: Window.Native = .{ .win32 = .{ .hinstance = null, .hwnd = null } };
    try testing.expectEqualStrings("VK_KHR_win32_surface", std.mem.span(platformExtensionZ(win32)));

    const xcb: Window.Native = .{ .xcb = .{ .connection = null, .window = 0 } };
    try testing.expectEqualStrings("VK_KHR_xcb_surface", std.mem.span(platformExtensionZ(xcb)));

    // And the name the instance asks for is the name the window reports, which
    // is the one invariant that cannot be checked without both.
    try testing.expectEqualStrings(
        Window.Native.extensionFor(win32),
        std.mem.span(platformExtensionZ(win32)),
    );
}
