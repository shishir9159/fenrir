//! The swapchain, its images, and the render pass they are attached to.
//!
//! Separate from `Device` because this is the part that is thrown away and
//! rebuilt: every resize, every move between monitors of different densities,
//! and every time a compositor decides the surface it gave out is stale. A
//! program that keeps these in the same object as the instance ends up either
//! destroying too much on a resize or leaking the difference.
//!
//! ## Two semaphores, counted differently, which is not an accident
//!
//! The image-available semaphore belongs to the *frame*: there are as many as
//! there are frames in flight, and `Renderer` owns them.
//!
//! The render-finished semaphore belongs to the *image*, and they are here.
//! This is the mistake nearly every first Vulkan renderer makes, including the
//! one the official tutorial made for years: with a render-finished semaphore
//! per frame in flight, two frames can be presenting different images while
//! signalling the same semaphore, and the presentation engine is entitled to
//! wait on a signal that has already been consumed. It works on the machine it
//! was written on and produces a hang or a validation error on somebody
//! else's. There must be one per swapchain image, because the wait belongs to
//! the presentation of that image.
//!
//! `images_in_flight` is the third piece of the same problem: the acquire can
//! return an image that a frame two submissions ago is still writing to, and
//! the fence of that frame is what has to be waited on before it is reused.
//!
//! ## Why a render pass and not dynamic rendering
//!
//! Dynamic rendering is nicer and is core in 1.3. This renderer requires 1.2
//! for descriptor indexing, and 1.3 would exclude a good deal of working
//! hardware for a saving of about forty lines. One subpass, one attachment,
//! `LOAD_OP_CLEAR`, and a single dependency that makes the layout transition
//! wait for the acquire.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Device = @import("Device.zig");
const choose = @import("choose.zig");
const vk = @import("vk.zig");

const Swapchain = @This();

pub const Error = Device.Error;

/// What an acquire produced.
pub const Acquired = union(enum) {
    /// The image to draw into, and the semaphore to signal when its rendering
    /// is finished.
    image: struct { index: u32, render_finished: vk.Semaphore },
    /// The surface changed under us. The caller recreates and tries again next
    /// frame; nothing was submitted and nothing has to be undone.
    out_of_date,
    /// The window has no area. Not an error and not something to retry in a
    /// tight loop: the frame is skipped until the window is restored.
    minimised,
};

gpa: Allocator,
device: *Device,

handle: vk.SwapchainKHR = vk.null_handle,
format: vk.Format = .undefined,
color_space: vk.ColorSpaceKHR = .srgb_nonlinear,
present_mode: vk.PresentModeKHR = .fifo,
extent: vk.Extent2D = .{},
/// False when the driver offered no sRGB surface format. The renderer prints
/// one line about it, because the symptom -- every colour too dark -- is
/// otherwise blamed on the shader.
srgb: bool = true,

render_pass: vk.RenderPass = vk.null_handle,
/// Bumped when the render pass is rebuilt, which happens only if the surface
/// format changed. `Renderer` compares it and rebuilds its pipeline, because a
/// pipeline is tied to the render pass it was created against.
format_generation: u32 = 0,

images: []vk.Image = &.{},
views: []vk.ImageView = &.{},
framebuffers: []vk.Framebuffer = &.{},
/// One per image; see the header.
render_finished: []vk.Semaphore = &.{},
/// The fence of the frame that last used each image, or null. Not owned.
images_in_flight: []vk.Fence = &.{},

vsync: choose.Vsync = .on,
/// Every pixel is computed even where another window hides it, because the
/// frame is going to be read back. Takes effect at the next `recreate`.
readable: bool = false,

pub fn init(
    gpa: Allocator,
    device: *Device,
    window_extent: vk.Extent2D,
    vsync: choose.Vsync,
) Error!Swapchain {
    var s: Swapchain = .{ .gpa = gpa, .device = device, .vsync = vsync };
    errdefer s.deinit();
    try s.build(window_extent, vk.null_handle);
    return s;
}

pub fn deinit(s: *Swapchain) void {
    const d = s.device;
    const dt = &d.dt;
    _ = dt.deviceWaitIdle(d.handle);

    s.destroyImageResources();
    if (s.handle != vk.null_handle) dt.destroySwapchainKHR(d.handle, s.handle, null);
    if (s.render_pass != vk.null_handle) dt.destroyRenderPass(d.handle, s.render_pass, null);
    s.* = undefined;
}

fn destroyImageResources(s: *Swapchain) void {
    const d = s.device;
    const dt = &d.dt;
    for (s.framebuffers) |f| dt.destroyFramebuffer(d.handle, f, null);
    for (s.views) |v| dt.destroyImageView(d.handle, v, null);
    for (s.render_finished) |sem| dt.destroySemaphore(d.handle, sem, null);
    s.gpa.free(s.framebuffers);
    s.gpa.free(s.views);
    s.gpa.free(s.images);
    s.gpa.free(s.render_finished);
    s.gpa.free(s.images_in_flight);
    s.framebuffers = &.{};
    s.views = &.{};
    s.images = &.{};
    s.render_finished = &.{};
    s.images_in_flight = &.{};
}

/// Rebuilds for a new size. The old swapchain is passed in as `oldSwapchain`,
/// which lets the driver reuse its images and lets frames already in flight
/// finish presenting -- the difference between a resize that is smooth and one
/// that flashes black.
pub fn recreate(s: *Swapchain, window_extent: vk.Extent2D) Error!void {
    const d = s.device;
    _ = d.dt.deviceWaitIdle(d.handle);

    const old = s.handle;
    s.destroyImageResources();
    s.handle = vk.null_handle;
    defer if (old != vk.null_handle) d.dt.destroySwapchainKHR(d.handle, old, null);

    try s.build(window_extent, old);
}

fn build(s: *Swapchain, window_extent: vk.Extent2D, old: vk.SwapchainKHR) Error!void {
    const d = s.device;
    const gpa = s.gpa;

    const caps = try d.surfaceCapabilities();
    s.extent = choose.extent(caps, window_extent);

    const formats = try d.surfaceFormats(gpa);
    defer gpa.free(formats);
    const picked = choose.surfaceFormat(formats);

    const modes = try d.surfacePresentModes(gpa);
    defer gpa.free(modes);

    const format_changed = s.format != picked.format.format;
    s.format = picked.format.format;
    s.color_space = picked.format.color_space;
    s.srgb = picked.srgb;
    s.present_mode = choose.presentMode(modes, s.vsync);

    // The render pass is built before the minimised check, not after: it
    // depends on the format and not on the size, and `Renderer` needs one to
    // create its pipeline against. A program started into a minimised window
    // -- which is what restoring a session does -- would otherwise reach
    // pipeline creation with no render pass at all.
    if (s.render_pass == vk.null_handle or format_changed) {
        if (s.render_pass != vk.null_handle) {
            d.dt.destroyRenderPass(d.handle, s.render_pass, null);
            s.format_generation += 1;
        }
        try s.createRenderPass();
    }

    if (choose.isMinimised(s.extent)) {
        // No images to make. The frame loop checks `isMinimised` and skips
        // until a resize brings the window back.
        return;
    }

    var families: [2]u32 = .{ d.families.graphics, d.families.present };
    const shared = d.families.shared();

    const info: vk.SwapchainCreateInfoKHR = .{
        .surface = d.surface,
        .min_image_count = choose.imageCount(caps),
        .image_format = s.format,
        .image_color_space = s.color_space,
        .image_extent = s.extent,
        // TRANSFER_DST as well as COLOR_ATTACHMENT, so a frame can be copied
        // out to a file. That is what makes `fenrir view --snapshot` possible,
        // and it is how the GPU output gets compared against the CPU reference
        // rasteriser.
        .image_usage = vk.ImageUsageFlags.color_attachment | vk.ImageUsageFlags.transfer_src,
        .image_sharing_mode = if (shared) .exclusive else .concurrent,
        .queue_family_index_count = if (shared) 0 else 2,
        .p_queue_family_indices = if (shared) null else &families,
        // Whatever the compositor already has. Asking for IDENTITY on a screen
        // that is rotated makes the driver rotate every frame.
        .pre_transform = caps.current_transform,
        .composite_alpha = choose.compositeAlpha(caps),
        .present_mode = s.present_mode,
        // Fragments hidden by another window need not be computed. The only
        // reason to say no is if the frame is going to be read back, which is
        // what `readable` is for: `fenrir read --shot` with the GPU path.
        .clipped = if (s.readable) 0 else 1,
        .old_swapchain = old,
    };

    try vk.check(d.dt.createSwapchainKHR(d.handle, &info, null, &s.handle));

    var n: u32 = 0;
    try vk.check(d.dt.getSwapchainImagesKHR(d.handle, s.handle, &n, null));
    s.images = try gpa.alloc(vk.Image, n);
    try vk.check(d.dt.getSwapchainImagesKHR(d.handle, s.handle, &n, s.images.ptr));

    s.views = try gpa.alloc(vk.ImageView, n);
    @memset(s.views, vk.null_handle);
    s.framebuffers = try gpa.alloc(vk.Framebuffer, n);
    @memset(s.framebuffers, vk.null_handle);
    s.render_finished = try gpa.alloc(vk.Semaphore, n);
    @memset(s.render_finished, vk.null_handle);
    s.images_in_flight = try gpa.alloc(vk.Fence, n);
    @memset(s.images_in_flight, vk.null_handle);

    for (s.images, 0..) |image, i| {
        const view_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .format = s.format,
            .subresource_range = .{ .aspect_mask = vk.ImageAspectFlags.color },
        };
        try vk.check(d.dt.createImageView(d.handle, &view_info, null, &s.views[i]));

        const fb_info: vk.FramebufferCreateInfo = .{
            .render_pass = s.render_pass,
            .attachment_count = 1,
            .p_attachments = s.views[i .. i + 1].ptr,
            .width = s.extent.width,
            .height = s.extent.height,
        };
        try vk.check(d.dt.createFramebuffer(d.handle, &fb_info, null, &s.framebuffers[i]));

        const sem_info: vk.SemaphoreCreateInfo = .{};
        try vk.check(d.dt.createSemaphore(d.handle, &sem_info, null, &s.render_finished[i]));
    }
}

fn createRenderPass(s: *Swapchain) Error!void {
    const d = s.device;

    const attachment: vk.AttachmentDescription = .{
        .format = s.format,
        .load_op = .clear,
        .store_op = .store,
        // Undefined, not PRESENT_SRC: the contents of a reacquired image are
        // not preserved, and promising the driver they are is how a frame ends
        // up with the last one's garbage behind it.
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass: vk.SubpassDescription = .{
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_ref),
    };

    // The one dependency that matters: the layout transition into
    // COLOR_ATTACHMENT_OPTIMAL happens at the start of the pass, and it must
    // not happen before the acquire's semaphore is signalled. Without this the
    // transition is allowed to run at TOP_OF_PIPE, before the image is
    // actually available, and the result is a torn or blank frame that appears
    // only under load.
    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.subpass_external,
        .dst_subpass = 0,
        .src_stage_mask = vk.PipelineStageFlags.color_attachment_output,
        .src_access_mask = 0,
        .dst_stage_mask = vk.PipelineStageFlags.color_attachment_output,
        .dst_access_mask = vk.AccessFlags.color_attachment_write,
    };

    const info: vk.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    };
    try vk.check(d.dt.createRenderPass(d.handle, &info, null, &s.render_pass));
}

pub fn isMinimised(s: *const Swapchain) bool {
    return s.handle == vk.null_handle or choose.isMinimised(s.extent);
}

pub fn imageCount(s: *const Swapchain) u32 {
    return @intCast(s.images.len);
}

/// Takes the next image, waiting on the fence of whichever frame last used it.
///
/// `image_available` is signalled by the presentation engine when the image is
/// really ready; the render pass's external dependency is what makes the
/// layout transition wait for it.
pub fn acquire(s: *Swapchain, image_available: vk.Semaphore) Error!Acquired {
    if (s.isMinimised()) return .minimised;
    const d = s.device;

    var index: u32 = 0;
    const result = d.dt.acquireNextImageKHR(
        d.handle,
        s.handle,
        std.math.maxInt(u64),
        image_available,
        vk.null_handle,
        &index,
    );
    switch (result) {
        .error_out_of_date_khr => return .out_of_date,
        // Presented, but the surface has changed: this frame is drawn and the
        // swapchain is rebuilt afterwards. Treating it as an error here is
        // what makes a window flicker while it is being dragged to resize.
        .success, .suboptimal_khr => {},
        else => try vk.check(result),
    }

    // The acquired image may still be in use by a frame submitted two frames
    // ago. Its fence, not this frame's, is the one to wait on.
    if (s.images_in_flight[index] != vk.null_handle) {
        _ = d.dt.waitForFences(d.handle, 1, @ptrCast(&s.images_in_flight[index]), 1, std.math.maxInt(u64));
    }

    return .{ .image = .{ .index = index, .render_finished = s.render_finished[index] } };
}

/// Records that `fence` is the one guarding this image from now on.
pub fn markInFlight(s: *Swapchain, index: u32, fence: vk.Fence) void {
    s.images_in_flight[index] = fence;
}

/// Queues the image for display. Returns false when the swapchain needs
/// rebuilding, which the caller does at the top of the next frame rather than
/// here, so that a resize costs one frame and not two.
pub fn present(s: *Swapchain, index: u32, wait_on: vk.Semaphore) Error!bool {
    const d = s.device;
    var handle = s.handle;
    var image_index = index;
    var semaphore = wait_on;

    const info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&semaphore),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&handle),
        .p_image_indices = @ptrCast(&image_index),
    };

    const result = d.dt.queuePresentKHR(d.present_queue, &info);
    return switch (result) {
        .success => true,
        .suboptimal_khr, .error_out_of_date_khr => false,
        else => blk: {
            try vk.check(result);
            break :blk true;
        },
    };
}

pub fn renderArea(s: *const Swapchain) vk.Rect2D {
    return .{ .offset = .{}, .extent = s.extent };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the acquire result distinguishes the three things that can happen" {
    // No device here, so what is testable is the shape: a frame loop that
    // collapses `out_of_date` and `minimised` into one case either spins at
    // full speed while the window is minimised or fails to rebuild after a
    // resize, and both are silent.
    const a: Acquired = .{ .image = .{ .index = 2, .render_finished = 7 } };
    try testing.expectEqual(@as(u32, 2), a.image.index);
    try testing.expect(@as(std.meta.Tag(Acquired), .minimised) != .out_of_date);
}
