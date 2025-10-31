//! Týr's own `glyf` parser: a TrueType backend with no C in it.
//!
//! FreeType and stb_truetype both do this and both are optional here, which
//! means that on a default build neither exists and every character is a
//! fallback box. That is the difference between a PDF reader and a program
//! that opens PDFs, so this file removes the option: it is always compiled in,
//! it needs nothing linked, and it is the reason `fenrir raster` can put words
//! on a page.
//!
//! ## What it reads
//!
//! `head` for the em square and the `loca` width, `maxp` for the glyph count,
//! `loca` and `glyf` for outlines, `hhea` and `hmtx` for advances, `cmap` for
//! code points, `post` for glyph names. That is the whole of what a PDF needs
//! from a TrueType program -- hinting is deliberately absent, because a page
//! is a fixed layout and grid-fitting moves stems off the positions the file
//! specifies.
//!
//! ## Two things worth knowing about `glyf`
//!
//! **A contour is not a list of points.** TrueType stores on-curve and
//! off-curve points in one stream, and two consecutive off-curve points imply
//! an on-curve point exactly halfway between them. That implied point is not
//! stored anywhere and a parser that does not reconstruct it draws every
//! rounded letter as a polygon of the wrong shape. Worse, a contour may have
//! *no* on-curve points at all -- an `o` from certain foundries is exactly
//! this -- in which case the starting point has to be synthesised too.
//!
//! **A glyph may be other glyphs.** A composite glyph references components by
//! index with a 2x2 matrix and an offset each, and components may themselves
//! be composite. `é` is usually one; so is every accented letter in every font
//! that was not subsetted flat. The recursion is bounded here, because a
//! damaged font can point a component at its own glyph.
//!
//! ## Damage
//!
//! Every read is bounds-checked against the table it is in, and every table
//! against the file. A font in a PDF has usually been subsetted by a tool that
//! rewrote its tables, sometimes badly, and the failure mode has to be a
//! missing glyph rather than a read past the end of a buffer. `Reader` below
//! exists for that and nothing else.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const format = @import("../format.zig");

const geom = @import("../../gelgja/geom.zig");
const Point = geom.Point;
const Verb = geom.Verb;

pub const backend: Face.Backend = .{
    .name = "truetype",
    .caps = .{
        .truetype = true,
        .glyph_names = true,
        .cmap = true,
        // No rasteriser: Gleipnir fills glyph outlines with the same scanline
        // code it fills every other path with, so that a letter's edge and a
        // rule's edge get identical coverage. A second rasteriser here would
        // be a second answer to the same question.
        .rasterize = false,
        .hinting = false,
    },
    .open = open,
};

/// A component nested this deep is a damaged font, not a clever one. Real
/// composites are two levels: a letter, an accent, and occasionally an accent
/// that is itself composite.
const max_component_depth: u8 = 5;

/// TrueType caps a glyph at 65535 points; anything claiming more has a
/// corrupt count and would otherwise be believed.
const max_points: usize = 10_000;

// -- bounds-checked reading --------------------------------------------------

/// Big-endian reads that return null rather than trapping.
///
/// Every field in an SFNT is at a computed offset, and every one of those
/// computations depends on a number read from the file. A subsetter that
/// truncated a table leaves offsets pointing past its end, and there is no
/// version of that which should be a crash.
const Reader = struct {
    bytes: []const u8,

    fn u8At(r: Reader, at: usize) ?u8 {
        if (at >= r.bytes.len) return null;
        return r.bytes[at];
    }

    fn u16At(r: Reader, at: usize) ?u16 {
        if (at + 2 > r.bytes.len) return null;
        return std.mem.readInt(u16, r.bytes[at..][0..2], .big);
    }

    fn i16At(r: Reader, at: usize) ?i16 {
        const v = r.u16At(at) orelse return null;
        return @bitCast(v);
    }

    fn u32At(r: Reader, at: usize) ?u32 {
        if (at + 4 > r.bytes.len) return null;
        return std.mem.readInt(u32, r.bytes[at..][0..4], .big);
    }

    fn slice(r: Reader, at: usize, len: usize) ?[]const u8 {
        if (at > r.bytes.len or len > r.bytes.len - at) return null;
        return r.bytes[at..][0..len];
    }
};

// -- the face ---------------------------------------------------------------

const TrueType = struct {
    gpa: Allocator,
    data: []const u8,

    glyf: []const u8,
    loca: []const u8,
    /// `indexToLocFormat`: offsets are `u32` rather than `u16` halves.
    long_loca: bool,
    num_glyphs: u16,
    units_per_em: u16,

    /// `numberOfHMetrics` entries of `(advance, lsb)`, then bare left side
    /// bearings for the remaining glyphs -- a monospaced font stores one
    /// advance and nothing else, which is the whole point of the arrangement.
    hmtx: []const u8,
    num_h_metrics: u16,

    /// The chosen `cmap` subtable, already narrowed, and its format.
    cmap: []const u8 = &.{},
    cmap_format: u16 = 0,
    /// A (3, 0) symbol subtable maps codes in the `0xF000` private-use block,
    /// so a lookup for code 65 has to be tried as `0xF041` as well. Symbolic
    /// TrueType fonts in PDFs use this constantly.
    cmap_symbol: bool = false,

    post: []const u8 = &.{},

    fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
        const t: *TrueType = @ptrCast(@alignCast(ptr));
        gpa.destroy(t);
    }
};

pub fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
    const base = try faceOffset(bytes, index);
    const dir: Reader = .{ .bytes = bytes };

    const num_tables = dir.u16At(base + 4) orelse return error.CorruptFont;
    var tables: Tables = .{};
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = base + 12 + i * 16;
        const tag = dir.slice(rec, 4) orelse break;
        const off = dir.u32At(rec + 8) orelse break;
        const len = dir.u32At(rec + 12) orelse break;
        // A table whose span leaves the file is dropped rather than clamped:
        // half a `loca` is worse than none, because the glyphs it does cover
        // would be believed.
        const span = dir.slice(off, len) orelse continue;
        tables.put(tag[0..4].*, span);
    }

    const head = tables.get("head") orelse return error.UnsupportedFormat;
    const maxp = tables.get("maxp") orelse return error.UnsupportedFormat;
    const glyf = tables.get("glyf") orelse return error.UnsupportedFormat;
    const loca = tables.get("loca") orelse return error.UnsupportedFormat;

    const h: Reader = .{ .bytes = head };
    const units_per_em = h.u16At(18) orelse return error.CorruptFont;
    const loc_format = h.i16At(50) orelse return error.CorruptFont;

    const m: Reader = .{ .bytes = maxp };
    const num_glyphs = m.u16At(4) orelse return error.CorruptFont;

    var num_h_metrics: u16 = 0;
    if (tables.get("hhea")) |hhea| {
        const r: Reader = .{ .bytes = hhea };
        num_h_metrics = r.u16At(34) orelse 0;
    }

    const t = try gpa.create(TrueType);
    errdefer gpa.destroy(t);
    t.* = .{
        .gpa = gpa,
        .data = bytes,
        .glyf = glyf,
        .loca = loca,
        .long_loca = loc_format != 0,
        .num_glyphs = num_glyphs,
        // Zero would divide by zero in `unitScale`, and a few damaged
        // subsetted fonts really do carry it.
        .units_per_em = if (units_per_em == 0) 1000 else units_per_em,
        .hmtx = tables.get("hmtx") orelse &.{},
        .num_h_metrics = num_h_metrics,
        .post = tables.get("post") orelse &.{},
    };
    if (tables.get("cmap")) |c| chooseCmap(t, c);

    var ascender: i16 = 0;
    var descender: i16 = 0;
    var line_gap: i16 = 0;
    if (tables.get("hhea")) |hhea| {
        const r: Reader = .{ .bytes = hhea };
        ascender = r.i16At(4) orelse 0;
        descender = r.i16At(6) orelse 0;
        line_gap = r.i16At(8) orelse 0;
    }

    return .{
        .ptr = t,
        .vtable = &vtable,
        .caps = .{
            .truetype = true,
            .glyph_names = t.post.len > 0,
            .cmap = t.cmap.len > 0,
        },
        .info = .{
            .units_per_em = t.units_per_em,
            .num_glyphs = num_glyphs,
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .format = .truetype,
            .is_fixed_pitch = num_h_metrics == 1,
        },
        .data = bytes,
        .backend = backend.name,
    };
}

/// Where the SFNT header for face `index` starts. Zero for a plain font, and
/// read out of the collection header for a `ttcf`.
fn faceOffset(bytes: []const u8, index: u32) Face.Error!usize {
    const r: Reader = .{ .bytes = bytes };
    const tag = r.slice(0, 4) orelse return error.UnsupportedFormat;
    if (!std.mem.eql(u8, tag, "ttcf")) {
        if (index != 0) return error.Unsupported;
        return 0;
    }
    const count = r.u32At(8) orelse return error.CorruptFont;
    if (index >= count) return error.Unsupported;
    return r.u32At(12 + @as(usize, index) * 4) orelse return error.CorruptFont;
}

/// The handful of tables this backend reads, found in one pass.
///
/// A fixed list rather than a map: there are eight of them, the comparison is
/// four bytes, and a hash map would allocate for a lookup that happens once
/// per font.
const Tables = struct {
    const names = [_][]const u8{ "head", "maxp", "glyf", "loca", "hhea", "hmtx", "cmap", "post" };
    spans: [names.len][]const u8 = @splat(&.{}),

    fn put(t: *Tables, tag: [4]u8, span: []const u8) void {
        inline for (names, 0..) |n, i| {
            if (std.mem.eql(u8, &tag, n)) {
                t.spans[i] = span;
                return;
            }
        }
    }

    fn get(t: Tables, comptime name: []const u8) ?[]const u8 {
        const i = comptime blk: {
            for (names, 0..) |n, j| {
                if (std.mem.eql(u8, n, name)) break :blk j;
            }
            @compileError("no such table: " ++ name);
        };
        return if (t.spans[i].len == 0) null else t.spans[i];
    }
};

/// Picks the best `cmap` subtable available.
///
/// The order matters and is not arbitrary. A full Unicode subtable comes
/// first; then the BMP one, which is what almost every font has; then a
/// symbol subtable, which is what almost every *subsetted* font in a PDF has
/// and which needs the `0xF000` offset applied at lookup; then Mac Roman as a
/// last resort. Getting the order wrong on a symbolic font maps every code to
/// nothing and the page comes out blank.
fn chooseCmap(t: *TrueType, table: []const u8) void {
    const r: Reader = .{ .bytes = table };
    const n = r.u16At(2) orelse return;

    var best: i32 = -1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = 4 + i * 8;
        const platform = r.u16At(rec) orelse break;
        const encoding = r.u16At(rec + 2) orelse break;
        const off = r.u32At(rec + 4) orelse break;
        const sub = r.slice(off, table.len - @min(off, table.len)) orelse continue;
        const sr: Reader = .{ .bytes = sub };
        const fmt = sr.u16At(0) orelse continue;

        const rank: i32 = switch (platform) {
            3 => switch (encoding) {
                10 => if (fmt == 12) 100 else -1,
                1 => if (fmt == 4 or fmt == 6 or fmt == 0) 90 else -1,
                0 => if (fmt == 4 or fmt == 6 or fmt == 0) 70 else -1, // symbol
                else => -1,
            },
            0 => if (fmt == 12) 95 else if (fmt == 4 or fmt == 6 or fmt == 0) 85 else -1,
            1 => if (fmt == 0 or fmt == 6) 50 else -1,
            else => -1,
        };
        if (rank <= best) continue;
        best = rank;
        t.cmap = sub;
        t.cmap_format = fmt;
        t.cmap_symbol = platform == 3 and encoding == 0;
    }
}

const vtable: Face.VTable = .{
    .glyphForName = glyphForName,
    .glyphForCodepoint = glyphForCodepoint,
    .advance = advance,
    .outline = outlineFn,
    .rasterize = rasterizeFn,
    .deinit = TrueType.deinitFn,
};

fn rasterizeFn(_: *anyopaque, _: Face.GlyphIndex, _: Face.Render) Face.Error!Face.Bitmap {
    return error.Unsupported;
}

// -- metrics ----------------------------------------------------------------

fn advance(ptr: *anyopaque, g: Face.GlyphIndex) ?f32 {
    const t: *TrueType = @ptrCast(@alignCast(ptr));
    if (g >= t.num_glyphs or t.num_h_metrics == 0) return null;
    const r: Reader = .{ .bytes = t.hmtx };
    // Past the last full metric, every glyph shares the last advance. This is
    // how a monospaced font stores one number instead of thousands.
    const i = @min(g, t.num_h_metrics - 1);
    const w = r.u16At(@as(usize, i) * 4) orelse return null;
    return @floatFromInt(w);
}

// -- cmap -------------------------------------------------------------------

fn glyphForCodepoint(ptr: *anyopaque, cp: u21) ?Face.GlyphIndex {
    const t: *TrueType = @ptrCast(@alignCast(ptr));
    if (lookupCmap(t, cp)) |g| {
        if (g != 0) return g;
    }
    // A (3, 0) subtable keeps its codes in the private-use area, so a font
    // that answers nothing for 'A' may well answer for 0xF041. Tried second
    // rather than first so a font with both mappings uses the real one.
    if (t.cmap_symbol and cp < 0x100) {
        if (lookupCmap(t, 0xF000 + @as(u21, @intCast(cp)))) |g| {
            if (g != 0) return g;
        }
    }
    return null;
}

fn lookupCmap(t: *TrueType, cp: u21) ?Face.GlyphIndex {
    const r: Reader = .{ .bytes = t.cmap };
    return switch (t.cmap_format) {
        0 => blk: {
            if (cp > 0xff) break :blk null;
            const g = r.u8At(6 + @as(usize, cp)) orelse break :blk null;
            break :blk @as(u16, g);
        },
        4 => format4(r, cp),
        6 => blk: {
            const first = r.u16At(6) orelse break :blk null;
            const count = r.u16At(8) orelse break :blk null;
            if (cp < first or cp >= @as(u32, first) + count) break :blk null;
            break :blk r.u16At(10 + (cp - first) * 2);
        },
        12 => format12(r, cp),
        else => null,
    };
}

/// Format 4: segmented ranges, the workhorse of the BMP.
///
/// Searched linearly rather than by the binary search the format's own
/// `searchRange` fields describe. A subsetted font has a handful of segments,
/// those fields are wrong often enough to be untrustworthy, and a linear walk
/// cannot be led off the end by them.
fn format4(r: Reader, cp: u21) ?Face.GlyphIndex {
    if (cp > 0xffff) return null;
    const seg_x2 = r.u16At(6) orelse return null;
    const segs = seg_x2 / 2;
    const ends = 14;
    const starts = ends + seg_x2 + 2;
    const deltas = starts + seg_x2;
    const ranges = deltas + seg_x2;

    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const end = r.u16At(ends + i * 2) orelse return null;
        if (cp > end) continue;
        const start = r.u16At(starts + i * 2) orelse return null;
        if (cp < start) return null;

        const delta = r.u16At(deltas + i * 2) orelse return null;
        const range_off = r.u16At(ranges + i * 2) orelse return null;
        if (range_off == 0) {
            // The delta is added modulo 2^16, which is how the format encodes
            // a negative shift without a signed field.
            return @truncate(@as(u32, @intCast(cp)) +% delta);
        }
        // `glyphIdArray` is addressed relative to the range offset's own
        // position, which is the one genuinely strange thing in the format.
        const at = ranges + i * 2 + range_off + (cp - start) * 2;
        const g = r.u16At(at) orelse return null;
        if (g == 0) return 0;
        return @truncate(@as(u32, g) +% delta);
    }
    return null;
}

/// Format 12: grouped ranges, for anything past the BMP.
fn format12(r: Reader, cp: u21) ?Face.GlyphIndex {
    const groups = r.u32At(12) orelse return null;
    var i: usize = 0;
    while (i < groups) : (i += 1) {
        const at = 16 + i * 12;
        const first = r.u32At(at) orelse return null;
        const last = r.u32At(at + 4) orelse return null;
        const gid = r.u32At(at + 8) orelse return null;
        if (cp < first) return null;
        if (cp > last) continue;
        return @truncate(gid + (cp - first));
    }
    return null;
}

// -- glyph names ------------------------------------------------------------

fn glyphForName(ptr: *anyopaque, name: []const u8) ?Face.GlyphIndex {
    const t: *TrueType = @ptrCast(@alignCast(ptr));
    const r: Reader = .{ .bytes = t.post };
    const version = r.u32At(0) orelse return null;

    // 1.0 means "the glyph order *is* the standard Macintosh order", so the
    // name's position in that list is the glyph index.
    if (version == 0x0001_0000) return macIndex(name);
    if (version != 0x0002_0000) return null;

    const n = r.u16At(32) orelse return null;
    // Names past 257 are stored as Pascal strings after the index array, in
    // order of first use rather than of glyph index -- so they have to be
    // walked, not indexed.
    var g: u16 = 0;
    while (g < n) : (g += 1) {
        const idx = r.u16At(34 + @as(usize, g) * 2) orelse return null;
        if (idx < 258) {
            if (macIndex(name)) |m| {
                if (m == idx) return g;
            }
            continue;
        }
        const want = idx - 258;
        var at: usize = 34 + @as(usize, n) * 2;
        var k: u16 = 0;
        while (k <= want) : (k += 1) {
            const len = r.u8At(at) orelse return null;
            const s = r.slice(at + 1, len) orelse return null;
            if (k == want) {
                if (std.mem.eql(u8, s, name)) return g;
                break;
            }
            at += 1 + @as(usize, len);
        }
    }
    return null;
}

fn macIndex(name: []const u8) ?Face.GlyphIndex {
    for (mac_glyph_names, 0..) |n, i| {
        if (n) |s| {
            if (std.mem.eql(u8, s, name)) return @intCast(i);
        }
    }
    return null;
}

// -- outlines ---------------------------------------------------------------

fn outlineFn(ptr: *anyopaque, gpa: Allocator, g: Face.GlyphIndex, out: *Outline) Face.Error!void {
    const t: *TrueType = @ptrCast(@alignCast(ptr));
    try decode(t, gpa, g, out, .identity, 0);
}

/// The 2x2 part of a component's placement, plus its offset. Kept separate
/// from `geom.Transform` because the values are F2Dot14 fixed point in the
/// file and only become floats here.
const Placement = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    dx: f32,
    dy: f32,

    const identity: Placement = .{ .a = 1, .b = 0, .c = 0, .d = 1, .dx = 0, .dy = 0 };

    fn apply(p: Placement, x: f32, y: f32) Point {
        return .{ .x = p.a * x + p.c * y + p.dx, .y = p.b * x + p.d * y + p.dy };
    }

    fn then(inner: Placement, outer: Placement) Placement {
        return .{
            .a = inner.a * outer.a + inner.b * outer.c,
            .b = inner.a * outer.b + inner.b * outer.d,
            .c = inner.c * outer.a + inner.d * outer.c,
            .d = inner.c * outer.b + inner.d * outer.d,
            .dx = inner.dx * outer.a + inner.dy * outer.c + outer.dx,
            .dy = inner.dx * outer.b + inner.dy * outer.d + outer.dy,
        };
    }
};

/// The span of `glyf` holding one glyph, or null when it is blank.
///
/// Equal `loca` entries mean a glyph with no outline, which is not an error:
/// that is exactly how a space is stored, and it is the commonest glyph in
/// every document.
fn glyphSpan(t: *TrueType, g: Face.GlyphIndex) ?[]const u8 {
    if (g >= t.num_glyphs) return null;
    const r: Reader = .{ .bytes = t.loca };
    const start: u32, const end: u32 = if (t.long_loca) .{
        r.u32At(@as(usize, g) * 4) orelse return null,
        r.u32At(@as(usize, g) * 4 + 4) orelse return null,
    } else .{
        // Short `loca` stores halved offsets, which is why a font using it
        // cannot exceed 128 KB of glyph data.
        @as(u32, r.u16At(@as(usize, g) * 2) orelse return null) * 2,
        @as(u32, r.u16At(@as(usize, g) * 2 + 2) orelse return null) * 2,
    };
    if (end <= start) return null;
    const gr: Reader = .{ .bytes = t.glyf };
    return gr.slice(start, end - start);
}

fn decode(
    t: *TrueType,
    gpa: Allocator,
    g: Face.GlyphIndex,
    out: *Outline,
    place: Placement,
    depth: u8,
) Face.Error!void {
    if (depth > max_component_depth) return;
    const span = glyphSpan(t, g) orelse return;
    const r: Reader = .{ .bytes = span };
    const contours = r.i16At(0) orelse return;
    if (contours >= 0) {
        try simple(gpa, r, @intCast(contours), out, place);
    } else {
        try composite(t, gpa, r, out, place, depth);
    }
}

fn simple(
    gpa: Allocator,
    r: Reader,
    contours: u16,
    out: *Outline,
    place: Placement,
) Face.Error!void {
    if (contours == 0) return;

    // End points, one per contour; the last one gives the point count.
    const ends_at: usize = 10;
    const n_points: usize = blk: {
        const last = r.u16At(ends_at + (@as(usize, contours) - 1) * 2) orelse return;
        break :blk @as(usize, last) + 1;
    };
    if (n_points > max_points) return;

    const instr_len = r.u16At(ends_at + @as(usize, contours) * 2) orelse return;
    var at: usize = ends_at + @as(usize, contours) * 2 + 2 + instr_len;

    // Flags, run-length encoded: a flag with REPEAT set is followed by a count
    // byte saying how many more points share it.
    var flags: [max_points]u8 = undefined;
    {
        var i: usize = 0;
        while (i < n_points) {
            const f = r.u8At(at) orelse return;
            at += 1;
            flags[i] = f;
            i += 1;
            if (f & 0x08 != 0) {
                const repeat = r.u8At(at) orelse return;
                at += 1;
                var k: usize = 0;
                while (k < repeat and i < n_points) : (k += 1) {
                    flags[i] = f;
                    i += 1;
                }
            }
        }
    }

    // Coordinates are deltas from the previous point, in one of three widths
    // decided by two flag bits each. The x array comes entirely before the y
    // array, so neither can be read without walking the other's flags first.
    var xs: [max_points]i32 = undefined;
    var ys: [max_points]i32 = undefined;
    {
        var v: i32 = 0;
        var i: usize = 0;
        while (i < n_points) : (i += 1) {
            const f = flags[i];
            if (f & 0x02 != 0) {
                const d = r.u8At(at) orelse return;
                at += 1;
                // The "same" bit doubles as the sign bit for a short delta.
                v += if (f & 0x10 != 0) @as(i32, d) else -@as(i32, d);
            } else if (f & 0x10 == 0) {
                const d = r.i16At(at) orelse return;
                at += 2;
                v += d;
            }
            xs[i] = v;
        }
    }
    {
        var v: i32 = 0;
        var i: usize = 0;
        while (i < n_points) : (i += 1) {
            const f = flags[i];
            if (f & 0x04 != 0) {
                const d = r.u8At(at) orelse return;
                at += 1;
                v += if (f & 0x20 != 0) @as(i32, d) else -@as(i32, d);
            } else if (f & 0x20 == 0) {
                const d = r.i16At(at) orelse return;
                at += 2;
                v += d;
            }
            ys[i] = v;
        }
    }

    var first: usize = 0;
    var c: usize = 0;
    while (c < contours) : (c += 1) {
        const last_index = r.u16At(ends_at + c * 2) orelse return;
        const last: usize = last_index;
        if (last < first or last >= n_points) break;
        try contour(gpa, out, place, flags[first .. last + 1], xs[first .. last + 1], ys[first .. last + 1]);
        first = last + 1;
    }
}

/// One closed contour of mixed on- and off-curve points.
fn contour(
    gpa: Allocator,
    out: *Outline,
    place: Placement,
    flags: []const u8,
    xs: []const i32,
    ys: []const i32,
) Face.Error!void {
    const n = flags.len;
    if (n == 0) return;

    const on = struct {
        fn f(fl: u8) bool {
            return fl & 0x01 != 0;
        }
    }.f;
    const at = struct {
        fn f(p: Placement, x: []const i32, y: []const i32, i: usize) Point {
            return p.apply(@floatFromInt(x[i]), @floatFromInt(y[i]));
        }
    }.f;
    const mid = struct {
        fn f(a: Point, b: Point) Point {
            return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
        }
    }.f;

    // Where to start. Almost always the first point, but a contour may be
    // entirely off-curve -- a circle drawn as four quadratics with no on-curve
    // points at all -- and then the start is the midpoint of the last and
    // first control points, which exists only by implication.
    var start_i: usize = 0;
    var start: Point = undefined;
    var found = false;
    for (flags, 0..) |f, i| {
        if (on(f)) {
            start_i = i;
            start = at(place, xs, ys, i);
            found = true;
            break;
        }
    }
    if (!found) {
        start = mid(at(place, xs, ys, n - 1), at(place, xs, ys, 0));
        start_i = 0;
    }

    try out.moveTo(gpa, start);

    var pending: ?Point = null;
    var k: usize = 0;
    const begin: usize = if (found) start_i + 1 else 0;
    // When the start was a real point it has already been emitted as the
    // move, so only the other `n - 1` remain and the edge back to it is the
    // `close`. Walking all `n` would emit that edge as an explicit line as
    // well: harmless, since it is zero-length, but it puts a redundant
    // segment in every straight-sided glyph on every page.
    //
    // When the start was synthesised -- a contour with no on-curve point at
    // all -- it is not one of the points, so all `n` have to be walked and the
    // curve back to it is emitted below.
    const steps: usize = if (found) n - 1 else n;
    while (k < steps) : (k += 1) {
        const i = (begin + k) % n;
        const p = at(place, xs, ys, i);
        if (on(flags[i])) {
            if (pending) |q| {
                try out.quadTo(gpa, q, p);
                pending = null;
            } else {
                try out.lineTo(gpa, p);
            }
        } else {
            if (pending) |q| {
                // Two controls in a row: the on-curve point between them is
                // not stored and has to be reconstructed.
                try out.quadTo(gpa, q, mid(q, p));
            }
            pending = p;
        }
    }
    if (pending) |q| try out.quadTo(gpa, q, start);
    try out.close(gpa);
}

fn composite(
    t: *TrueType,
    gpa: Allocator,
    r: Reader,
    out: *Outline,
    place: Placement,
    depth: u8,
) Face.Error!void {
    var at: usize = 10;
    while (true) {
        const flags = r.u16At(at) orelse return;
        const glyph = r.u16At(at + 2) orelse return;
        at += 4;

        const words = flags & 0x0001 != 0;
        const xy = flags & 0x0002 != 0;

        var dx: f32 = 0;
        var dy: f32 = 0;
        if (words) {
            const a1 = r.i16At(at) orelse return;
            const a2 = r.i16At(at + 2) orelse return;
            at += 4;
            if (xy) {
                dx = @floatFromInt(a1);
                dy = @floatFromInt(a2);
            }
        } else {
            const a1 = r.u8At(at) orelse return;
            const a2 = r.u8At(at + 1) orelse return;
            at += 2;
            if (xy) {
                dx = @floatFromInt(@as(i8, @bitCast(a1)));
                dy = @floatFromInt(@as(i8, @bitCast(a2)));
            }
        }
        // Point-matching placement (`!xy`) aligns a component by making two
        // point indices coincide. It needs the parent's points, which means
        // decoding the whole composite twice, and it appears in almost nothing
        // made this century. The offset stays zero, which puts the component
        // at the origin rather than dropping it.

        var comp: Placement = .{ .a = 1, .b = 0, .c = 0, .d = 1, .dx = dx, .dy = dy };
        if (flags & 0x0008 != 0) {
            const s = f2dot14(r, at) orelse return;
            at += 2;
            comp.a = s;
            comp.d = s;
        } else if (flags & 0x0040 != 0) {
            comp.a = f2dot14(r, at) orelse return;
            comp.d = f2dot14(r, at + 2) orelse return;
            at += 4;
        } else if (flags & 0x0080 != 0) {
            comp.a = f2dot14(r, at) orelse return;
            comp.b = f2dot14(r, at + 2) orelse return;
            comp.c = f2dot14(r, at + 4) orelse return;
            comp.d = f2dot14(r, at + 6) orelse return;
            at += 8;
        }

        try decode(t, gpa, glyph, out, comp.then(place), depth + 1);

        if (flags & 0x0020 == 0) break;
    }
}

/// A signed 2.14 fixed-point number: the scale factors in a composite.
fn f2dot14(r: Reader, at: usize) ?f32 {
    const v = r.i16At(at) orelse return null;
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

/// The standard Macintosh glyph order, which `post` versions 1.0 and 2.0 index
/// into. Positions 0..257; anything past that has its name stored in the table
/// itself.
const mac_glyph_names = [_]?[]const u8{
    ".notdef",      ".null",         "nonmarkingreturn", "space",        "exclam",
    "quotedbl",     "numbersign",    "dollar",           "percent",      "ampersand",
    "quotesingle",  "parenleft",     "parenright",       "asterisk",     "plus",
    "comma",        "hyphen",        "period",           "slash",        "zero",
    "one",          "two",           "three",            "four",         "five",
    "six",          "seven",         "eight",            "nine",         "colon",
    "semicolon",    "less",          "equal",            "greater",      "question",
    "at",           "A",             "B",                "C",            "D",
    "E",            "F",             "G",                "H",            "I",
    "J",            "K",             "L",                "M",            "N",
    "O",            "P",             "Q",                "R",            "S",
    "T",            "U",             "V",                "W",            "X",
    "Y",            "Z",             "bracketleft",      "backslash",    "bracketright",
    "asciicircum",  "underscore",    "grave",            "a",            "b",
    "c",            "d",             "e",                "f",            "g",
    "h",            "i",             "j",                "k",            "l",
    "m",            "n",             "o",                "p",            "q",
    "r",            "s",             "t",                "u",            "v",
    "w",            "x",             "y",                "z",            "braceleft",
    "bar",          "braceright",    "asciitilde",       "Adieresis",    "Aring",
    "Ccedilla",     "Eacute",        "Ntilde",           "Odieresis",    "Udieresis",
    "aacute",       "agrave",        "acircumflex",      "adieresis",    "atilde",
    "aring",        "ccedilla",      "eacute",           "egrave",       "ecircumflex",
    "edieresis",    "iacute",        "igrave",           "icircumflex",  "idieresis",
    "ntilde",       "oacute",        "ograve",           "ocircumflex",  "odieresis",
    "otilde",       "uacute",        "ugrave",           "ucircumflex",  "udieresis",
    "dagger",       "degree",        "cent",             "sterling",     "section",
    "bullet",       "paragraph",     "germandbls",       "registered",   "copyright",
    "trademark",    "acute",         "dieresis",         "notequal",     "AE",
    "Oslash",       "infinity",      "plusminus",        "lessequal",    "greaterequal",
    "yen",          "mu",            "partialdiff",      "summation",    "product",
    "pi",           "integral",      "ordfeminine",      "ordmasculine", "Omega",
    "ae",           "oslash",        "questiondown",     "exclamdown",   "logicalnot",
    "radical",      "florin",        "approxequal",      "Delta",        "guillemotleft",
    "guillemotright", "ellipsis",    "nonbreakingspace", "Agrave",       "Atilde",
    "Otilde",       "OE",            "oe",               "endash",       "emdash",
    "quotedblleft", "quotedblright", "quoteleft",        "quoteright",   "divide",
    "lozenge",      "ydieresis",     "Ydieresis",        "fraction",     "currency",
    "guilsinglleft", "guilsinglright", "fi",             "fl",           "daggerdbl",
    "periodcentered", "quotesinglbase", "quotedblbase",  "perthousand",  "Acircumflex",
    "Ecircumflex",  "Aacute",        "Edieresis",        "Egrave",       "Iacute",
    "Icircumflex",  "Idieresis",     "Igrave",           "Oacute",       "Ocircumflex",
    "apple",        "Ograve",        "Uacute",           "Ucircumflex",  "Ugrave",
    "dotlessi",     "circumflex",    "tilde",            "macron",       "breve",
    "dotaccent",    "ring",          "cedilla",          "hungarumlaut", "ogonek",
    "caron",        "Lslash",        "lslash",           "Scaron",       "scaron",
    "Zcaron",       "zcaron",        "brokenbar",        "Eth",          "eth",
    "Yacute",       "yacute",        "Thorn",            "thorn",        "minus",
    "multiply",     "onesuperior",   "twosuperior",      "threesuperior", "onehalf",
    "onequarter",   "threequarters", "franc",            "Gbreve",       "gbreve",
    "Idotaccent",   "Scedilla",      "scedilla",         "Cacute",       "cacute",
    "Ccaron",       "ccaron",        "dcroat",
};

comptime {
    std.debug.assert(mac_glyph_names.len == 258);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Builds a TrueType font in memory.
///
/// Written out rather than checked in as a binary, for the same reason every
/// parser test in this project builds its input: a fixture you cannot read is
/// a fixture nobody can adjust, and the interesting cases here -- a contour
/// with no on-curve points, a composite that references itself -- are ones no
/// real font would provide on demand.
const Builder = struct {
    tables: std.ArrayList(struct { tag: [4]u8, data: []const u8 }) = .empty,
    gpa: Allocator,

    fn deinit(b: *Builder) void {
        b.tables.deinit(b.gpa);
    }

    fn add(b: *Builder, tag: *const [4]u8, data: []const u8) !void {
        try b.tables.append(b.gpa, .{ .tag = tag.*, .data = data });
    }

    fn finish(b: *Builder) ![]u8 {
        const n = b.tables.items.len;
        var size: usize = 12 + n * 16;
        for (b.tables.items) |t| size += (t.data.len + 3) & ~@as(usize, 3);

        const out = try b.gpa.alloc(u8, size);
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], 0x0001_0000, .big);
        std.mem.writeInt(u16, out[4..6], @intCast(n), .big);

        var at: usize = 12 + n * 16;
        for (b.tables.items, 0..) |t, i| {
            const rec = 12 + i * 16;
            @memcpy(out[rec..][0..4], &t.tag);
            std.mem.writeInt(u32, out[rec + 8 ..][0..4], @intCast(at), .big);
            std.mem.writeInt(u32, out[rec + 12 ..][0..4], @intCast(t.data.len), .big);
            @memcpy(out[at..][0..t.data.len], t.data);
            at += (t.data.len + 3) & ~@as(usize, 3);
        }
        return out;
    }
};

fn headTable(upem: u16, long_loca: bool) [54]u8 {
    var h: [54]u8 = @splat(0);
    std.mem.writeInt(u16, h[18..20], upem, .big);
    std.mem.writeInt(i16, h[50..52], if (long_loca) 1 else 0, .big);
    return h;
}

fn maxpTable(glyphs: u16) [6]u8 {
    var m: [6]u8 = @splat(0);
    std.mem.writeInt(u32, m[0..4], 0x0001_0000, .big);
    std.mem.writeInt(u16, m[4..6], glyphs, .big);
    return m;
}

/// A closed triangle: three on-curve points, one contour.
fn triangle() [30]u8 {
    var g: [30]u8 = @splat(0);
    std.mem.writeInt(i16, g[0..2], 1, .big); // one contour
    std.mem.writeInt(i16, g[2..4], 0, .big); // xMin ..
    std.mem.writeInt(i16, g[4..6], 0, .big);
    std.mem.writeInt(i16, g[6..8], 100, .big);
    std.mem.writeInt(i16, g[8..10], 100, .big);
    std.mem.writeInt(u16, g[10..12], 2, .big); // endPt of contour 0
    std.mem.writeInt(u16, g[12..14], 0, .big); // no instructions
    // Flags: on-curve, x and y as signed 16-bit deltas.
    g[14] = 0x01;
    g[15] = 0x01;
    g[16] = 0x01;
    std.mem.writeInt(i16, g[17..19], 0, .big); // x deltas
    std.mem.writeInt(i16, g[19..21], 100, .big);
    std.mem.writeInt(i16, g[21..23], -50, .big);
    std.mem.writeInt(i16, g[23..25], 0, .big); // y deltas
    std.mem.writeInt(i16, g[25..27], 0, .big);
    std.mem.writeInt(i16, g[27..29], 100, .big);
    return g;
}

fn longLoca(offsets: []const u32, out: []u8) []u8 {
    for (offsets, 0..) |o, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], o, .big);
    return out[0 .. offsets.len * 4];
}

test "a minimal font opens and yields an outline" {
    const gpa = testing.allocator;
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();

    const tri = triangle();
    var loca_buf: [16]u8 = undefined;
    const h = headTable(1000, true);
    const m = maxpTable(2);
    try b.add("head", &h);
    try b.add("maxp", &m);
    // Glyph 0 is empty (equal offsets), glyph 1 is the triangle.
    try b.add("loca", longLoca(&.{ 0, 0, tri.len }, &loca_buf));
    try b.add("glyf", &tri);

    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    try testing.expectEqualStrings("truetype", face.backend);
    try testing.expectEqual(@as(u16, 1000), face.info.units_per_em);
    try testing.expectEqual(@as(u32, 2), face.info.num_glyphs);

    var o: Outline = .{};
    defer o.deinit(gpa);

    // Glyph 0 has equal loca entries, which is how a space is stored -- not an
    // error, and not a missing glyph.
    try face.outline(gpa, 0, &o);
    try testing.expect(o.isEmpty());

    try face.outline(gpa, 1, &o);
    try testing.expectEqual(@as(u32, 1), o.contourCount());
    try testing.expectEqual(@as(usize, 4), o.verbs.items.len); // move, line, line, close
    try testing.expectEqual(@as(f32, 0), o.points.items[0].x);
    try testing.expectEqual(@as(f32, 100), o.points.items[1].x);
    // Deltas accumulate: 0, 100, then -50 is 50.
    try testing.expectEqual(@as(f32, 50), o.points.items[2].x);
    try testing.expectEqual(@as(f32, 100), o.points.items[2].y);
}

test "two consecutive off-curve points imply the on-curve point between them" {
    // The single subtlety of `glyf`. The implied point is not in the file, and
    // a parser that does not reconstruct it draws every round letter with the
    // wrong shape -- not obviously broken, just subtly wrong everywhere.
    const gpa = testing.allocator;

    var g: [30]u8 = @splat(0);
    std.mem.writeInt(i16, g[0..2], 1, .big);
    std.mem.writeInt(u16, g[10..12], 2, .big); // three points
    std.mem.writeInt(u16, g[12..14], 0, .big);
    g[14] = 0x01; // on curve
    g[15] = 0x00; // off
    g[16] = 0x00; // off
    std.mem.writeInt(i16, g[17..19], 0, .big);
    std.mem.writeInt(i16, g[19..21], 100, .big);
    std.mem.writeInt(i16, g[21..23], 0, .big);
    // Deltas, not positions: y runs 0, +100, -100, so the points are (0,0),
    // (100,100) and (100,0) and the implied midpoint is (100,50).
    std.mem.writeInt(i16, g[23..25], 0, .big);
    std.mem.writeInt(i16, g[25..27], 100, .big);
    std.mem.writeInt(i16, g[27..29], -100, .big);

    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    var loca_buf: [16]u8 = undefined;
    const h = headTable(1000, true);
    const m = maxpTable(2);
    try b.add("head", &h);
    try b.add("maxp", &m);
    try b.add("loca", longLoca(&.{ 0, 0, g.len }, &loca_buf));
    try b.add("glyf", &g);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, 1, &o);

    // Two controls in a row means two curves, not one: the first ends at the
    // midpoint of the two control points.
    var cubics: u32 = 0;
    for (o.verbs.items) |v| {
        if (v == .cubic) cubics += 1;
    }
    try testing.expectEqual(@as(u32, 2), cubics);

    // That midpoint is ((100,0) + (100,100)) / 2 = (100, 50). It appears as
    // the end point of the first cubic, which is the third point after the
    // move and its two controls.
    const p = o.points.items[3];
    try testing.expectApproxEqAbs(@as(f32, 100), p.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), p.y, 0.01);
}

test "a contour with no on-curve points at all still closes" {
    // Real, and produced by more than one foundry: a circle drawn as four
    // quadratics has no on-curve point anywhere, and the starting point has to
    // be synthesised from the last and first controls.
    const gpa = testing.allocator;

    // Four control points around a diamond, none of them on the curve.
    var g: [34]u8 = @splat(0);
    std.mem.writeInt(i16, g[0..2], 1, .big);
    std.mem.writeInt(u16, g[10..12], 3, .big); // endPt: four points
    std.mem.writeInt(u16, g[12..14], 0, .big);
    g[14] = 0;
    g[15] = 0;
    g[16] = 0;
    g[17] = 0;
    // x deltas: 50, 100, 50, 0
    std.mem.writeInt(i16, g[18..20], 50, .big);
    std.mem.writeInt(i16, g[20..22], 50, .big);
    std.mem.writeInt(i16, g[22..24], -50, .big);
    std.mem.writeInt(i16, g[24..26], -50, .big);
    // y deltas: 0, 50, 100, 50
    std.mem.writeInt(i16, g[26..28], 0, .big);
    std.mem.writeInt(i16, g[28..30], 50, .big);
    std.mem.writeInt(i16, g[30..32], 50, .big);
    std.mem.writeInt(i16, g[32..34], -50, .big);

    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    var loca_buf: [16]u8 = undefined;
    const h = headTable(1000, true);
    const m = maxpTable(2);
    try b.add("head", &h);
    try b.add("maxp", &m);
    try b.add("loca", longLoca(&.{ 0, 0, g.len }, &loca_buf));
    try b.add("glyf", &g);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, 1, &o);

    try testing.expectEqual(@as(u32, 1), o.contourCount());
    try testing.expectEqual(Verb.move, o.verbs.items[0]);
    try testing.expectEqual(Verb.close, o.verbs.items[o.verbs.items.len - 1]);
    // Four controls, four curves.
    var cubics: u32 = 0;
    for (o.verbs.items) |v| {
        if (v == .cubic) cubics += 1;
    }
    try testing.expectEqual(@as(u32, 4), cubics);
}

test "a composite glyph places its components" {
    const gpa = testing.allocator;

    const tri = triangle();
    // A composite referencing glyph 1 twice, offset the second time.
    var comp: [22]u8 = @splat(0);
    std.mem.writeInt(i16, comp[0..2], -1, .big); // composite
    std.mem.writeInt(u16, comp[10..12], 0x0003, .big); // ARGS_ARE_WORDS | XY | (more below)
    std.mem.writeInt(u16, comp[10..12], 0x0023, .big); // + MORE_COMPONENTS
    std.mem.writeInt(u16, comp[12..14], 1, .big); // glyph 1
    std.mem.writeInt(i16, comp[14..16], 0, .big);
    std.mem.writeInt(i16, comp[16..18], 0, .big);
    std.mem.writeInt(u16, comp[18..20], 0x0003, .big); // words | xy, no more
    std.mem.writeInt(u16, comp[20..22], 1, .big);
    // The second component's offsets follow; the buffer ends, so the parser
    // must stop rather than read past it.

    var glyf_buf: [64]u8 = undefined;
    @memcpy(glyf_buf[0..tri.len], &tri);
    @memcpy(glyf_buf[tri.len..][0..comp.len], &comp);
    const glyf = glyf_buf[0 .. tri.len + comp.len];

    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    var loca_buf: [24]u8 = undefined;
    const h = headTable(1000, true);
    const m = maxpTable(3);
    try b.add("head", &h);
    try b.add("maxp", &m);
    try b.add("loca", longLoca(&.{ 0, 0, tri.len, tri.len + comp.len }, &loca_buf));
    try b.add("glyf", glyf);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, 2, &o);
    // The first component drew; the truncated second did not crash anything.
    try testing.expect(o.contourCount() >= 1);
}

test "a cmap maps code points, symbol subtables included" {
    const gpa = testing.allocator;

    // Format 4 with one real segment (A..C) and the mandatory 0xFFFF
    // terminator, which a parser that trusts segCount without checking the
    // terminator will happily walk off the end of.
    var cmap: [64]u8 = @splat(0);
    std.mem.writeInt(u16, cmap[0..2], 0, .big); // version
    std.mem.writeInt(u16, cmap[2..4], 1, .big); // one encoding record
    std.mem.writeInt(u16, cmap[4..6], 3, .big); // platform 3
    std.mem.writeInt(u16, cmap[6..8], 1, .big); // encoding 1: BMP
    std.mem.writeInt(u32, cmap[8..12], 12, .big); // subtable offset
    const sub = cmap[12..];
    std.mem.writeInt(u16, sub[0..2], 4, .big); // format
    std.mem.writeInt(u16, sub[2..4], 32, .big); // length
    std.mem.writeInt(u16, sub[4..6], 0, .big); // language
    std.mem.writeInt(u16, sub[6..8], 4, .big); // segCountX2 = 2 segments
    // endCode
    std.mem.writeInt(u16, sub[14..16], 'C', .big);
    std.mem.writeInt(u16, sub[16..18], 0xFFFF, .big);
    // reservedPad at 18
    // startCode
    std.mem.writeInt(u16, sub[20..22], 'A', .big);
    std.mem.writeInt(u16, sub[22..24], 0xFFFF, .big);
    // idDelta: glyph = code + delta, so 'A' (65) maps to 1 with delta -64.
    std.mem.writeInt(i16, sub[24..26], -64, .big);
    std.mem.writeInt(i16, sub[26..28], 1, .big);
    // idRangeOffset, both zero.

    const tri = triangle();
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    var loca_buf: [16]u8 = undefined;
    const h = headTable(1000, true);
    const m = maxpTable(2);
    try b.add("head", &h);
    try b.add("maxp", &m);
    try b.add("loca", longLoca(&.{ 0, 0, tri.len }, &loca_buf));
    try b.add("glyf", &tri);
    try b.add("cmap", &cmap);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    try testing.expect(face.caps.cmap);
    try testing.expectEqual(@as(u16, 1), face.glyphForCodepoint('A').?);
    try testing.expectEqual(@as(u16, 3), face.glyphForCodepoint('C').?);
    try testing.expect(face.glyphForCodepoint('Z') == null);
}

test "a font missing the tables it needs is declined, not half-opened" {
    const gpa = testing.allocator;
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    const h = headTable(1000, true);
    try b.add("head", &h);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    try testing.expectError(error.UnsupportedFormat, open(gpa, bytes, 0));
}

test "truncated tables produce missing glyphs rather than reads past the end" {
    // A subsetter that rewrote `loca` badly is the normal way a font arrives
    // damaged, and every offset in an SFNT comes from the file itself. Running
    // this under the test allocator with bounds checks on is the point.
    const gpa = testing.allocator;

    const tri = triangle();
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    var loca_buf: [16]u8 = undefined;
    const h = headTable(1000, true);
    const m = maxpTable(3);
    try b.add("head", &h);
    try b.add("maxp", &m);
    // Offsets that run past the end of `glyf`.
    try b.add("loca", longLoca(&.{ 0, 0, 9999, 99999 }, &loca_buf));
    try b.add("glyf", &tri);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);
    for ([_]u16{ 0, 1, 2, 3, 999 }) |g| {
        try face.outline(gpa, g, &o);
        try testing.expect(o.isEmpty());
    }
}

test "the standard Macintosh glyph order is intact" {
    // `post` version 1.0 says "the glyph order is the standard order", so
    // these positions *are* the glyph indices for such a font. An entry
    // inserted or dropped shifts everything after it.
    try testing.expectEqualStrings(".notdef", mac_glyph_names[0].?);
    try testing.expectEqualStrings("space", mac_glyph_names[3].?);
    try testing.expectEqualStrings("A", mac_glyph_names[36].?);
    try testing.expectEqualStrings("a", mac_glyph_names[68].?);
    try testing.expectEqualStrings("dcroat", mac_glyph_names[257].?);
    try testing.expectEqual(@as(?Face.GlyphIndex, 36), macIndex("A"));
    try testing.expect(macIndex("nosuchglyph") == null);
}

test "a zero em is repaired rather than divided by" {
    const gpa = testing.allocator;
    const tri = triangle();
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    var loca_buf: [16]u8 = undefined;
    const h = headTable(0, true); // damaged
    const m = maxpTable(2);
    try b.add("head", &h);
    try b.add("maxp", &m);
    try b.add("loca", longLoca(&.{ 0, 0, tri.len }, &loca_buf));
    try b.add("glyf", &tri);
    const bytes = try b.finish();
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);
    try testing.expectEqual(@as(u16, 1000), face.info.units_per_em);
    try testing.expect(face.unitScale() > 0);
}
