//! Turning a string into positioned glyphs. HarfBuzz's job, and a separate
//! axis from `Face`.
//!
//! It is worth being blunt about this, because "font backend" is usually said
//! as though FreeType, stb_truetype and HarfBuzz were three answers to one
//! question. They are not. FreeType and stb_truetype are *glyph sources*: give
//! them an index, they give you an outline. HarfBuzz is a *shaper*: give it a
//! Unicode string, it gives you which glyphs, in which order, at which
//! offsets, after applying the font's ligature, kerning, mark-attachment and
//! reordering rules. HarfBuzz cannot draw a glyph; FreeType cannot decide that
//! `fi` should become one.
//!
//! The consequence for this program is sharper still: **a PDF page never needs
//! shaping.** A content stream does not contain text, it contains glyph
//! selectors and explicit positions. The producer already ran a shaper, years
//! ago, on another machine, and baked the answer into `Tj` and `TJ`. Shaping
//! that data again would substitute our opinion of how the font should behave
//! for the one the document was laid out with, and the page would no longer
//! match the paper it was printed from. Extraction runs the other way, through
//! `/ToUnicode`.
//!
//! So this interface exists for exactly one consumer: the UI. Menus, the
//! search box, page labels, tooltips -- text that Fenrir itself composes and
//! that has never been shaped by anyone. That is a small enough surface that
//! the built-in shaper below covers Latin entirely, and a big enough one that
//! a build wanting correct Arabic or Devanagari in its own chrome can link
//! HarfBuzz and get it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("Face.zig");

const Shaper = @This();

ptr: *anyopaque,
vtable: *const VTable,
name: []const u8,

pub const Error = error{ OutOfMemory, ShaperFailed };

pub const Direction = enum { ltr, rtl, ttb };

/// One glyph as a shaper places it. Advances and offsets are in font units,
/// matching `Face` and `Outline`; the caller scales by `size / units_per_em`.
pub const Positioned = struct {
    glyph: Face.GlyphIndex,
    /// Byte offset into the input this glyph came from. Several glyphs can
    /// share a cluster (a decomposed accent) and one glyph can cover several
    /// bytes (a ligature), which is why this is not an index.
    cluster: u32,
    x_advance: f32 = 0,
    y_advance: f32 = 0,
    x_offset: f32 = 0,
    y_offset: f32 = 0,
};

pub const Request = struct {
    text: []const u8,
    direction: Direction = .ltr,
    /// An ISO 15924 tag such as `Arab`, or empty to let the shaper guess.
    script: []const u8 = "",
    /// A BCP 47 tag such as `tr`, which changes `i` casing and a few
    /// ligatures. Ignored by the built-in shaper.
    language: []const u8 = "",
};

pub const VTable = struct {
    /// Appends to `out` rather than returning a slice, so a caller laying out
    /// a paragraph reuses one buffer across runs.
    shape: *const fn (
        ptr: *anyopaque,
        gpa: Allocator,
        face: Face,
        req: Request,
        out: *std.ArrayList(Positioned),
    ) Error!void,
    deinit: *const fn (ptr: *anyopaque, gpa: Allocator) void,
};

pub fn shape(
    s: Shaper,
    gpa: Allocator,
    face: Face,
    req: Request,
    out: *std.ArrayList(Positioned),
) Error!void {
    return s.vtable.shape(s.ptr, gpa, face, req, out);
}

pub fn deinit(s: *Shaper, gpa: Allocator) void {
    s.vtable.deinit(s.ptr, gpa);
    s.* = undefined;
}

// -- the built-in shaper ----------------------------------------------------

/// One glyph per code point, advances from the face, no substitution and no
/// kerning. Correct for Latin, Greek and Cyrillic without ligatures, which is
/// what Fenrir's own chrome is written in; visibly wrong for Arabic and Indic
/// scripts, which is why the HarfBuzz backend exists.
pub const simple: Shaper = .{
    // Stateless, so the instance pointer is never dereferenced. A dummy
    // address rather than `undefined` keeps it valid to copy and compare.
    .ptr = @constCast(@ptrCast(&simple_tag)),
    .vtable = &simple_vtable,
    .name = "simple",
};

const simple_tag: u8 = 0;

const simple_vtable: VTable = .{
    .shape = simpleShape,
    .deinit = simpleDeinit,
};

fn simpleShape(
    _: *anyopaque,
    gpa: Allocator,
    face: Face,
    req: Request,
    out: *std.ArrayList(Positioned),
) Error!void {
    var it: std.unicode.Utf8Iterator = .{ .bytes = req.text, .i = 0 };
    while (true) {
        const start = it.i;
        const cp = it.nextCodepoint() orelse break;
        const g = face.glyphForCodepoint(cp) orelse Face.notdef;
        try out.append(gpa, .{
            .glyph = g,
            .cluster = @intCast(start),
            .x_advance = face.advance(g) orelse 0,
        });
    }
    // Right-to-left with no reordering is still better than dropping the run:
    // the glyphs are right and only the order is wrong, which is legible.
    if (req.direction == .rtl) std.mem.reverse(Positioned, out.items);
}

fn simpleDeinit(_: *anyopaque, _: Allocator) void {}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const registry = @import("registry.zig");

test "the simple shaper emits one glyph per code point" {
    const gpa = testing.allocator;
    var face = try registry.open(gpa, "", .{});
    defer face.deinit(gpa);

    var out: std.ArrayList(Positioned) = .empty;
    defer out.deinit(gpa);

    // Six code points, one of them three bytes long.
    try simple.shape(gpa, face, .{ .text = "Tyr\u{2014}!" }, &out);
    try testing.expectEqual(@as(usize, 5), out.items.len);

    // Clusters are byte offsets, so the em dash makes the last one jump.
    try testing.expectEqual(@as(u32, 0), out.items[0].cluster);
    try testing.expectEqual(@as(u32, 3), out.items[3].cluster);
    try testing.expectEqual(@as(u32, 6), out.items[4].cluster);
}

test "a face with no cmap yields notdef rather than nothing" {
    const gpa = testing.allocator;
    var face = try registry.open(gpa, "", .{});
    defer face.deinit(gpa);

    var out: std.ArrayList(Positioned) = .empty;
    defer out.deinit(gpa);

    try simple.shape(gpa, face, .{ .text = "ab" }, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    for (out.items) |p| try testing.expectEqual(Face.notdef, p.glyph);
}

test "shaping appends, so one buffer serves a paragraph" {
    const gpa = testing.allocator;
    var face = try registry.open(gpa, "", .{});
    defer face.deinit(gpa);

    var out: std.ArrayList(Positioned) = .empty;
    defer out.deinit(gpa);

    try simple.shape(gpa, face, .{ .text = "ab" }, &out);
    try simple.shape(gpa, face, .{ .text = "cd" }, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
}

test "an empty string shapes to nothing" {
    const gpa = testing.allocator;
    var face = try registry.open(gpa, "", .{});
    defer face.deinit(gpa);

    var out: std.ArrayList(Positioned) = .empty;
    defer out.deinit(gpa);

    try simple.shape(gpa, face, .{ .text = "" }, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
