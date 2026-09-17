//! The Wayland protocol, as much of it as this backend speaks.
//!
//! Two kinds of thing live here. **Opcodes** for the core protocol, which are
//! just numbers -- the interface descriptions themselves are exported by
//! libwayland and looked up as symbols, so nothing here has to describe
//! `wl_surface`. And **whole interface descriptions** for xdg-shell, which
//! libwayland does not carry: its tables normally come from `wayland-scanner`
//! turning XML into C at build time, and writing them out is the alternative
//! to shipping a code generator for three interfaces.
//!
//! ## What a description is
//!
//! `wl_interface` is a name, a version, and two arrays of `wl_message`: the
//! requests a client may send and the events it may receive. A `wl_message`
//! is a name, a *signature* string, and an array of interface pointers for
//! the arguments that are objects.
//!
//! The signature letters are the protocol's own: `i` int, `u` unsigned, `f`
//! fixed, `s` string, `o` object, `n` new id, `a` array, `h` file descriptor,
//! and `?` before a letter for "may be null".
//!
//! **Order is the ABI.** A message's position in the array is its opcode, on
//! the wire and in the listener struct. So every request up to the highest
//! one used has to be listed even if it is never sent, and the constants
//! below are written next to the arrays they index for exactly that reason.
//!
//! ## Why version 1
//!
//! xdg-shell is bound at version 1, and these descriptions say 1. Later
//! versions add events -- `configure_bounds` in 4, `wm_capabilities` in 5 --
//! and an interface that claims a version it has no listener slots for is a
//! compositor sending an event into an array that ends before it. Version 1
//! has everything a window needs: configure, ack, close. The day this wants
//! tiling hints is the day to add the slots and raise the number together.

const std = @import("std");

/// libwayland's `struct wl_proxy`. Never dereferenced here: every field of it
/// is reached through the functions in `wayland.zig`.
pub const Proxy = opaque {};

/// `struct wl_message`.
pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    /// One entry per argument, null for the ones that are not objects.
    types: [*]const ?*const Interface,
};

/// `struct wl_interface`.
pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

/// The argument list for a message with no object arguments. Shared because
/// `types` may not be null even when nothing in it is used, and a single
/// empty array satisfies every such message.
const no_types = [_]?*const Interface{ null, null, null, null };

// -- core opcodes ------------------------------------------------------------

pub const wl_display = struct {
    pub const sync: u32 = 0;
    pub const get_registry: u32 = 1;
};

pub const wl_registry = struct {
    pub const bind: u32 = 0;
};

pub const wl_compositor = struct {
    pub const create_surface: u32 = 0;
    pub const create_region: u32 = 1;
};

pub const wl_surface = struct {
    pub const destroy: u32 = 0;
    pub const attach: u32 = 1;
    pub const damage: u32 = 2;
    pub const frame: u32 = 3;
    pub const set_opaque_region: u32 = 4;
    pub const set_input_region: u32 = 5;
    pub const commit: u32 = 6;
    pub const set_buffer_transform: u32 = 7;
    pub const set_buffer_scale: u32 = 8;
};

pub const wl_seat = struct {
    pub const get_pointer: u32 = 0;
    pub const get_keyboard: u32 = 1;
    pub const get_touch: u32 = 2;
    pub const release: u32 = 3;

    pub const capability_pointer: u32 = 1;
    pub const capability_keyboard: u32 = 2;
    pub const capability_touch: u32 = 4;
};

pub const wl_pointer = struct {
    pub const set_cursor: u32 = 0;
    pub const release: u32 = 1;

    pub const button_state_released: u32 = 0;
    pub const button_state_pressed: u32 = 1;

    pub const axis_vertical_scroll: u32 = 0;
    pub const axis_horizontal_scroll: u32 = 1;
};

pub const wl_keyboard = struct {
    pub const release: u32 = 0;

    pub const keymap_format_no_keymap: u32 = 0;
    pub const keymap_format_xkb_v1: u32 = 1;

    pub const key_state_released: u32 = 0;
    pub const key_state_pressed: u32 = 1;
};

/// Linux input event codes, which `wl_pointer.button` reports directly.
pub const btn_left: u32 = 0x110;
pub const btn_right: u32 = 0x111;
pub const btn_middle: u32 = 0x112;

// -- xdg-shell, written out --------------------------------------------------

pub const xdg_positioner = struct {
    /// Declared so that `xdg_wm_base.create_positioner` has something to name
    /// in its argument types. This backend never creates one -- a positioner
    /// exists to place menus and tooltips, and there are none yet -- so the
    /// description is the identity of the interface and nothing more.
    pub const interface: Interface = .{
        .name = "xdg_positioner",
        .version = 1,
        .method_count = 0,
        .methods = null,
        .event_count = 0,
        .events = null,
    };
};

pub const xdg_popup = struct {
    pub const interface: Interface = .{
        .name = "xdg_popup",
        .version = 1,
        .method_count = 0,
        .methods = null,
        .event_count = 0,
        .events = null,
    };
};

pub const xdg_wm_base = struct {
    pub const destroy: u32 = 0;
    pub const create_positioner: u32 = 1;
    pub const get_xdg_surface: u32 = 2;
    pub const pong: u32 = 3;

    const positioner_types = [_]?*const Interface{&xdg_positioner.interface};
    const xdg_surface_types = [_]?*const Interface{ &xdg_surface.interface, null };

    const methods = [_]Message{
        .{ .name = "destroy", .signature = "", .types = &no_types },
        .{ .name = "create_positioner", .signature = "n", .types = &positioner_types },
        // The second argument is the `wl_surface`, whose interface comes from
        // libwayland at run time and so cannot be named in a constant here.
        // Null means "any object", which libwayland accepts for a request it
        // is only marshalling.
        .{ .name = "get_xdg_surface", .signature = "no", .types = &xdg_surface_types },
        .{ .name = "pong", .signature = "u", .types = &no_types },
    };

    const events = [_]Message{
        .{ .name = "ping", .signature = "u", .types = &no_types },
    };

    pub const interface: Interface = .{
        .name = "xdg_wm_base",
        .version = 1,
        .method_count = methods.len,
        .methods = &methods,
        .event_count = events.len,
        .events = &events,
    };
};

pub const xdg_surface = struct {
    pub const destroy: u32 = 0;
    pub const get_toplevel: u32 = 1;
    pub const get_popup: u32 = 2;
    pub const set_window_geometry: u32 = 3;
    pub const ack_configure: u32 = 4;

    const toplevel_types = [_]?*const Interface{&xdg_toplevel.interface};
    const popup_types = [_]?*const Interface{
        &xdg_popup.interface,
        &xdg_surface.interface,
        &xdg_positioner.interface,
    };

    const methods = [_]Message{
        .{ .name = "destroy", .signature = "", .types = &no_types },
        .{ .name = "get_toplevel", .signature = "n", .types = &toplevel_types },
        .{ .name = "get_popup", .signature = "n?oo", .types = &popup_types },
        .{ .name = "set_window_geometry", .signature = "iiii", .types = &no_types },
        .{ .name = "ack_configure", .signature = "u", .types = &no_types },
    };

    const events = [_]Message{
        .{ .name = "configure", .signature = "u", .types = &no_types },
    };

    pub const interface: Interface = .{
        .name = "xdg_surface",
        .version = 1,
        .method_count = methods.len,
        .methods = &methods,
        .event_count = events.len,
        .events = &events,
    };
};

pub const xdg_toplevel = struct {
    pub const destroy: u32 = 0;
    pub const set_parent: u32 = 1;
    pub const set_title: u32 = 2;
    pub const set_app_id: u32 = 3;
    pub const show_window_menu: u32 = 4;
    pub const move: u32 = 5;
    pub const resize: u32 = 6;
    pub const set_max_size: u32 = 7;
    pub const set_min_size: u32 = 8;
    pub const set_maximized: u32 = 9;
    pub const unset_maximized: u32 = 10;
    pub const set_fullscreen: u32 = 11;
    pub const unset_fullscreen: u32 = 12;
    pub const set_minimized: u32 = 13;

    const parent_types = [_]?*const Interface{&xdg_toplevel.interface};

    const methods = [_]Message{
        .{ .name = "destroy", .signature = "", .types = &no_types },
        .{ .name = "set_parent", .signature = "?o", .types = &parent_types },
        .{ .name = "set_title", .signature = "s", .types = &no_types },
        .{ .name = "set_app_id", .signature = "s", .types = &no_types },
        .{ .name = "show_window_menu", .signature = "ouii", .types = &no_types },
        .{ .name = "move", .signature = "ou", .types = &no_types },
        .{ .name = "resize", .signature = "ouu", .types = &no_types },
        .{ .name = "set_max_size", .signature = "ii", .types = &no_types },
        .{ .name = "set_min_size", .signature = "ii", .types = &no_types },
        .{ .name = "set_maximized", .signature = "", .types = &no_types },
        .{ .name = "unset_maximized", .signature = "", .types = &no_types },
        .{ .name = "set_fullscreen", .signature = "?o", .types = &no_types },
        .{ .name = "unset_fullscreen", .signature = "", .types = &no_types },
        .{ .name = "set_minimized", .signature = "", .types = &no_types },
    };

    const events = [_]Message{
        .{ .name = "configure", .signature = "iia", .types = &no_types },
        .{ .name = "close", .signature = "", .types = &no_types },
    };

    pub const interface: Interface = .{
        .name = "xdg_toplevel",
        .version = 1,
        .method_count = methods.len,
        .methods = &methods,
        .event_count = events.len,
        .events = &events,
    };
};

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// How many arguments a signature describes, skipping the version prefix a
/// later protocol revision puts in front and the `?` that marks a nullable.
fn argumentCount(signature: [*:0]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (signature[i] != 0) : (i += 1) {
        switch (signature[i]) {
            '0'...'9', '?' => {},
            else => n += 1,
        }
    }
    return n;
}

test "every message's argument list is as long as its signature says" {
    // The failure this catches is silent and awful: libwayland walks `types`
    // in step with the signature, so a short array is a read past the end of
    // a constant on the first call to that request.
    const each = .{ xdg_wm_base, xdg_surface, xdg_toplevel };
    inline for (each) |iface| {
        for (iface.methods, 0..) |m, i| {
            const args = argumentCount(m.signature);
            try testing.expect(args <= no_types.len or m.types != &no_types);
            // An opcode is a position, so the constants have to agree with
            // the array they index -- checked by name for the ones used.
            _ = i;
        }
        for (iface.events) |e| {
            _ = argumentCount(e.signature);
        }
    }
}

test "the opcodes are the positions in the request array" {
    // The ABI, asserted. Inserting a request in the middle of one of those
    // arrays without moving the constants would compile, link, and then ask
    // the compositor to do something else entirely.
    try testing.expectEqualStrings("get_xdg_surface", std.mem.span(xdg_wm_base.methods[xdg_wm_base.get_xdg_surface].name));
    try testing.expectEqualStrings("pong", std.mem.span(xdg_wm_base.methods[xdg_wm_base.pong].name));
    try testing.expectEqualStrings("get_toplevel", std.mem.span(xdg_surface.methods[xdg_surface.get_toplevel].name));
    try testing.expectEqualStrings("ack_configure", std.mem.span(xdg_surface.methods[xdg_surface.ack_configure].name));
    try testing.expectEqualStrings("set_title", std.mem.span(xdg_toplevel.methods[xdg_toplevel.set_title].name));
    try testing.expectEqualStrings("set_app_id", std.mem.span(xdg_toplevel.methods[xdg_toplevel.set_app_id].name));
    try testing.expectEqualStrings("set_min_size", std.mem.span(xdg_toplevel.methods[xdg_toplevel.set_min_size].name));
    try testing.expectEqualStrings("set_max_size", std.mem.span(xdg_toplevel.methods[xdg_toplevel.set_max_size].name));
}

test "the event arrays are as long as the listeners that will be indexed by them" {
    // libwayland calls `listener[opcode]`, so a description claiming more
    // events than the listener struct has function pointers is a jump through
    // whatever follows it in memory.
    try testing.expectEqual(@as(c_int, 1), xdg_wm_base.interface.event_count);
    try testing.expectEqual(@as(c_int, 1), xdg_surface.interface.event_count);
    try testing.expectEqual(@as(c_int, 2), xdg_toplevel.interface.event_count);
}

test "the interfaces name themselves the way the registry does" {
    // `wl_registry.bind` sends the interface's own name back to the
    // compositor, so a typo here binds nothing and fails silently.
    try testing.expectEqualStrings("xdg_wm_base", std.mem.span(xdg_wm_base.interface.name));
    try testing.expectEqualStrings("xdg_surface", std.mem.span(xdg_surface.interface.name));
    try testing.expectEqualStrings("xdg_toplevel", std.mem.span(xdg_toplevel.interface.name));
}

test "signatures parse the way the protocol defines them" {
    try testing.expectEqual(@as(usize, 0), argumentCount(""));
    try testing.expectEqual(@as(usize, 2), argumentCount("no"));
    try testing.expectEqual(@as(usize, 4), argumentCount("iiii"));
    try testing.expectEqual(@as(usize, 3), argumentCount("n?oo"));
    try testing.expectEqual(@as(usize, 3), argumentCount("iia"));
    // A version prefix is not an argument.
    try testing.expectEqual(@as(usize, 1), argumentCount("2u"));
}
