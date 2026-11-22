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
//!
//! ## Writing
//!
//! `write` is the other half: an `Annot` in the same space made into the
//! annotation a save appends, one an anchor however many lines it covers,
//! with the appearance other readers draw -- they draw `/AP` and nothing
//! else. `Appearances` is why most of those cost a name and not a stream,
//! and `attach` puts what was written on its page.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Document = @import("Document.zig");
const Page = @import("Page.zig");
const Writer = @import("Writer.zig");
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
const Ref = object.Ref;

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
    /// A box a line, for a markup or an arrow. For a reply being written,
    /// the first line of what it answers, where its icon goes.
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
    /// The object it is, or null for one written straight into `/Annots`.
    /// What a save writes over to change it, keeping what answers it.
    ref: ?Ref = null,
};

/// What an annotation looks like, as a number: its kind, its lines or its
/// paths to a hundredth of a point, which is what `write` keeps, and its
/// text. The identity of one with no `/NM`, or one its page repeats, by
/// which a name the reader gives it is found again.
///
/// Not its object number: a program that rewrites the file renumbers every
/// object and leaves the drawing where it was. Two annotations of one
/// shape on one page are one, which is what they look like.
pub fn shapeOf(a: Annot) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(&.{@intFromEnum(a.kind)});
    for (a.lines) |box| {
        for ([_]f32{ box.min_x, box.min_y, box.max_x, box.max_y }) |v| hashHundredths(&h, v);
    }
    for (a.paths) |path| {
        h.update(&.{0xff});
        for (path) |p| {
            hashHundredths(&h, p.x);
            hashHundredths(&h, p.y);
        }
    }
    h.update(a.text);
    return h.final();
}

fn hashHundredths(h: *std.hash.Wyhash, v: f32) void {
    const n: i64 = @intFromFloat(std.math.clamp(@round(@as(f64, v) * 100), -1e15, 1e15));
    h.update(std.mem.asBytes(&n));
}

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

        var a: Annot = .{ .kind = kind, .ref = raw.asRef() };
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

// -- writing ----------------------------------------------------------------

/// What `write` is told beside the annotation: who wrote it, when, and what
/// a reply answers. Another reader's comment pane lists comments by the
/// first two.
pub const Written = struct {
    /// `/T`, the `author` setting. Left out when empty.
    author: []const u8 = "",
    /// `/M`, in seconds since 1970, UTC. Left out when zero.
    when: i64 = 0,
    /// `/IRT`: for a reply, the annotation it answers.
    answers: ?Ref = null,
    /// The object to write it as: one the file has, changed in place so
    /// that its replies' `/IRT` and its page's `/Annots` still name it.
    /// Null for a new one.
    into: ?Ref = null,
    /// For an arrow, where the words of its first line begin, in the same
    /// space: the arrow stops short of them rather than of the mark, which
    /// may begin mid-line. Null where the words are not known.
    start: ?f32 = null,
};

pub const WriteError = Writer.Error || error{
    /// A markup or an arrow with no line, ink with no path, or a reply with
    /// no line to put its icon at.
    NothingToDraw,
};

/// The colour of an annotation that was given none: the reader's default
/// highlight.
const fallback: Color = .{ .r = 1, .g = 0.9, .b = 0.2 };

/// The appearance streams a file's annotations share (§12.5.5).
///
/// Most annotations draw the same thing. A highlight of one line is a
/// rectangle of one colour wherever it is, and a reader stretches an
/// appearance's box to the annotation's `/Rect`, so one form a colour serves
/// every such highlight in the file; the same goes for an underline, a
/// strike-through, an arrow and a reply's note icon. What differs every time
/// -- several lines, a squiggle, ink -- gets a form of its own, and every
/// form that blends names the one `/Resources`.
///
/// For one save. A save that fails leaves this naming objects that were
/// never written, so the next one starts again from `adopt`.
pub const Appearances = struct {
    /// The `/Resources` with the multiply blend, once one is written or found.
    resources: ?Ref = null,
    /// By `keyOf`.
    forms: std.AutoHashMapUnmanaged(u32, Ref) = .empty,

    pub fn deinit(ap: *Appearances, gpa: Allocator) void {
        ap.forms.deinit(gpa);
        ap.* = undefined;
    }

    /// Takes the shared forms `p`'s annotations already name, so that a save
    /// names them too rather than writing them again.
    ///
    /// Only a form whose bytes are exactly what `drawShared` makes for the
    /// annotation's shape, colour and turn. That is the check stretching
    /// needs: a form another program wrote may have the same box and draw
    /// anything in it, and stretched over somebody else's words it would be
    /// a different drawing.
    pub fn adopt(ap: *Appearances, gpa: Allocator, doc: *Document, p: Page) Error!void {
        const listed = p.annotations(doc) catch return;
        for (listed) |raw| {
            ap.adoptOne(gpa, doc, raw) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
        }
    }

    fn adoptOne(ap: *Appearances, gpa: Allocator, doc: *Document, raw: Object) Error!void {
        const annot = (try doc.resolve(raw)).asDict() orelse return;
        const subtype = (try doc.get(annot, "Subtype") orelse return).asName() orelse return;
        const shape = Shape.of(subtype) orelse return;
        const appearance = (try doc.get(annot, "AP") orelse return).asDict() orelse return;
        const ref = (appearance.get("N") orelse return).asRef() orelse return;
        const stream = (try doc.fetch(ref)).asStream() orelse return;

        // The box first: it turns away nearly every form another program
        // wrote before its stream is decoded.
        const box = numbersOf(doc, stream.dict, "BBox");
        const size = shape.size();
        if (box.len != 4) return;
        for (box, [4]f64{ 0, 0, size[0], size[1] }, 0..) |_, want, i| {
            if (numberAt(doc, box, i) != want) return;
        }
        const turn = turnIn(doc, stream.dict) orelse return;
        if (turn != .none and !shape.turns()) return;
        const rgb = rgbOf(colorOf(doc, annot) orelse return);

        var c: Content = .{ .out = .init(gpa) };
        defer c.out.deinit();
        drawShared(&c, shape, rgb) catch return error.OutOfMemory;
        if (!std.mem.eql(u8, (try doc.streamData(stream)).data, c.out.written())) return;

        const gop = try ap.forms.getOrPut(gpa, keyOf(shape, rgb, turn));
        if (!gop.found_existing) gop.value_ptr.* = ref;
        if (shape == .highlight and ap.resources == null) {
            if (stream.dict.get("Resources")) |r| ap.resources = r.asRef();
        }
    }

    /// The shared form for `shape` in `rgb`, written the first time it is
    /// asked for.
    fn form(ap: *Appearances, w: *Writer, shape: Shape, rgb: Rgb, turn: Page.Rotation) WriteError!Ref {
        const t: Page.Rotation = if (shape.turns()) turn else .none;
        const gop = try ap.forms.getOrPut(w.gpa, keyOf(shape, rgb, t));
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer ap.forms.removeByPtr(gop.key_ptr);

        const a = w.allocator();
        var c: Content = .{ .out = .init(a) };
        try drawShared(&c, shape, rgb);
        const size = shape.size();
        const ref = try ap.formOf(w, t, .fromRect(0, 0, size[0], size[1]), c.out.written(), shape == .highlight);
        gop.value_ptr.* = ref;
        return ref;
    }

    /// A form drawing `drawing` in `box`, both in the reader's space and
    /// turned into the file's by its `/Matrix`. The fit to `/Rect` (§12.5.5)
    /// puts it in place; the turn is what keeps an underline under its
    /// words on a turned page.
    fn formOf(ap: *Appearances, w: *Writer, turn: Page.Rotation, box: Bounds, drawing: []const u8, blends: bool) WriteError!Ref {
        const a = w.allocator();
        var dict: Dict = .empty;
        try dict.put(a, "Subtype", .{ .name = "Form" });
        try dict.put(a, "BBox", .{ .array = try boxOf(a, box) });
        if (turn != .none) {
            const m = turnMatrix(turn);
            const matrix = try a.alloc(Object, 6);
            for (matrix, [6]i8{ m[0], m[1], m[2], m[3], 0, 0 }) |*slot, v| slot.* = .{ .integer = v };
            try dict.put(a, "Matrix", .{ .array = matrix });
        }
        if (blends) try dict.put(a, "Resources", .{ .ref = try ap.blend(w) });
        const ref: Ref = .{ .num = w.fresh(), .gen = 0 };
        try w.putContent(ref.num, dict, drawing);
        return ref;
    }

    /// The `/Resources` every highlight's form names: the multiply blend,
    /// under which a wash darkens the paper and leaves black type black, as
    /// a highlighter does.
    fn blend(ap: *Appearances, w: *Writer) WriteError!Ref {
        if (ap.resources) |r| return r;
        const a = w.allocator();
        var mode: Dict = .empty;
        try mode.put(a, "BM", .{ .name = "Multiply" });
        var states: Dict = .empty;
        try states.put(a, "M", .{ .dict = mode });
        var resources: Dict = .empty;
        try resources.put(a, "ExtGState", .{ .dict = states });
        const ref: Ref = .{ .num = w.fresh(), .gen = 0 };
        try w.put(ref.num, .{ .dict = resources });
        ap.resources = ref;
        return ref;
    }
};

/// The drawings `Appearances` shares, one form a colour and a turn.
const Shape = enum(u8) {
    highlight,
    underline,
    strikeout,
    arrow,
    note,

    fn of(subtype: []const u8) ?Shape {
        const names = [_]struct { []const u8, Shape }{
            .{ "Highlight", .highlight }, .{ "Underline", .underline },
            .{ "StrikeOut", .strikeout }, .{ "Line", .arrow },
            .{ "Text", .note },
        };
        for (names) |n| {
            if (std.mem.eql(u8, subtype, n[0])) return n[1];
        }
        return null;
    }

    /// The form's box. What is drawn in it keeps its proportions to the box,
    /// so stretched to any `/Rect` it is what fenrir draws at that size: an
    /// underline a twelfth of its line's height, an arrow as tall as its
    /// head is wide.
    fn size(s: Shape) [2]f32 {
        return switch (s) {
            .highlight => .{ 1, 1 },
            .underline, .strikeout => .{ 12, 12 },
            .arrow => .{ 17, 6 },
            .note => .{ 14, 14 },
        };
    }

    /// Whether the drawing has a way up. A wash does not; nor does the note
    /// icon, which §12.5.6.4 keeps upright on a turned page. An underline
    /// does, or on a turned page it runs down the side of its words.
    fn turns(s: Shape) bool {
        return s == .underline or s == .strikeout or s == .arrow;
    }
};

/// A colour as the library holds it, a byte a channel, so that a colour
/// read back from `/C` is the one that was written.
const Rgb = [3]u8;

fn rgbOf(c: Color) Rgb {
    var out: Rgb = undefined;
    for (&out, [3]f32{ c.r, c.g, c.b }) |*slot, v| slot.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
    return out;
}

fn keyOf(shape: Shape, rgb: Rgb, turn: Page.Rotation) u32 {
    return @as(u32, @intFromEnum(shape)) << 26 | @as(u32, turn.degrees() / 90) << 24 |
        @as(u32, rgb[0]) << 16 | @as(u32, rgb[1]) << 8 | rgb[2];
}

/// `rgb` at `k` of its strength over white: what a wash at that opacity
/// leaves on paper, which under multiply is also what it leaves over
/// anything else on the page.
fn wash(rgb: Rgb, k: f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (&out, rgb) |*slot, v| slot.* = 1 - k * (1 - @as(f64, @floatFromInt(v)) / 255);
    return out;
}

/// `rgb` darkened to `k`, as the reader darkens an arrow to read on paper.
fn shade(rgb: Rgb, k: f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (&out, rgb) |*slot, v| slot.* = k * @as(f64, @floatFromInt(v)) / 255;
    return out;
}

/// The reader washes a highlight over the page at this opacity.
const wash_strength = 0.35;

/// What a shared form draws, in its box. `adopt` compares a form in the file
/// against these bytes, so they are made in this one place.
fn drawShared(c: *Content, shape: Shape, rgb: Rgb) Io.Writer.Error!void {
    switch (shape) {
        .highlight => {
            try c.op("/M gs");
            try c.fill(wash(rgb, wash_strength));
            try c.op("0 0 1 1 re f");
        },
        .underline => {
            try c.fill(shade(rgb, 1));
            try c.op("0 0 12 1 re f");
        },
        .strikeout => {
            try c.fill(shade(rgb, 1));
            try c.op("0 5.5 12 1 re f");
        },
        // The reader's arrow, ten units to the line's height: a shaft of
        // twelve and a head of five, three either side of the middle.
        .arrow => {
            try c.fill(shade(rgb, 0.75));
            try c.op("0 2.5 12.5 1 re f 12 0 m 17 3 l 12 6 l f");
        },
        // A speech bubble with two lines of writing in it.
        .note => {
            try c.fill(shade(rgb, 1));
            try c.stroke(shade(rgb, 0.6));
            try c.op("1 13 m 13 13 l 13 4 l 7 4 l 3 1 l 4 4 l 1 4 l h B 3.5 10 m 10.5 10 l 3.5 7 m 8.5 7 l S");
        },
    }
}

/// A content stream being written: tokens a space apart, and numbers in the
/// fewest characters that hold them.
const Content = struct {
    out: Io.Writer.Allocating,

    fn gap(c: *Content) Io.Writer.Error!void {
        if (c.out.written().len != 0) try c.out.writer.writeByte(' ');
    }

    fn op(c: *Content, text: []const u8) Io.Writer.Error!void {
        try c.gap();
        try c.out.writer.writeAll(text);
    }

    /// A coordinate, to a hundredth of a point.
    fn at(c: *Content, v: f64) Io.Writer.Error!void {
        try c.gap();
        try decimal(&c.out.writer, v, 100);
    }

    fn rect(c: *Content, b: Bounds, y: f32, height: f32) Io.Writer.Error!void {
        for ([4]f32{ b.min_x, y, b.width(), height }) |v| try c.at(v);
        try c.op("re");
    }

    fn fill(c: *Content, rgb: [3]f64) Io.Writer.Error!void {
        try c.color(rgb);
        try c.op("rg");
    }

    fn stroke(c: *Content, rgb: [3]f64) Io.Writer.Error!void {
        try c.color(rgb);
        try c.op("RG");
    }

    /// To a thousandth, which tells all 256 levels of a byte apart.
    fn color(c: *Content, rgb: [3]f64) Io.Writer.Error!void {
        for (rgb) |v| {
            try c.gap();
            try decimal(&c.out.writer, v, 1000);
        }
    }
};

/// `v` to `1/per`, in the fewest characters: `12`, `20.5`, `.25`, `-.5`.
fn decimal(out: *Io.Writer, v: f64, per: f64) Io.Writer.Error!void {
    var r = @round(std.math.clamp(v, -1e9, 1e9) * per) / per;
    // No `-0`, and nothing that is not a number.
    if (r == 0 or !std.math.isFinite(r)) r = 0;
    var buf: [48]u8 = undefined;
    var text = std.fmt.bufPrint(&buf, "{d}", .{@abs(r)}) catch unreachable;
    // §7.3.3 lets a number leave out the zero before its point.
    if (std.mem.startsWith(u8, text, "0.")) text = text[1..];
    if (r < 0) try out.writeByte('-');
    try out.writeAll(text);
}

/// The turn that takes the reader's space to the file's, without the shift:
/// `a b c d` of `pageMatrix` undone. Whole numbers, so a form's `/Matrix`
/// says `0 1 -1 0` and not `-0`.
fn turnMatrix(turn: Page.Rotation) [4]i8 {
    return switch (turn) {
        .none => .{ 1, 0, 0, 1 },
        .cw90 => .{ 0, 1, -1, 0 },
        .cw180 => .{ -1, 0, 0, -1 },
        .cw270 => .{ 0, -1, 1, 0 },
    };
}

/// The turn a form's `/Matrix` gives, or null for one that is not a turn.
fn turnIn(doc: *Document, dict: Dict) ?Page.Rotation {
    const m = numbersOf(doc, dict, "Matrix");
    if (m.len == 0) return .none;
    if (m.len != 6) return null;
    for ([_]Page.Rotation{ .none, .cw90, .cw180, .cw270 }) |turn| {
        const want = turnMatrix(turn);
        for (0..6) |i| {
            const v: f64 = if (i < 4) @floatFromInt(want[i]) else 0;
            if (numberAt(doc, m, i) != v) break;
        } else return turn;
    }
    return null;
}

/// From the reader's space back to the file's: `pageMatrix` undone.
fn backOf(p: Page) Matrix {
    return content.pageMatrix(p, p.rotate).invert() orelse .identity;
}

fn boxOf(a: Allocator, b: Bounds) Allocator.Error![]Object {
    const out = try a.alloc(Object, 4);
    for (out, [4]f32{ b.min_x, b.min_y, b.max_x, b.max_y }) |*slot, v| slot.* = Writer.hundredths(v);
    return out;
}

/// A box in the reader's space as a `/Rect` in the file's: its corners taken
/// back and bounded.
fn rectOf(a: Allocator, back: Matrix, b: Bounds) Allocator.Error![]Object {
    var user: Bounds = .empty;
    for ([4][2]f32{ .{ b.min_x, b.min_y }, .{ b.max_x, b.min_y }, .{ b.max_x, b.max_y }, .{ b.min_x, b.max_y } }) |c| {
        user = user.add(place(back, c[0], c[1]));
    }
    return boxOf(a, user);
}

/// `/QuadPoints`, in Acrobat's order -- top-left, top-right, bottom-left,
/// bottom-right of the words as they read -- because that is what other
/// readers draw from, whatever §12.5.6.10 says; `linesOf` reads either.
fn quadsOf(a: Allocator, back: Matrix, lines: []const Bounds) Allocator.Error![]Object {
    const out = try a.alloc(Object, lines.len * 8);
    for (lines, 0..) |l, i| {
        const corners = [4][2]f32{ .{ l.min_x, l.max_y }, .{ l.max_x, l.max_y }, .{ l.min_x, l.min_y }, .{ l.max_x, l.min_y } };
        for (corners, 0..) |c, j| {
            const p = back.apply(c[0], c[1]);
            out[i * 8 + j * 2] = Writer.hundredths(p[0]);
            out[i * 8 + j * 2 + 1] = Writer.hundredths(p[1]);
        }
    }
    return out;
}

fn colorObjects(a: Allocator, rgb: Rgb) Allocator.Error![]Object {
    const out = try a.alloc(Object, 3);
    for (out, rgb) |*slot, v| {
        const r = @round(@as(f64, @floatFromInt(v)) / 255 * 1000) / 1000;
        slot.* = if (r == 0 or r == 1) .{ .integer = @intFromFloat(r) } else .{ .real = r };
    }
    return out;
}

/// `/M` (§7.9.4): the moment in UTC, to the second.
pub fn dateOf(a: Allocator, seconds: i64) Allocator.Error![]const u8 {
    const at: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const year = at.getEpochDay().calculateYearDay();
    const day = year.calculateMonthDay();
    const time = at.getDaySeconds();
    return std.fmt.allocPrint(a, "D:{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        year.year,              day.month.numeric(),       day.day_index + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    });
}

/// The reader's arrow at the first line of what it points at: a quarter of
/// the line's height short of the words, as long as 1.7 heights and as tall
/// as 0.6 of one. See `drawShared`.
fn arrowBox(first: Bounds, start: ?f32) Bounds {
    const h = @max(first.height(), 1);
    const tip = @min(start orelse first.min_x, first.min_x) - h * 0.25;
    const mid = (first.min_y + first.max_y) * 0.5;
    return .fromRect(tip - h * 1.7, mid - h * 0.3, tip, mid + h * 0.3);
}

/// Where a reply's icon goes: over the top-right corner of the first line of
/// what it answers, where the reader puts a comment's tab.
fn noteBox(first: Bounds) Bounds {
    return .fromRect(first.max_x - 7, first.max_y - 7, first.max_x + 7, first.max_y + 7);
}

/// A markup of several lines, or a squiggle of any, drawn line by line as
/// the shared forms draw one; returns the box it covers.
fn drawMarkup(c: *Content, kind: Kind, lines: []const Bounds, rgb: Rgb) Io.Writer.Error!Bounds {
    var box: Bounds = .empty;
    for (lines) |l| box = box.unionWith(l);
    switch (kind) {
        .highlight => {
            try c.op("/M gs");
            try c.fill(wash(rgb, wash_strength));
            for (lines) |l| try c.rect(l, l.min_y, l.height());
            try c.op("f");
        },
        .underline, .strikeout => {
            try c.fill(shade(rgb, 1));
            for (lines) |l| {
                const t = l.height() / 12;
                try c.rect(l, if (kind == .underline) l.min_y else (l.min_y + l.max_y - t) * 0.5, t);
            }
            try c.op("f");
        },
        .squiggly => {
            try c.stroke(shade(rgb, 1));
            try c.op("1 j");
            for (lines) |l| try zigzag(c, l);
        },
        .ink, .arrow, .reply => unreachable,
    }
    return box;
}

/// A ceiling on one squiggle's corners: a line a few metres long.
const max_corners = 1 << 12;

/// A squiggle along the foot of `l`, as a zigzag where the reader draws round
/// waves: the same pitch and height, in a tenth of the bytes, and how Acrobat
/// draws one. Drawn from the line's own corner, so that lines of one height
/// are the same bytes and zlib takes the second for nothing.
fn zigzag(c: *Content, l: Bounds) Io.Writer.Error!void {
    const t = l.height() / 12;
    const step = 2.5 * t;
    if (!(step > 0)) return;
    const low = t * 0.5;
    const high = low + step;
    try c.op("q 1 0 0 1");
    try c.at(l.min_x);
    try c.at(l.min_y);
    try c.op("cm");
    try c.at(t);
    try c.op("w 0");
    try c.at(low);
    try c.op("m");

    const w = l.width();
    var k: u32 = 1;
    while (@as(f32, @floatFromInt(k)) * step < w and k < max_corners) : (k += 1) {
        try c.at(@as(f32, @floatFromInt(k)) * step);
        try c.at(if (k % 2 == 1) high else low);
        try c.op("l");
    }
    // The last corner short of the end: the line runs on to the end, as far
    // up or down as it has got.
    const from: f32 = if (k % 2 == 1) low else high;
    const to: f32 = if (k % 2 == 1) high else low;
    const part = (w - @as(f32, @floatFromInt(k - 1)) * step) / step;
    try c.at(w);
    try c.at(from + (to - from) * std.math.clamp(part, 0, 1));
    try c.op("l S Q");
}

/// Ink as it went, with round ends and corners like the reader's pen;
/// returns the box it covers, the pen's width included.
fn drawInk(c: *Content, paths: []const []const Point, width: f32, rgb: Rgb) Io.Writer.Error!Bounds {
    try c.stroke(shade(rgb, 1));
    try c.at(width);
    try c.op("w 1 J 1 j");
    var box: Bounds = .empty;
    for (paths) |path| {
        for (path, 0..) |p, i| {
            try c.at(p.x);
            try c.at(p.y);
            try c.op(if (i == 0) "m" else "l");
            box = box.add(p);
        }
        // A dot is a line of no length, which a round cap draws.
        if (path.len == 1) {
            try c.at(path[0].x);
            try c.at(path[0].y);
            try c.op("l");
        }
    }
    try c.op("S");
    const r = @max(width * 0.5, 0.5);
    return .fromRect(box.min_x - r, box.min_y - r, box.max_x + r, box.max_y + r);
}

/// Writes `a` as one annotation on `p`, with its appearance, and returns it
/// for `attach`. `a` is in the reader's space, as `read` returns one, and
/// `read` gives it back to a hundredth of a point.
pub fn write(w: *Writer, ap: *Appearances, p: Page, a: Annot, written: Written) WriteError!Ref {
    const arena = w.allocator();
    const back = backOf(p);
    const rgb = rgbOf(a.color orelse fallback);

    var d: Dict = .empty;
    try d.put(arena, "Subtype", .{ .name = switch (a.kind) {
        .highlight => "Highlight",
        .underline => "Underline",
        .strikeout => "StrikeOut",
        .squiggly => "Squiggly",
        .ink => "Ink",
        .arrow => "Line",
        .reply => "Text",
    } });
    // Filled in below, once the drawing says how much it covers.
    try d.put(arena, "Rect", .null);

    var c: Content = .{ .out = .init(arena) };
    const Drawn = struct { box: Bounds, form: Ref };
    const drawn: Drawn = switch (a.kind) {
        .highlight, .underline, .strikeout, .squiggly => blk: {
            if (a.lines.len == 0) return error.NothingToDraw;
            try d.put(arena, "QuadPoints", .{ .array = try quadsOf(arena, back, a.lines) });
            // A squiggle's pitch is set by its height, so how many waves fit
            // depends on how long the line is: never the same drawing twice.
            if (a.lines.len == 1 and a.kind != .squiggly) {
                const shape: Shape = switch (a.kind) {
                    .underline => .underline,
                    .strikeout => .strikeout,
                    else => .highlight,
                };
                break :blk .{ .box = a.lines[0], .form = try ap.form(w, shape, rgb, p.rotate) };
            }
            const box = try drawMarkup(&c, a.kind, a.lines, rgb);
            break :blk .{ .box = box, .form = try ap.formOf(w, p.rotate, box, c.out.written(), a.kind == .highlight) };
        },
        .arrow => blk: {
            if (a.lines.len == 0) return error.NothingToDraw;
            try d.put(arena, "QuadPoints", .{ .array = try quadsOf(arena, back, a.lines) });
            const box = arrowBox(a.lines[0], written.start);
            const mid = (box.min_y + box.max_y) * 0.5;
            const line = try arena.alloc(Object, 4);
            for ([2]f32{ box.min_x, box.max_x }, 0..) |x, i| {
                const at = back.apply(x, mid);
                line[i * 2] = Writer.hundredths(at[0]);
                line[i * 2 + 1] = Writer.hundredths(at[1]);
            }
            try d.put(arena, "L", .{ .array = line });
            // What a reader that draws a line itself is told: the head is
            // at the words' end of it.
            try d.put(arena, "LE", .{ .array = &.{ .{ .name = "None" }, .{ .name = "ClosedArrow" } } });
            break :blk .{ .box = box, .form = try ap.form(w, .arrow, rgb, p.rotate) };
        },
        .ink => blk: {
            if (a.paths.len == 0) return error.NothingToDraw;
            const list = try arena.alloc(Object, a.paths.len);
            for (list, a.paths) |*slot, path| {
                const xy = try arena.alloc(Object, path.len * 2);
                for (path, 0..) |pt, i| {
                    const at = back.apply(pt.x, pt.y);
                    xy[i * 2] = Writer.hundredths(at[0]);
                    xy[i * 2 + 1] = Writer.hundredths(at[1]);
                }
                slot.* = .{ .array = xy };
            }
            try d.put(arena, "InkList", .{ .array = list });
            var style: Dict = .empty;
            try style.put(arena, "W", Writer.hundredths(a.width));
            try d.put(arena, "BS", .{ .dict = style });
            const box = try drawInk(&c, a.paths, a.width, rgb);
            break :blk .{ .box = box, .form = try ap.formOf(w, p.rotate, box, c.out.written(), false) };
        },
        .reply => blk: {
            if (a.lines.len == 0) return error.NothingToDraw;
            break :blk .{ .box = noteBox(a.lines[0]), .form = try ap.form(w, .note, rgb, .none) };
        },
    };
    try d.put(arena, "Rect", .{ .array = try rectOf(arena, back, drawn.box) });

    try d.put(arena, "C", .{ .array = try colorObjects(arena, rgb) });
    if (a.name.len != 0) try d.put(arena, "NM", .{ .string = a.name });
    if (written.author.len != 0) try d.put(arena, "T", .{ .string = try outline.encode(arena, written.author) });
    if (written.when != 0) try d.put(arena, "M", .{ .string = try dateOf(arena, written.when) });
    if (a.text.len != 0) try d.put(arena, "Contents", .{ .string = try outline.encode(arena, a.text) });
    // Printed, as a highlighter's ink is on the paper it marks. A reply's
    // icon is the reader's furniture and stays on the screen.
    if (a.kind != .reply) try d.put(arena, "F", .{ .integer = 4 });
    if (written.answers) |r| try d.put(arena, "IRT", .{ .ref = r });
    var appearance: Dict = .empty;
    try appearance.put(arena, "N", .{ .ref = drawn.form });
    try d.put(arena, "AP", .{ .dict = appearance });

    const ref: Ref = written.into orelse .{ .num = w.fresh(), .gen = 0 };
    try w.put(ref.num, .{ .dict = d });
    return ref;
}

/// Puts `refs` on `p`'s `/Annots`, after what is there, and takes `drop`
/// off it. Once a page a save: a second call reads the list as the file
/// has it, not as the first left it.
///
/// The first time, the list becomes an object of its own and the page names
/// it, so that every later save rewrites a list a few bytes an annotation
/// long and not the page, whose dictionary can be long.
pub fn attach(w: *Writer, p: Page, refs: []const Ref, drop: []const Ref) Writer.Error!void {
    if (refs.len == 0 and drop.len == 0) return;
    const a = w.allocator();
    const old = try p.annotations(w.doc);
    var list: std.ArrayList(Object) = try .initCapacity(a, old.len + refs.len);
    for (old) |o| {
        const r = o.asRef() orelse {
            list.appendAssumeCapacity(o);
            continue;
        };
        for (drop) |d| {
            if (d.num == r.num) break;
        } else list.appendAssumeCapacity(o);
    }
    for (refs) |r| list.appendAssumeCapacity(.{ .ref = r });

    if (p.dict.get("Annots")) |held| {
        if (held.asRef()) |own| return w.put(own.num, .{ .array = list.items });
    }
    const num = w.fresh();
    try w.put(num, .{ .array = list.items });
    var page = try p.dict.clone(a);
    try page.put(a, "Annots", .{ .ref = .{ .num = num, .gen = 0 } });
    try w.put(p.ref.num, .{ .dict = page });
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

// -- tests: writing ---------------------------------------------------------

/// A file whose table is right, which `Writer` asks for: the catalog, the
/// tree, one page with `page_extra`, and `objects` numbered from 4.
fn fileWith(page_extra: []const u8, objects: []const []const u8) ![]u8 {
    const gpa = testing.allocator;
    const page = try std.fmt.allocPrint(gpa, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] {s} >>", .{page_extra});
    defer gpa.free(page);
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", page });
    try all.appendSlice(gpa, objects);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("%PDF-1.7\n");
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);
    for (all.items, 1..) |obj, num| {
        try offsets.append(gpa, out.written().len);
        try w.print("{d} 0 obj\n{s}\nendobj\n", .{ num, obj });
    }
    const at = out.written().len;
    try w.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{all.items.len + 1});
    for (offsets.items) |o| try w.print("{d:0>10} 00000 n\r\n", .{o});
    try w.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ all.items.len + 1, at });
    return out.toOwnedSlice();
}

/// The file as it is after `update` is appended to it.
fn appended(doc: *Document, update: []const u8) !Document {
    return Document.open(testing.allocator, try std.mem.concat(testing.allocator, u8, &.{ doc.bytes, update }));
}

/// Each annotation's appearance, by object number, in `/Annots` order.
fn formsOf(doc: *Document, out: []u32) !void {
    const listed = try (try pages.all(doc))[0].annotations(doc);
    for (listed, out) |raw, *slot| {
        const annot = (try doc.resolve(raw)).asDict().?;
        slot.* = (try doc.get(annot, "AP")).?.asDict().?.get("N").?.asRef().?.num;
    }
}

const yellow: Color = .{ .r = 1, .g = 0.9, .b = 0.2 };
const green: Color = .{ .r = 0.3, .g = 0.8, .b = 0.4 };

test "a line of one colour shares a form, and several lines draw their own" {
    var doc = try Document.open(testing.allocator, try fileWith("", &.{}));
    defer doc.deinit();
    const page = (try pages.all(&doc))[0];
    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    var ap: Appearances = .{};
    defer ap.deinit(testing.allocator);

    const one = [_]Bounds{.fromRect(72, 700, 300, 712)};
    const other = [_]Bounds{.fromRect(72, 680, 200, 692)};
    const two = [_]Bounds{ .fromRect(72, 660, 300, 672), .fromRect(72, 646, 150, 658) };
    const refs = [_]Ref{
        try write(&w, &ap, page, .{ .kind = .highlight, .lines = &one, .color = yellow, .name = "f1" }, .{}),
        try write(&w, &ap, page, .{ .kind = .highlight, .lines = &other, .color = yellow, .name = "f2" }, .{}),
        try write(&w, &ap, page, .{ .kind = .highlight, .lines = &one, .color = green }, .{}),
        try write(&w, &ap, page, .{ .kind = .highlight, .lines = &two, .color = yellow }, .{}),
        try write(&w, &ap, page, .{ .kind = .underline, .lines = &one, .color = yellow }, .{}),
    };
    try attach(&w, page, &refs, &.{});
    const update = try w.finish(.{});
    defer testing.allocator.free(update);

    var after = try appended(&doc, update);
    defer after.deinit();
    try testing.expect(!after.recovered);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try readOnly(&after, arena.allocator());
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqualStrings("f2", got[1].name);
    try expectBox(.{ 72, 700, 300, 712 }, got[0].lines[0]);
    try expectBox(.{ 72, 646, 150, 658 }, got[3].lines[1]);
    try testing.expectEqual(Kind.underline, got[4].kind);
    try testing.expectEqual(rgbOf(yellow), rgbOf(got[0].color.?));
    try testing.expectEqual(rgbOf(green), rgbOf(got[2].color.?));

    // Two yellow lines name one form. Green, two lines and an underline
    // are three more.
    var forms: [5]u32 = undefined;
    try formsOf(&after, &forms);
    try testing.expectEqual(forms[0], forms[1]);
    for (forms[2..], 2..) |f, i| {
        for (forms[0..i]) |before| try testing.expect(f != before);
    }
}

test "what is written is drawn under its words, the right way up on a turned page" {
    var doc = try Document.open(testing.allocator, try fileWith("/CropBox [100 50 500 750] /Rotate 90", &.{}));
    defer doc.deinit();
    const page = (try pages.all(&doc))[0];
    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    var ap: Appearances = .{};
    defer ap.deinit(testing.allocator);

    // Twelve points tall, so the underline is one.
    const line = [_]Bounds{.fromRect(20, 300, 140, 312)};
    const ref = try write(&w, &ap, page, .{ .kind = .underline, .lines = &line }, .{});
    try attach(&w, page, &.{ref}, &.{});
    const update = try w.finish(.{});
    defer testing.allocator.free(update);

    var after = try appended(&doc, update);
    defer after.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectBox(.{ 20, 300, 140, 312 }, (try readOnly(&after, arena.allocator()))[0].lines[0]);

    const turned = (try pages.all(&after))[0];
    var drawn = try content.page(testing.allocator, &after, turned, .{});
    defer drawn.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), drawn.diagnostics.annotations_drawn);
    var fills: usize = 0;
    for (drawn.list.cmds) |cmd| {
        if (cmd != .fill_path) continue;
        fills += 1;
        try expectBox(.{ 20, 300, 140, 301 }, drawn.list.pathBounds(cmd.fill_path.path));
    }
    try testing.expectEqual(@as(usize, 1), fills);

    // And the reader, which draws it as a mark, is not shown it twice.
    var left = try content.page(testing.allocator, &after, turned, .{ .taken = taken });
    defer left.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), left.diagnostics.annotations_drawn);
}

test "ink, an arrow and a reply come back as they went, with who and when" {
    var doc = try Document.open(testing.allocator, try fileWith("", &.{}));
    defer doc.deinit();
    const page = (try pages.all(&doc))[0];
    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    var ap: Appearances = .{};
    defer ap.deinit(testing.allocator);

    const words = [_]Bounds{.fromRect(100, 500, 220, 512)};
    const stroke = [_]Point{ .{ .x = 10, .y = 10 }, .{ .x = 40.25, .y = 60 }, .{ .x = 80, .y = 20 } };
    const paths = [_][]const Point{&stroke};
    const said: Written = .{ .author = "a reader", .when = 1_000_000_000 };
    const anchor = try write(&w, &ap, page, .{ .kind = .arrow, .lines = &words, .name = "f9", .text = "first" }, said);
    const refs = [_]Ref{
        anchor,
        try write(&w, &ap, page, .{ .kind = .ink, .paths = &paths, .width = 2.5, .color = green }, said),
        try write(&w, &ap, page, .{ .kind = .reply, .lines = &words, .name = "fa", .text = "na\u{ef}ve \u{2192} yes" }, .{ .answers = anchor }),
    };
    try attach(&w, page, &refs, &.{});
    const update = try w.finish(.{});
    defer testing.allocator.free(update);

    var after = try appended(&doc, update);
    defer after.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try readOnly(&after, arena.allocator());
    try testing.expectEqual(@as(usize, 3), got.len);

    try testing.expectEqual(Kind.arrow, got[0].kind);
    try testing.expectEqualStrings("f9", got[0].name);
    try testing.expectEqualStrings("first", got[0].text);
    try expectBox(.{ 100, 500, 220, 512 }, got[0].lines[0]);

    try testing.expectEqual(Kind.ink, got[1].kind);
    try testing.expectEqual(@as(usize, 3), got[1].paths[0].len);
    try testing.expectEqual(Point{ .x = 40.25, .y = 60 }, got[1].paths[0][1]);
    try testing.expectEqual(@as(f32, 2.5), got[1].width);

    try testing.expectEqual(Kind.reply, got[2].kind);
    try testing.expectEqual(@as(?u32, 0), got[2].thread);
    try testing.expectEqualStrings("na\u{ef}ve \u{2192} yes", got[2].text);

    const arrow = (try after.fetch(anchor)).asDict().?;
    try testing.expectEqualStrings("a reader", arrow.get("T").?.asString().?);
    try testing.expectEqualStrings("D:20010909014640Z", arrow.get("M").?.asString().?);
}

test "a later save names the forms the file has, and only fenrir's" {
    // 4 is another program's highlight, in fenrir's yellow, with a form of
    // fenrir's box that draws something else in it.
    var doc = try Document.open(testing.allocator, try fileWith("/Annots [4 0 R]", &.{
        "<< /Subtype /Highlight /Rect [0 0 9 9] /C [1 .902 .2] /AP << /N 5 0 R >> >>",
        "<< /Subtype /Form /BBox [0 0 1 1] /Length 12 >>\nstream\n0 0 1 1 re f\nendstream",
    }));
    defer doc.deinit();
    const line = [_]Bounds{.fromRect(72, 700, 300, 712)};

    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    var ap: Appearances = .{};
    defer ap.deinit(testing.allocator);
    const page = (try pages.all(&doc))[0];
    try ap.adopt(testing.allocator, &doc, page);
    try testing.expectEqual(@as(u32, 0), ap.forms.count());
    const first = try write(&w, &ap, page, .{ .kind = .highlight, .lines = &line, .color = yellow }, .{});
    try attach(&w, page, &.{first}, &.{});
    const one = try w.finish(.{});
    defer testing.allocator.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "/Subtype/Form") != null);

    var middle = try appended(&doc, one);
    defer middle.deinit();
    var again = try Writer.init(testing.allocator, &middle);
    defer again.deinit();
    var later: Appearances = .{};
    defer later.deinit(testing.allocator);
    const same = (try pages.all(&middle))[0];
    try later.adopt(testing.allocator, &middle, same);
    try testing.expectEqual(@as(u32, 1), later.forms.count());
    try testing.expect(later.resources != null);
    const second = try write(&again, &later, same, .{ .kind = .highlight, .lines = &line, .color = yellow }, .{});
    try attach(&again, same, &.{second}, &.{});
    const two = try again.finish(.{});
    defer testing.allocator.free(two);
    // Nothing drawn again: the second save carries no form at all.
    try testing.expect(std.mem.indexOf(u8, two, "/Subtype/Form") == null);

    var last = try appended(&middle, two);
    defer last.deinit();
    var forms: [3]u32 = undefined;
    try formsOf(&last, &forms);
    try testing.expectEqual(@as(u32, 5), forms[0]);
    try testing.expect(forms[1] != 5);
    try testing.expectEqual(forms[1], forms[2]);
}

test "a shape is what is drawn, to a hundredth, and not where the object is" {
    const line = [_]Bounds{.fromRect(100, 500, 220, 512)};
    const nudged = [_]Bounds{.fromRect(100.001, 500, 220, 512)};
    const moved = [_]Bounds{.fromRect(100.5, 500, 220, 512)};
    const a: Annot = .{ .kind = .highlight, .lines = &line };
    try testing.expectEqual(shapeOf(a), shapeOf(.{ .kind = .highlight, .lines = &nudged, .name = "anything" }));
    try testing.expect(shapeOf(a) != shapeOf(.{ .kind = .highlight, .lines = &moved }));
    try testing.expect(shapeOf(a) != shapeOf(.{ .kind = .underline, .lines = &line }));
    try testing.expect(shapeOf(a) != shapeOf(.{ .kind = .highlight, .lines = &line, .text = "why" }));
}

test "an annotation with nothing to draw is refused" {
    var doc = try Document.open(testing.allocator, try fileWith("", &.{}));
    defer doc.deinit();
    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    var ap: Appearances = .{};
    defer ap.deinit(testing.allocator);
    const page = (try pages.all(&doc))[0];
    try testing.expectError(error.NothingToDraw, write(&w, &ap, page, .{ .kind = .highlight }, .{}));
    try testing.expectError(error.NothingToDraw, write(&w, &ap, page, .{ .kind = .ink }, .{}));
    try testing.expect(w.isEmpty());
}
