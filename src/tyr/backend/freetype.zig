//! FreeType, behind `Face.VTable`. Built only with `-Dfreetype`.
//!
//! NOT COMPILED BY DEFAULT, AND NOT COMPILED ON THE MACHINE THIS WAS WRITTEN
//! ON -- FreeType is not installed here, so this file has never been through
//! the compiler. Treat the first `-Dfreetype` build as a bring-up, not as a
//! regression. It is checked in anyway because the interface is only worth
//! believing if a real backend is written against it, and because everything
//! Týr's core does is shaped by what this file needs.
//!
//! FreeType is the reference here rather than the eventual answer. It reads
//! every format PDF can contain, including Type 1 and CID-keyed CFF, it knows
//! glyph names, and it hints. When Týr's own parsers are written, this is what
//! their output gets diffed against, glyph by glyph.
//!
//! One `FT_Library` per face, deliberately. A library instance is not thread
//! safe and a document is rendered from a thread pool; sharing one would need
//! a mutex on the hottest path in text rendering to save a few kilobytes per
//! font. Faces are opened once per document, so the cost is paid a dozen times
//! and never again.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const format = @import("../format.zig");

const GlyphIndex = Face.GlyphIndex;

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});

// Spelled out rather than taken from the header: these are `( 1L << n )`
// macros, which translate-c renders inconsistently across FreeType versions.
const FT_LOAD_NO_SCALE: i32 = 1 << 0;
const FT_LOAD_NO_HINTING: i32 = 1 << 1;
const FT_LOAD_RENDER: i32 = 1 << 2;
const FT_FACE_FLAG_FIXED_WIDTH: c_long = 1 << 2;
const FT_FACE_FLAG_GLYPH_NAMES: c_long = 1 << 9;

pub const backend: Face.Backend = .{
    .name = "freetype",
    .caps = .{
        .truetype = true,
        .cff = true,
        .type1 = true,
        .glyph_names = true,
        .cmap = true,
        .rasterize = true,
        .hinting = true,
        .variations = true,
    },
    .open = open,
};

const State = struct {
    library: c.FT_Library,
    face: c.FT_Face,
    /// FreeType reads the font lazily, so the bytes must outlive the face.
    /// They belong to the document's arena, which does outlive it, but
    /// stating the dependency here is cheaper than rediscovering it from a
    /// use-after-free in a glyph decode.
    bytes: []const u8,
};

fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
    if (bytes.len == 0) return error.UnsupportedFormat;

    const state = try gpa.create(State);
    errdefer gpa.destroy(state);

    var library: c.FT_Library = null;
    if (c.FT_Init_FreeType(&library) != 0) return error.BackendFailed;
    errdefer _ = c.FT_Done_FreeType(library);

    var face: c.FT_Face = null;
    const rc = c.FT_New_Memory_Face(
        library,
        bytes.ptr,
        @intCast(bytes.len),
        @intCast(index),
        &face,
    );
    if (rc != 0) return error.UnsupportedFormat;
    errdefer _ = c.FT_Done_Face(face);

    state.* = .{ .library = library, .face = face, .bytes = bytes };

    const flags = face.*.face_flags;
    const upem = face.*.units_per_EM;

    return .{
        .ptr = state,
        .vtable = &vtable,
        .data = bytes,
        .info = .{
            // A bitmap-only face reports 0, which would make every scale a
            // division by zero downstream.
            .units_per_em = if (upem == 0) 1000 else upem,
            .num_glyphs = @intCast(@max(face.*.num_glyphs, 0)),
            .ascender = face.*.ascender,
            .descender = face.*.descender,
            .line_gap = @intCast(face.*.height - (face.*.ascender - face.*.descender)),
            .format = format.sniff(bytes),
            .is_fixed_pitch = (flags & FT_FACE_FLAG_FIXED_WIDTH) != 0,
        },
        // Narrowed from the backend's static capabilities by what this file
        // actually contains: a subsetted TrueType with no `post` table has no
        // glyph names, however much FreeType can do in general.
        .caps = .{
            .truetype = true,
            .cff = true,
            .type1 = true,
            .glyph_names = (flags & FT_FACE_FLAG_GLYPH_NAMES) != 0,
            .cmap = face.*.charmap != null,
            .rasterize = true,
            .hinting = true,
        },
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

fn stateOf(ptr: *anyopaque) *State {
    return @ptrCast(@alignCast(ptr));
}

fn glyphForName(ptr: *anyopaque, name: []const u8) ?GlyphIndex {
    // FT_Get_Name_Index takes a C string and PDF glyph names are bounded by
    // the spec at 127 bytes, so this cannot legitimately overflow.
    var buf: [128]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;

    const g = c.FT_Get_Name_Index(stateOf(ptr).face, &buf);
    return if (g == 0) null else @intCast(g);
}

fn glyphForCodepoint(ptr: *anyopaque, cp: u21) ?GlyphIndex {
    const g = c.FT_Get_Char_Index(stateOf(ptr).face, cp);
    return if (g == 0) null else @intCast(g);
}

fn advance(ptr: *anyopaque, g: GlyphIndex) ?f32 {
    const face = stateOf(ptr).face;
    if (c.FT_Load_Glyph(face, g, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING) != 0) return null;
    return @floatFromInt(face.*.glyph.*.metrics.horiAdvance);
}

/// The decompose callbacks run in C, so a Zig error cannot propagate out of
/// them. They stash it here and the caller re-raises it.
const Decompose = struct {
    gpa: Allocator,
    out: *Outline,
    err: ?Face.Error = null,

    fn point(v: [*c]const c.FT_Vector) @import("../../gelgja/geom.zig").Point {
        return .{ .x = @floatFromInt(v.*.x), .y = @floatFromInt(v.*.y) };
    }
};

fn moveTo(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const d: *Decompose = @ptrCast(@alignCast(user.?));
    // FreeType leaves the last contour open; closing here rather than after
    // the walk keeps the outline valid at every point.
    d.out.close(d.gpa) catch |e| {
        d.err = e;
        return 1;
    };
    d.out.moveTo(d.gpa, Decompose.point(to)) catch |e| {
        d.err = e;
        return 1;
    };
    return 0;
}

fn lineTo(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const d: *Decompose = @ptrCast(@alignCast(user.?));
    d.out.lineTo(d.gpa, Decompose.point(to)) catch |e| {
        d.err = e;
        return 1;
    };
    return 0;
}

fn conicTo(ctrl: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const d: *Decompose = @ptrCast(@alignCast(user.?));
    d.out.quadTo(d.gpa, Decompose.point(ctrl), Decompose.point(to)) catch |e| {
        d.err = e;
        return 1;
    };
    return 0;
}

fn cubicTo(
    c1: [*c]const c.FT_Vector,
    c2: [*c]const c.FT_Vector,
    to: [*c]const c.FT_Vector,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const d: *Decompose = @ptrCast(@alignCast(user.?));
    d.out.cubicTo(d.gpa, Decompose.point(c1), Decompose.point(c2), Decompose.point(to)) catch |e| {
        d.err = e;
        return 1;
    };
    return 0;
}

fn outline(ptr: *anyopaque, gpa: Allocator, g: GlyphIndex, out: *Outline) Face.Error!void {
    const face = stateOf(ptr).face;
    // NO_SCALE gives font units, which is what `Outline` is documented to
    // hold; NO_HINTING because hints are grid fitting for a pixel size that
    // does not exist yet.
    if (c.FT_Load_Glyph(face, g, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING) != 0) {
        return error.Unsupported;
    }

    var d: Decompose = .{ .gpa = gpa, .out = out };
    const funcs: c.FT_Outline_Funcs = .{
        .move_to = moveTo,
        .line_to = lineTo,
        .conic_to = conicTo,
        .cubic_to = cubicTo,
        .shift = 0,
        .delta = 0,
    };

    const rc = c.FT_Outline_Decompose(&face.*.glyph.*.outline, &funcs, &d);
    if (d.err) |e| return e;
    if (rc != 0) return error.CorruptFont;
    try out.close(gpa);
}

fn rasterize(ptr: *anyopaque, g: GlyphIndex, px_size: f32) Face.Error!Face.Bitmap {
    const face = stateOf(ptr).face;
    const px: c_uint = @intFromFloat(@max(1, @round(px_size)));
    if (c.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.BackendFailed;
    if (c.FT_Load_Glyph(face, g, FT_LOAD_RENDER) != 0) return error.Unsupported;

    const slot = face.*.glyph;
    const bmp = slot.*.bitmap;
    // A space has a real advance and no pixels; that is not an error.
    if (bmp.buffer == null) return .{};

    const rows: u32 = bmp.rows;
    const pitch: u32 = @intCast(@abs(bmp.pitch));
    return .{
        .pixels = bmp.buffer[0 .. rows * pitch],
        .width = bmp.width,
        .height = rows,
        .stride = pitch,
        .left = slot.*.bitmap_left,
        .top = slot.*.bitmap_top,
    };
}

fn deinit(ptr: *anyopaque, gpa: Allocator) void {
    const state = stateOf(ptr);
    _ = c.FT_Done_Face(state.face);
    _ = c.FT_Done_FreeType(state.library);
    gpa.destroy(state);
}
