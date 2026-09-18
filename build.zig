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

    // Lyngvi's shaders, and where their SPIR-V comes from. See `ShaderSource`.
    //
    //   zig build -Dshaders=glsl    compile src/gleipnir/shader/*.vert|frag
    //   zig build -Dshaders=slang   compile src/gleipnir/shader/slang/*.slang
    //   zig build -Dshaders=spirv   embed src/gleipnir/shader/spirv/*.spv as is
    //   zig build spirv             regenerate that directory from the source
    //                               -Dshaders names (glsl unless told)
    const shader_source = b.option(
        ShaderSource,
        "shaders",
        "Where the SPIR-V comes from: auto, glsl, slang or spirv (default: auto)",
    ) orelse .auto;
    const glsl_compiler = b.option(
        GlslCompiler,
        "glsl-compiler",
        "Which GLSL compiler -Dshaders=glsl runs: auto, glslc or glslang (default: auto)",
    ) orelse .auto;
    const slangc_path = b.option([]const u8, "slangc", "Path to slangc, when it is not on PATH");
    const shaders = compileShaders(b, shader_source, glsl_compiler, slangc_path);

    // Which path rasteriser the *window* uses, and which `--path` will
    // accept.
    //
    // `both` is the point of it: the
    // CPU rasteriser is the reference, the GPU one is the model of the
    // shader, and a build with both can draw the same page each way and
    // subtract. `fenrir raster --path both` is that comparison.
    //
    // A release build may pick one, and `-Dpath=gpu` builds a reader that
    // never rasterises a page on the CPU while `-Dpath=cpu` builds one that
    // never creates the analytic pipeline -- for a machine whose driver
    // cannot be trusted with it.
    //
    // The default stays `both` in every mode, and deliberately: a build with
    // both is a build that can check one against the other. The GPU path
    // draws images and the blend modes documents use, and the CPU one is
    // still the only one with all sixteen modes.
    //
    // What this does *not* do is remove the CPU rasteriser from the binary.
    // `fenrir raster` and `fenrir read --shot` both render with no device in
    // the process and would have nothing to render with; the flag decides
    // what the window does, not what the program contains.
    //
    // This is one option and not two booleans because there is no fourth
    // state: a build with neither draws nothing.
    const path_backend = b.option(
        PathBackend,
        "path",
        "Which path rasteriser the window uses: cpu, gpu, or both (default: both)",
    ) orelse PathBackend.both;

    // Mímir's store. SQLite is the one library this project links on purpose:
    // the recent files, the settings and the reading positions are small,
    // structured, and have to survive a crash mid-write, which is a
    // transactional database and not a file format worth inventing. It is
    // compiled from the amalgamation by this build -- one C file, pinned by
    // hash in `build.zig.zon` -- rather than linked from the system.
    //
    // A lazy dependency, so `-Dsqlite=false` neither downloads nor compiles
    // it and the binary links no C at all. Everything else still works; the
    // reader simply forgets where you were.
    const want_sqlite = b.option(bool, "sqlite", "Store recent files, places, settings and highlights in SQLite (default: true)") orelse true;
    // Resolved before the module is created, because `build_options` has to
    // say whether Mímir has a database; linked after, which is below.
    const sqlite_dep = if (want_sqlite) b.lazyDependency("sqlite", .{}) else null;
    const have_sqlite = sqlite_dep != null;

    // Galdr, the plugin system, and the Lua it runs. The second library this
    // project links on purpose, compiled from the pinned release by this
    // build exactly as SQLite is. `-Dlua=false` builds a reader that runs no
    // scripts, and links no Lua.
    const want_lua = b.option(bool, "lua", "Run Lua plugins and init.lua with Galdr (default: true)") orelse true;
    const lua_dep = if (want_lua) b.lazyDependency("lua", .{}) else null;

    const opts = b.addOptions();
    opts.addOption(bool, "sqlite", have_sqlite);
    opts.addOption(bool, "lua", lua_dep != null);
    opts.addOption(bool, "path_cpu", path_backend != .gpu);
    opts.addOption(bool, "path_gpu", path_backend != .cpu);
    opts.addOption([]const u8, "path_backend", @tagName(path_backend));
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

    if (sqlite_dep) |dep| {
        const sqlite = b.addLibrary(.{
            .name = "sqlite3",
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        sqlite.root_module.addCSourceFile(.{
            .file = dep.path("sqlite3.c"),
            .flags = &sqlite_flags,
        });
        fenrir.link_libc = true;
        fenrir.linkLibrary(sqlite);
    }

    if (lua_dep) |dep| {
        const lua = b.addLibrary(.{
            .name = "lua",
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        // Every library file, and neither of the two programs: `lua.c` is the
        // interpreter's `main` and `luac.c` the compiler's.
        const flags: []const []const u8 = if (target.result.os.tag == .windows)
            &lua_flags
        else
            &(lua_flags ++ [_][]const u8{"-DLUA_USE_POSIX"});
        lua.root_module.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &lua_sources,
            .flags = flags,
        });
        fenrir.link_libc = true;
        fenrir.linkLibrary(lua);
    }

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

    // Lyngvi's Wayland backend, and the Vulkan loader on every Unix, open
    // their libraries with the system's `dlopen`. That is not a preference.
    // The Vulkan driver loads libwayland-client itself and calls it on the
    // `wl_display` this process hands over, so there must be exactly one
    // libwayland in the process -- the one the system dynamic linker loaded.
    // Zig's own ELF loader, which is what `std.DynLib` uses without libc,
    // would map a second private copy, and the driver would be handed proxies
    // belonging to a library it has never seen. Nothing is linked at build
    // time: libwayland, libxkbcommon and libvulkan are all found when the
    // program runs, so the binary still starts on a machine without them.
    if (target.result.os.tag == .linux or target.result.os.tag.isBSD()) {
        fenrir.link_libc = true;
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

    // `zig build spirv`: the modules this build compiled, written back into
    // the tree, so a checkout builds with `-Dshaders=spirv` and no compiler.
    const spirv_step = b.step("spirv", "Regenerate src/gleipnir/shader/spirv/ from -Dshaders=glsl|slang");
    if (shaders.generated) {
        const update = b.addUpdateSourceFiles();
        for (shader_stages, 0..) |stage, i| {
            update.addCopyFileToSource(shaders.spv[i], b.fmt("{s}/spirv/{s}.spv", .{ shader_dir, stage }));
        }
        spirv_step.dependOn(&update.step);
    } else {
        spirv_step.dependOn(&b.addFail(
            "nothing to write: this build compiled no shaders. Pass -Dshaders=glsl or -Dshaders=slang.",
        ).step);
    }
}

/// The two rasterisers, and the build that keeps both.
///
///   **cpu** -- `gleipnir/raster.zig`, stencil-then-cover with multisampling,
///   into a framebuffer that is then uploaded as a texture. Needs no device
///   and is the reference every other answer is checked against.
///
///   **gpu** -- `gleipnir/slugpipe.zig`, analytic coverage from the outline
///   in the fragment shader. Resolution independent, one draw call a page, no
///   stencil attachment and no multisampling.
const PathBackend = enum { cpu, gpu, both };

/// How SQLite is compiled. Each of these either removes something this
/// program does not use or refuses something it should never do.
///
/// `DQS=0` makes a double-quoted string a syntax error rather than a fallback
/// to an identifier, which is the misfeature that turns a typo in a column
/// name into a silently constant string. `THREADSAFE=1` because the reader
/// has a rasterising thread and the frame loop, and a serialised connection
/// is cheaper than the rule that only one of them may ever touch it.
const sqlite_flags = [_][]const u8{
    "-DSQLITE_DQS=0",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
    "-DSQLITE_MAX_EXPR_DEPTH=0",
    "-DSQLITE_OMIT_DECLTYPE",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_OMIT_AUTOINIT",
    "-DSQLITE_USE_ALLOCA",
};

/// Lua's library, file by file: everything in `src/` but the two programs.
/// `loadlib.c`, `liolib.c` and `loslib.c` are compiled and never opened --
/// Galdr's sandbox does not load `package`, `io` or `os` -- because leaving
/// them out would mean patching `linit.c`, and an untouched upstream source
/// is worth a few unused kilobytes.
const lua_sources = [_][]const u8{
    "lapi.c",    "lcode.c",   "lctype.c",  "ldebug.c",   "ldo.c",     "ldump.c",
    "lfunc.c",   "lgc.c",     "llex.c",    "lmem.c",     "lobject.c", "lopcodes.c",
    "lparser.c", "lstate.c",  "lstring.c", "ltable.c",   "ltm.c",     "lundump.c",
    "lvm.c",     "lzio.c",    "lauxlib.c", "lbaselib.c", "lcorolib.c", "ldblib.c",
    "liolib.c",  "lmathlib.c", "loadlib.c", "loslib.c",  "lstrlib.c", "ltablib.c",
    "lutf8lib.c", "linit.c",
};

/// Lua compiles cleanly as C99. Nothing is tuned: the defaults -- 64-bit
/// integers, double floats -- are what the declarations in
/// `src/galdr/lua.zig` are written against, and changing either here without
/// changing them there is a stack corrupted at run time.
const lua_flags = [_][]const u8{
    "-std=gnu99",
};

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
    "slug.vert",
    "slug.frag",
};

/// The headers a stage may `#include`. Listed as build inputs for every stage
/// rather than per stage: over-invalidating recompiles four small shaders,
/// under-invalidating ships a pipeline whose two halves disagree about a
/// struct layout, and only one of those is recoverable by looking at it.
const shader_headers = [_][]const u8{ "rect.glsl", "path.glsl", "slug.glsl" };

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

/// Where the SPIR-V in the binary comes from.
///
///   **glsl** -- `src/gleipnir/shader/*.vert` and `*.frag`, through glslc or
///   glslang. The GLSL is the source every other form is checked against.
///
///   **slang** -- `src/gleipnir/shader/slang/*.slang`, through slangc: one
///   module per pipeline with a `vertexMain` and a `fragmentMain`. Held to
///   the same tests as the GLSL, including the one that reads every storage
///   buffer's layout back out of the compiled module.
///
///   **spirv** -- `src/gleipnir/shader/spirv/*.spv`, committed, embedded as
///   they are. No compiler at all, which is what a machine with a driver and
///   no SDK needs to get a window that draws. `zig build spirv` rewrites the
///   directory from whichever of the other two `-Dshaders` names.
///
///   **auto** -- glsl if a GLSL compiler is on PATH, else spirv if the
///   committed modules are there, else a binary with no shaders that opens a
///   window and says what is missing.
///
/// An explicit choice whose tool or files are missing fails the build and
/// says so; only `auto` falls back.
const ShaderSource = enum { auto, glsl, slang, spirv };

const GlslCompiler = enum { auto, glslc, glslang };

const Shaders = struct {
    spv: [shader_stages.len]std.Build.LazyPath,
    compiled: bool,
    /// What made them, for `lyngvi_shader_compiler`: `glslc`, `glslang`,
    /// `slangc`, `spirv` for the committed modules, or empty.
    compiler: []const u8,
    /// True when these came out of a compiler this build ran, which is what
    /// `zig build spirv` can write back into the tree.
    generated: bool = false,
};

fn compileShaders(
    b: *std.Build,
    source: ShaderSource,
    glsl_compiler: GlslCompiler,
    slangc_path: ?[]const u8,
) Shaders {
    switch (source) {
        .glsl => return compileGlsl(b, glsl_compiler) orelse
            fatal("-Dshaders=glsl needs glslc or glslang on PATH (or pick -Dshaders=spirv)", .{}),
        .slang => {
            const exe = slangc_path orelse (b.findProgram(&.{"slangc"}, &.{}) catch
                fatal("-Dshaders=slang needs slangc on PATH, or -Dslangc=<path>", .{}));
            return compileSlang(b, exe);
        },
        .spirv => return prebuilt(b) orelse
            fatal("-Dshaders=spirv needs {s}/spirv/*.spv; run `zig build spirv` where a compiler is installed", .{shader_dir}),
        .auto => {
            if (compileGlsl(b, glsl_compiler)) |s| return s;
            if (prebuilt(b)) |s| return s;
            // Empty rather than absent, so `@embedFile` still resolves and
            // the failure is one `if` at pipeline creation rather than a
            // conditional import.
            const empty = b.addWriteFiles();
            var out: Shaders = .{ .spv = undefined, .compiled = false, .compiler = "" };
            for (shader_stages, 0..) |stage, i| {
                out.spv[i] = empty.add(b.fmt("{s}.spv", .{stage}), "");
            }
            return out;
        },
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Three names, because the same job has three spellings. `glslc` is
/// shaderc's. `glslang` is the current name of the Khronos reference
/// compiler, and `glslangValidator` is what it was called before 14.0 and
/// still is in a Linux distribution's `glslang-tools` package.
fn compileGlsl(b: *std.Build, which: GlslCompiler) ?Shaders {
    if (which != .glslang) {
        if (b.findProgram(&.{"glslc"}, &.{})) |exe| {
            return compileGlslWith(b, .glslc, exe);
        } else |_| {
            if (which == .glslc) fatal("-Dglsl-compiler=glslc: glslc is not on PATH", .{});
        }
    }
    if (b.findProgram(&.{ "glslang", "glslangValidator" }, &.{})) |exe| {
        return compileGlslWith(b, .glslang, exe);
    } else |_| {
        if (which == .glslang) fatal("-Dglsl-compiler=glslang: glslang is not on PATH", .{});
    }
    return null;
}

fn compileGlslWith(b: *std.Build, which: GlslCompiler, exe: []const u8) Shaders {
    // Absolute. The step runs with the cache directory as its working
    // directory and is handed an absolute path to the shader, so a relative
    // include path resolves against the wrong root and the only symptom is
    // `'#include' : must be followed by a header name` about a file that is
    // plainly there.
    const include = b.pathFromRoot(shader_dir);

    var out: Shaders = .{
        .spv = undefined,
        .compiled = true,
        .compiler = @tagName(which),
        .generated = true,
    };
    for (shader_stages, 0..) |stage, i| {
        const run = switch (which) {
            // `-O` is shaderc's optimiser. glslang has no equivalent without
            // linking SPIRV-Tools, and the difference is a few hundred bytes
            // of module that the driver's own compiler folds away anyway.
            .glslc, .auto => b.addSystemCommand(&.{ exe, "-I", include, "--target-env=vulkan1.2", "-O" }),
            // glslang wants the include directory attached to the flag, and
            // rejects it as a separate argument.
            .glslang => b.addSystemCommand(&.{
                exe,
                "-V",
                "--quiet",
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

/// `slangc <pipeline>.slang -entry vertexMain -stage vertex`, and the same
/// for the fragment half. Slang names the SPIR-V entry point `main` unless
/// told otherwise, which is what the pipelines ask for.
fn compileSlang(b: *std.Build, exe: []const u8) Shaders {
    var out: Shaders = .{ .spv = undefined, .compiled = true, .compiler = "slangc", .generated = true };
    for (shader_stages, 0..) |stage, i| {
        const dot = std.mem.indexOfScalar(u8, stage, '.').?;
        const module = stage[0..dot];
        const kind = stage[dot + 1 ..];
        const is_vertex = std.mem.eql(u8, kind, "vert");
        const run = b.addSystemCommand(&.{exe});
        run.addFileArg(b.path(b.fmt("{s}/slang/{s}.slang", .{ shader_dir, module })));
        run.addArgs(&.{
            "-target",                                        "spirv",
            "-entry",                                         if (is_vertex) "vertexMain" else "fragmentMain",
            "-stage",                                         if (is_vertex) "vertex" else "fragment",
            "-o",
        });
        out.spv[i] = run.addOutputFileArg(b.fmt("{s}.spv", .{stage}));
    }
    return out;
}

/// The committed modules, if every one of them is there.
fn prebuilt(b: *std.Build) ?Shaders {
    var out: Shaders = .{ .spv = undefined, .compiled = true, .compiler = "spirv" };
    for (shader_stages, 0..) |stage, i| {
        const sub = b.fmt("{s}/spirv/{s}.spv", .{ shader_dir, stage });
        b.build_root.handle.access(b.graph.io, sub, .{}) catch return null;
        out.spv[i] = b.path(sub);
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
