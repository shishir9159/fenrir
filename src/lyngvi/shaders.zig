//! The compiled shaders, and what to say when there are none.
//!
//! The GLSL in `gleipnir/shader/` is the source of truth and is compiled to
//! SPIR-V by the build, not by this program: a renderer that carries a shader
//! compiler pays for it in binary size and startup time on every machine in
//! order to produce the same two blobs every time. `build.zig` looks for
//! `glslc` or `glslangValidator`, runs it if it finds one, and hands the
//! results here as anonymous imports.
//!
//! When it finds neither, the imports are empty and `available` is false. That
//! is a real situation and not an error: a machine with a Vulkan driver and no
//! shader compiler is the normal state of a machine that has never had the SDK
//! installed. Everything else in Lyngvi still works there -- the window opens,
//! the device is created, `fenrir view --probe` prints what the hardware can
//! do -- and only the pipeline refuses, with a message naming the command that
//! would fix it.
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
    "install the Vulkan SDK (or shaderc) and rebuild: the build runs\n" ++
    "    glslc -I src/gleipnir/shader --target-env=vulkan1.2 src/gleipnir/shader/rect.vert -o rect.vert.spv\n" ++
    "automatically once glslc or glslangValidator is on PATH";

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
/// Unlike the stencil pipeline's, these *do* read storage buffers -- six of
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

        // The analytic pipeline reads six storage buffers and indexes every
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

test "the hint names the command that fixes it" {
    try testing.expect(std.mem.indexOf(u8, compile_hint, "glslc") != null);
    try testing.expect(std.mem.indexOf(u8, compile_hint, "vulkan1.2") != null);
}
