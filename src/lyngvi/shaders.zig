//! The compiled shaders, and what to say when there are none.
//!
//! SPIR-V comes in by the build, not by this program: a renderer that carries
//! a shader compiler pays for it in binary size and startup time on every
//! machine in order to produce the same blobs every time. `-Dshaders` picks
//! where it comes from -- the GLSL in `gleipnir/shader/` through glslc or
//! glslang, the Slang in `gleipnir/shader/slang/` through slangc, or the
//! modules committed in `gleipnir/shader/spirv/` with no compiler at all --
//! and the result arrives here as anonymous imports. `compiler` says which.
//!
//! The tests below hold every source to the same contract, which is what
//! lets one replace another: each module is the stage it claims to be, asks
//! for descriptor indexing exactly where the pipeline expects it, and lays
//! out every storage buffer the way the Zig side writes it.
//!
//! With `-Dshaders=auto` and nothing to compile or embed, the imports are
//! empty and `available` is false. Everything else in Lyngvi still works
//! there -- the window opens, the device is created -- and only the pipeline
//! refuses, with a message naming the command that would fix it.
//!
//! The blobs are declared `align(4)` because `vkCreateShaderModule` takes a
//! `const uint32_t*` and `@embedFile` promises nothing about alignment.

const std = @import("std");
const build_options = @import("build_options");

const spirv = @import("spirv.zig");

/// True when this binary has real SPIR-V in it.
pub const available = build_options.lyngvi_spirv;

/// The command that produces the modules, quoted in the error message when
/// there are none. Kept next to the thing it produces so it cannot drift.
pub const compile_hint =
    "rebuild with -Dshaders=spirv to embed the committed modules in src/gleipnir/shader/spirv,\n" ++
    "or put glslc, glslang or slangc on PATH and pick -Dshaders=glsl or -Dshaders=slang";

/// Which compiler, or `spirv` for the committed modules, made what is embedded.
pub const compiler = build_options.lyngvi_shader_compiler;

const rect_vert_raw = @embedFile("rect_vert_spv");
const rect_frag_raw = @embedFile("rect_frag_spv");
const path_vert_raw = @embedFile("path_vert_spv");
const path_frag_raw = @embedFile("path_frag_spv");
const slug_vert_raw = @embedFile("slug_vert_spv");
const slug_frag_raw = @embedFile("slug_frag_spv");

pub const vert: [rect_vert_raw.len]u8 align(4) = rect_vert_raw.*;
pub const frag: [rect_frag_raw.len]u8 align(4) = rect_frag_raw.*;
pub const path_vert: [path_vert_raw.len]u8 align(4) = path_vert_raw.*;
pub const path_frag: [path_frag_raw.len]u8 align(4) = path_frag_raw.*;
pub const slug_vert: [slug_vert_raw.len]u8 align(4) = slug_vert_raw.*;
pub const slug_frag: [slug_frag_raw.len]u8 align(4) = slug_frag_raw.*;

pub const Error = error{ NoShaders, WrongStage } || spirv.Error;

/// Parses a blob and checks that its entry point really is the stage it is
/// about to be wired into. Getting that wrong creates a pipeline successfully
/// and draws nothing, which is the most expensive class of renderer bug
/// because there is no error message to search for.
fn module(blob: []align(@alignOf(u32)) const u8, stage: spirv.ExecutionModel) Error!spirv.Module {
    if (!available or blob.len == 0) return error.NoShaders;
    const m = try spirv.parse(blob);
    if (!m.isStage(stage)) return error.WrongStage;
    return m;
}

pub fn vertexModule() Error!spirv.Module {
    return module(&vert, .vertex);
}

pub fn fragmentModule() Error!spirv.Module {
    return module(&frag, .fragment);
}

/// The path pipeline's stages. Both passes of stencil-then-cover use the same
/// two modules -- the winding rule lives in the stencil ops, not in the
/// shader -- so there are two here rather than four.
pub fn pathVertexModule() Error!spirv.Module {
    return module(&path_vert, .vertex);
}

pub fn pathFragmentModule() Error!spirv.Module {
    return module(&path_frag, .fragment);
}

/// The analytic path pipeline's stages: one draw, one pass, two modules.
///
/// Unlike the stencil pipeline's, these *do* read storage buffers -- eight of
/// them -- and index them with the instance index, which is uniform across a
/// draw. So they need descriptor indexing no more than the rect pipeline's
/// vertex shader does, and `slugFragmentModule` is checked for that below.
pub fn slugVertexModule() Error!spirv.Module {
    return module(&slug_vert, .vertex);
}

pub fn slugFragmentModule() Error!spirv.Module {
    return module(&slug_frag, .fragment);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a build with no shader compiler says so rather than crashing" {
    // This is the state of a machine with a driver and no SDK, which is most
    // of them. The two paths are checked by whichever one this build is in;
    // both are reachable in CI, where the SDK is installed on one runner.
    if (available) {
        const v = try vertexModule();
        const f = try fragmentModule();
        try testing.expect(v.byteSize() > 0);
        try testing.expect(f.byteSize() > 0);
        // The path stages come from the same build step and either both
        // stages of both pipelines are here or none of them are.
        const pv = try pathVertexModule();
        const pf = try pathFragmentModule();
        try testing.expect(pv.byteSize() > 0);
        try testing.expect(pf.byteSize() > 0);
        try testing.expect(pv.isStage(.vertex));
        try testing.expect(pf.isStage(.fragment));
        // The path shaders index no descriptor array at all -- everything they
        // need is a push constant -- so they must *not* need the feature the
        // rect pipeline does. A path pipeline that asked for it would make the
        // descriptor-indexing fallback pointless.
        try testing.expect(!try pf.needsNonUniformIndexing());

        // The analytic pipeline reads eight storage buffers and indexes every
        // one of them with a value derived from the instance index, which is
        // uniform across the draw. So it must not ask for non-uniform
        // indexing either: a page's worth of paths goes through one draw call
        // on a device that has none of the descriptor-indexing features.
        const sv = try slugVertexModule();
        const sf = try slugFragmentModule();
        try testing.expect(sv.byteSize() > 0);
        try testing.expect(sf.byteSize() > 0);
        try testing.expect(sv.isStage(.vertex));
        try testing.expect(sf.isStage(.fragment));
        try testing.expect(!try sf.needsNonUniformIndexing());
        // The check that catches a build wiring the modules to the wrong
        // stages, which creates a pipeline that draws nothing and reports
        // nothing.
        try testing.expect(v.isStage(.vertex));
        try testing.expect(f.isStage(.fragment));
        // The fragment shader indexes the texture array with a value the
        // compiler cannot prove uniform, so it must declare the capability --
        // and if it stops declaring it, the renderer is asking for a device
        // feature it no longer needs.
        try testing.expect(try f.needsNonUniformIndexing());
    } else {
        try testing.expectError(error.NoShaders, vertexModule());
        try testing.expectError(error.NoShaders, fragmentModule());
        try testing.expectError(error.NoShaders, pathVertexModule());
        try testing.expectError(error.NoShaders, pathFragmentModule());
    }
}

test "the compiled shader lays out every buffer the way the Zig side writes it" {
    // The failure this exists for shipped: `PathHeader` held its box in a
    // `vec4`, which aligns a std430 struct to sixteen bytes and made it 48
    // where `slug.Header` is 40. Every comptime assertion on the Zig side
    // passed, the shader compiled, the pipeline validated, and every header
    // after the first was read from the wrong place -- a page of text drawn
    // as its own glyphs, huge and scattered. Nothing but the compiled module
    // knows the layout the shader will actually use, so it is read from there.
    if (!available) return error.SkipZigTest;
    const slugpipe = @import("../gleipnir/slugpipe.zig");
    const slug = @import("../gleipnir/slug.zig");
    const b = slugpipe.binding;

    const checks = [_]Check{
        .{ .binding = b.curves, .T = slug.Curve },
        .{ .binding = b.bands, .T = slug.Band },
        .{ .binding = b.indices, .T = u32 },
        .{ .binding = b.headers, .T = slug.Header },
        .{ .binding = b.instances, .T = slugpipe.Instance },
        .{ .binding = b.clips, .T = slugpipe.ClipNode },
        .{ .binding = b.images, .T = slugpipe.ImageInfo },
        .{ .binding = b.texels, .T = u32 },
    };

    const rect = @import("../gleipnir/rect.zig");
    try expectLayouts(try slugFragmentModule(), &checks);
    try expectLayouts(try slugVertexModule(), &[_]Check{
        .{ .binding = b.headers, .T = slug.Header },
        .{ .binding = b.instances, .T = slugpipe.Instance },
    });
    // The rect pipeline's one buffer, from both stages.
    try expectLayouts(try vertexModule(), &[_]Check{.{ .binding = 0, .T = rect.Instance }});
    try expectLayouts(try fragmentModule(), &[_]Check{.{ .binding = 0, .T = rect.Instance }});
}

const Check = struct {
    binding: u32,
    T: type,
};

fn expectLayouts(module_: spirv.Module, comptime checks: []const Check) !void {
    inline for (checks) |c| {
        const layout = (try module_.arrayLayout(0, c.binding)) orelse {
            std.debug.print("binding {d} is not in the module\n", .{c.binding});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(@as(u32, @sizeOf(c.T)), layout.stride);

        if (@typeInfo(c.T) == .@"struct") {
            // The GLSL structs may group two Zig fields into one vector --
            // `vec2 p0` for `x0, y0` -- so every GLSL member offset has to be
            // the offset of *some* Zig field.
            for (layout.memberOffsets()) |offset| {
                var found = false;
                inline for (@typeInfo(c.T).@"struct".field_names) |name| {
                    if (@offsetOf(c.T, name) == offset) found = true;
                }
                if (!found) {
                    std.debug.print("binding {d}: a member at offset {d} lines up with no field of {s}\n", .{
                        c.binding, offset, @typeName(c.T),
                    });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "the hint names the command that fixes it" {
    try testing.expect(std.mem.indexOf(u8, compile_hint, "-Dshaders=spirv") != null);
    try testing.expect(std.mem.indexOf(u8, compile_hint, "glslc") != null);
}
