//! The editing model behind a text field: a caret, a selection, and the eight
//! operations that move them.
//!
//! Split from the widget that draws it, and deliberately: everything here is
//! arithmetic over bytes, so all of it is testable with no UI, no font and no
//! window, which is where the awkward cases live. Where a caret lands after
//! backspacing over an accented letter is not a question anyone should have
//! to open a window to answer.
//!
//! ## It owns no string
//!
//! `Field.bytes` is the caller's storage and nothing here ever allocates.
//! `checkbox` takes a `*bool` for the same reason: a control whose value
//! lived inside the box would be a value nothing else could read, and a
//! search box the reader cannot read the query out of is not a search box.
//!
//! A fixed buffer rather than a list also settles the per-frame allocation
//! rule by construction. Every field in this program is bounded -- a page
//! number, a search query, a `:` line -- so `insert` returning false when it
//! is full is the whole of the overflow policy.
//!
//! ## Byte offsets, on character boundaries
//!
//! `caret` and `anchor` are offsets into the bytes, not character counts,
//! because every operation that uses them -- insert, remove, measure a prefix
//! -- wants a byte offset, and a count would be converted at each one. They
//! are kept on a boundary instead, by `before` and `after`, so no operation
//! can cut a character in half.

const std = @import("std");

/// A line of text being edited, and where the caret is in it.
pub const Field = struct {
    /// The caller's storage. Never reallocated, never freed here.
    bytes: []u8,
    len: u32 = 0,

    /// Byte offsets into `bytes[0..len]`, always on a character boundary.
    caret: u32 = 0,

    /// The other end of the selection; equal to `caret` when there is none.
    anchor: u32 = 0,

    /// How far the text is scrolled left under the caret, in pixels. Here
    /// rather than on the box because it has to survive the field losing
    /// focus and getting it back.
    offset: f32 = 0,
    /// When the caret last moved, so that the blink restarts on a keystroke
    /// rather than keeping its own phase.
    blink_from: f64 = 0,

    pub fn init(storage: []u8) Field {
        return .{ .bytes = storage };
    }

    pub fn slice(f: Field) []const u8 {
        return f.bytes[0..f.len];
    }

    pub fn isEmpty(f: Field) bool {
        return f.len == 0;
    }

    pub fn hasSelection(f: Field) bool {
        return f.caret != f.anchor;
    }

    /// The selection, low end first.
    pub fn selection(f: Field) [2]u32 {
        return if (f.caret < f.anchor) .{ f.caret, f.anchor } else .{ f.anchor, f.caret };
    }

    /// Replaces the contents and puts the caret at the end, which is where
    /// someone who has just opened a field on existing text wants it.
    ///
    /// Text too long for the storage is cut, and the cut is walked back to a
    /// character boundary. Without that the invariant at the top of this
    /// struct is broken before anyone has pressed a key, and `before` goes
    /// looking for the lead byte of a character whose tail is not there.
    pub fn set(f: *Field, text: []const u8) void {
        var take: u32 = @intCast(@min(text.len, f.bytes.len));
        if (take < text.len) take = before(text, take + 1);

        @memcpy(f.bytes[0..take], text[0..take]);
        f.len = take;
        f.caret = take;
        f.offset = 0;
        f.anchor = take;
    }

    pub fn clear(f: *Field) void {
        f.len = 0;
        f.caret = 0;
        f.anchor = 0;
        f.offset = 0;
    }

    pub fn selectAll(f: *Field) void {
        f.anchor = 0;
        f.caret = f.len;
    }

    /// Inserts at the caret, replacing the selection. False when the text
    /// would not fit, in which case nothing at all is inserted -- a partial
    /// insert would cut a character in half.
    pub fn insert(f: *Field, text: []const u8) bool {
        f.deleteSelection();
        if (f.len + text.len > f.bytes.len) return false;

        const at = f.caret;
        std.mem.copyBackwards(u8, f.bytes[at + text.len .. f.len + text.len], f.bytes[at..f.len]);
        @memcpy(f.bytes[at..][0..text.len], text);
        f.len += @intCast(text.len);
        f.caret = at + @as(u32, @intCast(text.len));
        f.anchor = f.caret;
        return true;
    }

    pub fn deleteSelection(f: *Field) void {
        if (!f.hasSelection()) return;
        const sel = f.selection();
        f.removeRange(sel[0], sel[1]);
    }

    /// The character before the caret, or the selection if there is one.
    pub fn backspace(f: *Field) void {
        if (f.hasSelection()) return f.deleteSelection();
        if (f.caret == 0) return;
        f.removeRange(before(f.slice(), f.caret), f.caret);
    }

    /// The character after the caret, or the selection if there is one.
    pub fn deleteForward(f: *Field) void {
        if (f.hasSelection()) return f.deleteSelection();
        if (f.caret >= f.len) return;
        f.removeRange(f.caret, after(f.slice(), f.caret));
    }

    fn removeRange(f: *Field, from: u32, to: u32) void {
        std.mem.copyForwards(u8, f.bytes[from..], f.bytes[to..f.len]);
        f.len -= to - from;
        f.caret = from;
        f.anchor = from;
    }

    /// Puts the caret somewhere, extending the selection or collapsing it.
    pub fn moveTo(f: *Field, at: u32, extend: bool) void {
        f.caret = at;
        if (!extend) f.anchor = at;
    }

    /// One character left.
    ///
    /// Collapsing to the *near end* of a selection rather than stepping from
    /// the caret is the detail every text field has and nobody notices until
    /// it is missing: with three words selected, left goes to the start of
    /// the selection and right to the end, not one character either side of
    /// wherever the drag happened to finish.
    pub fn moveLeft(f: *Field, extend: bool) void {
        if (!extend and f.hasSelection()) {
            const sel = f.selection();
            f.caret = sel[0];
            f.anchor = sel[0];
            return;
        }
        f.moveTo(before(f.slice(), f.caret), extend);
    }

    pub fn moveRight(f: *Field, extend: bool) void {
        if (!extend and f.hasSelection()) {
            const sel = f.selection();
            f.caret = sel[1];
            f.anchor = sel[1];
            return;
        }
        f.moveTo(after(f.slice(), f.caret), extend);
    }

    pub fn moveHome(f: *Field, extend: bool) void {
        f.moveTo(0, extend);
    }

    pub fn moveEnd(f: *Field, extend: bool) void {
        f.moveTo(f.len, extend);
    }
};

// -- character boundaries -----------------------------------------------------

/// The start of the character before `at`. Continuation bytes are `10xxxxxx`,
/// so walking back over them lands on a lead byte -- which is the whole of
/// what is needed here, and needs no decoding.
pub fn before(text: []const u8, at: u32) u32 {
    if (at == 0) return 0;
    var i = at - 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

/// The start of the character after `at`.
pub fn after(text: []const u8, at: u32) u32 {
    if (at >= text.len) return @intCast(text.len);
    const n = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    return @min(at + n, @as(u32, @intCast(text.len)));
}


// -- the widget ---------------------------------------------------------------

const Box = @import("../Box.zig");
const UI = @import("../UI.zig");
const paint = @import("../../gelgja/paint.zig");

const Color = paint.Color;
const Signal = UI.Signal;
const Size = Box.Size;
const Style = Box.Style;

pub const Error = UI.Error;

/// Room either side of the text. The caret sits inside it, so a caret at the
/// start of the text is not flush against the border.
pub const pad: f32 = 6;
/// Caret width. One pixel reads as a hair at any size; two is a cursor.
pub const caret_width: f32 = 2;
/// A whole blink, and how much of it the caret is visible for.
pub const blink_period: f64 = 1.06;
pub const blink_on: f64 = 0.62;

pub const Options = struct {
    w: ?Size = null,
    h: ?Size = null,
    /// Drawn dimmed while the field is empty and unfocused.
    placeholder: []const u8 = "",
    /// The selection band. Defaults to a mix of the style's own two colours,
    /// which lands the right way up on a dark theme and on a light one --
    /// the same argument `hot_lift` makes.
    selection: ?Color = null,
};

pub const Result = struct {
    signal: Signal,
    /// The text changed this frame.
    edited: bool = false,
    /// Enter was pressed while focused.
    submitted: bool = false,
    /// Escape was pressed while focused.
    cancelled: bool = false,
};

/// A one-line text field.
///
/// Three measures of a prefix per frame -- to the caret, and to each end of
/// the selection -- plus one of the whole string. Týr caches shaped runs, so
/// each is a hash lookup and a sum over the run; a field holds a few dozen
/// characters and this is not where a frame goes.
pub fn textField(ui: *UI, name: []const u8, f: *Field, opts: Options) Error!Result {
    const outer = ui.style();
    const line = ui.metrics.lineHeight(outer.font, outer.font_size);

    ui.nextDefaults(.{
        .w = opts.w orelse .fill,
        .h = opts.h orelse .px(@round(line + pad * 2)),
        .axis = .x,
        .child_align = .center,
        .flags = .{
            .clickable = true,
            .focusable = true,
            .draw_background = true,
            .draw_border = true,
            .clip = true,
        },
    });
    const b = try ui.open(name);
    defer ui.close(b);

    var out: Result = .{ .signal = ui.signal(b) };
    if (out.signal.focused) keys(ui, f, &out);

    const st = b.style;
    const text = f.slice();

    // A press puts the caret where it was pressed and a drag from there
    // selects. Both read last frame's rectangle, which is the one that was
    // under the pointer when it was pressed.
    const left = b.rect.min_x + pad - f.offset;
    if (out.signal.pressed) {
        f.moveTo(try indexAt(ui, f, st, left, ui.in.mouse.x), false);
        f.blink_from = ui.time;
    } else if (out.signal.dragging) {
        f.moveTo(try indexAt(ui, f, st, left, ui.in.mouse.x), true);
    }

    const total = if (text.len == 0) 0 else (try ui.metrics.measure(text, st.font, st.font_size)).x;
    const caret_x = try widthTo(ui, f, st, f.caret);

    // Keep the caret in view, against last frame's width -- like everything
    // else a call site needs geometry for. A field that has just appeared
    // scrolls right on its second frame, and a field being typed into has
    // been on screen a while.
    const inner = b.rect.width() - pad * 2;
    if (inner > 0) {
        if (caret_x - f.offset > inner) f.offset = caret_x - inner;
        if (caret_x - f.offset < 0) f.offset = caret_x;
        f.offset = std.math.clamp(f.offset, 0, @max(total - inner, 0));
    }

    if (f.hasSelection()) {
        const sel = f.selection();
        const x0 = try widthTo(ui, f, st, sel[0]);
        const x1 = try widthTo(ui, f, st, sel[1]);
        ui.next(.{
            .w = .px(x1 - x0),
            .h = .px(line),
            .fixed_x = pad - f.offset + x0,
            .flags = .{ .floating_x = true, .draw_background = true },
            .bg = opts.selection orelse mix(st.bg, st.fg, 0.28),
        });
        _ = try ui.box("selection");
    }

    const empty = f.isEmpty();
    const showing = if (empty and !out.signal.focused) opts.placeholder else text;
    ui.next(.{
        .w = .px(@max(total, 1)),
        .h = .px(line),
        .fixed_x = pad - f.offset,
        .text_align = .start,
        .fg = if (empty) mix(st.bg, st.fg, 0.55) else st.fg,
        .flags = .{ .floating_x = true, .draw_text = true },
    });
    _ = try ui.boxText("text", showing);

    // Solid while the caret is moving and blinking once it settles: a caret
    // that keeps its own phase is invisible for half of every keystroke,
    // which reads as dropped input.
    if (out.signal.focused and @mod(ui.time - f.blink_from, blink_period) < blink_on) {
        ui.next(.{
            .w = .px(caret_width),
            .h = .px(line),
            .fixed_x = pad - f.offset + caret_x,
            .flags = .{ .floating_x = true, .draw_background = true },
            .bg = st.fg,
        });
        _ = try ui.box("caret");
    }

    return out;
}

/// One frame's keys, in the order the platform saw them.
///
/// `Signal.text` is every character typed this frame, flattened, which is
/// enough for a box that only appends and wrong for one that edits: typing
/// `a`, backspace, `a` leaves the text unchanged, and a field that saw the
/// three out of order would disagree.
///
/// Tab is deliberately not read. `UI.end` moves focus along the ring with it
/// after the tree is built, and a field that swallowed tab would trap the
/// keyboard inside itself.
fn keys(ui: *UI, f: *Field, out: *Result) void {
    for (ui.in.events) |e| switch (e) {
        .text => |t| {
            if (typeInto(f, t)) {
                out.edited = true;
                f.blink_from = ui.time;
            }
        },
        .key_down => |k| {
            if (k.modifiers.ctrl) {
                if ((k.char | 0x20) == 'a') f.selectAll();
                continue;
            }
            const extend = k.modifiers.shift;
            switch (k.code) {
                .left => f.moveLeft(extend),
                .right => f.moveRight(extend),
                .home => f.moveHome(extend),
                .end => f.moveEnd(extend),
                .backspace => {
                    f.backspace();
                    out.edited = true;
                },
                .delete => {
                    f.deleteForward();
                    out.edited = true;
                },
                .enter => out.submitted = true,
                .escape => out.cancelled = true,
                else => continue,
            }
            f.blink_from = ui.time;
        },
        else => {},
    };
}

/// Inserts a text event, minus anything that is not text.
///
/// Enter, tab and escape arrive as keys, and several platforms put them in
/// the text stream as well, as `\r`, `\t` and `\x1b`. A field that took them
/// would hold a control character it can neither draw nor measure.
fn typeInto(f: *Field, t: []const u8) bool {
    var changed = false;
    var i: usize = 0;
    while (i < t.len) {
        if (isControl(t[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < t.len and !isControl(t[j])) j += 1;
        if (f.insert(t[i..j])) changed = true;
        i = j;
    }
    return changed;
}

fn isControl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

/// How wide the text is up to a byte offset.
fn widthTo(ui: *UI, f: *Field, st: Style, at: u32) Error!f32 {
    if (at == 0) return 0;
    return (try ui.metrics.measure(f.bytes[0..at], st.font, st.font_size)).x;
}


/// The offset a pointer at `x` is nearest to, `left` being where the text
/// starts on screen.
///
/// Past the *middle* of a character means the caret belongs after it, which
/// is what makes clicking between two letters land where the eye expects
/// rather than always to the left of it. Walks forward and stops at the
/// answer, so a click near the start of a long line costs a couple of
/// measures rather than one per character.
fn indexAt(ui: *UI, f: *Field, st: Style, left: f32, x: f32) Error!u32 {
    const text = f.slice();
    var i: u32 = 0;
    var behind: f32 = 0;
    while (i < f.len) {
        const next = after(text, i);
        const ahead = (try ui.metrics.measure(text[0..next], st.font, st.font_size)).x;
        if (left + (behind + ahead) * 0.5 > x) return i;
        behind = ahead;
        i = next;
    }
    return f.len;
}
fn mix(a: Color, b: Color, k: f32) Color {
    const t = std.math.clamp(k, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}
// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn scratch(storage: []u8, text: []const u8) Field {
    var f: Field = .init(storage);
    f.set(text);
    return f;
}

test "typing inserts at the caret and pushes the rest along" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "ac");

    f.moveLeft(false);
    try testing.expect(f.insert("b"));
    try testing.expectEqualStrings("abc", f.slice());
    try testing.expectEqual(@as(u32, 2), f.caret);
}

test "a field that is full takes nothing rather than half a character" {
    var store: [4]u8 = undefined;
    var f = scratch(&store, "abc");

    // Two bytes into one byte of room: refused whole.
    try testing.expect(!f.insert("é"));
    try testing.expectEqualStrings("abc", f.slice());
    try testing.expect(f.insert("d"));
    try testing.expectEqualStrings("abcd", f.slice());
}

test "backspace removes a character, not a byte" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "aé");

    f.backspace();
    try testing.expectEqualStrings("a", f.slice());
    try testing.expectEqual(@as(u32, 1), f.caret);
}

test "the caret steps over a character at a time in both directions" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "aéb");

    f.moveHome(false);
    f.moveRight(false);
    try testing.expectEqual(@as(u32, 1), f.caret);
    f.moveRight(false);
    try testing.expectEqual(@as(u32, 3), f.caret); // over both bytes of é
    f.moveLeft(false);
    try testing.expectEqual(@as(u32, 1), f.caret);
}

test "a selection is replaced by what is typed over it" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "hello");

    f.selectAll();
    try testing.expect(f.hasSelection());
    try testing.expect(f.insert("bye"));
    try testing.expectEqualStrings("bye", f.slice());
    try testing.expect(!f.hasSelection());
}

test "an unextended motion collapses to the near end of the selection" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "hello");

    f.selectAll();
    f.moveLeft(false);
    try testing.expectEqual(@as(u32, 0), f.caret);

    f.selectAll();
    f.moveRight(false);
    try testing.expectEqual(@as(u32, 5), f.caret);
}

test "shift extends from the anchor and leaves it alone" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "hello");

    f.moveHome(false);
    f.moveRight(true);
    f.moveRight(true);
    try testing.expectEqual(@as(u32, 0), f.anchor);
    try testing.expectEqual(@as(u32, 2), f.caret);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, &f.selection());

    // Backwards past the anchor: the selection is still low end first.
    f.moveEnd(false);
    f.moveLeft(true);
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, &f.selection());
}

test "delete forward takes the character after the caret" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "abc");

    f.moveHome(false);
    f.deleteForward();
    try testing.expectEqualStrings("bc", f.slice());
    f.moveEnd(false);
    f.deleteForward();
    try testing.expectEqualStrings("bc", f.slice());
}

test "setting the text puts the caret where someone would carry on typing" {
    var store: [32]u8 = undefined;
    var f: Field = .init(&store);

    f.set("48");
    try testing.expectEqual(@as(u32, 2), f.caret);
    try testing.expect(!f.hasSelection());

    f.clear();
    try testing.expect(f.isEmpty());
    try testing.expectEqual(@as(u32, 0), f.caret);
}

test "text longer than the storage is truncated rather than overrunning it" {
    var store: [4]u8 = undefined;
    var f: Field = .init(&store);

    f.set("abcdefgh");
    try testing.expectEqual(@as(u32, 4), f.len);
    try testing.expectEqual(@as(u32, 4), f.caret);
}

test "a cut that lands inside a character is walked back to its start" {
    var store: [4]u8 = undefined;
    var f: Field = .init(&store);

    // Three bytes, then a two-byte character that will not fit whole.
    f.set("abcé");
    try testing.expectEqualStrings("abc", f.slice());
    try testing.expectEqual(@as(u32, 3), f.caret);

    // And the invariant holds afterwards: backspace takes a character.
    f.backspace();
    try testing.expectEqualStrings("ab", f.slice());
}

// -- the widget, with a UI but no font and no window --------------------------

const input = @import("../input.zig");

/// One frame with the field in it. `UI.fixed_metrics` advances half an em per
/// byte, so at the default fourteen pixels every character is seven wide and
/// the geometry below is arithmetic rather than a typeface's opinion.
fn oneFrame(ui: *UI, f: *Field, in: input.Input) !Result {
    try ui.begin(.fromRect(0, 0, 300, 60), in);
    const r = try textField(ui, "q", f, .{});
    ui.end();
    return r;
}

fn focusIt(ui: *UI) void {
    ui.setFocus(@import("../key.zig").make(ui.root.key, "q"));
}

fn typing(text: []const u8) [1]input.Event {
    return .{.{ .text = text }};
}

fn pressing(code: input.KeyCode) [1]input.Event {
    return .{.{ .key_down = .{ .code = code } }};
}

test "an unfocused field ignores typing and a focused one takes it" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);

    var hi = typing("hi");
    _ = try oneFrame(&ui, &f, .{ .events = &hi });
    try testing.expect(f.isEmpty());

    focusIt(&ui);
    const r = try oneFrame(&ui, &f, .{ .events = &hi });
    try testing.expectEqualStrings("hi", f.slice());
    try testing.expect(r.edited);
}

test "a backspace between two keystrokes is applied between them" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);

    _ = try oneFrame(&ui, &f, .{});
    focusIt(&ui);

    // The whole reason this walks `ui.in.events` instead of `Signal.text`:
    // flattened, these three are "aa" and the answer would be wrong.
    var mixed = [_]input.Event{
        .{ .text = "a" },
        .{ .key_down = .{ .code = .backspace } },
        .{ .text = "b" },
    };
    _ = try oneFrame(&ui, &f, .{ .events = &mixed });
    try testing.expectEqualStrings("b", f.slice());
}

test "enter submits and escape cancels, and neither changes the text" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);
    f.set("48");

    _ = try oneFrame(&ui, &f, .{});
    focusIt(&ui);

    var enter = pressing(.enter);
    const submitted = try oneFrame(&ui, &f, .{ .events = &enter });
    try testing.expect(submitted.submitted and !submitted.cancelled);

    var escape = pressing(.escape);
    const cancelled = try oneFrame(&ui, &f, .{ .events = &escape });
    try testing.expect(cancelled.cancelled and !cancelled.submitted);

    try testing.expectEqualStrings("48", f.slice());
}

test "a carriage return in the text stream is not text" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);

    _ = try oneFrame(&ui, &f, .{});
    focusIt(&ui);

    // Windows sends enter as a key *and* as `\r`; a field that took it would
    // hold a character it can neither draw nor measure.
    var stream = typing("a\r\tb\x1b");
    _ = try oneFrame(&ui, &f, .{ .events = &stream });
    try testing.expectEqualStrings("ab", f.slice());
}

test "shift with a motion extends the selection through the widget" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);
    f.set("hello");

    _ = try oneFrame(&ui, &f, .{});
    focusIt(&ui);

    var shift_left = [_]input.Event{
        .{ .key_down = .{ .code = .left, .modifiers = .{ .shift = true } } },
        .{ .key_down = .{ .code = .left, .modifiers = .{ .shift = true } } },
    };
    _ = try oneFrame(&ui, &f, .{ .events = &shift_left });
    try testing.expectEqualSlices(u32, &.{ 3, 5 }, &f.selection());
}


test "the caret scrolls into view when the text is longer than the field" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [256]u8 = undefined;
    var f: Field = .init(&store);

    // Sixty characters at seven pixels is far wider than three hundred.
    const sixty: [60]u8 = @splat('x');
    f.set(&sixty);
    _ = try oneFrame(&ui, &f, .{});
    _ = try oneFrame(&ui, &f, .{});
    try testing.expect(f.offset > 0);

    // Home brings it back to the start, and the offset follows the caret
    // rather than being reset by hand anywhere.
    focusIt(&ui);
    var home = pressing(.home);
    _ = try oneFrame(&ui, &f, .{ .events = &home });
    _ = try oneFrame(&ui, &f, .{});
    try testing.expectEqual(@as(f32, 0), f.offset);
}

test "a focused field with a selection draws a band, the text and a caret" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);
    f.set("hello");

    _ = try oneFrame(&ui, &f, .{});
    focusIt(&ui);
    f.selectAll();
    _ = try oneFrame(&ui, &f, .{});

    const box_of = @import("../key.zig").make;
    const field_key = box_of(ui.root.key, "q");

    const band = ui.find(box_of(field_key, "selection")).?;
    const shown = ui.find(box_of(field_key, "text")).?;
    const caret = ui.find(box_of(field_key, "caret")).?;

    // Five characters at seven pixels, starting a pad in.
    try testing.expectEqualStrings("hello", shown.text);
    try testing.expectApproxEqAbs(@as(f32, 35), band.rect.width(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, pad), band.rect.min_x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, caret_width), caret.rect.width(), 0.01);
    // The caret is at the end, which is where `selectAll` leaves it.
    try testing.expectApproxEqAbs(@as(f32, pad + 35), caret.rect.min_x, 0.01);
}

test "a press puts the caret at the character it landed nearest" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);
    f.set("hello");

    // The text starts at `pad` and every character is seven wide, so sixteen
    // is past the middle of the second one: the caret belongs after the
    // first, not before it, which is what a field that rounded down does.
    const at: @import("../../gelgja/geom.zig").Point = .{ .x = 16, .y = 20 };

    // Over it first. A press only reaches a box the pointer was already on,
    // which is true of a real mouse and is where the frame of latency in
    // hover resolution shows.
    _ = try oneFrame(&ui, &f, .{ .mouse = at });
    _ = try oneFrame(&ui, &f, .{ .mouse = at, .buttons = .{ .left = true } });

    try testing.expectEqual(@as(u32, 1), f.caret);
    try testing.expect(!f.hasSelection());
}

test "dragging from a press selects between the two" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var store: [64]u8 = undefined;
    var f: Field = .init(&store);
    f.set("hello");

    // Just past the middle of the first character, which sits at 9.5.
    const start: @import("../../gelgja/geom.zig").Point = .{ .x = 12, .y = 20 };
    _ = try oneFrame(&ui, &f, .{ .mouse = start });
    _ = try oneFrame(&ui, &f, .{ .mouse = start, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(u32, 1), f.anchor);

    // Still held, three characters along.
    const along: @import("../../gelgja/geom.zig").Point = .{ .x = 30, .y = 20 };
    _ = try oneFrame(&ui, &f, .{ .mouse = along, .buttons = .{ .left = true } });

    try testing.expectEqual(@as(u32, 1), f.anchor);
    try testing.expect(f.caret > 1);
    try testing.expect(f.hasSelection());
}
