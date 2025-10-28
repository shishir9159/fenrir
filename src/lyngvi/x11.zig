//! The X11 backend, stubbed.
//!
//! It is here on the first day rather than the day it is written, for the same
//! reason `tyr/backend/fallback.zig` was: a platform layer with exactly one
//! implementation is not a platform layer, it is Win32 code with a vtable in
//! front of it, and the difference only becomes visible when the second one is
//! attempted and something in the interface turns out to be a Windows concept.
//!
//! Writing this file's *signature* now is what proves the interface is not.
//! `Window.Native` already has an `xcb` arm; `Events` already takes wheel
//! movement in pixels rather than notches, because X11 delivers it as button
//! presses 4 and 5 with no magnitude at all; `Window.Options.scroll_line_pixels`
//! exists because in that arrangement the platform has no opinion to report
//! and someone has to supply the number.
//!
//! ## What implementing it involves
//!
//! xcb rather than Xlib: the protocol is asynchronous, xcb exposes it that
//! way, and Xlib's synchronous round trips are the reason X11 applications
//! feel slow over a network. `VK_KHR_xcb_surface` takes exactly the connection
//! and window this would produce.
//!
//! * `xcb_connect`, `xcb_generate_id`, `xcb_create_window`, `xcb_map_window`.
//! * `WM_PROTOCOLS` / `WM_DELETE_WINDOW` interned through `xcb_intern_atom`,
//!   because a close button that is not registered for it kills the client
//!   rather than sending it a message.
//! * `xcb_poll_for_event` for `pump`, and a poll on the connection's file
//!   descriptor for `wait`.
//! * `XCB_KEY_PRESS` through `xkbcommon` for text: the keysym-to-character
//!   mapping is not something to write by hand, and it is what makes dead keys
//!   and compose sequences work.
//! * Buttons 4/5 and 6/7 for vertical and horizontal wheel movement, each
//!   press worth `scroll_line_pixels` times the system's line count.
//! * `_NET_WM_NAME` as UTF-8 for the title, since `WM_NAME` is Latin-1.
//! * DPI from `Xft.dpi` in the resource database, falling back to the physical
//!   dimensions in the screen, falling back to 96.
//!
//! The one thing not to carry over: X11 has no per-window scale factor and no
//! equivalent of `WM_DPICHANGED`, so `scale` is fixed at startup and a window
//! dragged between monitors of different densities stays the size it was.
//! Wayland does have one, which is the argument for that backend being third
//! rather than for this one being second.

const std = @import("std");

const Window = @import("Window.zig");

pub fn create(gpa: std.mem.Allocator, options: Window.Options) Window.Error!Window {
    _ = gpa;
    _ = options;
    return error.UnsupportedPlatform;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the stub has the signature the real one will have" {
    // The point of the file: `lyngvi.open` dispatches on the target and this
    // arm has to compile on every platform, so the day someone fills it in the
    // only thing that changes is the body.
    try testing.expectError(error.UnsupportedPlatform, create(testing.allocator, .{}));
}
