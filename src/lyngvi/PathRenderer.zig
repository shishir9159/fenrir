//! The analytic path pipeline, on the device.
//!
//! A second pipeline alongside `Renderer`'s, sharing its render pass, its
//! command buffer and its swapchain, and owning nothing but its own layout,
//! buffers, pipelines and descriptor sets. `Renderer` records it between the
//! two halves of its own draw, so a frame is: rects under, paths, rects over.
//!
//! `gleipnir/slugpipe.zig` is the contract this implements and the place the
//! reasoning lives. The short version: eight read-only storage buffers hold
//! the outlines, the images, and the instances that place them; the vertex
//! shader builds a bounding quad per instance out of `gl_VertexIndex`; and
//! the fragment shader works out from the curves how much of its pixel is
//! covered. There is no vertex buffer, no index buffer, no stencil
//! attachment, no multisampling and no second pass.
//!
//! ## Pipelines
//!
//! One per `slugpipe.Composite`: the same shaders, the same layout, and a
//! different blend state. `record` walks the frame's instances and draws each
//! run that shares a composite with its pipeline, so a page with no blend
//! modes on it is one draw and a page with a highlighter annotation is three.
//!
//! ## What is per frame and what is not
//!
//! All eight buffers are per frame in flight, because all eight can change:
//! a reader that scrolls to a new page uploads a new set of outlines. That
//! costs `frames_in_flight` copies of a page's geometry and buys the property
//! that a frame in flight never has its buffers rewritten underneath it,
//! which is otherwise the hardest bug in a renderer to see. What is *sent*
//! is less: the six recorded buffers only when the scene's generation moves,
//! the two placement buffers only when the frame's does.
//!
//! The buffers grow and never shrink, so a session settles at the high-water
//! mark of the largest set of pages it has drawn.
//!
//! ## Descriptor indexing
//!
//! None. Eight bindings, one descriptor each, indexed by `gl_InstanceIndex`
//! and by values loaded from the buffers themselves -- all of which are plain
//! array subscripts inside a buffer rather than descriptor selections. Images
//! are texels in a buffer and not textures for exactly this reason. So this
//! pipeline runs on a device with no descriptor-indexing features at all.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const choose = @import("choose.zig");
const shaders = @import("shaders.zig");
const vk = @import("vk.zig");

const scene_mod = @import("../gleipnir/scene.zig");
const slugpipe = @import("../gleipnir/slugpipe.zig");

const Composite = slugpipe.Composite;
const Scene = scene_mod.Scene;
const PathRenderer = @This();

pub const Error = Device.Error || shaders.Error;

/// Matches `Renderer.frames_in_flight`, because the two record into the same
/// command buffer and so must agree about which frame they are on.
pub const frames_in_flight = 2;

/// Smallest allocation for each buffer. A page of prose is a few hundred
/// kilobytes of curves; starting there avoids a growth step per buffer on the
/// first frame of every document.
pub const min_large_bytes: u64 = 256 * 1024;
pub const min_small_bytes: u64 = 16 * 1024;

const Buffers = struct {
    list: [slugpipe.binding.count]Device.Buffer = @splat(.{}),
    set: vk.DescriptorSet = vk.null_handle,
    /// The store and placement generations these buffers hold, so neither is
    /// sent again unchanged. `maxInt` is "nothing yet", which no real
    /// generation is.
    generation: u32 = std.math.maxInt(u32),
    placement: u32 = std.math.maxInt(u32),
};

gpa: Allocator,
device: *Device,
swapchain: *Swapchain,

set_layout: vk.DescriptorSetLayout = vk.null_handle,
pool: vk.DescriptorPool = vk.null_handle,
layout: vk.PipelineLayout = vk.null_handle,
pipelines: [Composite.count]vk.Pipeline = @splat(vk.null_handle),
pipeline_generation: u32 = 0,

frames: [frames_in_flight]Buffers = @splat(.{}),

/// True when this binary has no SPIR-V in it, the same as `Renderer`'s. The
/// window still opens and the rect pipeline still draws; paths do not.
shaders_missing: bool = false,

// -- counters ----------------------------------------------------------------
paths_drawn: u64 = 0,
draw_calls: u64 = 0,
instance_high_water: u32 = 0,
curve_high_water: u32 = 0,
texel_high_water: u32 = 0,
bytes_uploaded: u64 = 0,

pub fn init(gpa: Allocator, device: *Device, swapchain: *Swapchain) Error!PathRenderer {
    var p: PathRenderer = .{ .gpa = gpa, .device = device, .swapchain = swapchain };
    errdefer p.deinit();

    try p.createDescriptorLayout();
    try p.createPipelineLayout();
    try p.createDescriptorPool();
    try p.createBuffers();

    p.createPipelines() catch |err| switch (err) {
        // The same bargain the rect pipeline makes: a machine with a driver
        // and no shader compiler builds and runs, and says what is missing.
        error.NoShaders => p.shaders_missing = true,
        else => return err,
    };
    return p;
}

pub fn deinit(p: *PathRenderer) void {
    const d = p.device;
    p.destroyPipelines();
    if (p.layout != vk.null_handle) d.dt.destroyPipelineLayout(d.handle, p.layout, null);
    for (&p.frames) |*f| {
        for (&f.list) |*b| d.destroyBuffer(b);
    }
    if (p.pool != vk.null_handle) d.dt.destroyDescriptorPool(d.handle, p.pool, null);
    if (p.set_layout != vk.null_handle) d.dt.destroyDescriptorSetLayout(d.handle, p.set_layout, null);
    p.* = undefined;
}

fn destroyPipelines(p: *PathRenderer) void {
    const d = p.device;
    for (&p.pipelines) |*pl| {
        if (pl.* != vk.null_handle) d.dt.destroyPipeline(d.handle, pl.*, null);
        pl.* = vk.null_handle;
    }
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
            // stages for all of them costs nothing and keeps the two halves
            // of the include file from disagreeing about who may read what.
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

/// The first allocation for a binding: the large ones are the ones a page
/// of text fills on its first frame.
fn minimumFor(b: u32) u64 {
    return switch (b) {
        slugpipe.binding.curves, slugpipe.binding.indices, slugpipe.binding.texels => min_large_bytes,
        else => min_small_bytes,
    };
}

fn createBuffers(p: *PathRenderer) Error!void {
    const d = p.device;
    for (&p.frames) |*f| {
        // A descriptor set cannot be written with a null buffer, so every
        // binding starts at its minimum size even in a frame that will never
        // have an image or a clip in it.
        for (&f.list, 0..) |*b, i| b.* = try p.newBuffer(minimumFor(@intCast(i)));

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

    for (&f.list, 0..) |b, i| {
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

/// The blend state for each composite. See `slugpipe.Composite` for why each
/// is what it is.
pub fn blendFor(c: Composite) vk.PipelineColorBlendAttachmentState {
    var s: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = 1,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
    };
    switch (c) {
        .normal => {},
        .multiply => s.src_color_blend_factor = .dst_color,
        .screen => s.dst_color_blend_factor = .one_minus_src_color,
        .darken => {
            s.color_blend_op = .min;
            s.alpha_blend_op = .max;
        },
        .lighten => {
            s.color_blend_op = .max;
            s.alpha_blend_op = .max;
        },
    }
    return s;
}

fn createPipelines(p: *PathRenderer) Error!void {
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

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    var attachments: [Composite.count]vk.PipelineColorBlendAttachmentState = undefined;
    var blends: [Composite.count]vk.PipelineColorBlendStateCreateInfo = undefined;
    var infos: [Composite.count]vk.GraphicsPipelineCreateInfo = undefined;
    for (0..Composite.count) |i| {
        attachments[i] = blendFor(@enumFromInt(i));
        blends[i] = .{ .attachment_count = 1, .p_attachments = @ptrCast(&attachments[i]) };
        infos[i] = .{
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &assembly,
            .p_viewport_state = &viewport,
            .p_rasterization_state = &raster,
            .p_multisample_state = &multisample,
            .p_color_blend_state = &blends[i],
            .p_dynamic_state = &dynamic,
            .layout = p.layout,
            .render_pass = p.swapchain.render_pass,
            .subpass = 0,
        };
    }

    try vk.check(d.dt.createGraphicsPipelines(
        d.handle,
        vk.null_handle,
        Composite.count,
        &infos,
        null,
        &p.pipelines,
    ));
    p.pipeline_generation = p.swapchain.format_generation;
}

/// Rebuilds the pipelines if the swapchain's format has changed underneath
/// them.
///
/// A pipeline is tied to the render pass it was created with, and a format
/// change makes a new one.
pub fn refresh(p: *PathRenderer) Error!void {
    if (p.shaders_missing) return;
    if (p.pipelines[0] != vk.null_handle and p.pipeline_generation == p.swapchain.format_generation) {
        return;
    }
    const d = p.device;
    if (p.pipelines[0] != vk.null_handle) {
        _ = d.dt.deviceWaitIdle(d.handle);
        p.destroyPipelines();
    }
    try p.createPipelines();
}

/// Copies a scene into frame `index`'s buffers.
///
/// Must be called after that frame's fence has been waited on and before its
/// command buffer is recorded -- which is exactly where `Renderer.frame`
/// calls it, between the wait and the render pass.
pub fn upload(p: *PathRenderer, index: u32, s: *const Scene, draw_frame: *const scene_mod.Frame) Error!void {
    const f = &p.frames[index];

    const b = slugpipe.binding;
    var parts: [b.count][]const u8 = undefined;
    parts[b.curves] = s.store.curveBytes();
    parts[b.bands] = s.store.bandBytes();
    parts[b.indices] = s.store.indexBytes();
    parts[b.headers] = s.store.headerBytes();
    parts[b.instances] = std.mem.sliceAsBytes(draw_frame.instances.items);
    parts[b.clips] = std.mem.sliceAsBytes(draw_frame.clips.items);
    parts[b.images] = s.imageBytes();
    parts[b.texels] = s.texelBytes();

    // The recorded buffers change only when a page comes into view; the
    // placement changes whenever the scroll moves. Sending the outlines every
    // frame works and costs megabytes a frame on a page of text.
    const store_changed = f.generation != s.generation;
    const placed_changed = f.placement != draw_frame.generation;
    if (!store_changed and !placed_changed) return;

    var regrown = false;
    for (&f.list, parts, 0..) |*buf, bytes, i| {
        const changed = if (b.placement(@intCast(i))) placed_changed else store_changed;
        if (!changed) continue;
        if (bytes.len > buf.size) {
            // Safe here and nowhere else: this frame's fence has been waited
            // on, so nothing the GPU is reading lives in the old buffer.
            const want = choose.bufferCapacity(buf.size, bytes.len, minimumFor(@intCast(i)));
            p.device.destroyBuffer(buf);
            buf.* = try p.newBuffer(want);
            regrown = true;
        }
        if (bytes.len == 0) continue;
        @memcpy(buf.slice()[0..bytes.len], bytes);
        p.device.flush(buf.*, 0, bytes.len);
        p.bytes_uploaded += bytes.len;
    }
    // One update for however many moved, rather than one each.
    if (regrown) p.writeDescriptors(f);
    f.generation = s.generation;
    f.placement = draw_frame.generation;

    p.instance_high_water = @max(p.instance_high_water, draw_frame.instanceCount());
    p.curve_high_water = @max(p.curve_high_water, @as(u32, @intCast(s.store.curves.items.len)));
    p.texel_high_water = @max(p.texel_high_water, @as(u32, @intCast(s.texels.items.len)));
}

/// One draw call's worth of instances: a run that shares a composite.
pub const Run = struct { first: u32, count: u32, composite: Composite };

/// Splits a frame's instances into runs by composite, in order. Order is the
/// depth test here, so a run may not be merged with a later one of the same
/// composite across a different one between them.
pub fn nextRun(instances: []const slugpipe.Instance, from: u32) ?Run {
    if (from >= instances.len) return null;
    const composite = instances[from].compositeOf();
    var end = from + 1;
    while (end < instances.len and instances[end].compositeOf() == composite) end += 1;
    return .{ .first = from, .count = end - from, .composite = composite };
}

/// Records the draws into a command buffer that is already inside a render
/// pass, with the viewport and scissor already set and the extent given.
pub fn record(
    p: *PathRenderer,
    cb: vk.CommandBuffer,
    index: u32,
    draw_frame: *const scene_mod.Frame,
    extent: vk.Extent2D,
) void {
    const count = draw_frame.instanceCount();
    if (count == 0 or p.pipelines[0] == vk.null_handle) return;

    const d = p.device;
    const f = &p.frames[index];

    const push: slugpipe.PushConstants = .{ .viewport = .{
        @floatFromInt(extent.width),
        @floatFromInt(extent.height),
    } };

    var bound: ?Composite = null;
    var at: u32 = 0;
    while (nextRun(draw_frame.instances.items, at)) |run| : (at = run.first + run.count) {
        if (bound != run.composite) {
            d.dt.cmdBindPipeline(cb, .graphics, p.pipelines[@intFromEnum(run.composite)]);
            if (bound == null) {
                // The layout is shared, so the set and the push constants
                // survive a pipeline change and are bound once.
                d.dt.cmdBindDescriptorSets(cb, .graphics, p.layout, 0, 1, @ptrCast(&f.set), 0, null);
                d.dt.cmdPushConstants(
                    cb,
                    p.layout,
                    vk.ShaderStageFlags.vertex,
                    0,
                    @sizeOf(slugpipe.PushConstants),
                    &push,
                );
            }
            bound = run.composite;
        }
        d.dt.cmdDraw(cb, slugpipe.draw.vertex_count, run.count, 0, run.first);
        p.draw_calls += 1;
    }
    p.paths_drawn += count;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "the buffers are one per binding, in binding order" {
    // `list` is what both the descriptor writes and the uploads iterate, so a
    // buffer out of order would put the instances in the curve binding --
    // which draws something, plausibly, and wrongly.
    const b: Buffers = .{};
    try testing.expectEqual(@as(usize, slugpipe.binding.count), b.list.len);
    try testing.expect(slugpipe.binding.placement(slugpipe.binding.instances));
    try testing.expect(slugpipe.binding.placement(slugpipe.binding.clips));
    try testing.expect(!slugpipe.binding.placement(slugpipe.binding.texels));
    try testing.expect(!slugpipe.binding.placement(slugpipe.binding.curves));
}

test "a frame is drawn as one call per run of composites, in order" {
    const Instance = slugpipe.Instance;
    const clip: [4]f32 = .{ 0, 0, 1, 1 };
    const list = [_]Instance{
        .init(0, .identity, clip, .black, 1, .normal),
        .init(0, .identity, clip, .black, 1, .normal),
        .init(0, .identity, clip, .black, 1, .multiply),
        .init(0, .identity, clip, .black, 1, .normal),
    };
    const a = nextRun(&list, 0).?;
    try testing.expectEqual(@as(u32, 2), a.count);
    try testing.expectEqual(Composite.normal, a.composite);
    const b = nextRun(&list, 2).?;
    try testing.expectEqual(@as(u32, 1), b.count);
    try testing.expectEqual(Composite.multiply, b.composite);
    const c = nextRun(&list, 3).?;
    try testing.expectEqual(@as(u32, 3), c.first);
    try testing.expect(nextRun(&list, 4) == null);
}

test "multiply and screen blend with the factors that make them exact" {
    const m = blendFor(.multiply);
    try testing.expectEqual(vk.BlendFactor.dst_color, m.src_color_blend_factor);
    try testing.expectEqual(vk.BlendFactor.one_minus_src_alpha, m.dst_color_blend_factor);
    const s = blendFor(.screen);
    try testing.expectEqual(vk.BlendFactor.one, s.src_color_blend_factor);
    try testing.expectEqual(vk.BlendFactor.one_minus_src_color, s.dst_color_blend_factor);
    try testing.expectEqual(vk.BlendOp.min, blendFor(.darken).color_blend_op);
    try testing.expectEqual(vk.BlendOp.max, blendFor(.lighten).color_blend_op);
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
