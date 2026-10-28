//! Every decision the device and swapchain make, as functions of their inputs.
//!
//! Vulkan initialisation is mostly not API calls. It is a dozen small
//! judgements -- which format, which present mode, how many images, which
//! memory type, which queue family -- surrounded by the calls that fetch the
//! candidates. The calls need a device. The judgements do not, and every one
//! of them is a place where a wrong answer shows up as a black window, a
//! stutter, or a crash on somebody else's hardware six months later.
//!
//! So they live here, as pure functions over the arrays Vulkan hands back, and
//! they are tested against the awkward cases: a driver that offers no sRGB
//! format at all, a compositor that reports `0xFFFFFFFF` for its extent, a
//! surface with no maximum image count, a device whose only host-visible
//! memory is also device-local. Those cases are real, they are rare, and they
//! are exactly the ones that never come up on the machine the code was written
//! on.

const std = @import("std");

const vk = @import("vk.zig");

/// What a person means by "vsync", which is not what Vulkan calls it.
pub const Vsync = enum {
    /// `FIFO`. Always available, never tears, and the frame rate is the
    /// refresh rate. The right default for a document reader: a page that is
    /// not moving should cost nothing, and the alternatives all burn a core
    /// to render frames nobody sees.
    on,
    /// `MAILBOX` if the driver has it, `IMMEDIATE` if not, `FIFO` if neither.
    /// Lowest latency, highest power draw.
    off,
    /// `FIFO_RELAXED`: vsync, except that a frame which missed its slot is
    /// shown immediately rather than held for the next one. Tears only after a
    /// hitch, which is the one moment tearing is preferable to a doubled
    /// frame.
    adaptive,
};

pub fn presentMode(available: []const vk.PresentModeKHR, want: Vsync) vk.PresentModeKHR {
    const order: []const vk.PresentModeKHR = switch (want) {
        .on => &.{.fifo},
        .off => &.{ .mailbox, .immediate, .fifo },
        .adaptive => &.{ .fifo_relaxed, .fifo },
    };
    for (order) |mode| {
        for (available) |a| if (a == mode) return mode;
    }
    // FIFO is required of every implementation, so this is unreachable in
    // practice and still worth writing: a driver that violates it would
    // otherwise get a mode it never offered.
    return .fifo;
}

pub const FormatChoice = struct {
    format: vk.SurfaceFormatKHR,
    /// False when nothing sRGB was on offer. The shader blends in linear light
    /// and depends on the hardware encoding on write; without it, everything
    /// is written as if it were already encoded and the whole frame comes out
    /// too dark. The renderer prints a warning rather than refusing to start,
    /// because a dark window is more useful than no window when someone is
    /// debugging exactly this.
    srgb: bool,
};

/// Picks the swapchain format.
///
/// `B8G8R8A8_SRGB` first, not for any deep reason: it is what Windows,
/// Android, and every desktop compositor list first, so choosing it avoids a
/// format conversion in the presentation engine on the overwhelming majority
/// of machines. `R8G8B8A8_SRGB` is the same thing with the channels the other
/// way round and costs nothing either.
pub fn surfaceFormat(available: []const vk.SurfaceFormatKHR) FormatChoice {
    // The legacy "the surface has no preferred format" signal: a single entry
    // whose format is UNDEFINED means anything is allowed. Modern drivers do
    // not do this; drivers on machines people still use do.
    if (available.len == 1 and available[0].format == .undefined) {
        return .{
            .format = .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear },
            .srgb = true,
        };
    }

    for ([_]vk.Format{ .b8g8r8a8_srgb, .r8g8b8a8_srgb }) |want| {
        for (available) |a| {
            if (a.format == want and a.color_space == .srgb_nonlinear) {
                return .{ .format = a, .srgb = true };
            }
        }
    }
    for (available) |a| {
        if (a.format.isSrgb()) return .{ .format = a, .srgb = true };
    }
    if (available.len == 0) {
        return .{
            .format = .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear },
            .srgb = false,
        };
    }
    return .{ .format = available[0], .srgb = false };
}

/// How many images to ask the presentation engine for.
///
/// One more than the minimum, so that the application always has an image to
/// draw into while the compositor holds one. Asking for exactly the minimum
/// means every `vkAcquireNextImageKHR` blocks until the compositor is finished
/// with the previous frame, which turns a 2ms frame into a 16ms one and looks
/// exactly like a slow renderer.
///
/// `max_image_count` of zero means no maximum, which is the trap in this
/// function: clamping to it unconditionally asks for zero images.
pub fn imageCount(caps: vk.SurfaceCapabilitiesKHR) u32 {
    var n = caps.min_image_count + 1;
    if (caps.max_image_count != 0 and n > caps.max_image_count) n = caps.max_image_count;
    return n;
}

/// The swapchain size.
///
/// `current_extent` is authoritative when the compositor sets it, and the
/// sentinel `0xFFFFFFFF` means "you choose", which is what X11 and some
/// Wayland compositors say. In that case the window's own idea of its size is
/// used, clamped into the surface's range -- and it must be clamped, because a
/// size outside the range is a validation error and a creation failure, not a
/// negotiation.
pub fn extent(caps: vk.SurfaceCapabilitiesKHR, window: vk.Extent2D) vk.Extent2D {
    const undefined_extent: u32 = 0xffff_ffff;
    if (caps.current_extent.width != undefined_extent and
        caps.current_extent.height != undefined_extent)
    {
        return caps.current_extent;
    }
    return .{
        .width = std.math.clamp(window.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(window.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

/// True when the surface has no area, which happens for a whole minute at a
/// time whenever somebody minimises the window. Creating a swapchain then
/// fails; the frame loop has to skip instead.
pub fn isMinimised(e: vk.Extent2D) bool {
    return e.width == 0 or e.height == 0;
}

/// How the window's alpha is composited with what is behind it.
///
/// `OPAQUE` unless the surface refuses it, which is the case on some Wayland
/// and Android implementations. Picking a translucent mode when the shader
/// writes premultiplied alpha would make the whole window see-through wherever
/// the UI is not opaque, which is most of a page margin.
pub fn compositeAlpha(caps: vk.SurfaceCapabilitiesKHR) u32 {
    const order = [_]u32{
        vk.CompositeAlphaFlagsKHR.@"opaque",
        vk.CompositeAlphaFlagsKHR.inherit,
        vk.CompositeAlphaFlagsKHR.pre_multiplied,
        vk.CompositeAlphaFlagsKHR.post_multiplied,
    };
    for (order) |bit| {
        if (caps.supported_composite_alpha & bit != 0) return bit;
    }
    return vk.CompositeAlphaFlagsKHR.@"opaque";
}

/// A memory type satisfying `required`, preferring one that also has
/// `preferred`.
///
/// The two-tier search is what picks up resizable BAR without asking for it:
/// the instance buffer requires HOST_VISIBLE and prefers DEVICE_LOCAL, so on a
/// machine that exposes a device-local host-visible heap the buffer lands in
/// video memory and the GPU reads it at full speed, and on one that does not
/// it lands in system memory and everything still works.
pub fn memoryType(
    props: *const vk.PhysicalDeviceMemoryProperties,
    type_bits: u32,
    required: u32,
    preferred: u32,
) ?u32 {
    var fallback: ?u32 = null;
    var i: u32 = 0;
    while (i < props.memory_type_count) : (i += 1) {
        if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const flags = props.memory_types[i].property_flags;
        if (flags & required != required) continue;
        if (flags & preferred == preferred) return i;
        if (fallback == null) fallback = i;
    }
    return fallback;
}

pub const Families = struct {
    graphics: u32,
    present: u32,
    /// How many bits of a timestamp written on the graphics queue mean
    /// anything. Zero is a queue with no timestamps at all.
    timestamp_bits: u32 = 0,

    pub fn shared(f: Families) bool {
        return f.graphics == f.present;
    }
};

/// Finds a graphics queue and a presentation queue, preferring one family that
/// does both.
///
/// It is nearly always the same family, and when it is, the swapchain can be
/// EXCLUSIVE, which is faster and is the only mode some drivers optimise. When
/// it is not -- which happens on a few AMD and mobile configurations -- the
/// swapchain has to be CONCURRENT and list both families, and forgetting that
/// is a validation error on hardware the author does not own.
///
/// `present_support` is a bitmask indexed by family, because the query for it
/// needs a surface and this function does not.
pub fn queueFamilies(
    families: []const vk.QueueFamilyProperties,
    present_support: u64,
) ?Families {
    var graphics: ?u32 = null;
    var present: ?u32 = null;

    for (families, 0..) |f, i| {
        const index: u32 = @intCast(i);
        if (f.queue_count == 0) continue;
        const does_graphics = f.queue_flags & vk.QueueFlags.graphics != 0;
        const does_present = present_support & (@as(u64, 1) << @intCast(i)) != 0;

        if (does_graphics and does_present) {
            return .{ .graphics = index, .present = index, .timestamp_bits = f.timestamp_valid_bits };
        }
        if (does_graphics and graphics == null) graphics = index;
        if (does_present and present == null) present = index;
    }

    const g = graphics orelse return null;
    return .{
        .graphics = g,
        .present = present orelse return null,
        .timestamp_bits = families[g].timestamp_valid_bits,
    };
}

/// A timestamp difference in milliseconds, or null from a queue that keeps no
/// timestamps.
///
/// Only the low `valid_bits` of a timestamp are meaningful. Masking the
/// difference, rather than the two values, also gets a counter that wrapped
/// between them right, once.
pub fn ticksToMs(begin: u64, end: u64, period_ns: f32, valid_bits: u32) ?f64 {
    if (valid_bits == 0 or !(period_ns > 0)) return null;
    const mask: u64 = if (valid_bits >= 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(valid_bits)) - 1;
    const ticks = (end -% begin) & mask;
    return @as(f64, @floatFromInt(ticks)) * period_ns / 1_000_000.0;
}

/// How much this device is wanted, higher being better. Only compared against
/// other candidates, so the absolute numbers mean nothing.
///
/// Discrete over integrated is the usual ordering and is right for a renderer
/// that will be pushing page images around. `descriptor_indexing` is worth
/// more than the gap between device classes, because without it every frame
/// splits into a draw call per texture run -- eighteen of them for the demo
/// interface, and one with it.
pub fn scoreDevice(
    props: *const vk.PhysicalDeviceProperties,
    has_swapchain: bool,
    has_descriptor_indexing: bool,
) ?u32 {
    if (!has_swapchain) return null;

    var score: u32 = switch (props.device_type) {
        .discrete_gpu => 4000,
        .integrated_gpu => 3000,
        .virtual_gpu => 2000,
        .cpu => 500,
        else => 1000,
    };
    if (has_descriptor_indexing) score += 5000;
    // A tie-break, not a preference: between two devices of the same class the
    // newer API is the better bet, and the term is small enough that it can
    // never outweigh the class.
    score += vk.versionMinor(props.api_version);
    return score;
}

/// Rounds a buffer size up so that a growing instance buffer reallocates a
/// logarithmic number of times rather than once per frame.
///
/// Doubling, with a floor: the first frame of a UI has a few hundred
/// instances, a page of text has a few thousand, and a document zoomed out to
/// a grid of thumbnails has tens of thousands. Growing by exactly what is
/// needed would reallocate -- and stall, because the old buffer may still be
/// in flight -- on almost every frame during a zoom.
pub fn bufferCapacity(current: u64, needed: u64, minimum: u64) u64 {
    var n = @max(current, minimum);
    while (n < needed) n *= 2;
    return n;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn fmt(f: vk.Format) vk.SurfaceFormatKHR {
    return .{ .format = f, .color_space = .srgb_nonlinear };
}

test "the swapchain format prefers BGRA sRGB, then RGBA sRGB, then any sRGB" {
    {
        const avail = [_]vk.SurfaceFormatKHR{ fmt(.r8g8b8a8_unorm), fmt(.b8g8r8a8_srgb), fmt(.r8g8b8a8_srgb) };
        const c = surfaceFormat(&avail);
        try testing.expectEqual(vk.Format.b8g8r8a8_srgb, c.format.format);
        try testing.expect(c.srgb);
    }
    {
        const avail = [_]vk.SurfaceFormatKHR{ fmt(.b8g8r8a8_unorm), fmt(.r8g8b8a8_srgb) };
        const c = surfaceFormat(&avail);
        try testing.expectEqual(vk.Format.r8g8b8a8_srgb, c.format.format);
        try testing.expect(c.srgb);
    }
}

test "a driver offering nothing sRGB gets a format and a warning flag" {
    // Rare, and it does happen -- some headless and virtualised drivers list
    // only UNORM. The renderer still starts; `srgb = false` is what tells it
    // to say why the frame looks wrong.
    const avail = [_]vk.SurfaceFormatKHR{ fmt(.b8g8r8a8_unorm), fmt(.a2b10g10r10_unorm_pack32) };
    const c = surfaceFormat(&avail);
    try testing.expectEqual(vk.Format.b8g8r8a8_unorm, c.format.format);
    try testing.expect(!c.srgb);
}

test "the legacy no-preference signal means anything is allowed" {
    const avail = [_]vk.SurfaceFormatKHR{fmt(.undefined)};
    const c = surfaceFormat(&avail);
    try testing.expectEqual(vk.Format.b8g8r8a8_srgb, c.format.format);
    try testing.expect(c.srgb);
}

test "present modes fall back in the order the intent implies" {
    const all = [_]vk.PresentModeKHR{ .immediate, .mailbox, .fifo, .fifo_relaxed };
    const only_fifo = [_]vk.PresentModeKHR{.fifo};

    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(&all, .on));
    try testing.expectEqual(vk.PresentModeKHR.mailbox, presentMode(&all, .off));
    try testing.expectEqual(vk.PresentModeKHR.fifo_relaxed, presentMode(&all, .adaptive));

    // Everything degrades to FIFO, which every implementation must support.
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(&only_fifo, .off));
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(&only_fifo, .adaptive));
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(&.{}, .off));

    const no_mailbox = [_]vk.PresentModeKHR{ .immediate, .fifo };
    try testing.expectEqual(vk.PresentModeKHR.immediate, presentMode(&no_mailbox, .off));
}

test "image count is one above the minimum, and zero maximum means no maximum" {
    try testing.expectEqual(@as(u32, 3), imageCount(.{ .min_image_count = 2, .max_image_count = 8 }));
    try testing.expectEqual(@as(u32, 2), imageCount(.{ .min_image_count = 2, .max_image_count = 2 }));
    // The trap: clamping to a zero maximum would ask for zero images.
    try testing.expectEqual(@as(u32, 4), imageCount(.{ .min_image_count = 3, .max_image_count = 0 }));
}

test "the extent follows the compositor unless it defers to us" {
    const fixed: vk.SurfaceCapabilitiesKHR = .{
        .current_extent = .{ .width = 800, .height = 600 },
        .min_image_extent = .{ .width = 1, .height = 1 },
        .max_image_extent = .{ .width = 4096, .height = 4096 },
    };
    try testing.expectEqual(vk.Extent2D{ .width = 800, .height = 600 }, extent(fixed, .{ .width = 1, .height = 1 }));

    const deferred: vk.SurfaceCapabilitiesKHR = .{
        .current_extent = .{ .width = 0xffff_ffff, .height = 0xffff_ffff },
        .min_image_extent = .{ .width = 64, .height = 64 },
        .max_image_extent = .{ .width = 1024, .height = 1024 },
    };
    try testing.expectEqual(
        vk.Extent2D{ .width = 640, .height = 480 },
        extent(deferred, .{ .width = 640, .height = 480 }),
    );
    // Outside the range is a creation failure, not a negotiation.
    try testing.expectEqual(
        vk.Extent2D{ .width = 1024, .height = 64 },
        extent(deferred, .{ .width = 5000, .height = 10 }),
    );
}

test "a minimised window is recognised rather than asked to make a swapchain" {
    try testing.expect(isMinimised(.{ .width = 0, .height = 600 }));
    try testing.expect(isMinimised(.{ .width = 800, .height = 0 }));
    try testing.expect(!isMinimised(.{ .width = 1, .height = 1 }));
}

test "composite alpha is opaque unless the surface will not have it" {
    try testing.expectEqual(
        vk.CompositeAlphaFlagsKHR.@"opaque",
        compositeAlpha(.{ .supported_composite_alpha = 0xf }),
    );
    try testing.expectEqual(
        vk.CompositeAlphaFlagsKHR.inherit,
        compositeAlpha(.{ .supported_composite_alpha = vk.CompositeAlphaFlagsKHR.inherit }),
    );
}

test "memory selection takes the preferred bits when they are on offer" {
    const m = vk.MemoryPropertyFlags;
    var props: vk.PhysicalDeviceMemoryProperties = .{};
    props.memory_type_count = 3;
    props.memory_types[0] = .{ .property_flags = m.device_local, .heap_index = 0 };
    props.memory_types[1] = .{ .property_flags = m.host_visible | m.host_coherent, .heap_index = 1 };
    props.memory_types[2] = .{
        .property_flags = m.device_local | m.host_visible | m.host_coherent,
        .heap_index = 0,
    };

    // Resizable BAR present: the upload buffer lands in video memory.
    try testing.expectEqual(
        @as(?u32, 2),
        memoryType(&props, 0b111, m.host_visible | m.host_coherent, m.device_local),
    );
    // Only the plain host-visible type is allowed by the requirements mask.
    try testing.expectEqual(
        @as(?u32, 1),
        memoryType(&props, 0b010, m.host_visible, m.device_local),
    );
    // Nothing satisfies the requirement.
    try testing.expectEqual(
        @as(?u32, null),
        memoryType(&props, 0b001, m.host_visible, 0),
    );
}

test "one family that does both beats two that each do one" {
    const g = vk.QueueFlags.graphics;
    const c = vk.QueueFlags.compute;

    const families = [_]vk.QueueFamilyProperties{
        .{ .queue_flags = c, .queue_count = 8, .timestamp_valid_bits = 0, .min_image_transfer_granularity = .{} },
        .{ .queue_flags = g, .queue_count = 1, .timestamp_valid_bits = 64, .min_image_transfer_granularity = .{} },
    };
    // Family 1 does graphics and present.
    const both = queueFamilies(&families, 0b10).?;
    try testing.expectEqual(@as(u32, 1), both.graphics);
    try testing.expect(both.shared());
    try testing.expectEqual(@as(u32, 64), both.timestamp_bits);

    // Present only on the family that cannot draw: legal, and the swapchain
    // then has to be CONCURRENT. The timestamps are the drawing family's.
    const split = queueFamilies(&families, 0b01).?;
    try testing.expectEqual(@as(u32, 1), split.graphics);
    try testing.expectEqual(@as(u32, 0), split.present);
    try testing.expect(!split.shared());
    try testing.expectEqual(@as(u32, 64), split.timestamp_bits);

    // Nothing can present: not a usable device.
    try testing.expectEqual(@as(?Families, null), queueFamilies(&families, 0));
}

test "a family with no queues is not a family" {
    const families = [_]vk.QueueFamilyProperties{
        .{ .queue_flags = vk.QueueFlags.graphics, .queue_count = 0, .timestamp_valid_bits = 0, .min_image_transfer_granularity = .{} },
    };
    try testing.expectEqual(@as(?Families, null), queueFamilies(&families, 0b1));
}

test "descriptor indexing outweighs the gap between device classes" {
    var integrated: vk.PhysicalDeviceProperties = undefined;
    integrated.device_type = .integrated_gpu;
    integrated.api_version = vk.api_1_3;

    var discrete: vk.PhysicalDeviceProperties = undefined;
    discrete.device_type = .discrete_gpu;
    discrete.api_version = vk.api_1_0;

    // The reason: without it every frame is one draw call per texture run.
    const modern_integrated = scoreDevice(&integrated, true, true).?;
    const old_discrete = scoreDevice(&discrete, true, false).?;
    try testing.expect(modern_integrated > old_discrete);

    // With the feature on both, the discrete card wins.
    try testing.expect(scoreDevice(&discrete, true, true).? > scoreDevice(&integrated, true, true).?);

    // No swapchain extension is not a candidate at all.
    try testing.expectEqual(@as(?u32, null), scoreDevice(&discrete, false, true));
}

test "buffer capacity doubles from a floor rather than tracking the frame" {
    try testing.expectEqual(@as(u64, 4096), bufferCapacity(0, 1, 4096));
    try testing.expectEqual(@as(u64, 4096), bufferCapacity(4096, 4096, 4096));
    try testing.expectEqual(@as(u64, 8192), bufferCapacity(4096, 4097, 4096));
    // A zoom that multiplies the instance count by fifty reallocates six
    // times, not fifty.
    try testing.expectEqual(@as(u64, 262144), bufferCapacity(4096, 200000, 4096));
}

test "a timestamp difference counts only the valid bits, and survives a wrap" {
    // A queue with no timestamps, and a device that reports no period.
    try testing.expectEqual(@as(?f64, null), ticksToMs(0, 100, 1, 0));
    try testing.expectEqual(@as(?f64, null), ticksToMs(0, 100, 0, 64));

    // A nanosecond a tick, a million ticks.
    try testing.expectApproxEqAbs(@as(f64, 1), ticksToMs(5, 1_000_005, 1, 64).?, 1e-12);
    // A period that is not a whole number of nanoseconds, as Intel's is not.
    try testing.expectApproxEqAbs(@as(f64, 1), ticksToMs(0, 12_000, 83.333336, 64).?, 1e-4);

    // A 36-bit counter that wrapped between the two: fifteen ticks, not
    // most of two to the sixty-fourth.
    const top = (@as(u64, 1) << 36) - 10;
    try testing.expectApproxEqAbs(@as(f64, 15e-6), ticksToMs(top, 5, 1, 36).?, 1e-12);
    // Bits above the valid ones do not count.
    const high: u64 = 0xf000_0000_0000_0000;
    try testing.expectApproxEqAbs(@as(f64, 1e-6), ticksToMs(high | 3, 0x0f00_0000_0000_0000 | 4, 1, 36).?, 1e-12);
}
