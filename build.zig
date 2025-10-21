const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Týr's glyph backends. These flags decide what is *linked*; which backend
    // opens a given font is still a runtime decision, so a build with both can
    // render the same page each way and diff the two. See src/tyr/registry.zig.
    const want_freetype = b.option(bool, "freetype", "Link FreeType as a glyph backend") orelse false;
    const want_stb = b.option(bool, "stb-truetype", "Compile stb_truetype as a glyph backend (needs vendor/stb/stb_truetype.h)") orelse false;
    const want_harfbuzz = b.option(bool, "harfbuzz", "Link HarfBuzz as the UI text shaper") orelse false;
    const font_default = b.option([]const u8, "font-backend", "Glyph backend to try first at runtime") orelse "";

    // Explicit paths, for the platforms where `linkSystemLibrary` cannot find
    // anything on its own. It resolves a name through pkg-config, which is a
    // reasonable assumption on Linux and a poor one on Windows, where there is
    // usually no pkg-config and no convention about where a library lives.
    // Giving the paths by hand is then the difference between a build and a
    // link error about a name nobody can act on.
    //
    //   zig build -Dfreetype -Dfreetype-include=C:/dev/freetype/include/freetype2 \
    //                        -Dfreetype-lib=C:/dev/freetype/lib
    //
    // The include path is the directory containing `ft2build.h`, which in a
    // normal install is `<prefix>/include/freetype2` and not `<prefix>/include`.
    const freetype_include = b.option([]const u8, "freetype-include", "Directory containing ft2build.h");
    const freetype_lib = b.option([]const u8, "freetype-lib", "Directory containing the FreeType import library");
    const harfbuzz_include = b.option([]const u8, "harfbuzz-include", "Directory containing hb.h");
    const harfbuzz_lib = b.option([]const u8, "harfbuzz-lib", "Directory containing the HarfBuzz import library");

    if (want_stb and !hasStbHeader(b)) {
        std.debug.print(
            \\-Dstb-truetype needs the header vendored first:
            \\
            \\    mkdir -p vendor/stb
            \\    curl -Lo vendor/stb/stb_truetype.h https://raw.githubusercontent.com/nothings/stb/master/stb_truetype.h
            \\
        , .{});
        std.process.exit(1);
    }

    // Lyngvi's shaders. The GLSL is the source of truth and SPIR-V is what a
    // driver takes, so the translation belongs to the build -- but a shader
    // compiler is part of the Vulkan SDK, and requiring the SDK to build a PDF
    // reader is exactly the dependency `vk.zig` exists to avoid. So: compile
    // them if a compiler is on PATH, and if not, build a binary that opens a
    // window, creates a device, and refuses to make a pipeline with a message
    // naming the command that would fix it.
    const shaders = compileShaders(b);

    const opts = b.addOptions();
    opts.addOption(bool, "tyr_freetype", want_freetype);
    opts.addOption(bool, "tyr_stb_truetype", want_stb);
    opts.addOption(bool, "tyr_harfbuzz", want_harfbuzz);
    opts.addOption([]const u8, "tyr_default", font_default);
    opts.addOption(bool, "lyngvi_spirv", shaders.compiled);
    opts.addOption([]const u8, "lyngvi_shader_compiler", shaders.compiler);

    // The library: everything that understands PDF, with no I/O policy of its
    // own. Consumers hand it bytes and an allocator.
    const fenrir = b.addModule("fenrir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fenrir.addOptions("build_options", opts);

    // `@embedFile`d by `lyngvi/shaders.zig`. Always present, empty when there
    // was nothing to compile them with, so the import never has to be
    // conditional in the Zig source.
    inline for (shader_stages, 0..) |stage, i| {
        fenrir.addAnonymousImport(comptime importName(stage), .{ .root_source_file = shaders.spv[i] });
    }

    // Lyngvi's Win32 backend. Declared rather than imported -- there is no
    // `windows.h` anywhere in this project -- but the symbols still have to
    // resolve, and `user32` is where they live. `kernel32` is linked for every
    // Windows target already.
    if (target.result.os.tag == .windows) {
        fenrir.linkSystemLibrary("user32", .{});
    }

    if (want_freetype) {
        fenrir.link_libc = true;
        linkC(fenrir, "freetype2", "freetype", freetype_include, freetype_lib);
    }
    if (want_harfbuzz) {
        fenrir.link_libc = true;
        linkC(fenrir, "harfbuzz", "harfbuzz", harfbuzz_include, harfbuzz_lib);
    }
    if (want_stb) {
        // Header-only, so nothing to link: the implementation is compiled into
        // the backend's translation unit by STB_TRUETYPE_IMPLEMENTATION.
        fenrir.link_libc = true;
        fenrir.addIncludePath(b.path("vendor/stb"));
    }

    // The `fenrir` CLI is a thin shell over the library. Keeping them in
    // separate modules keeps accidental I/O dependencies out of the core.
    const exe = b.addExecutable(.{
        .name = "fenrir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fenrir", .module = fenrir }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the fenrir CLI").dependOn(&run_cmd.step);

    const lib_tests = b.addRunArtifact(b.addTest(.{ .root_module = fenrir }));
    const exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&lib_tests.step);
    test_step.dependOn(&exe_tests.step);
}

const shader_dir = "src/gleipnir/shader";

/// Every stage the build compiles, in the order `shaders.spv` returns them.
/// Adding one here is the only edit needed: the anonymous import name is
/// derived from the file name, and `lyngvi/shaders.zig` declares the matching
/// `@embedFile`.
const shader_stages = [_][]const u8{
    "rect.vert",
    "rect.frag",
    "path.vert",
    "path.frag",
};

/// The headers a stage may `#include`. Listed as build inputs for every stage
/// rather than per stage: over-invalidating recompiles four small shaders,
/// under-invalidating ships a pipeline whose two halves disagree about a
/// struct layout, and only one of those is recoverable by looking at it.
const shader_headers = [_][]const u8{ "rect.glsl", "path.glsl" };

/// `rect.vert` -> `rect_vert_spv`. Comptime, because `addAnonymousImport`
/// takes a name that has to match the `@embedFile` on the Zig side, and a
/// mismatch there is a compile error rather than something discovered later.
fn importName(comptime stage: []const u8) []const u8 {
    comptime {
        var buf: [stage.len + 4]u8 = undefined;
        @memcpy(buf[0..stage.len], stage);
        @memcpy(buf[stage.len..], "_spv");
        for (buf[0..stage.len]) |*c| {
            if (c.* == '.') c.* = '_';
        }
        const out = buf;
        return &out;
    }
}

const Shaders = struct {
    spv: [shader_stages.len]std.Build.LazyPath,
    compiled: bool,
    compiler: []const u8,
};

/// Turns `src/gleipnir/shader/*.{vert,frag}` into SPIR-V, if anything on this
/// machine can.
///
/// Three names, because the same job has three spellings. `glslc` is shaderc's
/// and the one the compile command in `gleipnir/pipeline.zig` is written for.
/// `glslang` is the current name of the Khronos reference compiler, and
/// `glslangValidator` is what it was called before 14.0 and still is in a
/// Linux distribution's `glslang-tools` package. Finding none is not an error:
/// the build succeeds with empty modules and `lyngvi_spirv` false, which is
/// what makes `zig build test` work on a machine with a driver and no SDK.
fn compileShaders(b: *std.Build) Shaders {
    if (b.findProgram(&.{"glslc"}, &.{})) |exe| {
        return compileWith(b, .glslc, exe, "glslc");
    } else |_| {}

    // Both spellings take identical flags -- it is the same binary under two
    // names -- so the only thing that differs is which one is on PATH.
    if (b.findProgram(&.{ "glslang", "glslangValidator" }, &.{})) |exe| {
        return compileWith(b, .glslang, exe, "glslang");
    } else |_| {}

    // Empty rather than absent, so `@embedFile` still resolves and the failure
    // is one `if` at pipeline creation rather than a conditional import.
    const empty = b.addWriteFiles();
    var out: Shaders = .{ .spv = undefined, .compiled = false, .compiler = "" };
    for (shader_stages, 0..) |stage, i| {
        out.spv[i] = empty.add(b.fmt("{s}.spv", .{stage}), "");
    }
    return out;
}

const Compiler = enum { glslc, glslang };

fn compileWith(b: *std.Build, which: Compiler, exe: []const u8, label: []const u8) Shaders {
    // Absolute. The step runs with the cache directory as its working
    // directory and is handed an absolute path to the shader, so a relative
    // include path resolves against the wrong root and the only symptom is
    // `'#include' : must be followed by a header name` about a file that is
    // plainly there.
    const include = b.pathFromRoot(shader_dir);

    var out: Shaders = .{ .spv = undefined, .compiled = true, .compiler = label };
    for (shader_stages, 0..) |stage, i| {
        const run = switch (which) {
            // `-O` is shaderc's optimiser. glslang has no equivalent without
            // linking SPIRV-Tools, and the difference is a few hundred bytes
            // of module that the driver's own compiler folds away anyway.
            .glslc => b.addSystemCommand(&.{ exe, "-I", include, "--target-env=vulkan1.2", "-O" }),
            // glslang wants the include directory attached to the flag, and
            // rejects it as a separate argument.
            .glslang => b.addSystemCommand(&.{
                exe,
                "-V",
                "--target-env",
                "vulkan1.2",
                b.fmt("-I{s}", .{include}),
            }),
        };
        run.addFileArg(b.path(b.fmt("{s}/{s}", .{ shader_dir, stage })));
        for (shader_headers) |header| {
            run.addFileInput(b.path(b.fmt("{s}/{s}", .{ shader_dir, header })));
        }
        run.addArg("-o");
        out.spv[i] = run.addOutputFileArg(b.fmt("{s}.spv", .{stage}));
    }
    return out;
}

/// Checked here rather than left to a `file not found` from inside `@cImport`,
/// which reports the failure as a Zig compile error three layers deep with no
/// hint that a download is what is missing.
fn hasStbHeader(b: *std.Build) bool {
    b.build_root.handle.access(b.graph.io, "vendor/stb/stb_truetype.h", .{}) catch return false;
    return true;
}

/// Links a C library either through pkg-config or through paths given by hand.
///
/// `pc_name` is what pkg-config calls it and `lib_name` is what the linker
/// does, and they differ for exactly the library that needs this most:
/// pkg-config knows `freetype2`, the import library is `freetype`.
fn linkC(
    module: *std.Build.Module,
    pc_name: []const u8,
    lib_name: []const u8,
    include: ?[]const u8,
    lib_dir: ?[]const u8,
) void {
    if (include) |dir| {
        module.addIncludePath(.{ .cwd_relative = dir });
        if (lib_dir) |ldir| module.addLibraryPath(.{ .cwd_relative = ldir });
        // pkg-config is skipped rather than tried first: on a machine where
        // the paths were given by hand it is usually absent, and its failure
        // is reported as a build error rather than as a fallback.
        module.linkSystemLibrary(lib_name, .{ .use_pkg_config = .no });
        return;
    }
    module.linkSystemLibrary(pc_name, .{});
}
