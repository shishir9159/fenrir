//! Everything the Vulkan side of the path pipeline has to agree with, written
//! down where it can be read without a device.
//!
//! The companion to `pipeline.zig`, and the same bargain: no Vulkan in this
//! file, only the contract. `lyngvi/Renderer.zig` makes the calls and has a
//! test that compares the two, which is possible only there because it is the
//! only place in the project where both halves exist.
//!
//! The rect pipeline's stakes were a black window. This one's are worse,
//! because most of the state below is *silently* wrong rather than absent. A
//! stencil op on the wrong face inverts every fill. A write mask of `0xff`
//! where even-odd wants `0x01` makes alternate contours disappear. A front
//! face of `CLOCKWISE` turns every path inside out, which on a page of text
//! looks like a page of text with the counters filled in. None of those
//! produce a validation message, so they are stated here once, with the reason.
//!
//! ## The four pipelines
//!
//! Two winding rules times two passes. They differ *only* in depth-stencil
//! state and colour write mask -- same modules, same vertex input, same
//! layout, same blend -- which is what makes them cheap to create and is the
//! reason the shader knows nothing about winding rules.
//!
//!     nonzero  stencil   inc/dec on front/back, no colour
//!     nonzero  cover     test != 0, zero behind, colour
//!     even-odd stencil   invert bit 0, no colour
//!     even-odd cover     test bit 0, zero behind, colour
//!
//! ## Order
//!
//! Stencil then cover, per path, with a barrier between only if the driver
//! needs one -- it does not, because both passes are in the same render pass
//! and the stencil attachment is read-after-write by the same fragment stage,
//! which Vulkan orders for free within a subpass.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const path = @import("path.zig");
const rect = @import("rect.zig");

const Color = paint.Color;
const FillRule = geom.FillRule;
const Transform = geom.Transform;

pub const vert_source = @embedFile("shader/path.vert");
pub const frag_source = @embedFile("shader/path.frag");
pub const shared_source = @embedFile("shader/path.glsl");

/// How to turn the sources above into SPIR-V by hand. `build.zig` does it
/// automatically for every stage in `shader_stages`; this is the command to
/// type when a shader will not compile and the build's error needs
/// reproducing.
///
///     glslang -V --target-env vulkan1.2 -Isrc/gleipnir/shader \
///         src/gleipnir/shader/path.vert -o path.vert.spv
///
/// Note `-I<dir>` attached: glslang rejects it as a separate argument, where
/// glslc requires it to be one. That difference cost an afternoon once.
pub const compile_command = "glslang -V --target-env vulkan1.2 -Isrc/gleipnir/shader";

/// Matches `layout(push_constant) uniform Push` in `shader/path.glsl`.
///
/// Forty-eight bytes, well inside the 128 every Vulkan implementation
/// guarantees. There is no descriptor set at all: the path pipeline binds no
/// buffers and samples no images, so `VkPipelineLayout` has one push constant
/// range and nothing else. That is worth the field order being chosen for
/// alignment rather than for reading -- the two `vec4`s first so neither needs
/// padding in front of it, the two `vec2`s packed into the last sixteen bytes.
pub const PushConstants = extern struct {
    /// `a`, `b`, `c`, `d` of the path-space-to-device matrix.
    xform: [4]f32 = .{ 1, 0, 0, 1 },
    /// Premultiplied, linear light. Premultiplied because the blend state is
    /// `ONE / ONE_MINUS_SRC_ALPHA`, the same as the rect pipeline; two
    /// pipelines that disagree about this composite correctly alone and
    /// wrongly against each other.
    color: [4]f32 = .{ 0, 0, 0, 1 },
    /// `e`, `f` of the same matrix.
    translate: [2]f32 = .{ 0, 0 },
    /// Framebuffer size in pixels. Divided by in the vertex shader rather than
    /// folded into a projection matrix, for the same reason as in the rect
    /// pipeline: with no rotation the matrix is four useful numbers padded out
    /// to sixteen.
    viewport: [2]f32 = .{ 1, 1 },

    /// Builds the push constant for one fill. `alpha` is the constant alpha in
    /// force (`/ca` or `/CA`), folded in here rather than in the colour so a
    /// paint can be reused across states.
    pub fn init(xform: Transform, viewport: [2]f32, color: Color, alpha: f32) PushConstants {
        const a = std.math.clamp(color.a, 0, 1) * std.math.clamp(alpha, 0, 1);
        return .{
            .xform = .{ xform.a, xform.b, xform.c, xform.d },
            .color = .{
                rect.srgbToLinear(std.math.clamp(color.r, 0, 1)) * a,
                rect.srgbToLinear(std.math.clamp(color.g, 0, 1)) * a,
                rect.srgbToLinear(std.math.clamp(color.b, 0, 1)) * a,
                a,
            },
            .translate = .{ xform.e, xform.f },
            .viewport = viewport,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(PushConstants) == 48);
    std.debug.assert(@offsetOf(PushConstants, "xform") == 0);
    std.debug.assert(@offsetOf(PushConstants, "color") == 16);
    std.debug.assert(@offsetOf(PushConstants, "translate") == 32);
    std.debug.assert(@offsetOf(PushConstants, "viewport") == 40);
}

/// The vertex input, which unlike the rect pipeline actually has one.
///
/// The rect pipeline draws from `gl_VertexIndex` with no buffer at all,
/// because every rect is four corners of a known quad. A path is not: the
/// geometry *is* the shape, so it has to be uploaded.
pub const vertex = struct {
    /// `VkVertexInputBindingDescription`: binding 0, stride 8, per-vertex.
    pub const binding: u32 = 0;
    pub const stride: u32 = @sizeOf(path.Vertex);
    /// `VkVertexInputAttributeDescription`: location 0, `R32G32_SFLOAT`,
    /// offset 0.
    pub const location: u32 = 0;
    pub const offset: u32 = 0;

    /// `vkCmdBindIndexBuffer` takes `VK_INDEX_TYPE_UINT32`. Sixteen bits would
    /// halve the traffic and cap a path at 65,536 points, which sounds like
    /// plenty until a contour map arrives.
    pub const index_bits: u32 = 32;
};

/// The rasterisation state both passes share.
pub const raster = struct {
    /// `VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST`. Not a fan: the stencil geometry
    /// is a fan *per subpath*, and a path has many, so one list in one draw
    /// beats one fan draw per contour.
    pub const topology_is_triangle_list = true;

    /// **Culling off, front face counter-clockwise.**
    ///
    /// Both halves are load-bearing and neither is obvious. Culling must be
    /// off because the back-facing triangles are not waste -- they are the
    /// *decrements*, and culling them turns the winding number into a plain
    /// coverage count, which fills every hole in every glyph on the page.
    ///
    /// The winding is decided in framebuffer coordinates, where y points down
    /// because the vertex shader writes pixel coordinates straight into clip
    /// space with no flip. Vulkan calls a triangle front-facing when the
    /// signed area computed there is positive and `frontFace` is
    /// `COUNTER_CLOCKWISE`, which is exactly the `signedArea(a, b, c) > 0`
    /// that `path.stencilAt` and `raster.zig` use for the increment. Set it to
    /// `CLOCKWISE` and every fill inverts.
    pub const cull_none = true;
    pub const front_face_counter_clockwise = true;

    /// No depth attachment, no depth test, no depth write. Order is the depth
    /// test, exactly as in the rect pipeline. The attachment is stencil-only.
    pub const depth_test = false;
};

/// The stencil op state for one pass under one rule.
///
/// Named the way `VkStencilOpState` names things, so the mapping into
/// `Renderer.zig` is transcription rather than translation.
pub const StencilOps = struct {
    fail: Op,
    pass: Op,
    depth_fail: Op,
    compare: Compare,
    compare_mask: u32,
    write_mask: u32,
    reference: u32,

    pub const Op = enum {
        keep,
        zero,
        invert,
        increment_wrap,
        decrement_wrap,
    };

    pub const Compare = enum { always, not_equal };
};

pub const Face = struct {
    front: StencilOps,
    back: StencilOps,
};

/// The stencil pass: turn geometry into winding numbers.
pub fn stencilPass(rule: FillRule) Face {
    return switch (rule) {
        // Increment on front faces, decrement on back. The stencil buffer then
        // literally holds the winding number, modulo 256.
        .nonzero => .{
            .front = .{
                .fail = .keep,
                .pass = .increment_wrap,
                .depth_fail = .keep,
                .compare = .always,
                .compare_mask = 0xff,
                .write_mask = 0xff,
                .reference = 0,
            },
            .back = .{
                .fail = .keep,
                .pass = .decrement_wrap,
                .depth_fail = .keep,
                .compare = .always,
                .compare_mask = 0xff,
                .write_mask = 0xff,
                .reference = 0,
            },
        },
        // Even-odd needs one bit and does not care which way a triangle faces:
        // inverting twice is the identity, which is the parity it is after.
        // The write mask is what keeps it out of the other seven bits, and
        // widening it to 0xff would make the buffer hold `count` rather than
        // `count & 1` while the cover pass still tested one bit -- which
        // happens to give the same answer, and then stops when the count
        // passes 255.
        .even_odd => .{
            .front = evenOddStencil,
            .back = evenOddStencil,
        },
    };
}

const evenOddStencil: StencilOps = .{
    .fail = .keep,
    .pass = .invert,
    .depth_fail = .keep,
    .compare = .always,
    .compare_mask = 0xff,
    .write_mask = 0x01,
    .reference = 0,
};

/// The cover pass: test the winding number and clear it in the same operation.
///
/// `fail` is `zero` as well as `pass`, which is the part that is easy to leave
/// out. A sample that fails the test still had a stencil value written by the
/// stencil pass, and if it is not cleared it stays there for the next path --
/// which will be somewhere else on the page, and will be filled in the shape
/// of this one. Zeroing on both outcomes is what lets a whole page share one
/// stencil attachment with no clear between paths, and `Canvas.stencilIsClean`
/// in `raster.zig` is the test that it holds.
pub fn coverPass(rule: FillRule) Face {
    const ops: StencilOps = .{
        .fail = .zero,
        .pass = .zero,
        .depth_fail = .zero,
        .compare = .not_equal,
        // Nonzero asks whether any bit is set; even-odd asks about bit zero.
        .compare_mask = switch (rule) {
            .nonzero => 0xff,
            .even_odd => 0x01,
        },
        .write_mask = 0xff,
        .reference = 0,
    };
    return .{ .front = ops, .back = ops };
}

/// Colour writes are off during the stencil pass. The fragment shader still
/// runs -- there is no way to have a graphics pipeline without one here, and
/// it is four instructions -- but its output goes nowhere.
pub fn colorWriteMask(pass: enum { stencil, cover }) u32 {
    return switch (pass) {
        .stencil => 0x0,
        .cover => 0xf, // R | G | B | A
    };
}

/// Blend state, identical to the rect pipeline's.
///
/// `ONE / ONE_MINUS_SRC_ALPHA` over an `_SRGB` attachment, so the hardware
/// decodes on read and encodes on write and the blend happens in linear light.
/// The fragment shader emits premultiplied colour; with `SRC_ALPHA` instead of
/// `ONE` every path would be multiplied by its alpha twice.
pub const blend = struct {
    pub const enabled = true;
    pub const src_factor_one = true;
    pub const dst_factor_one_minus_src_alpha = true;
};

/// Multisampling, which is where a path's antialiasing comes from.
///
/// The rect pipeline is deliberately single-sampled and gets its edges from a
/// distance field. A path cannot: there is no closed form for the distance to
/// a cubic, and the numerical ones cost more per pixel than four samples do.
/// So the render pass is multisampled and the rect pipeline pays a little
/// bandwidth it does not need, which is the right trade for a *document*
/// reader -- almost everything on a page is a path, and the UI chrome that
/// isn't is a few hundred rects.
///
/// Four is the default because it is where an edge stops looking like stairs.
/// `preferred` is a request: a device that cannot offer it falls back through
/// `fallbacks` in order, and one is always available.
pub const multisample = struct {
    pub const preferred: u32 = 4;
    pub const fallbacks = [_]u32{ 4, 2, 1 };

    /// `sampleShading` is deliberately off. It would run the fragment shader
    /// per sample rather than per pixel, which for a shader that returns a
    /// constant buys nothing at four times the cost.
    pub const sample_shading = false;

    /// Picks the best count a device supports. `mask` is the intersection of
    /// `framebufferColorSampleCounts` and `framebufferStencilSampleCounts`,
    /// as a `VkSampleCountFlags` bitmask.
    pub fn choose(mask: u32) u32 {
        for (fallbacks) |n| {
            if (mask & n != 0) return n;
        }
        return 1;
    }
};

/// What the path pipeline needs from a device, as opposed to prefers.
///
/// Notably short. The rect pipeline needs descriptor indexing; this one needs
/// a stencil buffer, which every Vulkan implementation has, and nothing else.
/// No descriptor sets, no extensions, no optional features. A device that can
/// run Vulkan at all can run this.
pub const requires = struct {
    /// One of these must be supported for the depth-stencil attachment.
    /// `S8_UINT` first because it is the cheapest -- there is no depth here to
    /// waste -- but it is optional in Vulkan, so the two combined formats that
    /// every implementation must support come after it.
    pub const stencil_formats = [_][]const u8{
        "s8_uint",
        "d24_unorm_s8_uint",
        "d32_sfloat_s8_uint",
    };
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the embedded shaders are the ones that were reviewed" {
    try testing.expect(std.mem.startsWith(u8, vert_source, "#version 450"));
    try testing.expect(std.mem.startsWith(u8, frag_source, "#version 450"));
    try testing.expect(std.mem.indexOf(u8, vert_source, "in_pos") != null);
    try testing.expect(std.mem.indexOf(u8, shared_source, "pathToDevice") != null);
}

test "both stages include the shared push constant rather than restating it" {
    try testing.expect(std.mem.indexOf(u8, vert_source, "#include \"path.glsl\"") != null);
    try testing.expect(std.mem.indexOf(u8, frag_source, "#include \"path.glsl\"") != null);
    try testing.expect(std.mem.indexOf(u8, compile_command, "-I") != null);
    // glslang needs the extension asked for by name; glslc enables it
    // implicitly, so a shader that compiles with one and not the other is
    // exactly this line missing.
    try testing.expect(std.mem.indexOf(u8, vert_source, "GL_GOOGLE_include_directive") != null);
    try testing.expect(std.mem.indexOf(u8, frag_source, "GL_GOOGLE_include_directive") != null);
}

test "the GLSL push constant still names every Zig field, in order" {
    // The one invariant no compiler on either side can check. A field
    // reordered here and not there shifts everything after it, and the symptom
    // is a page drawn at the wrong place in the wrong colour rather than an
    // error.
    var at: usize = 0;
    inline for (@typeInfo(PushConstants).@"struct".field_names) |name| {
        const found = std.mem.indexOfPos(u8, shared_source, at, name) orelse {
            std.debug.print("shader/path.glsl never mentions '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        };
        at = found;
    }
}

test "nonzero increments front faces and decrements back ones" {
    const s = stencilPass(.nonzero);
    try testing.expectEqual(StencilOps.Op.increment_wrap, s.front.pass);
    try testing.expectEqual(StencilOps.Op.decrement_wrap, s.back.pass);
    // If these ever match, culling has effectively been turned on and every
    // hole in every glyph fills in.
    try testing.expect(s.front.pass != s.back.pass);
    try testing.expectEqual(@as(u32, 0xff), s.front.write_mask);
}

test "even-odd inverts one bit and does not care about facing" {
    const s = stencilPass(.even_odd);
    try testing.expectEqual(StencilOps.Op.invert, s.front.pass);
    try testing.expectEqual(s.front.pass, s.back.pass);
    try testing.expectEqual(@as(u32, 0x01), s.front.write_mask);
    // And the cover pass has to read the same bit it wrote.
    try testing.expectEqual(@as(u32, 0x01), coverPass(.even_odd).front.compare_mask);
}

test "the cover pass zeroes on failure as well as on success" {
    // The line that keeps one stencil attachment usable for a whole page.
    // Without it, a path leaves its own shape behind in the buffer and the
    // next path anywhere on the page is filled through it.
    for ([_]FillRule{ .nonzero, .even_odd }) |rule| {
        const c = coverPass(rule);
        try testing.expectEqual(StencilOps.Op.zero, c.front.fail);
        try testing.expectEqual(StencilOps.Op.zero, c.front.pass);
        try testing.expectEqual(StencilOps.Op.zero, c.front.depth_fail);
        try testing.expectEqual(StencilOps.Compare.not_equal, c.front.compare);
        try testing.expectEqual(@as(u32, 0), c.front.reference);
        // The write mask has to reach every bit the stencil pass could have
        // set, or even-odd's inverted bit survives into the next path.
        try testing.expectEqual(@as(u32, 0xff), c.front.write_mask);
    }
}

test "the stencil pass writes no colour and the cover pass writes all of it" {
    try testing.expectEqual(@as(u32, 0), colorWriteMask(.stencil));
    try testing.expectEqual(@as(u32, 0xf), colorWriteMask(.cover));
}

test "the sample count falls back rather than failing" {
    // A VkSampleCountFlags mask: bit values are the counts themselves.
    try testing.expectEqual(@as(u32, 4), multisample.choose(0x1 | 0x2 | 0x4 | 0x8));
    try testing.expectEqual(@as(u32, 2), multisample.choose(0x1 | 0x2));
    try testing.expectEqual(@as(u32, 1), multisample.choose(0x1));
    // A device advertising nothing at all still gets a legal answer.
    try testing.expectEqual(@as(u32, 1), multisample.choose(0));
}

test "a push constant carries a premultiplied colour in linear light" {
    const p = PushConstants.init(.identity, .{ 800, 600 }, .{ .r = 1, .g = 0, .b = 0, .a = 0.5 }, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), p.color[3], 0.001);
    // Red is 1.0 in sRGB and 1.0 in linear, premultiplied to 0.5.
    try testing.expectApproxEqAbs(@as(f32, 0.5), p.color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), p.color[1], 0.001);

    // A mid grey is where the encoding shows: 0.5 sRGB is 0.214 linear.
    const g = PushConstants.init(.identity, .{ 1, 1 }, .gray(0.5), 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2140), g.color[0], 0.001);

    // The constant alpha multiplies the colour's own.
    const half = PushConstants.init(.identity, .{ 1, 1 }, .black, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), half.color[3], 0.001);
}

test "a push constant carries the matrix in the order the shader reads it" {
    const t: Transform = .{ .a = 2, .b = 3, .c = 4, .d = 5, .e = 6, .f = 7 };
    const p = PushConstants.init(t, .{ 1, 1 }, .black, 1);
    try testing.expectEqual([4]f32{ 2, 3, 4, 5 }, p.xform);
    try testing.expectEqual([2]f32{ 6, 7 }, p.translate);

    // And `pathToDevice` in the shader has to compute what `Transform.apply`
    // does here, which is the only place the two conventions could diverge.
    const got = t.apply(.{ .x = 10, .y = 20 });
    const shader_x = p.xform[0] * 10 + p.xform[2] * 20 + p.translate[0];
    const shader_y = p.xform[1] * 10 + p.xform[3] * 20 + p.translate[1];
    try testing.expectApproxEqAbs(got.x, shader_x, 0.0001);
    try testing.expectApproxEqAbs(got.y, shader_y, 0.0001);
}

test "the vertex stride matches the vertex" {
    try testing.expectEqual(@as(u32, 8), vertex.stride);
    try testing.expectEqual(@sizeOf(path.Vertex), vertex.stride);
}
