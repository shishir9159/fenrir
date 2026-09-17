//! What the platform reports, in the shape the UI wants it.
//!
//! Written the way Gelgja was -- as the target the platform layer would be
//! implemented against, before there was one -- and now filled by
//! `lyngvi/Events.zig`, which turns a message loop's output into exactly this.
//! Its job was to be small enough that a Win32 message loop and an xcb event
//! loop could both fill it without either one leaking through; the Win32 half
//! is written and the xcb half is stubbed, and nothing here had to change for
//! the first one, which is the only evidence available that it will not have
//! to for the second.
//!
//! ## State and events, and why both
//!
//! The mouse is *state*: where it is now and which buttons are down now. The
//! UI derives presses and releases by comparing against last frame, which
//! means a platform layer that drops an event or coalesces two moves cannot
//! desynchronise the button state -- and every platform layer does coalesce
//! moves.
//!
//! The keyboard is *events*: which keys went down, in order, with autorepeat,
//! interleaved with the text they produced. None of that can be recovered from
//! a snapshot. Typing `a` then backspace then `a` leaves the same state as
//! typing nothing, and a text field has to see all three.
//!
//! The wheel is state again, but accumulated: a frame that saw three ticks
//! reports three ticks and then zero. Reporting each tick as an event would
//! make a UI scroll in steps at whatever rate the mouse driver chose.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");
const Point = geom.Point;

pub const MouseButton = enum(u2) {
    left,
    right,
    middle,

    pub fn index(b: MouseButton) usize {
        return @intFromEnum(b);
    }
};

pub const button_count = 3;

pub const Buttons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,

    pub const none: Buttons = .{};

    pub fn isDown(b: Buttons, which: MouseButton) bool {
        return switch (which) {
            .left => b.left,
            .right => b.right,
            .middle => b.middle,
        };
    }

    pub fn set(b: *Buttons, which: MouseButton, down: bool) void {
        switch (which) {
            .left => b.left = down,
            .right => b.right = down,
            .middle => b.middle = down,
        }
    }

    pub fn any(b: Buttons) bool {
        return b.left or b.right or b.middle;
    }
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Command on macOS, the Windows key elsewhere. Named for what it does
    /// rather than what it is printed with, since the two differ per platform
    /// and the UI only ever asks the question one way.
    super: bool = false,
    _reserved: u4 = 0,

    pub const none: Modifiers = .{};
};

/// Named keys, meaning physical function rather than the character produced.
///
/// Characters do not appear here at all: they arrive as `.text` events, in
/// UTF-8, after the platform's own composition. A key enum with letters in it
/// invites reading `.a` to mean the character `a`, which is wrong on every
/// non-US layout and wrong for every dead key and IME.
pub const KeyCode = enum(u8) {
    none,
    escape,
    enter,
    tab,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
    space,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    /// A key the platform layer recognised but this enum has no name for.
    /// Reported rather than dropped so that a trace of a session is complete.
    other,
};

pub const Event = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    /// Committed text, already composed. Borrowed from the frame's arena.
    text: []const u8,

    pub const KeyEvent = struct {
        code: KeyCode,
        modifiers: Modifiers = .{},
        /// True for the repeats a held key generates after the first.
        repeat: bool = false,
        /// The character this key is *labelled with* under the layout in
        /// force, with no modifier applied -- `w` for the key that types `w`,
        /// wherever the layout puts it. Zero when the key has no character.
        ///
        /// This exists for chords and for nothing else. `Ctrl` suppresses the
        /// text event on every platform, so `<C-w>` cannot be read from
        /// `.text`, and reading it from `KeyCode` would mean putting letters
        /// in that enum and promising a position on the keyboard. Asking the
        /// layout what this key is called keeps the promise the enum refuses
        /// to make: the answer is the letter printed on the key, whatever
        /// layout is loaded.
        char: u21 = 0,
    };
};

/// A key with modifiers held: `<C-w>`, written out.
///
/// `shift` is not part of it. A layout reports one character per key and the
/// shifted form is a different character, so a chord that cared about shift
/// would have to know that `<C-S-6>` is `<C-^>` on one layout and something
/// else on the next. Chords here are ctrl and alt, which is what the ones in
/// this reader use.
pub const Chord = struct {
    char: u21,
    ctrl: bool = false,
    alt: bool = false,

    pub fn ctrlKey(c: u21) Chord {
        return .{ .char = c, .ctrl = true };
    }
};

/// One frame's worth of input. Everything here is what the platform saw since
/// the last frame; the UI keeps its own history and needs none kept here.
pub const Input = struct {
    mouse: Point = .origin,
    buttons: Buttons = .{},
    modifiers: Modifiers = .{},
    /// Accumulated wheel movement in *pixels*, not notches. A platform layer
    /// that only has notches multiplies by whatever its convention is, since
    /// that number is a platform preference and not a UI one.
    scroll: Point = .origin,
    events: []const Event = &.{},

    /// Seconds since the previous frame, for animation. Clamped by the UI, so
    /// a platform layer may pass whatever its clock produced -- including the
    /// enormous value that follows a window being dragged or a breakpoint.
    dt: f32 = 1.0 / 60.0,

    pub fn typedText(in: Input, buf: []u8) []const u8 {
        var n: usize = 0;
        for (in.events) |e| switch (e) {
            .text => |t| {
                const take = @min(t.len, buf.len - n);
                @memcpy(buf[n..][0..take], t[0..take]);
                n += take;
                if (n == buf.len) return buf;
            },
            else => {},
        };
        return buf[0..n];
    }

    pub fn pressed(in: Input, code: KeyCode) bool {
        for (in.events) |e| switch (e) {
            .key_down => |k| if (k.code == code) return true,
            else => {},
        };
        return false;
    }

    /// Presses including autorepeat, which is what a cursor key wants and what
    /// a shortcut does not.
    pub fn repeated(in: Input, code: KeyCode) bool {
        return in.pressed(code);
    }

    /// The first press only. A shortcut that fires on repeat opens forty
    /// dialogs when someone leans on the key.
    pub fn pressedOnce(in: Input, code: KeyCode) bool {
        for (in.events) |e| switch (e) {
            .key_down => |k| if (k.code == code and !k.repeat) return true,
            else => {},
        };
        return false;
    }

    /// A modified key went down this frame: `<C-w>`, and the like.
    ///
    /// The first press only, for the same reason `pressedOnce` exists -- a
    /// chord that fires on autorepeat splits the window four times while a
    /// finger rests on the key.
    pub fn chorded(in: Input, c: Chord) bool {
        if (c.char == 0) return false;
        for (in.events) |e| switch (e) {
            .key_down => |k| {
                if (k.repeat or k.char == 0) continue;
                if (lowerAscii(k.char) != lowerAscii(c.char)) continue;
                if (k.modifiers.ctrl != c.ctrl or k.modifiers.alt != c.alt) continue;
                return true;
            },
            else => {},
        };
        return false;
    }

    /// An unmodified key went down this frame, by the character on it.
    ///
    /// Distinct from reading `.text`: this fires for a press whose text the
    /// platform withheld, and it does not fire for text that arrived from an
    /// IME or a paste. Use it where a key is a *command* -- `j` to go down a
    /// line -- and `typedText` where it is a character being entered.
    pub fn typedKey(in: Input, char: u21) bool {
        for (in.events) |e| switch (e) {
            .key_down => |k| {
                if (k.char == 0 or k.modifiers.ctrl or k.modifiers.alt) continue;
                if (lowerAscii(k.char) == lowerAscii(char)) return true;
            },
            else => {},
        };
        return false;
    }
};

/// Case folding for the ASCII half only, which is where every chord in this
/// program lives. A layout that reports an uppercase label for a key -- and
/// Windows does, `MapVirtualKey` returns `W` -- should still answer to `w`.
fn lowerAscii(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "buttons are addressable both ways round" {
    var b: Buttons = .{};
    try testing.expect(!b.any());
    b.set(.right, true);
    try testing.expect(b.isDown(.right));
    try testing.expect(!b.isDown(.left));
    try testing.expect(b.any());
    b.set(.right, false);
    try testing.expect(!b.any());
}

test "text arrives as bytes, in order, however many events it took" {
    const events = [_]Event{
        .{ .text = "he" },
        .{ .key_down = .{ .code = .none } },
        .{ .text = "llo" },
    };
    const in: Input = .{ .events = &events };

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", in.typedText(&buf));
}

test "a text run longer than the buffer is truncated rather than overrunning" {
    const events = [_]Event{.{ .text = "abcdefgh" }};
    const in: Input = .{ .events = &events };
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", in.typedText(&buf));
}

test "a repeat is a press but not a first press" {
    const events = [_]Event{
        .{ .key_down = .{ .code = .down } },
        .{ .key_down = .{ .code = .down, .repeat = true } },
        .{ .key_down = .{ .code = .enter, .repeat = true } },
    };
    const in: Input = .{ .events = &events };

    // A cursor key wants every repeat.
    try testing.expect(in.repeated(.down));
    try testing.expect(in.pressedOnce(.down));
    // A shortcut wants only the first, or holding the key opens forty of them.
    try testing.expect(in.repeated(.enter));
    try testing.expect(!in.pressedOnce(.enter));
    try testing.expect(!in.pressed(.escape));
}

test "an empty frame reports nothing rather than trapping" {
    const in: Input = .{};
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("", in.typedText(&buf));
    try testing.expect(!in.pressed(.tab));
}
