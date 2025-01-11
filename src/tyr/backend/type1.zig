//! PostScript Type 1: the third font format, and the one that unlocks the
//! rest of the papers.
//!
//! `/FontFile` in a PDF is a Type 1 program, and dvips, older pdfTeX, and
//! every tool that shipped Computer Modern or the URW Nimbus faces emits one.
//! In a corpus of academic PDFs it is roughly half the documents, and without
//! it they render as blank pages with the figures intact -- which is exactly
//! what this project did an hour ago.
//!
//! ## The shape of the file
//!
//! A Type 1 font is a PostScript program in two halves. The first is
//! cleartext and carries `/FontMatrix` and the font's built-in `/Encoding`.
//! The second begins after the token `eexec` and is **encrypted**, with a
//! stream cipher whose key is a constant: 55665. Inside it are `/Subrs` and
//! `/CharStrings`, and each individual charstring is encrypted *again* with a
//! different constant key, 4330.
//!
//! None of that is security. It is 1985's idea of protecting a typeface, the
//! keys are published in the specification, and the only thing it means today
//! is that a parser has to decrypt twice before it sees a single drawing
//! operator.
//!
//! ## Type 1 charstrings are not Type 2 charstrings
//!
//! They share an outline and almost nothing else. The differences that matter:
//!
//! * `hsbw` gives the left sidebearing *and* the advance at the start of every
//!   glyph, so there is none of Type 2's parity guessing about a leading width.
//!   The sidebearing is also the initial pen position, which a parser that
//!   starts at the origin gets wrong by a few units on every glyph.
//! * `255` introduces a 32-bit **integer**, where Type 2 reads the same byte as
//!   16.16 fixed point. Same byte, different meaning, 65536 times the value.
//! * Flex and hint replacement are done by calling into `OtherSubrs`, a set of
//!   PostScript procedures in the font. Nobody interprets those; every reader
//!   recognises the four standard ones by number and implements them directly,
//!   which is what `otherSubr` below does.
//! * `seac` builds an accented glyph out of two others named by their
//!   *standard encoding* codes. It is how `é` is stored in a font that has no
//!   composite mechanism, and it is common enough in this corpus to be worth
//!   the hundred lines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Outline = @import("../Outline.zig");
const encoding = @import("../encoding.zig");

const geom = @import("../../gelgja/geom.zig");
const Point = geom.Point;
const Verb = geom.Verb;

pub const backend: Face.Backend = .{
    .name = "type1",
    .caps = .{
        .type1 = true,
        .glyph_names = true,
        .cmap = false,
        .rasterize = false,
    },
    .open = open,
};

const max_stack = 48;
const max_call_depth = 10;
const max_ops = 20_000;
const max_glyphs = 5000;

/// The two published keys. Not secrets; see the header.
const eexec_key: u16 = 55665;
const charstring_key: u16 = 4330;

const Glyph = struct {
    name: []const u8,
    /// Already decrypted, `lenIV` bytes removed.
    code: []const u8,
};

const Type1 = struct {
    gpa: Allocator,
    /// The decrypted private half. Every `Glyph.code` points into it.
    private: []u8,
    glyphs: []Glyph,
    subrs: [][]const u8,
    /// The font's own `/Encoding`, code to glyph name, borrowed from either
    /// half of the file.
    builtin: [256][]const u8,
    units_per_em: u16,

    fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
        const t: *Type1 = @ptrCast(@alignCast(ptr));
        gpa.free(t.private);
        gpa.free(t.glyphs);
        gpa.free(t.subrs);
        gpa.destroy(t);
    }
};

/// The Type 1 stream cipher, in both its uses.
///
/// `skip` is the number of leading plaintext bytes to discard: 4 for the
/// eexec section, and `lenIV` -- also 4 unless the font says otherwise -- for
/// each charstring. They exist to randomise the first cipher state and carry
/// no information.
fn decrypt(dst: []u8, src: []const u8, key: u16, skip: usize) []u8 {
    var r: u16 = key;
    var n: usize = 0;
    for (src) |c| {
        const p = c ^ @as(u8, @truncate(r >> 8));
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
        if (n >= skip) {
            if (n - skip >= dst.len) break;
            dst[n - skip] = p;
        }
        n += 1;
    }
    const kept = if (n > skip) n - skip else 0;
    return dst[0..@min(kept, dst.len)];
}

pub fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
    _ = index;
    const parts = try split(gpa, bytes);
    defer if (parts.owned) gpa.free(@constCast(parts.encrypted));

    // The encrypted half, decrypted once. Everything below points into this,
    // so the face owns it for its lifetime.
    const private = try gpa.alloc(u8, parts.encrypted.len);
    errdefer gpa.free(private);
    const plain = decrypt(private, parts.encrypted, eexec_key, 4);

    const t = try gpa.create(Type1);
    errdefer gpa.destroy(t);
    t.* = .{
        .gpa = gpa,
        .private = private,
        .glyphs = &.{},
        .subrs = &.{},
        .builtin = @splat(&.{}),
        .units_per_em = unitsPerEm(parts.clear),
    };
    errdefer gpa.free(t.glyphs);
    errdefer gpa.free(t.subrs);

    const len_iv = intAfter(plain, "/lenIV") orelse 4;
    t.subrs = try readSubrs(gpa, plain, len_iv);
    t.glyphs = try readCharStrings(gpa, plain, len_iv);
    if (t.glyphs.len == 0) return error.CorruptFont;

    readEncoding(t, parts.clear);

    return .{
        .ptr = t,
        .vtable = &vtable,
        .caps = .{ .type1 = true, .glyph_names = true, .cmap = false },
        .info = .{
            .units_per_em = t.units_per_em,
            .num_glyphs = @intCast(t.glyphs.len),
            .format = .type1,
        },
        .data = bytes,
        .backend = backend.name,
    };
}

const Parts = struct {
    clear: []const u8,
    encrypted: []const u8,
    /// True when `encrypted` was un-hexed into a fresh allocation.
    owned: bool = false,
};

/// Splits a font program into its cleartext and encrypted halves.
///
/// Three containers, all of which appear in real `/FontFile` streams: PFB with
/// its binary segment headers, PFA with the encrypted half in hexadecimal, and
/// the raw form PDF actually prescribes, where `/Length1` and `/Length2` give
/// the split and the second half is binary.
fn split(gpa: Allocator, bytes: []const u8) Face.Error!Parts {
    if (bytes.len < 8) return error.UnsupportedFormat;

    // PFB: 0x80, segment type, then a little-endian length.
    if (bytes[0] == 0x80) {
        var clear: []const u8 = &.{};
        var enc: []const u8 = &.{};
        var at: usize = 0;
        while (at + 6 <= bytes.len and bytes[at] == 0x80) {
            const kind = bytes[at + 1];
            if (kind == 3) break;
            const len = std.mem.readInt(u32, bytes[at + 2 ..][0..4], .little);
            const start = at + 6;
            if (len > bytes.len - start) break;
            const seg = bytes[start..][0..len];
            if (kind == 1 and clear.len == 0) clear = seg else if (kind == 2 and enc.len == 0) enc = seg;
            at = start + len;
        }
        if (enc.len == 0) return error.CorruptFont;
        return .{ .clear = clear, .encrypted = enc };
    }

    const marker = std.mem.indexOf(u8, bytes, "eexec") orelse return error.UnsupportedFormat;
    const clear = bytes[0..marker];
    var at = marker + 5;
    while (at < bytes.len and (bytes[at] == '\r' or bytes[at] == '\n' or
        bytes[at] == ' ' or bytes[at] == '\t')) : (at += 1)
    {}
    if (at >= bytes.len) return error.CorruptFont;
    const rest = bytes[at..];

    // Hexadecimal when the first four bytes are all hex digits. Binary data
    // that happens to look like hex for four bytes is possible and vanishingly
    // unlikely; the same test is what every other implementation uses.
    var hex = rest.len >= 4;
    if (hex) {
        for (rest[0..4]) |c| {
            if (!std.ascii.isHex(c)) hex = false;
        }
    }
    if (!hex) return .{ .clear = clear, .encrypted = rest };

    const buf = try gpa.alloc(u8, rest.len / 2);
    var n: usize = 0;
    var hi: ?u8 = null;
    for (rest) |c| {
        const v = std.fmt.charToDigit(c, 16) catch continue;
        if (hi) |h| {
            if (n >= buf.len) break;
            buf[n] = (h << 4) | v;
            n += 1;
            hi = null;
        } else hi = v;
    }
    return .{ .clear = clear, .encrypted = buf[0..n], .owned = true };
}

/// `/FontMatrix [0.001 0 0 0.001 0 0]`: the reciprocal of the first entry is
/// the em. Almost always 1000, and the exceptions are real -- some Computer
/// Modern variants ship 1/1000 scaled oddly, and a wrong em makes a page of
/// text the wrong size rather than unreadable.
fn unitsPerEm(clear: []const u8) u16 {
    const at = std.mem.indexOf(u8, clear, "/FontMatrix") orelse return 1000;
    const open_at = std.mem.indexOfScalarPos(u8, clear, at, '[') orelse return 1000;
    var it = std.mem.tokenizeAny(u8, clear[open_at + 1 ..], " \t\r\n]");
    const first = it.next() orelse return 1000;
    const v = std.fmt.parseFloat(f64, first) catch return 1000;
    if (!(v > 0) or !std.math.isFinite(v)) return 1000;
    const em = @round(1.0 / v);
    if (em < 16 or em > 16384) return 1000;
    return @intFromFloat(em);
}

fn intAfter(hay: []const u8, key: []const u8) ?usize {
    const at = std.mem.indexOf(u8, hay, key) orelse return null;
    var it = std.mem.tokenizeAny(u8, hay[at + key.len ..], " \t\r\n");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(usize, tok, 10) catch null;
}

/// `/Subrs N array` followed by `dup i L RD <binary> NP` entries.
fn readSubrs(gpa: Allocator, plain: []const u8, len_iv: usize) Face.Error![][]const u8 {
    const at = std.mem.indexOf(u8, plain, "/Subrs") orelse return &.{};
    const count = intAfter(plain[at..], "/Subrs") orelse return &.{};
    if (count == 0 or count > 65536) return &.{};

    const subrs = try gpa.alloc([]const u8, count);
    errdefer gpa.free(subrs);
    @memset(subrs, &.{});

    var pos = at;
    var found: usize = 0;
    while (found < count) {
        const dup = std.mem.indexOfPos(u8, plain, pos, "dup ") orelse break;
        var it = std.mem.tokenizeAny(u8, plain[dup + 4 ..], " \t\r\n");
        const idx_tok = it.next() orelse break;
        const len_tok = it.next() orelse break;
        const idx = std.fmt.parseInt(usize, idx_tok, 10) catch {
            pos = dup + 4;
            continue;
        };
        const len = std.fmt.parseInt(usize, len_tok, 10) catch {
            pos = dup + 4;
            continue;
        };
        // The binary follows the RD token and exactly one space.
        const data_at = binaryStart(plain, dup) orelse break;
        if (data_at + len > plain.len) break;
        if (idx < count) {
            subrs[idx] = decryptInPlace(plain, data_at, len, len_iv);
            found += 1;
        }
        pos = data_at + len;
    }
    return subrs;
}

/// Where a `... L RD ` entry's binary data begins.
///
/// The token before the data is `RD` or `-|` depending on the font, and is
/// followed by exactly one space which is *not* part of the data. Scanning for
/// the token rather than counting fields is what survives the whitespace
/// variations between generators.
fn binaryStart(plain: []const u8, from: usize) ?usize {
    var i = from;
    const limit = @min(plain.len, from + 64);
    while (i + 3 < limit) : (i += 1) {
        if ((plain[i] == 'R' and plain[i + 1] == 'D' and plain[i + 2] == ' ') or
            (plain[i] == '-' and plain[i + 1] == '|' and plain[i + 2] == ' '))
        {
            return i + 3;
        }
    }
    return null;
}

/// Decrypts one charstring in place. The plaintext is never longer than the
/// ciphertext, so it can overwrite it, which keeps the whole font in one
/// allocation.
fn decryptInPlace(plain: []const u8, at: usize, len: usize, len_iv: usize) []const u8 {
    const buf = @constCast(plain[at..][0..len]);
    const out = decrypt(buf, plain[at..][0..len], charstring_key, len_iv);
    return out;
}

/// `/CharStrings N dict dup begin` then `/name L RD <binary> ND` entries.
fn readCharStrings(gpa: Allocator, plain: []const u8, len_iv: usize) Face.Error![]Glyph {
    const at = std.mem.indexOf(u8, plain, "/CharStrings") orelse return &.{};

    var list: std.ArrayList(Glyph) = .empty;
    errdefer list.deinit(gpa);

    var pos = at + "/CharStrings".len;
    while (list.items.len < max_glyphs) {
        const slash = std.mem.indexOfScalarPos(u8, plain, pos, '/') orelse break;
        var end = slash + 1;
        while (end < plain.len and !isDelimiter(plain[end])) : (end += 1) {}
        const name = plain[slash + 1 .. end];
        if (name.len == 0) {
            pos = slash + 1;
            continue;
        }

        var it = std.mem.tokenizeAny(u8, plain[end..], " \t\r\n");
        const len_tok = it.next() orelse break;
        const len = std.fmt.parseInt(usize, len_tok, 10) catch {
            // Not a charstring entry -- `/Private`, `/ND`, and the other
            // dictionary keys that appear in the same region.
            pos = end;
            continue;
        };
        const data_at = binaryStart(plain, end) orelse {
            pos = end;
            continue;
        };
        if (data_at + len > plain.len) break;

        try list.append(gpa, .{
            .name = name,
            .code = decryptInPlace(plain, data_at, len, len_iv),
        });
        pos = data_at + len;
    }

    const glyphs = try list.toOwnedSlice(gpa);
    // `.notdef` belongs at index 0: `Face.notdef` is zero everywhere in Týr,
    // and a font that lists it late would otherwise have some other glyph
    // standing in for "no glyph".
    for (glyphs, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, ".notdef") and i != 0) {
            std.mem.swap(Glyph, &glyphs[0], &glyphs[i]);
            break;
        }
    }
    return glyphs;
}

fn isDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', 0, '/', '(', ')', '<', '>', '[', ']', '{', '}', '%' => true,
        else => false,
    };
}

/// The font's built-in encoding, out of the cleartext half.
///
/// Either `/Encoding StandardEncoding def`, or an array built up by a run of
/// `dup <code> /<name> put`. The latter is what every subsetted font has, and
/// it is the only encoding a symbolic Type 1 font has at all.
fn readEncoding(t: *Type1, clear: []const u8) void {
    const at = std.mem.indexOf(u8, clear, "/Encoding") orelse return;
    const tail = clear[at..];

    if (std.mem.indexOf(u8, tail[0..@min(tail.len, 64)], "StandardEncoding") != null) {
        for (&t.builtin, 0..) |*slot, code| {
            slot.* = encoding.nameFor(.standard, @intCast(code)) orelse &.{};
        }
        return;
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tail, pos, "dup ")) |dup| {
        pos = dup + 4;
        var it = std.mem.tokenizeAny(u8, tail[pos..], " \t\r\n");
        const code_tok = it.next() orelse break;
        const name_tok = it.next() orelse break;
        const code = std.fmt.parseInt(u16, code_tok, 10) catch continue;
        if (code > 255 or name_tok.len < 2 or name_tok[0] != '/') continue;
        t.builtin[code] = name_tok[1..];
        // `readonly def` ends the array; anything after it is a different
        // dictionary and its `dup`s are not encoding entries.
        if (std.mem.indexOfPos(u8, tail, pos, "readonly def")) |stop| {
            if (stop < pos) break;
        }
    }
}

const vtable: Face.VTable = .{
    .glyphForName = glyphForName,
    .glyphForCodepoint = glyphForCodepoint,
    .advance = advanceFn,
    .outline = outlineFn,
    .rasterize = rasterizeFn,
    .deinit = Type1.deinitFn,
};

fn rasterizeFn(_: *anyopaque, _: Face.GlyphIndex, _: Face.Render) Face.Error!Face.Bitmap {
    return error.Unsupported;
}

fn advanceFn(_: *anyopaque, _: Face.GlyphIndex) ?f32 {
    return null;
}

fn glyphForCodepoint(_: *anyopaque, _: u21) ?Face.GlyphIndex {
    return null;
}

fn glyphForName(ptr: *anyopaque, name: []const u8) ?Face.GlyphIndex {
    const t: *Type1 = @ptrCast(@alignCast(ptr));
    for (t.glyphs, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, name)) return @intCast(i);
    }
    return null;
}

/// The font's own encoding, for a code with no PDF `/Encoding` to override it.
pub fn glyphForBuiltinCode(f: Face, code: u8) ?Face.GlyphIndex {
    if (!std.mem.eql(u8, f.backend, backend.name)) return null;
    const t: *Type1 = @ptrCast(@alignCast(f.ptr));
    const name = t.builtin[code];
    if (name.len == 0) return null;
    return glyphForName(f.ptr, name);
}

// -- the charstring interpreter ---------------------------------------------

fn outlineFn(ptr: *anyopaque, gpa: Allocator, g: Face.GlyphIndex, out: *Outline) Face.Error!void {
    const t: *Type1 = @ptrCast(@alignCast(ptr));
    if (g >= t.glyphs.len) return;

    var s: State = .{ .font = t, .gpa = gpa, .out = out };
    try run(&s, t.glyphs[g].code, 0);
    if (s.open) try out.close(gpa);

    // `seac`: an accented glyph assembled from two others, named by their
    // codes in the *standard* encoding rather than in this font's.
    if (s.seac) |acc| {
        const base_name = encoding.nameFor(.standard, acc.bchar) orelse return;
        const accent_name = encoding.nameFor(.standard, acc.achar) orelse return;
        const base = glyphForName(ptr, base_name) orelse return;
        const accent = glyphForName(ptr, accent_name) orelse return;

        var b: State = .{ .font = t, .gpa = gpa, .out = out };
        try run(&b, t.glyphs[base].code, 0);
        if (b.open) try out.close(gpa);

        // The accent is placed by the difference between the two sidebearings
        // plus the given offset -- which is why `sbx` has to be remembered
        // rather than folded into the first move.
        var a: State = .{
            .font = t,
            .gpa = gpa,
            .out = out,
            .shift_x = acc.adx - acc.asb + s.sbx,
            .shift_y = acc.ady,
        };
        try run(&a, t.glyphs[accent].code, 0);
        if (a.open) try out.close(gpa);
    }
}

const Seac = struct { asb: f32, adx: f32, ady: f32, bchar: u8, achar: u8 };

const State = struct {
    font: *Type1,
    gpa: Allocator,
    out: *Outline,

    stack: [max_stack]f64 = undefined,
    n: usize = 0,
    /// `callothersubr` leaves values for a following `pop` to collect.
    ps: [max_stack]f64 = undefined,
    ps_n: usize = 0,

    x: f32 = 0,
    y: f32 = 0,
    /// Applied to every point, for the accent half of a `seac`.
    shift_x: f32 = 0,
    shift_y: f32 = 0,
    sbx: f32 = 0,
    open: bool = false,
    ops: u32 = 0,
    seac: ?Seac = null,

    /// Flex collects seven points through `rmoveto` before drawing anything.
    in_flex: bool = false,
    flex: [8]Point = undefined,
    flex_n: usize = 0,

    fn clear(s: *State) void {
        s.n = 0;
    }

    fn push(s: *State, v: f64) void {
        if (s.n < max_stack) {
            s.stack[s.n] = v;
            s.n += 1;
        }
    }

    fn at(s: *State) Point {
        return .{ .x = s.x + s.shift_x, .y = s.y + s.shift_y };
    }

    fn moveTo(s: *State, dx: f64, dy: f64) !void {
        s.x += @floatCast(dx);
        s.y += @floatCast(dy);
        if (s.in_flex) {
            if (s.flex_n < s.flex.len) {
                s.flex[s.flex_n] = s.at();
                s.flex_n += 1;
            }
            return;
        }
        if (s.open) try s.out.close(s.gpa);
        try s.out.moveTo(s.gpa, s.at());
        s.open = true;
    }

    fn lineTo(s: *State, dx: f64, dy: f64) !void {
        s.x += @floatCast(dx);
        s.y += @floatCast(dy);
        try s.out.lineTo(s.gpa, s.at());
    }

    fn curveTo(s: *State, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) !void {
        const c1: Point = .{ .x = s.x + @as(f32, @floatCast(dx1)), .y = s.y + @as(f32, @floatCast(dy1)) };
        const c2: Point = .{ .x = c1.x + @as(f32, @floatCast(dx2)), .y = c1.y + @as(f32, @floatCast(dy2)) };
        s.x = c2.x + @as(f32, @floatCast(dx3));
        s.y = c2.y + @as(f32, @floatCast(dy3));
        try s.out.cubicTo(
            s.gpa,
            .{ .x = c1.x + s.shift_x, .y = c1.y + s.shift_y },
            .{ .x = c2.x + s.shift_x, .y = c2.y + s.shift_y },
            s.at(),
        );
    }
};

fn run(s: *State, code: []const u8, depth: u8) Face.Error!void {
    if (depth > max_call_depth) return;
    var at: usize = 0;

    while (at < code.len) {
        s.ops += 1;
        if (s.ops > max_ops) return;

        const b0 = code[at];
        if (b0 >= 32) {
            if (b0 <= 246) {
                at += 1;
                s.push(@floatFromInt(@as(i32, b0) - 139));
            } else if (b0 <= 250) {
                if (at + 1 >= code.len) return;
                const b1 = code[at + 1];
                at += 2;
                s.push(@floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108));
            } else if (b0 <= 254) {
                if (at + 1 >= code.len) return;
                const b1 = code[at + 1];
                at += 2;
                s.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108));
            } else {
                // A 32-bit *integer*, not the 16.16 fixed point Type 2 reads
                // from the same byte.
                if (at + 4 >= code.len) return;
                const v = std.mem.readInt(i32, code[at + 1 ..][0..4], .big);
                at += 5;
                s.push(@floatFromInt(v));
            }
            continue;
        }

        at += 1;
        switch (b0) {
            13 => { // hsbw: sbx wx
                if (s.n >= 2) {
                    s.sbx = @floatCast(s.stack[0]);
                    // The sidebearing is where the pen starts, not a hint.
                    s.x = s.sbx;
                    s.y = 0;
                }
                s.clear();
            },
            9 => { // closepath
                if (s.open) try s.out.close(s.gpa);
                s.open = false;
                s.clear();
            },
            1, 3 => s.clear(), // hstem / vstem
            21 => {
                if (s.n >= 2) try s.moveTo(s.stack[s.n - 2], s.stack[s.n - 1]);
                s.clear();
            },
            22 => {
                if (s.n >= 1) try s.moveTo(s.stack[s.n - 1], 0);
                s.clear();
            },
            4 => {
                if (s.n >= 1) try s.moveTo(0, s.stack[s.n - 1]);
                s.clear();
            },
            5 => {
                if (s.n >= 2) try s.lineTo(s.stack[0], s.stack[1]);
                s.clear();
            },
            6 => {
                if (s.n >= 1) try s.lineTo(s.stack[0], 0);
                s.clear();
            },
            7 => {
                if (s.n >= 1) try s.lineTo(0, s.stack[0]);
                s.clear();
            },
            8 => {
                if (s.n >= 6) try s.curveTo(s.stack[0], s.stack[1], s.stack[2], s.stack[3], s.stack[4], s.stack[5]);
                s.clear();
            },
            30 => { // vhcurveto
                if (s.n >= 4) try s.curveTo(0, s.stack[0], s.stack[1], s.stack[2], s.stack[3], 0);
                s.clear();
            },
            31 => { // hvcurveto
                if (s.n >= 4) try s.curveTo(s.stack[0], 0, s.stack[1], s.stack[2], 0, s.stack[3]);
                s.clear();
            },
            10 => { // callsubr
                if (s.n == 0) continue;
                s.n -= 1;
                const i = @as(i64, @intFromFloat(s.stack[s.n]));
                if (i < 0 or i >= s.font.subrs.len) continue;
                try run(s, s.font.subrs[@intCast(i)], depth + 1);
            },
            11 => return,
            14 => { // endchar
                if (s.open) try s.out.close(s.gpa);
                s.open = false;
                return;
            },
            12 => {
                if (at >= code.len) return;
                const b1 = code[at];
                at += 1;
                try escape(s, b1, depth);
            },
            else => s.clear(),
        }
    }
}

fn escape(s: *State, op: u8, depth: u8) Face.Error!void {
    switch (op) {
        0, 1, 2 => s.clear(), // dotsection, vstem3, hstem3: hints
        6 => { // seac
            if (s.n >= 5) {
                s.seac = .{
                    .asb = @floatCast(s.stack[0]),
                    .adx = @floatCast(s.stack[1]),
                    .ady = @floatCast(s.stack[2]),
                    .bchar = @intFromFloat(std.math.clamp(s.stack[3], 0, 255)),
                    .achar = @intFromFloat(std.math.clamp(s.stack[4], 0, 255)),
                };
            }
            s.clear();
        },
        7 => { // sbw: sbx sby wx wy
            if (s.n >= 4) {
                s.sbx = @floatCast(s.stack[0]);
                s.x = s.sbx;
                s.y = @floatCast(s.stack[1]);
            }
            s.clear();
        },
        12 => { // div
            if (s.n >= 2) {
                const b = s.stack[s.n - 1];
                const a = s.stack[s.n - 2];
                s.n -= 2;
                s.push(if (b == 0) 0 else a / b);
            }
        },
        16 => try otherSubr(s, depth),
        17 => { // pop: collect a value left by callothersubr
            if (s.ps_n > 0) {
                s.ps_n -= 1;
                s.push(s.ps[s.ps_n]);
            } else s.push(0);
        },
        33 => { // setcurrentpoint
            if (s.n >= 2) {
                s.x = @floatCast(s.stack[0]);
                s.y = @floatCast(s.stack[1]);
            }
            s.clear();
        },
        else => s.clear(),
    }
}

/// `callothersubr`, which is how Type 1 does flex and hint replacement.
///
/// The arguments are `arg1 .. argn n othersubr# callothersubr`. Nobody
/// executes the font's actual PostScript for these; the four standard
/// procedures are recognised by number, and anything else has its arguments
/// handed straight back for the `pop`s that follow -- which is what the
/// specification says an interpreter that does not understand an OtherSubr
/// must do, and what keeps an unusual font from derailing.
fn otherSubr(s: *State, depth: u8) Face.Error!void {
    _ = depth;
    if (s.n < 2) {
        s.clear();
        return;
    }
    const which = @as(i64, @intFromFloat(s.stack[s.n - 1]));
    const argc_f = s.stack[s.n - 2];
    const argc: usize = if (argc_f >= 0 and argc_f < @as(f64, max_stack)) @intFromFloat(argc_f) else 0;
    s.n -= 2;
    const args_at = if (s.n >= argc) s.n - argc else 0;

    switch (which) {
        1 => { // flex start: the next seven rmovetos are collected, not drawn
            s.in_flex = true;
            s.flex_n = 0;
            s.n = args_at;
        },
        2 => s.n = args_at, // flex middle: nothing to do
        0 => { // flex end: draw the two curves
            s.in_flex = false;
            if (s.flex_n >= 7) {
                // The first collected point is a reference point the shape
                // does not pass through; the other six are the control points
                // of two cubics.
                try s.out.cubicTo(s.gpa, s.flex[1], s.flex[2], s.flex[3]);
                try s.out.cubicTo(s.gpa, s.flex[4], s.flex[5], s.flex[6]);
            }
            s.flex_n = 0;
            s.n = args_at;
            // Two `pop`s follow, expecting the end point.
            s.ps_n = 0;
            s.ps[0] = s.y;
            s.ps[1] = s.x;
            s.ps_n = 2;
        },
        3 => { // hint replacement: one `pop` follows, expecting a subr number
            s.n = args_at;
            s.ps[0] = 3;
            s.ps_n = 1;
        },
        else => {
            // Hand the arguments back for the pops.
            s.ps_n = 0;
            var i: usize = 0;
            while (i < argc and args_at + i < max_stack) : (i += 1) {
                if (s.ps_n < max_stack) {
                    s.ps[s.ps_n] = s.stack[args_at + i];
                    s.ps_n += 1;
                }
            }
            s.n = args_at;
        },
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// The inverse of `decrypt`, which is what lets these tests build a real Type
/// 1 font rather than embed one.
///
/// Encryption is the same feedback loop with the roles of plaintext and
/// ciphertext exchanged, so writing it here is both the fixture generator and
/// an independent statement of what `decrypt` is supposed to undo.
fn encrypt(out: []u8, plain: []const u8, key: u16, pad: usize) []u8 {
    var r: u16 = key;
    var n: usize = 0;
    // The leading bytes exist only to randomise the initial state and are
    // discarded on the way back in.
    var i: usize = 0;
    while (i < pad) : (i += 1) {
        const c = 0x55 ^ @as(u8, @truncate(r >> 8));
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
        out[n] = c;
        n += 1;
    }
    for (plain) |p| {
        const c = p ^ @as(u8, @truncate(r >> 8));
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

test "decryption undoes encryption for both keys" {
    const plain = "1234/CharStrings 3 dict dup begin";
    var cipher: [128]u8 = undefined;
    var back: [128]u8 = undefined;

    for ([_]u16{ eexec_key, charstring_key }) |key| {
        const c = encrypt(&cipher, plain, key, 4);
        try testing.expectEqual(plain.len + 4, c.len);
        const p = decrypt(&back, c, key, 4);
        try testing.expectEqualStrings(plain, p);
    }
}

test "a truncated cipher stream decrypts to what there is, not past it" {
    var cipher: [64]u8 = undefined;
    var back: [64]u8 = undefined;
    const c = encrypt(&cipher, "abcdefgh", charstring_key, 4);
    // Every prefix, including ones shorter than the discarded padding.
    var cut: usize = 0;
    while (cut <= c.len) : (cut += 1) {
        const p = decrypt(&back, c[0..cut], charstring_key, 4);
        try testing.expect(p.len == (if (cut > 4) cut - 4 else 0));
    }
}

/// Builds a Type 1 font: a cleartext half with an encoding, and an encrypted
/// half holding one charstring.
fn buildFont(gpa: Allocator, charstring: []const u8) ![]u8 {
    var private: std.ArrayList(u8) = .empty;
    defer private.deinit(gpa);

    // Each charstring is encrypted on its own, inside the section that is
    // itself encrypted. Two layers, both with published keys.
    var cs_cipher: [256]u8 = undefined;
    const cs = encrypt(&cs_cipher, charstring, charstring_key, 4);

    try private.appendSlice(gpa, "XXXX dup /Private 8 dict dup begin\n/lenIV 4 def\n");
    try private.appendSlice(gpa, "/CharStrings 2 dict dup begin\n");
    try private.appendSlice(gpa, "/.notdef 0 RD  ND\n");
    var num: [24]u8 = undefined;
    const header = std.fmt.bufPrint(&num, "/A {d} RD ", .{cs.len}) catch unreachable;
    try private.appendSlice(gpa, header);
    try private.appendSlice(gpa, cs);
    try private.appendSlice(gpa, " ND\nend end\n");

    const enc_buf = try gpa.alloc(u8, private.items.len + 8);
    defer gpa.free(enc_buf);
    const enc = encrypt(enc_buf, private.items, eexec_key, 4);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\%!PS-AdobeFont-1.0
        \\/FontMatrix [0.001 0 0 0.001 0 0] readonly def
        \\/Encoding 256 array
        \\dup 65 /A put
        \\readonly def
        \\currentfile eexec
        \\
    );
    try out.appendSlice(gpa, enc);
    return out.toOwnedSlice(gpa);
}

test "a Type 1 font opens, names its glyphs, and draws them" {
    const gpa = testing.allocator;

    // 0 500 hsbw  100 100 rmoveto  300 0 rlineto  0 300 rlineto  closepath
    // endchar. The one-byte operand form is `v + 139` and reaches 107, so the
    // larger numbers use the two-byte form: (b0-247)*256 + b1 + 108.
    const charstring = [_]u8{
        139,      139 + 100, 13, // hsbw: sbx = 0, wx = 100
        139 + 50, 139 + 50,  21, // rmoveto 50 50
        139 + 80, 139,       5, // rlineto 80 0
        139,      139 + 80,  5, // rlineto 0 80
        9, // closepath
        14, // endchar
    };

    const bytes = try buildFont(gpa, &charstring);
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    try testing.expectEqualStrings("type1", face.backend);
    try testing.expectEqual(@as(u16, 1000), face.info.units_per_em);
    try testing.expectEqual(@as(u32, 2), face.info.num_glyphs);

    // `.notdef` is forced to index 0 whatever order the font listed it in,
    // because `Face.notdef` is zero everywhere in Týr.
    try testing.expectEqual(@as(u16, 0), face.glyphForName(".notdef").?);
    const a = face.glyphForName("A").?;
    try testing.expect(a != 0);
    try testing.expect(face.glyphForName("nosuchglyph") == null);

    // The font's own encoding maps code 65 to it.
    try testing.expectEqual(a, glyphForBuiltinCode(face, 'A').?);
    try testing.expect(glyphForBuiltinCode(face, 'Z') == null);

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, a, &o);

    try testing.expectEqual(@as(u32, 1), o.contourCount());
    // `hsbw` puts the pen at the left sidebearing, which is zero here, so the
    // first move lands at (50, 50) rather than anywhere else.
    try testing.expectEqual(@as(f32, 50), o.points.items[0].x);
    try testing.expectEqual(@as(f32, 50), o.points.items[0].y);
    try testing.expectEqual(@as(f32, 130), o.points.items[1].x);
    try testing.expectEqual(@as(f32, 130), o.points.items[2].y);
    try testing.expectEqual(Verb.close, o.verbs.items[o.verbs.items.len - 1]);
}

test "the left sidebearing is where the pen starts" {
    // `hsbw` is not a hint. A parser that treats it as one and starts at the
    // origin draws every glyph in the font a few units to the left, which
    // reads as bad spacing rather than as a bug.
    const gpa = testing.allocator;

    const charstring = [_]u8{
        139 + 40, 139 + 100, 13, // hsbw: sbx = 40
        139,      139,       21, // rmoveto 0 0
        139 + 10, 139,       5,
        14,
    };
    const bytes = try buildFont(gpa, &charstring);
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, face.glyphForName("A").?, &o);
    try testing.expectEqual(@as(f32, 40), o.points.items[0].x);
}

test "255 introduces a 32-bit integer, not fixed point" {
    // The same byte means 16.16 fixed point in a Type 2 charstring. Reading
    // Type 1 that way divides every such number by 65536.
    const gpa = testing.allocator;

    const charstring = [_]u8{
        139,      139 + 100, 13,
        255,      0,   0,   1,  0xF4, // 500
        139,      21, // rmoveto 500 0
        139 + 10, 139,       5,
        14,
    };
    const bytes = try buildFont(gpa, &charstring);
    defer gpa.free(bytes);

    var face = try open(gpa, bytes, 0);
    defer face.deinit(gpa);

    var o: Outline = .{};
    defer o.deinit(gpa);
    try face.outline(gpa, face.glyphForName("A").?, &o);
    try testing.expectEqual(@as(f32, 500), o.points.items[0].x);
}

test "the three container forms are all split correctly" {
    const gpa = testing.allocator;

    // Raw: `eexec` then binary.
    const raw = "%!PS\ncurrentfile eexec\n\x01\x02\x03\x04";
    const p1 = try split(gpa, raw);
    try testing.expect(!p1.owned);
    try testing.expectEqual(@as(usize, 4), p1.encrypted.len);

    // PFA: the same, in hexadecimal.
    const pfa = "%!PS\ncurrentfile eexec\n01020304";
    const p2 = try split(gpa, pfa);
    defer if (p2.owned) gpa.free(@constCast(p2.encrypted));
    try testing.expect(p2.owned);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, p2.encrypted);

    // PFB: binary segment headers with little-endian lengths.
    var pfb: [32]u8 = undefined;
    pfb[0] = 0x80;
    pfb[1] = 1;
    std.mem.writeInt(u32, pfb[2..6], 5, .little);
    @memcpy(pfb[6..11], "%!PS\n");
    pfb[11] = 0x80;
    pfb[12] = 2;
    std.mem.writeInt(u32, pfb[13..17], 3, .little);
    @memcpy(pfb[17..20], &[_]u8{ 9, 8, 7 });
    pfb[20] = 0x80;
    pfb[21] = 3;
    const p3 = try split(gpa, pfb[0..22]);
    try testing.expect(!p3.owned);
    try testing.expectEqualStrings("%!PS\n", p3.clear);
    try testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, p3.encrypted);

    // And bytes that are no kind of Type 1 at all.
    try testing.expectError(error.UnsupportedFormat, split(gpa, "not a font"));
}

test "the em comes from the FontMatrix" {
    try testing.expectEqual(@as(u16, 1000), unitsPerEm("/FontMatrix [0.001 0 0 0.001 0 0]"));
    try testing.expectEqual(@as(u16, 2048), unitsPerEm("/FontMatrix [0.00048828125 0 0 0.00048828125 0 0]"));
    // Absent, nonsense, or out of range: the near-universal default.
    try testing.expectEqual(@as(u16, 1000), unitsPerEm("no matrix here"));
    try testing.expectEqual(@as(u16, 1000), unitsPerEm("/FontMatrix [0 0 0 0 0 0]"));
    try testing.expectEqual(@as(u16, 1000), unitsPerEm("/FontMatrix [1e-9 0 0 1e-9 0 0]"));
}

test "StandardEncoding as the built-in encoding" {
    const gpa = testing.allocator;
    var t: Type1 = .{
        .gpa = gpa,
        .private = &.{},
        .glyphs = &.{},
        .subrs = &.{},
        .builtin = @splat(&.{}),
        .units_per_em = 1000,
    };
    readEncoding(&t, "/Encoding StandardEncoding def");
    try testing.expectEqualStrings("A", t.builtin['A']);
    try testing.expectEqualStrings("quoteright", t.builtin[0x27]);
}

test "a font whose private half is nonsense is declined rather than half-read" {
    const gpa = testing.allocator;
    // Valid container, encrypted garbage inside: no /CharStrings anywhere.
    const bytes = "%!PS\ncurrentfile eexec\n\x11\x22\x33\x44\x55\x66\x77\x88";
    try testing.expectError(error.CorruptFont, open(gpa, bytes, 0));
}
