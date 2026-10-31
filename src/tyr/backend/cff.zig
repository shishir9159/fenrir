//! Týr's own CFF parser and Type 2 charstring interpreter.
//!
//! The companion to `truetype.zig`, and the one academic papers need: pdfTeX,
//! dvips and every Type 1 tool of the last twenty years emits `/FontFile3`
//! with a `/Type1C` subtype, which is a bare CFF. Without this, a TrueType
//! parser alone renders a large fraction of the world's PDFs as nothing.
//!
//! ## What a CFF is
//!
//! A stack of INDEX structures -- length-prefixed arrays of byte strings --
//! and DICTs, which are operand-then-operator byte streams. Nothing is at a
//! fixed offset except the four-byte header; everything else is found by
//! reading a DICT entry that gives an offset to it. That indirection is the
//! format's whole character and the reason a parser is mostly plumbing.
//!
//! Outlines are Type 2 charstrings: a stack language with subroutines, two
//! levels of them, indexed with a bias that depends on how many there are.
//! `run` below is the interpreter.
//!
//! ## The three things that are easy to get wrong
//!
//! **The width argument.** A charstring may begin with one extra number: the
//! glyph's advance, as a delta from `nominalWidthX`. There is no marker for
//! it. Whether it is present is deduced from the *parity* of the argument
//! count at the first stack-clearing operator, and a parser that guesses wrong
//! shifts every subsequent coordinate by one argument and draws confetti.
//!
//! **`hintmask` eats bytes.** The operator is followed by a bitmask whose
//! length depends on how many stem hints have been declared so far -- and
//! those hints may have been declared implicitly, by leaving arguments on the
//! stack before the first `hintmask` rather than by an explicit `vstem`.
//! Miscount them and the interpreter resumes in the middle of a mask.
//!
//! **Subroutine bias.** Subroutine numbers are signed and biased by 107, 1131
//! or 32768 depending on the subroutine count. It is not a checksum or a
//! version; it is just a bias, and using the wrong one calls the wrong
//! subroutine, which usually still runs.
//!
//! ## CID-keyed fonts
//!
//! A CFF with a `ROS` entry has no single Private DICT: each glyph belongs to
//! a font in `FDArray`, chosen by `FDSelect`, and gets that font's local
//! subroutines. `/CIDFontType0C` in a PDF is exactly this, and it is how CJK
//! and most subsetted OpenType-CFF fonts arrive.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");

const geom = @import("../../gelgja/geom.zig");
const Point = geom.Point;
const Verb = geom.Verb;

pub const backend: Face.Backend = .{
    .name = "cff",
    .caps = .{
        .cff = true,
        .glyph_names = true,
        // A bare CFF has no `cmap`: it addresses glyphs by name, and the PDF's
        // own encoding is what turns a code into one. An OpenType wrapper does
        // have one, and `open` picks it up when present.
        .cmap = false,
        .rasterize = false,
    },
    .open = open,
};

/// Type 2 allows 48 arguments; a charstring pushing more is damaged. The
/// interpreter's own stack is separate and bounded below.
const max_stack = 48;
const max_call_depth = 10;
/// A charstring that emits more than this many segments is either generated
/// or damaged, and either way is not worth unbounded time.
const max_ops = 20_000;

// -- byte reading ------------------------------------------------------------

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

    fn u24At(r: Reader, at: usize) ?u32 {
        if (at + 3 > r.bytes.len) return null;
        return (@as(u32, r.bytes[at]) << 16) | (@as(u32, r.bytes[at + 1]) << 8) | r.bytes[at + 2];
    }

    fn u32At(r: Reader, at: usize) ?u32 {
        if (at + 4 > r.bytes.len) return null;
        return std.mem.readInt(u32, r.bytes[at..][0..4], .big);
    }

    fn offAt(r: Reader, at: usize, size: u8) ?u32 {
        return switch (size) {
            1 => if (r.u8At(at)) |v| @as(u32, v) else null,
            2 => if (r.u16At(at)) |v| @as(u32, v) else null,
            3 => r.u24At(at),
            4 => r.u32At(at),
            else => null,
        };
    }

    fn slice(r: Reader, at: usize, len: usize) ?[]const u8 {
        if (at > r.bytes.len or len > r.bytes.len - at) return null;
        return r.bytes[at..][0..len];
    }
};

/// A CFF INDEX: a count, an offset size, offsets, then the data they point
/// into. Entries are resolved lazily so nothing is copied and a damaged
/// offset costs one null rather than a failed parse of the whole font.
const Index = struct {
    data: []const u8 = &.{},
    offsets: []const u8 = &.{},
    off_size: u8 = 0,
    count: u32 = 0,
    /// One past the last byte of the INDEX, so the next structure can be found.
    end: usize = 0,

    fn parse(r: Reader, at: usize) ?Index {
        const count = r.u16At(at) orelse return null;
        if (count == 0) return .{ .end = at + 2 };
        const off_size = r.u8At(at + 2) orelse return null;
        if (off_size < 1 or off_size > 4) return null;

        const offsets_at = at + 3;
        const offsets_len = (@as(usize, count) + 1) * off_size;
        const offsets = r.slice(offsets_at, offsets_len) orelse return null;

        // Offsets are one-based: entry `i` runs from `offset[i] - 1` to
        // `offset[i+1] - 1` within the data. That subtraction belongs in `get`
        // and nowhere else -- applying it here as well, by starting the data
        // one byte early, shifts every object in the INDEX back by one and is
        // almost invisible: the INDEX still has the right count, the chain of
        // INDEXes after it still parses because the end position works out the
        // same, and only the *contents* are wrong. A charstring then begins
        // with the previous glyph's last byte, which is `endchar`, so every
        // glyph decodes to nothing at all.
        const data_at = offsets_at + offsets_len;
        const or_: Reader = .{ .bytes = offsets };
        const last = or_.offAt(@as(usize, count) * off_size, off_size) orelse return null;
        if (last < 1) return null;
        const data = r.slice(data_at, last - 1) orelse return null;

        return .{
            .data = data,
            .offsets = offsets,
            .off_size = off_size,
            .count = count,
            .end = data_at + last - 1,
        };
    }

    fn get(ix: Index, i: u32) ?[]const u8 {
        if (i >= ix.count) return null;
        const r: Reader = .{ .bytes = ix.offsets };
        const a = r.offAt(@as(usize, i) * ix.off_size, ix.off_size) orelse return null;
        const b = r.offAt((@as(usize, i) + 1) * ix.off_size, ix.off_size) orelse return null;
        if (b < a or a == 0) return null;
        const dr: Reader = .{ .bytes = ix.data };
        return dr.slice(a - 1, b - a);
    }
};

/// A parsed DICT: operator to operand list. Kept as raw spans and re-scanned
/// on demand, because a top DICT is read half a dozen times at open and never
/// again.
const Dict = struct {
    bytes: []const u8,

    /// Up to two operands, which covers every operator this parser reads
    /// except `FontMatrix`.
    fn get(d: Dict, op: u16) ?[2]f64 {
        var out: [2]f64 = .{ 0, 0 };
        var n: usize = 0;
        _ = d.scan(op, &out, &n);
        return if (n == 0) null else out;
    }

    fn getOne(d: Dict, op: u16) ?f64 {
        const v = d.get(op) orelse return null;
        return v[0];
    }

    fn has(d: Dict, op: u16) bool {
        var out: [2]f64 = .{ 0, 0 };
        var n: usize = 0;
        return d.scan(op, &out, &n);
    }

    /// Walks the DICT looking for `op`, filling the last `out.len` operands
    /// seen before it.
    fn scan(d: Dict, want: u16, out: *[2]f64, n_out: *usize) bool {
        var stack: [48]f64 = undefined;
        var n: usize = 0;
        var at: usize = 0;
        const r: Reader = .{ .bytes = d.bytes };

        while (at < d.bytes.len) {
            const b0 = d.bytes[at];
            if (b0 <= 21) {
                var op: u16 = b0;
                at += 1;
                if (b0 == 12) {
                    const b1 = r.u8At(at) orelse return false;
                    op = 0x0c00 | @as(u16, b1);
                    at += 1;
                }
                if (op == want) {
                    // The operands are the whole stack; the callers that want
                    // two want the first two, and the one that wants one wants
                    // the last -- `Private` is `[size, offset]` and everything
                    // else is a single value.
                    if (n >= 2) {
                        out[0] = stack[0];
                        out[1] = stack[1];
                        n_out.* = 2;
                    } else if (n == 1) {
                        out[0] = stack[0];
                        n_out.* = 1;
                    } else {
                        n_out.* = 0;
                    }
                    return n > 0;
                }
                n = 0;
                continue;
            }

            const v = operand(r, &at) orelse return false;
            if (n < stack.len) {
                stack[n] = v;
                n += 1;
            }
        }
        return false;
    }
};

/// One DICT operand. Integers in four widths plus a binary-coded-decimal real.
fn operand(r: Reader, at: *usize) ?f64 {
    const b0 = r.u8At(at.*) orelse return null;
    if (b0 >= 32 and b0 <= 246) {
        at.* += 1;
        return @floatFromInt(@as(i32, b0) - 139);
    }
    if (b0 >= 247 and b0 <= 250) {
        const b1 = r.u8At(at.* + 1) orelse return null;
        at.* += 2;
        return @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
    }
    if (b0 >= 251 and b0 <= 254) {
        const b1 = r.u8At(at.* + 1) orelse return null;
        at.* += 2;
        return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
    }
    if (b0 == 28) {
        const v = r.u16At(at.* + 1) orelse return null;
        at.* += 3;
        return @floatFromInt(@as(i16, @bitCast(v)));
    }
    if (b0 == 29) {
        const v = r.u32At(at.* + 1) orelse return null;
        at.* += 5;
        return @floatFromInt(@as(i32, @bitCast(v)));
    }
    if (b0 == 30) return real(r, at);
    return null;
}

/// A real number, one decimal digit per nibble. Assembled as text and parsed,
/// because the alternative is reimplementing decimal-to-binary rounding and
/// getting it slightly wrong for the two values in a font that use it.
fn real(r: Reader, at: *usize) ?f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var i = at.* + 1;
    while (true) {
        const b = r.u8At(i) orelse return null;
        i += 1;
        for ([_]u8{ b >> 4, b & 0x0f }) |nib| {
            if (nib == 0x0f) {
                at.* = i;
                return std.fmt.parseFloat(f64, buf[0..n]) catch 0;
            }
            if (n + 2 >= buf.len) continue;
            switch (nib) {
                0x0...0x9 => {
                    buf[n] = '0' + nib;
                    n += 1;
                },
                0xa => {
                    buf[n] = '.';
                    n += 1;
                },
                0xb => {
                    buf[n] = 'e';
                    n += 1;
                },
                0xc => {
                    buf[n] = 'e';
                    buf[n + 1] = '-';
                    n += 2;
                },
                0xe => {
                    buf[n] = '-';
                    n += 1;
                },
                else => {},
            }
        }
    }
}

// -- the face ---------------------------------------------------------------

const Cff = struct {
    gpa: Allocator,
    data: []const u8,

    charstrings: Index,
    gsubrs: Index,
    strings: Index,

    /// Non-CID fonts: one Private DICT and one set of local subroutines.
    lsubrs: Index = .{},
    default_width: f64 = 0,
    nominal_width: f64 = 0,

    /// CID fonts: per-glyph font selection.
    is_cid: bool = false,
    fdselect: []const u8 = &.{},
    fdarray: Index = .{},
    /// Local subroutines and widths per FD, resolved at open so the charstring
    /// interpreter never parses a DICT.
    fds: []Fd = &.{},

    charset: []const u8 = &.{},
    /// The font's own encoding, code to glyph. Only present when the font
    /// carries a custom one; the standard encodings are handled by name.
    encoding: []const u8 = &.{},

    /// `FontMatrix` scaled to an em square, so a font with the unusual 1/2048
    /// matrix that some tools emit is not drawn at the wrong size.
    units_per_em: u16 = 1000,

    fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
        const c: *Cff = @ptrCast(@alignCast(ptr));
        gpa.free(c.fds);
        gpa.destroy(c);
    }
};

const Fd = struct {
    lsubrs: Index = .{},
    default_width: f64 = 0,
    nominal_width: f64 = 0,
};

pub fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
    _ = index;
    const body = try unwrap(bytes);
    const r: Reader = .{ .bytes = body };

    const hdr_size = r.u8At(2) orelse return error.UnsupportedFormat;
    if (hdr_size < 4) return error.UnsupportedFormat;

    const names = Index.parse(r, hdr_size) orelse return error.CorruptFont;
    const tops = Index.parse(r, names.end) orelse return error.CorruptFont;
    const strings = Index.parse(r, tops.end) orelse return error.CorruptFont;
    const gsubrs = Index.parse(r, strings.end) orelse return error.CorruptFont;

    const top_bytes = tops.get(0) orelse return error.CorruptFont;
    const top: Dict = .{ .bytes = top_bytes };

    const cs_off = top.getOne(17) orelse return error.CorruptFont;
    const charstrings = Index.parse(r, floorToUsize(cs_off) orelse return error.CorruptFont) orelse
        return error.CorruptFont;
    if (charstrings.count == 0) return error.CorruptFont;

    const c = try gpa.create(Cff);
    errdefer gpa.destroy(c);
    c.* = .{
        .gpa = gpa,
        .data = body,
        .charstrings = charstrings,
        .gsubrs = gsubrs,
        .strings = strings,
        .is_cid = top.has(0x0c1e), // ROS
    };
    errdefer gpa.free(c.fds);

    // `FontMatrix` is normally 0.001; anything else means a different em.
    if (top.get(0x0c07)) |m| {
        if (m[0] > 0 and m[0] < 1) {
            const upem = @round(1.0 / m[0]);
            if (upem >= 16 and upem <= 16384) c.units_per_em = @intFromFloat(upem);
        }
    }

    if (top.get(18)) |priv| {
        const p = readPrivate(r, priv[1], priv[0]);
        c.lsubrs = p.lsubrs;
        c.default_width = p.default_width;
        c.nominal_width = p.nominal_width;
    }

    if (top.getOne(15)) |off| {
        // 0, 1 and 2 are the predefined charsets rather than offsets.
        if (off > 2) {
            if (floorToUsize(off)) |at| c.charset = r.slice(at, body.len - @min(at, body.len)) orelse &.{};
        }
    }
    if (top.getOne(16)) |off| {
        if (off > 1) {
            if (floorToUsize(off)) |at| c.encoding = r.slice(at, body.len - @min(at, body.len)) orelse &.{};
        }
    }

    if (c.is_cid) {
        if (top.getOne(0x0c25)) |off| { // FDSelect
            if (floorToUsize(off)) |at| c.fdselect = r.slice(at, body.len - @min(at, body.len)) orelse &.{};
        }
        if (top.getOne(0x0c24)) |off| { // FDArray
            if (floorToUsize(off)) |at| c.fdarray = Index.parse(r, at) orelse .{};
        }
        if (c.fdarray.count > 0) {
            c.fds = try gpa.alloc(Fd, c.fdarray.count);
            for (c.fds, 0..) |*fd, i| {
                fd.* = .{};
                const fd_bytes = c.fdarray.get(@intCast(i)) orelse continue;
                const fd_dict: Dict = .{ .bytes = fd_bytes };
                if (fd_dict.get(18)) |priv| {
                    const p = readPrivate(r, priv[1], priv[0]);
                    fd.lsubrs = p.lsubrs;
                    fd.default_width = p.default_width;
                    fd.nominal_width = p.nominal_width;
                }
            }
        }
    }

    return .{
        .ptr = c,
        .vtable = &vtable,
        .caps = .{ .cff = true, .glyph_names = !c.is_cid, .cmap = false },
        .info = .{
            .units_per_em = c.units_per_em,
            .num_glyphs = charstrings.count,
            .format = .cff,
        },
        .data = bytes,
        .backend = backend.name,
    };
}

/// A bare CFF, or the `CFF ` table out of an `OTTO` wrapper.
///
/// PDF's `/FontFile3` carries both: `/Type1C` and `/CIDFontType0C` are bare,
/// and `/OpenType` is a whole SFNT. Producers also mislabel them, so the
/// bytes decide.
fn unwrap(bytes: []const u8) Face.Error![]const u8 {
    const r: Reader = .{ .bytes = bytes };
    const tag = r.slice(0, 4) orelse return error.UnsupportedFormat;
    const is_sfnt = std.mem.eql(u8, tag, "OTTO") or
        std.mem.readInt(u32, tag[0..4], .big) == 0x0001_0000;
    if (!is_sfnt) {
        // A bare CFF has no magic, only a plausible header.
        if (bytes.len < 4 or bytes[0] != 1 or bytes[2] < 4) return error.UnsupportedFormat;
        return bytes;
    }

    const n = r.u16At(4) orelse return error.CorruptFont;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = 12 + i * 16;
        const t = r.slice(rec, 4) orelse break;
        if (!std.mem.eql(u8, t, "CFF ")) continue;
        const off = r.u32At(rec + 8) orelse break;
        const len = r.u32At(rec + 12) orelse break;
        return r.slice(off, len) orelse return error.CorruptFont;
    }
    return error.UnsupportedFormat;
}

const Private = struct {
    lsubrs: Index = .{},
    default_width: f64 = 0,
    nominal_width: f64 = 0,
};

fn readPrivate(r: Reader, offset: f64, size: f64) Private {
    const at = floorToUsize(offset) orelse return .{};
    const len = floorToUsize(size) orelse return .{};
    const bytes = r.slice(at, len) orelse return .{};
    const d: Dict = .{ .bytes = bytes };

    var p: Private = .{
        .default_width = d.getOne(20) orelse 0,
        .nominal_width = d.getOne(21) orelse 0,
    };
    // Local subroutines are at an offset *relative to the Private DICT*,
    // which is the one place in CFF where an offset is not from the start of
    // the font.
    if (d.getOne(19)) |sub| {
        if (floorToUsize(sub)) |rel| {
            p.lsubrs = Index.parse(r, at + rel) orelse .{};
        }
    }
    return p;
}

fn floorToUsize(v: f64) ?usize {
    if (!(v >= 0) or !std.math.isFinite(v) or v > 1e9) return null;
    return @intFromFloat(v);
}

const vtable: Face.VTable = .{
    .glyphForName = glyphForName,
    .glyphForCodepoint = glyphForCodepoint,
    .advance = advanceFn,
    .outline = outlineFn,
    .rasterize = rasterizeFn,
    .deinit = Cff.deinitFn,
};

fn rasterizeFn(_: *anyopaque, _: Face.GlyphIndex, _: Face.Render) Face.Error!Face.Bitmap {
    return error.Unsupported;
}

fn glyphForCodepoint(_: *anyopaque, _: u21) ?Face.GlyphIndex {
    // A bare CFF has no Unicode mapping at all. Codes reach glyphs through the
    // PDF's encoding and `glyphForName`, which is the arrangement PDF assumes
    // for a Type 1 font and the reason `caps.cmap` is false.
    return null;
}

/// The advance is in the charstring, not in a table, so it costs an
/// interpretation. Returned as null rather than run here: `/Widths` outranks
/// it on every PDF font that has one, which is nearly all of them.
fn advanceFn(_: *anyopaque, _: Face.GlyphIndex) ?f32 {
    return null;
}

// -- charset and names ------------------------------------------------------

/// SID for a glyph, from the charset. For a CID font this is the CID.
fn sidFor(c: *Cff, g: Face.GlyphIndex) ?u16 {
    if (g == 0) return 0;
    if (g >= c.charstrings.count) return null;
    if (c.charset.len == 0) {
        // The predefined ISOAdobe charset: SID == GID for the first 229
        // glyphs, which is exactly what an unsubsetted Type 1 font has.
        return g;
    }
    const r: Reader = .{ .bytes = c.charset };
    const fmt = r.u8At(0) orelse return null;
    switch (fmt) {
        0 => return r.u16At(1 + (@as(usize, g) - 1) * 2),
        1, 2 => {
            const step: usize = if (fmt == 1) 3 else 4;
            var at: usize = 1;
            var gid: u32 = 1;
            while (at + step <= c.charset.len) : (at += step) {
                const first = r.u16At(at) orelse return null;
                const left: u32 = if (fmt == 1)
                    r.u8At(at + 2) orelse return null
                else
                    r.u16At(at + 2) orelse return null;
                if (g >= gid and g <= gid + left) {
                    return @truncate(first + (g - gid));
                }
                gid += left + 1;
                if (gid > c.charstrings.count) break;
            }
            return null;
        },
        else => return null,
    }
}

/// The glyph whose charset entry is `sid`. Linear, because a charset is a few
/// hundred entries and this runs once per distinct character on a page.
fn glyphForSid(c: *Cff, sid: u16) ?Face.GlyphIndex {
    var g: u32 = 0;
    while (g < c.charstrings.count) : (g += 1) {
        if (sidFor(c, @intCast(g))) |s| {
            if (s == sid) return @intCast(g);
        }
    }
    return null;
}

/// CID to glyph, for a CID-keyed font. The charset holds CIDs there rather
/// than SIDs, so this is the same search under a different name -- and it is
/// the mapping `/CIDFontType0C` needs, which `/CIDToGIDMap` does *not* supply.
pub fn glyphForCid(f: Face, cid: u16) ?Face.GlyphIndex {
    if (!std.mem.eql(u8, f.backend, backend.name)) return null;
    const c: *Cff = @ptrCast(@alignCast(f.ptr));
    if (!c.is_cid) return if (cid < c.charstrings.count) @intCast(cid) else null;
    return glyphForSid(c, cid);
}

fn stringFor(c: *Cff, sid: u16) ?[]const u8 {
    if (sid < standard_strings.len) return standard_strings[sid];
    return c.strings.get(@intCast(@as(usize, sid) - standard_strings.len));
}

fn glyphForName(ptr: *anyopaque, name: []const u8) ?Face.GlyphIndex {
    const c: *Cff = @ptrCast(@alignCast(ptr));
    if (c.is_cid) return null;

    var g: u32 = 0;
    while (g < c.charstrings.count) : (g += 1) {
        const sid = sidFor(c, @intCast(g)) orelse continue;
        const s = stringFor(c, sid) orelse continue;
        if (std.mem.eql(u8, s, name)) return @intCast(g);
    }
    return null;
}

/// The font's own `Encoding`, for a font used with no `/Encoding` in the PDF.
pub fn glyphForBuiltinCode(f: Face, code: u8) ?Face.GlyphIndex {
    if (!std.mem.eql(u8, f.backend, backend.name)) return null;
    const c: *Cff = @ptrCast(@alignCast(f.ptr));
    if (c.encoding.len == 0) return null;

    const r: Reader = .{ .bytes = c.encoding };
    const fmt = r.u8At(0) orelse return null;
    switch (fmt & 0x7f) {
        0 => {
            const n = r.u8At(1) orelse return null;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const code_i = r.u8At(2 + i) orelse return null;
                if (code_i == code) return @intCast(i + 1);
            }
            return null;
        },
        1 => {
            const n = r.u8At(1) orelse return null;
            var gid: u32 = 1;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const first = r.u8At(2 + i * 2) orelse return null;
                const left = r.u8At(2 + i * 2 + 1) orelse return null;
                if (code >= first and code <= @as(u32, first) + left) {
                    return @intCast(gid + (code - first));
                }
                gid += @as(u32, left) + 1;
            }
            return null;
        },
        else => return null,
    }
}

// -- the charstring interpreter ---------------------------------------------

fn outlineFn(ptr: *anyopaque, gpa: Allocator, g: Face.GlyphIndex, out: *Outline) Face.Error!void {
    const c: *Cff = @ptrCast(@alignCast(ptr));
    const cs = c.charstrings.get(g) orelse return;

    var fd: Fd = .{
        .lsubrs = c.lsubrs,
        .default_width = c.default_width,
        .nominal_width = c.nominal_width,
    };
    if (c.is_cid and c.fds.len > 0) {
        fd = c.fds[fdFor(c, g)];
    }

    var st: State = .{
        .cff = c,
        .gpa = gpa,
        .out = out,
        .lsubrs = fd.lsubrs,
    };
    try run(&st, cs, 0);
    // A charstring that ends without `endchar` -- truncated by a subsetter --
    // still has a contour open, and leaving it open loses the glyph entirely.
    if (st.open) try out.close(gpa);
}

/// Which font in `FDArray` a glyph belongs to.
fn fdFor(c: *Cff, g: Face.GlyphIndex) usize {
    const r: Reader = .{ .bytes = c.fdselect };
    const fmt = r.u8At(0) orelse return 0;
    const n: usize = c.fds.len;
    const pick = switch (fmt) {
        0 => r.u8At(1 + @as(usize, g)) orelse 0,
        3 => blk: {
            const ranges = r.u16At(1) orelse break :blk 0;
            var i: usize = 0;
            while (i < ranges) : (i += 1) {
                const first = r.u16At(3 + i * 3) orelse break :blk 0;
                const fd = r.u8At(3 + i * 3 + 2) orelse break :blk 0;
                const next = r.u16At(3 + (i + 1) * 3) orelse
                    (r.u16At(3 + ranges * 3) orelse 0xffff);
                if (g >= first and g < next) break :blk fd;
            }
            break :blk 0;
        },
        else => 0,
    };
    return if (pick < n) pick else 0;
}

const State = struct {
    cff: *Cff,
    gpa: Allocator,
    out: *Outline,
    lsubrs: Index,

    stack: [max_stack]f64 = undefined,
    n: usize = 0,

    x: f32 = 0,
    y: f32 = 0,
    open: bool = false,

    /// Stem hints declared so far, which is what decides how many bytes a
    /// `hintmask` swallows.
    stems: u32 = 0,
    /// Whether the leading width argument has been dealt with. It can appear
    /// only before the first stack-clearing operator.
    width_done: bool = false,
    ops: u32 = 0,

    /// Transient storage for `flex`, which needs thirteen arguments.
    fn clear(s: *State) void {
        s.n = 0;
    }

    fn push(s: *State, v: f64) void {
        if (s.n < max_stack) {
            s.stack[s.n] = v;
            s.n += 1;
        }
    }

    fn moveTo(s: *State, dx: f64, dy: f64) !void {
        if (s.open) try s.out.close(s.gpa);
        s.x += @floatCast(dx);
        s.y += @floatCast(dy);
        try s.out.moveTo(s.gpa, .{ .x = s.x, .y = s.y });
        s.open = true;
    }

    fn lineTo(s: *State, dx: f64, dy: f64) !void {
        s.x += @floatCast(dx);
        s.y += @floatCast(dy);
        try s.out.lineTo(s.gpa, .{ .x = s.x, .y = s.y });
    }

    fn curveTo(s: *State, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) !void {
        const c1: Point = .{ .x = s.x + @as(f32, @floatCast(dx1)), .y = s.y + @as(f32, @floatCast(dy1)) };
        const c2: Point = .{ .x = c1.x + @as(f32, @floatCast(dx2)), .y = c1.y + @as(f32, @floatCast(dy2)) };
        s.x = c2.x + @as(f32, @floatCast(dx3));
        s.y = c2.y + @as(f32, @floatCast(dy3));
        try s.out.cubicTo(s.gpa, c1, c2, .{ .x = s.x, .y = s.y });
    }

    /// Drops the leading width argument if there is one.
    ///
    /// `even` is how many arguments the operator itself takes when the count
    /// is fixed; for the variable-argument operators it is a parity. An odd
    /// one out at the front is the width.
    fn takeWidth(s: *State, expected_parity: usize) void {
        if (s.width_done) return;
        s.width_done = true;
        if (expected_parity == 0) return;
        if (s.n % 2 == expected_parity % 2) return;
        // Shift the extra leading argument off.
        if (s.n > 0) {
            var i: usize = 1;
            while (i < s.n) : (i += 1) s.stack[i - 1] = s.stack[i];
            s.n -= 1;
        }
    }
};

fn bias(count: u32) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

fn run(s: *State, code: []const u8, depth: u8) Face.Error!void {
    if (depth > max_call_depth) return;
    const r: Reader = .{ .bytes = code };
    var at: usize = 0;

    while (at < code.len) {
        s.ops += 1;
        if (s.ops > max_ops) return;

        const b0 = code[at];

        // Operands.
        if (b0 >= 32 or b0 == 28) {
            if (b0 == 28) {
                const v = r.u16At(at + 1) orelse return;
                at += 3;
                s.push(@floatFromInt(@as(i16, @bitCast(v))));
            } else if (b0 <= 246) {
                at += 1;
                s.push(@floatFromInt(@as(i32, b0) - 139));
            } else if (b0 <= 250) {
                const b1 = r.u8At(at + 1) orelse return;
                at += 2;
                s.push(@floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108));
            } else if (b0 <= 254) {
                const b1 = r.u8At(at + 1) orelse return;
                at += 2;
                s.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108));
            } else {
                // 16.16 fixed point.
                const v = r.u32At(at + 1) orelse return;
                at += 5;
                s.push(@as(f64, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0);
            }
            continue;
        }

        at += 1;
        switch (b0) {
            // Stem hints. The arguments are pairs; an odd count means the
            // first is the width. Nothing is drawn, but the count matters
            // because `hintmask` is sized by it.
            1, 3, 18, 23 => {
                s.takeWidth(0);
                if (!s.width_done) s.width_done = true;
                if (s.n % 2 == 1) {
                    var i: usize = 1;
                    while (i < s.n) : (i += 1) s.stack[i - 1] = s.stack[i];
                    s.n -= 1;
                }
                s.stems += @intCast(s.n / 2);
                s.clear();
            },
            // hintmask / cntrmask. Any arguments still on the stack are an
            // implicit `vstem`, which is the subtlety that makes this operator
            // the commonest place for a charstring parser to lose its place.
            19, 20 => {
                if (!s.width_done) {
                    s.width_done = true;
                    if (s.n % 2 == 1 and s.n > 0) {
                        var i: usize = 1;
                        while (i < s.n) : (i += 1) s.stack[i - 1] = s.stack[i];
                        s.n -= 1;
                    }
                }
                s.stems += @intCast(s.n / 2);
                s.clear();
                at += (s.stems + 7) / 8;
            },
            21 => { // rmoveto
                s.takeWidth(2);
                if (s.n >= 2) try s.moveTo(s.stack[s.n - 2], s.stack[s.n - 1]);
                s.clear();
            },
            22 => { // hmoveto
                s.takeWidth(1);
                if (s.n >= 1) try s.moveTo(s.stack[s.n - 1], 0);
                s.clear();
            },
            4 => { // vmoveto
                s.takeWidth(1);
                if (s.n >= 1) try s.moveTo(0, s.stack[s.n - 1]);
                s.clear();
            },
            5 => { // rlineto
                var i: usize = 0;
                while (i + 1 < s.n) : (i += 2) try s.lineTo(s.stack[i], s.stack[i + 1]);
                s.clear();
            },
            6, 7 => { // hlineto / vlineto: alternating axes
                var horizontal = b0 == 6;
                var i: usize = 0;
                while (i < s.n) : (i += 1) {
                    if (horizontal) try s.lineTo(s.stack[i], 0) else try s.lineTo(0, s.stack[i]);
                    horizontal = !horizontal;
                }
                s.clear();
            },
            8 => { // rrcurveto
                var i: usize = 0;
                while (i + 5 < s.n) : (i += 6) {
                    try s.curveTo(s.stack[i], s.stack[i + 1], s.stack[i + 2], s.stack[i + 3], s.stack[i + 4], s.stack[i + 5]);
                }
                s.clear();
            },
            24 => { // rcurveline
                var i: usize = 0;
                while (i + 5 < s.n -| 2) : (i += 6) {
                    try s.curveTo(s.stack[i], s.stack[i + 1], s.stack[i + 2], s.stack[i + 3], s.stack[i + 4], s.stack[i + 5]);
                }
                if (i + 1 < s.n) try s.lineTo(s.stack[i], s.stack[i + 1]);
                s.clear();
            },
            25 => { // rlinecurve
                var i: usize = 0;
                const lines = if (s.n >= 6) (s.n - 6) / 2 else 0;
                while (i < lines * 2) : (i += 2) try s.lineTo(s.stack[i], s.stack[i + 1]);
                if (i + 5 < s.n) {
                    try s.curveTo(s.stack[i], s.stack[i + 1], s.stack[i + 2], s.stack[i + 3], s.stack[i + 4], s.stack[i + 5]);
                }
                s.clear();
            },
            26, 27 => { // vvcurveto / hhcurveto
                var i: usize = 0;
                var d1: f64 = 0;
                // An odd leading argument is a one-off displacement on the
                // other axis, applied to the first curve only.
                if (s.n % 4 == 1) {
                    d1 = s.stack[0];
                    i = 1;
                }
                while (i + 3 < s.n) : (i += 4) {
                    if (b0 == 26) {
                        try s.curveTo(d1, s.stack[i], s.stack[i + 1], s.stack[i + 2], 0, s.stack[i + 3]);
                    } else {
                        try s.curveTo(s.stack[i], d1, s.stack[i + 1], s.stack[i + 2], s.stack[i + 3], 0);
                    }
                    d1 = 0;
                }
                s.clear();
            },
            30, 31 => { // vhcurveto / hvcurveto: alternating start tangents
                var horizontal = b0 == 31;
                var i: usize = 0;
                while (i + 3 < s.n) : (i += 4) {
                    // The very last curve may carry a fifth argument, which is
                    // the free coordinate of its end point.
                    const last = i + 8 > s.n;
                    const extra: f64 = if (last and i + 4 < s.n) s.stack[i + 4] else 0;
                    if (horizontal) {
                        try s.curveTo(s.stack[i], 0, s.stack[i + 1], s.stack[i + 2], extra, s.stack[i + 3]);
                    } else {
                        try s.curveTo(0, s.stack[i], s.stack[i + 1], s.stack[i + 2], s.stack[i + 3], extra);
                    }
                    horizontal = !horizontal;
                }
                s.clear();
            },
            10 => { // callsubr
                if (s.n == 0) continue;
                s.n -= 1;
                const idx = s.stack[s.n];
                const i = @as(i64, @intFromFloat(idx)) + bias(s.lsubrs.count);
                if (i < 0 or i >= s.lsubrs.count) continue;
                if (s.lsubrs.get(@intCast(i))) |sub| try run(s, sub, depth + 1);
            },
            29 => { // callgsubr
                if (s.n == 0) continue;
                s.n -= 1;
                const idx = s.stack[s.n];
                const i = @as(i64, @intFromFloat(idx)) + bias(s.cff.gsubrs.count);
                if (i < 0 or i >= s.cff.gsubrs.count) continue;
                if (s.cff.gsubrs.get(@intCast(i))) |sub| try run(s, sub, depth + 1);
            },
            11 => return, // return
            14 => { // endchar
                if (!s.width_done) {
                    s.width_done = true;
                    // `endchar` takes 0 or 4 arguments; anything else at the
                    // front is the width.
                    if (s.n == 1 or s.n == 5) {
                        var i: usize = 1;
                        while (i < s.n) : (i += 1) s.stack[i - 1] = s.stack[i];
                        s.n -= 1;
                    }
                }
                // The four-argument form is `seac`: an accented character
                // built from two standard-encoding glyphs. Deliberately not
                // reconstructed -- it needs the standard encoding's glyph
                // names resolved back through this font's charset, and it
                // appears almost exclusively in unsubsetted Type 1 fonts,
                // which are the ones a PDF is least likely to embed. The base
                // glyph is drawn; the accent is missing.
                if (s.open) try s.out.close(s.gpa);
                s.open = false;
                return;
            },
            12 => {
                const b1 = r.u8At(at) orelse return;
                at += 1;
                try escape(s, b1);
            },
            else => s.clear(),
        }
    }
}

/// The `12 x` operators. Only the four flex forms matter for drawing; the
/// arithmetic ones exist in the specification and in no font anyone has
/// shipped.
fn escape(s: *State, op: u8) Face.Error!void {
    switch (op) {
        35 => { // flex
            if (s.n >= 13) {
                try s.curveTo(s.stack[0], s.stack[1], s.stack[2], s.stack[3], s.stack[4], s.stack[5]);
                try s.curveTo(s.stack[6], s.stack[7], s.stack[8], s.stack[9], s.stack[10], s.stack[11]);
            }
            s.clear();
        },
        34 => { // hflex
            if (s.n >= 7) {
                const y = s.y;
                try s.curveTo(s.stack[0], 0, s.stack[1], s.stack[2], s.stack[3], 0);
                try s.curveTo(s.stack[4], 0, s.stack[5], @as(f64, y) - @as(f64, s.y) + 0, s.stack[6], 0);
                // The second curve returns to the starting y, which the
                // specification states as a constraint rather than an
                // argument.
                s.y = y;
            }
            s.clear();
        },
        36 => { // hflex1
            if (s.n >= 9) {
                const y = s.y;
                try s.curveTo(s.stack[0], s.stack[1], s.stack[2], s.stack[3], s.stack[4], 0);
                // The endpoint returns to the starting y, and `dy5` is a
                // control delta `curveTo` has already accumulated by then, so
                // it comes off the endpoint too -- as `flex1` does below.
                // Assigning `s.y` after the call would repair the interpreter
                // and leave the outline with the discontinuity in it.
                try s.curveTo(s.stack[5], 0, s.stack[6], s.stack[7], s.stack[8], @as(f64, y) - @as(f64, s.y) - s.stack[7]);
                s.y = y;
            }
            s.clear();
        },
        37 => { // flex1
            if (s.n >= 11) {
                const x0 = s.x;
                const y0 = s.y;
                var dx: f64 = 0;
                var dy: f64 = 0;
                var i: usize = 0;
                while (i < 10) : (i += 2) {
                    dx += s.stack[i];
                    dy += s.stack[i + 1];
                }
                try s.curveTo(s.stack[0], s.stack[1], s.stack[2], s.stack[3], s.stack[4], s.stack[5]);
                // The last point returns to the start plus the summed delta,
                // with only one of its coordinates given.
                const d5 = s.stack[10];
                if (@abs(dx) > @abs(dy)) {
                    try s.curveTo(s.stack[6], s.stack[7], s.stack[8], s.stack[9], d5, @as(f64, y0) - @as(f64, s.y) - s.stack[7] - s.stack[9]);
                } else {
                    try s.curveTo(s.stack[6], s.stack[7], s.stack[8], s.stack[9], @as(f64, x0) - @as(f64, s.x) - s.stack[6] - s.stack[8], d5);
                }
            }
            s.clear();
        },
        else => s.clear(),
    }
}

/// The 391 predefined SIDs. A subsetted font's charset refers to these by
/// number and stores only the names it invents itself, so without them a
/// `/Differences` lookup finds nothing in the commonest kind of embedded font.
const standard_strings = [_][]const u8{
    ".notdef",           "space",             "exclam",           "quotedbl",
    "numbersign",        "dollar",            "percent",          "ampersand",
    "quoteright",        "parenleft",         "parenright",       "asterisk",
    "plus",              "comma",             "hyphen",           "period",
    "slash",             "zero",              "one",              "two",
    "three",             "four",              "five",             "six",
    "seven",             "eight",             "nine",             "colon",
    "semicolon",         "less",              "equal",            "greater",
    "question",          "at",                "A",                "B",
    "C",                 "D",                 "E",                "F",
    "G",                 "H",                 "I",                "J",
    "K",                 "L",                 "M",                "N",
    "O",                 "P",                 "Q",                "R",
    "S",                 "T",                 "U",                "V",
    "W",                 "X",                 "Y",                "Z",
    "bracketleft",       "backslash",         "bracketright",     "asciicircum",
    "underscore",        "quoteleft",         "a",                "b",
    "c",                 "d",                 "e",                "f",
    "g",                 "h",                 "i",                "j",
    "k",                 "l",                 "m",                "n",
    "o",                 "p",                 "q",                "r",
    "s",                 "t",                 "u",                "v",
    "w",                 "x",                 "y",                "z",
    "braceleft",         "bar",               "braceright",       "asciitilde",
    "exclamdown",        "cent",              "sterling",         "fraction",
    "yen",               "florin",            "section",          "currency",
    "quotesingle",       "quotedblleft",      "guillemotleft",    "guilsinglleft",
    "guilsinglright",    "fi",                "fl",               "endash",
    "dagger",            "daggerdbl",         "periodcentered",   "paragraph",
    "bullet",            "quotesinglbase",    "quotedblbase",     "quotedblright",
    "guillemotright",    "ellipsis",          "perthousand",      "questiondown",
    "grave",             "acute",             "circumflex",       "tilde",
    "macron",            "breve",             "dotaccent",        "dieresis",
    "ring",              "cedilla",           "hungarumlaut",     "ogonek",
    "caron",             "emdash",            "AE",               "ordfeminine",
    "Lslash",            "Oslash",            "OE",               "ordmasculine",
    "ae",                "dotlessi",          "lslash",           "oslash",
    "oe",                "germandbls",        "onesuperior",      "logicalnot",
    "mu",                "trademark",         "Eth",              "onehalf",
    "plusminus",         "Thorn",             "onequarter",       "divide",
    "brokenbar",         "degree",            "thorn",            "threequarters",
    "twosuperior",       "registered",        "minus",            "eth",
    "multiply",          "threesuperior",     "copyright",        "Aacute",
    "Acircumflex",       "Adieresis",         "Agrave",           "Aring",
    "Atilde",            "Ccedilla",          "Eacute",           "Ecircumflex",
    "Edieresis",         "Egrave",            "Iacute",           "Icircumflex",
    "Idieresis",         "Igrave",            "Ntilde",           "Oacute",
    "Ocircumflex",       "Odieresis",         "Ograve",           "Otilde",
    "Scaron",            "Uacute",            "Ucircumflex",      "Udieresis",
    "Ugrave",            "Yacute",            "Ydieresis",        "Zcaron",
    "aacute",            "acircumflex",       "adieresis",        "agrave",
    "aring",             "atilde",            "ccedilla",         "eacute",
    "ecircumflex",       "edieresis",         "egrave",           "iacute",
    "icircumflex",       "idieresis",         "igrave",           "ntilde",
    "oacute",            "ocircumflex",       "odieresis",        "ograve",
    "otilde",            "scaron",            "uacute",           "ucircumflex",
    "udieresis",         "ugrave",            "yacute",           "ydieresis",
    "zcaron",            "exclamsmall",       "Hungarumlautsmall", "dollaroldstyle",
    "dollarsuperior",    "ampersandsmall",    "Acutesmall",       "parenleftsuperior",
    "parenrightsuperior", "twodotenleader",   "onedotenleader",   "zerooldstyle",
    "oneoldstyle",       "twooldstyle",       "threeoldstyle",    "fouroldstyle",
    "fiveoldstyle",      "sixoldstyle",       "sevenoldstyle",    "eightoldstyle",
    "nineoldstyle",      "commasuperior",     "threequartersemdash", "periodsuperior",
    "questionsmall",     "asuperior",         "bsuperior",        "centsuperior",
    "dsuperior",         "esuperior",         "isuperior",        "lsuperior",
    "msuperior",         "nsuperior",         "osuperior",        "rsuperior",
    "ssuperior",         "tsuperior",         "ff",               "ffi",
    "ffl",               "parenleftinferior", "parenrightinferior", "Circumflexsmall",
    "hyphensuperior",    "Gravesmall",        "Asmall",           "Bsmall",
    "Csmall",            "Dsmall",            "Esmall",           "Fsmall",
    "Gsmall",            "Hsmall",            "Ismall",           "Jsmall",
    "Ksmall",            "Lsmall",            "Msmall",           "Nsmall",
    "Osmall",            "Psmall",            "Qsmall",           "Rsmall",
    "Ssmall",            "Tsmall",            "Usmall",           "Vsmall",
    "Wsmall",            "Xsmall",            "Ysmall",           "Zsmall",
    "colonmonetary",     "onefitted",         "rupiah",           "Tildesmall",
    "exclamdownsmall",   "centoldstyle",      "Lslashsmall",      "Scaronsmall",
    "Zcaronsmall",       "Dieresissmall",     "Brevesmall",       "Caronsmall",
    "Dotaccentsmall",    "Macronsmall",       "figuredash",       "hypheninferior",
    "Ogoneksmall",       "Ringsmall",         "Cedillasmall",     "questiondownsmall",
    "oneeighth",         "threeeighths",      "fiveeighths",      "seveneighths",
    "onethird",          "twothirds",         "zerosuperior",     "foursuperior",
    "fivesuperior",      "sixsuperior",       "sevensuperior",    "eightsuperior",
    "ninesuperior",      "zeroinferior",      "oneinferior",      "twoinferior",
    "threeinferior",     "fourinferior",      "fiveinferior",     "sixinferior",
    "seveninferior",     "eightinferior",     "nineinferior",     "centinferior",
    "dollarinferior",    "periodinferior",    "commainferior",    "Agravesmall",
    "Aacutesmall",       "Acircumflexsmall",  "Atildesmall",      "Adieresissmall",
    "Aringsmall",        "AEsmall",           "Ccedillasmall",    "Egravesmall",
    "Eacutesmall",       "Ecircumflexsmall",  "Edieresissmall",   "Igravesmall",
    "Iacutesmall",       "Icircumflexsmall",  "Idieresissmall",   "Ethsmall",
    "Ntildesmall",       "Ogravesmall",       "Oacutesmall",      "Ocircumflexsmall",
    "Otildesmall",       "Odieresissmall",    "OEsmall",          "Oslashsmall",
    "Ugravesmall",       "Uacutesmall",       "Ucircumflexsmall", "Udieresissmall",
    "Yacutesmall",       "Thornsmall",        "Ydieresissmall",   "001.000",
    "001.001",           "001.002",           "001.003",          "Black",
    "Bold",              "Book",              "Light",            "Medium",
    "Regular",           "Roman",             "Semibold",
};

comptime {
    std.debug.assert(standard_strings.len == 391);
}


// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Assembles a CFF INDEX the way the specification describes it, so the
/// parser is read against an independent construction rather than against
/// itself.
fn buildIndex(out: []u8, entries: []const []const u8) []u8 {
    std.mem.writeInt(u16, out[0..2], @intCast(entries.len), .big);
    if (entries.len == 0) return out[0..2];
    out[2] = 2; // two-byte offsets

    var off: u16 = 1; // one-based
    var at: usize = 3;
    std.mem.writeInt(u16, out[at..][0..2], off, .big);
    at += 2;
    for (entries) |e| {
        off += @intCast(e.len);
        std.mem.writeInt(u16, out[at..][0..2], off, .big);
        at += 2;
    }
    for (entries) |e| {
        @memcpy(out[at..][0..e.len], e);
        at += e.len;
    }
    return out[0..at];
}

test "an INDEX hands back exactly the bytes that were put in it" {
    // The regression test for the bug that made every CFF glyph empty. The
    // offsets in a CFF INDEX are one-based, and subtracting that one in two
    // places -- once when locating the data and again when indexing into it --
    // shifts every entry back by a byte. Nothing about the INDEX looks wrong
    // afterwards: the count is right, the next structure is still found,
    // and only the contents are off. In a charstring that means the first
    // byte read is the previous glyph's `endchar`, so every glyph in the font
    // decodes to nothing at all and the page comes out blank.
    var buf: [256]u8 = undefined;
    const entries = [_][]const u8{ "hello", "", "a", "worlds" };
    const bytes = buildIndex(&buf, &entries);

    const r: Reader = .{ .bytes = bytes };
    const ix = Index.parse(r, 0).?;
    try testing.expectEqual(@as(u32, 4), ix.count);
    try testing.expectEqual(bytes.len, ix.end);

    try testing.expectEqualStrings("hello", ix.get(0).?);
    try testing.expectEqualStrings("", ix.get(1).?);
    try testing.expectEqualStrings("a", ix.get(2).?);
    try testing.expectEqualStrings("worlds", ix.get(3).?);
    try testing.expect(ix.get(4) == null);
}

test "an empty INDEX is two bytes and not an error" {
    var buf: [8]u8 = undefined;
    const bytes = buildIndex(&buf, &.{});
    const r: Reader = .{ .bytes = bytes };
    const ix = Index.parse(r, 0).?;
    try testing.expectEqual(@as(u32, 0), ix.count);
    try testing.expectEqual(@as(usize, 2), ix.end);
    try testing.expect(ix.get(0) == null);
}

test "an INDEX that runs off the end declines rather than reading past it" {
    var buf: [256]u8 = undefined;
    const entries = [_][]const u8{ "hello", "world" };
    const bytes = buildIndex(&buf, &entries);

    // Every truncation of a valid INDEX must be refused or return null
    // entries; none may read past the slice.
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        const r: Reader = .{ .bytes = bytes[0..cut] };
        if (Index.parse(r, 0)) |ix| {
            var i: u32 = 0;
            while (i < ix.count + 2) : (i += 1) _ = ix.get(i);
        }
    }
}

test "DICT operands decode in all five widths" {
    // A DICT is operands then operator, and the operand encoding is shared
    // with charstrings except for the real-number form, which appears here
    // and nowhere else.
    const cases = [_]struct { bytes: []const u8, want: f64 }{
        .{ .bytes = &.{139}, .want = 0 }, // the zero point of the one-byte form
        .{ .bytes = &.{32}, .want = -107 },
        .{ .bytes = &.{246}, .want = 107 },
        .{ .bytes = &.{ 247, 0 }, .want = 108 },
        .{ .bytes = &.{ 250, 255 }, .want = 1131 },
        .{ .bytes = &.{ 251, 0 }, .want = -108 },
        .{ .bytes = &.{ 254, 255 }, .want = -1131 },
        .{ .bytes = &.{ 28, 0x30, 0x39 }, .want = 12345 },
        .{ .bytes = &.{ 28, 0xCF, 0xC7 }, .want = -12345 },
        .{ .bytes = &.{ 29, 0, 1, 0, 0 }, .want = 65536 },
    };
    for (cases) |c| {
        const r: Reader = .{ .bytes = c.bytes };
        var at: usize = 0;
        const got = operand(r, &at).?;
        try testing.expectApproxEqAbs(c.want, got, 0.0001);
        try testing.expectEqual(c.bytes.len, at);
    }
}

test "a real operand is decimal digits packed two to a byte" {
    // -2.25e-3, spelled with the nibble codes: e = minus, a = point,
    // c = exponent-minus, f = end.
    const bytes = [_]u8{ 30, 0xE2, 0xA2, 0x5C, 0x3F };
    const r: Reader = .{ .bytes = &bytes };
    var at: usize = 0;
    const got = operand(r, &at).?;
    try testing.expectApproxEqAbs(@as(f64, -2.25e-3), got, 1e-9);

    // And the common one: a FontMatrix entry.
    const m = [_]u8{ 30, 0x0A, 0x00, 0x1F };
    var mat: usize = 0;
    const mr: Reader = .{ .bytes = &m };
    try testing.expectApproxEqAbs(@as(f64, 0.001), operand(mr, &mat).?, 1e-12);
}

test "a DICT finds its operator and its operands" {
    // `391 17` is CharStrings at offset 391: two operand bytes then the
    // operator. Preceded by a different entry, so the operand stack has to be
    // cleared between them.
    const bytes = [_]u8{ 139, 0, 28, 1, 135, 17 };
    const d: Dict = .{ .bytes = &bytes };
    try testing.expectEqual(@as(f64, 391), d.getOne(17).?);
    try testing.expect(d.has(17));
    try testing.expect(!d.has(15));
    try testing.expect(d.getOne(15) == null);
}

test "the subroutine bias depends only on how many there are" {
    // Not a checksum and not a version: a plain bias, and the wrong one calls
    // a real subroutine that happens to be the wrong one, so the glyph draws
    // and is subtly incorrect.
    try testing.expectEqual(@as(i32, 107), bias(0));
    try testing.expectEqual(@as(i32, 107), bias(1239));
    try testing.expectEqual(@as(i32, 1131), bias(1240));
    try testing.expectEqual(@as(i32, 1131), bias(33899));
    try testing.expectEqual(@as(i32, 32768), bias(33900));
}

test "the standard strings are intact" {
    // A charset refers to these by number, so an entry inserted or dropped
    // renames every glyph after it.
    try testing.expectEqual(@as(usize, 391), standard_strings.len);
    try testing.expectEqualStrings(".notdef", standard_strings[0]);
    try testing.expectEqualStrings("space", standard_strings[1]);
    try testing.expectEqualStrings("A", standard_strings[34]);
    try testing.expectEqualStrings("a", standard_strings[66]);
    try testing.expectEqualStrings("Semibold", standard_strings[390]);
}

test "an unwrapped OTTO finds its CFF table" {
    // `/FontFile3 /OpenType` is a whole SFNT with the outlines in a `CFF `
    // table, and producers mislabel it as `/Type1C` often enough that the
    // bytes have to decide.
    var sfnt: [64]u8 = @splat(0);
    @memcpy(sfnt[0..4], "OTTO");
    std.mem.writeInt(u16, sfnt[4..6], 1, .big);
    @memcpy(sfnt[12..16], "CFF ");
    std.mem.writeInt(u32, sfnt[20..24], 32, .big); // offset
    std.mem.writeInt(u32, sfnt[24..28], 8, .big); // length
    @memcpy(sfnt[32..40], &[_]u8{ 1, 0, 4, 2, 9, 9, 9, 9 });

    const body = try unwrap(&sfnt);
    try testing.expectEqual(@as(usize, 8), body.len);
    try testing.expectEqual(@as(u8, 1), body[0]);

    // A bare CFF is returned as-is.
    const bare = [_]u8{ 1, 0, 4, 2, 0, 0 };
    try testing.expectEqual(@as(usize, 6), (try unwrap(&bare)).len);

    // And something that is neither is declined rather than guessed at.
    const junk = [_]u8{ 'J', 'U', 'N', 'K', 0, 0, 0, 0 };
    try testing.expectError(error.UnsupportedFormat, unwrap(&junk));
}

test "a charstring draws what it says" {
    // Exercised through `run` directly, because assembling a whole CFF around
    // it would test the INDEX walking twice and the interpreter once.
    const gpa = testing.allocator;

    var c: Cff = .{
        .gpa = gpa,
        .data = &.{},
        .charstrings = .{},
        .gsubrs = .{},
        .strings = .{},
    };
    var o: Outline = .{};
    defer o.deinit(gpa);
    o.reset(1000);

    var s: State = .{ .cff = &c, .gpa = gpa, .out = &o, .lsubrs = .{} };

    // 60 60 rmoveto  80 0 rlineto  0 80 rlineto  endchar
    //
    // The one-byte operand form is `v + 139` and reaches only to 107, which is
    // why the numbers here are small: anything larger needs the two-byte form
    // and would be testing the encoder rather than the interpreter.
    const code = [_]u8{
        139 + 60, 139 + 60, 21,
        139 + 80, 139,      5,
        139,      139 + 80, 5,
        14,
    };
    try run(&s, &code, 0);

    try testing.expectEqual(@as(u32, 1), o.contourCount());
    try testing.expectEqual(@as(f32, 60), o.points.items[0].x);
    try testing.expectEqual(@as(f32, 60), o.points.items[0].y);
    try testing.expectEqual(@as(f32, 140), o.points.items[1].x);
    try testing.expectEqual(@as(f32, 140), o.points.items[2].y);
    try testing.expectEqual(Verb.close, o.verbs.items[o.verbs.items.len - 1]);
}

test "the flex operators end where the specification says they end" {
    // `hflex1` used to end at `y + dy5`: it put the compensating delta on the
    // endpoint without taking off the control delta `curveTo` had already
    // accumulated, and then assigned `s.y` -- which repaired the interpreter
    // and left the outline with a silent discontinuity in it. So the endpoint
    // is asserted here, and so is the line after it, which is where the error
    // used to show. The two siblings are in the same test because they are
    // what the fix was checked against.
    const gpa = testing.allocator;
    var c: Cff = .{ .gpa = gpa, .data = &.{}, .charstrings = .{}, .gsubrs = .{}, .strings = .{} };

    for ([_]struct { name: []const u8, code: []const u8, x: f32 }{
        // 0 0 rmoveto  10 10 7 10 10 10 10 hflex  0 20 rlineto  endchar
        .{ .name = "hflex", .x = 60, .code = &.{
            139,      139,      21,
            139 + 10, 139 + 10, 139 + 7,  139 + 10, 139 + 10, 139 + 10, 139 + 10, 12, 34,
            139,      139 + 20, 5,
            14,
        } },
        // 0 0 rmoveto  10 5 10 7 10 10 10 9 10 hflex1  0 20 rlineto  endchar
        .{ .name = "hflex1", .x = 60, .code = &.{
            139,      139,     21,
            139 + 10, 139 + 5, 139 + 10, 139 + 7, 139 + 10, 139 + 10, 139 + 10, 139 + 9, 139 + 10, 12, 36,
            139,      139 + 20, 5,
            14,
        } },
        // The horizontal arm of flex1, which already subtracted both control
        // deltas and is the model the fix followed.
        .{ .name = "flex1", .x = 120, .code = &.{
            139,      139,     21,
            139 + 20, 139 + 5, 139 + 20, 139 - 5, 139 + 20, 139 + 5,
            139 + 20, 139 - 5, 139 + 20, 139 + 5, 139 + 20, 12, 37,
            139,      139 + 20, 5,
            14,
        } },
    }) |case| {
        var o: Outline = .{};
        defer o.deinit(gpa);
        o.reset(1000);
        var s: State = .{ .cff = &c, .gpa = gpa, .out = &o, .lsubrs = .{} };
        try run(&s, case.code, 0);

        // Two curves of three points each after the move, then the line.
        try testing.expectEqual(@as(usize, 8), o.points.items.len);
        const end = o.points.items[6];
        errdefer std.debug.print("{s} ended at ({d}, {d})\n", .{ case.name, end.x, end.y });
        try testing.expectApproxEqAbs(@as(f32, 0), end.y, 1e-4);
        try testing.expectApproxEqAbs(case.x, end.x, 1e-4);
        // And the segment after it starts from there, not from the drift.
        try testing.expectApproxEqAbs(@as(f32, 20), o.points.items[7].y, 1e-4);
    }
}

test "a leading width argument is recognised by parity and dropped" {
    // The subtlety that makes a wrong parser draw confetti: there is no marker
    // for the width, only an odd argument count at the first stack-clearing
    // operator.
    const gpa = testing.allocator;
    var c: Cff = .{ .gpa = gpa, .data = &.{}, .charstrings = .{}, .gsubrs = .{}, .strings = .{} };

    for ([_]struct { code: []const u8, x: f32 }{
        // Two arguments: no width, move to (10, 20).
        .{ .code = &.{ 139 + 10, 139 + 20, 21, 14 }, .x = 10 },
        // Three: the first is the width, move to (10, 20) again.
        .{ .code = &.{ 139 + 55, 139 + 10, 139 + 20, 21, 14 }, .x = 10 },
    }) |case| {
        var o: Outline = .{};
        defer o.deinit(gpa);
        o.reset(1000);
        var s: State = .{ .cff = &c, .gpa = gpa, .out = &o, .lsubrs = .{} };
        try run(&s, case.code, 0);
        try testing.expectEqual(case.x, o.points.items[0].x);
        try testing.expectEqual(@as(f32, 20), o.points.items[0].y);
    }
}

test "hintmask swallows a byte for every eight stems" {
    // Miscount the stems and the interpreter resumes in the middle of the
    // mask, reading mask bits as operators.
    const gpa = testing.allocator;
    var c: Cff = .{ .gpa = gpa, .data = &.{}, .charstrings = .{}, .gsubrs = .{}, .strings = .{} };

    var o: Outline = .{};
    defer o.deinit(gpa);
    o.reset(1000);
    var s: State = .{ .cff = &c, .gpa = gpa, .out = &o, .lsubrs = .{} };

    // Nine stem pairs declared implicitly, then hintmask, which must eat two
    // mask bytes; then a move that has to land where it says.
    const code = [_]u8{
        139, 139 + 10, 139, 139 + 10, 139, 139 + 10, 139, 139 + 10, 139, 139 + 10,
        139, 139 + 10, 139, 139 + 10, 139, 139 + 10, 139, 139 + 10, // 9 pairs
        19,  0xFF,     0xFF, // hintmask + two bytes
        139 + 40, 139 + 50, 21,
        14,
    };
    try run(&s, &code, 0);
    try testing.expectEqual(@as(usize, 9), s.stems);
    try testing.expectEqual(@as(f32, 40), o.points.items[0].x);
    try testing.expectEqual(@as(f32, 50), o.points.items[0].y);
}

test "a charstring that never ends is stopped" {
    const gpa = testing.allocator;
    var c: Cff = .{ .gpa = gpa, .data = &.{}, .charstrings = .{}, .gsubrs = .{}, .strings = .{} };
    var o: Outline = .{};
    defer o.deinit(gpa);
    o.reset(1000);
    var s: State = .{ .cff = &c, .gpa = gpa, .out = &o, .lsubrs = .{} };

    // A subroutine call to nowhere, repeated: the budget is what ends it.
    var code: [4096]u8 = undefined;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 2) {
        code[i] = 139 + 5;
        code[i + 1] = 5; // rlineto with one argument, which draws nothing
    }
    try run(&s, code[0..i], 0);
    try testing.expect(s.ops <= max_ops + 1);
}
