//! The pen: draw mode's strokes, from the button going down to a mark when
//! it comes up, and ink drawn over the page, kept or still in hand.
//!
//! A file of its own so that all of it is in one place, and so that a build
//! with no marks can leave it out with them.

const std = @import("std");
const fenrir = @import("fenrir");

const Library = @import("../library.zig").Library;
const Session = @import("Session.zig");
const marks = @import("marks.zig");

const gelgja = fenrir.gelgja;
const hlidskjalf = fenrir.hlidskjalf;
const lyngvi = fenrir.lyngvi;

const Color = gelgja.Color;
const Point = gelgja.Point;
const DrawList = fenrir.gleipnir.DrawList;

const Buffer = hlidskjalf.Buffer;
const Marks = hlidskjalf.Marks;
const View = hlidskjalf.View;
const keys = hlidskjalf.keys;

/// What `[` and `]` may take the pen to. A stroke under the thin end would
/// disappear at a fitted zoom and one over the thick end is a redaction.
const min_pen_width: f32 = 0.4;
const max_pen_width: f32 = 24;

/// How far apart two samples of the pointer have to be, in user-space points,
/// before the second is a place the pen went rather than the same place
/// reported again. Also `simplify`'s tolerance, because they are the same
/// question asked before and after the stroke.
const pen_tolerance: f32 = 0.4;

/// The pen: what the next stroke will look like, and the one being drawn.
///
/// The colour is a palette *index* rather than a `Color`, the way the
/// highlight digits are, so that a reader who changes their accent finds
/// the pen changed with it. Null is the reader's own ink colour.
///
/// `page` and `buffer` are which document and which page the stroke in
/// hand belongs to, and they are fixed when the button goes down: a drag
/// that wanders onto the next page keeps drawing on the page it started
/// on, because a stroke is a thing on one page and the alternative is a
/// line that is cut in half by a gap nobody drew.
pub const Pen = struct {
    colour: ?u8 = null,
    /// In PDF points, which is what a `Mark` stores and what keeps the
    /// pen the same weight against the type at every zoom.
    width: f32 = marks.default_pen_width,
    buffer: u32 = 0,
    page: u32 = 0,
    /// True while the button is down and points are being collected.
    down: bool = false,
};

/// The colour the next stroke comes out in.
///
/// Not `highlight`, which is a wash meant to be seen through: ink is
/// opaque and goes *on* the page, so the default is a dark grey-blue that
/// reads as a pen against white paper and is still visible against a
/// figure. A digit replaces it with a palette colour, and those are the
/// same eight the highlighter uses -- one palette, two tools, which is
/// what makes the swatch under the pointer mean what it says.
fn penColor(s: *const Session) Color {
    if (s.pen.colour) |i| return marks.paletteColor(s, i);
    return marks.ink_colour;
}

/// The pen goes down on `page` at `at`, in that page's user space.
fn penDown(s: *Session, v: *View, page: u32, at: Point) void {
    s.stroking.clearRetainingCapacity();
    s.pen.buffer = v.buffer;
    s.pen.page = page;
    s.pen.down = true;
    s.stroking.append(s.gpa, at) catch {};
}

/// One more sample of where the pen is, if it has moved far enough to be
/// a different place. `at` is in the page the stroke began on, which is
/// why it may be off that page: a drag that runs past the edge keeps
/// drawing, and the stroke is clipped to the page when it is shown.
fn penMove(s: *Session, at: Point) void {
    if (!s.pen.down) return;
    const last = s.stroking.getLastOrNull() orelse return;
    const dx = at.x - last.x;
    const dy = at.y - last.y;
    if (dx * dx + dy * dy < pen_tolerance * pen_tolerance) return;
    if (s.stroking.items.len >= Library.max_points) return;
    s.stroking.append(s.gpa, at) catch {};
}

/// The pen comes up: what was drawn becomes a mark, or nothing does.
///
/// A stroke of one point is a click and not a drawing, and is dropped --
/// which also means a press in draw mode that was meant to be a press
/// leaves nothing behind. Everything else goes through `Marks.add` like
/// any other mark, so it is in the same undo history and the same list.
fn penUp(s: *Session) void {
    if (!s.pen.down) return;
    s.pen.down = false;
    const points = Marks.simplify(s.stroking.items, pen_tolerance);
    if (points.len < 2) {
        s.stroking.clearRetainingCapacity();
        return;
    }
    if (s.pen.buffer >= s.buffers.items.len) return;
    const b = s.buffer(s.pen.buffer);
    b.marks.beginGroup();
    _ = b.marks.add(s.gpa, .{
        .kind = .ink,
        .page = s.pen.page,
        .points = points,
        .width = s.pen.width,
        .color = penColor(s),
    }, false) catch {};
    s.stroking.clearRetainingCapacity();
    marks.applyEffects(s);
    s.dirty_title = true;
}

/// The stroke in hand is abandoned: escape, or leaving draw mode with the
/// button still down.
pub fn penCancel(s: *Session) void {
    s.pen.down = false;
    s.stroking.clearRetainingCapacity();
}

pub fn setPenWidth(s: *Session, factor: f32) void {
    s.pen.width = std.math.clamp(s.pen.width * factor, min_pen_width, max_pen_width);
    s.say("pen {d:.1}pt", .{s.pen.width});
}

pub fn setPenColour(s: *Session, index: u8) void {
    if (index >= keys.palette_size) return;
    s.pen.colour = index;
    s.say("pen {s}", .{marks.paletteName(index)});
}

/// The pointer in draw mode: down is the pen down, moving is the stroke,
/// up is a mark.
///
/// The scrollbars are not consulted, unlike everywhere else, and that is
/// deliberate: in draw mode the pointer is a pen over the whole window,
/// and a stroke that began by grabbing a thumb somebody could not see
/// under their hand would be worse than a thumb that has to be reached
/// with the wheel. Scrolling is the wheel and the keys, both of which
/// still work while the pen is down.
pub fn drawPointer(s: *Session, in: lyngvi.Input, down: bool, pressed: bool) void {
    if (!down) return penUp(s);

    const v = s.view();
    if (pressed) {
        _ = s.layout().focusAt(in.mouse);
        const focused = s.view();
        const page = focused.pageAt(in.mouse) orelse return;
        const at = focused.userSpaceAt(page, in.mouse) orelse return;
        penDown(s, focused, page, at);
        return;
    }
    if (!s.pen.down or v.buffer != s.pen.buffer) return;
    // In the space of the page the stroke started on, whether or not the
    // pointer is still over it -- `userSpaceAt` answers null off the
    // page, and a stroke that stopped at the margin would be a line with
    // its end cut off.
    penMove(s, v.pageSpaceAt(s.pen.page, in.mouse));
}

/// The ink on the pages a window can see, and the stroke being drawn.
///
/// ## Why this is a row of discs
///
/// `gleipnir/stroke.zig` already turns a pen dragged along a path into an
/// outline -- caps, joins, miters -- and this does not call it, which
/// needs saying. What that file produces is a *path*, and the only path
/// pipeline in this reader draws the page: it runs on the worker thread,
/// behind a `Scene` recorded once per page per zoom, and ink has to
/// appear under the pointer this frame. The overlay these marks share
/// with the highlights is the instance pipeline, and an instance is an
/// axis-aligned rounded box by design -- see the note at the top of
/// `DrawList.zig` about why it has no rotation.
///
/// So the stroke is drawn the way `stroke.zig` itself says it thinks
/// about strokes: **stamping, not offsetting.** A rounded box whose
/// radius is half its side is a disc, a row of overlapping discs along a
/// segment is that segment stroked with round caps, and a disc at each
/// joint is the round join. It is the same algorithm reaching the screen
/// through the pipeline that is available, and it has the same property
/// that made it the choice there: no case analysis. A stroke that doubles
/// back, a corner tighter than the pen, a segment of no length -- none of
/// them is a special case, because overlapping opaque discs are their own
/// union.
///
/// The cost is instances, proportional to the visible length of stroke
/// rather than to the number of points, which is why the spacing is tied
/// to the radius and why pages out of view are skipped before any of it.
pub fn drawInk(
    s: *Session,
    v: *View,
    b: *Buffer,
    range: View.Visible,
    over: *DrawList,
) !void {
    for (b.marks.items()) |mark| {
        if (mark.kind != .ink) continue;
        if (mark.page < range.first or mark.page >= range.end) continue;
        try strokePoints(s, v, mark.page, mark.points, mark.width, mark.color, over);
    }

    // The stroke in hand, in this window only. It is not a mark yet --
    // it becomes one when the button comes up -- so it is drawn from the
    // session's buffer and not from the list.
    if (!s.pen.down or v.buffer != s.pen.buffer) return;
    if (s.pen.page < range.first or s.pen.page >= range.end) return;
    if (v != s.layout().current()) return;
    try strokePoints(s, v, s.pen.page, s.stroking.items, s.pen.width, penColor(s), over);
}

/// One polyline in user space, stamped into the overlay. See `drawInk`.
fn strokePoints(
    s: *Session,
    v: *View,
    page: u32,
    points: []const Point,
    width: f32,
    color: Color,
    over: *DrawList,
) !void {
    _ = s;
    if (points.len == 0) return;

    // Never thinner than a pixel: a hairline at a fitted zoom is what
    // makes ink look like it failed to load rather than like a fine pen.
    const radius = @max(0.5, width * v.zoom * 0.5);
    // Half a radius between stamps. The union of discs that far apart is
    // scalloped by about two per cent of the radius, which is under a
    // pixel at every width this reader allows, and it is the spacing at
    // which two overlapping antialiased edges still leave the inside of
    // the stroke fully covered.
    const step = @max(0.5, radius * 0.5);

    var previous = v.windowPointOf(page, points[0]);
    try disc(over, previous, radius, color);
    for (points[1..]) |p| {
        const at = v.windowPointOf(page, p);
        const dx = at.x - previous.x;
        const dy = at.y - previous.y;
        const length = @sqrt(dx * dx + dy * dy);
        // The segment's own stamps, then the joint. `n` is how many fit;
        // the endpoint is the next iteration's `previous` and is stamped
        // there, so it is not stamped twice here.
        const n: u32 = @intFromFloat(@min(@floor(length / step), max_stamps));
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n + 1));
            try disc(over, .{ .x = previous.x + dx * t, .y = previous.y + dy * t }, radius, color);
        }
        try disc(over, at, radius, color);
        previous = at;
    }
}

/// A ceiling on the stamps one segment may cost.
///
/// A segment is one frame of pointer movement, so it is short unless the
/// window was behind -- a frame after a breakpoint, or a drag that ran
/// across the screen while the reader was busy. The line is still drawn
/// in that case; it is drawn with a gap in it rather than with ten
/// thousand instances, which is the better of the two failures and is the
/// same argument `keys.max_commands` makes.
const max_stamps: f32 = 512;

fn disc(over: *DrawList, at: Point, radius: f32, color: Color) !void {
    try over.rounded(
        .fromRect(at.x - radius, at.y - radius, at.x + radius, at.y + radius),
        .all(radius),
        color,
    );
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const sessionOf = fixtures.sessionOf;

test "a drag in draw mode is a stroke, and it is a mark like any other" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    const b = s.buffer(0);

    // Down on the page, across it, and up.
    const from = v.windowPoint(0, .{ .x = 100, .y = 700 }).?;
    s.pointer(.{ .mouse = from, .buttons = .{ .left = true } });
    try testing.expect(s.pen.down);
    try testing.expectEqual(@as(usize, 0), b.marks.count());

    var x: f32 = 110;
    while (x <= 300) : (x += 10) {
        const at = v.windowPoint(0, .{ .x = x, .y = 700 }).?;
        s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    }
    // Nothing is written until the pen comes up: a stroke half drawn is not
    // a mark, it is a gesture.
    try testing.expectEqual(@as(usize, 0), b.marks.count());
    try testing.expect(s.stroking.items.len > 2);

    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 300, .y = 700 }).?, .buttons = .{} });
    try testing.expect(!s.pen.down);
    try testing.expectEqual(@as(usize, 1), b.marks.count());

    const mark = b.marks.items()[0];
    try testing.expectEqual(Marks.Kind.ink, mark.kind);
    // A straight drag is two points once it has been simplified, whatever it
    // was sampled as.
    try testing.expectEqual(@as(usize, 2), mark.points.len);
    try testing.expectApproxEqAbs(@as(f32, 100), mark.points[0].x, 1);
    try testing.expectApproxEqAbs(@as(f32, 300), mark.points[1].x, 1);
    try testing.expectApproxEqAbs(s.pen.width, mark.width, 0.001);

    // And it undoes with `u`, through the one history, like a highlight.
    try testing.expect(b.marks.canUndo());
    marks.undoMarks(&s, false);
    try testing.expectEqual(@as(usize, 0), b.marks.count());
}

test "a press in draw mode that goes nowhere leaves nothing behind" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const at = s.view().windowPoint(0, .{ .x = 100, .y = 700 }).?;
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = at, .buttons = .{} });
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "a stroke keeps to the page it began on, however far the drag goes" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    const on_page = v.windowPoint(0, .{ .x = 100, .y = 40 }).?;
    s.pointer(.{ .mouse = on_page, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(u32, 0), s.pen.page);

    // Down past the bottom of page one, into the gap and towards page two.
    // The stroke is still page one's, with points below its edge.
    const below: Point = .{ .x = on_page.x, .y = v.pageRect(0).max_y + 30 };
    s.pointer(.{ .mouse = below, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = below, .buttons = .{} });

    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
    const mark = s.buffer(0).marks.items()[0];
    try testing.expectEqual(@as(u32, 0), mark.page);
    try testing.expect(mark.points[mark.points.len - 1].y < 0);
}

test "leaving draw mode with the pen down throws the stroke away" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 100, .y = 700 }).?, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 300, .y = 700 }).?, .buttons = .{ .left = true } });

    _ = s.apply(keys.enter(&s.keymap, .normal));
    try testing.expect(!s.pen.down);
    try testing.expectEqual(@as(usize, 0), s.stroking.items.len);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "the pen takes the palette colours and a width that compounds" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    // The digit picks the same swatch it would pick in any other mode.
    _ = s.apply(keys.paletteCommand(.draw, 2).?);
    try testing.expectEqual(marks.paletteColor(&s, 2), penColor(&s));

    const started = s.pen.width;
    _ = s.apply(.{ .pen_width = 1.4 });
    try testing.expect(s.pen.width > started);
    _ = s.apply(.{ .pen_width = 1.0 / 1.4 });
    try testing.expectApproxEqAbs(started, s.pen.width, 0.0001);

    // And it is clamped: a pen thinner than a hair or wider than a page is
    // not a pen.
    for (0..40) |_| _ = s.apply(.{ .pen_width = 1.4 });
    try testing.expectApproxEqAbs(max_pen_width, s.pen.width, 0.001);
    for (0..80) |_| _ = s.apply(.{ .pen_width = 1.0 / 1.4 });
    try testing.expectApproxEqAbs(min_pen_width, s.pen.width, 0.001);
}

test "a click erases a stroke it is on, and not one it is merely inside" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    // Two sides of a box, drawn with the pen.
    const drawn = [_]Point{
        .{ .x = 100, .y = 400 },
        .{ .x = 300, .y = 400 },
        .{ .x = 300, .y = 600 },
    };
    _ = try s.buffer(0).marks.add(gpa, .{
        .kind = .ink,
        .page = 0,
        .points = &drawn,
        .width = 2,
    }, false);

    const v = s.view();
    // In normal mode a press on a mark takes it away -- the eraser on the end
    // of the highlighter, which ink gets for nothing by being a mark. A press
    // in the middle of the box is not on the line and takes nothing.
    const inside = v.windowPoint(0, .{ .x = 200, .y = 500 }).?;
    s.pointer(.{ .mouse = inside, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = inside, .buttons = .{} });
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());

    const on_line = v.windowPoint(0, .{ .x = 200, .y = 400 }).?;
    s.pointer(.{ .mouse = on_line, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "ink is drawn over the page, and only on the pages a window can see" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    const drawn = [_]Point{ .{ .x = 100, .y = 700 }, .{ .x = 300, .y = 700 } };
    const b = s.buffer(0);
    _ = try b.marks.add(gpa, .{ .kind = .ink, .page = 0, .points = &drawn, .width = 2 }, true);
    // The same stroke far down the document, which should cost nothing.
    _ = try b.marks.add(gpa, .{ .kind = .ink, .page = 8, .points = &drawn, .width = 2 }, true);

    var over: DrawList = .init(gpa, .fromRect(0, 0, 1000, 800));
    defer over.deinit();
    const v = s.view();
    try drawInk(&s, v, b, v.visiblePages(), &over);
    try testing.expect(over.count() > 0);

    // With nothing in range, nothing is drawn at all: an off-screen stroke
    // costs one compare, not a walk of its points.
    over.reset(.fromRect(0, 0, 1000, 800));
    try drawInk(&s, v, b, .{ .first = 0, .end = 0 }, &over);
    try testing.expectEqual(@as(u32, 0), over.count());
}
