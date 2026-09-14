//! Everything the Vulkan side of the analytic path pipeline has to agree
//! with, written down where it can be read without a device.
//!
//! The companion to `pipeline.zig` and `pathpipe.zig`, and the same bargain:
//! no Vulkan in this file, only the contract. `lyngvi/Renderer.zig` makes the
//! calls and has a test that compares the two, which is possible only there
//! because it is the only place in the project where both halves exist.
//!
//! ## Why this and not `pathpipe.zig`
//!
//! `pathpipe.zig` specifies stencil-and-cover, the classical way to fill a
//! path on a GPU: tessellate the outline into a fan, draw it into a stencil
//! attachment to accumulate winding numbers, then draw the bounding box with
//! a stencil test. It is written, it is correct, and it is not what this
//! renderer ended up using. Three things decided it:
//!
//! * **Two passes per path.** A page of four thousand glyphs is eight
//!   thousand draws with a pipeline bind between the halves. This is one draw
//!   for the whole page, instanced, exactly like the rect pipeline.
//! * **Antialiasing.** Stencil-and-cover has no subpixel information, so it
//!   needs a multisampled attachment: four or eight times the colour
//!   bandwidth, a resolve every frame, and coverage quantised to `samples +
//!   1` levels anyway. This computes coverage in closed form at one sample
//!   per pixel.
//! * **Clipping.** A stencil bit is in or out. An antialiased clip -- which
//!   PDF asks for on nearly every page with a figure on it -- needs either a
//!   second attachment or a jagged edge. Here a clip is another path
//!   evaluated by the same function, and intersecting clips is multiplying
//!   coverages.
//!
//! What stencil-and-cover has, and this does not, is a cost per fragment that
//! does not depend on the outline. This pays for every curve in the band a
//! fragment lands in. Bands keep that to a handful; a pathological path with
//! a thousand curves crossing one scanline would be slower here.
//!
//! `pathpipe.zig` stays because the CPU rasteriser is a model of it and the
//! two check each other, and because the comparison is the argument.
//!
//! ## The buffers
//!
//! Six storage buffers, all read-only, all in one descriptor set:
//!
//!     0  curves     the quadratics, in path space
//!     1  bands      slices of `indices`, one per row of a path
//!     2  indices    curve ids, grouped by band
//!     3  headers    one per uploaded outline
//!     4  instances  one per drawn path: which outline, where, what colour
//!     5  clips      the clip stack, as linked nodes
//!
//! The first four are `slug.Store` uploaded verbatim -- the Zig structs are
//! `extern` and the GLSL structs are their transcription, so it is a memcpy
//! and not a serialisation. The last two are built per frame.
//!
//! ## One draw
//!
//! `vkCmdDraw(cmd, 4, instances, 0, 0)` with a triangle strip. No vertex
//! buffer, no index buffer, no vertex attributes. The vertex shader builds
//! the path's device-space box from its header and the instance's matrix.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const rect = @import("rect.zig");
const slug = @import("slug.zig");

const Color = paint.Color;
const Transform = geom.Transform;

pub const vert_source = @embedFile("shader/slug.vert");
pub const frag_source = @embedFile("shader/slug.frag");
pub const shared_source = @embedFile("shader/slug.glsl");

/// How to turn the sources above into SPIR-V by hand.
///
/// Note `-I<dir>` attached: glslang rejects it as a separate argument, where
/// glslc requires it to be one.
pub const compile_command = "glslang -V --target-env vulkan1.2 -Isrc/gleipnir/shader";

/// Matches `layout(push_constant) uniform Push` in `shader/slug.glsl`.
///
/// Eight bytes, which is as small as a push constant range gets. Everything
/// else that used to live here -- the transform, the colour -- is per
/// instance now, because there is only one draw call and a push constant
/// cannot vary inside one.
pub const PushConstants = extern struct {
    viewport: [2]f32 = .{ 1, 1 },
};

/// Sentinel for `Instance.clip_node` and `ClipNode.parent`: no clip, or the
/// end of the chain.
pub const no_clip: u32 = std.math.maxInt(u32);

/// How many clips deep the fragment shader walks. Must equal
/// `MAX_CLIP_WALK` in `shader/slug.glsl`.
///
/// PDF clip stacks are one or two deep on a normal page and four on a busy
/// one. Eight is where a file that nests them pathologically stops costing
/// more than the correctness is worth; past it the innermost eight apply and
/// the rest are ignored, which shows too much rather than too little.
pub const max_clip_walk: u32 = 8;

/// One drawn path. Matches `struct Instance` in `shader/slug.glsl`.
///
/// Field order is chosen for std430 alignment rather than for reading: the
/// `vec4`s first so none of them needs padding in front of it, and the four
/// `uint`s packed into one sixteen-byte slot at the end.
pub const Instance = extern struct {
    /// `a`, `b`, `c`, `d` of path space to device pixels.
    xform: [4]f32 = .{ 1, 0, 0, 1 },
    /// `e`, `f` of the same, padded out to a `vec4` slot.
    translate: [2]f32 = .{ 0, 0 },
    _pad0: [2]f32 = .{ 0, 0 },
    /// Device-space scissor: min x, min y, max x, max y. Applied by shrinking
    /// the quad in the vertex shader, so clipped-away fragments are never
    /// generated.
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    /// Premultiplied, linear light. Premultiplied because the blend state is
    /// `ONE / ONE_MINUS_SRC_ALPHA`, the same as the rect pipeline; two
    /// pipelines that disagree about this composite correctly alone and
    /// wrongly against each other.
    color: [4]f32 = .{ 0, 0, 0, 1 },
    /// Index into the headers buffer: which outline this draws.
    header: u32 = 0,
    /// Index into the clips buffer, or `no_clip`.
    clip_node: u32 = no_clip,
    /// Sub-rows per pixel.
    rays: u32 = slug.default_rays,
    flags: u32 = 0,

    /// Builds the instance for one fill. `alpha` is the constant alpha in
    /// force (`/ca` or `/CA`), folded in here rather than into the colour so
    /// a paint can be reused across states.
    pub fn init(
        header: u32,
        xform: Transform,
        clip: [4]f32,
        color: Color,
        alpha: f32,
        rays: u32,
    ) Instance {
        const a = std.math.clamp(color.a, 0, 1) * std.math.clamp(alpha, 0, 1);
        return .{
            .xform = .{ xform.a, xform.b, xform.c, xform.d },
            .translate = .{ xform.e, xform.f },
            .clip = clip,
            .color = .{
                rect.srgbToLinear(std.math.clamp(color.r, 0, 1)) * a,
                rect.srgbToLinear(std.math.clamp(color.g, 0, 1)) * a,
                rect.srgbToLinear(std.math.clamp(color.b, 0, 1)) * a,
                a,
            },
            .header = header,
            .rays = rays,
        };
    }
};

/// One level of the clip stack. Matches `struct ClipNode` in the shader.
///
/// A linked list and not an array copied into each instance, because a page
/// draws thousands of paths under the same two clips: sharing the chain makes
/// the clip state eight bytes an instance rather than a hundred.
pub const ClipNode = extern struct {
    xform: [4]f32 = .{ 1, 0, 0, 1 },
    translate: [2]f32 = .{ 0, 0 },
    header: u32 = 0,
    parent: u32 = no_clip,
};

comptime {
    std.debug.assert(@sizeOf(PushConstants) == 8);
    std.debug.assert(@sizeOf(Instance) == 80);
    std.debug.assert(@offsetOf(Instance, "xform") == 0);
    std.debug.assert(@offsetOf(Instance, "translate") == 16);
    std.debug.assert(@offsetOf(Instance, "clip") == 32);
    std.debug.assert(@offsetOf(Instance, "color") == 48);
    std.debug.assert(@offsetOf(Instance, "header") == 64);
    std.debug.assert(@offsetOf(Instance, "clip_node") == 68);
    std.debug.assert(@offsetOf(Instance, "rays") == 72);
    std.debug.assert(@offsetOf(Instance, "flags") == 76);
    std.debug.assert(@sizeOf(ClipNode) == 32);
    // The shader indexes `bands[]` and `indices[]` with the header's spans,
    // so the strides have to be what the Zig side writes.
    std.debug.assert(@sizeOf(slug.Curve) == 24);
    std.debug.assert(@sizeOf(slug.Band) == 8);
    std.debug.assert(@sizeOf(slug.Header) == 40);
}

/// The six storage buffer bindings, in set 0.
pub const binding = struct {
    pub const curves: u32 = 0;
    pub const bands: u32 = 1;
    pub const indices: u32 = 2;
    pub const headers: u32 = 3;
    pub const instances: u32 = 4;
    pub const clips: u32 = 5;
    pub const count: u32 = 6;
};

/// The draw: a four-vertex strip, instanced.
pub const draw = struct {
    pub const vertex_count: u32 = 4;
    pub const topology_is_triangle_strip = true;
    /// No vertex buffer at all, the same as the rect pipeline. The quad comes
    /// out of `gl_VertexIndex`.
    pub const vertex_input_bindings: u32 = 0;
};

/// Rasterisation state.
pub const raster = struct {
    /// **Culling off.** Not because back faces are meaningful -- the quad is
    /// always wound the same way -- but because a transform with a negative
    /// determinant (a flip, which the page transform is) reverses it, and a
    /// culled quad draws nothing at all rather than drawing wrong.
    pub const cull_none = true;
    /// No depth attachment, no depth test, no depth write. Order is the depth
    /// test, exactly as in the rect pipeline.
    pub const depth_test = false;
    /// **And no stencil attachment.** The thing that is not here is the
    /// point: coverage comes from the outline, so the render pass needs
    /// nothing but a colour attachment and the reader does not pay for a
    /// depth-stencil image the size of the window.
    pub const stencil_attachment = false;
};

/// Multisampling: one sample.
///
/// The rect pipeline is single-sampled and gets its edges from a distance
/// field. This is single-sampled and gets them from the outline. Neither
/// needs a multisampled attachment, which means the whole renderer has one
/// colour image per swapchain view and no resolve -- and a page of text is
/// better antialiased than four times multisampling would make it, because
/// coverage across a vertical edge is continuous instead of being one of five
/// values.
pub const samples: u32 = 1;

/// Blend state, identical to the rect pipeline's.
///
/// `ONE / ONE_MINUS_SRC_ALPHA` over an `_SRGB` attachment, so the hardware
/// decodes on read and encodes on write and the blend happens in linear
/// light. The fragment shader emits premultiplied colour; with `SRC_ALPHA`
/// instead of `ONE` every path would be multiplied by its alpha twice.
pub const blend = struct {
    pub const enabled = true;
    pub const src_factor_one = true;
    pub const dst_factor_one_minus_src_alpha = true;
};

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "the instance's colour is premultiplied and linear" {
    // The contract with the blend state. A colour that is not premultiplied
    // here composites over the backdrop at the wrong weight and the page
    // comes out with a pale halo around every mark.
    const it: Instance = .init(0, .identity, .{ 0, 0, 100, 100 }, .{ .r = 1, .g = 0, .b = 0, .a = 0.5 }, 1.0, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), it.color[3], 0.001);
    // Red at full intensity is 1.0 in linear light too, halved by the alpha.
    try testing.expectApproxEqAbs(@as(f32, 0.5), it.color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), it.color[1], 0.001);

    // A mid grey is where sRGB and linear part company, and where a pipeline
    // that forgot the conversion would still look plausible.
    const grey: Instance = .init(0, .identity, .{ 0, 0, 1, 1 }, .gray(0.5), 1.0, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.2140), grey.color[0], 0.001);
}

test "the constant alpha multiplies the colour's own" {
    const it: Instance = .init(0, .identity, .{ 0, 0, 1, 1 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 }, 0.5, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), it.color[3], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), it.color[0], 0.001);
}

test "the transform is stored column by column, as the shader reads it" {
    // `applyXform` in the shader is `m.x*p.x + m.z*p.y + t.x`, so `xform` is
    // (a, b, c, d) and not (a, c, b, d). Getting this backwards transposes
    // every path on the page, which on an axis-aligned transform is invisible
    // and on a rotated one is not.
    const t: Transform = .{ .a = 2, .b = 3, .c = 5, .d = 7, .e = 11, .f = 13 };
    const it: Instance = .init(0, t, .{ 0, 0, 1, 1 }, .black, 1.0, 4);
    try testing.expectEqual([4]f32{ 2, 3, 5, 7 }, it.xform);
    try testing.expectEqual([2]f32{ 11, 13 }, it.translate);
}

test "the shader's constants are this file's constants" {
    // Nothing can check a GLSL source string at comptime, so the numbers that
    // have to agree are searched for in it. Crude, and it has caught the case
    // it exists for: a clip walk raised here and not there.
    try testing.expect(std.mem.indexOf(u8, shared_source, "MAX_CLIP_WALK = 8u") != null);
    try testing.expect(std.mem.indexOf(u8, shared_source, "NO_CLIP = 0xffffffffu") != null);
    try testing.expect(std.mem.indexOf(u8, shared_source, "ROOT_TABLE = 0x2E74u") != null);
    try testing.expectEqual(@as(u32, 8), max_clip_walk);
    try testing.expectEqual(@as(u32, 0xffffffff), no_clip);
    try testing.expectEqual(@as(u16, 0x2E74), slug.root_table);
}

test "every binding the shader declares has a number here" {
    inline for (.{
        .{ "binding = 0", binding.curves },
        .{ "binding = 1", binding.bands },
        .{ "binding = 2", binding.indices },
        .{ "binding = 3", binding.headers },
        .{ "binding = 4", binding.instances },
        .{ "binding = 5", binding.clips },
    }, 0..) |pair, i| {
        try testing.expect(std.mem.indexOf(u8, shared_source, pair[0]) != null);
        try testing.expectEqual(@as(u32, @intCast(i)), pair[1]);
    }
    try testing.expectEqual(@as(u32, 6), binding.count);
}
