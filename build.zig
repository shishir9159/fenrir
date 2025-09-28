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

    const opts = b.addOptions();
    opts.addOption(bool, "tyr_freetype", want_freetype);
    opts.addOption(bool, "tyr_stb_truetype", want_stb);
    opts.addOption(bool, "tyr_harfbuzz", want_harfbuzz);
    opts.addOption([]const u8, "tyr_default", font_default);

    // The library: everything that understands PDF, with no I/O policy of its
    // own. Consumers hand it bytes and an allocator.
    const fenrir = b.addModule("fenrir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fenrir.addOptions("build_options", opts);

    if (want_freetype) {
        fenrir.link_libc = true;
        fenrir.linkSystemLibrary("freetype2", .{});
    }
    if (want_harfbuzz) {
        fenrir.link_libc = true;
        fenrir.linkSystemLibrary("harfbuzz", .{});
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

/// Checked here rather than left to a `file not found` from inside `@cImport`,
/// which reports the failure as a Zig compile error three layers deep with no
/// hint that a download is what is missing.
fn hasStbHeader(b: *std.Build) bool {
    b.build_root.handle.access(b.graph.io, "vendor/stb/stb_truetype.h", .{}) catch return false;
    return true;
}
