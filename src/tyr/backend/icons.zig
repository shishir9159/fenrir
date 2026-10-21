//! The icon face: a `Face` whose glyphs are drawn rather than loaded.
//!
//! An icon is a small filled outline at a size nobody chose by hand, tinted
//! the colour of the text beside it, positioned on a baseline. That is a
//! glyph, in every respect that matters to the machinery below it, and the
//! cheapest way to draw one is to stop inventing a second pipeline for it.
//!
//! So this is `fallback.zig`'s trick with something worth drawing at the end
//! of it: a hundred-odd lines of `Face` whose `outline` reads a table of
//! `d` strings and hands them to `svgpath`. Everything downstream is then
//! unchanged and gets the icons for nothing. `Atlas` keys on
//! `(face, glyph, size, subpixel)` and already quantises the size, so an icon
//! is rasterised once per size and cached beside the letters. `Fonts.layout`
//! places it. `draw.zig` emits one tinted quad -- and that tint is the whole
//! of `currentColor`: an icon follows `Style.fg`, so a light theme and a dark
//! one need no second asset between them.
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
//! The paths are drawn on the 24-unit grid every icon set publishes, which
//! `svgpath.viewBox` maps onto the em square, flipping y. The face then
//! reports an ascender of a full em and no descender, so an icon's box *is*
//! the line box: drawn at fourteen pixels it is fourteen pixels tall and
//! sits centred on the line, with no per-call-site nudging.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const svgpath = @import("../svgpath.zig");

const GlyphIndex = Face.GlyphIndex;

/// The em square. A thousand, as for CFF, so the numbers in a trace read the
/// way the ones beside them do.
pub const units_per_em: u16 = 1000;

/// The grid the path data is drawn on.
pub const grid: f32 = 24;

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
/// They are drawn on a 24-unit grid with y downwards, as published. A hole is
/// a contour wound against the one containing it -- the nonzero rule, which
/// is what the rasteriser applies -- and the y flip reverses both, so it
/// survives the transform.
pub const builtin = [_]Icon{
    .{ .name = "unknown", .d = "M3 3h18v18H3z M5 5v14h14V5z" },

    // The reader's own furniture.
    .{ .name = "bookmark", .d = "M6 2h12v20l-6-5-6 5z" },
    .{ .name = "highlight", .d = "M4 17h16v4H4z M7 14l8-11 4 3-8 11z" },
    .{ .name = "note", .d = "M3 4h18v13H8l-5 4z" },
    .{ .name = "outline", .d = "M3 4h18v2H3z M7 11h14v2H7z M11 18h10v2H11z" },
    .{ .name = "page", .d = "M5 2h9l5 5v15H5z M7 4v16h10V8h-4V4z" },
    .{ .name = "open", .d = "M3 5h7l2 2h9v12H3z" },

    // The keymap's modes, in the order the left rail shows them.
    .{ .name = "normal", .d = "M5 2 5 20 10 15.5 13 21 15.6 19.7 12.8 14.6 18 14z" },
    .{
        .name = "visual",
        .d = "M3 3h7v2H5v5H3z M21 3v7h-2V5h-5V3z M3 21v-7h2v5h5v2z M21 21h-7v-2h5v-5h2z",
    },
    .{ .name = "edit", .d = "M3 17.2 14.8 5.4l3.8 3.8L6.8 21H3z M16.2 4 18 2.2 21.8 6 20 7.8z" },
    // A squiggle and not a pen. The pen it used to be sat one button below
    // `edit`, which is a pencil, and at sixteen pixels the two were the same
    // diagonal shape with the same nib -- a picture of the left rail is what
    // said so. An icon has to be different from the one beside it, not merely
    // correct about what it names.
    .{
        .name = "draw",
        .d = "M3 17 C6 9 9 9 12 14 C15 19 18 19 21 11 L21 14" ++
            " C18 22 15 22 12 17 C9 12 6 12 3 20 Z",
    },

    // Chevrons, as one shape rotated four ways. Written out rather than
    // rotated at run time: a matrix per icon would be a second way to say
    // where a glyph is, and the table is the first.
    .{ .name = "chevron_left", .d = "M15.5 4 6 12 15.5 20 17 18.2 9.5 12 17 5.8z" },
    .{ .name = "chevron_right", .d = "M8.5 4 18 12 8.5 20 7 18.2 14.5 12 7 5.8z" },
    .{ .name = "chevron_up", .d = "M4 15.5 12 6 20 15.5 18.2 17 12 9.5 5.8 17z" },
    .{ .name = "chevron_down", .d = "M4 8.5 12 18 20 8.5 18.2 7 12 14.5 5.8 7z" },

    // Search and the zooms, which are the same ring with different ink in it.
    .{
        .name = "search",
        .d = "M4 10a7 7 0 1 0 14 0 7 7 0 1 0-14 0z M6 10a5 5 0 1 1 10 0 5 5 0 1 1-10 0z" ++
            " M14.8 16.2l1.4-1.4 5.5 5.5-1.4 1.4z",
    },
    .{
        .name = "zoom_in",
        .d = "M4 10a7 7 0 1 0 14 0 7 7 0 1 0-14 0z M6 10a5 5 0 1 1 10 0 5 5 0 1 1-10 0z" ++
            " M10 6h2v3h3v2h-3v3h-2v-3H7V9h3z M14.8 16.2l1.4-1.4 5.5 5.5-1.4 1.4z",
    },
    .{
        .name = "zoom_out",
        .d = "M4 10a7 7 0 1 0 14 0 7 7 0 1 0-14 0z M6 10a5 5 0 1 1 10 0 5 5 0 1 1-10 0z" ++
            " M7 9h8v2H7z M14.8 16.2l1.4-1.4 5.5 5.5-1.4 1.4z",
    },
    .{ .name = "fit_width", .d = "M2 12 7 7v10z M22 12l-5-5v10z M6 11h12v2H6z" },
    .{
        .name = "fit_page",
        .d = "M4 3h16v18H4z M6 5v14h12V5z M12 6 15 10H9z M12 18 9 14h6z",
    },

    // Chrome: the bars, the panels and the buttons on them.
    .{ .name = "menu", .d = "M3 5h18v2H3z M3 11h18v2H3z M3 17h18v2H3z" },
    .{ .name = "settings", .d = "M3 7h5v2H3z M12 7h9v2h-9z M8 4h4v8H8z" ++
        " M3 15h9v2H3z M16 15h5v2h-5z M12 12h4v8h-4z" },
    .{ .name = "panel", .d = "M3 4h18v16H3z M5 6v12h9V6z" },
    .{ .name = "split", .d = "M3 4h18v16H3z M5 6v12h6V6z M13 6v12h6V6z" },
    .{ .name = "plus", .d = "M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7z" },
    .{ .name = "minus", .d = "M4 11h16v2H4z" },
    .{
        .name = "close",
        .d = "M5.6 4.2 12 10.6 18.4 4.2 19.8 5.6 13.4 12 19.8 18.4 18.4 19.8" ++
            " 12 13.4 5.6 19.8 4.2 18.4 10.6 12 4.2 5.6z",
    },
    .{ .name = "check", .d = "M9.5 18.8 3.6 12.9 5.7 10.8 9.5 14.6 18.3 5.8 20.4 7.9z" },
};

/// The glyph every failure resolves to.
pub const unknown: GlyphIndex = 0;

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
    const found = set.icon(g) orelse builtin[unknown];
    const opts: svgpath.Options = .{
        .transform = svgpath.viewBox(grid, @floatFromInt(units_per_em)),
    };

    svgpath.parse(gpa, out, found.d, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Path data this face cannot read came from a theme, and the theme
        // is what should be reporting it -- `fenrir icons` asks for every
        // outline exactly so it can. Here the answer is the visible box, for
        // the same reason index zero is one.
        error.BadPathData => {
            out.reset(units_per_em);
            svgpath.parse(gpa, out, builtin[unknown].d, opts) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // The box is written in this file and a test parses it.
                error.BadPathData => unreachable,
            };
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

test "every built-in icon parses, and draws inside the em" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    const em: f32 = @floatFromInt(units_per_em);
    for (builtin) |b| {
        o.reset(units_per_em);
        svgpath.parse(gpa, &o, b.d, .{ .transform = svgpath.viewBox(grid, em) }) catch |err| {
            std.debug.print("icon '{s}': {t}\n", .{ b.name, err });
            return err;
        };
        try testing.expect(!o.isEmpty());

        // Drawn on the grid it says it is drawn on. An icon that overflows
        // the em is one that will be clipped by a neighbour's cell in the
        // atlas, which reads as a stray line through the next glyph along.
        const bounds = o.bounds();
        try testing.expect(bounds.min_x >= -1 and bounds.max_x <= em + 1);
        try testing.expect(bounds.min_y >= -1 and bounds.max_y <= em + 1);

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

const geom = @import("../../gelgja/geom.zig");

test "an icon added by a theme is drawn by the same face" {
    const gpa = testing.allocator;
    var face = try create(gpa);
    defer face.deinit(gpa);

    const set = setOf(face).?;
    var name: [8]u8 = "sparkle\x00".*;
    const g = try set.add(name[0..7], "M12 2 14 10 22 12 14 14 12 22 10 14 2 12 10 10z");
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
