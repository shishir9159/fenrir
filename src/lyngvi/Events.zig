//! The queue between a platform's message loop and one frame of `thviti.Input`.
//!
//! A window procedure is called by the operating system, at times the program
//! does not choose, possibly several times for one movement of a hand. A frame
//! wants one coherent picture. This is the thing in between: the backend pushes
//! whatever it was told, and `take` turns the accumulation into the exact
//! structure `thviti/input.zig` describes.
//!
//! Which half of the input is state and which is a list is decided there, and
//! this file is the other end of that decision:
//!
//! * `mouse`, `buttons` and `modifiers` are overwritten. Twenty motion events
//!   between two frames leave one position, which is what the UI wants and what
//!   makes a coalescing platform layer harmless.
//! * `scroll` accumulates and is zeroed each frame. Three notches in one frame
//!   scroll three notches once, rather than one notch three frames running.
//! * Key and text events are a list, in order, because a text field has to see
//!   `a`, backspace, `a` and not the state that sequence leaves behind.
//!
//! ## Why the text is not stored in the events
//!
//! A `.text` event borrows its bytes. If those bytes lived in a growing list
//! of events, appending the next event could move them, and the slice in the
//! previous event would point at freed memory -- a bug that appears only when
//! someone types quickly enough to overflow the initial capacity, which is to
//! say in front of a user and never in a test. So the bytes go in one buffer
//! and the events hold offsets into it.
//!
//! There are two of those buffers, and the swap between them in `take` is the
//! second half of the same problem: the slices handed to the UI have to stay
//! valid for the whole frame, and a frame is allowed to pump the platform
//! queue in the middle of itself -- a window being dragged does exactly that,
//! because Windows runs its own modal loop and calls the window procedure from
//! inside it. Appending into the buffer those slices point at would move it.
//! So the accumulating buffer becomes the held one, the held one is cleared
//! and becomes the accumulator, and new input during the frame lands somewhere
//! the frame is not reading.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const thviti = @import("../thviti.zig");

const Point = geom.Point;

const Events = @This();

pub const Error = Allocator.Error;

pub const Input = thviti.Input;
pub const Event = thviti.Event;
pub const KeyCode = thviti.input.KeyCode;
pub const Modifiers = thviti.input.Modifiers;
pub const MouseButton = thviti.input.MouseButton;

/// One queued event, with text held by reference into `text` so that appending
/// cannot move it. See the header.
const Pending = union(enum) {
    key_down: Event.KeyEvent,
    key_up: Event.KeyEvent,
    text: struct { offset: u32, len: u32 },
};

gpa: Allocator,

// -- state, overwritten as it arrives ---------------------------------------

mouse: Point = .origin,
buttons: thviti.input.Buttons = .{},
modifiers: Modifiers = .{},
/// Accumulated pixels since the last frame; see `wheel`.
scroll: Point = .origin,

// -- the window's own state -------------------------------------------------

width: u32 = 0,
height: u32 = 0,
/// Device pixels per logical pixel: 1.0 at 96dpi, 1.5 at 150%, 2.0 on a
/// typical laptop display sold since about 2016.
scale: f32 = 1,
focused: bool = true,
/// Set when the user asked the window to close and never cleared here. The
/// application decides whether that request is honoured, which is the whole
/// reason it is a flag rather than an immediate exit.
close_requested: bool = false,
/// Set by a resize and cleared by `take`, so a frame can tell whether its
/// swapchain is still the right size without comparing dimensions itself.
resized: bool = false,

// -- the queue --------------------------------------------------------------

pending: std.ArrayList(Pending) = .empty,
/// Where text accumulates between frames.
text: std.ArrayList(u8) = .empty,
/// What the slices in `out` point into: last frame's `text`, swapped in and
/// left untouched until the frame after. See the header.
held: std.ArrayList(u8) = .empty,
out: std.ArrayList(Event) = .empty,

/// Events that arrived when the queue was already full; see `max_pending`.
dropped: u32 = 0,

/// Bounded rather than grown without limit: a window that is not being drawn
/// -- minimised, or behind a modal file dialog -- still receives input, and a
/// queue with no ceiling is a slow leak. Events past the limit are dropped,
/// since a program that has not drawn for four thousand keystrokes has bigger
/// problems than the last of them.
pub const max_pending = 4096;
pub const max_text_bytes = 64 * 1024;

pub fn init(gpa: Allocator) Events {
    return .{ .gpa = gpa };
}

pub fn deinit(e: *Events) void {
    e.pending.deinit(e.gpa);
    e.text.deinit(e.gpa);
    e.held.deinit(e.gpa);
    e.out.deinit(e.gpa);
    e.* = undefined;
}

// -- what a backend pushes --------------------------------------------------

pub fn moved(e: *Events, x: f32, y: f32) void {
    e.mouse = .{ .x = x, .y = y };
}

pub fn button(e: *Events, which: MouseButton, down: bool) void {
    e.buttons.set(which, down);
}

/// Wheel movement in *pixels*. A platform with notches multiplies by its own
/// convention before calling this; `input.zig` is explicit that the number of
/// pixels a notch is worth is a platform preference and not a UI one.
pub fn wheel(e: *Events, dx: f32, dy: f32) void {
    e.scroll.x += dx;
    e.scroll.y += dy;
}

pub fn setModifiers(e: *Events, m: Modifiers) void {
    e.modifiers = m;
}

pub fn key(e: *Events, code: KeyCode, down: bool, repeat: bool) Error!void {
    const ev: Event.KeyEvent = .{ .code = code, .modifiers = e.modifiers, .repeat = repeat };
    try e.push(if (down) .{ .key_down = ev } else .{ .key_up = ev });
}

/// Committed text, already composed by the platform's input method. UTF-8;
/// a backend working in UTF-16 pairs its surrogates before calling this.
pub fn typed(e: *Events, utf8: []const u8) Error!void {
    if (utf8.len == 0) return;
    if (e.text.items.len + utf8.len > max_text_bytes) {
        e.dropped += 1;
        return;
    }
    const offset: u32 = @intCast(e.text.items.len);
    try e.text.appendSlice(e.gpa, utf8);
    try e.push(.{ .text = .{ .offset = offset, .len = @intCast(utf8.len) } });
}

pub fn resize(e: *Events, w: u32, h: u32) void {
    if (w == e.width and h == e.height) return;
    e.width = w;
    e.height = h;
    e.resized = true;
}

pub fn setScale(e: *Events, s: f32) void {
    e.scale = if (s > 0) s else 1;
}

pub fn setFocus(e: *Events, on: bool) void {
    e.focused = on;
    // Losing focus while a button is held would otherwise leave that button
    // down forever: the release goes to whatever window took the focus, and
    // this one never hears about it. The UI would show a control stuck in its
    // pressed state until the user pressed and released it again.
    if (!on) e.buttons = .{};
}

pub fn requestClose(e: *Events) void {
    e.close_requested = true;
}

fn push(e: *Events, p: Pending) Error!void {
    if (e.pending.items.len >= max_pending) {
        e.dropped += 1;
        return;
    }
    try e.pending.append(e.gpa, p);
}

// -- what the frame takes ---------------------------------------------------

/// One frame's input, and a reset.
///
/// The returned `events` slice and the text inside it stay valid until the
/// next call to `take`, which is exactly one frame -- the same lifetime
/// `input.zig` documents for them.
pub fn take(e: *Events, dt: f32) Error!Input {
    e.out.clearRetainingCapacity();
    try e.out.ensureTotalCapacity(e.gpa, e.pending.items.len);

    // The swap, not a clear: the slices below point into `held`, and the
    // buffer they used to point into is what fresh input will now be appended
    // to. Clearing the one being read from -- which is what the obvious
    // version of this function does -- hands the UI a slice of freed bytes,
    // and in a safe build every one of them is 0xaa.
    std.mem.swap(std.ArrayList(u8), &e.text, &e.held);
    e.text.clearRetainingCapacity();

    for (e.pending.items) |p| {
        e.out.appendAssumeCapacity(switch (p) {
            .key_down => |k| .{ .key_down = k },
            .key_up => |k| .{ .key_up = k },
            .text => |t| .{ .text = e.held.items[t.offset..][0..t.len] },
        });
    }

    const in: Input = .{
        .mouse = e.mouse,
        .buttons = e.buttons,
        .modifiers = e.modifiers,
        .scroll = e.scroll,
        .events = e.out.items,
        .dt = dt,
    };

    // Only the per-frame parts are cleared. Position, buttons and modifiers
    // are state and survive; a frame in which nothing happened must report the
    // same pointer position as the last one, not the origin.
    e.pending.clearRetainingCapacity();
    e.scroll = .origin;
    e.resized = false;
    return in;
}

pub fn size(e: *const Events) struct { width: u32, height: u32 } {
    return .{ .width = e.width, .height = e.height };
}

pub fn isMinimised(e: *const Events) bool {
    return e.width == 0 or e.height == 0;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the mouse is state and the keyboard is a list" {
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    // Twenty moves between two frames leave one position.
    var i: f32 = 0;
    while (i < 20) : (i += 1) e.moved(i, i * 2);
    e.button(.left, true);
    try e.key(.enter, true, false);
    try e.key(.enter, false, false);

    const in = try e.take(1.0 / 60.0);
    try testing.expectEqual(Point{ .x = 19, .y = 38 }, in.mouse);
    try testing.expect(in.buttons.left);
    try testing.expectEqual(@as(usize, 2), in.events.len);
    try testing.expect(in.pressed(.enter));

    // The next frame keeps the position and the held button, and has no
    // events left over.
    const next = try e.take(1.0 / 60.0);
    try testing.expectEqual(Point{ .x = 19, .y = 38 }, next.mouse);
    try testing.expect(next.buttons.left);
    try testing.expectEqual(@as(usize, 0), next.events.len);
}

test "text survives the list growing under it" {
    // The bug this arrangement exists to prevent: if the bytes lived in the
    // events, appending past the initial capacity would move them and every
    // earlier slice would dangle. Typing enough to reallocate several times is
    // the only way to see it, so the test types enough.
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);

    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d},", .{i % 10});
        try e.typed(s);
        try expected.appendSlice(testing.allocator, s);
    }

    const in = try e.take(0.016);
    try testing.expectEqual(@as(usize, 500), in.events.len);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (in.events) |ev| try joined.appendSlice(testing.allocator, ev.text);
    try testing.expectEqualStrings(expected.items, joined.items);
}

test "input arriving mid-frame does not move the text the frame is reading" {
    // Not hypothetical: Windows runs its own modal message loop while a window
    // is being dragged or resized, and calls the window procedure from inside
    // it. So the platform can push text into this queue between `take` and the
    // last use of what `take` returned.
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    try e.typed("first");
    const in = try e.take(0.016);

    // Enough to reallocate several times over.
    var i: u32 = 0;
    while (i < 2000) : (i += 1) try e.typed("later");

    try testing.expectEqual(@as(usize, 1), in.events.len);
    try testing.expectEqualStrings("first", in.events[0].text);
}

test "the wheel accumulates within a frame and resets between them" {
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    e.wheel(0, 54);
    e.wheel(0, 54);
    e.wheel(-10, 0);
    const in = try e.take(0.016);
    try testing.expectEqual(@as(f32, 108), in.scroll.y);
    try testing.expectEqual(@as(f32, -10), in.scroll.x);

    // Reporting the same movement twice would scroll the document twice.
    const next = try e.take(0.016);
    try testing.expectEqual(@as(f32, 0), next.scroll.y);
}

test "losing focus releases every button" {
    // Otherwise the release is delivered to whatever window took the focus,
    // and this one shows a control pressed until it is clicked again.
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    e.button(.left, true);
    e.button(.right, true);
    e.setFocus(false);
    try testing.expect(!e.buttons.any());
    try testing.expect(!e.focused);
}

test "modifiers ride along with the key that was down when they were" {
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    e.setModifiers(.{ .ctrl = true });
    try e.key(.tab, true, false);
    e.setModifiers(.{});
    try e.key(.tab, true, true);

    const in = try e.take(0.016);
    try testing.expect(in.events[0].key_down.modifiers.ctrl);
    try testing.expect(!in.events[1].key_down.modifiers.ctrl);
    try testing.expect(in.events[1].key_down.repeat);
    // A shortcut wants the first press and not the autorepeat.
    try testing.expect(in.pressedOnce(.tab));
}

test "a resize is reported once, and only when the size really changed" {
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    e.resize(1280, 720);
    try testing.expect(e.resized);
    _ = try e.take(0.016);
    try testing.expect(!e.resized);

    // Windows sends WM_SIZE for a move as well as for a resize.
    e.resize(1280, 720);
    try testing.expect(!e.resized);
    e.resize(1280, 721);
    try testing.expect(e.resized);
}

test "a minimised window reports no area rather than a stale one" {
    var e: Events = .init(testing.allocator);
    defer e.deinit();
    e.resize(800, 600);
    try testing.expect(!e.isMinimised());
    e.resize(0, 0);
    try testing.expect(e.isMinimised());
}

test "a queue nobody drains is bounded" {
    // A window behind a modal dialog still receives input for as long as the
    // dialog is up.
    var e: Events = .init(testing.allocator);
    defer e.deinit();

    var i: u32 = 0;
    while (i < max_pending + 100) : (i += 1) try e.key(.space, true, false);
    try testing.expectEqual(@as(usize, max_pending), e.pending.items.len);
    try testing.expectEqual(@as(u32, 100), e.dropped);
}

test "an empty frame is a valid frame" {
    var e: Events = .init(testing.allocator);
    defer e.deinit();
    const in = try e.take(0.016);
    try testing.expectEqual(@as(usize, 0), in.events.len);
    try testing.expectEqual(Point.origin, in.mouse);
    try testing.expect(!in.buttons.any());
}
