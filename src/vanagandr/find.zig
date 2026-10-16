//! The search bar: a field, a count, and two chevrons.
//!
//! It is **not in the chrome**. There is no button that opens it and no room
//! reserved for it; `/` brings it into existence over the top-right corner of
//! the page and escape takes it away again. A reader who never searches never
//! gives up a pixel to the possibility, which is the same argument the tab
//! bar makes about a document with one tab.
//!
//! ## What this file knows, and what it does not
//!
//! A query and three numbers. Not a document, not a page, not what a match
//! is: `hlidskjalf/search.zig` finds them and the reader draws them on the
//! page. What comes back from here is one of four things somebody did --
//! typed, stepped, submitted, closed -- and the reader decides what each
//! means, the same division `palette.zig` and `panels.zig` draw.
//!
//! ## It floats, so it records its rectangle
//!
//! Like a panel and for the same reason: it is over the page, so a press
//! inside it must not also be a press on the text underneath. `State.rect` is
//! last frame's, which is the frame the button went down in.

const std = @import("std");
const fenrir = @import("fenrir");

const rails = @import("rails.zig");
const thviti = fenrir.thviti;

const Bounds = fenrir.gelgja.Bounds;
const Fonts = fenrir.tyr.Fonts;
const Icons = thviti.Icons;
const Theme = thviti.Theme;
const UI = thviti.UI;
const w = thviti.widgets;

pub const Error = UI.Error;

/// The longest query the bar will hold. The same bound the search itself
/// uses, so nothing typed here can be silently cut when it is handed over.
pub const query_max = fenrir.hlidskjalf.search.max_query;

/// Wide enough for a phrase at thirteen pixels with the count and the
/// chevrons beside it, narrow enough to leave a column of a two-column paper
/// readable under it.
pub const width: f32 = 340;
pub const height: f32 = 34;

const pad: f32 = 8;
const button: f32 = 20;
/// How far in from the right rail and down from whatever is above.
const inset: f32 = 10;

/// What the reader should do about it.
pub const Action = union(enum) {
    /// The query changed. The reader restarts the scan; there is no "find"
    /// button because a search that only ran on enter would make the count
    /// beside the field a lie for as long as somebody kept typing.
    typed,
    /// Next match, or the previous one when true.
    step: bool,
    /// Enter, which is `n` without moving the hands.
    submitted,
    /// Escape, the close button, or a click outside: put it away and take
    /// the highlights with it.
    close,
};

/// What the bar says beside the field.
pub const Count = struct {
    /// Which match the reader is standing on, numbered from one. Null before
    /// they have stepped onto one.
    at: ?u32 = null,
    found: u32 = 0,
    /// How much of the document has been looked at. A search over six
    /// hundred pages arrives over several seconds and the bar has to say so,
    /// or an incomplete count reads as a wrong one.
    scanned: u32 = 0,
    pages: u32 = 0,

    pub fn scanning(c: Count) bool {
        return c.pages != 0 and c.scanned < c.pages;
    }

    /// `3/47`, `47`, `no matches`, and each of them marked while the scan is
    /// still running.
    ///
    /// A `format` and not a branch at the call site because the four shapes
    /// are one decision -- what is known so far -- and a caller that had to
    /// choose between them could choose wrongly.
    pub fn format(c: Count, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (c.found == 0) {
            try writer.writeAll(if (c.scanning()) "searching" else "no matches");
            return;
        }
        if (c.at) |i| {
            try writer.print("{d}/{d}", .{ i, c.found });
        } else {
            try writer.print("{d}", .{c.found});
        }
        // A running total is not a count, and a reader who saw `4` settle
        // into `11` would not trust either number again.
        if (c.scanning()) try writer.writeAll("+");
    }
};

pub const State = struct {
    open: bool = false,

    /// `bytes` is an interior pointer into `query_buf`, re-aimed every frame
    /// so the struct survives being copied -- a `Session` is returned by
    /// value in the tests. `palette.zig` says the same thing at more length.
    field: w.Field = .{ .bytes = &.{} },
    query_buf: [query_max]u8 = undefined,
    /// The field has just appeared and wants the keyboard. A control that
    /// appears already wanting it has to ask for it.
    focus_next: bool = false,

    /// Where it was drawn last frame, for the pointer.
    rect: Bounds = .empty,
    /// The field had the keyboard when it was last drawn.
    ///
    /// Which is the answer to "should this keystroke go to the reader", and
    /// it has to be last frame's because the question is asked before the
    /// box tree exists -- the same reason a menu's `open` is the caller's.
    /// It is also why enter does not close the bar: it hands the keyboard
    /// back to the document, so `n` and `N` step the matches while the count
    /// stays on screen, and escape is what ends the search.
    typing: bool = false,

    pub fn show(st: *State) void {
        st.open = true;
        st.focus_next = true;
        st.typing = true;
        st.field.bytes = &st.query_buf;
        st.field.clear();
    }

    pub fn hide(st: *State) void {
        st.open = false;
        st.typing = false;
        st.rect = .empty;
    }

    pub fn query(st: *const State) []const u8 {
        return st.field.slice();
    }

    /// Whether a press at this point belongs to the bar rather than to the
    /// page under it.
    pub fn holds(st: *const State, x: f32, y: f32) bool {
        if (!st.open or st.rect.isEmpty()) return false;
        return x >= st.rect.min_x and x <= st.rect.max_x and
            y >= st.rect.min_y and y <= st.rect.max_y;
    }
};

/// Builds the bar, and says what was asked of it.
///
/// `top` is what is above it -- the tab bar's height, or zero. A floating box
/// has to be told; `ui.viewport` is the window and not the space left in it.
pub fn bar(
    ui: *UI,
    face: Fonts.FontId,
    t: Theme,
    icons: *const Icons,
    st: *State,
    count: Count,
    top: f32,
) Error!?Action {
    if (!st.open) return null;

    // Re-aimed every frame rather than on creation: see `State.field`.
    st.field.bytes = &st.query_buf;

    // Before the build, so the field has the keyboard in the same frame it
    // first appears. The key is the field's *path* -- the row it sits in is
    // part of it -- and a name worked out by hand is wrong until something
    // walks it, which is what the test at the bottom of this file does.
    if (st.focus_next) {
        st.focus_next = false;
        ui.setFocus(queryKey(ui));
    }

    ui.pushStyle(.{ .font = face, .font_size = 13, .fg = t.text, .bg = t.panel });
    defer ui.popStyle();

    ui.next(.{
        .w = .px(width),
        .h = .px(height),
        .axis = .x,
        .child_align = .center,
        .fixed_x = @max(ui.viewport.width() - rails.width - width - inset, 0),
        .fixed_y = top + inset,
        .border_color = t.divider,
        .flags = .{
            .floating_x = true,
            .floating_y = true,
            .clickable = true,
            .draw_background = true,
            .draw_border = true,
            .clip = true,
        },
    });
    const box = try ui.open("find");
    defer ui.close(box);
    st.rect = box.rect;

    var out: ?Action = null;

    try w.spacer(ui, .px(pad));
    {
        // The glass is a label and not a button: nothing happens when it is
        // pressed, and a control that lifts under the pointer and then does
        // nothing is worse than no control.
        const glass = icons.byName("fenrir.search", .toolbar_small);
        ui.next(.{ .fg = t.text_dim, .font = glass.font, .font_size = glass.px });
        _ = try w.label(ui, glass.text);
    }
    try w.spacer(ui, .px(pad * 0.5));

    {
        ui.next(.{ .w = .fill, .h = .px(22), .axis = .x });
        const slot = try ui.open("slot");
        defer ui.close(slot);

        const r = try w.field.textField(ui, "query", &st.field, .{
            .h = .px(22),
            .placeholder = "find",
        });
        if (r.edited) out = .typed;
        if (r.submitted) out = .submitted;
        if (r.cancelled) out = .close;

        // Enter gives the keyboard back to the document; a click in the
        // field takes it again.
        st.typing = ui.focus == queryKey(ui) and !r.submitted;
        if (r.submitted) ui.setFocus(.nil);
    }

    // The count, in the same place whatever it says, so the chevrons do not
    // move under a pointer on their way to being clicked.
    ui.next(.{ .w = .px(62), .h = .fill, .axis = .x, .child_align = .center });
    const tally = try ui.open("tally");
    {
        defer ui.close(tally);
        try w.fill(ui);
        ui.next(.{ .fg = if (count.found == 0) t.text_dim else t.text, .font_size = 12 });
        _ = try w.labelf(ui, "{f}###count", .{count});
    }

    try w.spacer(ui, .px(pad * 0.5));
    if ((try w.iconButton(ui, "prev", icons.byName("fenrir.chevron_up", .toolbar_small), .{
        .size = button,
    })).clicked) out = .{ .step = true };
    if ((try w.iconButton(ui, "next", icons.byName("fenrir.chevron_down", .toolbar_small), .{
        .size = button,
    })).clicked) out = .{ .step = false };
    if ((try w.iconButton(ui, "close", icons.byName("fenrir.close", .toolbar_small), .{
        .size = button,
    })).clicked) out = .close;
    try w.spacer(ui, .px(pad * 0.5));

    return out;
}

/// The key the field will have, worked out before the field exists. Every
/// segment of the path is here because every segment is in the hash.
fn queryKey(ui: *UI) thviti.key.Key {
    const root = thviti.key.make(ui.root.key, "find");
    return thviti.key.make(thviti.key.make(root, "slot"), "query");
}


// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn say(c: Count, buf: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try c.format(&writer);
    return writer.buffered();
}

test "the count says what is known and admits what is not" {
    var buf: [64]u8 = undefined;

    // Nothing found and nowhere near finished: not "no matches", which would
    // be a wrong answer rather than an unfinished one.
    try testing.expectEqualStrings("searching", try say(.{ .pages = 10 }, &buf));
    try testing.expectEqualStrings("no matches", try say(.{ .pages = 10, .scanned = 10 }, &buf));

    // Found some, still looking: the plus is the whole difference between a
    // count and a running total.
    try testing.expectEqualStrings("4+", try say(.{ .found = 4, .pages = 10, .scanned = 3 }, &buf));
    try testing.expectEqualStrings("2/4+", try say(.{ .at = 2, .found = 4, .pages = 10, .scanned = 3 }, &buf));
    try testing.expectEqualStrings("2/4", try say(.{ .at = 2, .found = 4, .pages = 10, .scanned = 10 }, &buf));
}

test "a search that opens is empty and wants the keyboard" {
    var st: State = .{};
    st.show();
    try testing.expect(st.open);
    try testing.expect(st.focus_next);
    try testing.expectEqualStrings("", st.query());

    st.hide();
    try testing.expect(!st.open);
    // And it stops claiming the pointer the moment it is closed, rather than
    // holding last frame's rectangle over the page.
    try testing.expect(!st.holds(100, 100));
}
