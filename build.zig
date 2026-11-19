const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // One resolved configuration, computed before any module or step exists.
    // Everything below reads `caps` and never asks for an option again: which
    // commands are registered, which modules are created, which dependencies
    // are fetched, which shader stages are compiled. A flag read in two
    // places is a flag two halves of the build can disagree about, and the
    // symptom of that is a binary whose help text offers a command its
    // comptime table does not contain.
    const caps = resolve(b);
    const optimize = caps.optimize;

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
    const shaders = compileShaders(b, shader_source, glsl_compiler, slangc_path, caps.stages());

    // Mímir's store and Galdr's Lua, fetched only if this configuration has
    // them. Both are `lazy` in `build.zig.zon`, so a profile that carries no
    // database and no plugin host neither downloads nor compiles a line of C
    // -- which costs nothing but asking in this order.
    const sqlite_dep = if (caps.store) b.lazyDependency("sqlite", .{}) else null;
    const lua_dep = if (caps.plugins) b.lazyDependency("lua", .{}) else null;

    // A lazy dependency answers null on the run that fetches it, so what the
    // binary *has* is not what the profile asked for until the archive is
    // there. `build_options` says what is actually linked.
    const have_sqlite = sqlite_dep != null;
    const have_lua = lua_dep != null;

    const opts = b.addOptions();
    opts.addOption([]const u8, "profile", @tagName(caps.profile));
    opts.addOption(bool, "sqlite", have_sqlite);
    opts.addOption(bool, "lua", have_lua);
    opts.addOption(bool, "path_cpu", caps.path_cpu);
    opts.addOption(bool, "path_gpu", caps.path_gpu);
    opts.addOption(bool, "tools", caps.tools);
    opts.addOption(bool, "config", caps.config);
    opts.addOption(bool, "splits", caps.splits);
    opts.addOption(bool, "marks", caps.marks);
    opts.addOption(bool, "search", caps.search);
    opts.addOption(bool, "panels", caps.panels);
    opts.addOption(bool, "compare", caps.compare);
    opts.addOption(bool, "diagnostics", caps.diagnostics);
    opts.addOption(bool, "bench", caps.bench);
    opts.addOption(bool, "instruments", caps.instruments);
    opts.addOption(bool, "stripped", caps.strip);
    opts.addOption(bool, "shader_path", caps.shader_path);
    opts.addOption(bool, "shader_slug", caps.path_gpu);
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
        // Stripping and optimising are different decisions: `-Dstrip` is its
        // own axis so a profile cannot end up with either unreadable stacks
        // or a binary nobody wants to ship. Runtime error messages survive
        // it; they are what a user reports.
        .strip = caps.strip,
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
    //
    // pkg-config is turned off for the same reason `linkC` turns it off: it is
    // asked by default, it cannot describe a Windows system library, and on
    // 0.17 its absence is a build error rather than a fallback.
    if (target.result.os.tag == .windows) {
        fenrir.linkSystemLibrary("user32", .{ .use_pkg_config = .no });
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
        // Header-only, so nothing to link: the implementation is translated
        // with the declarations by STB_TRUETYPE_IMPLEMENTATION, below.
        fenrir.link_libc = true;
    }

    // The three C backends' headers. Each is a module because 0.17 removed
    // `@cImport`, and each is present whether or not its flag is on.
    cHeader(b, fenrir, target, optimize, .{
        .name = "freetype_c",
        .header = "freetype.h",
        .wanted = want_freetype,
        .include = if (freetype_include) |dir| b.graph.cwdRelativePath(dir) else null,
    });
    cHeader(b, fenrir, target, optimize, .{
        .name = "harfbuzz_c",
        .header = "harfbuzz.h",
        .wanted = want_harfbuzz,
        .include = if (harfbuzz_include) |dir| b.graph.cwdRelativePath(dir) else null,
    });
    cHeader(b, fenrir, target, optimize, .{
        .name = "stb_c",
        .header = "stb.h",
        .wanted = want_stb,
        .include = b.path("vendor/stb"),
        .defines = &.{
            .{ "STB_TRUETYPE_IMPLEMENTATION", "1" },
            .{ "STBTT_STATIC", "1" },
        },
    });

    // The `fenrir` CLI is a thin shell over the library. Keeping them in
    // separate modules keeps accidental I/O dependencies out of the core.
    const exe = b.addExecutable(.{
        .name = "fenrir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = caps.strip,
            .imports = &.{.{ .name = "fenrir", .module = fenrir }},
        }),
    });

    // `zig-out/<profile>-<path>/bin/`, so building a second configuration
    // does not destroy the first. Not tidiness: the benchmark method in
    // OPTIMIZING.md needs both binaries to exist at once and to be run
    // interleaved, and an install that overwrites the thing being compared
    // against guarantees the comparison measures CPU frequency drift.
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{caps.dir(b)}) } },
    });
    b.getInstallStep().dependOn(&install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the fenrir CLI").dependOn(&run_cmd.step);

    const lib_tests = b.addRunArtifact(b.addTest(.{ .root_module = fenrir }));
    const exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&lib_tests.step);
    test_step.dependOn(&exe_tests.step);

    // `zig build spirv`: the modules this build compiled, written back into
    // the tree, so a checkout builds with `-Dshaders=spirv` and no compiler.
    const spirv_step = b.step("spirv", "Regenerate src/gleipnir/shader/spirv/ from -Dshaders=glsl|slang");
    if (!shaders.generated) {
        spirv_step.dependOn(&b.addFail(
            "nothing to write: this build compiled no shaders. Pass -Dshaders=glsl or -Dshaders=slang.",
        ).step);
    } else if (!caps.allStages()) {
        // Every stage, or none of them. A profile that left a stage out holds
        // an empty module in its place, and writing that back would delete a
        // committed shader -- silently, and only noticed by the next person
        // who builds with -Dshaders=spirv.
        spirv_step.dependOn(&b.addFail(
            "this profile compiles only the shader stages it uses, so it cannot rewrite " ++
                "spirv/ without deleting the rest. Use -Dprofile=debug.",
        ).step);
    } else {
        const update = b.addUpdateSourceFiles();
        for (shader_stages, 0..) |stage, i| {
            update.addCopyFileToSource(shaders.spv[i], b.fmt("{s}/spirv/{s}.spv", .{ shader_dir, stage }));
        }
        spirv_step.dependOn(&update.step);
    }
}

/// What this binary contains, resolved once from the options and read
/// everywhere after.
///
/// Three jobs want three binaries, and they are not the same binary with
/// flags on it:
///
///   **light** -- a viewer that opens now. A LaTeX edit-compile-look loop
///   wants a window that is already there and redraws the page the compiler
///   just wrote: no database, no plugin host, no editing surface, nothing to
///   initialise. It renders exactly what the others render -- the same Gjöll,
///   the same Gelgja, the same Gleipnir -- because a viewer that is fast
///   because it is less correct is not a viewer worth having.
///
///   **debug** -- everything, for finding out what is wrong. Both rasterisers
///   in one binary so a page can be drawn each way and subtracted, every
///   diagnostic command, and symbols.
///
///   **release** -- the reader people use: reader, editor, persistence and
///   plugins, and none of the benchmark drivers, tracing or diagnostic
///   capture that exist to answer questions about fenrir rather than about a
///   document.
///
/// `-Doptimize` is deliberately off this axis, so `debug` can be ReleaseFast
/// when a bug only appears there and `release` can be Debug while something
/// is chased.
const Profile = enum { light, debug, release };

const Caps = struct {
    profile: Profile,
    /// What `-Dpath` named, which is what the *window* reaches for first.
    path: PathBackend,
    optimize: std.builtin.Optimize,
    strip: bool,

    /// Which rasterisers are *in* the binary. In `light` and `release` these
    /// follow `path` exactly; in `debug` both are always true, and
    /// deliberately -- `fenrir raster` is the reference every GPU answer is
    /// checked against, so a build that honestly excluded the CPU rasteriser
    /// could not check itself, and `debug` exists to check things.
    path_cpu: bool,
    path_gpu: bool,

    /// Mímir: recent files, places, settings, stored marks.
    store: bool,
    /// Galdr: Lua, init.lua, plugins.
    plugins: bool,
    /// `fenrir.toml`: the reader's options and settings, read from a file at
    /// start. Not in `light`, which reads nothing it was not handed on its
    /// command line: a viewer that opens now has no file to look for first.
    config: bool,
    /// The split tree, the tabpages and their bar, and more than one
    /// document open at once. Without them the reader is one window on one
    /// document -- `hlidskjalf.OneWindow` where `Tabs` would be -- and a
    /// second file is refused by name rather than opened into a buffer that
    /// nothing could show.
    splits: bool,
    /// Highlights, notes and ink, and the caret and visual mode that select
    /// what a highlight is made on. One capability and not two because a
    /// selection has nowhere else to go: there is no clipboard, and the
    /// author asked that a selection never be stored. Without them the
    /// reader has normal mode and the command line, `j` and `k` scroll, and
    /// a file's own annotations are drawn in the page as `raster` draws them.
    marks: bool,
    /// `/`: the bar, the scan of every page's text behind it, and the
    /// matches drawn over the page. Not in `light`, which then never builds
    /// a page's text unless something else asks for it.
    search: bool,
    /// The rails down either side of the page, the panel they open, the
    /// command palette and the settings page: the interface beyond the
    /// status bar. Not in `light`, whose window is the page and the bar
    /// under it, and whose pages have the width the rails would take.
    panels: bool,
    /// `fenrir diff` and the reader's comparison overlay.
    compare: bool,
    /// The commands that answer questions about fenrir rather than about a
    /// document: `dump`, `xref`, `extract`, `trace`, `icons`, `rects`, `ui`,
    /// `view`.
    diagnostics: bool,
    /// `--time`, `--bench`, and the fixed workloads they drive.
    bench: bool,
    /// Validation layers and GPU timestamps.
    instruments: bool,
    /// The commands that report on a document or on this build: `info`,
    /// `pages`, `fonts`, `health`, `commands`. Off only in `light`, whose
    /// surface is the document and nothing else.
    tools: bool,

    /// `path.vert`/`path.frag`. The stencil-then-cover pipeline has no Vulkan
    /// consumer at all -- `gleipnir/pathpipe.zig` is a contract with no
    /// implementor, and the two modules are reached only by
    /// `lyngvi/shaders.zig`'s own layout tests. So they belong in `debug` and
    /// nowhere else. That is not permission to delete them: the contract is
    /// what the CPU rasteriser is written against.
    shader_path: bool,

    /// Which shader stages this configuration compiles. The rest are empty
    /// modules, so the `@embedFile` still resolves.
    fn stages(c: Caps) [shader_stages.len]bool {
        var out: [shader_stages.len]bool = undefined;
        for (shader_stages, 0..) |stage, i| {
            out[i] = if (std.mem.startsWith(u8, stage, "rect."))
                true // common presentation, in every build
            else if (std.mem.startsWith(u8, stage, "slug."))
                c.path_gpu
            else
                c.shader_path;
        }
        return out;
    }

    fn allStages(c: Caps) bool {
        for (c.stages()) |on| {
            if (!on) return false;
        }
        return true;
    }

    fn dir(c: Caps, b: *std.Build) []const u8 {
        return b.fmt("{t}-{t}", .{ c.profile, c.path });
    }
};

/// Resolves every option into one `Caps`, and refuses a configuration that
/// contradicts itself with a sentence rather than a warning.
fn resolve(b: *std.Build) Caps {
    const profile = b.option(
        Profile,
        "profile",
        "What the binary contains: light, debug or release (default: debug)",
    ) orelse .debug;

    // Read by hand rather than through `standardOptimizeOption`, which only
    // offers a default by *replacing* `-Doptimize` with `-Drelease`. The
    // profile is allowed to prefer a mode; it is not allowed to take the axis
    // away.
    const optimize: std.builtin.Optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.graph.release_mode) {
        .off => switch (profile) {
            // What this project already recommends for reading documents:
            // fast, and it still stops on a bad index instead of drawing
            // garbage. Whether ReleaseFast is worth the lost check is a
            // question for the benchmark matrix, not for a preference.
            .light, .release => .safe,
            .debug => .debug,
        },
        // `--release` with no mode asks for the one this project declares,
        // and it is the same answer whichever profile asked.
        .any, .safe => .safe,
        .fast => .fast,
        .small => .small,
    };

    // Which path rasteriser the window uses, and which `--path` will accept.
    //
    // `both` is the point of it in `debug`: the CPU rasteriser is the
    // reference, the GPU one is the model of the shader, and a build with
    // both can draw the same page each way and subtract. `fenrir raster
    // --path both` is that comparison.
    //
    // In `light` and `release` the flag removes the other one, and a build
    // with one refuses the other by name rather than falling back. The
    // consequence is that `-Dprofile=release -Dpath=gpu` has no `raster`
    // command at all. That is correct and it is the point: a binary for a
    // machine whose driver is trusted carries nothing to fall back to.
    //
    // One option and not two booleans because there is no fourth state: a
    // build with neither draws nothing.
    const path: PathBackend = b.option(
        PathBackend,
        "path",
        "Which path rasteriser the window uses: cpu, gpu, or both (default: cpu for light, both otherwise)",
    ) orelse switch (profile) {
        .light => .cpu,
        .debug, .release => .both,
    };

    // `?bool`, so "not given" and "given true" are different facts. Only the
    // second can contradict a profile, and only a contradiction is an error.
    const want_sqlite = b.option(
        bool,
        "sqlite",
        "Store recent files, places, settings and highlights in SQLite (default: on outside -Dprofile=light)",
    );
    const want_lua = b.option(
        bool,
        "lua",
        "Run Lua plugins and init.lua with Galdr (default: on outside -Dprofile=light)",
    );
    const want_strip = b.option(bool, "strip", "Leave the symbols out (default: on outside -Dprofile=debug)");

    const light = profile == .light;
    if (light and want_sqlite == true) {
        fatal(
            \\-Dprofile=light builds no database, so -Dsqlite=true has nothing to
            \\       turn on. Use -Dprofile=release for a reader that remembers.
        , .{});
    }
    if (light and want_lua == true) {
        fatal(
            \\-Dprofile=light builds no plugin host, so -Dlua=true has nothing to
            \\       turn on. Use -Dprofile=release for a reader with plugins.
        , .{});
    }

    return .{
        .profile = profile,
        .path = path,
        .optimize = optimize,
        // Symbols follow the table in build.md: `debug` keeps them, the other
        // two do not. `-Dstrip=false` is how a release build gets a readable
        // stack out of a crash a user reported.
        .strip = want_strip orelse (profile != .debug),
        .path_cpu = profile == .debug or path != .gpu,
        .path_gpu = profile == .debug or path != .cpu,
        .store = !light and (want_sqlite orelse true),
        .plugins = !light and (want_lua orelse true),
        .config = !light,
        .splits = !light,
        .marks = !light,
        .search = !light,
        .panels = !light,
        .compare = !light,
        .diagnostics = profile == .debug,
        .bench = profile == .debug,
        .instruments = profile == .debug,
        .tools = !light,
        .shader_path = profile == .debug,
    };
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

/// `wanted` selects the stages by their consumers: `rect.*` is common
/// presentation and is in every build, `slug.*` is GPU PDF rendering, and
/// `path.*` has no Vulkan consumer at all. A stage this configuration does
/// not want gets an empty module rather than no module, so the
/// `@embedFile` on the Zig side still resolves and the payload is what
/// shrank.
fn compileShaders(
    b: *std.Build,
    source: ShaderSource,
    glsl_compiler: GlslCompiler,
    slangc_path: ?[]const u8,
    wanted: [shader_stages.len]bool,
) Shaders {
    switch (source) {
        .glsl => return compileGlsl(b, glsl_compiler, wanted) orelse
            fatal("-Dshaders=glsl needs glslc or glslang on PATH (or pick -Dshaders=spirv)", .{}),
        .slang => {
            const exe = slangc_path orelse (b.findProgram(.{ .names = &.{"slangc"} }) orelse
                fatal("-Dshaders=slang needs slangc on PATH, or -Dslangc=<path>", .{}));
            return compileSlang(b, exe, wanted);
        },
        .spirv => return prebuilt(b, wanted) orelse
            fatal("-Dshaders=spirv needs {s}/spirv/*.spv; run `zig build spirv` where a compiler is installed", .{shader_dir}),
        .auto => {
            if (compileGlsl(b, glsl_compiler, wanted)) |s| return s;
            if (prebuilt(b, wanted)) |s| return s;
            // Empty rather than absent, so `@embedFile` still resolves and
            // the failure is one `if` at pipeline creation rather than a
            // conditional import.
            var out: Shaders = .{ .spv = undefined, .compiled = false, .compiler = "" };
            for (shader_stages, 0..) |_, i| out.spv[i] = emptyStage(b, i);
            return out;
        },
    }
}

/// The placeholder for a stage nobody in this build asks for. One
/// `WriteFile` step per stage rather than one for all of them, because the
/// callers fill `spv` a stage at a time and only some of the entries are
/// empty.
fn emptyStage(b: *std.Build, i: usize) std.Build.LazyPath {
    const empty = b.addWriteFiles();
    return empty.add(b.fmt("{s}.spv", .{shader_stages[i]}), "");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Three names, because the same job has three spellings. `glslc` is
/// shaderc's. `glslang` is the current name of the Khronos reference
/// compiler, and `glslangValidator` is what it was called before 14.0 and
/// still is in a Linux distribution's `glslang-tools` package.
fn compileGlsl(b: *std.Build, which: GlslCompiler, wanted: [shader_stages.len]bool) ?Shaders {
    if (which != .glslang) {
        if (b.findProgram(.{ .names = &.{"glslc"} })) |exe| {
            return compileGlslWith(b, .glslc, exe, wanted);
        } else {
            if (which == .glslc) fatal("-Dglsl-compiler=glslc: glslc is not on PATH", .{});
        }
    }
    if (b.findProgram(.{ .names = &.{ "glslang", "glslangValidator" } })) |exe| {
        return compileGlslWith(b, .glslang, exe, wanted);
    } else {
        if (which == .glslang) fatal("-Dglsl-compiler=glslang: glslang is not on PATH", .{});
    }
    return null;
}

fn compileGlslWith(
    b: *std.Build,
    which: GlslCompiler,
    exe: []const u8,
    wanted: [shader_stages.len]bool,
) Shaders {
    var out: Shaders = .{
        .spv = undefined,
        .compiled = true,
        .compiler = @tagName(which),
        .generated = true,
    };
    for (shader_stages, 0..) |stage, i| {
        if (!wanted[i]) {
            out.spv[i] = emptyStage(b, i);
            continue;
        }
        const run = switch (which) {
            // `-O` is shaderc's optimiser. glslang has no equivalent without
            // linking SPIRV-Tools, and the difference is a few hundred bytes
            // of module that the driver's own compiler folds away anyway.
            .glslc, .auto => b.addSystemCommand(&.{ exe, "--target-env=vulkan1.2", "-O" }),
            .glslang => b.addSystemCommand(&.{
                exe,
                "-V",
                "--quiet",
                "--target-env",
                "vulkan1.2",
            }),
        };
        run.addDirectoryArg2(b.path(shader_dir), .{
            // Attached to the flag. glslang rejects the directory as a separate
            // argument; glslc takes it either way.
            .prefix = "-I",
            // Absolute, because the step runs with the cache directory as its
            // working directory and is handed an absolute path to the shader: a
            // relative include resolves against the wrong root, and the only
            // symptom is `'#include' : must be followed by a header name`
            // about a file that is plainly there.
            .make_absolute = true,
        });
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
fn compileSlang(b: *std.Build, exe: []const u8, wanted: [shader_stages.len]bool) Shaders {
    var out: Shaders = .{ .spv = undefined, .compiled = true, .compiler = "slangc", .generated = true };
    for (shader_stages, 0..) |stage, i| {
        if (!wanted[i]) {
            out.spv[i] = emptyStage(b, i);
            continue;
        }
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

/// The committed modules, if every stage this build wants is there.
fn prebuilt(b: *std.Build, wanted: [shader_stages.len]bool) ?Shaders {
    var out: Shaders = .{ .spv = undefined, .compiled = true, .compiler = "spirv" };
    for (shader_stages, 0..) |stage, i| {
        if (!wanted[i]) {
            out.spv[i] = emptyStage(b, i);
            continue;
        }
        const sub = b.fmt("{s}/spirv/{s}.spv", .{ shader_dir, stage });
        if (!exists(b, sub)) return null;
        out.spv[i] = b.path(sub);
    }
    return out;
}

/// Checked here rather than left to a `file not found` from inside `@cImport`,
/// which reports the failure as a Zig compile error three layers deep with no
/// hint that a download is what is missing.
fn hasStbHeader(b: *std.Build) bool {
    return exists(b, "vendor/stb/stb_truetype.h");
}

/// Whether a file is in the source tree, asked at configure time.
///
/// Against the working directory, which is the build root because this package
/// is always the root one -- 0.17 removed `b.build_root`, and the directory
/// handle it carried with it. Do not "simplify" this into a `LazyPath`: both
/// callers have to answer now, before the step graph exists, because what they
/// decide is which steps there are.
fn exists(b: *std.Build, sub_path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, sub_path, .{}) catch return false;
    return true;
}

/// A C header as a module, which is what 0.17 leaves instead of `@cImport`.
///
/// `tyr/backend/{freetype,harfbuzz,stb}.zig` each import theirs by name. A
/// build that did not ask for one gets an empty module instead: the file still
/// has to parse, and nothing in it is analysed, because `tyr/registry.zig`
/// names a backend only when its flag turned it on.
///
/// Do not "simplify" this into a conditional `@import` in the Zig source. A
/// module named in an `@import` has to exist whether or not the comptime branch
/// around it is taken, so the choice has to be made here.
const CHeader = struct {
    /// What the backend file imports.
    name: []const u8,
    /// The header beside it, which the step reads.
    header: []const u8,
    wanted: bool,
    /// Where the library's own headers are, when they are not on the default
    /// search path.
    include: ?std.Build.LazyPath = null,
    /// What `@cDefine` used to say.
    defines: []const [2][]const u8 = &.{},
};

/// What the empty module says, for anyone who finds it in the cache.
const stub_doc =
    \\//! No C library: this backend is off in this build. The header is
    \\//! translated only when its flag turns it on -- see `cHeader` in
    \\//! build.zig.
    \\
;

fn cHeader(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    h: CHeader,
) void {
    if (!h.wanted) {
        // Written rather than kept in the tree, because a file may be the root
        // of only one module and one stub on disk cannot be all three.
        const empty = b.addWriteFiles();
        module.addAnonymousImport(h.name, .{
            .root_source_file = empty.add(b.fmt("{s}.zig", .{h.name}), stub_doc),
        });
        return;
    }
    const tc = b.addTranslateC(.{
        .root_source_file = b.path(b.fmt("src/tyr/backend/{s}", .{h.header})),
        .target = target,
        .optimize = optimize,
    });
    if (h.include) |dir| tc.addIncludePath(dir);
    for (h.defines) |d| tc.defineCMacro(d[0], d[1]);
    module.addImport(h.name, tc.createModule());
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
