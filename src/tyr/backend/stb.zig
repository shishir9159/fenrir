//! stb_truetype, behind `Face.VTable`. Built only with `-Dstb-truetype`,
//! which also requires `vendor/stb/stb_truetype.h` to be present.
//!
//! NOT COMPILED BY DEFAULT, AND NOT COMPILED ON THE MACHINE THIS WAS WRITTEN
//! ON -- the header is not vendored here. Same caveat as the FreeType file:
//! checked in so the interface has a second real implementation shaping it,
//! not because it has been through a compiler.
//!
//! Why have it at all, next to FreeType. It is one public-domain header with
//! no build system, so `-Dstb-truetype` works identically on Windows, Linux
//! and a cross-compile, where `-Dfreetype` depends on whatever the host
//! happens to have installed. For a project whose test plan is "render the
//! same page two ways and diff", a backend that is trivially reproducible on
//! every machine is worth more than one that is more capable.
//!
//! What it cannot do, and why `Capabilities` is not decoration: **stb has no
//! glyph names.** There is no `stbtt_FindGlyphIndexByName`, because the `post`
//! table and the CFF charset are not parsed. Every Type 1 font and every CFF
//! font selected through an `/Encoding` `/Differences` array names its glyphs
//! -- `/aacute`, `/summation` -- and that is a large share of real PDFs. A
//! build with only this backend renders those through `cmap` when the name
//! maps back to a code point, and boxes otherwise.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const format = @import("../format.zig");
const geom = @import("../../gelgja/geom.zig");

const GlyphIndex = Face.GlyphIndex;
const Point = geom.Point;

const c = @cImport({
    @cDefine("STB_TRUETYPE_IMPLEMENTATION", "1");
    @cDefine("STBTT_STATIC", "1");
    @cInclude("stb_truetype.h");
});

pub const backend: Face.Backend = .{
    .name = "stb",
    .caps = .{
        .truetype = true,
        // stb_truetype has read CFF/Type 2 charstrings since 1.20. Older
        // vendored copies will fail at `open` rather than misrender, which is
        // the right way round.
        .cff = true,
        .cmap = true,
        .rasterize = true,
        // The gap. See the note at the top.
        .glyph_names = false,
        .hinting = false,
    },
    .open = open,
};

const State = struct {
    info: c.stbtt_fontinfo,
    /// stb keeps pointers into the font data; it never copies.
    bytes: []const u8,
    /// Scratch for `rasterize`, freed on the next call and at close. stb
    /// allocates the bitmap itself and hands over ownership.
    bitmap: ?[*]u8 = null,
};

fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
    if (bytes.len == 0) return error.UnsupportedFormat;

    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    state.* = .{ .info = undefined, .bytes = bytes };

    const offset = c.stbtt_GetFontOffsetForIndex(bytes.ptr, @intCast(index));
    if (offset < 0) return error.UnsupportedFormat;
    if (c.stbtt_InitFont(&state.info, bytes.ptr, offset) == 0) return error.UnsupportedFormat;

    // stb exposes no `unitsPerEm` accessor, but it will scale one em to one
    // pixel on request, and that factor is exactly its reciprocal.
    const per_px = c.stbtt_ScaleForMappingEmToPixels(&state.info, 1.0);
    const upem: u16 = if (per_px > 0)
        @intFromFloat(@round(1.0 / per_px))
    else
        1000;

    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    c.stbtt_GetFontVMetrics(&state.info, &ascent, &descent, &line_gap);

    return .{
        .ptr = state,
        .vtable = &vtable,
        .data = bytes,
        .info = .{
            .units_per_em = if (upem == 0) 1000 else upem,
            .num_glyphs = @intCast(@max(state.info.numGlyphs, 0)),
            .ascender = @intCast(ascent),
            .descender = @intCast(descent),
            .line_gap = @intCast(line_gap),
            .format = format.sniff(bytes),
        },
        .caps = backend.caps,
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

/// Always null. `Face.glyphForName` short-circuits on `caps.glyph_names`
/// before reaching this, so it exists only to fill the vtable.
fn glyphForName(_: *anyopaque, _: []const u8) ?GlyphIndex {
    return null;
}

fn glyphForCodepoint(ptr: *anyopaque, cp: u21) ?GlyphIndex {
    const g = c.stbtt_FindGlyphIndex(&stateOf(ptr).info, @intCast(cp));
    return if (g <= 0) null else @intCast(g);
}

fn advance(ptr: *anyopaque, g: GlyphIndex) ?f32 {
    var adv: c_int = 0;
    var lsb: c_int = 0;
    c.stbtt_GetGlyphHMetrics(&stateOf(ptr).info, g, &adv, &lsb);
    return @floatFromInt(adv);
}

fn outline(ptr: *anyopaque, gpa: Allocator, g: GlyphIndex, out: *Outline) Face.Error!void {
    const state = stateOf(ptr);
    var verts: [*c]c.stbtt_vertex = null;
    const n = c.stbtt_GetGlyphShape(&state.info, g, &verts);
    // Zero is a legitimate answer: a space has no contours.
    if (n <= 0 or verts == null) return;
    defer c.stbtt_FreeShape(&state.info, verts);

    for (verts[0..@intCast(n)]) |v| {
        const to: Point = .{ .x = @floatFromInt(v.x), .y = @floatFromInt(v.y) };
        const ctrl: Point = .{ .x = @floatFromInt(v.cx), .y = @floatFromInt(v.cy) };
        switch (v.type) {
            c.STBTT_vmove => {
                try out.close(gpa);
                try out.moveTo(gpa, to);
            },
            c.STBTT_vline => try out.lineTo(gpa, to),
            c.STBTT_vcurve => try out.quadTo(gpa, ctrl, to),
            c.STBTT_vcubic => try out.cubicTo(
                gpa,
                ctrl,
                .{ .x = @floatFromInt(v.cx1), .y = @floatFromInt(v.cy1) },
                to,
            ),
            else => {},
        }
    }
    try out.close(gpa);
}

fn rasterize(ptr: *anyopaque, g: GlyphIndex, req: Face.Render) Face.Error!Face.Bitmap {
    const state = stateOf(ptr);
    if (state.bitmap) |b| {
        c.stbtt_FreeBitmap(b, null);
        state.bitmap = null;
    }

    // `ScaleForMappingEmToPixels`, not `ScaleForPixelHeight`. The latter fits
    // the ascender-to-descender span into `px_size`, which is a different and
    // font-dependent number; FreeType, `Face.unitScale`, and the atlas all
    // mean the em square. Using stb's other convention would make the same
    // requested size come out visibly different between two backends, which
    // is precisely the disagreement the backend diff is supposed to detect,
    // and it would be ours rather than the font's.
    const scale = c.stbtt_ScaleForMappingEmToPixels(&state.info, req.px_size);
    var w: c_int = 0;
    var h: c_int = 0;
    var xoff: c_int = 0;
    var yoff: c_int = 0;
    // The subpixel form shifts the outline before scan conversion, which is
    // the whole point; stb takes the shift in pixels and its y runs down, so
    // both offsets pass through unchanged.
    const bits = c.stbtt_GetGlyphBitmapSubpixel(
        &state.info,
        scale,
        scale,
        req.offset_x,
        req.offset_y,
        g,
        &w,
        &h,
        &xoff,
        &yoff,
    );
    if (bits == null) return .{};
    state.bitmap = bits;

    const width: u32 = @intCast(@max(w, 0));
    const height: u32 = @intCast(@max(h, 0));
    return .{
        .pixels = bits[0 .. width * height],
        .width = width,
        .height = height,
        .stride = width,
        .left = xoff,
        // stb reports the top edge as a downward offset from the baseline;
        // `Bitmap.top` is measured the other way, like FreeType's.
        .top = -yoff,
    };
}

fn deinit(ptr: *anyopaque, gpa: Allocator) void {
    const state = stateOf(ptr);
    if (state.bitmap) |b| c.stbtt_FreeBitmap(b, null);
    gpa.destroy(state);
}
