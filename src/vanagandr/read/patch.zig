//! Patches on the page: a body, two wedges, and the correction set in the
//! page's own type.
//!
//! ## The shape
//!
//! The overlay is the instance pipeline, and an instance is an axis-aligned
//! rounded box -- see the note at the top of `rect.zig`. A patch's hull is
//! a hexagon with two sloped edges, so it is drawn as the rectangle between
//! the slopes, one fill, and each slope scanlined into rows a device pixel
//! tall that end at a fractional x. The box's own edge antialiasing makes
//! the diagonal come out clean rather than stepped. A slope spans about a
//! line, so a wedge is a line's height in instances: about fourteen at
//! 100%, fifty-six at 400%.
//!
//! ## The type
//!
//! The correction is set in the font of the first glyph under the patch, at
//! that glyph's size, so it looks like the paragraph it corrects. The font
//! is the document's, and the document is the rasterising thread's, so the
//! worker is asked for it once (`fontJob`, `glyphs.lettering`): the program,
//! for a face of this thread's own in the interface's atlas, and every
//! character the font can set with the glyph that sets it. A character it
//! cannot set -- a subset holds only what the page used -- is set in the
//! interface's face, and so is all of it until the font comes.
//!
//! Laid out in points at the size the zoom quantises to, eighth-octave steps
//! as canvas text is, so zooming does not fill the atlas with every size;
//! the lines are kept until the text, the font or that step changes, and
//! nothing is laid out per frame. The glyphs are placed the way
//! `Fonts.layout` places them, from the lettering's glyphs and the PDF's
//! widths rather than through the shaper, which would ask the program's
//! cmap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const Session = @import("Session.zig");
const glyphmod = @import("../glyphs.zig");
const render = @import("render.zig");

const gelgja = fenrir.gelgja;
const hlidskjalf = fenrir.hlidskjalf;
const tyr = fenrir.tyr;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const DrawList = fenrir.gleipnir.DrawList;
const Buffer = hlidskjalf.Buffer;
const Hull = hlidskjalf.patch.Hull;
const Marks = hlidskjalf.Marks;
const View = hlidskjalf.View;
const Fonts = tyr.Fonts;

/// What the session keeps for patches between frames: the fonts asked for,
/// what each patch is set in, and the lines its correction is laid in.
pub const State = struct {
    faces: std.ArrayList(Face) = .empty,
    looks: std.ArrayList(Look) = .empty,
    laid: std.ArrayList(Laid) = .empty,
    rows: std.ArrayList(Row) = .empty,

    /// After the interface is destroyed: its fonts borrow the programs.
    pub fn deinit(st: *State, gpa: Allocator) void {
        for (st.faces.items) |*f| {
            if (f.lettering) |*l| l.deinit(gpa);
        }
        st.faces.deinit(gpa);
        st.looks.deinit(gpa);
        st.laid.deinit(gpa);
        st.rows.deinit(gpa);
    }
};

/// A font of one document, as the interface's atlas has it.
const Face = struct {
    /// The document, by address: a reload is another document, and asks
    /// for its fonts again.
    doc: usize,
    object: u32,
    /// Where to send the worker for it.
    buffer: u32,
    state: enum { wanted, ready, none } = .wanted,
    id: Fonts.FontId = 0,
    lettering: ?glyphmod.Lettering = null,
};

/// What a patch is set in, found once from the glyphs under it.
const Look = struct {
    anchor: u64,
    doc: usize,
    /// Zero when no glyph with a font was under it.
    object: u32,
    /// In points.
    size: f32,
    /// Baseline to baseline, from the line under the patch to the next in
    /// its column, or zero when there is none to measure.
    leading: f32 = 0,
};

/// A patch's correction, laid out at one size in one face.
const Laid = struct {
    anchor: u64,
    text: u64,
    px: f32,
    face: Fonts.FontId,
    first: u32,
    count: u32,
};

/// One line of a correction: the bytes it shows, on which piece, and where
/// it begins, in the page's points.
const Row = struct {
    piece: u64,
    from: u32,
    to: u32,
    left: f32,
    baseline: f32,
};

/// How many layouts are kept before they are all dropped: far more than are
/// on screen at once, and a correction being typed makes one a key.
const laid_limit = 128;

/// The interface's face for what the page's cannot set.
fn fallbackFace(s: *Session) Fonts.FontId {
    return if (s.chrome) |c| c.face else 0;
}

// -- the font -----------------------------------------------------------------

/// The next font a patch on screen is waiting for, as a job.
pub fn fontJob(s: *Session) ?render.Job {
    if (s.chrome == null) return null;
    for (s.patches.faces.items) |*f| {
        if (f.state != .wanted) continue;
        if (f.buffer >= s.bufferCount() or @intFromPtr(s.buffer(f.buffer).doc) != f.doc) {
            f.state = .none;
            continue;
        }
        return .{ .buffer = f.buffer, .page = f.object, .zoom = 0, .want = .font };
    }
    return null;
}

/// A font back from the worker, opened in the interface's atlas. Null is a
/// font with no program fenrir can open, and its patches stay in the
/// interface's face.
pub fn take(s: *Session, job: render.Job, lettering: ?glyphmod.Lettering) void {
    var given = lettering;
    defer if (given) |*l| l.deinit(s.gpa);
    if (job.buffer >= s.bufferCount()) return;
    const doc = @intFromPtr(s.buffer(job.buffer).doc);
    for (s.patches.faces.items) |*f| {
        if (f.doc != doc or f.object != job.page or f.state != .wanted) continue;
        f.state = .none;
        const c = s.chrome orelse return;
        const l = given orelse return;
        const id = c.fonts.open(l.program, .{}) catch return;
        // The fallback backend opens anything and draws boxes, which is
        // worse than the interface's face.
        if (std.mem.eql(u8, c.fonts.face(id).backend, "fallback")) return;
        f.id = id;
        f.state = .ready;
        f.lettering = l;
        given = null;
        return;
    }
}

fn faceOf(s: *Session, doc: usize, object: u32) ?*Face {
    for (s.patches.faces.items) |*f| {
        if (f.doc == doc and f.object == object) return f;
    }
    return null;
}

/// What the patch `anchor` is set in: the font and size of the first glyph
/// under its first piece, found once its page's text is known, and asked of
/// the worker the first time. Until the text is known, null.
fn lookOf(s: *Session, b: *Buffer, index: u32, anchor: u64) ?Look {
    const doc = @intFromPtr(b.doc);
    for (s.patches.looks.items) |l| {
        if (l.anchor == anchor and l.doc == doc) return l;
    }
    const first = b.marks.firstLine(s.gpa, anchor) orelse return null;
    const head = b.marks.items()[first];
    const map = b.textMap(head.page) orelse return null;

    const hull = head.hull();
    var look: Look = .{ .anchor = anchor, .doc = doc, .object = 0, .size = guessedSize(head) };
    for (map.boxes, 0..) |g, i| {
        if (g.space or g.turn != .none) continue;
        const middle: gelgja.Point = .{ .x = g.middle(), .y = (g.box.min_y + g.box.max_y) * 0.5 };
        if (!hull.contains(middle)) continue;
        // The box is the size from a fifth under the baseline to three
        // quarters over it; see `text.build`.
        look.object = g.font;
        look.size = g.box.height() / 0.95;
        // The passage's own leading, so the correction's lines fall where
        // its lines did rather than where the font's metrics put them --
        // which a font program embedded in a PDF often does not carry.
        const line = map.lineOf(@intCast(i));
        if (line + 1 < map.lines.len) {
            const next = map.lines[line + 1];
            const gap = map.lines[line].baseline - next.baseline;
            if (next.column == map.lines[line].column and gap > look.size and gap < look.size * 3) look.leading = gap;
        }
        break;
    }
    s.patches.looks.append(s.gpa, look) catch return look;
    if (look.object != 0 and faceOf(s, doc, look.object) == null) {
        s.patches.faces.append(s.gpa, .{ .doc = doc, .object = look.object, .buffer = index }) catch {};
    }
    return look;
}

/// A size for a patch over no text the map knows: a line of it, when the
/// hull says how tall a line is, and ten points when it does not.
fn guessedSize(m: Marks.Mark) f32 {
    if (m.insets.rise > 0) return m.insets.rise / 0.95;
    if (m.box.height() < 30) return @max(m.box.height() / 0.95, 4);
    return 10;
}

/// `px` to the nearest eighth of an octave, so a zoom by a hair is not a new
/// size in the atlas.
pub fn quantised(px: f32) f32 {
    if (!(px > 0)) return 1;
    return std.math.exp2(@round(std.math.log2(px) * 8) / 8);
}

// -- laying it out --------------------------------------------------------------

/// One character, as it will be set: the face, the glyph, and how far it
/// moves the pen, in ems.
const Set = struct { face: Fonts.FontId, glyph: tyr.GlyphIndex, advance: f32 };

fn setOf(fonts: *Fonts, page: ?*const Face, fallback: Fonts.FontId, cp: u21) Set {
    if (page) |f| {
        if (f.lettering.?.find(cp)) |l| return .{ .face = f.id, .glyph = l.glyph, .advance = l.advance };
    }
    const face = fonts.face(fallback);
    const glyph = face.glyphForCodepoint(cp) orelse 0;
    return .{ .face = fallback, .glyph = glyph, .advance = (face.advance(glyph) orelse 0) * face.unitScale() };
}

/// The pieces of a patch, in reading order: the order its correction flows
/// through them.
fn piecesOf(b: *Buffer, anchor: u64, out: *[max_pieces]usize) []usize {
    var n: usize = 0;
    for (b.marks.items(), 0..) |m, i| {
        if (m.anchor != anchor or m.kind != .patch or n == max_pieces) continue;
        out[n] = i;
        n += 1;
    }
    const items = b.marks.items();
    const order = struct {
        fn lt(list: []const Marks.Mark, x: usize, y: usize) bool {
            return Marks.readsBefore(list[x], list[y]);
        }
    }.lt;
    std.mem.sort(usize, out[0..n], items, order);
    return out[0..n];
}

/// A patch crosses a column or a page break a handful of times at most.
const max_pieces = 32;

/// The rows a patch's correction is laid in at `px`, laying them out first
/// when the text, the face or the size has changed since.
fn laidFor(s: *Session, b: *Buffer, anchor: u64, text: []const u8, look: Look, k: f32) ?Laid {
    const c = s.chrome orelse return null;
    const px = quantised(look.size * k);
    const page: ?*const Face = if (faceOf(s, look.doc, look.object)) |f| (if (f.state == .ready) f else null) else null;
    const face = if (page) |f| f.id else fallbackFace(s);
    const hash = std.hash.Wyhash.hash(0, text);
    for (s.patches.laid.items) |l| {
        if (l.anchor == anchor and l.text == hash and l.px == px and l.face == face) return l;
    }
    if (s.patches.laid.items.len >= laid_limit) {
        s.patches.laid.clearRetainingCapacity();
        s.patches.rows.clearRetainingCapacity();
    }

    // In points at the quantised size, so the lines break where the glyphs
    // drawn at `px` end. A line is a fifth of the size under its baseline
    // and three quarters over it, as `text.build` measures the passage's,
    // so the first baseline is the first line's own.
    const size = px / k;
    const pitch = if (look.leading > 0) look.leading else size * 1.2;

    const first: u32 = @intCast(s.patches.rows.items.len);
    var at: usize = 0;
    var buf: [max_pieces]usize = undefined;
    for (piecesOf(b, anchor, &buf)) |i| {
        const m = b.marks.items()[i];
        const hull = m.hull();
        var base = hull.box.max_y - 0.75 * size;
        var row: u32 = 0;
        // At least a row a piece, however short the piece, and then as
        // many as fit above its foot.
        while (row == 0 or base - 0.2 * size >= hull.box.min_y - 0.5) : ({
            base -= pitch;
            row += 1;
        }) {
            const upper = hull.span(@min(base + 0.75 * size, hull.box.max_y));
            const lower = hull.span(@max(base - 0.2 * size, hull.box.min_y));
            const left = @max(upper[0], lower[0]);
            const width = @min(upper[1], lower[1]) - left;
            // A row starts at a word, not at the space before it.
            while (at < text.len and text[at] == ' ') at += 1;
            const end = fit(c, page, fallbackFace(s), text, at, width / size);
            s.patches.rows.append(s.gpa, .{
                .piece = m.key,
                .from = @intCast(at),
                .to = @intCast(end),
                .left = left,
                .baseline = base,
            }) catch return null;
            at = end;
        }
    }
    const laid: Laid = .{
        .anchor = anchor,
        .text = hash,
        .px = px,
        .face = face,
        .first = first,
        .count = @intCast(s.patches.rows.items.len - first),
    };
    s.patches.laid.append(s.gpa, laid) catch return null;
    return laid;
}

/// Where a row that starts at `from` and is `width` ems wide ends: after the
/// last word that fits, or in the middle of a word too long for any row.
/// Always past `from` when there is text left, so a row too narrow for one
/// letter still moves the text on.
fn fit(c: anytype, page: ?*const Face, fallback: Fonts.FontId, text: []const u8, from: usize, width: f32) usize {
    var pen: f32 = 0;
    var at = from;
    var last_space: ?usize = null;
    while (at < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        const end = @min(text.len, at + n);
        const cp = std.unicode.utf8Decode(text[at..end]) catch ' ';
        pen += setOf(&c.fonts, page, fallback, cp).advance;
        if (pen > width and at > from) {
            if (cp == ' ') return at;
            return last_space orelse at;
        }
        if (cp == ' ') last_space = at;
        at = end;
    }
    return at;
}

// -- drawing it ---------------------------------------------------------------

/// What a patch hides its words under: paper, tinted a quarter of the way to
/// its colour, so a digit marks a correction without making it unreadable.
fn paperOf(c: Color) Color {
    const k = 0.25;
    return .{ .r = 1 - k * (1 - c.r), .g = 1 - k * (1 - c.g), .b = 1 - k * (1 - c.b), .a = 1 };
}

const ink: Color = .black;

/// The patches on the pages a window can see: every body, then every
/// correction, so a later patch's paper never covers an earlier one's
/// words where two meet.
pub fn drawPatches(s: *Session, v: *View, b: *Buffer, index: u32, range: View.Visible, over: *DrawList) !void {
    const editing = s.keymap.mode == .edit or s.keymap.mode == .note;
    const in_focus = v == s.layout().current();
    var any = false;
    for (b.marks.items()) |mark| {
        if (mark.kind != .patch) continue;
        if (mark.page < range.first or mark.page >= range.end) continue;
        any = true;
        const w = v.windowBox(mark.page, mark.box);
        try body(over, mark.hull(), w, v.zoom, paperOf(mark.color));
        if (editing and in_focus and s.focus_mark == mark.key) {
            const pad = 2.0;
            try over.border(.fromRect(w.min_x - pad, w.min_y - pad, w.max_x + pad, w.max_y + pad), .all(2), 2, .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 });
        }
    }
    if (!any) return;
    const c = s.chrome orelse return;
    if (c.atlas == 0) return;

    for (b.marks.items()) |mark| {
        if (mark.kind != .patch) continue;
        if (mark.page < range.first or mark.page >= range.end) continue;
        const look = lookOf(s, b, index, mark.anchor) orelse Look{ .anchor = mark.anchor, .doc = 0, .object = 0, .size = guessedSize(mark) };
        const laid = laidFor(s, b, mark.anchor, mark.text, look, v.zoom) orelse continue;
        const page: ?*const Face = if (faceOf(s, look.doc, look.object)) |f| (if (f.state == .ready) f else null) else null;
        const w = v.windowBox(mark.page, mark.box);
        over.pushClip(w);
        defer over.popClip();
        for (s.patches.rows.items[laid.first..][0..laid.count]) |row| {
            if (row.piece != mark.key) continue;
            try setRow(c, over, page, laid, mark.text[row.from..row.to], .{
                .x = w.min_x + (row.left - mark.box.min_x) * v.zoom,
                .y = w.min_y + (mark.box.max_y - row.baseline) * v.zoom,
            });
        }
    }
}

/// One row of a correction, from the pen at its baseline in window pixels.
fn setRow(c: anytype, over: *DrawList, page: ?*const Face, laid: Laid, text: []const u8, origin: gelgja.Point) !void {
    const fonts = &c.fonts;
    const fallback = c.face;
    const base_y = @round(origin.y);
    var pen = origin.x;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        const set = setOf(fonts, page, fallback, cp);
        defer pen += set.advance * laid.px;
        if (cp == ' ' or set.glyph == 0) continue;
        const at = fonts.atlas.position(pen);
        const cell = (try fonts.atlas.get(fonts.gpa, fonts.face(set.face), set.face, set.glyph, laid.px, at.bucket)) orelse continue;
        if (cell.isBlank()) continue;
        const x0 = at.pixel + @as(f32, @floatFromInt(cell.left));
        const y0 = base_y - @as(f32, @floatFromInt(cell.top));
        const dst: Bounds = .fromRect(x0, y0, x0 + @as(f32, @floatFromInt(cell.w)), y0 + @as(f32, @floatFromInt(cell.h)));
        const src: Bounds = .fromRect(
            @floatFromInt(cell.x),
            @floatFromInt(cell.y),
            @as(f32, @floatFromInt(cell.x)) + @as(f32, @floatFromInt(cell.w)),
            @as(f32, @floatFromInt(cell.y)) + @as(f32, @floatFromInt(cell.h)),
        );
        // Twice: a book face's thin stems at a reading size come out of the
        // coverage atlas a mid grey, where the page's own rasteriser draws
        // them near black, and a correction lighter than the words around
        // it reads as a different hand. Two coverages are one darker one.
        try over.glyph(dst, c.atlas, src, ink);
        try over.glyph(dst, c.atlas, src, ink);
    }
}

/// A hull, opaque: the rectangle between its slopes, and each slope a row a
/// device pixel tall. `w` is the hull's box in the window and `k` points to
/// pixels.
pub fn body(over: *DrawList, h: Hull, w: Bounds, k: f32, fill: Color) !void {
    const i = h.insets;
    // Where each band ends, on a whole pixel, so the rows and the body
    // between them meet without a seam.
    const a = @min(w.max_y, @round(w.min_y + i.rise * k));
    const z = @max(a, @round(w.max_y - i.fall * k));
    if (z > a) try over.fill(.fromRect(w.min_x, a, w.max_x, z), fill);
    try band(over, h, w, k, w.min_y, a, fill);
    try band(over, h, w, k, z, w.max_y, fill);
}

/// The most rows a wedge is drawn in. A wedge taller than this, at a zoom
/// that makes a line hundreds of pixels high, is drawn in taller rows.
const max_rows = 256;

fn band(over: *DrawList, h: Hull, w: Bounds, k: f32, from: f32, to: f32, fill: Color) !void {
    if (!(to > from)) return;
    const step = @max(1, @ceil((to - from) / max_rows));
    var y = from;
    while (y < to) {
        const next = @min(to, @floor(y / step) * step + step);
        // Back into the page at the row's middle, for the span there.
        const span = h.span(h.box.max_y - ((y + next) * 0.5 - w.min_y) / k);
        try over.fill(.fromRect(w.min_x + (span[0] - h.box.min_x) * k, y, w.min_x + (span[1] - h.box.min_x) * k, next), fill);
        y = next;
    }
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "a hull is drawn as its body and a row a pixel for each slope" {
    const gpa = testing.allocator;
    var over: DrawList = .init(gpa, .fromRect(0, 0, 800, 800));
    defer over.deinit();

    // A paragraph's hull at 2x: a line and a half's cut at each corner.
    const h: Hull = .{
        .box = .fromRect(72, 654, 540, 700),
        .insets = .{ .head = 128, .tail = 140, .rise = 10, .fall = 10 },
    };
    const w: Bounds = .fromRect(10, 20, 10 + 468 * 2, 20 + 46 * 2);
    try body(&over, h, w, 2, .white);
    // The body, and twenty rows for each of the two wedges.
    try testing.expectEqual(@as(usize, 1 + 20 + 20), over.instances.items.len);

    // A rectangle is the body alone.
    over.reset(.fromRect(0, 0, 800, 800));
    try body(&over, .{ .box = h.box }, w, 2, .white);
    try testing.expectEqual(@as(usize, 1), over.instances.items.len);
}

test "the size steps in eighths of an octave" {
    try testing.expectEqual(@as(f32, 16), quantised(16));
    try testing.expectApproxEqAbs(@as(f32, 16), quantised(16.3), 1e-4);
    try testing.expect(quantised(17.5) > 16);
    try testing.expectEqual(quantised(12.01), quantised(12.02));
}
