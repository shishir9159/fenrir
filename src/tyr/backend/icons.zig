//! The icon face: a `Face` whose glyphs are drawn rather than loaded.
//!
//! An icon is a small filled outline at a size nobody chose by hand, tinted
//! the colour of the text beside it, positioned on a baseline. That is a
//! glyph, in every respect that matters to the machinery below it, and the
//! cheapest way to draw one is to stop inventing a second pipeline for it.
//!
//! So this is `fallback.zig`'s trick with something worth drawing at the end
//! of it: a hundred-odd lines of `Face` whose `outline` reads a table of
//! outlines, Phosphor's path data put through `svgpath` by the compiler.
//! Everything downstream is then unchanged and gets the icons for nothing.
//! `Atlas` keys on `(face, glyph, size, subpixel)` and already quantises the
//! size, so an icon is rasterised once per size and cached beside the
//! letters. `Fonts.layout` places it. `draw.zig` emits one tinted quad -- and
//! that tint is the whole of `currentColor`: an icon follows `Style.fg`, so a
//! light theme and a dark one need no second asset between them.
//!
//! ## Why the glyphs are reached by code point
//!
//! Because the shaper is: `Fonts.layout` takes a string, and the string is
//! what a box holds. Giving the UI a way to place one glyph by index would
//! mean a second path through `Fonts`, a second field on `Box` and a second
//! branch in the renderer, to arrive at exactly what a private-use code point
//! already does. So icons live at `U+E000` upwards -- the same convention
//! every symbol font on a terminal uses -- and `text(id)` is a four-byte
//! string. `Icons.zig` is what turns a name into one.
//!
//! ## The grid, and where the icon sits on the line
//!
//! The paths are drawn on Phosphor's 256-unit grid, which `svgpath.viewBox`
//! maps onto the em square, flipping y. A theme's path data is on the same
//! grid, so an icon copied from phosphoricons.com in another weight drops
//! in. The face then reports an ascender of a full em and no descender, so
//! an icon's box *is* the line box: drawn at fourteen pixels it is fourteen
//! pixels tall and sits centred on the line, with no per-call-site nudging.
//!
//! ## Parsed by the compiler
//!
//! A built-in icon's outline is in the binary, so asking for one is two
//! slice copies and a bad path in the table is a compile error. Parsing at
//! run time cost 2.5us an icon, half of first drawing it at 20px. The
//! compiler runs `svgpath` itself, so there is one parser and the test below
//! holds the two answers together.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../../gelgja/geom.zig");
const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const svgpath = @import("../svgpath.zig");
const ph = @import("phosphor.zig");

const GlyphIndex = Face.GlyphIndex;

/// The em square. A thousand, as for CFF, so the numbers in a trace read the
/// way the ones beside them do.
pub const units_per_em: u16 = 1000;

/// The grid the path data is drawn on.
pub const grid: f32 = 256;

const view = svgpath.viewBox(grid, @floatFromInt(units_per_em));

/// Where the glyphs appear in Unicode. The private use area, which is what it
/// is for; nothing outside this program should ever see these code points,
/// because nothing outside this program has this face.
pub const first_codepoint: u21 = 0xe000;

/// One icon: the name it is asked for by, and the path that draws it.
pub const Icon = struct {
    name: []const u8,
    d: []const u8,
};

/// The icons this binary can draw without being given anything.
///
/// Index zero is `unknown` and that is not an accident: it is `.notdef`, it
/// is what an unregistered id resolves to, and it is a hollow box for the
/// same reason Týr's fallback draws one. An icon that fails to resolve and
/// draws *nothing* is indistinguishable from a toolbar that is correctly
/// empty, and the bug is then found by someone else, later, in a screenshot.
///
/// Fenrir's names, which the registry and every call site use, on
/// Phosphor's drawings, which can change under them without one call site
/// noticing.
pub const builtin = [_]Icon{
    .{ .name = "unknown", .d = ph.square },

    // The reader's own furniture.
    .{ .name = "bookmark", .d = ph.bookmark_simple },
    .{ .name = "highlight", .d = ph.highlighter },
    .{ .name = "note", .d = ph.chat_text },
    .{ .name = "outline", .d = ph.tree_view },
    .{ .name = "page", .d = ph.file },
    .{ .name = "open", .d = ph.folder_open },

    // The keymap's modes, in the order the left rail shows them.
    .{ .name = "normal", .d = ph.cursor },
    .{ .name = "visual", .d = ph.cursor_text },
    .{ .name = "edit", .d = ph.pencil_simple },
    // A scribble and not a pen. The pen it once was sat one button below
    // `edit`, which is a pencil, and at sixteen pixels the two were the same
    // diagonal shape with the same nib -- a picture of the left rail is what
    // said so. An icon has to be different from the one beside it, not merely
    // correct about what it names.
    .{ .name = "draw", .d = ph.scribble_loop },

    .{ .name = "chevron_left", .d = ph.caret_left },
    .{ .name = "chevron_right", .d = ph.caret_right },
    .{ .name = "chevron_up", .d = ph.caret_up },
    .{ .name = "chevron_down", .d = ph.caret_down },

    // Search and the zooms, which are the same ring with different ink in it.
    .{ .name = "search", .d = ph.magnifying_glass },
    .{ .name = "zoom_in", .d = ph.magnifying_glass_plus },
    .{ .name = "zoom_out", .d = ph.magnifying_glass_minus },
    .{ .name = "fit_width", .d = ph.arrows_out_line_horizontal },
    .{ .name = "fit_page", .d = ph.corners_out },

    // Chrome: the bars, the panels and the buttons on them.
    .{ .name = "menu", .d = ph.list },
    .{ .name = "settings", .d = ph.sliders_horizontal },
    .{ .name = "panel", .d = ph.sidebar_simple },
    .{ .name = "split", .d = ph.square_split_horizontal },
    // A plus over a minus: what came and what went.
    .{ .name = "changes", .d = ph.plus_minus },
    .{ .name = "plus", .d = ph.plus },
    .{ .name = "minus", .d = ph.minus },
    .{ .name = "close", .d = ph.x },
    .{ .name = "check", .d = ph.check },
};

/// The glyph every failure resolves to.
pub const unknown: GlyphIndex = 0;

/// `builtin`, already outlines.
const baked = bake();

const Baked = struct {
    verbs: []const geom.Verb,
    points: []const geom.Point,
};

fn bake() [builtin.len]Baked {
    // Parsing took about twenty backward branches a byte of path data; three
    // times that, so adding an icon never means finding this number.
    var bytes: u32 = 0;
    for (builtin) |b| bytes += b.d.len;
    @setEvalBranchQuota(64 * bytes);

    var out: [builtin.len]Baked = undefined;
    for (builtin, &out) |b, *o| {
        // No allocator runs at comptime, and none is asked for while the
        // lists have room: `failing` is what says so if one ever has not.
        var verbs: [256]geom.Verb = undefined;
        var points: [768]geom.Point = undefined;
        var ol: Outline = .{ .verbs = .initBuffer(&verbs), .points = .initBuffer(&points) };
        svgpath.parse(.failing, &ol, b.d, .{ .transform = view }) catch |err|
            @compileError("icon '" ++ b.name ++ "': " ++ @errorName(err));
        const v = verbs[0..ol.verbs.items.len].*;
        const p = points[0..ol.points.items.len].*;
        o.* = .{ .verbs = &v, .points = &p };
    }
    return out;
}

fn copy(gpa: Allocator, out: *Outline, b: Baked) Error!void {
    try out.verbs.appendSlice(gpa, b.verbs);
    try out.points.appendSlice(gpa, b.points);
}

pub const Error = Face.Error;

/// The icons a face can draw: the built-in table, and whatever was added to
/// it afterwards.
///
/// It grows because an icon theme is allowed to bring path data of its own,
/// and that data has to be drawn by *some* face. Making it this one keeps a
/// themed icon and a built-in one identical from the atlas down, which is
/// worth more than the small awkwardness of a face that is not fixed at the
/// moment it is opened.
pub const Set = struct {
    gpa: Allocator,
    /// Added icons only; the built-in table is consulted first and is static.
    added: std.ArrayList(Icon) = .empty,
    /// Holds the names and the path data of the added ones. An arena because
    /// they are freed together, with the face, and never one at a time.
    arena: std.heap.ArenaAllocator,

    pub fn count(s: *const Set) usize {
        return builtin.len + s.added.items.len;
    }

    pub fn icon(s: *const Set, g: GlyphIndex) ?Icon {
        if (g < builtin.len) return builtin[g];
        const i = g - builtin.len;
        if (i >= s.added.items.len) return null;
        return s.added.items[i];
    }

    /// Adds an icon, copying both strings, and returns the glyph to draw it.
    ///
    /// The path is *not* parsed here. A theme that names a hundred icons
    /// would pay for ninety of them twice -- once now and once when the atlas
    /// asks -- and the atlas is where the answer is cached anyway. What a
    /// caller wanting the data checked should do is ask for the outline once,
    /// which is what `fenrir icons` does.
    pub fn add(s: *Set, name: []const u8, d: []const u8) Error!GlyphIndex {
        if (s.count() > std.math.maxInt(GlyphIndex)) return error.Unsupported;
        const a = s.arena.allocator();
        const owned: Icon = .{
            .name = try a.dupe(u8, name),
            .d = try a.dupe(u8, d),
        };
        try s.added.append(s.gpa, owned);
        return @intCast(s.count() - 1);
    }

    pub fn find(s: *const Set, name: []const u8) ?GlyphIndex {
        for (builtin, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, name)) return @intCast(i);
        }
        for (s.added.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, name)) return @intCast(builtin.len + i);
        }
        return null;
    }
};

/// The code point a glyph is drawn by, which is what a string has to contain.
pub fn codepoint(g: GlyphIndex) u21 {
    return first_codepoint + @as(u21, g);
}

/// Encodes `g` into `buf`, for a call site putting one icon in a box. Four
/// bytes is the most UTF-8 ever needs and the private use area needs three.
pub fn encode(g: GlyphIndex, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(codepoint(g), buf) catch unreachable;
    return buf[0..n];
}

/// Opens an icon face. Nothing is read and nothing can fail but the
/// allocation, because every glyph it can draw is in this file.
pub fn create(gpa: Allocator) Error!Face {
    const set = try gpa.create(Set);
    set.* = .{ .gpa = gpa, .arena = .init(gpa) };
    return .{
        .ptr = set,
        .vtable = &vtable,
        .info = .{
            .units_per_em = units_per_em,
            // Zero for the reason the fallback gives -- a count is a bound
            // someone will check against -- and here it would go stale as
            // well: a face is copied by value into `Fonts`, and a theme can
            // add glyphs to the set behind it afterwards.
            .num_glyphs = 0,
            // A full em up and nothing below, so that an icon's line box is
            // the icon. See the note at the top.
            .ascender = @intCast(units_per_em),
            .descender = 0,
            .format = .unknown,
        },
        .caps = .{ .glyph_names = true, .cmap = true },
        .backend = "icons",
    };
}

/// The set behind an icon face, or null for any other face. The check is the
/// vtable's address, which no other backend can have.
pub fn setOf(f: Face) ?*Set {
    if (f.vtable != &vtable) return null;
    return @ptrCast(@alignCast(f.ptr));
}

const vtable: Face.VTable = .{
    .glyphForName = glyphForName,
    .glyphForCodepoint = glyphForCodepoint,
    .advance = advance,
    .outline = outline,
    .rasterize = rasterize,
    .deinit = deinit,
};

fn glyphForName(ptr: *anyopaque, name: []const u8) ?GlyphIndex {
    const set: *Set = @ptrCast(@alignCast(ptr));
    return set.find(name);
}

fn glyphForCodepoint(ptr: *anyopaque, cp: u21) ?GlyphIndex {
    const set: *Set = @ptrCast(@alignCast(ptr));
    if (cp < first_codepoint) return null;
    const g = cp - first_codepoint;
    if (g >= set.count()) return null;
    return @intCast(g);
}

/// Square, always. An icon that advanced by its own ink would make a rail of
/// buttons sit at uneven spacing and a menu's labels fail to line up.
fn advance(_: *anyopaque, _: GlyphIndex) ?f32 {
    return @floatFromInt(units_per_em);
}

fn outline(ptr: *anyopaque, gpa: Allocator, g: GlyphIndex, out: *Outline) Error!void {
    const set: *Set = @ptrCast(@alignCast(ptr));
    if (g < builtin.len) return copy(gpa, out, baked[g]);
    const found = set.icon(g) orelse return copy(gpa, out, baked[unknown]);

    svgpath.parse(gpa, out, found.d, .{ .transform = view }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Path data this face cannot read came from a theme, and the theme
        // is what should be reporting it -- `fenrir icons` asks for every
        // outline exactly so it can. Here the answer is the visible box, for
        // the same reason index zero is one.
        error.BadPathData => {
            out.reset(units_per_em);
            return copy(gpa, out, baked[unknown]);
        },
    };
}

fn rasterize(_: *anyopaque, _: GlyphIndex, _: Face.Render) Error!Face.Bitmap {
    return error.Unsupported;
}

fn deinit(ptr: *anyopaque, gpa: Allocator) void {
    const set: *Set = @ptrCast(@alignCast(ptr));
    set.added.deinit(gpa);
    set.arena.deinit();
    gpa.destroy(set);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const raster = @import("../raster.zig");

test "the compiler's outlines are the parser's, and draw inside the em" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    var r: raster.Raster = .{};
    defer r.deinit(gpa);

    const em: f32 = @floatFromInt(units_per_em);
    // A tenth of a pixel at 24px, the largest slot. Phosphor's ink runs to
    // the edge of its grid, and `draw`'s 1.6 units past it.
    const slack = em / 240;
    for (builtin, baked) |b, k| {
        o.reset(units_per_em);
        try svgpath.parse(gpa, &o, b.d, .{ .transform = view });
        try testing.expect(!o.isEmpty());

        // Comptime float arithmetic is not promised to round as the
        // target's does, so the points agree to a thousandth of a unit --
        // a millionth of the em -- rather than to the bit.
        try testing.expectEqualSlices(geom.Verb, o.verbs.items, k.verbs);
        for (o.points.items, k.points) |p, q| {
            try testing.expectApproxEqAbs(p.x, q.x, 1e-3);
            try testing.expectApproxEqAbs(p.y, q.y, 1e-3);
        }

        // Drawn on the grid it says it is drawn on. An icon that overflows
        // the em is one that will be clipped by a neighbour's cell in the
        // atlas, which reads as a stray line through the next glyph along.
        // The ink is what is measured, as the atlas measures it: a curve's
        // controls may stand further out.
        const ink = try r.flatten(gpa, o, .{});
        try testing.expect(ink.min_x >= -slack and ink.max_x <= em + slack);
        try testing.expect(-ink.max_y >= -slack and -ink.min_y <= em + slack);

        // And it is a shape, not a stroke that happens to have ink: every
        // icon here is filled, so every contour has to be closed.
        try testing.expect(o.contourCount() >= 1);
    }
}

test "names are unique, because a duplicate would shadow the first silently" {
    for (builtin, 0..) |a, i| {
        for (builtin[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "the face answers to names and to code points" {
    const gpa = testing.allocator;
    var face = try create(gpa);
    defer face.deinit(gpa);

    try testing.expectEqualStrings("icons", face.backend);
    const g = face.glyphForName("bookmark").?;
    try testing.expectEqual(g, face.glyphForCodepoint(codepoint(g)).?);

    try testing.expectEqual(@as(?GlyphIndex, null), face.glyphForName("no such icon"));
    // Ordinary text is not in this face at all, and must not fall through to
    // an icon: a label drawn with the icon font by mistake should be visibly
    // wrong, not quietly a row of bookmarks.
    try testing.expectEqual(@as(?GlyphIndex, null), face.glyphForCodepoint('A'));
    try testing.expectEqual(@as(?GlyphIndex, null), face.glyphForCodepoint(0xf8ff));
}

test "an unregistered glyph draws the visible box rather than nothing" {
    const gpa = testing.allocator;
    var face = try create(gpa);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);

    try face.outline(gpa, 4000, &o);
    // The hollow box: two contours, wound against each other.
    try testing.expectEqual(@as(u32, 2), o.contourCount());

    var box: Outline = .{};
    defer box.deinit(gpa);
    try face.outline(gpa, unknown, &box);
    try testing.expectEqualSlices(geom.Point, box.points.items, o.points.items);
}

test "an icon added by a theme is drawn by the same face" {
    const gpa = testing.allocator;
    var face = try create(gpa);
    defer face.deinit(gpa);

    const set = setOf(face).?;
    var name: [8]u8 = "sparkle\x00".*;
    const g = try set.add(name[0..7], "M128 16 152 104 240 128 152 152 128 240 104 152 16 128 104 104z");
    // The strings are copied: the caller's buffer is not the face's.
    @memset(&name, '?');

    try testing.expectEqual(g, face.glyphForName("sparkle").?);
    try testing.expectEqual(@as(usize, builtin.len + 1), set.count());

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, g, &o);
    try testing.expectEqual(@as(u32, 1), o.contourCount());
}

test "path data a theme got wrong falls back to the box" {
    const gpa = testing.allocator;
    var face = try create(gpa);
    defer face.deinit(gpa);

    const g = try setOf(face).?.add("broken", "M0 0 Lnonsense");

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, g, &o);
    // Two contours means the box, not the fragment that parsed before the
    // bad byte -- the outline is reset first.
    try testing.expectEqual(@as(u32, 2), o.contourCount());
}

test "an icon is square, and its line box is the icon" {
    const gpa = testing.allocator;
    var face = try create(gpa);
    defer face.deinit(gpa);

    try testing.expectEqual(@as(?f32, @floatFromInt(units_per_em)), face.advance(0));
    // A full em of ascent and nothing below it, so a 16-pixel icon occupies
    // a 16-pixel line and needs no nudging to sit on one.
    try testing.expectEqual(@as(i16, @intCast(units_per_em)), face.info.ascender);
    try testing.expectEqual(@as(i16, 0), face.info.descender);
}

test "encoding gives a string a box can hold" {
    var buf: [4]u8 = undefined;
    const s = encode(1, &buf);
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(codepoint(1), try std.unicode.utf8Decode(s));
}
