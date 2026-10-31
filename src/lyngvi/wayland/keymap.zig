//! Turning a Wayland key event into a key and a character.
//!
//! Wayland hands the client a raw evdev scancode and a *keymap*, as a file
//! descriptor holding an XKB description of the user's layout. Nothing about
//! what the key means is in the event. That is the correct design -- the
//! compositor should not be deciding that the key at `D` types a `d` -- and
//! it means every client has to do this work.
//!
//! Two halves, and they are separate on purpose:
//!
//! **The key code** -- escape, left, page down -- comes from the evdev
//! number directly. Those numbers are kernel ABI and identical on every
//! layout, keyboard and machine: `KEY_ESC` is 1 whether the keyboard is
//! Dvorak, AZERTY or Japanese. So `KeyCode` needs no library at all, which is
//! also why it is the half that never degrades.
//!
//! **The character** -- the `w` in `<C-w>`, and the text a key produces --
//! is the layout's business, and the layout is in the keymap. That needs
//! xkbcommon, which is loaded at run time if it is present.
//!
//! ## What happens without xkbcommon
//!
//! A US-QWERTY table, and the reader still works: every key it binds is an
//! ASCII letter or a digit, and on a US layout the table is right. On any
//! other layout the *named* keys are still right -- scrolling, paging, the
//! cursor -- and the letters are wrong, which is a real degradation and is
//! why it is a fallback rather than the implementation. libxkbcommon is
//! present on every desktop that has a Wayland compositor, because the
//! compositor itself links it.

const std = @import("std");
const builtin = @import("builtin");

const thviti = @import("../../thviti.zig");
const KeyCode = thviti.input.KeyCode;
const Modifiers = thviti.input.Modifiers;

// -- evdev to KeyCode ---------------------------------------------------------

/// Linux input codes, from `include/uapi/linux/input-event-codes.h`. Only the
/// ones `KeyCode` has a name for; everything else is `.other`, reported
/// rather than dropped so that a trace of a session is complete.
pub const evdev = struct {
    pub const esc: u32 = 1;
    pub const @"1": u32 = 2;
    pub const minus: u32 = 12;
    pub const equal: u32 = 13;
    pub const backspace: u32 = 14;
    pub const tab: u32 = 15;
    pub const q: u32 = 16;
    pub const enter: u32 = 28;
    pub const leftctrl: u32 = 29;
    pub const a: u32 = 30;
    pub const leftshift: u32 = 42;
    pub const backslash: u32 = 43;
    pub const z: u32 = 44;
    pub const rightshift: u32 = 54;
    pub const leftalt: u32 = 56;
    pub const space: u32 = 57;
    pub const capslock: u32 = 58;
    pub const f1: u32 = 59;
    pub const f10: u32 = 68;
    pub const numlock: u32 = 69;
    pub const scrolllock: u32 = 70;
    pub const f11: u32 = 87;
    pub const f12: u32 = 88;
    pub const rightctrl: u32 = 97;
    pub const rightalt: u32 = 100;
    pub const home: u32 = 102;
    pub const up: u32 = 103;
    pub const pageup: u32 = 104;
    pub const left: u32 = 105;
    pub const right: u32 = 106;
    pub const end: u32 = 107;
    pub const down: u32 = 108;
    pub const pagedown: u32 = 109;
    pub const insert: u32 = 110;
    pub const delete: u32 = 111;
    pub const leftmeta: u32 = 125;
    pub const rightmeta: u32 = 126;
};

/// The evdev code for a key, as a `KeyCode`. Layout-independent, and so the
/// half of this file that is always right.
pub fn codeOf(code: u32) KeyCode {
    return switch (code) {
        evdev.esc => .escape,
        evdev.enter => .enter,
        evdev.tab => .tab,
        evdev.backspace => .backspace,
        evdev.delete => .delete,
        evdev.left => .left,
        evdev.right => .right,
        evdev.up => .up,
        evdev.down => .down,
        evdev.home => .home,
        evdev.end => .end,
        evdev.pageup => .page_up,
        evdev.pagedown => .page_down,
        evdev.insert => .insert,
        evdev.space => .space,
        // F1..F10 are contiguous; F11 and F12 are not, because the keyboards
        // of 1984 had ten function keys and the codes were assigned then.
        evdev.f1...evdev.f10 => @enumFromInt(@intFromEnum(KeyCode.f1) + (code - evdev.f1)),
        evdev.f11 => .f11,
        evdev.f12 => .f12,
        else => .other,
    };
}

/// Whether a key should repeat while it is held.
///
/// Modifiers must not: a held shift that repeated would send a key-down every
/// thirty milliseconds for as long as someone was capitalising a word.
pub fn shouldRepeat(code: u32) bool {
    return switch (code) {
        evdev.leftctrl,
        evdev.rightctrl,
        evdev.leftshift,
        evdev.rightshift,
        evdev.leftalt,
        evdev.rightalt,
        evdev.leftmeta,
        evdev.rightmeta,
        evdev.capslock,
        evdev.numlock,
        evdev.scrolllock,
        => false,
        else => true,
    };
}

// -- the US fallback ----------------------------------------------------------

/// evdev code to the character a US-QWERTY keyboard prints on it, unshifted
/// and shifted. Used only when xkbcommon could not be loaded; see the header.
const us_layout = [_]struct { u32, u8, u8 }{
    .{ 2, '1', '!' },   .{ 3, '2', '@' },  .{ 4, '3', '#' },   .{ 5, '4', '$' },
    .{ 6, '5', '%' },   .{ 7, '6', '^' },  .{ 8, '7', '&' },   .{ 9, '8', '*' },
    .{ 10, '9', '(' },  .{ 11, '0', ')' }, .{ 12, '-', '_' },  .{ 13, '=', '+' },
    .{ 16, 'q', 'Q' },  .{ 17, 'w', 'W' }, .{ 18, 'e', 'E' },  .{ 19, 'r', 'R' },
    .{ 20, 't', 'T' },  .{ 21, 'y', 'Y' }, .{ 22, 'u', 'U' },  .{ 23, 'i', 'I' },
    .{ 24, 'o', 'O' },  .{ 25, 'p', 'P' }, .{ 26, '[', '{' },  .{ 27, ']', '}' },
    .{ 30, 'a', 'A' },  .{ 31, 's', 'S' }, .{ 32, 'd', 'D' },  .{ 33, 'f', 'F' },
    .{ 34, 'g', 'G' },  .{ 35, 'h', 'H' }, .{ 36, 'j', 'J' },  .{ 37, 'k', 'K' },
    .{ 38, 'l', 'L' },  .{ 39, ';', ':' }, .{ 40, '\'', '"' }, .{ 41, '`', '~' },
    .{ 43, '\\', '|' }, .{ 44, 'z', 'Z' }, .{ 45, 'x', 'X' },  .{ 46, 'c', 'C' },
    .{ 47, 'v', 'V' },  .{ 48, 'b', 'B' }, .{ 49, 'n', 'N' },  .{ 50, 'm', 'M' },
    .{ 51, ',', '<' },  .{ 52, '.', '>' }, .{ 53, '/', '?' },  .{ 57, ' ', ' ' },
};

fn usChar(code: u32, shifted: bool) u21 {
    for (us_layout) |entry| {
        if (entry[0] != code) continue;
        return if (shifted) entry[2] else entry[1];
    }
    return 0;
}

// -- xkbcommon, if it is there ------------------------------------------------

const Context = opaque {};
const Keymap = opaque {};
const KeyboardState = opaque {};

/// The handful of xkbcommon entry points a client needs. Loaded by name at
/// run time, like libwayland and the Vulkan loader; nothing here is a
/// link-time dependency.
const Xkb = struct {
    handle: ?*anyopaque = null,

    context_new: *const fn (u32) callconv(.c) ?*Context = undefined,
    context_unref: *const fn (?*Context) callconv(.c) void = undefined,
    keymap_new_from_string: *const fn (?*Context, [*:0]const u8, u32, u32) callconv(.c) ?*Keymap = undefined,
    keymap_unref: *const fn (?*Keymap) callconv(.c) void = undefined,
    keymap_key_repeats: *const fn (?*Keymap, u32) callconv(.c) c_int = undefined,
    state_new: *const fn (?*Keymap) callconv(.c) ?*KeyboardState = undefined,
    state_unref: *const fn (?*KeyboardState) callconv(.c) void = undefined,
    state_update_mask: *const fn (?*KeyboardState, u32, u32, u32, u32, u32, u32) callconv(.c) u32 = undefined,
    state_key_get_utf8: *const fn (?*KeyboardState, u32, [*]u8, usize) callconv(.c) c_int = undefined,
    state_key_get_utf32: *const fn (?*KeyboardState, u32, ) callconv(.c) u32 = undefined,
    state_mod_name_is_active: *const fn (?*KeyboardState, [*:0]const u8, u32) callconv(.c) c_int = undefined,

    const sonames = [_][:0]const u8{ "libxkbcommon.so.0", "libxkbcommon.so" };

    /// `xkb_` plus the field name: `state_key_get_utf8` is
    /// `xkb_state_key_get_utf8`, and so on for all of them.
    fn load() ?Xkb {
        var x: Xkb = .{};
        for (sonames) |name| {
            x.handle = std.c.dlopen(name.ptr, .{ .LAZY = true });
            if (x.handle != null) break;
        }
        if (x.handle == null) return null;

        inline for (@typeInfo(Xkb).@"struct".field_names) |field| {
            if (comptime std.mem.eql(u8, field, "handle")) continue;
            const symbol = "xkb_" ++ field;
            const found = std.c.dlsym(x.handle, symbol) orelse {
                _ = std.c.dlclose(x.handle.?);
                return null;
            };
            @field(x, field) = @ptrCast(@alignCast(found));
        }
        return x;
    }
};

const keymap_format_text_v1: u32 = 1;
const compile_no_flags: u32 = 0;
const state_mods_effective: u32 = 1 << 3;

/// Everything about the keyboard's current interpretation: the layout, the
/// modifiers held, and the two questions the backend asks of them.
pub const State = struct {
    xkb: ?Xkb = null,
    context: ?*Context = null,
    keymap: ?*Keymap = null,
    state: ?*KeyboardState = null,

    /// Kept even when xkbcommon is present, because `Modifiers` is a flat
    /// four bits and asking xkb for each of them on every event would be four
    /// string comparisons per keystroke.
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,

    /// The bit positions in the mask a compositor sends are the keymap's own
    /// modifier indices, which for every keymap in practice are these. Only
    /// consulted in the fallback, where there is no keymap to ask.
    const mod_shift: u32 = 1 << 0;
    const mod_caps: u32 = 1 << 1;
    const mod_ctrl: u32 = 1 << 2;
    const mod_alt: u32 = 1 << 3;
    const mod_logo: u32 = 1 << 6;

    pub fn deinit(s: *State) void {
        const xkb = s.xkb orelse return;
        if (s.state) |v| xkb.state_unref(v);
        if (s.keymap) |k| xkb.keymap_unref(k);
        if (s.context) |c| xkb.context_unref(c);
        if (xkb.handle) |h| _ = std.c.dlclose(h);
        s.* = .{};
    }

    /// Takes the keymap the compositor sent over a file descriptor.
    ///
    /// The descriptor is ours to close whatever happens -- including when the
    /// format is one we do not understand, which is the path that leaks it in
    /// every client that gets this wrong.
    pub fn load(s: *State, format: u32, fd: i32, count: u32) void {
        defer _ = std.c.close(fd);
        if (format != 1) return; // Only `xkb_v1` exists.
        if (count == 0) return;

        if (s.xkb == null) s.xkb = Xkb.load();
        const xkb = s.xkb orelse return;

        if (s.context == null) s.context = xkb.context_new(0);
        const context = s.context orelse return;

        // Mapped rather than read: the compositor sends this as shared
        // memory, and it is NUL-terminated inside the mapping.
        const mapped = std.posix.mmap(
            null,
            count,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch return;
        defer std.posix.munmap(mapped);

        const text: [*:0]const u8 = @ptrCast(mapped.ptr);
        const fresh = xkb.keymap_new_from_string(context, text, keymap_format_text_v1, compile_no_flags) orelse return;

        // Swapped in only once the new one exists, so a keymap that fails to
        // compile leaves the working one in place rather than no keyboard.
        if (s.state) |old| xkb.state_unref(old);
        if (s.keymap) |old| xkb.keymap_unref(old);
        s.keymap = fresh;
        s.state = xkb.state_new(fresh);
    }

    pub fn setModifiers(s: *State, depressed: u32, latched: u32, locked: u32, group: u32) void {
        s.depressed = depressed;
        s.latched = latched;
        s.locked = locked;
        if (s.xkb) |xkb| {
            if (s.state) |v| _ = xkb.state_update_mask(v, depressed, latched, locked, 0, 0, group);
        }
    }

    pub fn modifiers(s: *const State) Modifiers {
        const held = s.depressed | s.latched | s.locked;
        return .{
            .shift = held & mod_shift != 0,
            .ctrl = held & mod_ctrl != 0,
            .alt = held & mod_alt != 0,
            .super = held & mod_logo != 0,
        };
    }

    fn shifted(s: *const State) bool {
        const held = s.depressed | s.latched;
        return held & mod_shift != 0;
    }

    /// The text this key produces, after the layout, the modifiers, and any
    /// dead key or compose sequence.
    pub fn textOf(s: *const State, scancode: u32, buf: []u8) []const u8 {
        if (s.xkb) |xkb| {
            if (s.state) |v| {
                const n = xkb.state_key_get_utf8(v, scancode, buf.ptr, buf.len);
                if (n <= 0) return &.{};
                return buf[0..@min(@as(usize, @intCast(n)), buf.len)];
            }
        }
        // The fallback. Ctrl+key produces no text on any platform, which is
        // what `Chord` exists to work around, so it produces none here.
        const m = s.modifiers();
        if (m.ctrl or m.alt) return &.{};
        const c = usChar(scancode -| 8, s.shifted());
        if (c == 0) return &.{};
        buf[0] = @intCast(c);
        return buf[0..1];
    }

    /// The character printed on this key, with no modifier applied: the `w`
    /// of `<C-w>`. See `thviti/input.zig` for why a chord needs this and
    /// cannot use `KeyCode`.
    pub fn label(s: *const State, scancode: u32) u21 {
        if (s.xkb) |xkb| {
            if (s.state) |v| {
                // Not `state_key_get_utf32` on the live state: that applies
                // the modifiers, and with ctrl held it answers with a control
                // character or nothing. The label is the key's name, so the
                // fallback table -- which is about the key and not about what
                // is held with it -- is consulted for a modified press.
                const m = s.modifiers();
                if (!m.ctrl and !m.alt) {
                    const c = xkb.state_key_get_utf32(v, scancode);
                    if (c >= 0x20 and c != 0x7f) return @intCast(c);
                }
            }
        }
        return usChar(scancode -| 8, false);
    }

    /// Whether this key repeats, as the keymap says. Falls back to the rule
    /// that everything but a modifier does.
    pub fn repeats(s: *const State, scancode: u32) bool {
        if (s.xkb) |xkb| {
            if (s.keymap) |k| return xkb.keymap_key_repeats(k, scancode) != 0;
        }
        return shouldRepeat(scancode -| 8);
    }
};

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "evdev codes map to keys without consulting any layout" {
    // The point of this half: these answers are the same on every keyboard
    // and every layout, so they are the ones that never degrade.
    try testing.expectEqual(KeyCode.escape, codeOf(evdev.esc));
    try testing.expectEqual(KeyCode.left, codeOf(evdev.left));
    try testing.expectEqual(KeyCode.right, codeOf(evdev.right));
    try testing.expectEqual(KeyCode.up, codeOf(evdev.up));
    try testing.expectEqual(KeyCode.down, codeOf(evdev.down));
    try testing.expectEqual(KeyCode.page_up, codeOf(evdev.pageup));
    try testing.expectEqual(KeyCode.page_down, codeOf(evdev.pagedown));
    try testing.expectEqual(KeyCode.home, codeOf(evdev.home));
    try testing.expectEqual(KeyCode.end, codeOf(evdev.end));
    try testing.expectEqual(KeyCode.space, codeOf(evdev.space));
    try testing.expectEqual(KeyCode.enter, codeOf(evdev.enter));

    // A letter is not a named key: it arrives as text and as a chord label.
    try testing.expectEqual(KeyCode.other, codeOf(evdev.q));
    try testing.expectEqual(KeyCode.other, codeOf(evdev.a));
}

test "the function keys survive the gap between F10 and F11" {
    // F1..F10 are contiguous and F11..F12 are not, which a single range
    // would get wrong by two.
    try testing.expectEqual(KeyCode.f1, codeOf(evdev.f1));
    try testing.expectEqual(KeyCode.f5, codeOf(evdev.f1 + 4));
    try testing.expectEqual(KeyCode.f10, codeOf(evdev.f10));
    try testing.expectEqual(KeyCode.f11, codeOf(evdev.f11));
    try testing.expectEqual(KeyCode.f12, codeOf(evdev.f12));
}

test "modifiers do not repeat and everything else does" {
    try testing.expect(!shouldRepeat(evdev.leftshift));
    try testing.expect(!shouldRepeat(evdev.leftctrl));
    try testing.expect(!shouldRepeat(evdev.rightalt));
    try testing.expect(!shouldRepeat(evdev.capslock));
    try testing.expect(shouldRepeat(evdev.down));
    try testing.expect(shouldRepeat(evdev.a));
}

test "without xkbcommon the reader's own keys still work" {
    // The fallback's job, stated as a test: every binding `read.zig` has is
    // reachable on a US layout with no library loaded.
    var s: State = .{};
    var buf: [8]u8 = undefined;

    // A scancode is the evdev code plus eight.
    try testing.expectEqualStrings("q", s.textOf(evdev.q + 8, &buf));
    try testing.expectEqualStrings("j", s.textOf(evdev.a + 6 + 8, &buf)); // j is 36
    try testing.expectEqualStrings("-", s.textOf(evdev.minus + 8, &buf));
    try testing.expectEqualStrings("=", s.textOf(evdev.equal + 8, &buf));

    // Shifted, for `$` and `^`.
    s.depressed = State.mod_shift;
    try testing.expectEqualStrings("$", s.textOf(5 + 8, &buf));
    try testing.expectEqualStrings("^", s.textOf(7 + 8, &buf));
}

test "ctrl suppresses text but not the label, which is what makes a chord work" {
    var s: State = .{};
    var buf: [8]u8 = undefined;

    s.depressed = State.mod_ctrl;
    // No text: this is true on every platform and is the reason `char`
    // exists on a key event at all.
    try testing.expectEqualStrings("", s.textOf(17 + 8, &buf));
    // But the key is still the one labelled `w`, so `<C-w>` is reachable.
    try testing.expectEqual(@as(u21, 'w'), s.label(17 + 8));
    try testing.expect(s.modifiers().ctrl);
}

test "the modifier mask becomes the four bits the UI asks about" {
    var s: State = .{};
    try testing.expectEqual(Modifiers{}, s.modifiers());

    s.setModifiers(State.mod_shift | State.mod_ctrl, 0, 0, 0);
    const m = s.modifiers();
    try testing.expect(m.shift and m.ctrl);
    try testing.expect(!m.alt and !m.super);

    // A locked modifier -- caps lock, or a sticky key -- counts as held.
    s.setModifiers(0, 0, State.mod_alt, 0);
    try testing.expect(s.modifiers().alt);
}
