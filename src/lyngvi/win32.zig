//! The Win32 window, declared rather than imported.
//!
//! Thirty extern declarations and a window procedure. No `windows.h`, no
//! `@cImport`, and no dependency on the Windows SDK being installed: the
//! functions are named, their signatures written out, and the linker resolves
//! them against the import libraries Zig already ships. Every constant here is
//! a number from a public header that has not changed since 1995.
//!
//! ## The three things this file exists to get right
//!
//! **The pointer back to ourselves.** A window procedure is a free function
//! the operating system calls. It gets an `HWND` and nothing else, so the
//! instance has to be found from that. The pointer is passed through
//! `CreateWindowExW`'s last argument, retrieved in `WM_NCCREATE` -- the first
//! message a window receives, before any message that could need it -- and
//! stored in the window's user data. Any message that arrives before that is
//! handled without it rather than crashing on a null.
//!
//! **Capture.** Press inside a scrollbar, drag past the edge of the window,
//! release. Without `SetCapture` the release is delivered to whatever window
//! is under the pointer, this one never learns the button came up, and the
//! thumb follows the mouse across the desktop until it is clicked again. With
//! it, the messages keep coming here until the last button is released. This
//! is the same failure `Events.setFocus` guards against from the other side.
//!
//! **Text, which is not keys.** `WM_KEYDOWN` reports a virtual key: the
//! physical function, identical on every layout. `WM_CHAR` reports a character
//! after the layout, the dead keys and the IME have all had their say -- as a
//! UTF-16 code unit, so anything outside the basic plane arrives as two
//! messages that have to be paired before they are anything at all. Both are
//! forwarded, and `input.zig` explains at length why a UI needs both.

const std = @import("std");
const builtin = @import("builtin");

const Events = @import("Events.zig");
const Window = @import("Window.zig");

const thviti = @import("../thviti.zig");
const KeyCode = thviti.input.KeyCode;

const Win32 = @This();

// -- types ------------------------------------------------------------------

const HANDLE = ?*anyopaque;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMODULE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HMENU = ?*anyopaque;
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;
const BOOL = i32;
const ATOM = u16;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    w_param: WPARAM,
    l_param: LPARAM,
    time: u32,
    pt: POINT,
};

const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cb_size: u32,
    style: u32,
    lpfn_wnd_proc: WNDPROC,
    cb_cls_extra: i32,
    cb_wnd_extra: i32,
    h_instance: HINSTANCE,
    h_icon: HICON,
    h_cursor: HCURSOR,
    hbr_background: HBRUSH,
    lpsz_menu_name: ?[*:0]const u16,
    lpsz_class_name: [*:0]const u16,
    h_icon_sm: HICON,
};

const CREATESTRUCTW = extern struct {
    lp_create_params: ?*anyopaque,
    h_instance: HINSTANCE,
    h_menu: HMENU,
    hwnd_parent: HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpsz_name: ?[*:0]const u16,
    lpsz_class: ?[*:0]const u16,
    dw_ex_style: u32,
};

// -- constants --------------------------------------------------------------

const CS_VREDRAW: u32 = 0x0001;
const CS_HREDRAW: u32 = 0x0002;
const CS_OWNDC: u32 = 0x0020;

const WS_OVERLAPPEDWINDOW: u32 = 0x00cf_0000;
const WS_POPUP: u32 = 0x8000_0000;
const WS_CAPTION: u32 = 0x00c0_0000;
const WS_SYSMENU: u32 = 0x0008_0000;
const WS_MINIMIZEBOX: u32 = 0x0002_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x8000_0000));

const SW_HIDE: i32 = 0;
const SW_SHOW: i32 = 5;
const SW_SHOWNORMAL: i32 = 1;

const GWLP_USERDATA: i32 = -21;
const PM_REMOVE: u32 = 0x0001;
const INFINITE: u32 = 0xffff_ffff;
const QS_ALLINPUT: u32 = 0x04ff;

const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_SETFOCUS: u32 = 0x0007;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_CLOSE: u32 = 0x0010;
const WM_QUIT: u32 = 0x0012;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_GETMINMAXINFO: u32 = 0x0024;
const WM_NCCREATE: u32 = 0x0081;
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_CHAR: u32 = 0x0102;
const WM_SYSKEYDOWN: u32 = 0x0104;
const WM_SYSKEYUP: u32 = 0x0105;
const WM_SYSCHAR: u32 = 0x0106;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_LBUTTONDBLCLK: u32 = 0x0203;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_MBUTTONDOWN: u32 = 0x0207;
const WM_MBUTTONUP: u32 = 0x0208;
const WM_MBUTTONDBLCLK: u32 = 0x0209;
const WM_MOUSEWHEEL: u32 = 0x020a;
const WM_MOUSEHWHEEL: u32 = 0x020e;
const WM_DPICHANGED: u32 = 0x02e0;

/// `MapVirtualKey`: virtual key to the character the layout prints on it.
const MAPVK_VK_TO_CHAR: u32 = 2;

const SIZE_MINIMIZED: u32 = 1;

const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;

const SPI_GETWHEELSCROLLLINES: u32 = 0x0068;
const WHEEL_DELTA: f32 = 120;
/// The system's "scroll one screen per notch" setting, which arrives as this
/// rather than as a line count.
const WHEEL_PAGESCROLL: u32 = 0xffff_ffff;

const IDC_ARROW: [*:0]const u16 = @ptrFromInt(32512);

const VK_BACK: u32 = 0x08;
const VK_TAB: u32 = 0x09;
const VK_RETURN: u32 = 0x0d;
const VK_SHIFT: u32 = 0x10;
const VK_CONTROL: u32 = 0x11;
const VK_MENU: u32 = 0x12;
const VK_ESCAPE: u32 = 0x1b;
const VK_SPACE: u32 = 0x20;
const VK_PRIOR: u32 = 0x21;
const VK_NEXT: u32 = 0x22;
const VK_END: u32 = 0x23;
const VK_HOME: u32 = 0x24;
const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;
const VK_INSERT: u32 = 0x2d;
const VK_DELETE: u32 = 0x2e;
const VK_LWIN: u32 = 0x5b;
const VK_RWIN: u32 = 0x5c;
const VK_F1: u32 = 0x70;
const VK_F12: u32 = 0x7b;

/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, which is a sentinel pointer
/// rather than a value: -4 cast to a handle.
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

const USER_DEFAULT_SCREEN_DPI: f32 = 96;

// -- imports ----------------------------------------------------------------

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HMODULE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) HMODULE;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn UnregisterClassW([*:0]const u16, HINSTANCE) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(u32, ?[*:0]const u16, ?[*:0]const u16, u32, i32, i32, i32, i32, HWND, HMENU, HINSTANCE, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn PeekMessageW(*MSG, HWND, u32, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn MapVirtualKeyW(u32, u32) callconv(.winapi) u32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, BOOL, u32) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(HWND, HWND, i32, i32, i32, i32, u32) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(HINSTANCE, [*:0]const u16) callconv(.winapi) HCURSOR;
extern "user32" fn SetCapture(HWND) callconv(.winapi) HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
extern "user32" fn SystemParametersInfoW(u32, u32, ?*anyopaque, u32) callconv(.winapi) BOOL;
extern "user32" fn MsgWaitForMultipleObjects(u32, ?*const anyopaque, BOOL, u32, u32) callconv(.winapi) u32;
extern "user32" fn PostMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;

// Windows 10 and later, and reached through `GetProcAddress` rather than
// declared: linking them directly would make the binary refuse to start on an
// older system instead of running without them. A PDF reader has no business
// being the reason a machine cannot open a file.
const LateBound = struct {
    setProcessDpiAwarenessContext: ?*const fn (HANDLE) callconv(.winapi) BOOL = null,
    getDpiForWindow: ?*const fn (HWND) callconv(.winapi) u32 = null,
    adjustWindowRectExForDpi: ?*const fn (*RECT, u32, BOOL, u32, u32) callconv(.winapi) BOOL = null,

    fn load() LateBound {
        var lb: LateBound = .{};
        const user32 = LoadLibraryA("user32.dll") orelse return lb;
        if (GetProcAddress(user32, "SetProcessDpiAwarenessContext")) |p| lb.setProcessDpiAwarenessContext = @ptrCast(p);
        if (GetProcAddress(user32, "GetDpiForWindow")) |p| lb.getDpiForWindow = @ptrCast(p);
        if (GetProcAddress(user32, "AdjustWindowRectExForDpi")) |p| lb.adjustWindowRectExForDpi = @ptrCast(p);
        return lb;
    }
};

// -- state ------------------------------------------------------------------

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("fenrir.lyngvi.window");

/// Registered once per process. Window creation is a main-thread operation by
/// contract -- every windowing system on every platform requires it -- so this
/// needs no lock, and saying so is cheaper than pretending otherwise with an
/// atomic that would still not make the rest of the API thread-safe.
var class_atom: ATOM = 0;
var dpi_awareness_set = false;

gpa: std.mem.Allocator,
events: Events,
hwnd: HWND = null,
hinstance: HINSTANCE = null,
options: Window.Options,
late: LateBound,

/// Device pixels per logical pixel, from the monitor the window is on. Updated
/// on `WM_DPICHANGED`, which arrives when the window is dragged between
/// monitors of different densities -- not only at startup.
dpi_scale: f32 = 1,

/// Buttons currently held, counted rather than tracked as a mask, because
/// capture is released when the count reaches zero and Windows sends no
/// message saying "all buttons are now up".
buttons_down: u32 = 0,

/// A high surrogate waiting for its low half. UTF-16 delivers anything outside
/// the basic plane as two `WM_CHAR` messages, and either one alone is not a
/// character.
pending_surrogate: ?u16 = null,

/// Set when a push into the event queue failed. Checked after the pump rather
/// than inside the window procedure, which cannot return an error to anyone.
oom: bool = false,

pub fn create(gpa: std.mem.Allocator, options: Window.Options) Window.Error!Window {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const self = try gpa.create(Win32);
    errdefer gpa.destroy(self);

    self.* = .{
        .gpa = gpa,
        .events = .init(gpa),
        .options = options,
        .late = .load(),
    };
    errdefer self.events.deinit();

    // Before any window exists, or the process is stuck with whatever
    // awareness the manifest gave it -- which for a manifest-less binary is
    // "none", meaning Windows scales the window with a blur filter and every
    // pixel this renderer computes is thrown away.
    if (!dpi_awareness_set) {
        if (self.late.setProcessDpiAwarenessContext) |f| {
            _ = f(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
        dpi_awareness_set = true;
    }

    self.hinstance = GetModuleHandleW(null);

    if (class_atom == 0) {
        const class: WNDCLASSEXW = .{
            .cb_size = @sizeOf(WNDCLASSEXW),
            // OWNDC because the window keeps one device context for its whole
            // life, which is what a surface that is never recreated wants.
            .style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC,
            .lpfn_wnd_proc = wndProc,
            .cb_cls_extra = 0,
            .cb_wnd_extra = 0,
            .h_instance = self.hinstance,
            .h_icon = null,
            .h_cursor = LoadCursorW(null, IDC_ARROW),
            // No background brush. Windows would otherwise paint the window
            // grey before every frame, which is a full-window flash on any
            // frame the renderer is late for.
            .hbr_background = null,
            .lpsz_menu_name = null,
            .lpsz_class_name = class_name,
            .h_icon_sm = null,
        };
        class_atom = RegisterClassExW(&class);
        if (class_atom == 0) return error.WindowCreationFailed;
    }

    const style: u32 = if (options.resizable)
        WS_OVERLAPPEDWINDOW
    else
        WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

    // The requested size is the *client* area -- the part that gets drawn --
    // and `CreateWindowExW` takes the outer size, so the frame has to be added
    // on. Skipping this is why so many programs open a window a title bar
    // shorter than the one they asked for.
    var rect: RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(options.width),
        .bottom = @intCast(options.height),
    };
    _ = AdjustWindowRectEx(&rect, style, 0, 0);

    const title = try utf16(gpa, options.title);
    defer gpa.free(title);

    self.hwnd = CreateWindowExW(
        0,
        class_name,
        title.ptr,
        style,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        self.hinstance,
        // Handed to `WM_NCCREATE`, which is where the window procedure finds
        // its way back here.
        self,
    );
    if (self.hwnd == null) return error.WindowCreationFailed;

    self.dpi_scale = self.queryScale();
    self.events.setScale(self.dpi_scale);

    // The window was created at the size that was asked for in *logical*
    // pixels; on a scaled display the client area is now smaller than
    // intended, so it is resized once, after the DPI is known.
    if (self.dpi_scale != 1) self.resizeClient(options.width, options.height);

    self.syncClientSize();

    if (options.visible) {
        _ = ShowWindow(self.hwnd, SW_SHOWNORMAL);
        _ = UpdateWindow(self.hwnd);
    }

    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Window.VTable = .{
    .destroy = vtDestroy,
    .pump = vtPump,
    .wait = vtWait,
    .events = vtEvents,
    .native = vtNative,
    .size = vtSize,
    .scale = vtScale,
    .setTitle = vtSetTitle,
    .setVisible = vtSetVisible,
    .close = vtClose,
};

fn from(ptr: *anyopaque) *Win32 {
    return @ptrCast(@alignCast(ptr));
}

fn vtDestroy(ptr: *anyopaque) void {
    const self = from(ptr);
    if (self.hwnd) |h| _ = DestroyWindow(h);
    self.events.deinit();
    const gpa = self.gpa;
    gpa.destroy(self);
}

fn vtPump(ptr: *anyopaque) void {
    from(ptr).drain();
}

fn vtWait(ptr: *anyopaque, timeout_ms: u32) void {
    const self = from(ptr);
    // Only blocks when there is nothing queued: `MsgWaitForMultipleObjects`
    // returns immediately if the queue is non-empty, and a program that called
    // this in a loop would otherwise wait out its own backlog one message at a
    // time.
    _ = MsgWaitForMultipleObjects(0, null, 0, timeout_ms, QS_ALLINPUT);
    self.drain();
}

fn vtEvents(ptr: *anyopaque) *Events {
    return &from(ptr).events;
}

fn vtNative(ptr: *anyopaque) Window.Native {
    const self = from(ptr);
    return .{ .win32 = .{ .hinstance = self.hinstance, .hwnd = self.hwnd } };
}

fn vtSize(ptr: *anyopaque) Window.Size {
    const self = from(ptr);
    return .{ .width = self.events.width, .height = self.events.height };
}

fn vtScale(ptr: *anyopaque) f32 {
    return from(ptr).dpi_scale;
}

fn vtSetTitle(ptr: *anyopaque, title: []const u8) void {
    const self = from(ptr);
    const wide = utf16(self.gpa, title) catch return;
    defer self.gpa.free(wide);
    _ = SetWindowTextW(self.hwnd, wide.ptr);
}

fn vtSetVisible(ptr: *anyopaque, visible: bool) void {
    _ = ShowWindow(from(ptr).hwnd, if (visible) SW_SHOW else SW_HIDE);
}

fn vtClose(ptr: *anyopaque) void {
    from(ptr).events.requestClose();
}

// -- the loop ---------------------------------------------------------------

fn drain(self: *Win32) void {
    var msg: MSG = undefined;
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        if (msg.message == WM_QUIT) {
            self.events.requestClose();
            continue;
        }
        // The call that turns key presses into `WM_CHAR`, with the layout, the
        // dead keys and the input method applied.
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn utf16(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Not UTF-8 at all. A title is cosmetic; refusing to open the window
        // over it would be absurd.
        else => gpa.dupeSentinel(u16, std.unicode.utf8ToUtf16LeStringLiteral("fenrir"), 0),
    };
}

fn queryScale(self: *Win32) f32 {
    const f = self.late.getDpiForWindow orelse return 1;
    const dpi = f(self.hwnd);
    if (dpi == 0) return 1;
    return @as(f32, @floatFromInt(dpi)) / USER_DEFAULT_SCREEN_DPI;
}

fn resizeClient(self: *Win32, logical_w: u32, logical_h: u32) void {
    const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical_w)) * self.dpi_scale));
    const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical_h)) * self.dpi_scale));
    var rect: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };

    const style: u32 = if (self.options.resizable)
        WS_OVERLAPPEDWINDOW
    else
        WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

    // The frame is itself scaled, so on a mixed-DPI desktop the per-DPI
    // version has to be used or the client area comes out short by the
    // difference between two title bars.
    if (self.late.adjustWindowRectExForDpi) |f| {
        const dpi: u32 = @intFromFloat(@round(self.dpi_scale * USER_DEFAULT_SCREEN_DPI));
        _ = f(&rect, style, 0, 0, dpi);
    } else {
        _ = AdjustWindowRectEx(&rect, style, 0, 0);
    }

    _ = SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        SWP_NOZORDER | SWP_NOACTIVATE | 0x0002, // SWP_NOMOVE
    );
}

fn syncClientSize(self: *Win32) void {
    var rect: RECT = undefined;
    if (GetClientRect(self.hwnd, &rect) == 0) return;
    self.events.resize(
        @intCast(@max(rect.right - rect.left, 0)),
        @intCast(@max(rect.bottom - rect.top, 0)),
    );
}

/// Pixels of document movement for one notch of the wheel.
///
/// The number of *lines* is a system preference and the size of a line is
/// this program's business, which is the split `input.zig` describes. The
/// "one page per notch" setting arrives as a sentinel rather than a count, and
/// is answered with most of a screen -- all of it would leave nothing to read
/// across.
fn wheelPixels(self: *Win32) f32 {
    var lines: u32 = 3;
    _ = SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    if (lines == WHEEL_PAGESCROLL) {
        return @as(f32, @floatFromInt(self.events.height)) * 0.9;
    }
    if (lines == 0) lines = 3;
    return @as(f32, @floatFromInt(lines)) * self.options.scroll_line_pixels * self.dpi_scale;
}

fn currentModifiers() thviti.input.Modifiers {
    const down = struct {
        fn f(vk_code: i32) bool {
            // The high bit is "down now"; the low bit is the toggle state,
            // which is what makes Caps Lock look like a held key to code that
            // tests the wrong one.
            return @as(u16, @bitCast(GetKeyState(vk_code))) & 0x8000 != 0;
        }
    }.f;
    return .{
        .shift = down(VK_SHIFT),
        .ctrl = down(VK_CONTROL),
        .alt = down(VK_MENU),
        .super = down(@intCast(VK_LWIN)) or down(@intCast(VK_RWIN)),
    };
}

/// Virtual key to `KeyCode`.
///
/// Letters and digits are deliberately absent: they arrive as text, after the
/// layout has been applied, and a `KeyCode.a` would be a promise that the key
/// labelled A produces an `a` -- true on a US layout and false on a French
/// one, where it is where Q is.
fn mapKey(vk_code: u32) KeyCode {
    return switch (vk_code) {
        VK_ESCAPE => .escape,
        VK_RETURN => .enter,
        VK_TAB => .tab,
        VK_BACK => .backspace,
        VK_DELETE => .delete,
        VK_LEFT => .left,
        VK_RIGHT => .right,
        VK_UP => .up,
        VK_DOWN => .down,
        VK_HOME => .home,
        VK_END => .end,
        VK_PRIOR => .page_up,
        VK_NEXT => .page_down,
        VK_INSERT => .insert,
        VK_SPACE => .space,
        VK_F1...VK_F12 => @enumFromInt(@intFromEnum(KeyCode.f1) + (vk_code - VK_F1)),
        else => .other,
    };
}

/// The character the current layout prints on a virtual key, or zero.
///
/// `MAPVK_VK_TO_CHAR` is the layout asking itself what this key is called,
/// which is exactly the question a chord has to answer and the one `mapKey`
/// refuses to: `KeyCode` names a function, this names a letter, and neither
/// pretends to be the other. The top bit marks a dead key -- returned with
/// the character, and not one we want to chord on.
fn labelOf(vk_code: u32) u21 {
    const mapped = MapVirtualKeyW(vk_code, MAPVK_VK_TO_CHAR);
    if (mapped == 0 or mapped & 0x8000_0000 != 0) return 0;
    const c: u32 = mapped & 0xffff;
    // Control characters and the surrogate range are not labels.
    if (c < 0x20 or (c >= 0xd800 and c <= 0xdfff)) return 0;
    return @intCast(c);
}

fn loWord(v: usize) u16 {
    return @truncate(v);
}

fn hiWord(v: usize) u16 {
    return @truncate(v >> 16);
}

/// Mouse coordinates arrive as two signed 16-bit halves of `lParam`, and they
/// really are signed: a drag past the left edge of a captured window reports a
/// negative x, and reading them as unsigned puts the pointer at 65000.
fn pointOf(l: LPARAM) struct { x: f32, y: f32 } {
    const bits: usize = @bitCast(l);
    const x: i16 = @bitCast(loWord(bits));
    const y: i16 = @bitCast(hiWord(bits));
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

fn wndProc(hwnd: HWND, msg: u32, w_param: WPARAM, l_param: LPARAM) callconv(.winapi) LRESULT {
    // The first message a window gets, and the one that installs the pointer
    // every later message depends on.
    if (msg == WM_NCCREATE) {
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(l_param)));
        if (cs.lp_create_params) |p| {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(p)));
        }
        return DefWindowProcW(hwnd, msg, w_param, l_param);
    }

    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return DefWindowProcW(hwnd, msg, w_param, l_param);
    const self: *Win32 = @ptrFromInt(@as(usize, @bitCast(raw)));

    return self.handle(hwnd, msg, w_param, l_param);
}

fn handle(self: *Win32, hwnd: HWND, msg: u32, w_param: WPARAM, l_param: LPARAM) LRESULT {
    switch (msg) {
        WM_CLOSE => {
            // Not destroyed here. The application decides, which is what makes
            // "you have unsaved changes" possible at all.
            self.events.requestClose();
            return 0;
        },
        WM_DESTROY => {
            self.hwnd = null;
            PostQuitMessage(0);
            return 0;
        },
        WM_ERASEBKGND => {
            // Claimed, so Windows does not fill the window with a brush behind
            // the renderer's back.
            return 1;
        },
        WM_SIZE => {
            if (w_param == SIZE_MINIMIZED) {
                self.events.resize(0, 0);
            } else {
                const bits: usize = @bitCast(l_param);
                self.events.resize(loWord(bits), hiWord(bits));
            }
            return 0;
        },
        WM_SETFOCUS => {
            self.events.setFocus(true);
            return 0;
        },
        WM_KILLFOCUS => {
            self.events.setFocus(false);
            self.buttons_down = 0;
            _ = ReleaseCapture();
            return 0;
        },
        WM_DPICHANGED => {
            self.dpi_scale = @as(f32, @floatFromInt(loWord(w_param))) / USER_DEFAULT_SCREEN_DPI;
            self.events.setScale(self.dpi_scale);
            // Windows supplies the rectangle the window should move to so that
            // it stays the same apparent size on the new monitor. Ignoring it
            // is what makes a window jump when it is dragged across a
            // boundary.
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(l_param)));
            _ = SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            return 0;
        },
        WM_MOUSEMOVE => {
            const p = pointOf(l_param);
            self.events.moved(p.x, p.y);
            self.events.setModifiers(currentModifiers());
            return 0;
        },
        WM_LBUTTONDOWN, WM_LBUTTONDBLCLK => return self.mouseDown(.left, l_param),
        WM_RBUTTONDOWN, WM_RBUTTONDBLCLK => return self.mouseDown(.right, l_param),
        WM_MBUTTONDOWN, WM_MBUTTONDBLCLK => return self.mouseDown(.middle, l_param),
        WM_LBUTTONUP => return self.mouseUp(.left, l_param),
        WM_RBUTTONUP => return self.mouseUp(.right, l_param),
        WM_MBUTTONUP => return self.mouseUp(.middle, l_param),
        WM_MOUSEWHEEL => {
            const notches = @as(f32, @floatFromInt(@as(i16, @bitCast(hiWord(w_param))))) / WHEEL_DELTA;
            // Positive is away from the user, which scrolls the content down
            // the screen -- the same sign Þviti's scroll views subtract.
            self.events.wheel(0, notches * self.wheelPixels());
            return 0;
        },
        WM_MOUSEHWHEEL => {
            const notches = @as(f32, @floatFromInt(@as(i16, @bitCast(hiWord(w_param))))) / WHEEL_DELTA;
            // Positive is to the right, and the content moves the other way.
            self.events.wheel(-notches * self.wheelPixels(), 0);
            return 0;
        },
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            self.events.setModifiers(currentModifiers());
            // Bit 30 of lParam is the previous key state: set means this is a
            // repeat rather than a fresh press.
            const repeat = (@as(usize, @bitCast(l_param)) >> 30) & 1 != 0;
            const vk: u32 = @intCast(w_param & 0xff);
            self.events.keyChar(mapKey(vk), labelOf(vk), true, repeat) catch {
                self.oom = true;
            };
            // System keys still go to `DefWindowProc`, which is what turns
            // Alt+F4 into a close and Alt into a menu activation.
            if (msg == WM_SYSKEYDOWN) return DefWindowProcW(self.hwnd, msg, w_param, l_param);
            return 0;
        },
        WM_KEYUP, WM_SYSKEYUP => {
            self.events.setModifiers(currentModifiers());
            const vk: u32 = @intCast(w_param & 0xff);
            self.events.keyChar(mapKey(vk), labelOf(vk), false, false) catch {
                self.oom = true;
            };
            if (msg == WM_SYSKEYUP) return DefWindowProcW(self.hwnd, msg, w_param, l_param);
            return 0;
        },
        WM_CHAR, WM_SYSCHAR => {
            self.character(@truncate(w_param));
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, w_param, l_param),
    }
}

fn mouseDown(self: *Win32, which: thviti.input.MouseButton, l_param: LPARAM) LRESULT {
    const p = pointOf(l_param);
    self.events.moved(p.x, p.y);
    self.events.setModifiers(currentModifiers());
    self.events.button(which, true);

    // Capture on the first button only. Calling it again for the second would
    // be harmless; releasing it on the first release would not be, and the
    // count is what keeps those two straight.
    if (self.buttons_down == 0) _ = SetCapture(self.hwnd);
    self.buttons_down += 1;
    return 0;
}

fn mouseUp(self: *Win32, which: thviti.input.MouseButton, l_param: LPARAM) LRESULT {
    const p = pointOf(l_param);
    self.events.moved(p.x, p.y);
    self.events.setModifiers(currentModifiers());
    self.events.button(which, false);

    // Saturating, because a button can be released here that was pressed
    // before the window had focus -- the press went somewhere else and the
    // release still arrives.
    self.buttons_down -|= 1;
    if (self.buttons_down == 0) _ = ReleaseCapture();
    return 0;
}

/// One UTF-16 code unit from `WM_CHAR`, turned into UTF-8 once it is a whole
/// character.
fn character(self: *Win32, unit: u16) void {
    // Control characters are keys, not text. Backspace, tab, escape and enter
    // all arrive here as well as through `WM_KEYDOWN`, and a text field that
    // inserts them ends up with a literal 0x08 in the document.
    if (self.pending_surrogate == null and (unit < 0x20 or unit == 0x7f)) return;

    var pair: [2]u16 = undefined;
    var units: []const u16 = pair[0..1];

    if (std.unicode.utf16IsHighSurrogate(unit)) {
        // Half a character. Held until its other half arrives.
        self.pending_surrogate = unit;
        return;
    }
    if (self.pending_surrogate) |high| {
        self.pending_surrogate = null;
        if (!std.unicode.utf16IsLowSurrogate(unit)) {
            // A high surrogate followed by anything else is malformed. Drop
            // the orphan rather than emitting it as a character in its own
            // right, which would be an unpaired surrogate in supposedly valid
            // UTF-8.
            if (unit < 0x20 or unit == 0x7f) return;
            pair[0] = unit;
        } else {
            pair[0] = high;
            pair[1] = unit;
            units = pair[0..2];
        }
    } else {
        pair[0] = unit;
    }

    var buf: [4]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&buf, units) catch return;
    self.events.typed(buf[0..n]) catch {
        self.oom = true;
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the key map covers the named keys and refuses to name letters" {
    try testing.expectEqual(KeyCode.escape, mapKey(VK_ESCAPE));
    try testing.expectEqual(KeyCode.page_down, mapKey(VK_NEXT));
    try testing.expectEqual(KeyCode.f1, mapKey(VK_F1));
    try testing.expectEqual(KeyCode.f12, mapKey(VK_F12));
    try testing.expectEqual(KeyCode.f5, mapKey(VK_F1 + 4));

    // `A` is 0x41 and produces `a`, `A`, or on a French layout the character
    // on the Q key. None of those is a name, so it has none.
    try testing.expectEqual(KeyCode.other, mapKey(0x41));
    try testing.expectEqual(KeyCode.other, mapKey(0x30));
}

test "mouse coordinates are signed, because a captured drag goes negative" {
    // (-3, -7) packed the way Windows packs it. Read as unsigned this is
    // (65533, 65529) and the pointer teleports off the screen.
    const packed_bits: usize = (@as(usize, 0xfff9) << 16) | 0xfffd;
    const p = pointOf(@bitCast(packed_bits));
    try testing.expectEqual(@as(f32, -3), p.x);
    try testing.expectEqual(@as(f32, -7), p.y);

    const positive: usize = (@as(usize, 300) << 16) | 40;
    const q = pointOf(@bitCast(positive));
    try testing.expectEqual(@as(f32, 40), q.x);
    try testing.expectEqual(@as(f32, 300), q.y);
}

test "a character outside the basic plane needs both of its halves" {
    // U+1F600, which Windows delivers as D83D DE00 in two messages. Emitting
    // either half alone would put an unpaired surrogate into what is supposed
    // to be UTF-8.
    var self: Win32 = .{
        .gpa = testing.allocator,
        .events = .init(testing.allocator),
        .options = .{},
        .late = .{},
    };
    defer self.events.deinit();

    self.character(0xd83d);
    try testing.expectEqual(@as(usize, 0), self.events.pending.items.len);
    self.character(0xde00);

    const in = try self.events.take(0.016);
    try testing.expectEqual(@as(usize, 1), in.events.len);
    try testing.expectEqualStrings("\u{1F600}", in.events[0].text);
}

test "control characters are keys and never text" {
    var self: Win32 = .{
        .gpa = testing.allocator,
        .events = .init(testing.allocator),
        .options = .{},
        .late = .{},
    };
    defer self.events.deinit();

    // Backspace, tab, enter and escape all arrive as WM_CHAR too. A text field
    // that inserted them would put a literal 0x08 in the document.
    for ([_]u16{ 0x08, 0x09, 0x0d, 0x1b, 0x7f }) |c| self.character(c);
    try testing.expectEqual(@as(usize, 0), self.events.pending.items.len);

    self.character('x');
    const in = try self.events.take(0.016);
    try testing.expectEqual(@as(usize, 1), in.events.len);
    try testing.expectEqualStrings("x", in.events[0].text);
}

test "an orphaned high surrogate does not poison the next character" {
    var self: Win32 = .{
        .gpa = testing.allocator,
        .events = .init(testing.allocator),
        .options = .{},
        .late = .{},
    };
    defer self.events.deinit();

    self.character(0xd83d);
    self.character('a'); // not a low surrogate
    const in = try self.events.take(0.016);
    try testing.expectEqual(@as(usize, 1), in.events.len);
    try testing.expectEqualStrings("a", in.events[0].text);
    try testing.expectEqual(@as(?u16, null), self.pending_surrogate);
}
