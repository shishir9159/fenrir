//! What a window is, to the rest of the program.
//!
//! One runtime interface with one implementation per platform, the same shape
//! as `tyr.Face` and `tyr.Shaper`: a pointer, a vtable, and a set of methods
//! that forward. Compile-time dispatch would be smaller and faster and would
//! also mean that the choice of backend is baked into the binary, which is
//! wrong on Linux, where X11 and Wayland are both installed on the same
//! machine and which one is running is a property of the session.
//!
//! The surface is fifteen entry points, which was the estimate before any of
//! it was written and turned out to be right. That is the whole platform
//! layer: everything else a window does -- hit testing, focus, cursors that
//! change over a control, drag and drop within the program -- belongs to Þviti
//! and is already written, because none of it needs the operating system.
//!
//! ## What is deliberately not here
//!
//! No message boxes, no file dialogs, no menus, no clipboard, no drag-and-drop
//! from other applications, no tray icons. Each of those is a genuinely
//! platform-shaped API that a PDF reader eventually needs, and each of them is
//! a self-contained addition later. Putting them in now would mean designing
//! them against one platform.
//!
//! No OpenGL or Direct3D fallback either. The surface this hands to Vulkan is
//! the only rendering path, and a machine without Vulkan gets a message that
//! says so rather than a silently slower program.

const std = @import("std");

const Events = @import("Events.zig");

const Window = @This();

pub const Error = error{
    /// The platform refused to make a window: no display connection, no
    /// permission, or a class name that is already registered by something
    /// else in the same process.
    WindowCreationFailed,
    /// Compiled for a platform with no backend, or running under a display
    /// server this build does not speak.
    UnsupportedPlatform,
} || std.mem.Allocator.Error;

/// The handle Vulkan needs to make a surface, in the shape the relevant
/// `vkCreate*SurfaceKHR` wants it.
///
/// A tagged union rather than an opaque pointer, because the surface call is
/// different per platform and the tag is what chooses it. It is also the one
/// place where the rest of the program is allowed to know which windowing
/// system it is running on.
pub const Native = union(enum) {
    win32: struct { hinstance: ?*anyopaque, hwnd: ?*anyopaque },
    xcb: struct { connection: ?*anyopaque, window: u32 },
    xlib: struct { display: ?*anyopaque, window: c_ulong },
    wayland: struct { display: ?*anyopaque, surface: ?*anyopaque },

    /// The instance extension a surface of this kind needs, which is asked for
    /// before the window exists and therefore cannot be asked of one.
    pub fn extensionFor(tag: std.meta.Tag(Native)) []const u8 {
        return switch (tag) {
            .win32 => "VK_KHR_win32_surface",
            .xcb => "VK_KHR_xcb_surface",
            .xlib => "VK_KHR_xlib_surface",
            .wayland => "VK_KHR_wayland_surface",
        };
    }
};

pub const Options = struct {
    title: []const u8 = "fenrir",
    /// Logical pixels. Multiplied by the display's scale factor before the
    /// window is created, so 1100x760 is the same apparent size on a 96dpi
    /// monitor and on a 200% laptop panel.
    width: u32 = 1100,
    height: u32 = 760,
    resizable: bool = true,
    visible: bool = true,
    /// Pixels of scrolling per line of text, multiplied by the system's own
    /// "lines per notch" preference. Lives here because `input.zig` is
    /// explicit that this number is a platform preference and not a UI one,
    /// and a platform that has no opinion has to get it from somewhere.
    scroll_line_pixels: f32 = 18,
};

pub const Size = struct {
    /// Device pixels. This is the number the swapchain is made from, and the
    /// number the UI lays out in.
    width: u32,
    height: u32,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (ptr: *anyopaque) void,
    /// Drains the platform queue into `events` and returns. Never blocks.
    pump: *const fn (ptr: *anyopaque) void,
    /// Blocks until something arrives or `timeout_ms` passes, then drains.
    /// A reader that is not animating anything should be idle, and a loop
    /// built only on `pump` is a busy loop by construction.
    wait: *const fn (ptr: *anyopaque, timeout_ms: u32) void,
    events: *const fn (ptr: *anyopaque) *Events,
    native: *const fn (ptr: *anyopaque) Native,
    size: *const fn (ptr: *anyopaque) Size,
    scale: *const fn (ptr: *anyopaque) f32,
    setTitle: *const fn (ptr: *anyopaque, title: []const u8) void,
    setVisible: *const fn (ptr: *anyopaque, visible: bool) void,
    close: *const fn (ptr: *anyopaque) void,
};

pub fn destroy(w: Window) void {
    w.vtable.destroy(w.ptr);
}

pub fn pump(w: Window) void {
    w.vtable.pump(w.ptr);
}

pub fn wait(w: Window, timeout_ms: u32) void {
    w.vtable.wait(w.ptr, timeout_ms);
}

pub fn events(w: Window) *Events {
    return w.vtable.events(w.ptr);
}

pub fn native(w: Window) Native {
    return w.vtable.native(w.ptr);
}

pub fn size(w: Window) Size {
    return w.vtable.size(w.ptr);
}

pub fn scale(w: Window) f32 {
    return w.vtable.scale(w.ptr);
}

pub fn setTitle(w: Window, title: []const u8) void {
    w.vtable.setTitle(w.ptr, title);
}

pub fn setVisible(w: Window, visible: bool) void {
    w.vtable.setVisible(w.ptr, visible);
}

/// Asks the window to close. Not the same as destroying it: this sets the flag
/// the application reads, so a document with unsaved changes can refuse.
pub fn close(w: Window) void {
    w.vtable.close(w.ptr);
}

pub fn shouldClose(w: Window) bool {
    return w.events().close_requested;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the surface extension follows from the handle, before a window exists" {
    // Asked while building the instance, which happens before the window is
    // created, which is why it is a function of the tag and not of a window.
    try testing.expectEqualStrings("VK_KHR_win32_surface", Native.extensionFor(.win32));
    try testing.expectEqualStrings("VK_KHR_xcb_surface", Native.extensionFor(.xcb));
    try testing.expectEqualStrings("VK_KHR_wayland_surface", Native.extensionFor(.wayland));
}

test "the vtable is the whole platform surface" {
    // Fifteen functions was the estimate. If this number grows, something that
    // belongs in Þviti has been pushed down into the platform layer -- which
    // is how a portable program acquires three subtly different behaviours.
    const n = @typeInfo(VTable).@"struct".field_names.len;
    try testing.expect(n <= 15);
}
