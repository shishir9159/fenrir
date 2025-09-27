const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: everything that understands PDF, with no I/O policy of its
    // own. Consumers hand it bytes and an allocator.
    const fenrir = b.addModule("fenrir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
