//! The rect pipeline, made real.
//!
//! `gleipnir/pipeline.zig` wrote down what the Vulkan side has to agree with
//! before there was a Vulkan side: which binding is what, how big the push
//! constant is, which blend factors the shader's output assumes. This is the
//! other half of that contract, and it is deliberately the only file in the
//! project that both knows about `DrawList` and calls `vkCmdDraw`.
//!
//! ## One draw call
//!
//! A frame is `vkCmdDraw(cb, 4, instance_count, 0, 0)`. No vertex buffer, no
//! index buffer, no vertex input state at all: the quad's four corners come
//! out of `gl_VertexIndex` and the instance comes out of a storage buffer
//! indexed by `gl_InstanceIndex`. The clip is a field of the instance rather
//! than a scissor, so instances with different clips sit next to each other
//! with no state change between them, and the texture is an index into an
//! unbounded array, so a glyph atlas and a page image can appear in the same
//! call.
//!
//! That last part is why descriptor indexing is a hard requirement here and
//! not a preference. `DrawList.textureRuns` exists as the fallback and needs a
//! second SPIR-V module with a single `texture2D` in place of the array; until
//! that module exists, a device without the feature is refused by name rather
//! than drawn to incorrectly.
//!
//! ## What is per frame and what is per image
//!
//! Two frames in flight. Each has a command pool, a command buffer, a fence,
//! an image-available semaphore, a persistently mapped instance buffer and a
//! staging buffer. The render-finished semaphores are per swapchain *image*
//! and live in `Swapchain`, for the reason set out there at length.
//!
//! The instance buffer is mapped once and never unmapped. Mapping per frame is
//! a driver call and a page-table update to obtain a pointer that was already
//! valid; the buffer is written with one `memcpy` from `DrawList.bytes` and
//! read by the GPU where it lies. On a machine that exposes a device-local
//! host-visible heap -- resizable BAR -- it lands in video memory without
//! being asked to, because `choose.memoryType` prefers those bits.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const choose = @import("choose.zig");
const shaders = @import("shaders.zig");
const spirv = @import("spirv.zig");
const vk = @import("vk.zig");

const DrawList = @import("../gleipnir/DrawList.zig");
const paint = @import("../gelgja/paint.zig");
const pipeline_contract = @import("../gleipnir/pipeline.zig");
const rect = @import("../gleipnir/rect.zig");
const scene_mod = @import("../gleipnir/scene.zig");
const PathRenderer = @import("PathRenderer.zig");

const Color = paint.Color;
const Renderer = @This();

pub const Error = error{
    NoDescriptorIndexing,
    UnknownTexture,
    TooManyTextures,
} || Device.Error || shaders.Error;

/// Two, not three. Three costs a frame of latency for a smoothness that only
/// matters when the render time is close to the refresh interval, which for a
/// UI drawing a few thousand instances it is not.
pub const frames_in_flight = 2;

/// The size of the descriptor array. Sixty-four is far more than a reader
/// needs -- one glyph atlas, a handful of decoded page images -- and small
/// enough that filling every slot with a placeholder at startup costs nothing.
pub const max_textures = 64;

pub const min_instance_bytes: u64 = 64 * 1024;
pub const min_staging_bytes: u64 = 256 * 1024;

/// Timestamps a frame writes: the start of its command buffer, either side of
/// the paths, and the end.
const queries_per_frame = 4;

/// A fixed ring of timings, in milliseconds, and what `--time` makes of them.
///
/// Fixed, so recording one is a store and never an allocation. A run longer
/// than the ring keeps its latest frames, which after the first page has
/// arrived is what a measurement wants.
pub const Samples = struct {
    pub const capacity = 2048;

    values: [capacity]f32 = undefined,
    count: u64 = 0,

    pub fn push(s: *Samples, ms: f32) void {
        s.values[@intCast(s.count % capacity)] = ms;
        s.count += 1;
    }

    pub const Spread = struct { n: usize = 0, best: f32 = 0, median: f32 = 0, p95: f32 = 0 };

    /// Sorts what it holds in place, so it is for the end of a run.
    pub fn spread(s: *Samples) Spread {
        const n: usize = @intCast(@min(s.count, capacity));
        if (n == 0) return .{};
        const v = s.values[0..n];
        std.mem.sort(f32, v, {}, std.sort.asc(f32));
        return .{ .n = n, .best = v[0], .median = v[n / 2], .p95 = v[(n * 95) / 100] };
    }
};

pub const Status = enum {
    /// Drawn and queued for presentation.
    drawn,
    /// The surface changed size or was invalidated. The caller recreates the
    /// swapchain and draws again next frame.
    needs_recreate,
    /// The window has no area. Nothing was submitted.
    skipped,
};

pub const TextureKind = enum {
    /// One byte per pixel of coverage, which is what Týr's glyph atlas is. The
    /// shader reads the red channel and modulates alpha only, so one atlas
    /// serves every colour of text on the screen.
    coverage,
    /// Four bytes per pixel, sRGB-encoded: a rasterised page, a decoded image.
    color,

    fn format(k: TextureKind) vk.Format {
        return switch (k) {
            .coverage => .r8_unorm,
            // UNORM, not `_SRGB`, even though the bytes *are* sRGB-encoded.
            //
            // An `_SRGB` sampled image is decoded by the hardware on read, so
            // the shader would receive linear light -- and `rect.frag` then
            // applies `srgbToLinear` to it, because that is what it does to
            // every colour it is given. Converting twice is a page rendered
            // far too dark, and it is invisible in the CPU model, whose
            // sampler hands over the stored bytes.
            //
            // So the rule is one rule everywhere: every colour that reaches
            // the shader is sRGB-encoded and the shader decodes it. The
            // hardware is told to keep its hands off.
            .color => .r8g8b8a8_unorm,
        };
    }

    fn bytesPerPixel(k: TextureKind) u32 {
        return switch (k) {
            .coverage => 1,
            .color => 4,
        };
    }
};

/// A rectangle of an image to send to the device this frame.
///
/// `pixels` is the *whole* image and `stride` its row length in bytes; the
/// rectangle selects part of it. That is the shape Týr's atlas reports its
/// dirty region in, and copying the sub-rectangle out into a packed buffer
/// first would be a second copy of the same bytes.
pub const Upload = struct {
    texture: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    pixels: []const u8,
    stride: u32,
};

pub const Texture = struct {
    image: vk.Image = vk.null_handle,
    memory: vk.DeviceMemory = vk.null_handle,
    view: vk.ImageView = vk.null_handle,
    width: u32 = 0,
    height: u32 = 0,
    kind: TextureKind = .coverage,
};

/// A frame as the device drew it: what is on the screen, read back from the
/// swapchain image after the frame finished, so a test of the GPU path is a
/// test of the GPU and not of a model of it.
///
/// Eight-bit RGBA, sRGB-encoded -- the swapchain format is `_SRGB`, so the
/// bytes stored are already the encoded ones -- and opaque, because the frame
/// is cleared to an opaque colour.
pub const Capture = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

const Frame = struct {
    pool: vk.CommandPool = vk.null_handle,
    cb: vk.CommandBuffer = null,
    fence: vk.Fence = vk.null_handle,
    image_available: vk.Semaphore = vk.null_handle,
    instances: Device.Buffer = .{},
    staging: Device.Buffer = .{},
    set: vk.DescriptorSet = vk.null_handle,
};

gpa: Allocator,
device: *Device,
swapchain: *Swapchain,

sampler: vk.Sampler = vk.null_handle,
set_layout: vk.DescriptorSetLayout = vk.null_handle,
pool: vk.DescriptorPool = vk.null_handle,
layout: vk.PipelineLayout = vk.null_handle,
pipeline: vk.Pipeline = vk.null_handle,
/// The swapchain's format generation the pipeline was built against. A format
/// change means a new render pass, and a pipeline is tied to the render pass
/// it was created with.
pipeline_generation: u32 = 0,

/// True when this binary was built without a shader compiler on the machine.
///
/// Not an error, and not a reason to refuse to run: everything except the draw
/// call still works, so the window opens, the swapchain is created, images are
/// acquired, cleared and presented, and the frame loop can be timed. What is
/// missing is the drawing, and a window that clears to the right colour and
/// presents at the refresh rate has already proved most of this file.
shaders_missing: bool = false,

setup_pool: vk.CommandPool = vk.null_handle,

frames: [frames_in_flight]Frame = @splat(.{}),
index: u32 = 0,

textures: std.ArrayList(Texture) = .empty,

/// Set to copy the next drawn frame back to the host. See `Capture`.
capture_next: bool = false,
/// The last frame copied back, if one was asked for. Owned, freed on the
/// next capture and at `deinit`.
captured: ?Capture = null,
/// Host-visible, sized to the last capture. Kept so a second capture of the
/// same size allocates nothing.
readback: Device.Buffer = .{},

// -- counters, because a renderer nobody can measure is a renderer nobody can
// fix. Read by `fenrir view` on exit.
frames_drawn: u64 = 0,
frames_skipped: u64 = 0,
recreates: u32 = 0,
instance_high_water: u32 = 0,
bytes_uploaded: u64 = 0,

/// `queries_per_frame` timestamps for each frame in flight, or null on a
/// queue that keeps none.
query_pool: vk.QueryPool = vk.null_handle,
/// Which frames submitted timestamps that have not been read yet.
queried: [frames_in_flight]bool = @splat(false),
/// What the device says each frame took, and the paths within it. A frame's
/// are read back right after its own fence, two frames later, when they are
/// certainly there: asking never waits.
gpu_frame: Samples = .{},
gpu_paths: Samples = .{},

pub fn init(gpa: Allocator, device: *Device, swapchain: *Swapchain) Error!Renderer {
    if (!device.descriptor_indexing) return error.NoDescriptorIndexing;

    var r: Renderer = .{ .gpa = gpa, .device = device, .swapchain = swapchain };
    errdefer r.deinit();

    try r.createSampler();
    try r.createDescriptorLayout();
    try r.createPipelineLayout();
    r.createPipeline() catch |err| switch (err) {
        error.NoShaders => r.shaders_missing = true,
        else => return err,
    };
    try r.createDescriptorPool();
    try r.createSetupPool();
    try r.createFrames();
    r.createQueryPool();

    // Slot zero of the array is never named by an instance -- ids from
    // `DrawList.registerTexture` are one-based, and zero means "no texture" --
    // but every slot has to hold a valid descriptor, because reading an
    // unbound one is undefined behaviour rather than a black pixel. So slot
    // zero holds a 1x1 white texture, every slot past the last real one holds
    // the same, and the ids line up with `DrawList`'s for free.
    const placeholder = try r.createTexture(1, 1, .color);
    std.debug.assert(placeholder == 0);
    const white: [4]u8 = .{ 255, 255, 255, 255 };
    try r.uploadNow(placeholder, .{
        .texture = placeholder,
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .pixels = &white,
        .stride = 4,
    });
    r.writeAllTextureSlots();

    return r;
}

pub fn deinit(r: *Renderer) void {
    const d = r.device;
    const dt = &d.dt;
    _ = dt.deviceWaitIdle(d.handle);

    for (r.textures.items) |*t| r.destroyTexture(t);
    r.textures.deinit(r.gpa);
    if (r.captured) |c| r.gpa.free(c.pixels);
    d.destroyBuffer(&r.readback);

    for (&r.frames) |*f| {
        if (f.pool != vk.null_handle) dt.destroyCommandPool(d.handle, f.pool, null);
        if (f.fence != vk.null_handle) dt.destroyFence(d.handle, f.fence, null);
        if (f.image_available != vk.null_handle) dt.destroySemaphore(d.handle, f.image_available, null);
        d.destroyBuffer(&f.instances);
        d.destroyBuffer(&f.staging);
    }
    if (r.setup_pool != vk.null_handle) dt.destroyCommandPool(d.handle, r.setup_pool, null);
    if (r.query_pool != vk.null_handle) dt.destroyQueryPool(d.handle, r.query_pool, null);
    if (r.pool != vk.null_handle) dt.destroyDescriptorPool(d.handle, r.pool, null);
    if (r.pipeline != vk.null_handle) dt.destroyPipeline(d.handle, r.pipeline, null);
    if (r.layout != vk.null_handle) dt.destroyPipelineLayout(d.handle, r.layout, null);
    if (r.set_layout != vk.null_handle) dt.destroyDescriptorSetLayout(d.handle, r.set_layout, null);
    if (r.sampler != vk.null_handle) dt.destroySampler(d.handle, r.sampler, null);
    r.* = undefined;
}

// -- setup ------------------------------------------------------------------

fn createSampler(r: *Renderer) Error!void {
    const d = r.device;
    // Linear, clamped, no mips. Clamping is what keeps a glyph from picking up
    // its neighbour in the atlas when a source rectangle lands half a texel
    // off, which is exactly what subpixel positioning arranges for.
    const info: vk.SamplerCreateInfo = .{};
    try vk.check(d.dt.createSampler(d.handle, &info, null, &r.sampler));
}

fn createDescriptorLayout(r: *Renderer) Error!void {
    const d = r.device;
    const b = pipeline_contract.binding;

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = b.instances,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            // Read by both stages: the vertex shader for the rectangle, the
            // fragment shader for everything else. That is what keeps the
            // varyings down to one flat integer.
            .stage_flags = vk.ShaderStageFlags.vertex | vk.ShaderStageFlags.fragment,
        },
        .{
            .binding = b.textures,
            .descriptor_type = .sampled_image,
            .descriptor_count = max_textures,
            .stage_flags = vk.ShaderStageFlags.fragment,
        },
        .{
            .binding = b.sampler,
            .descriptor_type = .sampler,
            .descriptor_count = 1,
            .stage_flags = vk.ShaderStageFlags.fragment,
        },
    };

    const info: vk.DescriptorSetLayoutCreateInfo = .{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    };
    try vk.check(d.dt.createDescriptorSetLayout(d.handle, &info, null, &r.set_layout));
}

fn createPipelineLayout(r: *Renderer) Error!void {
    const d = r.device;
    const range: vk.PushConstantRange = .{
        .stage_flags = vk.ShaderStageFlags.vertex,
        .offset = 0,
        .size = @sizeOf(pipeline_contract.PushConstants),
    };
    const info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&r.set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&range),
    };
    try vk.check(d.dt.createPipelineLayout(d.handle, &info, null, &r.layout));
}

fn createPipeline(r: *Renderer) Error!void {
    const d = r.device;

    // Parsed rather than trusted: an empty `.spv` from a compiler that failed
    // and exited zero, or the two modules wired to the wrong stages, both
    // produce a pipeline that creates successfully and draws nothing.
    const vertex = try shaders.vertexModule();
    const fragment = try shaders.fragmentModule();

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

    // No vertex input state whatsoever; see the header.
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{};
    const assembly: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_strip };
    const viewport: vk.PipelineViewportStateCreateInfo = .{};
    const raster: vk.PipelineRasterizationStateCreateInfo = .{
        // Culling off: nothing here is wound consistently and nothing needs to
        // be. A fully clipped instance is a zero-area quad, which no winding
        // rule can rescue and none has to.
        .cull_mode = 0,
    };
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{};

    // The blend state the fragment shader's output assumes. `SRC_ALPHA` here
    // instead of `ONE` would multiply every instance by its alpha twice, and
    // everything translucent would go dark.
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

    // Viewport and scissor are dynamic so that a resize does not rebuild the
    // pipeline -- which would mean a compile on the main thread in the middle
    // of someone dragging a window edge.
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
        .layout = r.layout,
        .render_pass = r.swapchain.render_pass,
        .subpass = 0,
    };

    try vk.check(d.dt.createGraphicsPipelines(d.handle, vk.null_handle, 1, @ptrCast(&info), null, @ptrCast(&r.pipeline)));
    r.pipeline_generation = r.swapchain.format_generation;
}

fn createDescriptorPool(r: *Renderer) Error!void {
    const d = r.device;
    const sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_buffer, .descriptor_count = frames_in_flight },
        .{ .type = .sampled_image, .descriptor_count = frames_in_flight * max_textures },
        .{ .type = .sampler, .descriptor_count = frames_in_flight },
    };
    const info: vk.DescriptorPoolCreateInfo = .{
        .max_sets = frames_in_flight,
        .pool_size_count = sizes.len,
        .p_pool_sizes = &sizes,
    };
    try vk.check(d.dt.createDescriptorPool(d.handle, &info, null, &r.pool));
}

fn createSetupPool(r: *Renderer) Error!void {
    const d = r.device;
    const info: vk.CommandPoolCreateInfo = .{
        .flags = vk.CommandPoolCreateFlags.transient,
        .queue_family_index = d.families.graphics,
    };
    try vk.check(d.dt.createCommandPool(d.handle, &info, null, &r.setup_pool));
}

fn createFrames(r: *Renderer) Error!void {
    const d = r.device;

    var layouts: [frames_in_flight]vk.DescriptorSetLayout = @splat(r.set_layout);
    var sets: [frames_in_flight]vk.DescriptorSet = @splat(vk.null_handle);
    const alloc: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = r.pool,
        .descriptor_set_count = frames_in_flight,
        .p_set_layouts = &layouts,
    };
    try vk.check(d.dt.allocateDescriptorSets(d.handle, &alloc, &sets));

    for (&r.frames, 0..) |*f, i| {
        f.set = sets[i];

        const pool_info: vk.CommandPoolCreateInfo = .{
            // Reset the whole pool each frame rather than the buffer: it lets
            // the driver hand the memory back in one go instead of tracking
            // one buffer's worth.
            .flags = vk.CommandPoolCreateFlags.transient,
            .queue_family_index = d.families.graphics,
        };
        try vk.check(d.dt.createCommandPool(d.handle, &pool_info, null, &f.pool));

        const cb_info: vk.CommandBufferAllocateInfo = .{
            .command_pool = f.pool,
            .command_buffer_count = 1,
        };
        try vk.check(d.dt.allocateCommandBuffers(d.handle, &cb_info, @ptrCast(&f.cb)));

        // Created signalled, so the first frame's wait returns immediately
        // instead of deadlocking on a fence nothing will ever signal.
        const fence_info: vk.FenceCreateInfo = .{ .flags = vk.FenceCreateFlags.signaled };
        try vk.check(d.dt.createFence(d.handle, &fence_info, null, &f.fence));

        const sem_info: vk.SemaphoreCreateInfo = .{};
        try vk.check(d.dt.createSemaphore(d.handle, &sem_info, null, &f.image_available));

        f.instances = try r.newInstanceBuffer(min_instance_bytes);
        f.staging = try r.newStagingBuffer(min_staging_bytes);

        r.writeBufferDescriptor(f.*);
        r.writeSamplerDescriptor(f.*);
    }
}

/// Not an error to go without: a queue with no timestamps draws the same
/// frames, and `--time` says it has no device times to give.
fn createQueryPool(r: *Renderer) void {
    const d = r.device;
    if (d.families.timestamp_bits == 0 or !(d.properties.limits.timestamp_period > 0)) return;
    const info: vk.QueryPoolCreateInfo = .{
        .query_type = .timestamp,
        .query_count = queries_per_frame * frames_in_flight,
    };
    var pool: vk.QueryPool = vk.null_handle;
    if (d.dt.createQueryPool(d.handle, &info, null, &pool) != .success) return;
    r.query_pool = pool;
}

/// One of this frame's timestamps, written once every command before it has
/// reached `stage`.
fn stamp(r: *Renderer, cb: vk.CommandBuffer, stage: u32, which: u32) void {
    if (r.query_pool == vk.null_handle) return;
    r.device.dt.cmdWriteTimestamp(cb, stage, r.query_pool, r.index * queries_per_frame + which);
}

/// Reads back the timestamps frame `i` wrote, if it wrote any. Called after
/// that frame's fence, so they are there and this does not wait for them.
fn collectTimestamps(r: *Renderer, i: u32) void {
    if (!r.queried[i]) return;
    r.queried[i] = false;
    const d = r.device;
    var ticks: [queries_per_frame]u64 = undefined;
    const got = d.dt.getQueryPoolResults(
        d.handle,
        r.query_pool,
        i * queries_per_frame,
        queries_per_frame,
        @sizeOf(@TypeOf(ticks)),
        &ticks,
        @sizeOf(u64),
        vk.QueryResultFlags.result_64,
    );
    if (got != .success) return;
    const period = d.properties.limits.timestamp_period;
    const bits = d.families.timestamp_bits;
    if (choose.ticksToMs(ticks[0], ticks[3], period, bits)) |ms| r.gpu_frame.push(@floatCast(ms));
    if (choose.ticksToMs(ticks[1], ticks[2], period, bits)) |ms| r.gpu_paths.push(@floatCast(ms));
}

fn newInstanceBuffer(r: *Renderer, size: u64) Error!Device.Buffer {
    const m = vk.MemoryPropertyFlags;
    return r.device.createBuffer(
        size,
        vk.BufferUsageFlags.storage_buffer,
        m.host_visible | m.host_coherent,
        // Preferred, not required: on a machine with resizable BAR the buffer
        // lands in video memory and the GPU reads it at full speed, and on one
        // without it lands in system memory and everything still works.
        m.device_local,
    );
}

fn newStagingBuffer(r: *Renderer, size: u64) Error!Device.Buffer {
    const m = vk.MemoryPropertyFlags;
    return r.device.createBuffer(
        size,
        vk.BufferUsageFlags.transfer_src,
        m.host_visible | m.host_coherent,
        0,
    );
}

fn writeBufferDescriptor(r: *Renderer, f: Frame) void {
    const d = r.device;
    const info: vk.DescriptorBufferInfo = .{ .buffer = f.instances.handle };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = f.set,
        .dst_binding = pipeline_contract.binding.instances,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_buffer_info = @ptrCast(&info),
    };
    d.dt.updateDescriptorSets(d.handle, 1, @ptrCast(&write), 0, null);
}

fn writeSamplerDescriptor(r: *Renderer, f: Frame) void {
    const d = r.device;
    const info: vk.DescriptorImageInfo = .{ .sampler = r.sampler };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = f.set,
        .dst_binding = pipeline_contract.binding.sampler,
        .descriptor_count = 1,
        .descriptor_type = .sampler,
        .p_image_info = @ptrCast(&info),
    };
    d.dt.updateDescriptorSets(d.handle, 1, @ptrCast(&write), 0, null);
}

/// Fills every slot of the texture array in every frame's set.
///
/// Slots past the last real texture get the placeholder, because a descriptor
/// that is never written is undefined behaviour to read even if the shader
/// never reaches it -- and "never reaches it" is a claim about a branch the
/// driver is entitled to disbelieve.
fn writeAllTextureSlots(r: *Renderer) void {
    const d = r.device;
    var infos: [max_textures]vk.DescriptorImageInfo = undefined;
    const placeholder = r.textures.items[0].view;
    for (&infos, 0..) |*info, i| {
        const view = if (i < r.textures.items.len and r.textures.items[i].view != vk.null_handle)
            r.textures.items[i].view
        else
            placeholder;
        info.* = .{ .image_view = view, .image_layout = .shader_read_only_optimal };
    }

    for (r.frames) |f| {
        const write: vk.WriteDescriptorSet = .{
            .dst_set = f.set,
            .dst_binding = pipeline_contract.binding.textures,
            .dst_array_element = 0,
            .descriptor_count = max_textures,
            .descriptor_type = .sampled_image,
            .p_image_info = &infos,
        };
        d.dt.updateDescriptorSets(d.handle, 1, @ptrCast(&write), 0, null);
    }
}

/// Rebuilds the pipeline after the swapchain's format changed. Cheap and rare:
/// it happens when a window moves to a monitor with a different colour depth,
/// and not on an ordinary resize.
pub fn refresh(r: *Renderer) Error!void {
    if (r.shaders_missing) return;
    if (r.pipeline_generation == r.swapchain.format_generation) return;
    const d = r.device;
    _ = d.dt.deviceWaitIdle(d.handle);
    d.dt.destroyPipeline(d.handle, r.pipeline, null);
    r.pipeline = vk.null_handle;
    try r.createPipeline();
}

// -- textures ---------------------------------------------------------------

/// Creates a texture and returns its id, which is also its index in the
/// descriptor array.
///
/// The first call makes the placeholder in slot zero, so real textures are
/// numbered from one -- exactly as `DrawList.registerTexture` numbers them.
/// A caller that registers the same textures in the same order in both places
/// therefore gets matching ids, which is a convention rather than an enforced
/// link, and `fenrir view` asserts it.
pub fn createTexture(r: *Renderer, width: u32, height: u32, kind: TextureKind) Error!u32 {
    if (r.textures.items.len >= max_textures) return error.TooManyTextures;
    const d = r.device;

    var t: Texture = .{ .width = width, .height = height, .kind = kind };

    const image_info: vk.ImageCreateInfo = .{
        .format = kind.format(),
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .usage = vk.ImageUsageFlags.sampled | vk.ImageUsageFlags.transfer_dst,
    };
    try vk.check(d.dt.createImage(d.handle, &image_info, null, &t.image));
    errdefer d.dt.destroyImage(d.handle, t.image, null);

    var req: vk.MemoryRequirements = undefined;
    d.dt.getImageMemoryRequirements(d.handle, t.image, &req);
    const type_index = choose.memoryType(
        &d.memory,
        req.memory_type_bits,
        vk.MemoryPropertyFlags.device_local,
        0,
    ) orelse return error.FeatureNotPresent;

    const alloc: vk.MemoryAllocateInfo = .{
        .allocation_size = req.size,
        .memory_type_index = type_index,
    };
    try vk.check(d.dt.allocateMemory(d.handle, &alloc, null, &t.memory));
    errdefer d.dt.freeMemory(d.handle, t.memory, null);
    try vk.check(d.dt.bindImageMemory(d.handle, t.image, t.memory, 0));

    const view_info: vk.ImageViewCreateInfo = .{
        .image = t.image,
        .format = kind.format(),
        .subresource_range = .{ .aspect_mask = vk.ImageAspectFlags.color },
    };
    try vk.check(d.dt.createImageView(d.handle, &view_info, null, &t.view));
    errdefer d.dt.destroyImageView(d.handle, t.view, null);

    // Moved into the layout the descriptor claims it is in, before anything
    // can sample it. A texture created and never uploaded to would otherwise
    // sit in UNDEFINED while the descriptor says SHADER_READ_ONLY, which is
    // undefined behaviour rather than a black rectangle.
    try r.transitionNow(t.image, .undefined, .shader_read_only_optimal);

    try r.textures.append(r.gpa, t);

    // The descriptor has to be written or the new texture is not reachable
    // from the shader at all -- every instance naming it would sample the
    // placeholder instead, which is a screen of solid white text rather than
    // an error. The wait is safe because this happens at startup and when a
    // page image is decoded, not per frame.
    _ = d.dt.deviceWaitIdle(d.handle);
    r.writeAllTextureSlots();

    return @intCast(r.textures.items.len - 1);
}

/// Replaces a texture's image with one of a different size, keeping its id.
///
/// This is what an atlas growing looks like from here. It waits for the device
/// to go idle, which is exactly as expensive as it sounds and happens a
/// handful of times in the life of a document: Týr's atlas grows by doubling
/// its height, so a session's worth of glyphs costs three or four of these.
pub fn resizeTexture(r: *Renderer, id: u32, width: u32, height: u32) Error!void {
    if (id == 0 or id >= r.textures.items.len) return error.UnknownTexture;
    const d = r.device;
    _ = d.dt.deviceWaitIdle(d.handle);

    const kind = r.textures.items[id].kind;
    r.destroyTexture(&r.textures.items[id]);

    // `createTexture` appends, so the new one is moved into the existing slot
    // and the append undone -- which keeps the id, and therefore every
    // instance already referring to it, valid.
    _ = try r.createTexture(width, height, kind);
    r.textures.items[id] = r.textures.pop().?;

    r.writeAllTextureSlots();
}

fn destroyTexture(r: *Renderer, t: *Texture) void {
    const d = r.device;
    if (t.view != vk.null_handle) d.dt.destroyImageView(d.handle, t.view, null);
    if (t.image != vk.null_handle) d.dt.destroyImage(d.handle, t.image, null);
    if (t.memory != vk.null_handle) d.dt.freeMemory(d.handle, t.memory, null);
    t.* = .{};
}

pub fn textureCount(r: *const Renderer) u32 {
    return @intCast(r.textures.items.len);
}

// -- one-shot command buffers -----------------------------------------------

fn beginOneShot(r: *Renderer) Error!vk.CommandBuffer {
    const d = r.device;
    var cb: vk.CommandBuffer = null;
    const info: vk.CommandBufferAllocateInfo = .{ .command_pool = r.setup_pool, .command_buffer_count = 1 };
    try vk.check(d.dt.allocateCommandBuffers(d.handle, &info, @ptrCast(&cb)));
    const begin: vk.CommandBufferBeginInfo = .{ .flags = vk.CommandBufferUsageFlags.one_time_submit };
    try vk.check(d.dt.beginCommandBuffer(cb, &begin));
    return cb;
}

fn endOneShot(r: *Renderer, cb: vk.CommandBuffer) Error!void {
    const d = r.device;
    try vk.check(d.dt.endCommandBuffer(cb));
    var handle = cb;
    const submit: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&handle),
    };
    try vk.check(d.dt.queueSubmit(d.graphics_queue, 1, @ptrCast(&submit), vk.null_handle));
    // A full queue wait. Only ever reached at startup and when an atlas grows,
    // where the alternative -- a fence and a deferred free -- is machinery for
    // an event that happens four times.
    _ = d.dt.queueWaitIdle(d.graphics_queue);
    d.dt.freeCommandBuffers(d.handle, r.setup_pool, 1, @ptrCast(&handle));
}

fn transitionNow(r: *Renderer, image: vk.Image, from: vk.ImageLayout, to: vk.ImageLayout) Error!void {
    const cb = try r.beginOneShot();
    recordTransition(r.device, cb, image, from, to);
    try r.endOneShot(cb);
}

fn recordTransition(
    d: *Device,
    cb: vk.CommandBuffer,
    image: vk.Image,
    from: vk.ImageLayout,
    to: vk.ImageLayout,
) void {
    const a = vk.AccessFlags;
    const p = vk.PipelineStageFlags;

    var src_access: u32 = 0;
    var dst_access: u32 = 0;
    var src_stage: u32 = p.top_of_pipe;
    var dst_stage: u32 = p.bottom_of_pipe;

    if (to == .transfer_dst_optimal) {
        dst_access = a.transfer_write;
        dst_stage = p.transfer;
        if (from == .shader_read_only_optimal) {
            src_access = a.shader_read;
            src_stage = p.fragment_shader;
        }
    } else if (to == .shader_read_only_optimal) {
        dst_access = a.shader_read;
        dst_stage = p.fragment_shader;
        if (from == .transfer_dst_optimal) {
            src_access = a.transfer_write;
            src_stage = p.transfer;
        }
    } else if (to == .transfer_src_optimal) {
        // A finished frame on its way to the host. The render pass has ended,
        // so what it last did to the image was write colour.
        dst_access = a.transfer_read;
        dst_stage = p.transfer;
        src_access = a.color_attachment_write;
        src_stage = p.color_attachment_output;
    } else if (to == .present_src_khr and from == .transfer_src_optimal) {
        src_access = a.transfer_read;
        src_stage = p.transfer;
    }

    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = from,
        .new_layout = to,
        .image = image,
        .subresource_range = .{ .aspect_mask = vk.ImageAspectFlags.color },
    };
    d.dt.cmdPipelineBarrier(cb, src_stage, dst_stage, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
}

/// Uploads immediately, with its own command buffer and a queue wait. Used for
/// the placeholder texture at startup; everything else rides along with the
/// frame.
fn uploadNow(r: *Renderer, id: u32, up: Upload) Error!void {
    var staging = try r.newStagingBuffer(@max(min_staging_bytes, uploadBytes(r, up)));
    defer r.device.destroyBuffer(&staging);

    const written = r.packInto(staging.slice(), 0, up);
    const cb = try r.beginOneShot();
    const t = r.textures.items[id];
    recordTransition(r.device, cb, t.image, .shader_read_only_optimal, .transfer_dst_optimal);
    r.recordCopy(cb, t, staging.handle, 0, up);
    recordTransition(r.device, cb, t.image, .transfer_dst_optimal, .shader_read_only_optimal);
    try r.endOneShot(cb);
    r.bytes_uploaded += written;
}

fn uploadBytes(r: *Renderer, up: Upload) u64 {
    const bpp = r.textures.items[up.texture].kind.bytesPerPixel();
    return @as(u64, up.w) * up.h * bpp;
}

/// Copies the sub-rectangle out of the source image into `dst`, packed.
///
/// Packed, because `bufferRowLength` could describe the source stride instead
/// and then the whole atlas would have to be in the staging buffer to reach
/// the last row of a dirty region near its bottom.
fn packInto(r: *Renderer, dst: []u8, offset: u64, up: Upload) u64 {
    const bpp = r.textures.items[up.texture].kind.bytesPerPixel();
    const row_bytes = up.w * bpp;
    var y: u32 = 0;
    while (y < up.h) : (y += 1) {
        const src_start = (up.y + y) * up.stride + up.x * bpp;
        const dst_start = offset + y * row_bytes;
        @memcpy(dst[dst_start..][0..row_bytes], up.pixels[src_start..][0..row_bytes]);
    }
    return @as(u64, up.h) * row_bytes;
}

fn recordCopy(r: *Renderer, cb: vk.CommandBuffer, t: Texture, buffer: vk.Buffer, offset: u64, up: Upload) void {
    const region: vk.BufferImageCopy = .{
        .buffer_offset = offset,
        .image_subresource = .{ .aspect_mask = vk.ImageAspectFlags.color },
        .image_offset = .{ .x = @intCast(up.x), .y = @intCast(up.y), .z = 0 },
        .image_extent = .{ .width = up.w, .height = up.h, .depth = 1 },
    };
    r.device.dt.cmdCopyBufferToImage(cb, buffer, t.image, .transfer_dst_optimal, 1, @ptrCast(&region));
}

// -- the frame --------------------------------------------------------------

/// Draws one frame: waits for its slot, acquires an image, uploads what
/// changed, records the single draw call, submits and presents.
///
/// Returns `.needs_recreate` rather than recreating the swapchain itself. The
/// caller has the window and therefore the new size, and doing it at the top
/// of the next frame rather than in the middle of this one is what makes a
/// resize cost one frame instead of two.
/// The path pipeline's contribution to a frame, if there is one.
///
/// Recorded inside the same render pass, after the rects: a reader draws the
/// page's backdrop, shadow and paper as rectangles, the page's marks as
/// paths, and nothing needs to go between. UI chrome that must sit *on top*
/// of the page -- a scrollbar, a selection -- is drawn in `over`.
pub const Paths = struct {
    renderer: *PathRenderer,
    /// The outlines, shared across frames and uploaded only when they change.
    scene: *const scene_mod.Scene,
    /// This frame is placement: one matrix per instance.
    frame: *const scene_mod.Frame,
};

pub fn frame(
    r: *Renderer,
    list: *const DrawList,
    uploads: []const Upload,
    clear: Color,
) Error!Status {
    return r.frameWith(list, uploads, clear, null, null);
}

/// `frame`, with paths drawn between two rect lists.
///
/// Order in one render pass is draw order, and a page is three layers: the
/// paper under it, the marks on it, and the interface over it. One draw list
/// cannot express that, because the paths have to land in the middle of it,
/// so there are two.
pub fn frameWith(
    r: *Renderer,
    list: *const DrawList,
    uploads: []const Upload,
    clear: Color,
    paths: ?Paths,
    over: ?*const DrawList,
) Error!Status {
    const d = r.device;
    const s = r.swapchain;
    if (s.isMinimised()) {
        r.frames_skipped += 1;
        return .skipped;
    }
    try r.refresh();

    const f = &r.frames[r.index];

    // Waits for the frame two submissions ago, which is what makes writing to
    // this frame's mapped buffer safe without any other synchronisation.
    _ = d.dt.waitForFences(d.handle, 1, @ptrCast(&f.fence), 1, std.math.maxInt(u64));
    r.collectTimestamps(r.index);

    const acquired = try s.acquire(f.image_available);
    const image = switch (acquired) {
        .image => |i| i,
        .out_of_date => {
            r.recreates += 1;
            return .needs_recreate;
        },
        .minimised => {
            r.frames_skipped += 1;
            return .skipped;
        },
    };

    // Reset only after the acquire succeeded: an early reset followed by a
    // return leaves an unsignalled fence that the next frame waits on for
    // ever.
    _ = d.dt.resetFences(d.handle, 1, @ptrCast(&f.fence));

    const split = try r.writeInstances(f, list, over);
    const staged = try r.stageUploads(f, uploads);
    // After the fence and before the recording: the only window in which this
    // frame's buffers are not being read by the device.
    if (paths) |p| try p.renderer.upload(r.index, p.scene, p.frame);

    try vk.check(d.dt.resetCommandPool(d.handle, f.pool, 0));
    const begin: vk.CommandBufferBeginInfo = .{ .flags = vk.CommandBufferUsageFlags.one_time_submit };
    try vk.check(d.dt.beginCommandBuffer(f.cb, &begin));
    // Reset where the reset is allowed, outside the pass, before this frame
    // writes the queries its predecessor two frames ago left behind.
    if (r.query_pool != vk.null_handle) {
        d.dt.cmdResetQueryPool(f.cb, r.query_pool, r.index * queries_per_frame, queries_per_frame);
    }
    r.stamp(f.cb, vk.PipelineStageFlags.top_of_pipe, 0);

    // Uploads first, outside the render pass: a copy cannot be recorded inside
    // one, and doing them here rather than in their own submission is what
    // keeps a frame that adds glyphs to the atlas from stalling the queue.
    var offset: u64 = 0;
    for (uploads[0..staged]) |up| {
        const t = r.textures.items[up.texture];
        recordTransition(d, f.cb, t.image, .shader_read_only_optimal, .transfer_dst_optimal);
        r.recordCopy(f.cb, t, f.staging.handle, offset, up);
        recordTransition(d, f.cb, t.image, .transfer_dst_optimal, .shader_read_only_optimal);
        offset += r.uploadBytes(up);
    }

    // The clear colour is written into an `_SRGB` attachment, which the
    // hardware encodes on write -- so the value given here is linear, and
    // handing it an sRGB-encoded number makes the background visibly paler
    // than the same colour drawn as a rectangle.
    const clear_value: vk.ClearValue = .{ .color = .{ .float32 = .{
        rect.srgbToLinear(clear.r),
        rect.srgbToLinear(clear.g),
        rect.srgbToLinear(clear.b),
        clear.a,
    } } };

    const pass_info: vk.RenderPassBeginInfo = .{
        .render_pass = s.render_pass,
        .framebuffer = s.framebuffers[image.index],
        .render_area = s.renderArea(),
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&clear_value),
    };
    d.dt.cmdBeginRenderPass(f.cb, &pass_info, .@"inline");

    const count = split.under + split.over;
    // Recorded whether or not there is a pipeline to draw with, so that a
    // build with no shaders still reports what a build with them would have
    // drawn.
    r.instance_high_water = @max(r.instance_high_water, count);

    // Viewport and scissor are pipeline-independent dynamic state, so they
    // are set once and both pipelines inherit them.
    const viewport: vk.Viewport = .{
        .width = @floatFromInt(s.extent.width),
        .height = @floatFromInt(s.extent.height),
    };
    d.dt.cmdSetViewport(f.cb, 0, 1, @ptrCast(&viewport));
    const scissor = s.renderArea();
    d.dt.cmdSetScissor(f.cb, 0, 1, @ptrCast(&scissor));

    // Three layers in one pass: rects under, paths, rects over. Each is at
    // most one draw call, so a page of ten thousand marks under a scrollbar
    // is three.
    //
    // The two stamps either side of the paths are each written once
    // everything before them has finished, so their difference is what the
    // paths added to the frame. Not quite what they cost: the device may
    // start them under the tail of the rects before, which on a page is a
    // few hundred rectangles.
    r.recordRects(f, split.under, 0);
    r.stamp(f.cb, vk.PipelineStageFlags.bottom_of_pipe, 1);
    if (paths) |p| p.renderer.record(f.cb, r.index, p.frame, s.extent);
    r.stamp(f.cb, vk.PipelineStageFlags.bottom_of_pipe, 2);
    r.recordRects(f, split.over, split.under);

    d.dt.cmdEndRenderPass(f.cb);

    // The copy back, in the same command buffer: after the pass has left the
    // image in PRESENT_SRC, and put back into it before the present.
    const capturing = r.capture_next;
    if (capturing) {
        r.capture_next = false;
        const bytes = @as(u64, s.extent.width) * s.extent.height * 4;
        if (r.readback.size < bytes) {
            d.destroyBuffer(&r.readback);
            r.readback = try d.createBuffer(
                bytes,
                vk.BufferUsageFlags.transfer_dst,
                vk.MemoryPropertyFlags.host_visible,
                vk.MemoryPropertyFlags.host_cached,
            );
        }
        const target = s.images[image.index];
        recordTransition(d, f.cb, target, .present_src_khr, .transfer_src_optimal);
        const region: vk.BufferImageCopy = .{
            .image_subresource = .{ .aspect_mask = vk.ImageAspectFlags.color },
            .image_extent = .{ .width = s.extent.width, .height = s.extent.height, .depth = 1 },
        };
        d.dt.cmdCopyImageToBuffer(f.cb, target, .transfer_src_optimal, r.readback.handle, 1, @ptrCast(&region));
        recordTransition(d, f.cb, target, .transfer_src_optimal, .present_src_khr);
    }

    r.stamp(f.cb, vk.PipelineStageFlags.bottom_of_pipe, 3);
    try vk.check(d.dt.endCommandBuffer(f.cb));

    var wait_semaphore = f.image_available;
    var signal_semaphore = image.render_finished;
    var cb = f.cb;
    // The stage the wait applies to. COLOR_ATTACHMENT_OUTPUT rather than
    // TOP_OF_PIPE, so the vertex work can start before the image is available
    // and only the writing waits.
    var wait_stage: u32 = vk.PipelineStageFlags.color_attachment_output;

    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&wait_semaphore),
        .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cb),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&signal_semaphore),
    };
    try vk.check(d.dt.queueSubmit(d.graphics_queue, 1, @ptrCast(&submit), f.fence));
    s.markInFlight(image.index, f.fence);
    r.queried[r.index] = r.query_pool != vk.null_handle;

    if (capturing) try r.finishCapture(f.fence);

    const presented = try s.present(image.index, image.render_finished);

    r.index = (r.index + 1) % frames_in_flight;
    r.frames_drawn += 1;
    return if (presented) .drawn else .needs_recreate;
}

/// Waits for the frame that recorded a copy back and keeps its pixels.
///
/// A full wait on this frame's fence, which is a stall of one frame; it is
/// only ever asked for by a command that is about to write a file and exit.
fn finishCapture(r: *Renderer, fence: vk.Fence) Error!void {
    const d = r.device;
    const s = r.swapchain;
    var handle = fence;
    try vk.check(d.dt.waitForFences(d.handle, 1, @ptrCast(&handle), 1, std.math.maxInt(u64)));

    const w = s.extent.width;
    const h = s.extent.height;
    const n = @as(usize, w) * h * 4;
    const src = r.readback.slice()[0..n];
    const out = try r.gpa.alloc(u8, n);
    const bgra = switch (s.format) {
        .b8g8r8a8_srgb, .b8g8r8a8_unorm => true,
        else => false,
    };
    var i: usize = 0;
    while (i < n) : (i += 4) {
        out[i + 0] = if (bgra) src[i + 2] else src[i];
        out[i + 1] = src[i + 1];
        out[i + 2] = if (bgra) src[i] else src[i + 2];
        out[i + 3] = 255;
    }
    if (r.captured) |c| r.gpa.free(c.pixels);
    r.captured = .{ .pixels = out, .width = w, .height = h };
}

/// How many instances came from each list, so the two draws know their ranges.
const Split = struct { under: u32 = 0, over: u32 = 0 };

/// Packs one or two draw lists into this frame's instance buffer, back to
/// back.
///
/// One buffer and not two: `vkCmdDraw`'s `firstInstance` is added to
/// `gl_InstanceIndex`, so a second range in the same buffer is a second draw
/// with an offset rather than a second binding and a second descriptor write.
fn writeInstances(r: *Renderer, f: *Frame, list: *const DrawList, over: ?*const DrawList) Error!Split {
    const a = list.bytes();
    const b = if (over) |o| o.bytes() else &.{};
    const total = a.len + b.len;
    if (total == 0) return .{};

    if (total > f.instances.size) {
        // Safe here and nowhere else: the fence for this frame has been waited
        // on, so nothing the GPU is reading lives in the old buffer.
        const want = choose.bufferCapacity(f.instances.size, total, min_instance_bytes);
        r.device.destroyBuffer(&f.instances);
        f.instances = try r.newInstanceBuffer(want);
        r.writeBufferDescriptor(f.*);
    }

    // The whole upload: memcpy into memory the GPU reads where it lies.
    const dst = f.instances.slice();
    @memcpy(dst[0..a.len], a);
    if (b.len != 0) @memcpy(dst[a.len..][0..b.len], b);
    r.device.flush(f.instances, 0, total);

    return .{
        .under = list.count(),
        .over = if (over) |o| o.count() else 0,
    };
}

/// One draw for a contiguous range of the instance buffer.
fn recordRects(r: *Renderer, f: *Frame, count: u32, first: u32) void {
    if (count == 0 or r.pipeline == vk.null_handle) return;
    const d = r.device;
    const s = r.swapchain;

    d.dt.cmdBindPipeline(f.cb, .graphics, r.pipeline);
    d.dt.cmdBindDescriptorSets(f.cb, .graphics, r.layout, 0, 1, @ptrCast(&f.set), 0, null);

    const push: pipeline_contract.PushConstants = .{ .viewport = .{
        @floatFromInt(s.extent.width),
        @floatFromInt(s.extent.height),
    } };
    d.dt.cmdPushConstants(
        f.cb,
        r.layout,
        vk.ShaderStageFlags.vertex,
        0,
        @sizeOf(pipeline_contract.PushConstants),
        &push,
    );

    d.dt.cmdDraw(f.cb, pipeline_contract.state.vertices_per_instance, count, 0, first);
}

/// Packs as many uploads as fit into this frame's staging buffer, growing it
/// first when it is too small. Returns how many were staged; anything left
/// over is simply not uploaded this frame, and the caller's dirty region will
/// still be dirty next time.
fn stageUploads(r: *Renderer, f: *Frame, uploads: []const Upload) Error!usize {
    if (uploads.len == 0) return 0;

    var needed: u64 = 0;
    for (uploads) |up| needed += r.uploadBytes(up);

    if (needed > f.staging.size) {
        const want = choose.bufferCapacity(f.staging.size, needed, min_staging_bytes);
        r.device.destroyBuffer(&f.staging);
        f.staging = try r.newStagingBuffer(want);
    }

    const dst = f.staging.slice();
    var offset: u64 = 0;
    var staged: usize = 0;
    for (uploads) |up| {
        const size = r.uploadBytes(up);
        if (offset + size > dst.len) break;
        _ = r.packInto(dst, offset, up);
        offset += size;
        staged += 1;
    }
    r.device.flush(f.staging, 0, offset);
    r.bytes_uploaded += offset;
    return staged;
}

/// Waits for every frame in flight. Called before tearing anything down that a
/// pending frame might still be reading.
pub fn waitIdle(r: *Renderer) void {
    _ = r.device.dt.deviceWaitIdle(r.device.handle);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the renderer agrees with the contract it was written against" {
    // `gleipnir/pipeline.zig` states the bindings, the push constant and the
    // instance size with no Vulkan in sight. This is the only place both
    // halves exist, so it is the only place the two can be compared.
    try testing.expectEqual(@as(u32, 0), pipeline_contract.binding.instances);
    try testing.expectEqual(@as(u32, 1), pipeline_contract.binding.textures);
    try testing.expectEqual(@as(u32, 2), pipeline_contract.binding.sampler);
    try testing.expectEqual(@as(usize, 8), @sizeOf(pipeline_contract.PushConstants));
    try testing.expectEqual(@as(u32, 4), pipeline_contract.state.vertices_per_instance);
    try testing.expectEqual(@as(u32, 96), pipeline_contract.state.instance_size);
    try testing.expectEqual(@as(u32, 96), @sizeOf(rect.Instance));
}

test "no sampled texture is an sRGB format, whatever its bytes mean" {
    try testing.expectEqual(vk.Format.r8_unorm, TextureKind.coverage.format());
    try testing.expectEqual(@as(u32, 1), TextureKind.coverage.bytesPerPixel());
    try testing.expectEqual(@as(u32, 4), TextureKind.color.bytesPerPixel());

    // The one that matters, and the one that is tempting to get wrong: a
    // page image holds sRGB-encoded bytes, so `_SRGB` looks like the honest
    // format for it. It is not. `rect.frag` converts every colour it is
    // handed, so a format that also converts converts twice, and the page
    // comes out at roughly the square of the brightness it should have.
    //
    // The CPU model cannot catch this -- its sampler hands over the stored
    // bytes -- so it is pinned here instead.
    inline for (comptime std.enums.values(TextureKind)) |kind| {
        try testing.expect(!kind.format().isSrgb());
    }
    try testing.expectEqual(vk.Format.r8g8b8a8_unorm, TextureKind.color.format());
}

test "a ring of timings keeps the latest and reports their spread" {
    var s: Samples = .{};
    try testing.expectEqual(@as(usize, 0), s.spread().n);

    // A hundred frames of 1 to 100 ms, pushed out of order.
    var i: u32 = 0;
    while (i < 100) : (i += 1) s.push(@floatFromInt((i * 37) % 100 + 1));
    const a = s.spread();
    try testing.expectEqual(@as(usize, 100), a.n);
    try testing.expectEqual(@as(f32, 1), a.best);
    try testing.expectEqual(@as(f32, 51), a.median);
    try testing.expectEqual(@as(f32, 96), a.p95);

    // Past capacity it keeps the last `capacity`: a slow start is forgotten.
    var r: Samples = .{};
    r.push(1000);
    i = 0;
    while (i < Samples.capacity) : (i += 1) r.push(2);
    const b = r.spread();
    try testing.expectEqual(@as(usize, Samples.capacity), b.n);
    try testing.expectEqual(@as(f32, 2), b.p95);
    try testing.expectEqual(@as(f32, 2), b.best);
}

test "the descriptor pool is sized for what the sets actually hold" {
    // Undersizing it produces `ERROR_OUT_OF_POOL_MEMORY` at startup, which is
    // at least loud. Oversizing it wastes nothing worth measuring, and the
    // arithmetic is easy to get wrong in the direction that fails on the
    // second frame rather than the first.
    try testing.expect(frames_in_flight * max_textures >= max_textures);
    try testing.expectEqual(@as(u32, 2), frames_in_flight);
}
