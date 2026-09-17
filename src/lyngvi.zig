//! Lyngvi -- the platform: a window, its input, and the device that draws into
//! it.
//!
//! Lyngvi is the island. The gods took the wolf out to it on the pretext of a
//! game, because the binding could not be done anywhere he was at ease; the
//! island is not part of the trick and does nothing clever, it is only the
//! ground the whole thing had to happen on. Every other layer in this project
//! computes something. This one owns a handle from the operating system and a
//! queue from a driver, and its entire contribution is that there is somewhere
//! for the rest to take place.
//!
//! ## What is here
//!
//!     Window ---- events ----> Þviti ---- boxes ----> Gleipnir
//!        |                                               |
//!        +-- surface --> Device --> Swapchain --> Renderer (instances)
//!
//! `Window` is fifteen functions with one implementation per platform.
//! `Device` and `Swapchain` are Vulkan, reached through bindings written by
//! hand and loaded at run time, so the default build still links no C.
//! `Renderer` is the rect pipeline from `gleipnir/pipeline.zig` made real:
//! one storage buffer of instances, one unbounded texture array, one draw call
//! for the frame.
//!
//! ## Two things this layer deliberately does not decide
//!
//! **When to draw.** `App` offers a loop, and it is a convenience rather than
//! a framework: `pump`, `take`, `begin`, `end`, `render`, `present` are all
//! public and can be called by hand in any order that makes sense. A reader
//! that wants to redraw only when something moved needs that, and a program
//! that cannot get at the pieces ends up reimplementing them.
//!
//! **What the units are.** Sizes come out of `Window` in device pixels, and
//! the DPI scale is reported alongside rather than folded in. A UI that wants
//! to lay out in logical pixels multiplies its font sizes; one that wants
//! physical pixels ignores the number. Folding it in here would make the
//! second impossible and hide the first.

const std = @import("std");
const builtin = @import("builtin");

pub const Device = @import("lyngvi/Device.zig");
pub const Events = @import("lyngvi/Events.zig");
pub const PathRenderer = @import("lyngvi/PathRenderer.zig");
pub const Renderer = @import("lyngvi/Renderer.zig");
pub const Swapchain = @import("lyngvi/Swapchain.zig");
pub const Window = @import("lyngvi/Window.zig");
pub const choose = @import("lyngvi/choose.zig");
pub const loader = @import("lyngvi/loader.zig");
pub const shaders = @import("lyngvi/shaders.zig");
pub const spirv = @import("lyngvi/spirv.zig");
pub const vk = @import("lyngvi/vk.zig");

pub const wayland = @import("lyngvi/wayland.zig");
pub const win32 = @import("lyngvi/win32.zig");
pub const x11 = @import("lyngvi/x11.zig");

pub const Error = Window.Error;
pub const Input = Events.Input;
pub const Native = Window.Native;
pub const Options = Window.Options;
pub const Vsync = choose.Vsync;

/// Whether this build has a window backend for the target at all: Win32 on
/// Windows, Wayland on the Unixes. `fenrir view` uses it to say so in one line
/// rather than failing halfway through creating an instance.
///
/// True on Linux even though a given machine may have no compositor running
/// -- that is a property of the session, not the build, and `open` is where
/// it is discovered and reported.
pub const has_window = builtin.os.tag == .windows or wayland.supported;

/// Whether the shaders were compiled to SPIR-V when this binary was built.
/// False means `Renderer.init` will refuse, and `fenrir view --probe` still
/// works, which is the useful half of the layer on a machine with no shader
/// compiler.
pub const has_shaders = shaders.available;

/// Opens a window using whichever backend fits the target and the session.
///
/// On the Unixes that is a run-time decision, which is why `Window` is a
/// vtable and not a comptime switch: the same binary may be started under a
/// Wayland compositor or an X server. Wayland is tried first -- it is what a
/// current desktop runs, and it is the one that reports per-monitor scale --
/// and X11 second, which today means a clear "not supported" rather than a
/// window.
pub fn open(gpa: std.mem.Allocator, options: Options) Error!Window {
    return switch (builtin.os.tag) {
        .windows => win32.create(gpa, options),
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => wayland.create(gpa, options) catch |err| switch (err) {
            // No compositor, no libwayland, or a compositor without
            // xdg-shell: fall through. Out of memory is not a reason to try
            // another display server.
            error.UnsupportedPlatform, error.WindowCreationFailed => x11.create(gpa, options),
            else => err,
        },
        else => error.UnsupportedPlatform,
    };
}

/// A monotonic clock producing the `dt` a frame is animated with.
///
/// Separate from `Events` because a frame's duration is not an event and
/// because the UI has to be drivable from a fixed step in a test. `thviti`
/// clamps whatever this reports, which is what makes the enormous value after
/// a window drag or a breakpoint harmless.
///
/// `awake` rather than `real`: a wall clock can go backwards when NTP corrects
/// it, and a negative `dt` runs every animation in reverse for one frame.
pub const Clock = struct {
    io: std.Io,
    last: std.Io.Timestamp,

    pub fn start(io: std.Io) Clock {
        return .{ .io = io, .last = std.Io.Clock.awake.now(io) };
    }

    /// Seconds since the last call.
    pub fn tick(c: *Clock) f32 {
        const now = std.Io.Clock.awake.now(c.io);
        const ns = c.last.durationTo(now).nanoseconds;
        c.last = now;
        if (ns <= 0) return 0;
        return @as(f32, @floatFromInt(@as(i64, @intCast(ns)))) / std.time.ns_per_s;
    }
};

test {
    _ = Device;
    _ = Events;
    _ = PathRenderer;
    _ = Renderer;
    _ = Swapchain;
    _ = Window;
    _ = choose;
    _ = loader;
    _ = shaders;
    _ = spirv;
    _ = vk;
    _ = x11;
    _ = wayland;
    _ = @import("lyngvi/wayland/protocol.zig");
    _ = @import("lyngvi/wayland/keymap.zig");
    if (builtin.os.tag == .windows) _ = win32;
}
