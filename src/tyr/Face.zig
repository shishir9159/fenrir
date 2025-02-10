//! One loaded font program, behind a runtime interface.
//!
//! This is the seam that lets FreeType, stb_truetype and a native Zig parser
//! coexist in one binary. Dispatch is a vtable, not a `comptime` switch, for
//! one concrete reason: the whole verification plan for Gleipnir is diffing
//! two renderings of the same page, and the most valuable diff is the same
//! page through two *font* backends. That requires both to be callable in one
//! process, from one call site, chosen by a string on the command line.
//!
//! The shape is `std.mem.Allocator`'s: an opaque pointer and a table of
//! function pointers. A face is a handful of bytes, passed by value, and the
//! indirect call is paid once per glyph decode -- which is dwarfed by the
//! charstring interpreter or the `glyf` walk behind it.
//!
//! What is deliberately *not* here:
//!
//! **Shaping.** HarfBuzz turns a Unicode string into positioned glyphs, which
//! is a different job from turning a glyph index into an outline, and it is
//! one a PDF page never needs -- the content stream has already been shaped by
//! the producer. See `Shaper.zig`.
//!
//! **Encoding.** Mapping a character *code* to a glyph is PDF's business:
//! `/Encoding`, `/Differences`, a CMap, `/CIDToGIDMap`. Týr's core owns that
//! and hands a backend an index or a name, never a raw code. Backends that
//! disagree about `/Differences` would be untestable against each other.
//!
//! **Widths.** A PDF's `/Widths` array overrides the font program (§9.2.4),
//! including where the two disagree, which they routinely do in subsetted
//! fonts. `advance` exists for the non-embedded standard-14 case and as a
//! fallback, never as the first source of truth.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Outline = @import("Outline.zig");
const format = @import("format.zig");

const Face = @This();

/// The backend's own handle: an `FT_Face`, an `stbtt_fontinfo`, a parsed SFNT.
ptr: *anyopaque,
vtable: *const VTable,

/// Cached because it is read on every glyph and never changes.
info: Info,

/// What this face can actually do -- the backend's static capabilities
/// narrowed by what this particular file turned out to contain. A TrueType
/// font with no `post` table has no glyph names even under FreeType.
caps: Capabilities,

/// The font program itself. Backends keep pointers into it rather than
/// copying, and a shaper needs it to build a font object of its own, so it
/// is carried here rather than left to the caller to remember.
data: []const u8 = &.{},

/// Which backend opened it. Carried on the face rather than looked up,
/// because it belongs in every trace line and every bug report.
backend: []const u8,

pub const Error = error{
    /// The bytes are not a font this backend understands.
    UnsupportedFormat,
    /// They are, but they are damaged past the point of use.
    CorruptFont,
    /// The face has no such glyph, or the operation needs a capability this
    /// face lacks.
    Unsupported,
    /// The backend reported a failure of its own that maps to nothing here.
    BackendFailed,
    OutOfMemory,
};

/// TrueType and CFF both cap a font at 65535 glyphs, so the index is a `u16`
/// everywhere -- including in Gelgja's `Glyph`, which is why `0xffff` reads as
/// "not resolved yet" there rather than as a real glyph.
pub const GlyphIndex = u16;

pub const notdef: GlyphIndex = 0;

pub const Info = struct {
    units_per_em: u16 = 1000,
    num_glyphs: u32 = 0,
    /// Typographic vertical metrics, in font units.
    ascender: i16 = 0,
    descender: i16 = 0,
    line_gap: i16 = 0,
    format: format.Format = .unknown,
    is_fixed_pitch: bool = false,
};

/// What a backend supports. Used twice: statically, on a `Backend`, to choose
/// one before any bytes are read; and per-face, to answer "can this one give
/// me a glyph by name" without a failed call.
pub const Capabilities = packed struct {
    /// `glyf`/`loca` outlines.
    truetype: bool = false,
    /// CFF/Type 2 charstrings, bare or inside an `OTTO` wrapper.
    cff: bool = false,
    /// PostScript Type 1, PFB or PFA.
    type1: bool = false,
    /// `glyphForName` works. Type 1 and CFF `/Differences` need this;
    /// stb_truetype cannot do it at all, which is the single sharpest
    /// difference between the backends and the reason `Capabilities` exists.
    glyph_names: bool = false,
    /// `glyphForCodepoint` works, i.e. the `cmap` table is readable.
    cmap: bool = false,
    /// The backend can produce hinted bitmaps of its own.
    rasterize: bool = false,
    /// Grid-fitting is applied when rasterising.
    hinting: bool = false,
    /// OpenType variable fonts, allowed by PDF 2.0.
    variations: bool = false,

    pub fn supports(c: Capabilities, r: format.Requirement) bool {
        return switch (r) {
            .truetype => c.truetype,
            .cff => c.cff,
            .type1 => c.type1,
            // An unrecognised program: no backend can promise it, so let the
            // preferred one try rather than refusing outright.
            .none => true,
        };
    }
};

/// An 8-bit coverage bitmap produced by a backend that rasterises.
///
/// `pixels` is owned by the backend and valid only until the next call on the
/// same face -- FreeType's `FT_GlyphSlot` works exactly this way, and copying
/// on every glyph to hide that would cost more than the atlas upload.
pub const Bitmap = struct {
    pixels: []const u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// Bytes per row, which is not always `width`.
    stride: u32 = 0,
    /// Top-left corner relative to the pen position, in pixels, y downwards.
    left: i32 = 0,
    top: i32 = 0,
};

pub const VTable = struct {
    /// Glyph index for a PostScript glyph name (`aacute`, `uni20AC`).
    /// Null when absent or when the face has no name table.
    glyphForName: *const fn (ptr: *anyopaque, name: []const u8) ?GlyphIndex,

    /// Glyph index for a Unicode code point, through the `cmap`.
    glyphForCodepoint: *const fn (ptr: *anyopaque, cp: u21) ?GlyphIndex,

    /// Horizontal advance in font units. Null when the glyph does not exist.
    /// Remember that `/Widths` outranks this.
    advance: *const fn (ptr: *anyopaque, g: GlyphIndex) ?f32,

    /// Decompose a glyph into `out`, unscaled. `out` is reset first.
    outline: *const fn (ptr: *anyopaque, gpa: Allocator, g: GlyphIndex, out: *Outline) Error!void,

    /// Optional. Returns `error.Unsupported` unless `caps.rasterize`.
    rasterize: *const fn (ptr: *anyopaque, g: GlyphIndex, px_size: f32) Error!Bitmap,

    deinit: *const fn (ptr: *anyopaque, gpa: Allocator) void,
};

// -- the call sites ---------------------------------------------------------

pub fn glyphForName(f: Face, name: []const u8) ?GlyphIndex {
    if (!f.caps.glyph_names) return null;
    return f.vtable.glyphForName(f.ptr, name);
}

pub fn glyphForCodepoint(f: Face, cp: u21) ?GlyphIndex {
    if (!f.caps.cmap) return null;
    return f.vtable.glyphForCodepoint(f.ptr, cp);
}

pub fn advance(f: Face, g: GlyphIndex) ?f32 {
    return f.vtable.advance(f.ptr, g);
}

pub fn outline(f: Face, gpa: Allocator, g: GlyphIndex, out: *Outline) Error!void {
    out.reset(f.info.units_per_em);
    return f.vtable.outline(f.ptr, gpa, g, out);
}

/// Only when `caps.rasterize`. Gleipnir uses its own scanline fill for page
/// content, so that glyph edges and vector edges get identical coverage; this
/// exists for small UI text, where a backend's hinting beats an unhinted fill
/// by a visible margin at eleven pixels.
pub fn rasterize(f: Face, g: GlyphIndex, px_size: f32) Error!Bitmap {
    if (!f.caps.rasterize) return error.Unsupported;
    return f.vtable.rasterize(f.ptr, g, px_size);
}

pub fn deinit(f: *Face, gpa: Allocator) void {
    f.vtable.deinit(f.ptr, gpa);
    f.* = undefined;
}

/// Font units to text space, before the font size.
pub fn unitScale(f: Face) f32 {
    return 1.0 / @as(f32, @floatFromInt(f.info.units_per_em));
}

// -- backend registration ---------------------------------------------------

/// A backend as the registry sees it: a name, what it can do, and how to open
/// bytes with it. One of these per implementation, and nothing else about a
/// backend is public.
pub const Backend = struct {
    /// The name `--font-backend=` matches and traces print.
    name: []const u8,
    caps: Capabilities,
    /// `index` selects a face inside a `ttcf` collection; 0 otherwise.
    open: *const fn (gpa: Allocator, bytes: []const u8, index: u32) Error!Face,

    pub fn canOpen(b: *const Backend, f: format.Format) bool {
        return b.caps.supports(f.requirement());
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "capabilities gate a backend against a format" {
    const stb: Capabilities = .{ .truetype = true, .cmap = true, .rasterize = true };
    const ft: Capabilities = .{
        .truetype = true,
        .cff = true,
        .type1 = true,
        .glyph_names = true,
        .cmap = true,
        .rasterize = true,
        .hinting = true,
    };

    // The case that matters: most subsetted PDF fonts are bare CFF, and
    // stb_truetype cannot open them.
    try testing.expect(!stb.supports(format.Format.cff.requirement()));
    try testing.expect(ft.supports(format.Format.cff.requirement()));
    try testing.expect(stb.supports(format.Format.truetype.requirement()));

    // An unidentifiable program is offered to whoever is preferred, rather
    // than refused by everyone.
    try testing.expect(stb.supports(format.Format.unknown.requirement()));
}

test "an unknown-capability face refuses without calling through" {
    // A vtable whose members all trap: reaching any of them is the failure.
    const trap = struct {
        fn name(_: *anyopaque, _: []const u8) ?GlyphIndex {
            unreachable;
        }
        fn cp(_: *anyopaque, _: u21) ?GlyphIndex {
            unreachable;
        }
        fn adv(_: *anyopaque, _: GlyphIndex) ?f32 {
            unreachable;
        }
        fn out(_: *anyopaque, _: Allocator, _: GlyphIndex, _: *Outline) Error!void {
            unreachable;
        }
        fn ras(_: *anyopaque, _: GlyphIndex, _: f32) Error!Bitmap {
            unreachable;
        }
        fn free(_: *anyopaque, _: Allocator) void {}
    };
    const vt: VTable = .{
        .glyphForName = trap.name,
        .glyphForCodepoint = trap.cp,
        .advance = trap.adv,
        .outline = trap.out,
        .rasterize = trap.ras,
        .deinit = trap.free,
    };

    var dummy: u8 = 0;
    const f: Face = .{
        .ptr = &dummy,
        .vtable = &vt,
        .info = .{},
        .caps = .{ .truetype = true },
        .backend = "trap",
    };

    try testing.expectEqual(@as(?GlyphIndex, null), f.glyphForName("aacute"));
    try testing.expectEqual(@as(?GlyphIndex, null), f.glyphForCodepoint('A'));
    try testing.expectError(error.Unsupported, f.rasterize(1, 12));
}

test "unit scale follows the em square" {
    var dummy: u8 = 0;
    const vt: VTable = undefined;
    _ = vt;
    const f: Face = .{
        .ptr = &dummy,
        .vtable = undefined,
        .info = .{ .units_per_em = 2048 },
        .caps = .{},
        .backend = "none",
    };
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 2048.0), f.unitScale(), 1e-9);
}
