//! The backend that is always compiled in.
//!
//! It is not a font renderer. It opens anything, claims nothing, and draws
//! every glyph as a `.notdef` box: the hollow rectangle a real font puts at
//! index 0. Three jobs justify it.
//!
//! It keeps the build honest. `zig build` with no options links no C at all,
//! so the parser, the interpreter and the display list stay testable on a
//! machine with no FreeType, which is most CI images and, at the time of
//! writing, this one.
//!
//! It fails visibly. A missing glyph that draws nothing is indistinguishable
//! from correct output on a page that happened to have no text there. A row of
//! boxes is unmistakably wrong, in the right place, at the right size --
//! which means positioning can be debugged before shaping works, and PDF
//! positioning is entirely `/Widths` and `TJ` offsets, neither of which comes
//! from the font program.
//!
//! It is the reference implementation of `Face.VTable`. Everything a backend
//! must provide is here, in sixty lines, with no C in the way.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const format = @import("../format.zig");

const GlyphIndex = Face.GlyphIndex;

pub const backend: Face.Backend = .{
    .name = "fallback",
    // It claims every format, because refusing would leave a build with no
    // real backend unable to open anything at all. The registry only reaches
    // it after every other backend has declined.
    .caps = .{ .truetype = true, .cff = true, .type1 = true },
    .open = open,
};

const State = struct {
    units_per_em: u16,
};

fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
    _ = index;
    const state = try gpa.create(State);
    state.* = .{ .units_per_em = 1000 };
    return .{
        .ptr = state,
        .vtable = &vtable,
        .data = bytes,
        .info = .{
            .units_per_em = state.units_per_em,
            // Zero, not a guess. A caller that needs a real count must ask a
            // real backend, and a bounds check against a fabricated number
            // would reject glyphs this face is perfectly willing to draw.
            .num_glyphs = 0,
            .ascender = 750,
            .descender = -250,
            .format = format.sniff(bytes),
        },
        .caps = .{},
        .backend = backend.name,
    };
}

const vtable: Face.VTable = .{
    .glyphForName = glyphForName,
    .glyphForCodepoint = glyphForCodepoint,
    .advance = advance,
    .outline = outline,
    .rasterize = rasterize,
    .deinit = deinit,
};

fn glyphForName(_: *anyopaque, _: []const u8) ?GlyphIndex {
    return null;
}

fn glyphForCodepoint(_: *anyopaque, _: u21) ?GlyphIndex {
    return null;
}

/// Half an em. Only ever consulted when the PDF gave no `/Widths` entry, which
/// for a font this backend is standing in for means the text was already going
/// to be misplaced.
fn advance(_: *anyopaque, _: GlyphIndex) ?f32 {
    return 500;
}

/// The `.notdef` box: an outer contour and an inner one wound the other way,
/// so the nonzero rule leaves it hollow. Winding it the same way would give a
/// solid black slab, which is both uglier and a worse diagnostic -- a hollow
/// box reads as "no glyph", a filled one reads as "broken rasteriser".
fn outline(_: *anyopaque, gpa: Allocator, _: GlyphIndex, out: *Outline) Face.Error!void {
    const o = struct {
        const x0: f32 = 60;
        const y0: f32 = 0;
        const x1: f32 = 440;
        const y1: f32 = 700;
        const t: f32 = 40;
    };

    // Outer, counter-clockwise.
    try out.moveTo(gpa, .{ .x = o.x0, .y = o.y0 });
    try out.lineTo(gpa, .{ .x = o.x1, .y = o.y0 });
    try out.lineTo(gpa, .{ .x = o.x1, .y = o.y1 });
    try out.lineTo(gpa, .{ .x = o.x0, .y = o.y1 });
    try out.close(gpa);

    // Inner, clockwise.
    try out.moveTo(gpa, .{ .x = o.x0 + o.t, .y = o.y0 + o.t });
    try out.lineTo(gpa, .{ .x = o.x0 + o.t, .y = o.y1 - o.t });
    try out.lineTo(gpa, .{ .x = o.x1 - o.t, .y = o.y1 - o.t });
    try out.lineTo(gpa, .{ .x = o.x1 - o.t, .y = o.y0 + o.t });
    try out.close(gpa);
}

fn rasterize(_: *anyopaque, _: GlyphIndex, _: Face.Render) Face.Error!Bitmap {
    return error.Unsupported;
}

const Bitmap = Face.Bitmap;

fn deinit(ptr: *anyopaque, gpa: Allocator) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    gpa.destroy(state);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "opens anything and reports the sniffed format" {
    const gpa = testing.allocator;
    var face = try backend.open(gpa, &.{ 0, 1, 0, 0 }, 0);
    defer face.deinit(gpa);

    try testing.expectEqualStrings("fallback", face.backend);
    try testing.expectEqual(format.Format.truetype, face.info.format);
    try testing.expectEqual(@as(u16, 1000), face.info.units_per_em);
}

test "opens empty bytes rather than failing" {
    const gpa = testing.allocator;
    // A font stream that failed to decompress still has to yield a face, or
    // one broken font takes the whole page down with it.
    var face = try backend.open(gpa, "", 0);
    defer face.deinit(gpa);
    try testing.expectEqual(format.Format.unknown, face.info.format);
}

test "every glyph is a hollow notdef box" {
    const gpa = testing.allocator;
    var face = try backend.open(gpa, "", 0);
    defer face.deinit(gpa);

    var out: Outline = .{};
    defer out.deinit(gpa);
    try face.outline(gpa, 42, &out);

    try testing.expectEqual(@as(u32, 2), out.contourCount());
    const b = out.bounds();
    try testing.expectEqual(@as(f32, 60), b.min_x);
    try testing.expectEqual(@as(f32, 700), b.max_y);

    // A second glyph reuses the buffer and does not accumulate.
    try face.outline(gpa, 7, &out);
    try testing.expectEqual(@as(u32, 2), out.contourCount());
}

test "declares no capabilities, so lookups short-circuit" {
    const gpa = testing.allocator;
    var face = try backend.open(gpa, "", 0);
    defer face.deinit(gpa);

    try testing.expectEqual(@as(?GlyphIndex, null), face.glyphForName("A"));
    try testing.expectEqual(@as(?GlyphIndex, null), face.glyphForCodepoint('A'));
    try testing.expectError(error.Unsupported, face.rasterize(0, .{ .px_size = 12 }));
    try testing.expectEqual(@as(?f32, 500), face.advance(0));
}
