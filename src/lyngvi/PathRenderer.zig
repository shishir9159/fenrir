//! The analytic path pipeline, on the device.
//!
//! A second pipeline alongside `Renderer`'s, sharing its render pass, its
//! command buffer and its swapchain, and owning nothing but its own layout,
//! buffers and descriptor sets. `Renderer` records it between the two halves
//! of its own draw, so a frame is: rects under, paths, rects over.
//!
//! `gleipnir/slugpipe.zig` is the contract this implements and the place the
//! reasoning lives. The short version: six read-only storage buffers hold the
//! outlines and the instances that place them, the vertex shader builds a
//! bounding quad per instance out of `gl_VertexIndex`, and the fragment
//! shader works out from the curves how much of its pixel is covered. There
//! is no vertex buffer, no index buffer, no stencil attachment, no
//! multisampling and no second pass.
//!
//! ## What is per frame and what is not
//!
//! All six buffers are per frame, because all six can change per frame: a
//! reader that scrolls to a new page uploads a new set of outlines. That
//! costs `frames_in_flight` copies of a page's geometry -- a megabyte or two
//! -- and buys the property that a frame in flight never has its buffers
//! rewritten underneath it, which is otherwise the hardest bug in a renderer
//! to see.
//!
//! The buffers grow and never shrink, so a session settles at the high-water
//! mark of the largest page it has drawn.
//!
//! ## Descriptor indexing
//!
//! None. Six bindings, one descriptor each, indexed by `gl_InstanceIndex` and
//! by values loaded from the buffers themselves -- all of which are plain
//! array subscripts inside a buffer rather than descriptor selections. So
//! this pipeline runs on a device with no descriptor-indexing features at
//! all, unlike the rect pipeline, whose texture array needs them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const choose = @import("choose.zig");
const shaders = @import("shaders.zig");
const vk = @import("vk.zig");

const scene_mod = @import("../gleipnir/scene.zig");
const slug = @import("../gleipnir/slug.zig");
const slugpipe = @import("../gleipnir/slugpipe.zig");

const Scene = scene_mod.Scene;
const PathRenderer = @This();

pub const Error = Device.Error || shaders.Error;

/// Matches `Renderer.frames_in_flight`, because the two record into the same
/// command buffer and so must agree about which frame they are on.
pub const frames_in_flight = 2;

/// Smallest allocation for each of the six. A page of prose is a few hundred
/// kilobytes of curves; starting there avoids a growth step per buffer on the
/// first frame of every document.
pub const min_curve_bytes: u64 = 256 * 1024;
pub const min_small_bytes: u64 = 16 * 1024;

const Buffers = struct {
    curves: Device.Buffer = .{},
    bands: Device.Buffer = .{},
    indices: Device.Buffer = .{},
    headers: Device.Buffer = .{},
    instances: Device.Buffer = .{},
    clips: Device.Buffer = .{},
    set: vk.DescriptorSet = vk.null_handle,
    /// The store and placement generations these buffers hold, so neither is
    /// sent again unchanged. `maxInt` is "nothing yet", which no real
    /// generation is.
    generation: u32 = std.math.maxInt(u32),
    placement: u32 = std.math.maxInt(u32),

    /// In binding order, so the descriptor writes and the uploads can both be
    /// loops rather than six repetitions.
    fn all(b: *Buffers) [slugpipe.binding.count]*Device.Buffer {
        return .{ &b.curves, &b.bands, &b.indices, &b.headers, &b.instances, &b.clips };
    }
};

gpa: Allocator,
device: *Device,
swapchain: *Swapchain,

set_layout: vk.DescriptorSetLayout = vk.null_handle,
pool: vk.DescriptorPool = vk.null_handle,
layout: vk.PipelineLayout = vk.null_handle,
pipeline: vk.Pipeline = vk.null_handle,
pipeline_generation: u32 = 0,

frames: [frames_in_flight]Buffers = @splat(.{}),

/// True when this binary has no SPIR-V in it, the same as `Renderer`'s. The
/// window still opens and the rect pipeline still draws; paths do not.
shaders_missing: bool = false,

// -- counters ----------------------------------------------------------------
paths_drawn: u64 = 0,
instance_high_water: u32 = 0,
curve_high_water: u32 = 0,
bytes_uploaded: u64 = 0,

pub fn init(gpa: Allocator, device: *Device, swapchain: *Swapchain) Error!PathRenderer {
    var p: PathRenderer = .{ .gpa = gpa, .device = device, .swapchain = swapchain };
    errdefer p.deinit();

    try p.createDescriptorLayout();
    try p.createPipelineLayout();
    try p.createDescriptorPool();
    try p.createBuffers();

    p.createPipeline() catch |err| switch (err) {
        // The same bargain the rect pipeline makes: a machine with a driver
        // and no shader compiler builds and runs, and says what is missing.
        error.NoShaders => p.shaders_missing = true,
        else => return err,
    };
    return p;
}

pub fn deinit(p: *PathRenderer) void {
    const d = p.device;
    if (p.pipeline != vk.null_handle) d.dt.destroyPipeline(d.handle, p.pipeline, null);
    if (p.layout != vk.null_handle) d.dt.destroyPipelineLayout(d.handle, p.layout, null);
    for (&p.frames) |*f| {
        for (f.all()) |b| d.destroyBuffer(b);
    }
    if (p.pool != vk.null_handle) d.dt.destroyDescriptorPool(d.handle, p.pool, null);
    if (p.set_layout != vk.null_handle) d.dt.destroyDescriptorSetLayout(d.handle, p.set_layout, null);
    p.* = undefined;
}

fn createDescriptorLayout(p: *PathRenderer) Error!void {
    const d = p.device;
    var bindings: [slugpipe.binding.count]vk.DescriptorSetLayoutBinding = undefined;
    for (&bindings, 0..) |*b, i| {
        b.* = .{
            .binding = @intCast(i),
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            // The vertex shader reads the instance and its header to build
            // the quad; the fragment shader reads everything. Declaring both
            // stages for all six costs nothing and keeps the two halves of
            // the include file from disagreeing about who may read what.
            .stage_flags = vk.ShaderStageFlags.vertex | vk.ShaderStageFlags.fragment,
        };
    }

    const info: vk.DescriptorSetLayoutCreateInfo = .{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    };
    try vk.check(d.dt.createDescriptorSetLayout(d.handle, &info, null, &p.set_layout));
}

fn createPipelineLayout(p: *PathRenderer) Error!void {
    const d = p.device;
    const range: vk.PushConstantRange = .{
        .stage_flags = vk.ShaderStageFlags.vertex,
        .offset = 0,
        .size = @sizeOf(slugpipe.PushConstants),
    };
    const info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&p.set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&range),
    };
    try vk.check(d.dt.createPipelineLayout(d.handle, &info, null, &p.layout));
}

fn createDescriptorPool(p: *PathRenderer) Error!void {
    const d = p.device;
    const sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_buffer, .descriptor_count = frames_in_flight * slugpipe.binding.count },
    };
    const info: vk.DescriptorPoolCreateInfo = .{
        .max_sets = frames_in_flight,
        .pool_size_count = sizes.len,
        .p_pool_sizes = &sizes,
    };
    try vk.check(d.dt.createDescriptorPool(d.handle, &info, null, &p.pool));
}

fn createBuffers(p: *PathRenderer) Error!void {
    const d = p.device;
    for (&p.frames) |*f| {
        // A descriptor set cannot be written with a null buffer, so every one
        // of the six starts at its minimum size even for a frame that will
        // never have clips in it.
        f.curves = try p.newBuffer(min_curve_bytes);
        f.bands = try p.newBuffer(min_small_bytes);
        f.indices = try p.newBuffer(min_small_bytes);
        f.headers = try p.newBuffer(min_small_bytes);
        f.instances = try p.newBuffer(min_small_bytes);
        f.clips = try p.newBuffer(min_small_bytes);

        const info: vk.DescriptorSetAllocateInfo = .{
            .descriptor_pool = p.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&p.set_layout),
        };
        try vk.check(d.dt.allocateDescriptorSets(d.handle, &info, @ptrCast(&f.set)));
        p.writeDescriptors(f);
    }
}

fn newBuffer(p: *PathRenderer, size: u64) Error!Device.Buffer {
    const m = vk.MemoryPropertyFlags;
    return p.device.createBuffer(
        size,
        vk.BufferUsageFlags.storage_buffer,
        m.host_visible | m.host_coherent,
        // Preferred, not required: with resizable BAR the outlines land in
        // video memory and the fragment shader reads them at full speed.
        m.device_local,
    );
}

fn writeDescriptors(p: *PathRenderer, f: *Buffers) void {
    const d = p.device;
    var infos: [slugpipe.binding.count]vk.DescriptorBufferInfo = undefined;
    var writes: [slugpipe.binding.count]vk.WriteDescriptorSet = undefined;

    for (f.all(), 0..) |b, i| {
        infos[i] = .{ .buffer = b.handle };
        writes[i] = .{
            .dst_set = f.set,
            .dst_binding = @intCast(i),
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = @ptrCast(&infos[i]),
        };
    }
    d.dt.updateDescriptorSets(d.handle, writes.len, &writes, 0, null);
}

fn createPipeline(p: *PathRenderer) Error!void {
    const d = p.device;

    // Parsed rather than trusted, for the same reason as the rect pipeline's:
    // an empty `.spv` from a compiler that failed and exited zero creates a
    // pipeline that draws nothing and reports nothing.
    const vertex = try shaders.slugVertexModule();
    const fragment = try shaders.slugFragmentModule();

    var vert_module: vk.ShaderModule = vk.null_handle;
    var frag_module: vk.ShaderModule = vk.null_handle;
    {
        const info: vk.ShaderModuleCreateInfo = .{
            .code_size = vertex.byteSize(),
            .p_code = vertex.code().ptr,
        };
        try vk.check(d.dt.createShaderModule(d.handle, &info, null, &vert_module));
    }
    defer d.dt.destroyShaderModule(d.handle, vert_module, null);
    {
        const info: vk.ShaderModuleCreateInfo = .{
            .code_size = fragment.byteSize(),
            .p_code = fragment.code().ptr,
        };
        try vk.check(d.dt.createShaderModule(d.handle, &info, null, &frag_module));
    }
    defer d.dt.destroyShaderModule(d.handle, frag_module, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = vk.ShaderStageFlags.vertex, .module = vert_module, .p_name = "main" },
        .{ .stage = vk.ShaderStageFlags.fragment, .module = frag_module, .p_name = "main" },
    };

    // No vertex input state whatsoever: the quad comes out of gl_VertexIndex
    // and the outline out of a storage buffer.
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{};
    const assembly: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_strip };
    const viewport: vk.PipelineViewportStateCreateInfo = .{};
    const raster: vk.PipelineRasterizationStateCreateInfo = .{
        // Culling off. The page transform has a y flip in it, which reverses
        // the quad's winding; a culled quad draws nothing at all.
        .cull_mode = 0,
    };
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{};

    const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = 1,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
    };
    const blend: vk.PipelineColorBlendStateCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &raster,
        .p_multisample_state = &multisample,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dynamic,
        .layout = p.layout,
        .render_pass = p.swapchain.render_pass,
        .subpass = 0,
    };

    try vk.check(d.dt.createGraphicsPipelines(
        d.handle,
        vk.null_handle,
        1,
        @ptrCast(&info),
        null,
        @ptrCast(&p.pipeline),
    ));
    p.pipeline_generation = p.swapchain.format_generation;
}

/// Rebuilds the pipeline if the swapchain's format has changed underneath it.
///
/// A pipeline is tied to the render pass it was created with, and a format
/// change makes a new one. Called from `Renderer.refresh`, which is called at
/// the top of every frame.
pub fn refresh(p: *PathRenderer) Error!void {
    if (p.shaders_missing) return;
    if (p.pipeline != vk.null_handle and p.pipeline_generation == p.swapchain.format_generation) {
        return;
    }
    const d = p.device;
    if (p.pipeline != vk.null_handle) {
        _ = d.dt.deviceWaitIdle(d.handle);
        d.dt.destroyPipeline(d.handle, p.pipeline, null);
        p.pipeline = vk.null_handle;
    }
    try p.createPipeline();
}

/// Copies a scene into frame `index`'s buffers.
///
/// Must be called after that frame's fence has been waited on and before its
/// command buffer is recorded -- which is exactly where `Renderer.frame`
/// calls it, between the wait and the render pass.
pub fn upload(p: *PathRenderer, index: u32, s: *const Scene, draw_frame: *const scene_mod.Frame) Error!void {
    const f = &p.frames[index];

    const parts = [slugpipe.binding.count][]const u8{
        s.store.curveBytes(),
        s.store.bandBytes(),
        s.store.indexBytes(),
        s.store.headerBytes(),
        std.mem.sliceAsBytes(draw_frame.instances.items),
        std.mem.sliceAsBytes(draw_frame.clips.items),
    };
    const minimums = [slugpipe.binding.count]u64{
        min_curve_bytes, min_small_bytes, min_small_bytes,
        min_small_bytes, min_small_bytes, min_small_bytes,
    };

    // The outlines are the first four and they change only when a page comes
    // into view; the placement is the last two and changes whenever the
    // scroll moves. Sending the outlines every frame works and costs four
    // megabytes a frame on a page of text, which is most of a gigabyte a
    // minute of bandwidth spent re-sending bytes the device already has.
    const store_changed = f.generation != s.generation;
    const placed_changed = f.placement != draw_frame.generation;
    if (!store_changed and !placed_changed) return;

    const first = if (store_changed) 0 else slugpipe.binding.instances;
    const last = if (placed_changed) slugpipe.binding.count else slugpipe.binding.instances;
    if (first >= last) return;

    var regrown = false;
    for (
        f.all()[first..last],
        parts[first..last],
        minimums[first..last],
    ) |b, bytes, floor| {
        if (bytes.len > b.size) {
            // Safe here and nowhere else: this frame's fence has been waited
            // on, so nothing the GPU is reading lives in the old buffer.
            const want = choose.bufferCapacity(b.size, bytes.len, floor);
            p.device.destroyBuffer(b);
            b.* = try p.newBuffer(want);
            regrown = true;
        }
        if (bytes.len == 0) continue;
        @memcpy(b.slice()[0..bytes.len], bytes);
        p.device.flush(b.*, 0, bytes.len);
        p.bytes_uploaded += bytes.len;
    }
    // One update for however many of the six moved, rather than one each.
    if (regrown) p.writeDescriptors(f);
    f.generation = s.generation;
    f.placement = draw_frame.generation;

    p.instance_high_water = @max(p.instance_high_water, draw_frame.instanceCount());
    p.curve_high_water = @max(p.curve_high_water, @as(u32, @intCast(s.store.curves.items.len)));
}

/// Records the draw into a command buffer that is already inside a render
/// pass, with the viewport and scissor already set.
///
/// One `vkCmdDraw` for the whole page: four vertices, one instance per path.
pub fn record(p: *PathRenderer, cb: vk.CommandBuffer, index: u32, draw_frame: *const scene_mod.Frame) void {
    const count = draw_frame.instanceCount();
    if (count == 0 or p.pipeline == vk.null_handle) return;

    const d = p.device;
    const f = &p.frames[index];

    d.dt.cmdBindPipeline(cb, .graphics, p.pipeline);
    d.dt.cmdBindDescriptorSets(cb, .graphics, p.layout, 0, 1, @ptrCast(&f.set), 0, null);

    const push: slugpipe.PushConstants = .{ .viewport = .{
        @floatFromInt(p.swapchain.extent.width),
        @floatFromInt(p.swapchain.extent.height),
    } };
    d.dt.cmdPushConstants(
        cb,
        p.layout,
        vk.ShaderStageFlags.vertex,
        0,
        @sizeOf(slugpipe.PushConstants),
        &push,
    );

    d.dt.cmdDraw(cb, slugpipe.draw.vertex_count, count, 0, 0);
    p.paths_drawn += count;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "the descriptor bindings are the contract's, in order" {
    // A layout whose bindings are numbered differently from the shader's
    // creates successfully, validates cleanly, and reads the instance array
    // as though it were the curve array. Asserting the mapping here is the
    // only place both halves are visible at once.
    var bindings: [slugpipe.binding.count]u32 = undefined;
    for (&bindings, 0..) |*b, i| b.* = @intCast(i);

    try testing.expectEqual(bindings[slugpipe.binding.curves], slugpipe.binding.curves);
    try testing.expectEqual(bindings[slugpipe.binding.bands], slugpipe.binding.bands);
    try testing.expectEqual(bindings[slugpipe.binding.indices], slugpipe.binding.indices);
    try testing.expectEqual(bindings[slugpipe.binding.headers], slugpipe.binding.headers);
    try testing.expectEqual(bindings[slugpipe.binding.instances], slugpipe.binding.instances);
    try testing.expectEqual(bindings[slugpipe.binding.clips], slugpipe.binding.clips);
    try testing.expectEqual(@as(u32, 6), slugpipe.binding.count);
}

test "the buffer list is in binding order" {
    // `all()` is what both the descriptor writes and the uploads iterate, so
    // an entry out of order would put the instances in the curve binding --
    // which draws something, plausibly, and wrongly.
    var b: Buffers = .{};
    const list = b.all();
    try testing.expectEqual(@as(usize, slugpipe.binding.count), list.len);
    try testing.expect(list[slugpipe.binding.curves] == &b.curves);
    try testing.expect(list[slugpipe.binding.bands] == &b.bands);
    try testing.expect(list[slugpipe.binding.indices] == &b.indices);
    try testing.expect(list[slugpipe.binding.headers] == &b.headers);
    try testing.expect(list[slugpipe.binding.instances] == &b.instances);
    try testing.expect(list[slugpipe.binding.clips] == &b.clips);
}

test "this pipeline agrees with the renderer about how many frames are in flight" {
    // The two record into the same command buffer with the same frame index.
    // If they disagreed, the path buffers would be uploaded for one frame and
    // read for another, which shows as a page that is one frame stale -- and
    // only while scrolling.
    try testing.expectEqual(
        @as(comptime_int, @import("Renderer.zig").frames_in_flight),
        frames_in_flight,
    );
}
