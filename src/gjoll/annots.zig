//! A page's annotations, read back as the marks and comments they are
//! (ISO 32000-2 §12.5).
//!
//! The interpreter *draws* an annotation; this *reads* one. A highlight made
//! in Acrobat, in Zotero or by an earlier fenrir is some boxes over words, a
//! colour and perhaps a note, and the reader wants those facts -- to step
//! through it, comment on it, recolour it -- rather than the appearance
//! stream that paints them. What is read here the reader draws itself, so
//! the interpreter is told to leave it out (`taken`, passed as
//! `Options.taken`), and both sides ask one function, `roleOf`. Two copies
//! of that decision would sooner or later disagree, and an annotation they
//! disagree about is drawn twice or by nobody.
//!
//! ## What is read
//!
//! - The four text markups, a box a line from `/QuadPoints`, or the `/Rect`
//!   for one that has none.
//! - `/Ink`, a polyline a path of `/InkList`.
//! - `/Line` when it carries `/QuadPoints`: fenrir's arrow, and the words it
//!   points at. A line from another program is a drawing, not a mark.
//! - `/Text` in reply to one of those through `/IRT`: a comment on it. A
//!   thread is followed back to its first annotation, which is what every
//!   comment in it is about.
//!
//! Everything else -- links, form fields, stamps, a sticky note on its own --
//! is not a mark, and the interpreter goes on drawing it. A note on its own
//! has no words under it to be a comment on.
//!
//! ## Where
//!
//! In the space the reader keeps marks in: the page as displayed, crop box at
//! the origin, `/Rotate` applied, y upwards. The file's numbers are default
//! user space, so every point comes in through `pageMatrix`, the transform
//! the interpreter puts under the page.
//!
//! ## Names
//!
//! `/NM` is kept as it was written. Whether it is one of fenrir's, and so a
//! number, is the reader's question; here it is bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const Page = @import("Page.zig");
const content = @import("content.zig");
const gelgja = @import("../gelgja.zig");
const object = @import("object.zig");
const outline = @import("outline.zig");

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const Dict = object.Dict;
const Matrix = content.Matrix;
const Object = object.Object;
const Point = gelgja.Point;

pub const Error = Document.Error;

/// What an annotation becomes. The four markups are PDF's names, which is
/// what lets the reader's `Style` take them by name.
pub const Kind = enum {
    highlight,
    underline,
    strikeout,
    squiggly,
    ink,
    arrow,
    /// A comment on the first annotation of its thread.
    reply,
};

pub const Annot = struct {
    kind: Kind,
    /// `/NM`, as written, or empty for an annotation that has none.
    name: []const u8 = "",
    /// For a reply, the annotation its thread starts at, as an index into
    /// the same list. Null for a reply whose thread is not on its page,
    /// which the standard forbids and which the reader drops.
    thread: ?u32 = null,
    /// A box a line, for a markup or an arrow.
    lines: []const Bounds = &.{},
    /// A polyline a path, for ink.
    paths: []const []const Point = &.{},
    /// `/C`. Null when the file gives none, or the empty array that means
    /// no colour at all.
    color: ?Color = null,
    /// The pen's width, for ink: `/BS /W`, or `/Border`'s third number.
    width: f32 = 1,
    /// `/Contents`, as UTF-8.
    text: []const u8 = "",
};

/// More than any page holds, and few enough that a hostile file cannot
/// make one page cost seconds.
const max_quads = 1 << 12;
const max_points = 1 << 16;
const max_hops = 16;

/// Every annotation on `p` that the reader takes, in `/Annots` order.
/// Everything returned is allocated in `arena`; nothing is borrowed from the
/// document, so it can be handed to another thread.
pub fn read(arena: Allocator, doc: *Document, p: Page) Error![]const Annot {
    const listed = p.annotations(doc) catch return &.{};
    const base = content.pageMatrix(p, p.rotate);

    var out: std.ArrayList(Annot) = .empty;
    // `/IRT` names its parent by reference, so a reply is placed by the
    // object number of each annotation read before it was.
    var numbers: std.ArrayList(u32) = .empty;
    var parents: std.ArrayList(u32) = .empty;

    for (listed) |raw| {
        const resolved = doc.resolve(raw) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const dict = resolved.asDict() orelse continue;
        const kind = roleOf(doc, dict, 0) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        } orelse continue;

        var a: Annot = .{ .kind = kind };
        a.name = try arena.dupe(u8, stringOf(doc, dict, "NM"));
        a.color = colorOf(doc, dict);
        if (stringOf(doc, dict, "Contents").len != 0) {
            a.text = try outline.decode(arena, stringOf(doc, dict, "Contents"));
        }
        switch (kind) {
            .highlight, .underline, .strikeout, .squiggly, .arrow => a.lines = try linesOf(arena, doc, dict, base),
            .ink => {
                a.paths = try pathsOf(arena, doc, dict, base);
                a.width = widthOf(doc, dict);
            },
            .reply => {},
        }

        try out.append(arena, a);
        try numbers.append(arena, refNumber(raw));
        try parents.append(arena, refNumber(dict.get("IRT")));
    }

    // A reply to a reply is a comment on the same thing, so each is
    // followed back to the first annotation of its thread.
    for (out.items, 0..) |*a, i| {
        if (a.kind != .reply) continue;
        var at = i;
        var hops: u8 = 0;
        while (out.items[at].kind == .reply) : (hops += 1) {
            if (hops == max_hops) break;
            at = indexOf(numbers.items, parents.items[at]) orelse break;
        }
        if (out.items[at].kind != .reply) a.thread = @intCast(at);
    }
    return out.items;
}

/// Whether the reader draws this annotation itself: what the interpreter is
/// told through `Options.taken`. Errors are a no, so a dictionary that will
/// not resolve is left to the interpreter, which skips it too.
pub fn taken(doc: *Document, annot: Dict) bool {
    return (roleOf(doc, annot, 0) catch null) != null;
}

/// What the reader makes of one annotation, or null when it is not a mark.
fn roleOf(doc: *Document, annot: Dict, depth: u8) Error!?Kind {
    // §12.5.3: hidden everywhere, or kept off the screen. Neither is on
    // the page as a reader sees it, so neither is a mark on it.
    const flags = if (try doc.get(annot, "F")) |v| v.asInt() orelse 0 else 0;
    if (flags & (1 << 1) != 0 or flags & (1 << 5) != 0) return null;

    const subtype = (try doc.get(annot, "Subtype") orelse return null).asName() orelse return null;
    const markups = [_]struct { []const u8, Kind }{
        .{ "Highlight", .highlight },
        .{ "Underline", .underline },
        .{ "StrikeOut", .strikeout },
        .{ "Squiggly", .squiggly },
    };
    for (markups) |m| {
        if (std.mem.eql(u8, subtype, m[0])) return m[1];
    }
    if (std.mem.eql(u8, subtype, "Ink")) return .ink;
    if (std.mem.eql(u8, subtype, "Line")) {
        return if (annot.get("QuadPoints") != null) .arrow else null;
    }
    if (!std.mem.eql(u8, subtype, "Text")) return null;

    // A note is a comment when it answers something the reader takes.
    // `/RT /Group` is not an answer: it makes two annotations one, which
    // the reader has no way to show.
    if (try doc.get(annot, "RT")) |rt| {
        if (rt.isName("Group")) return null;
    }
    if (depth == max_hops) return null;
    const parent = (try doc.get(annot, "IRT") orelse return null).asDict() orelse return null;
    return if (try roleOf(doc, parent, depth + 1) != null) .reply else null;
}

/// The object number a reference names, or zero for anything else.
fn refNumber(v: ?Object) u32 {
    const ref = (v orelse return 0).asRef() orelse return 0;
    return ref.num;
}

fn indexOf(numbers: []const u32, num: u32) ?usize {
    if (num == 0) return null;
    return std.mem.indexOfScalar(u32, numbers, num);
}

/// A string entry's bytes, or empty. A reference that will not resolve is
/// read as no string: a note with an unreadable name is still a note.
fn stringOf(doc: *Document, dict: Dict, key: []const u8) []const u8 {
    const v = (doc.get(dict, key) catch return "") orelse return "";
    return v.asString() orelse "";
}

fn numbersOf(doc: *Document, dict: Dict, key: []const u8) []const Object {
    const v = (doc.get(dict, key) catch return &.{}) orelse return &.{};
    return v.asArray() orelse &.{};
}

fn numberAt(doc: *Document, list: []const Object, i: usize) ?f64 {
    const v = doc.resolve(list[i]) catch return null;
    const n = v.asNumber() orelse return null;
    return if (std.math.isFinite(n)) n else null;
}

fn place(base: Matrix, x: f64, y: f64) Point {
    const p = base.apply(x, y);
    return .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]) };
}

/// One box a quadrilateral, bounding its four corners.
///
/// Bounding rather than reading two corners, because the standard and the
/// programs disagree about their order: §12.5.6.10 says counter-clockwise
/// and Acrobat writes top-left, top-right, bottom-left, bottom-right. The
/// box is the same either way, and a turned page turns them all.
fn linesOf(arena: Allocator, doc: *Document, dict: Dict, base: Matrix) Error![]const Bounds {
    var out: std.ArrayList(Bounds) = .empty;
    const quads = numbersOf(doc, dict, "QuadPoints");
    var q: usize = 0;
    while (q + 8 <= quads.len and out.items.len < max_quads) : (q += 8) {
        var box: Bounds = .empty;
        for (0..4) |corner| {
            const x = numberAt(doc, quads, q + corner * 2) orelse break;
            const y = numberAt(doc, quads, q + corner * 2 + 1) orelse break;
            box = box.add(place(base, x, y));
        } else if (!box.isEmpty()) try out.append(arena, box);
    }
    if (out.items.len != 0) return out.items;

    // No quadrilaterals, or none that read: the rectangle is the one box the
    // annotation is sure to have.
    const rect = numbersOf(doc, dict, "Rect");
    if (rect.len < 4) return &.{};
    var box: Bounds = .empty;
    for ([_][2]usize{ .{ 0, 1 }, .{ 2, 1 }, .{ 2, 3 }, .{ 0, 3 } }) |c| {
        const x = numberAt(doc, rect, c[0]) orelse return &.{};
        const y = numberAt(doc, rect, c[1]) orelse return &.{};
        box = box.add(place(base, x, y));
    }
    try out.append(arena, box);
    return out.items;
}

fn pathsOf(arena: Allocator, doc: *Document, dict: Dict, base: Matrix) Error![]const []const Point {
    var out: std.ArrayList([]const Point) = .empty;
    var budget: usize = max_points;
    for (numbersOf(doc, dict, "InkList")) |raw| {
        const list = (doc.resolve(raw) catch continue).asArray() orelse continue;
        var path: std.ArrayList(Point) = .empty;
        var i: usize = 0;
        while (i + 2 <= list.len and budget != 0) : (i += 2) {
            const x = numberAt(doc, list, i) orelse continue;
            const y = numberAt(doc, list, i + 1) orelse continue;
            try path.append(arena, place(base, x, y));
            budget -= 1;
        }
        if (path.items.len != 0) try out.append(arena, path.items);
    }
    return out.items;
}

/// `/C` (§12.5.2): none, a grey, an RGB or a CMYK, by how many numbers.
fn colorOf(doc: *Document, dict: Dict) ?Color {
    const c = numbersOf(doc, dict, "C");
    var v: [4]f32 = @splat(0);
    if (c.len != 1 and c.len != 3 and c.len != 4) return null;
    for (c, 0..) |_, i| v[i] = @floatCast(std.math.clamp(numberAt(doc, c, i) orelse return null, 0, 1));
    return switch (c.len) {
        1 => .{ .r = v[0], .g = v[0], .b = v[0] },
        3 => .{ .r = v[0], .g = v[1], .b = v[2] },
        // The naive conversion, as for a CMYK fill with no profile: the
        // colour is a swatch to recognise, not a proof to print.
        else => .{ .r = (1 - v[0]) * (1 - v[3]), .g = (1 - v[1]) * (1 - v[3]), .b = (1 - v[2]) * (1 - v[3]) },
    };
}

/// `/BS /W`, else `/Border`'s third number, else one point: §12.5.4's
/// default for both.
fn widthOf(doc: *Document, dict: Dict) f32 {
    const bs = (doc.get(dict, "BS") catch null) orelse Object.null_object;
    if (bs.asDict()) |style| {
        const w = (doc.get(style, "W") catch null) orelse Object.null_object;
        if (w.asNumber()) |n| return @floatCast(@max(n, 0));
    }
    const border = numbersOf(doc, dict, "Border");
    if (border.len >= 3) {
        if (numberAt(doc, border, 2)) |n| return @floatCast(@max(n, 0));
    }
    return 1;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const pages = @import("pages.zig");

/// A one-page document with `page_extra` on the page and `objects` after
/// it. `startxref 0` sends the open through reconstruction, which finds
/// every object by its header, so no offsets are counted by hand.
fn openWith(page_extra: []const u8, objects: []const u8) !Document {
    const src = try std.fmt.allocPrint(testing.allocator,
        \\%PDF-1.7
        \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        \\2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        \\3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] {s} >> endobj
        \\{s}
        \\trailer << /Root 1 0 R /Size 60 >>
        \\startxref 0
        \\%%EOF
        \\
    , .{ page_extra, objects });
    return Document.open(testing.allocator, src);
}

fn readOnly(doc: *Document, arena: Allocator) ![]const Annot {
    const list = try pages.all(doc);
    return read(arena, doc, list[0]);
}

fn expectBox(want: [4]f32, got: Bounds) !void {
    try testing.expectApproxEqAbs(want[0], got.min_x, 1e-3);
    try testing.expectApproxEqAbs(want[1], got.min_y, 1e-3);
    try testing.expectApproxEqAbs(want[2], got.max_x, 1e-3);
    try testing.expectApproxEqAbs(want[3], got.max_y, 1e-3);
}

test "a highlight is a box a line, whichever order its corners come in" {
    // Two lines as Acrobat writes them -- top-left, top-right, bottom-left,
    // bottom-right -- and a third in the standard's counter-clockwise order.
    var doc = try openWith("/Annots [30 0 R]",
        \\30 0 obj << /Type /Annot /Subtype /Highlight /Rect [87 521 273 570]
        \\  /NM (305e35fa-f306) /C [1.0 0.75 0.0] /Contents <FEFF00680069>
        \\  /QuadPoints [134.9 569.4 272.4 569.4 134.9 557.4 272.4 557.4
        \\               87.8 557.4 272.1 557.4 87.8 545.4 272.1 545.4
        \\               87.8 533.5 87.8 521.5 125.7 521.5 125.7 533.5] >> endobj
    );
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try readOnly(&doc, arena.allocator());
    try testing.expectEqual(@as(usize, 1), got.len);
    const h = got[0];
    try testing.expectEqual(Kind.highlight, h.kind);
    try testing.expectEqualStrings("305e35fa-f306", h.name);
    try testing.expectEqualStrings("hi", h.text);
    try testing.expectEqual(@as(usize, 3), h.lines.len);
    try expectBox(.{ 134.9, 557.4, 272.4, 569.4 }, h.lines[0]);
    try expectBox(.{ 87.8, 545.4, 272.1, 557.4 }, h.lines[1]);
    try expectBox(.{ 87.8, 521.5, 125.7, 533.5 }, h.lines[2]);
    try testing.expectApproxEqAbs(@as(f32, 0.75), h.color.?.g, 1e-6);
}

test "a markup with no quadrilaterals is its rectangle, and the styles read by name" {
    var doc = try openWith("/Annots [30 0 R 31 0 R 32 0 R]",
        \\30 0 obj << /Subtype /Underline /Rect [10 20 110 32] >> endobj
        \\31 0 obj << /Subtype /StrikeOut /Rect [10 40 110 52] /C [] >> endobj
        \\32 0 obj << /Subtype /Squiggly /Rect [10 60 110 72] /C [0.5] >> endobj
    );
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try readOnly(&doc, arena.allocator());
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Kind.underline, got[0].kind);
    try testing.expectEqual(Kind.strikeout, got[1].kind);
    try testing.expectEqual(Kind.squiggly, got[2].kind);
    try expectBox(.{ 10, 20, 110, 32 }, got[0].lines[0]);
    // An empty `/C` is no colour, not black.
    try testing.expect(got[1].color == null);
    try testing.expectApproxEqAbs(@as(f32, 0.5), got[2].color.?.b, 1e-6);
}

test "ink is a polyline a path, at its pen's width" {
    var doc = try openWith("/Annots [30 0 R 31 0 R]",
        \\30 0 obj << /Subtype /Ink /Rect [0 0 100 100] /BS << /W 2.5 >>
        \\  /InkList [[10 10 20 20 30 10] [50 50 60 60]] >> endobj
        \\31 0 obj << /Subtype /Ink /Rect [0 0 100 100] /Border [0 0 4]
        \\  /InkList [[1 2 3 4]] >> endobj
    );
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try readOnly(&doc, arena.allocator());
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(Kind.ink, got[0].kind);
    try testing.expectEqual(@as(usize, 2), got[0].paths.len);
    try testing.expectEqual(@as(usize, 3), got[0].paths[0].len);
    try testing.expectEqual(Point{ .x = 30, .y = 10 }, got[0].paths[0][2]);
    try testing.expectEqual(@as(f32, 2.5), got[0].width);
    try testing.expectEqual(@as(f32, 4), got[1].width);
}

test "a reply is a comment on the first annotation of its thread" {
    // 31 answers the highlight and 32 answers 31: both are about the words
    // 30 marks. 33 groups itself with the highlight, 34 is a note on its
    // own, 35 is hidden and 36 is somebody's line drawing: none is read.
    var doc = try openWith("/Annots [32 0 R 30 0 R 31 0 R 33 0 R 34 0 R 35 0 R 36 0 R 37 0 R]",
        \\30 0 obj << /Subtype /Highlight /Rect [10 10 50 20] /NM (a) >> endobj
        \\31 0 obj << /Subtype /Text /Rect [10 10 30 30] /IRT 30 0 R /NM (b) /Contents (first) >> endobj
        \\32 0 obj << /Subtype /Text /Rect [10 10 30 30] /IRT 31 0 R /Contents (second) >> endobj
        \\33 0 obj << /Subtype /Text /Rect [10 10 30 30] /IRT 30 0 R /RT /Group >> endobj
        \\34 0 obj << /Subtype /Text /Rect [10 10 30 30] /Contents (alone) >> endobj
        \\35 0 obj << /Subtype /Highlight /Rect [10 10 50 20] /F 2 >> endobj
        \\36 0 obj << /Subtype /Line /Rect [0 0 90 90] /L [0 0 90 90] >> endobj
        \\37 0 obj << /Subtype /Line /Rect [0 0 90 90] /L [0 0 90 90]
        \\  /QuadPoints [100 120 200 120 100 108 200 108] >> endobj
    );
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try readOnly(&doc, arena.allocator());
    try testing.expectEqual(@as(usize, 4), got.len);
    // In `/Annots` order, which put the second reply first.
    try testing.expectEqual(Kind.reply, got[0].kind);
    try testing.expectEqualStrings("second", got[0].text);
    try testing.expectEqual(@as(?u32, 1), got[0].thread);
    try testing.expectEqual(Kind.highlight, got[1].kind);
    try testing.expectEqual(@as(?u32, 1), got[2].thread);
    try testing.expectEqualStrings("b", got[2].name);
    try testing.expectEqual(Kind.arrow, got[3].kind);
    try expectBox(.{ 100, 108, 200, 120 }, got[3].lines[0]);
}

test "the interpreter leaves out exactly what is read" {
    // `taken` and `read` are the two halves of one decision; an annotation
    // they disagree about is on screen twice or not at all.
    var doc = try openWith("/Annots [30 0 R 31 0 R 32 0 R 33 0 R 34 0 R 35 0 R]",
        \\30 0 obj << /Subtype /Highlight /Rect [10 10 50 20] >> endobj
        \\31 0 obj << /Subtype /Text /Rect [10 10 30 30] /IRT 30 0 R >> endobj
        \\32 0 obj << /Subtype /Text /Rect [10 10 30 30] /IRT 33 0 R >> endobj
        \\33 0 obj << /Subtype /Link /Rect [10 10 30 30] >> endobj
        \\34 0 obj << /Subtype /Ink /Rect [0 0 9 9] /InkList [[1 1 2 2]] /F 32 >> endobj
        \\35 0 obj << /Subtype /Squiggly /Rect [0 0 9 9] /F 4 >> endobj
    );
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try readOnly(&doc, arena.allocator());
    const list = try pages.all(&doc);
    var took: usize = 0;
    for (try list[0].annotations(&doc)) |raw| {
        if (taken(&doc, (try doc.resolve(raw)).asDict().?)) took += 1;
    }
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(got.len, took);
}

test "marks are read into the page as displayed, crop box and rotation applied" {
    // A quarter turn clockwise on a crop box that starts at (100, 50): the
    // box's bottom-left corner is the origin before the turn, and the turn
    // puts the file's x up the screen.
    var doc = try openWith("/CropBox [100 50 500 750] /Rotate 90 /Annots [30 0 R]",
        \\30 0 obj << /Subtype /Highlight /Rect [0 0 1 1]
        \\  /QuadPoints [110 70 210 70 110 60 210 60] >> endobj
    );
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try readOnly(&doc, arena.allocator());
    // In the crop box: x 10..110, y 10..20. Turned: x' = y, y' = 400 - x.
    try expectBox(.{ 10, 290, 20, 390 }, got[0].lines[0]);
}
