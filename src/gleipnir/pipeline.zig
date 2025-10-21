//! Everything the Vulkan side of the rect pipeline has to agree with, written
//! down where it can be read without a device.
//!
//! There is no Vulkan in this file, and there still is not now that Lyngvi
//! exists. This half is the contract -- which binding is what, how big a push
//! constant is, which blend factors the shader's output assumes, which device
//! features it actually requires -- and `lyngvi/Renderer.zig` is the half that
//! makes the calls. Getting any of these wrong produces a black window and no
//! error message, which is why they are stated once, here, in a file that
//! compiles on a machine with no driver, rather than discovered one at a time
//! inside three hundred lines of `vkCreate*`.
//!
//! `Renderer.zig` has a test that compares the two, which is possible only
//! there: it is the only place in the project where both halves exist.
//!
//! The shader sources are embedded rather than read from disk so that a
//! binary is self-contained, and so that renaming a file breaks the build
//! instead of breaking at runtime.

const std = @import("std");

const rect = @import("rect.zig");

pub const vert_source = @embedFile("shader/rect.vert");
pub const frag_source = @embedFile("shader/rect.frag");
pub const shared_source = @embedFile("shader/rect.glsl");

/// How to turn the sources above into SPIR-V. Not a build step yet: no shader
/// compiler is a dependency of this project, nothing consumes SPIR-V until
/// there is a device to hand it to, and a build step that has never run is
/// worth less than a command that has been written down correctly.
///
///     glslc -I src/gleipnir/shader --target-env=vulkan1.2 \
///         src/gleipnir/shader/rect.vert -o rect.vert.spv
///     glslc -I src/gleipnir/shader --target-env=vulkan1.2 \
///         src/gleipnir/shader/rect.frag -o rect.frag.spv
///
/// `-I` is needed because both stages include `rect.glsl`, which is where the
/// instance layout lives; duplicating it into each stage is how the two drift
/// apart.
pub const compile_command = "glslc -I src/gleipnir/shader --target-env=vulkan1.2";

/// Descriptor set 0. One set for the whole frame, bound once.
pub const binding = struct {
    /// `readonly buffer Instances` -- the array uploaded by `DrawList.bytes`.
    /// A storage buffer rather than a vertex buffer because the fragment
    /// shader reads it too, which is what keeps the varyings down to one flat
    /// integer.
    pub const instances: u32 = 0;
    /// `uniform texture2D textures[]` -- an unbounded array of sampled images.
    /// Instances index it directly, which is what allows a glyph atlas, an
    /// icon sheet and a page image in one draw call.
    pub const textures: u32 = 1;
    /// `uniform sampler samp` -- separate from the images, so one sampler
    /// serves the whole array.
    pub const sampler: u32 = 2;
};

/// Matches `layout(push_constant) uniform Push` in `shader/rect.glsl`.
pub const PushConstants = extern struct {
    /// Framebuffer size in pixels. The vertex shader divides by this rather
    /// than being given a projection matrix, because with no rotation the
    /// matrix would be four useful numbers padded out to sixteen.
    viewport: [2]f32,
};

comptime {
    std.debug.assert(@sizeOf(PushConstants) == 8);
}

/// The pipeline state the shader's output assumes, in words rather than in
/// `VkPipelineColorBlendAttachmentState`. Each of these is load-bearing:
///
/// * **Topology** `TRIANGLE_STRIP`, 4 vertices, no vertex or index buffer, no
///   vertex input state at all. The draw is `vkCmdDraw(cmd, 4, n, 0, 0)`.
/// * **Blend** enabled, `srcColor = ONE`, `dstColor = ONE_MINUS_SRC_ALPHA`,
///   the same for alpha, op `ADD`. The fragment shader emits premultiplied
///   colour; with `SRC_ALPHA` instead of `ONE` every instance would be
///   multiplied by its alpha twice and everything translucent would go dark.
/// * **Culling** off. Nothing here is wound consistently and nothing needs to
///   be -- a fully clipped instance is a zero-area quad, which no winding
///   rule can rescue and none has to.
/// * **Depth** none: no depth attachment, no test, no write. Order is the
///   depth test, and Vulkan guarantees instances rasterise in index order
///   within one draw.
/// * **Colour attachment** an `_SRGB` format. The hardware then decodes on
///   read and encodes on write, so the blend above happens in linear light,
///   which is what `srgbToLinear` in the fragment shader is arranged for.
/// * **Samples** one. Antialiasing comes from the distance field, not from
///   multisampling; that is the point of an SDF pipeline, and MSAA would cost
///   memory bandwidth to improve nothing.
pub const state = struct {
    pub const vertices_per_instance: u32 = 4;
    pub const instance_size: u32 = @sizeOf(rect.Instance);
};

/// Device features the shader requires, as opposed to prefers.
///
/// `descriptor_indexing` is the only real one, and it buys the headline: an
/// instance can name any texture, so a frame never has to break a draw call to
/// rebind one. Without it the fallback is `DrawList.textureRuns`, which needs
/// no shader change beyond replacing the unbounded array with a single
/// `texture2D`. That fallback is worth keeping working, because the class of
/// device that lacks descriptor indexing is exactly the class of device
/// someone will try to read a PDF on.
pub const requires = struct {
    pub const descriptor_indexing = true;
    pub const runtime_descriptor_array = true;
    pub const shader_sampled_image_array_non_uniform_indexing = true;
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the embedded shaders are the ones that were reviewed" {
    // Not a checksum -- that would fail on every edit. Just enough that a
    // truncated or renamed file cannot pass silently.
    try testing.expect(std.mem.startsWith(u8, vert_source, "#version 450"));
    try testing.expect(std.mem.startsWith(u8, frag_source, "#version 450"));
    try testing.expect(std.mem.indexOf(u8, vert_source, "gl_InstanceIndex") != null);
    try testing.expect(std.mem.indexOf(u8, frag_source, "sdRoundedBox") != null);
    try testing.expect(std.mem.indexOf(u8, shared_source, "struct Instance") != null);
}

test "the GLSL instance struct still names every Zig field" {
    // The one invariant that cannot be checked by a compiler on either side.
    // A field added to `rect.Instance` and forgotten in `rect.glsl` shifts
    // every member after it, and the symptom is a frame of garbage rather
    // than an error, so this at least catches the omission.
    inline for (@typeInfo(rect.Instance).@"struct".fields) |f| {
        const name = comptime if (std.mem.eql(u8, f.name, "texture")) "texture_id" else f.name;
        try testing.expect(std.mem.indexOf(u8, shared_source, name) != null);
    }
}

test "both stages include the shared layout rather than restating it" {
    try testing.expect(std.mem.indexOf(u8, vert_source, "#include \"rect.glsl\"") != null);
    try testing.expect(std.mem.indexOf(u8, frag_source, "#include \"rect.glsl\"") != null);
    // Which is why the compile command needs an include path.
    try testing.expect(std.mem.indexOf(u8, compile_command, "-I ") != null);
}
