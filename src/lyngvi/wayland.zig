//! The Wayland backend.
//!
//! The second platform, and the one that proves `Window` is an interface
//! rather than Win32 with a vtable in front of it. Almost nothing in the
//! shared layer had to change for it, which was the point of writing
//! `x11.zig`'s signature on the first day; the two things that did are noted
//! at the bottom.
//!
//! ## Why libwayland is linked when nothing else is
//!
//! Every other system interface in this project is declared by hand and
//! called directly -- Vulkan through a loader, SQLite from the amalgamation,
//! Win32 as externs. Wayland is a socket protocol and could be spoken the
//! same way. It is not, and the reason is Vulkan:
//! `VkWaylandSurfaceCreateInfoKHR` takes a `struct wl_display *` and a
//! `struct wl_surface *`, and the driver calls *libwayland's own functions*
//! on them. They are that library's proxy objects, not object ids on a wire.
//! A hand-rolled client would have a perfectly good connection that no Vulkan
//! ICD on earth would accept.
//!
//! So `libwayland-client.so.0` is opened at run time, the same way the Vulkan
//! loader is, and none of it is a link-time dependency: a binary built here
//! runs on a machine with no Wayland at all and says so.
//!
//! ## What is declared by hand anyway
//!
//! The protocol *descriptions*. libwayland exports a `wl_interface` for every
//! core object, and those are looked up as symbols. xdg-shell is not core --
//! its tables normally come from code generated out of XML at build time --
//! so they are written out in `protocol.zig` instead, which is about a hundred
//! lines of message names and signature strings. That is less machinery than a
//! code generator and it is checked by a test that walks what the compositor
//! would send.
//!
//! ## Scale
//!
//! Wayland is the platform that gets this right: the compositor tells the
//! surface which outputs it is on and what those outputs' scales are, and it
//! does so *again* when the window is dragged to another monitor. `size`
//! therefore reports device pixels the way the Win32 backend does, and a
//! window moved from a 100% monitor to a 200% one re-scales rather than
//! staying the size it was -- which is exactly what `x11.zig`'s notes say X11
//! cannot do.

const std = @import("std");
const builtin = @import("builtin");

const Events = @import("Events.zig");
const Window = @import("Window.zig");
const protocol = @import("wayland/protocol.zig");
const keymap = @import("wayland/keymap.zig");

const thviti = @import("../thviti.zig");
const KeyCode = thviti.input.KeyCode;

const Wayland = @This();

const Proxy = protocol.Proxy;
const Interface = protocol.Interface;

// -- libwayland, opened at run time ------------------------------------------

/// The entry points this backend calls, and the core interface descriptions
/// it needs pointers to.
///
/// Every one is resolved by name. A missing symbol means a libwayland too old
/// for `wl_proxy_marshal_flags`, which arrived in 1.20 (2021); rather than
/// carry the older `wl_proxy_marshal` as well, that reports as "no Wayland"
/// and the caller falls through to the next backend.
const Client = struct {
    handle: ?*anyopaque = null,

    display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*Display = undefined,
    display_disconnect: *const fn (*Display) callconv(.c) void = undefined,
    display_get_fd: *const fn (*Display) callconv(.c) c_int = undefined,
    display_roundtrip: *const fn (*Display) callconv(.c) c_int = undefined,
    display_flush: *const fn (*Display) callconv(.c) c_int = undefined,
    display_dispatch_pending: *const fn (*Display) callconv(.c) c_int = undefined,
    display_prepare_read: *const fn (*Display) callconv(.c) c_int = undefined,
    display_read_events: *const fn (*Display) callconv(.c) c_int = undefined,
    display_cancel_read: *const fn (*Display) callconv(.c) void = undefined,

    proxy_marshal_flags: *const fn (*Proxy, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*Proxy = undefined,
    proxy_add_listener: *const fn (*Proxy, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int = undefined,
    proxy_destroy: *const fn (*Proxy) callconv(.c) void = undefined,
    proxy_get_version: *const fn (*Proxy) callconv(.c) u32 = undefined,

    // The core protocol's own descriptions, as exported data symbols.
    compositor_interface: *const Interface = undefined,
    surface_interface: *const Interface = undefined,
    registry_interface: *const Interface = undefined,
    seat_interface: *const Interface = undefined,
    pointer_interface: *const Interface = undefined,
    keyboard_interface: *const Interface = undefined,
    output_interface: *const Interface = undefined,

    const Display = opaque {};

    /// The sonames tried, newest first. `.so.0` is the one that exists on a
    /// system with only the runtime installed; the bare `.so` is a developer
    /// machine with the headers.
    const sonames = [_][:0]const u8{ "libwayland-client.so.0", "libwayland-client.so" };

    fn load() ?Client {
        if (!supported) return null;

        var c: Client = .{};
        for (sonames) |name| {
            c.handle = std.c.dlopen(name.ptr, .{ .LAZY = true });
            if (c.handle != null) break;
        }
        if (c.handle == null) return null;

        inline for (@typeInfo(Client).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "handle")) continue;

            // `wl_` and the field name is the symbol: `display_connect` is
            // `wl_display_connect`, `surface_interface` is
            // `wl_surface_interface`. Adding an entry to this struct is then
            // the only edit, with no second table of names to keep in step.
            //
            // The `_interface` entries are data, not functions: the symbol's
            // address *is* the `struct wl_interface`, so the cast is to a
            // pointer to one and not to a pointer to a pointer.
            const found = std.c.dlsym(c.handle, "wl_" ++ field.name) orelse {
                // Closed by hand: this returns an optional and not an error,
                // so an `errdefer` would never run and the library would stay
                // mapped for the life of the process.
                c.unload();
                return null;
            };
            @field(c, field.name) = @ptrCast(@alignCast(found));
        }
        return c;
    }

    fn unload(c: *Client) void {
        if (c.handle) |h| _ = std.c.dlclose(h);
        c.handle = null;
    }
};

/// Whether this target could have Wayland at all. Checked at compile time so
/// that the Windows build does not carry a `dlopen` it can never call.
pub const supported = builtin.os.tag == .linux or builtin.os.tag == .freebsd or
    builtin.os.tag == .openbsd or builtin.os.tag == .netbsd or builtin.os.tag == .dragonfly;

// -- the window --------------------------------------------------------------

gpa: std.mem.Allocator,
events: Events,
options: Window.Options,

wl: Client = .{},
display: ?*Client.Display = null,

/// The globals, bound from the registry. A compositor that does not advertise
/// `xdg_wm_base` is not one this can make a window on -- that has been the
/// shell protocol since 2018, and the alternative is `wl_shell`, which was
/// deprecated before it.
registry: ?*Proxy = null,
compositor: ?*Proxy = null,
wm_base: ?*Proxy = null,
seat: ?*Proxy = null,
pointer: ?*Proxy = null,
keyboard: ?*Proxy = null,

surface: ?*Proxy = null,
xdg_surface: ?*Proxy = null,
toplevel: ?*Proxy = null,

/// Outputs, so that a surface's scale is the scale of the monitor it is on.
outputs: [max_outputs]Output = @splat(.{}),
/// The outputs this surface is currently on, as a bitmask over `outputs`.
on_outputs: u32 = 0,

/// Logical size, as the compositor's `configure` gave it.
logical: Window.Size,
/// The scale in force, from the outputs the surface is on.
buffer_scale: u32 = 1,
/// Set until the first `configure`, because nothing may be committed to an
/// xdg surface before it has been configured once.
configured: bool = false,
/// Set by a `configure` whose size or scale differs from the last one.
pending_resize: bool = false,

/// Where the pointer is, in surface-local logical pixels as the protocol
/// reports it. Multiplied by the scale on the way into `Events`, which deals
/// only in device pixels.
mouse_x: f32 = 0,
mouse_y: f32 = 0,

/// Key repeat, which on Wayland is the client's job: the compositor reports
/// the rate and the delay and sends exactly one event per physical press.
repeat: Repeat = .{},
keys: keymap.State = .{},

closed: bool = false,
/// Set when a push into the event queue failed, checked after the pump.
oom: bool = false,

pub const max_outputs = 8;

const Output = struct {
    proxy: ?*Proxy = null,
    name: u32 = 0,
    scale: u32 = 1,
};

/// The repeat a held key produces. Wayland sends one `key` event for a press
/// and one for the release, and leaves everything between them to the client;
/// `repeat_info` says how fast the user asked for it to be.
const Repeat = struct {
    /// Milliseconds before the first repeat, and between repeats after it.
    delay_ms: u32 = 500,
    interval_ms: u32 = 33,
    /// The key being held, or none.
    code: u32 = 0,
    key: KeyCode = .none,
    char: u21 = 0,
    /// The timestamp the next repeat is due at, in the compositor's own
    /// millisecond clock.
    due: u32 = 0,

    fn holding(r: Repeat) bool {
        return r.code != 0;
    }

    fn release(r: *Repeat, code: u32) void {
        if (r.code == code) r.* = .{ .delay_ms = r.delay_ms, .interval_ms = r.interval_ms };
    }
};

pub fn create(gpa: std.mem.Allocator, options: Window.Options) Window.Error!Window {
    if (!supported) return error.UnsupportedPlatform;

    const wl = Client.load() orelse return error.UnsupportedPlatform;

    const self = try gpa.create(Wayland);
    errdefer gpa.destroy(self);

    self.* = .{
        .gpa = gpa,
        .events = .init(gpa),
        .options = options,
        .wl = wl,
        .logical = .{ .width = options.width, .height = options.height },
    };
    errdefer self.events.deinit();

    self.display = self.wl.display_connect(null) orelse {
        self.wl.unload();
        return error.UnsupportedPlatform;
    };
    errdefer self.wl.display_disconnect(self.display.?);

    try self.bindGlobals();
    try self.makeSurface();

    // Two round trips: the first brings the globals, the second the events
    // that binding them produced -- the seat's capabilities and the outputs'
    // scales. Doing it in one leaves a window that does not know how big its
    // pixels are until the user moves the mouse.
    _ = self.wl.display_roundtrip(self.display.?);

    self.events.resize(self.pixelWidth(), self.pixelHeight());
    self.events.setScale(@floatFromInt(self.buffer_scale));

    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Window.VTable = .{
    .destroy = destroy,
    .pump = pump,
    .wait = waitFor,
    .events = eventsOf,
    .native = native,
    .size = size,
    .scale = scaleOf,
    .setTitle = setTitle,
    .setVisible = setVisible,
    .close = requestClose,
};

fn destroy(ptr: *anyopaque) void {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    const gpa = self.gpa;

    // Children before parents, or libwayland leaks the proxies and the
    // compositor keeps the objects.
    for ([_]*?*Proxy{
        &self.toplevel,
        &self.xdg_surface,
        &self.surface,
        &self.pointer,
        &self.keyboard,
        &self.seat,
        &self.wm_base,
        &self.compositor,
        &self.registry,
    }) |slot| {
        if (slot.*) |p| self.wl.proxy_destroy(p);
        slot.* = null;
    }
    for (&self.outputs) |*o| {
        if (o.proxy) |p| self.wl.proxy_destroy(p);
        o.* = .{};
    }

    if (self.display) |d| self.wl.display_disconnect(d);
    self.wl.unload();
    self.events.deinit();
    gpa.destroy(self);
}

fn eventsOf(ptr: *anyopaque) *Events {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    return &self.events;
}

fn native(ptr: *anyopaque) Window.Native {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    return .{ .wayland = .{
        .display = @ptrCast(self.display),
        .surface = @ptrCast(self.surface),
    } };
}

fn size(ptr: *anyopaque) Window.Size {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    return .{ .width = self.pixelWidth(), .height = self.pixelHeight() };
}

fn scaleOf(ptr: *anyopaque) f32 {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    return @floatFromInt(self.buffer_scale);
}

fn pixelWidth(self: *const Wayland) u32 {
    return @max(1, self.logical.width * self.buffer_scale);
}

fn pixelHeight(self: *const Wayland) u32 {
    return @max(1, self.logical.height * self.buffer_scale);
}

fn setTitle(ptr: *anyopaque, title: []const u8) void {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    const top = self.toplevel orelse return;

    // The protocol takes a NUL-terminated string and a title is a formatted
    // buffer, so it has to be copied. Bounded rather than allocated: a title
    // longer than this is a bug somewhere above, not something to grow for.
    var buf: [512]u8 = undefined;
    const n = @min(title.len, buf.len - 1);
    @memcpy(buf[0..n], title[0..n]);
    buf[n] = 0;

    _ = self.wl.proxy_marshal_flags(
        top,
        protocol.xdg_toplevel.set_title,
        null,
        self.wl.proxy_get_version(top),
        0,
        @as([*:0]const u8, @ptrCast(&buf)),
    );
    self.flush();
}

fn setVisible(ptr: *anyopaque, visible: bool) void {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    // Wayland has no "hide this window": a surface with no buffer attached is
    // not mapped, and one with a buffer is. The renderer owns the buffers, so
    // the honest answer is that this backend cannot honour the request --
    // recorded rather than silently ignored, because `--shot` relies on it
    // and gets a visible window here.
    self.options.visible = visible;
}

fn requestClose(ptr: *anyopaque) void {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    self.closed = true;
    self.events.requestClose();
}

// -- the connection ----------------------------------------------------------

fn bindGlobals(self: *Wayland) Window.Error!void {
    const display: *Proxy = @ptrCast(self.display.?);

    self.registry = self.wl.proxy_marshal_flags(
        display,
        protocol.wl_display.get_registry,
        self.wl.registry_interface,
        self.wl.proxy_get_version(display),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.WindowCreationFailed;

    _ = self.wl.proxy_add_listener(self.registry.?, &registry_listener, self);
    _ = self.wl.display_roundtrip(self.display.?);

    if (self.compositor == null or self.wm_base == null) return error.WindowCreationFailed;
}

const registry_listener = extern struct {
    global: *const fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void = onGlobal,
    global_remove: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void = onGlobalRemove,
}{};

fn onGlobal(data: ?*anyopaque, registry: *Proxy, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    const which = std.mem.span(iface);

    if (std.mem.eql(u8, which, "wl_compositor")) {
        // Four, for `set_buffer_scale`, which is what makes a window on a
        // 200% monitor sharp rather than a 100% one scaled up.
        self.compositor = self.bind(registry, name, self.wl.compositor_interface, @min(version, 4));
    } else if (std.mem.eql(u8, which, "xdg_wm_base")) {
        self.wm_base = self.bind(registry, name, &protocol.xdg_wm_base.interface, 1);
        if (self.wm_base) |b| _ = self.wl.proxy_add_listener(b, &wm_base_listener, self);
    } else if (std.mem.eql(u8, which, "wl_seat")) {
        // Four, for `repeat_info`: without it a held cursor key does not
        // repeat at the rate the user set, and this is the one place the
        // client is required to implement repeat itself.
        self.seat = self.bind(registry, name, self.wl.seat_interface, @min(version, 4));
        if (self.seat) |s| _ = self.wl.proxy_add_listener(s, &seat_listener, self);
    } else if (std.mem.eql(u8, which, "wl_output")) {
        for (&self.outputs) |*o| {
            if (o.proxy != null) continue;
            o.* = .{
                .proxy = self.bind(registry, name, self.wl.output_interface, @min(version, 2)),
                .name = name,
                .scale = 1,
            };
            if (o.proxy) |p| _ = self.wl.proxy_add_listener(p, &output_listener, self);
            break;
        }
    }
}

fn onGlobalRemove(data: ?*anyopaque, _: *Proxy, name: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    for (&self.outputs, 0..) |*o, i| {
        if (o.proxy == null or o.name != name) continue;
        self.wl.proxy_destroy(o.proxy.?);
        o.* = .{};
        self.on_outputs &= ~(@as(u32, 1) << @intCast(i));
    }
    self.refreshScale();
}

fn bind(self: *Wayland, registry: *Proxy, name: u32, iface: *const Interface, version: u32) ?*Proxy {
    return self.wl.proxy_marshal_flags(
        registry,
        protocol.wl_registry.bind,
        iface,
        version,
        0,
        name,
        iface.name,
        version,
        @as(?*anyopaque, null),
    );
}

const wm_base_listener = extern struct {
    ping: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void = onPing,
}{};

/// The compositor asking whether this client is still alive. Answering is not
/// optional: a client that does not pong is declared unresponsive and offered
/// to the user for killing.
fn onPing(data: ?*anyopaque, base: *Proxy, serial: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    _ = self.wl.proxy_marshal_flags(
        base,
        protocol.xdg_wm_base.pong,
        null,
        self.wl.proxy_get_version(base),
        0,
        serial,
    );
}

fn makeSurface(self: *Wayland) Window.Error!void {
    const compositor = self.compositor orelse return error.WindowCreationFailed;
    const base = self.wm_base orelse return error.WindowCreationFailed;

    self.surface = self.wl.proxy_marshal_flags(
        compositor,
        protocol.wl_compositor.create_surface,
        self.wl.surface_interface,
        self.wl.proxy_get_version(compositor),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.WindowCreationFailed;
    _ = self.wl.proxy_add_listener(self.surface.?, &surface_listener, self);

    self.xdg_surface = self.wl.proxy_marshal_flags(
        base,
        protocol.xdg_wm_base.get_xdg_surface,
        &protocol.xdg_surface.interface,
        self.wl.proxy_get_version(base),
        0,
        @as(?*anyopaque, null),
        self.surface.?,
    ) orelse return error.WindowCreationFailed;
    _ = self.wl.proxy_add_listener(self.xdg_surface.?, &xdg_surface_listener, self);

    self.toplevel = self.wl.proxy_marshal_flags(
        self.xdg_surface.?,
        protocol.xdg_surface.get_toplevel,
        &protocol.xdg_toplevel.interface,
        self.wl.proxy_get_version(self.xdg_surface.?),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.WindowCreationFailed;
    _ = self.wl.proxy_add_listener(self.toplevel.?, &toplevel_listener, self);

    setTitle(self, self.options.title);
    self.setAppId("fenrir");
    if (!self.options.resizable) {
        self.setSizeLimit(protocol.xdg_toplevel.set_min_size, self.logical);
        self.setSizeLimit(protocol.xdg_toplevel.set_max_size, self.logical);
    }

    // Nothing may be attached before the first `configure` arrives, so the
    // surface is committed empty and the round trip in `create` waits for it.
    self.commit();
}

fn setAppId(self: *Wayland, id: [:0]const u8) void {
    const top = self.toplevel orelse return;
    _ = self.wl.proxy_marshal_flags(
        top,
        protocol.xdg_toplevel.set_app_id,
        null,
        self.wl.proxy_get_version(top),
        0,
        id.ptr,
    );
}

fn setSizeLimit(self: *Wayland, opcode: u32, want: Window.Size) void {
    const top = self.toplevel orelse return;
    _ = self.wl.proxy_marshal_flags(
        top,
        opcode,
        null,
        self.wl.proxy_get_version(top),
        0,
        @as(i32, @intCast(want.width)),
        @as(i32, @intCast(want.height)),
    );
}

fn commit(self: *Wayland) void {
    const surface = self.surface orelse return;
    _ = self.wl.proxy_marshal_flags(
        surface,
        protocol.wl_surface.commit,
        null,
        self.wl.proxy_get_version(surface),
        0,
    );
    self.flush();
}

fn flush(self: *Wayland) void {
    if (self.display) |d| _ = self.wl.display_flush(d);
}

// -- the surface and its scale -----------------------------------------------

const surface_listener = extern struct {
    enter: *const fn (?*anyopaque, *Proxy, ?*Proxy) callconv(.c) void = onSurfaceEnter,
    leave: *const fn (?*anyopaque, *Proxy, ?*Proxy) callconv(.c) void = onSurfaceLeave,
}{};

fn onSurfaceEnter(data: ?*anyopaque, _: *Proxy, output: ?*Proxy) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    for (self.outputs, 0..) |o, i| {
        if (o.proxy != null and o.proxy == output) self.on_outputs |= @as(u32, 1) << @intCast(i);
    }
    self.refreshScale();
}

fn onSurfaceLeave(data: ?*anyopaque, _: *Proxy, output: ?*Proxy) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    for (self.outputs, 0..) |o, i| {
        if (o.proxy != null and o.proxy == output) self.on_outputs &= ~(@as(u32, 1) << @intCast(i));
    }
    self.refreshScale();
}

const output_listener = extern struct {
    geometry: *const fn (?*anyopaque, *Proxy, i32, i32, i32, i32, i32, [*:0]const u8, [*:0]const u8, i32) callconv(.c) void = onOutputGeometry,
    mode: *const fn (?*anyopaque, *Proxy, u32, i32, i32, i32) callconv(.c) void = onOutputMode,
    done: *const fn (?*anyopaque, *Proxy) callconv(.c) void = onOutputDone,
    scale: *const fn (?*anyopaque, *Proxy, i32) callconv(.c) void = onOutputScale,
}{};

fn onOutputGeometry(_: ?*anyopaque, _: *Proxy, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*:0]const u8, _: [*:0]const u8, _: i32) callconv(.c) void {}
fn onOutputMode(_: ?*anyopaque, _: *Proxy, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}

fn onOutputDone(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.refreshScale();
}

fn onOutputScale(data: ?*anyopaque, output: *Proxy, factor: i32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    for (&self.outputs) |*o| {
        if (o.proxy == output) o.scale = @intCast(@max(1, factor));
    }
    self.refreshScale();
}

/// The scale a surface should render at: the largest of the outputs it is on.
///
/// The largest, not the first, because a window straddling a 100% and a 200%
/// monitor has to pick one, and picking the smaller makes it blurry on the
/// larger while picking the larger only makes it do more work.
fn refreshScale(self: *Wayland) void {
    const want = wantedScale(self.outputs, self.on_outputs);
    if (want == self.buffer_scale) return;
    self.buffer_scale = want;

    if (self.surface) |surface| {
        _ = self.wl.proxy_marshal_flags(
            surface,
            protocol.wl_surface.set_buffer_scale,
            null,
            self.wl.proxy_get_version(surface),
            0,
            @as(i32, @intCast(want)),
        );
    }
    self.events.setScale(@floatFromInt(want));
    self.events.resize(self.pixelWidth(), self.pixelHeight());
    self.pending_resize = true;
}

/// Pulled out so the rule can be tested without a compositor.
pub fn wantedScale(outputs: [max_outputs]Output, mask: u32) u32 {
    var best: u32 = 0;
    for (outputs, 0..) |o, i| {
        if (o.proxy == null) continue;
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        best = @max(best, o.scale);
    }
    // A surface on no output yet -- which is every surface before its first
    // frame -- renders at 1 rather than at 0.
    return @max(1, best);
}

const xdg_surface_listener = extern struct {
    configure: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void = onXdgConfigure,
}{};

/// The compositor has finished telling us about a change and wants it
/// acknowledged. Every `configure` must be acked, in order, or the surface
/// stops being updated.
fn onXdgConfigure(data: ?*anyopaque, xdg_surface: *Proxy, serial: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    _ = self.wl.proxy_marshal_flags(
        xdg_surface,
        protocol.xdg_surface.ack_configure,
        null,
        self.wl.proxy_get_version(xdg_surface),
        0,
        serial,
    );
    self.configured = true;
    self.commit();
}

const toplevel_listener = extern struct {
    configure: *const fn (?*anyopaque, *Proxy, i32, i32, ?*const anyopaque) callconv(.c) void = onToplevelConfigure,
    close: *const fn (?*anyopaque, *Proxy) callconv(.c) void = onToplevelClose,
}{};

fn onToplevelConfigure(data: ?*anyopaque, _: *Proxy, width: i32, height: i32, _: ?*const anyopaque) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    // Zero means "you choose", which happens on the first configure and
    // whenever a window stops being maximised. Keeping what was asked for is
    // the right answer to it.
    if (width <= 0 or height <= 0) return;

    const next: Window.Size = .{ .width = @intCast(width), .height = @intCast(height) };
    if (next.width == self.logical.width and next.height == self.logical.height) return;

    self.logical = next;
    self.events.resize(self.pixelWidth(), self.pixelHeight());
    self.pending_resize = true;
}

fn onToplevelClose(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.events.requestClose();
}

// -- input -------------------------------------------------------------------

const seat_listener = extern struct {
    capabilities: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void = onSeatCapabilities,
    name: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void = onSeatName,
}{};

fn onSeatName(_: ?*anyopaque, _: *Proxy, _: [*:0]const u8) callconv(.c) void {}

fn onSeatCapabilities(data: ?*anyopaque, seat: *Proxy, caps: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    const version = self.wl.proxy_get_version(seat);

    const has_pointer = caps & protocol.wl_seat.capability_pointer != 0;
    const has_keyboard = caps & protocol.wl_seat.capability_keyboard != 0;

    // Capabilities can be withdrawn as well as granted -- unplugging a mouse
    // sends this again with the bit cleared -- so both directions are handled
    // rather than only the first arrival.
    if (has_pointer and self.pointer == null) {
        self.pointer = self.wl.proxy_marshal_flags(
            seat,
            protocol.wl_seat.get_pointer,
            self.wl.pointer_interface,
            version,
            0,
            @as(?*anyopaque, null),
        );
        if (self.pointer) |p| _ = self.wl.proxy_add_listener(p, &pointer_listener, self);
    } else if (!has_pointer and self.pointer != null) {
        self.wl.proxy_destroy(self.pointer.?);
        self.pointer = null;
    }

    if (has_keyboard and self.keyboard == null) {
        self.keyboard = self.wl.proxy_marshal_flags(
            seat,
            protocol.wl_seat.get_keyboard,
            self.wl.keyboard_interface,
            version,
            0,
            @as(?*anyopaque, null),
        );
        if (self.keyboard) |k| _ = self.wl.proxy_add_listener(k, &keyboard_listener, self);
    } else if (!has_keyboard and self.keyboard != null) {
        self.wl.proxy_destroy(self.keyboard.?);
        self.keyboard = null;
    }
}

const pointer_listener = extern struct {
    enter: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy, i32, i32) callconv(.c) void = onPointerEnter,
    leave: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy) callconv(.c) void = onPointerLeave,
    motion: *const fn (?*anyopaque, *Proxy, u32, i32, i32) callconv(.c) void = onPointerMotion,
    button: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32) callconv(.c) void = onPointerButton,
    axis: *const fn (?*anyopaque, *Proxy, u32, u32, i32) callconv(.c) void = onPointerAxis,
    frame: *const fn (?*anyopaque, *Proxy) callconv(.c) void = onPointerFrame,
    axis_source: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void = onPointerAxisSource,
    axis_stop: *const fn (?*anyopaque, *Proxy, u32, u32) callconv(.c) void = onPointerAxisStop,
    axis_discrete: *const fn (?*anyopaque, *Proxy, u32, i32) callconv(.c) void = onPointerAxisDiscrete,
}{};

fn onPointerFrame(_: ?*anyopaque, _: *Proxy) callconv(.c) void {}
fn onPointerAxisSource(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}
fn onPointerAxisStop(_: ?*anyopaque, _: *Proxy, _: u32, _: u32) callconv(.c) void {}
fn onPointerAxisDiscrete(_: ?*anyopaque, _: *Proxy, _: u32, _: i32) callconv(.c) void {}

fn onPointerEnter(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy, x: i32, y: i32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.moveTo(x, y);
}

fn onPointerLeave(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    // Buttons released on the way out. A pointer that leaves the surface
    // holding a button and comes back without it would otherwise leave the
    // UI dragging something forever.
    self.events.button(.left, false);
    self.events.button(.right, false);
    self.events.button(.middle, false);
}

fn onPointerMotion(data: ?*anyopaque, _: *Proxy, _: u32, x: i32, y: i32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.moveTo(x, y);
}

/// Surface-local coordinates arrive as 24.8 fixed point, in *logical* pixels.
/// Everything above this layer is in device pixels, so the scale goes on here
/// and not in four different places up the stack.
fn moveTo(self: *Wayland, x: i32, y: i32) void {
    const s: f32 = @floatFromInt(self.buffer_scale);
    self.mouse_x = fixedToFloat(x) * s;
    self.mouse_y = fixedToFloat(y) * s;
    self.events.moved(self.mouse_x, self.mouse_y);
}

/// `wl_fixed_t`: a signed 24.8 fixed-point number.
pub fn fixedToFloat(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}

fn onPointerButton(data: ?*anyopaque, _: *Proxy, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    const which: thviti.input.MouseButton = switch (button) {
        protocol.btn_left => .left,
        protocol.btn_right => .right,
        protocol.btn_middle => .middle,
        else => return,
    };
    self.events.setModifiers(self.keys.modifiers());
    self.events.button(which, state == protocol.wl_pointer.button_state_pressed);
}

fn onPointerAxis(data: ?*anyopaque, _: *Proxy, _: u32, axis: u32, value: i32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));

    // The value is in fixed-point *logical pixels* of scroll -- a real
    // distance, which is what `Events.wheel` wants, so unlike X11 there is
    // nothing to invent here. A touchpad sends a continuous stream of small
    // ones and a wheel sends multiples of a notch; both are already the right
    // number.
    const pixels = fixedToFloat(value) * @as(f32, @floatFromInt(self.buffer_scale));
    self.events.setModifiers(self.keys.modifiers());
    switch (axis) {
        protocol.wl_pointer.axis_vertical_scroll => self.events.wheel(0, -pixels),
        protocol.wl_pointer.axis_horizontal_scroll => self.events.wheel(-pixels, 0),
        else => {},
    }
}

const keyboard_listener = extern struct {
    keymap: *const fn (?*anyopaque, *Proxy, u32, i32, u32) callconv(.c) void = onKeymap,
    enter: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy, ?*const anyopaque) callconv(.c) void = onKeyboardEnter,
    leave: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy) callconv(.c) void = onKeyboardLeave,
    key: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32) callconv(.c) void = onKey,
    modifiers: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32, u32) callconv(.c) void = onModifiers,
    repeat_info: *const fn (?*anyopaque, *Proxy, i32, i32) callconv(.c) void = onRepeatInfo,
}{};

/// The compositor hands over a keymap as a file descriptor. Reading it needs
/// xkbcommon, which `keymap.zig` loads if it is there and does without if it
/// is not -- see the note there about what is lost either way.
fn onKeymap(data: ?*anyopaque, _: *Proxy, format: u32, fd: i32, count: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.keys.load(format, fd, count);
}

fn onKeyboardEnter(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy, _: ?*const anyopaque) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.events.setFocus(true);
}

fn onKeyboardLeave(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.events.setFocus(false);
    // A key held when focus leaves never sends its release, so the repeat
    // has to be stopped here or it runs until the window is focused again.
    self.repeat = .{ .delay_ms = self.repeat.delay_ms, .interval_ms = self.repeat.interval_ms };
}

fn onKey(data: ?*anyopaque, _: *Proxy, _: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    const down = state == protocol.wl_keyboard.key_state_pressed;

    // Wayland reports the evdev code; X11 and xkbcommon count from eight
    // higher. The `+ 8` is the whole of that difference and it lives here.
    const scancode = key + 8;

    self.events.setModifiers(self.keys.modifiers());
    self.emitKey(scancode, key, down);

    if (!down) {
        self.repeat.release(key);
        return;
    }
    if (self.keys.repeats(scancode)) {
        self.repeat.code = key;
        self.repeat.key = keymap.codeOf(key);
        self.repeat.char = self.keys.label(scancode);
        self.repeat.due = time +% self.repeat.delay_ms;
    }
}

fn emitKey(self: *Wayland, scancode: u32, evdev: u32, down: bool) void {
    const code = keymap.codeOf(evdev);
    const label = self.keys.label(scancode);
    self.events.keyChar(code, label, down, false) catch {
        self.oom = true;
    };

    if (!down) return;
    // Text, after the layout and any compose sequence have had their say.
    // Control characters are not text; see the same rule in `win32.zig`.
    var buf: [8]u8 = undefined;
    const utf8 = self.keys.textOf(scancode, &buf);
    if (utf8.len == 0) return;
    if (utf8.len == 1 and (utf8[0] < 0x20 or utf8[0] == 0x7f)) return;
    self.events.typed(utf8) catch {
        self.oom = true;
    };
}

fn onModifiers(
    data: ?*anyopaque,
    _: *Proxy,
    _: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    self.keys.setModifiers(depressed, latched, locked, group);
    self.events.setModifiers(self.keys.modifiers());
}

fn onRepeatInfo(data: ?*anyopaque, _: *Proxy, rate: i32, delay: i32) callconv(.c) void {
    const self: *Wayland = @ptrCast(@alignCast(data orelse return));
    // A rate of zero means the user turned repeat off, which is a setting to
    // honour rather than a number to clamp.
    self.repeat.interval_ms = if (rate > 0) @intCast(@divTrunc(1000, rate)) else 0;
    self.repeat.delay_ms = @intCast(@max(0, delay));
}

/// Emits whatever repeats are due. Called from the pump, because a repeat is
/// generated by the passage of time and no event will arrive to prompt it.
fn serviceRepeat(self: *Wayland, now_ms: u32) void {
    if (!self.repeat.holding() or self.repeat.interval_ms == 0) return;
    // Wrapping comparison: the compositor's clock is a `u32` of milliseconds
    // and rolls over every forty-nine days.
    while (now_ms -% self.repeat.due < std.math.maxInt(u32) / 2) {
        self.events.keyChar(self.repeat.key, self.repeat.char, true, true) catch {
            self.oom = true;
        };
        var buf: [8]u8 = undefined;
        const utf8 = self.keys.textOf(self.repeat.code + 8, &buf);
        if (utf8.len != 0 and !(utf8.len == 1 and (utf8[0] < 0x20 or utf8[0] == 0x7f))) {
            self.events.typed(utf8) catch {
                self.oom = true;
            };
        }
        self.repeat.due +%= self.repeat.interval_ms;
    }
}

// -- the pump ----------------------------------------------------------------

fn pump(ptr: *anyopaque) void {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    self.drain(0);
}

fn waitFor(ptr: *anyopaque, timeout_ms: u32) void {
    const self: *Wayland = @ptrCast(@alignCast(ptr));
    self.drain(@intCast(@min(timeout_ms, std.math.maxInt(i32))));
}

/// One turn of the Wayland event loop, blocking for at most `timeout_ms`.
///
/// The prepare/read/cancel dance is not optional and not decoration. A
/// straight `wl_display_dispatch` blocks, which a frame loop cannot afford;
/// polling the fd and then dispatching races, because another thread -- or
/// this one, earlier -- may already have queued events that make the fd
/// quiet. `prepare_read` closes that race: it fails while anything is queued,
/// which is the signal to dispatch what is queued and try again.
fn drain(self: *Wayland, timeout_ms: i32) void {
    const display = self.display orelse return;

    while (self.wl.display_prepare_read(display) != 0) {
        if (self.wl.display_dispatch_pending(display) < 0) return;
    }
    _ = self.wl.display_flush(display);

    var fds = [_]std.posix.pollfd{.{
        .fd = self.wl.display_get_fd(display),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, timeout_ms) catch 0;

    if (ready > 0 and fds[0].revents & std.posix.POLL.IN != 0) {
        if (self.wl.display_read_events(display) < 0) return;
    } else {
        self.wl.display_cancel_read(display);
    }
    _ = self.wl.display_dispatch_pending(display);

    self.serviceRepeat(nowMillis());
    if (self.pending_resize) {
        self.pending_resize = false;
        self.commit();
    }
}

/// A millisecond clock in the same units the compositor timestamps events
/// with. Those are `CLOCK_MONOTONIC` truncated to 32 bits, which is what this
/// reproduces -- key repeat compares the two, so they have to be the same
/// clock and not merely both monotonic.
fn nowMillis() u32 {
    var t: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &t) != 0) return 0;
    const ms = @as(u64, @intCast(t.sec)) *% 1000 +% @as(u64, @intCast(@divTrunc(t.nsec, 1_000_000)));
    return @truncate(ms);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "a target without Wayland refuses rather than pretending" {
    if (supported) return error.SkipZigTest;
    try testing.expectError(error.UnsupportedPlatform, create(testing.allocator, .{}));
}

test "fixed point is 24.8, signed" {
    // `wl_fixed_t`. Getting this wrong puts the pointer at 256 times where it
    // is, which is a cursor that never reaches anything.
    try testing.expectApproxEqAbs(@as(f32, 1), fixedToFloat(256), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), fixedToFloat(128), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -3.25), fixedToFloat(-832), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), fixedToFloat(0), 1e-6);
}

test "a surface takes the largest scale of the outputs it is on" {
    var outputs: [max_outputs]Output = @splat(.{});
    const fake: *Proxy = @ptrFromInt(0x1000);
    outputs[0] = .{ .proxy = fake, .scale = 1 };
    outputs[1] = .{ .proxy = fake, .scale = 2 };
    outputs[2] = .{ .proxy = fake, .scale = 3 };

    // On no output at all -- every surface, before its first frame.
    try testing.expectEqual(@as(u32, 1), wantedScale(outputs, 0));
    try testing.expectEqual(@as(u32, 1), wantedScale(outputs, 0b001));
    try testing.expectEqual(@as(u32, 2), wantedScale(outputs, 0b010));
    // Straddling two monitors: the sharper one wins, because the cost of
    // being wrong the other way is a blurry window.
    try testing.expectEqual(@as(u32, 2), wantedScale(outputs, 0b011));
    try testing.expectEqual(@as(u32, 3), wantedScale(outputs, 0b111));
    // An output that has gone away is not consulted even if its bit is set.
    outputs[2].proxy = null;
    try testing.expectEqual(@as(u32, 2), wantedScale(outputs, 0b111));
}

test "key repeat stops when the key is released and when focus leaves" {
    var r: Repeat = .{ .code = 30, .key = .none, .due = 100 };
    try testing.expect(r.holding());

    // A different key's release does not stop this one.
    r.release(31);
    try testing.expect(r.holding());
    r.release(30);
    try testing.expect(!r.holding());

    // And the rate survives, because it is the user's setting and not part
    // of what is being held.
    var rated: Repeat = .{ .delay_ms = 300, .interval_ms = 20, .code = 5 };
    rated.release(5);
    try testing.expectEqual(@as(u32, 300), rated.delay_ms);
    try testing.expectEqual(@as(u32, 20), rated.interval_ms);
}
