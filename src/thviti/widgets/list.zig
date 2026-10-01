//! A scrolling list that builds only the rows it can see.
//!
//! `vanagandr/ui.zig` builds all of them and lets the draw list cull what
//! falls outside the view, which is the right trade at two hundred rows and
//! the wrong one at sixty thousand: culling happens after a box has been
//! acquired, sized by five passes and hit-tested, so the work saved is the
//! drawing and nothing else. Here the rows outside the view are never built,
//! and what the view is showing costs the same whether the document has forty
//! sections or a six-hundred-page outline behind it.
//!
//! ## The range is arithmetic, and is tested as such
//!
//! `range` is the whole idea -- four numbers in, two row indices out -- and
//! it is a free function so the awkward cases can be asked about with no UI
//! at all. That is the same seam `field.zig` cut: the part worth being sure
//! of is the part with no window in it.
//!
//! ## Why a leading spacer rather than floating rows
//!
//! A row could be floated at `index * row_height` and positioned exactly.
//! It could not then be scrolled: `UI.positions` leaves floating children
//! alone on purpose, which is what makes a header pinned inside a scroll view
//! possible. So the rows stay in the flow and a nil-keyed spacer stands in
//! for the ones above them. One box, no state, and the scroll offset applies
//! to the rows the way it applies to everything else.
//!
//! ## Why an iterator and not a callback
//!
//! `openPanel` makes the argument already: returning the box rather than
//! taking a closure keeps the call site's control flow its own, which is the
//! entire argument for immediate mode. A list is where that matters most --
//! a row is where a program wants to `continue`, to break out early, or to
//! read something it has borrowed from a document.

const std = @import("std");

const Box = @import("../Box.zig");
const UI = @import("../UI.zig");
const paint = @import("../../gelgja/paint.zig");
const w = @import("../widgets.zig");

const Color = paint.Color;
const Signal = UI.Signal;
const Size = Box.Size;

pub const Error = UI.Error;

/// The row height the design language asks for: dense enough that a sidebar
/// shows twenty things rather than eight.
pub const row_height: f32 = 20;

pub const Options = struct {
    /// How many rows there are, not how many are drawn.
    count: u32,
    row_height: f32 = row_height,
    /// Rows built beyond each edge of the view. One is enough to keep a row
    /// from appearing after the scroll has already moved past it, since the
    /// range is computed from the eased offset rather than the target.
    overscan: u32 = 1,
    w: ?Size = null,
    h: ?Size = null,
};

/// A list, mid-build. `rows` says which ones to build; nothing else has to
/// be tracked by the caller.
pub const List = struct {
    view: w.ScrollView,
    count: u32,
    row_height: f32,
    /// The first row built this frame, and one past the last.
    first: u32,
    end: u32,

    pub fn content(l: List) f32 {
        return @as(f32, @floatFromInt(l.count)) * l.row_height;
    }

    /// How many rows were built, against how many there are. The pair the
    /// widget exists for.
    pub fn built(l: List) u32 {
        return l.end - l.first;
    }

    pub fn rows(l: List) Rows {
        return .{ .at = l.first, .end = l.end };
    }

    /// Where a row sits inside the content, whether or not it was built.
    pub fn topOf(l: List, index: u32) f32 {
        return @as(f32, @floatFromInt(index)) * l.row_height;
    }

    /// Brings a row into view, moving the least that will do it. Safe to call
    /// for a row outside the built range -- which is the point, since the row
    /// a keymap has just selected is usually one that is not on screen.
    pub fn scrollTo(l: List, index: u32) void {
        const height = l.view.box.rect.height();
        if (height <= 0) return;

        const top = l.topOf(index);
        const limit = @max(l.content() - height, 0);
        const at = &l.view.box.view_off_target[1];
        if (top < at.*) {
            at.* = @min(top, limit);
        } else if (top + l.row_height > at.* + height) {
            at.* = std.math.clamp(top + l.row_height - height, 0, limit);
        }
    }
};

pub const Rows = struct {
    at: u32,
    end: u32,

    pub fn next(it: *Rows) ?u32 {
        if (it.at >= it.end) return null;
        defer it.at += 1;
        return it.at;
    }
};

/// Which rows a view of `height` showing content scrolled to `off` covers.
///
/// Half-open, and clamped to the count at both ends, so `first == end` is an
/// empty range and never a wrap. A view with no height yet -- a list on the
/// frame it first appears -- has no rows, and `open` guesses the viewport
/// instead of asking for that answer.
pub fn range(count: u32, height_of_row: f32, off: f32, height: f32, overscan: u32) [2]u32 {
    if (count == 0 or height_of_row <= 0 or height <= 0) return .{ 0, 0 };

    const top = @max(off, 0);
    const n: f32 = @floatFromInt(count);

    const first_f = @min(@floor(top / height_of_row), n);
    const end_f = @min(@ceil((top + height) / height_of_row), n);

    const first: u32 = @intFromFloat(first_f);
    const end: u32 = @intFromFloat(end_f);
    return .{ first -| overscan, @min(count, end + overscan) };
}

/// Opens the list. The caller builds the rows `l.rows()` names and calls
/// `close`.
pub fn open(ui: *UI, name: []const u8, opts: Options) Error!List {
    ui.nextDefaults(.{ .w = opts.w orelse .fill, .h = opts.h orelse .fill });

    const content = @as(f32, @floatFromInt(opts.count)) * opts.row_height;
    const view = try w.openScroll(ui, name, content);

    // Last frame's height, like every other geometry a call site reads here.
    // A list that has never been laid out has none, and the viewport is the
    // one upper bound available without asking the solver to run early: it
    // builds too many rows for exactly one frame rather than none at all,
    // and a list that appears empty on the frame it opens looks broken in a
    // way that a list which is briefly generous does not.
    const height = if (view.box.rect.height() > 0)
        view.box.rect.height()
    else
        ui.viewport.height();

    const at = range(opts.count, opts.row_height, view.box.view_off[1], height, opts.overscan);

    // Everything above the first built row, as one box with no identity.
    try w.spacer(ui, .px(@as(f32, @floatFromInt(at[0])) * opts.row_height));

    return .{
        .view = view,
        .count = opts.count,
        .row_height = opts.row_height,
        .first = at[0],
        .end = at[1],
    };
}

pub fn close(ui: *UI, l: List) void {
    // And everything below it, so that the scroll view still sums to the
    // whole content for a caller who sized it `.children`.
    const below: f32 = @floatFromInt(l.count - l.end);
    w.spacer(ui, .px(below * l.row_height)) catch {};
    ui.close(l.view.box);
}

/// The scrollbar beside it, positioned from the same numbers.
pub fn scrollBar(ui: *UI, name: []const u8, l: List) Error!void {
    return w.scrollBar(ui, name, l.view, l.content());
}

pub const RowOptions = struct {
    selected: bool = false,
    /// Room before the text, for a tree drawn as a flat list with a depth per
    /// entry -- which is the shape `gjoll/outline.zig` will return.
    indent: f32 = 0,
    /// Defaults to a mix of the style's own two colours, the way the text
    /// field's selection does, so it lands the right way up in either theme.
    selection: ?Color = null,
};

/// One row: a band that takes the click, with the text clipped inside it.
///
/// `boxText` rather than `box`, because the text in a list is a document's
/// and not the program's -- a heading with `###` in it would otherwise split
/// and key on its own tail.
pub fn row(ui: *UI, l: List, index: u32, text: []const u8, opts: RowOptions) Error!Signal {
    const st = ui.style();

    ui.nextDefaults(.{
        .w = .fill,
        .h = .px(l.row_height),
        .axis = .x,
        .child_align = .center,
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .hot_animation = true,
            .clip = true,
        },
        // Transparent rather than absent: the hover lift moves a background
        // towards the foreground, and a row with no background to lift is a
        // row that cannot show it is under the pointer.
        .bg = if (opts.selected)
            opts.selection orelse mix(st.bg, st.fg, 0.24)
        else
            st.bg.withAlpha(0),
    });

    var name: [16]u8 = undefined;
    const b = try ui.open(std.fmt.bufPrint(&name, "###row{d}", .{index}) catch "###row");
    defer ui.close(b);
    const sig = ui.signal(b);

    if (opts.indent > 0) try w.spacer(ui, .px(opts.indent));
    ui.next(.{ .w = .fill, .h = .text(0), .flags = .{ .draw_text = true } });
    _ = try ui.boxText("label", text);

    return sig;
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

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a range covers the view and stops at the ends of the list" {
    // Twenty-pixel rows, a hundred-pixel view, no overscan: five rows.
    try testing.expectEqualSlices(u32, &.{ 0, 5 }, &range(100, 20, 0, 100, 0));
    // Scrolled two rows down, it is the same five, moved.
    try testing.expectEqualSlices(u32, &.{ 2, 7 }, &range(100, 20, 40, 100, 0));
    // Half a row down, six rows are partly visible and all six are built.
    try testing.expectEqualSlices(u32, &.{ 0, 6 }, &range(100, 20, 10, 100, 0));
    // And at the bottom it stops at the count rather than running past it.
    try testing.expectEqualSlices(u32, &.{ 95, 100 }, &range(100, 20, 1900, 100, 0));
}

test "overscan widens the range without leaving it" {
    try testing.expectEqualSlices(u32, &.{ 1, 8 }, &range(100, 20, 40, 100, 1));
    // Clamped at zero rather than wrapping, which a u32 subtraction would.
    try testing.expectEqualSlices(u32, &.{ 0, 7 }, &range(100, 20, 0, 100, 2));
    try testing.expectEqualSlices(u32, &.{ 93, 100 }, &range(100, 20, 1900, 100, 2));
}

test "a range with nothing to cover is empty rather than backwards" {
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, &range(0, 20, 0, 100, 1));
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, &range(100, 20, 0, 0, 1));
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, &range(100, 0, 0, 100, 1));
    // A negative offset is a rubber band, not a reason to index backwards:
    // it is clamped, so it asks the same question as an offset of zero.
    try testing.expectEqualSlices(u32, &.{ 0, 5 }, &range(100, 20, -30, 100, 0));
}

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

/// One frame of a list of `count` rows in a hundred-pixel-tall view.
fn oneFrame(ui: *UI, count: u32, in: @import("../input.zig").Input) !List {
    try ui.begin(.fromRect(0, 0, 200, 100), in);
    ui.next(.{ .w = .px(180), .h = .px(100) });
    const l = try open(ui, "rows", .{ .count = count, .row_height = 20 });
    var it = l.rows();
    while (it.next()) |n| {
        _ = try row(ui, l, n, "section", .{ .selected = n == 0 });
    }
    close(ui, l);
    ui.end();
    return l;
}

test "a list of sixty thousand rows builds a screenful" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, 60_000, .{});
    const l = try oneFrame(&ui, 60_000, .{});

    // Five rows in a hundred pixels, plus one of overscan at the bottom --
    // there is nothing above row zero to overscan into.
    try testing.expectEqual(@as(u32, 0), l.first);
    try testing.expectEqual(@as(u32, 6), l.end);
    try testing.expectEqual(@as(u32, 6), l.built());

    // And the persistent table holds those rows and their labels, not sixty
    // thousand of each. This is the claim the widget is making.
    try testing.expect(ui.boxCount() < 32);
}

test "scrolling moves the window of rows that exist" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, 1000, .{});
    _ = try oneFrame(&ui, 1000, .{});

    const view = ui.find(@import("../key.zig").make(ui.root.key, "rows")).?;
    view.view_off_target[1] = 400;
    view.view_off[1] = 400;

    const l = try oneFrame(&ui, 1000, .{});
    try testing.expectEqual(@as(u32, 19), l.first);
    try testing.expectEqual(@as(u32, 26), l.end);

    // Row zero was not built; row twenty was, and sits where the content
    // says. It is still *in the table* -- `prune_after` keeps a box that has
    // gone quiet for a few frames, so a panel behind a tab does not lose its
    // scroll -- and the frame it was last touched on is what says so.
    const key = @import("../key.zig").make;
    const rows_key = key(ui.root.key, "rows");
    try testing.expect(ui.find(key(rows_key, "row0")).?.last_frame < ui.frame_index);
    const twenty = ui.find(key(rows_key, "row20")).?;
    try testing.expectApproxEqAbs(@as(f32, 20 * 20 - 400), twenty.rect.min_y, 1e-3);
}

test "a row reports the click that lands on it" {
    var ui = scratch();
    defer ui.deinit();

    // Row two, half way down it: the third twenty-pixel band.
    const at: @import("../../gelgja/geom.zig").Point = .{ .x = 40, .y = 50 };
    _ = try oneFrame(&ui, 1000, .{ .mouse = at });
    _ = try oneFrame(&ui, 1000, .{ .mouse = at });

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at, .buttons = .{ .left = true } });
    ui.next(.{ .w = .px(180), .h = .px(100) });
    const l = try open(&ui, "rows", .{ .count = 1000, .row_height = 20 });
    var pressed: ?u32 = null;
    var it = l.rows();
    while (it.next()) |n| {
        if ((try row(&ui, l, n, "section", .{})).pressed) pressed = n;
    }
    close(&ui, l);
    ui.end();

    try testing.expectEqual(@as(?u32, 2), pressed);
}

test "scrolling to a row moves the least that brings it into view" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, 1000, .{});
    const l = try oneFrame(&ui, 1000, .{});

    // Already visible: nothing moves.
    l.scrollTo(1);
    try testing.expectEqual(@as(f32, 0), l.view.box.view_off_target[1]);

    // Below the view: just far enough that its bottom edge is the view's.
    l.scrollTo(9);
    try testing.expectApproxEqAbs(@as(f32, 100), l.view.box.view_off_target[1], 1e-3);

    // Above it: flush with the top.
    l.view.box.view_off_target[1] = 400;
    l.scrollTo(10);
    try testing.expectApproxEqAbs(@as(f32, 200), l.view.box.view_off_target[1], 1e-3);
}

test "an empty list builds no rows and still scrolls nowhere" {
    var ui = scratch();
    defer ui.deinit();

    const l = try oneFrame(&ui, 0, .{});
    try testing.expectEqual(@as(u32, 0), l.built());
    try testing.expectEqual(@as(f32, 0), l.content());
    l.scrollTo(4);
    try testing.expectEqual(@as(f32, 0), l.view.box.view_off_target[1]);
}
