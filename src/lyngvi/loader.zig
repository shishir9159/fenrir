//! Finding Vulkan at run time, and the three dispatch tables that follow.
//!
//! Nothing here is linked. The loader library is opened by name with
//! `std.DynLib`, one symbol is looked up in it, and every other entry point in
//! the program comes out of that one. The consequences are worth stating,
//! because they are the reason it is done this way:
//!
//! * The build needs no Vulkan SDK, no `vulkan-1.lib`, and no pkg-config.
//! * A machine with no driver gets `error.NoVulkanLoader` and a sentence
//!   saying so, instead of a link error at build time on a machine that was
//!   never going to run the program anyway.
//! * `fenrir info` on a headless server still works, because the loader is
//!   opened when a window is asked for and not before.
//!
//! ## Three tables, not one
//!
//! Vulkan has three levels of dispatch and they are not interchangeable.
//!
//! *Global* functions exist before an instance does, and are fetched with a
//! null instance. *Instance* functions are fetched from the instance and are
//! valid for every device under it. *Device* functions can be fetched either
//! from the instance -- where the loader inserts a trampoline that reads the
//! dispatch table out of the handle on every single call -- or from the device
//! with `vkGetDeviceProcAddr`, where the pointer goes straight into the
//! driver.
//!
//! For `vkCmdDraw` and friends, called once per instance batch per frame, that
//! trampoline is the difference between a call and a dependent load followed
//! by a call. Which is why the device table below is filled with
//! `vkGetDeviceProcAddr` and asserts that it was.
//!
//! ## How the tables are filled
//!
//! Each table is a struct whose field names *are* the function names, minus
//! the `vk` and with the first letter lowered, and whose field types are the
//! matching `Pfn` from `vk.zig`. Filling one is then a `inline for` over its
//! fields. A field of optional type is allowed to be missing -- that is how an
//! extension entry point is declared -- and a field of non-optional type that
//! comes back null is a hard error naming the symbol.
//!
//! The alternative is a hundred lines of `t.createBuffer = @ptrCast(get(dev,
//! "vkCreateBuffer") orelse return error.X);`, which is the same thing written
//! out by hand, with one chance per line to paste the wrong name into the
//! wrong field. That mistake is invisible: the program calls a real Vulkan
//! function with the wrong arguments.

const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vk.zig");

pub const Error = error{
    NoVulkanLoader,
    MissingEntryPoint,
} || vk.Error;

/// The name of the loader library on each platform, in the order they should
/// be tried. The `.1` soname on Linux is deliberate: the unversioned symlink
/// belongs to the SDK's development package, which a user running a binary
/// will not have installed.
pub const library_names: []const [:0]const u8 = switch (builtin.os.tag) {
    .windows => &.{"vulkan-1.dll"},
    .macos, .ios => &.{ "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib" },
    else => &.{ "libvulkan.so.1", "libvulkan.so" },
};

/// `createInstance` -> `"vkCreateInstance"`, at comptime.
fn symbolName(comptime field: []const u8) [:0]const u8 {
    // The name lives in a container-level constant rather than in a local,
    // because a pointer to a local cannot outlive the comptime call that made
    // it, and this pointer has to reach `vkGetInstanceProcAddr` at run time.
    const holder = struct {
        const value: [field.len + 2:0]u8 = blk: {
            var buf: [field.len + 2:0]u8 = undefined;
            buf[0] = 'v';
            buf[1] = 'k';
            buf[2] = std.ascii.toUpper(field[0]);
            for (field[1..], 3..) |c, i| buf[i] = c;
            buf[buf.len] = 0;
            break :blk buf;
        };
    };
    return &holder.value;
}

/// Looks a symbol up in one instance's namespace. A null handle is the global
/// namespace, which is how the three functions that exist before an instance
/// does are found.
const FromInstance = struct {
    f: vk.PfnGetInstanceProcAddr,
    handle: vk.Instance,

    fn get(self: FromInstance, name: [:0]const u8) ?vk.PfnVoidFunction {
        return self.f(self.handle, name.ptr);
    }
};

/// Looks a symbol up in one device's namespace, which is the whole point of
/// having a third table: the pointer that comes back goes straight into the
/// driver instead of through the loader's dispatch trampoline.
const FromDevice = struct {
    f: vk.PfnGetDeviceProcAddr,
    handle: vk.Device,

    fn get(self: FromDevice, name: [:0]const u8) ?vk.PfnVoidFunction {
        return self.f(self.handle, name.ptr);
    }
};

/// Fills `T` from `source`, which is either of the two lookups above.
fn fill(comptime T: type, missing: *?[]const u8, source: anytype) T {
    var table: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const name = comptime symbolName(f.name);
        const found = source.get(name);
        const optional = @typeInfo(f.type) == .optional;
        if (found) |p| {
            @field(table, f.name) = @ptrCast(p);
        } else if (optional) {
            @field(table, f.name) = null;
        } else {
            // Recorded rather than returned, so the caller can name the symbol
            // in its error message. A missing core entry point means a broken
            // or ancient loader, and "MissingEntryPoint" on its own sends
            // nobody anywhere.
            if (missing.* == null) missing.* = name;
            @field(table, f.name) = undefined;
        }
    }
    return table;
}

// -- global -----------------------------------------------------------------

pub const Global = struct {
    createInstance: vk.PfnCreateInstance,
    enumerateInstanceExtensionProperties: vk.PfnEnumerateInstanceExtensionProperties,
    enumerateInstanceLayerProperties: vk.PfnEnumerateInstanceLayerProperties,
    /// 1.1 and later. A 1.0 loader has no way to report its version other than
    /// by not having this, which is exactly what its absence is read as.
    enumerateInstanceVersion: ?vk.PfnEnumerateInstanceVersion,
};

/// Opening a shared library by name.
///
/// `std.DynLib` covers the POSIX platforms and is a compile error on Windows
/// in this version of the standard library, so the Windows half is three
/// declarations from `kernel32`. That is not a workaround for a gap so much as
/// the shape this always has: `dlopen` and `LoadLibrary` have the same three
/// operations and no common spelling.
const Shared = switch (builtin.os.tag) {
    .windows => struct {
        handle: ?*anyopaque,

        extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

        fn open(path: [:0]const u8) ?Shared {
            return .{ .handle = LoadLibraryA(path.ptr) orelse return null };
        }

        fn close(s: *Shared) void {
            _ = FreeLibrary(s.handle);
            s.handle = null;
        }

        fn lookup(s: *Shared, comptime T: type, name: [:0]const u8) ?T {
            return @ptrCast(GetProcAddress(s.handle, name.ptr) orelse return null);
        }
    },
    else => struct {
        lib: std.DynLib,

        fn open(path: [:0]const u8) ?Shared {
            return .{ .lib = std.DynLib.openZ(path.ptr) catch return null };
        }

        fn close(s: *Shared) void {
            s.lib.close();
        }

        fn lookup(s: *Shared, comptime T: type, name: [:0]const u8) ?T {
            return s.lib.lookup(T, name);
        }
    },
};

pub const Library = struct {
    lib: Shared,
    getInstanceProcAddr: vk.PfnGetInstanceProcAddr,
    global: Global,
    /// The symbol that was missing, if one was. Kept for the message.
    missing: ?[]const u8 = null,

    pub fn open() Error!Library {
        var lib = openAny() orelse return error.NoVulkanLoader;
        errdefer lib.close();

        const gipa = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
            return error.NoVulkanLoader;

        var missing: ?[]const u8 = null;
        const global = fill(Global, &missing, FromInstance{ .f = gipa, .handle = null });
        if (missing != null) return error.MissingEntryPoint;

        return .{ .lib = lib, .getInstanceProcAddr = gipa, .global = global };
    }

    fn openAny() ?Shared {
        inline for (library_names) |name| {
            if (Shared.open(name)) |lib| return lib;
        }
        return null;
    }

    pub fn close(l: *Library) void {
        l.lib.close();
        l.* = undefined;
    }

    /// What the loader itself supports, which caps what any instance can ask
    /// for. A 1.0 loader rejects an `apiVersion` above 1.0 outright rather
    /// than clamping it, so this has to be asked before the instance is made.
    pub fn apiVersion(l: *const Library) u32 {
        const f = l.global.enumerateInstanceVersion orelse return vk.api_1_0;
        var v: u32 = vk.api_1_0;
        if (!f(&v).isSuccess()) return vk.api_1_0;
        return v;
    }

    pub fn instanceExtensions(
        l: *const Library,
        gpa: std.mem.Allocator,
    ) ![]vk.ExtensionProperties {
        var n: u32 = 0;
        _ = l.global.enumerateInstanceExtensionProperties(null, &n, null);
        const out = try gpa.alloc(vk.ExtensionProperties, n);
        errdefer gpa.free(out);
        if (n != 0) try vk.check(l.global.enumerateInstanceExtensionProperties(null, &n, out.ptr));
        return out[0..n];
    }

    pub fn instanceLayers(
        l: *const Library,
        gpa: std.mem.Allocator,
    ) ![]vk.LayerProperties {
        var n: u32 = 0;
        _ = l.global.enumerateInstanceLayerProperties(&n, null);
        const out = try gpa.alloc(vk.LayerProperties, n);
        errdefer gpa.free(out);
        if (n != 0) try vk.check(l.global.enumerateInstanceLayerProperties(&n, out.ptr));
        return out[0..n];
    }

    pub fn loadInstance(l: *const Library, instance: vk.Instance) Error!InstanceTable {
        var missing: ?[]const u8 = null;
        const t = fill(InstanceTable, &missing, FromInstance{
            .f = l.getInstanceProcAddr,
            .handle = instance,
        });
        if (missing != null) return error.MissingEntryPoint;
        return t;
    }
};

// -- instance ---------------------------------------------------------------

pub const InstanceTable = struct {
    destroyInstance: vk.PfnDestroyInstance,
    enumeratePhysicalDevices: vk.PfnEnumeratePhysicalDevices,
    getPhysicalDeviceProperties: vk.PfnGetPhysicalDeviceProperties,
    getPhysicalDeviceMemoryProperties: vk.PfnGetPhysicalDeviceMemoryProperties,
    getPhysicalDeviceQueueFamilyProperties: vk.PfnGetPhysicalDeviceQueueFamilyProperties,
    enumerateDeviceExtensionProperties: vk.PfnEnumerateDeviceExtensionProperties,
    createDevice: vk.PfnCreateDevice,
    getDeviceProcAddr: vk.PfnGetDeviceProcAddr,

    /// 1.1 core. On a 1.0 instance the descriptor-indexing feature query is
    /// simply unavailable, and the renderer falls back to one texture per
    /// draw call without asking.
    getPhysicalDeviceFeatures2: ?vk.PfnGetPhysicalDeviceFeatures2,

    // VK_KHR_surface, and optional because it is an extension: an instance
    // created without it -- which is what `fenrir view --probe` does, so that
    // it works on a machine with no display -- has none of these, and a table
    // that insisted on them would turn "no window wanted" into a hard failure
    // to enumerate anything at all.
    destroySurfaceKHR: ?vk.PfnDestroySurfaceKHR,
    getPhysicalDeviceSurfaceSupportKHR: ?vk.PfnGetPhysicalDeviceSurfaceSupportKHR,
    getPhysicalDeviceSurfaceCapabilitiesKHR: ?vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR,
    getPhysicalDeviceSurfaceFormatsKHR: ?vk.PfnGetPhysicalDeviceSurfaceFormatsKHR,
    getPhysicalDeviceSurfacePresentModesKHR: ?vk.PfnGetPhysicalDeviceSurfacePresentModesKHR,

    // One per windowing system, and at most one of them is ever non-null.
    createWin32SurfaceKHR: ?vk.PfnCreateWin32SurfaceKHR,
    createXcbSurfaceKHR: ?vk.PfnCreateXcbSurfaceKHR,
    createXlibSurfaceKHR: ?vk.PfnCreateXlibSurfaceKHR,
    createWaylandSurfaceKHR: ?vk.PfnCreateWaylandSurfaceKHR,

    createDebugUtilsMessengerEXT: ?vk.PfnCreateDebugUtilsMessengerEXT,
    destroyDebugUtilsMessengerEXT: ?vk.PfnDestroyDebugUtilsMessengerEXT,

    pub fn loadDevice(t: *const InstanceTable, device: vk.Device) Error!DeviceTable {
        var missing: ?[]const u8 = null;
        const out = fill(DeviceTable, &missing, FromDevice{
            .f = t.getDeviceProcAddr,
            .handle = device,
        });
        if (missing != null) return error.MissingEntryPoint;
        return out;
    }
};

// -- device -----------------------------------------------------------------

pub const DeviceTable = struct {
    destroyDevice: vk.PfnDestroyDevice,
    getDeviceQueue: vk.PfnGetDeviceQueue,
    deviceWaitIdle: vk.PfnDeviceWaitIdle,
    queueSubmit: vk.PfnQueueSubmit,
    queueWaitIdle: vk.PfnQueueWaitIdle,
    queuePresentKHR: vk.PfnQueuePresentKHR,

    createSwapchainKHR: vk.PfnCreateSwapchainKHR,
    destroySwapchainKHR: vk.PfnDestroySwapchainKHR,
    getSwapchainImagesKHR: vk.PfnGetSwapchainImagesKHR,
    acquireNextImageKHR: vk.PfnAcquireNextImageKHR,

    createImage: vk.PfnCreateImage,
    destroyImage: vk.PfnDestroyImage,
    createImageView: vk.PfnCreateImageView,
    destroyImageView: vk.PfnDestroyImageView,
    getImageMemoryRequirements: vk.PfnGetImageMemoryRequirements,
    bindImageMemory: vk.PfnBindImageMemory,
    createSampler: vk.PfnCreateSampler,
    destroySampler: vk.PfnDestroySampler,

    createBuffer: vk.PfnCreateBuffer,
    destroyBuffer: vk.PfnDestroyBuffer,
    getBufferMemoryRequirements: vk.PfnGetBufferMemoryRequirements,
    bindBufferMemory: vk.PfnBindBufferMemory,
    allocateMemory: vk.PfnAllocateMemory,
    freeMemory: vk.PfnFreeMemory,
    mapMemory: vk.PfnMapMemory,
    unmapMemory: vk.PfnUnmapMemory,
    flushMappedMemoryRanges: vk.PfnFlushMappedMemoryRanges,

    createShaderModule: vk.PfnCreateShaderModule,
    destroyShaderModule: vk.PfnDestroyShaderModule,
    createPipelineLayout: vk.PfnCreatePipelineLayout,
    destroyPipelineLayout: vk.PfnDestroyPipelineLayout,
    createGraphicsPipelines: vk.PfnCreateGraphicsPipelines,
    destroyPipeline: vk.PfnDestroyPipeline,
    createRenderPass: vk.PfnCreateRenderPass,
    destroyRenderPass: vk.PfnDestroyRenderPass,
    createFramebuffer: vk.PfnCreateFramebuffer,
    destroyFramebuffer: vk.PfnDestroyFramebuffer,

    createDescriptorSetLayout: vk.PfnCreateDescriptorSetLayout,
    destroyDescriptorSetLayout: vk.PfnDestroyDescriptorSetLayout,
    createDescriptorPool: vk.PfnCreateDescriptorPool,
    destroyDescriptorPool: vk.PfnDestroyDescriptorPool,
    allocateDescriptorSets: vk.PfnAllocateDescriptorSets,
    updateDescriptorSets: vk.PfnUpdateDescriptorSets,

    createCommandPool: vk.PfnCreateCommandPool,
    destroyCommandPool: vk.PfnDestroyCommandPool,
    resetCommandPool: vk.PfnResetCommandPool,
    allocateCommandBuffers: vk.PfnAllocateCommandBuffers,
    freeCommandBuffers: vk.PfnFreeCommandBuffers,
    beginCommandBuffer: vk.PfnBeginCommandBuffer,
    endCommandBuffer: vk.PfnEndCommandBuffer,

    createFence: vk.PfnCreateFence,
    destroyFence: vk.PfnDestroyFence,
    waitForFences: vk.PfnWaitForFences,
    resetFences: vk.PfnResetFences,
    createSemaphore: vk.PfnCreateSemaphore,
    destroySemaphore: vk.PfnDestroySemaphore,

    cmdBeginRenderPass: vk.PfnCmdBeginRenderPass,
    cmdEndRenderPass: vk.PfnCmdEndRenderPass,
    cmdBindPipeline: vk.PfnCmdBindPipeline,
    cmdBindDescriptorSets: vk.PfnCmdBindDescriptorSets,
    cmdPushConstants: vk.PfnCmdPushConstants,
    cmdSetViewport: vk.PfnCmdSetViewport,
    cmdSetScissor: vk.PfnCmdSetScissor,
    cmdDraw: vk.PfnCmdDraw,
    cmdCopyBuffer: vk.PfnCmdCopyBuffer,
    cmdCopyBufferToImage: vk.PfnCmdCopyBufferToImage,
    cmdCopyImageToBuffer: vk.PfnCmdCopyImageToBuffer,
    cmdPipelineBarrier: vk.PfnCmdPipelineBarrier,
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a field name becomes the symbol the loader knows" {
    try testing.expectEqualStrings("vkCreateInstance", symbolName("createInstance"));
    try testing.expectEqualStrings("vkCmdDraw", symbolName("cmdDraw"));
    // The suffix is part of the name and must survive untouched: lowering the
    // whole thing and re-capitalising would produce `vkCreateSwapchainKhr`,
    // which no loader has ever exported.
    try testing.expectEqualStrings("vkCreateSwapchainKHR", symbolName("createSwapchainKHR"));
    try testing.expectEqualStrings(
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        symbolName("getPhysicalDeviceSurfaceCapabilitiesKHR"),
    );
}

test "every entry in every table is a function pointer of the matching kind" {
    // Guards against a field declared with the wrong `Pfn` -- a mistake that
    // compiles, links, and calls a real Vulkan function with the wrong
    // arguments. Checking the shape is all that can be done from here; the
    // names are checked by the test above and by the fact that a wrong name
    // returns null and is reported.
    inline for (.{ Global, InstanceTable, DeviceTable }) |T| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            const inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            const info = @typeInfo(inner);
            try testing.expect(info == .pointer);
            try testing.expect(@typeInfo(info.pointer.child) == .@"fn");
            try testing.expectEqual(std.builtin.CallingConvention.c, @typeInfo(info.pointer.child).@"fn".calling_convention);
        }
    }
}

test "the tables cover the calls a frame makes" {
    // A cheap completeness check on the hot path: if one of these is dropped
    // in a refactor the renderer stops compiling, but it stops compiling in
    // Renderer.zig with a confusing message about a missing field, and this
    // says what actually happened.
    inline for (.{
        "cmdDraw",           "cmdBindPipeline",   "cmdBindDescriptorSets",
        "cmdPushConstants",  "cmdBeginRenderPass", "cmdEndRenderPass",
        "acquireNextImageKHR", "queueSubmit",     "queuePresentKHR",
        "waitForFences",     "resetFences",
    }) |name| {
        try testing.expect(@hasField(DeviceTable, name));
    }
}

test "the loader library is named the way a running system names it" {
    // The versioned soname, not the SDK's development symlink: a user with a
    // driver and no SDK has libvulkan.so.1 and nothing else.
    try testing.expect(library_names.len >= 1);
    switch (builtin.os.tag) {
        .windows => try testing.expectEqualStrings("vulkan-1.dll", library_names[0]),
        .macos, .ios => try testing.expect(std.mem.startsWith(u8, library_names[0], "libvulkan")),
        else => try testing.expectEqualStrings("libvulkan.so.1", library_names[0]),
    }
}
