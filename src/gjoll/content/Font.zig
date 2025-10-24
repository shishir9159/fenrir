//! What the interpreter needs from a font dictionary: how to split a string
//! into codes, and how far each one advances the cursor.
//!
//! This is *not* the font layer. Týr loads programs and produces outlines;
//! this reads four entries out of a PDF dictionary. The division is exact:
//! everything here comes from the document, and everything Týr does comes
//! from the embedded font file. They meet at `DisplayList.FontInfo`, which
//! carries the object number and nothing else.
//!
//! Widths matter more than they sound like they do. A `Tj` is a string, and
//! the position of its second glyph is the width of its first -- so an
//! interpreter with no widths draws every glyph of a page on top of the one
//! before it. The result looks like a rendering bug in the rasteriser, three
//! layers away from the cause.
//!
//! ## What is approximated, and why
//!
//! - A simple font with no `/Widths` is one of the standard 14, whose metrics
//!   live in AFM files that ship with the specification rather than in the
//!   document. Those are Týr's to load; until it does, this uses one width
//!   for every glyph, which spaces text evenly and wrongly. It is the single
//!   largest known inaccuracy in the interpreter, and it is confined to this
//!   one function.
//! - A `/Type0` font whose `/Encoding` is a predefined CMap other than
//!   Identity is treated as two-byte identity. The predefined CMaps are
//!   external data files; two bytes per code is right for all of them, and
//!   the CID mapping is wrong for the CJK ones.
//!
//! Embedded CMap streams *are* parsed, because they are self-contained.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("../Document.zig");
const Lexer = @import("../Lexer.zig");
const matrix = @import("matrix.zig");
const pdf = @import("../object.zig");

const Dict = pdf.Dict;
const Matrix = matrix.Matrix;
const Object = pdf.Object;

const Font = @This();

pub const Error = Document.Error;

/// Widths in a simple or composite font are in glyph space, where the em is
/// 1000 units (§9.2.4). Type 3 is the exception and carries its own matrix.
const glyph_units: f64 = 1000;

/// The fallback width for a standard-14 font with no `/Widths` array. Half an
/// em: too wide for `i`, too narrow for `m`, and right on average for the
/// mixed-case text those fonts are used for.
pub const assumed_width: f64 = 500;

pub const Kind = enum {
    /// `/Type1`, `/TrueType`, `/MMType1`: one byte per code.
    simple,
    /// `/Type0`: codes go through a CMap to CIDs.
    composite,
    /// `/Type3`: glyphs are content streams in the document itself.
    type3,
};

kind: Kind = .simple,
/// `/BaseFont`, e.g. `ABCDEF+Helvetica`. Borrowed from the document.
base_font: []const u8 = "",
/// The font dictionary's object number, or zero for a direct dictionary.
object: u32 = 0,

// -- simple fonts -----------------------------------------------------------

first_char: u32 = 0,
/// `/Widths`, in glyph space, indexed from `first_char`.
widths: []const f32 = &.{},
/// `/FontDescriptor /MissingWidth`.
missing_width: f64 = 0,
/// True when neither `/Widths` nor `/MissingWidth` said anything, so
/// `assumed_width` is in play.
widths_assumed: bool = false,

// -- composite fonts --------------------------------------------------------

/// `/DW`, the default width for any CID not listed in `/W`.
default_width: f64 = 1000,
/// `/W`, flattened into sorted ranges.
cid_widths: []const CidRange = &.{},
cmap: CMap = .{},
/// `/Identity-V` and the other vertical CMaps advance down the page.
vertical: bool = false,

// -- type 3 -----------------------------------------------------------------

/// `/FontMatrix`: Type 3 glyph space is whatever the font says it is, which
/// is the whole point of the format.
font_matrix: Matrix = .{ .a = 0.001, .d = 0.001 },
/// `/CharProcs`: code -> content stream, through `encoding`.
char_procs: ?Dict = null,
/// The font's own `/Resources`, which its glyph procedures run against.
resources: ?Dict = null,
/// `/Encoding /Differences`, 256 entries of glyph name or empty.
encoding: ?[]const []const u8 = null,

pub const CidRange = struct {
    first: u32,
    last: u32,
    width: f32,
};

/// One code taken off the front of a string.
pub const Code = struct {
    /// The bytes exactly as they appeared, packed big-endian.
    code: u32,
    /// The character or glyph identifier the code maps to.
    cid: u32,
    /// How many bytes were consumed. Never zero, so a decode loop always
    /// terminates however damaged the string is.
    len: u8,
};

// -- code decoding ----------------------------------------------------------

/// Takes the next code off `bytes` at `at`.
pub fn decode(f: *const Font, bytes: []const u8, at: usize) Code {
    if (f.kind != .composite) {
        return .{ .code = bytes[at], .cid = bytes[at], .len = 1 };
    }
    return f.cmap.decode(bytes, at);
}

/// True when a code is the single byte 32, which is the only thing word
/// spacing applies to (§9.3.3). Notably *not* true of a two-byte code whose
/// value happens to be 32, which is a real trap: applying `Tw` there shifts
/// every CJK line.
pub fn isWordSpace(f: *const Font, code: Code) bool {
    _ = f;
    return code.len == 1 and code.code == 32;
}

// -- widths -----------------------------------------------------------------

/// The horizontal advance for one code, in text space at font size 1. Multiply
/// by `Tf`'s size to get the displacement.
pub fn advance(f: *const Font, code: Code) f64 {
    return switch (f.kind) {
        .composite => f.cidWidth(code.cid) / glyph_units,
        .type3 => f.type3Width(code.code),
        .simple => f.simpleWidth(code.code) / glyph_units,
    };
}

fn simpleWidth(f: *const Font, code: u32) f64 {
    if (code >= f.first_char) {
        const i = code - f.first_char;
        if (i < f.widths.len) {
            const w = f.widths[i];
            // A zero entry inside the array is meaningful -- combining marks
            // really do advance nothing -- so it is not treated as missing.
            if (std.math.isFinite(w)) return w;
        }
    }
    if (f.widths_assumed) return assumed_width;
    return f.missing_width;
}

fn cidWidth(f: *const Font, cid: u32) f64 {
    // `/W` is small: a handful of ranges for a subset font, a few hundred for
    // a full CJK one. A linear scan beats the cache miss of anything cleverer
    // until it does not, and it has not yet.
    for (f.cid_widths) |r| {
        if (cid >= r.first and cid <= r.last) return r.width;
    }
    return f.default_width;
}

fn type3Width(f: *const Font, code: u32) f64 {
    const w = f.simpleWidth(code);
    // Type 3 widths are in glyph space, and the font matrix is what maps
    // glyph space to text space. Only the horizontal scale matters for an
    // advance, which is what makes this one multiply rather than a transform.
    return w * f.font_matrix.a;
}

/// The glyph name a Type 3 code maps to, or null.
pub fn glyphName(f: *const Font, code: u32) ?[]const u8 {
    const names = f.encoding orelse return null;
    if (code >= names.len) return null;
    const name = names[code];
    return if (name.len == 0) null else name;
}

// -- CMaps ------------------------------------------------------------------

/// Enough of a CMap to split a string into codes and map them to CIDs
/// (§9.7.5). Predefined CMaps other than Identity are external data files;
/// see the note at the top of this file for what happens to those.
pub const CMap = struct {
    /// Codespace ranges, which decide how many bytes each code takes.
    codespace: []const Codespace = &.{},
    /// `cidrange` and `cidchar` entries, flattened.
    ranges: []const Range = &.{},
    /// True for `/Identity-H` and `/Identity-V`, where CID equals code and
    /// every code is two bytes.
    identity: bool = true,

    pub const Codespace = struct {
        low: u32,
        high: u32,
        bytes: u8,
    };

    pub const Range = struct {
        low: u32,
        high: u32,
        cid: u32,
        bytes: u8,
    };

    pub fn decode(cm: CMap, bytes: []const u8, at: usize) Code {
        if (cm.identity or cm.codespace.len == 0) {
            // Two bytes, big-endian, and a trailing odd byte stands alone
            // rather than reading past the end.
            if (at + 1 < bytes.len) {
                const code = (@as(u32, bytes[at]) << 8) | bytes[at + 1];
                return .{ .code = code, .cid = code, .len = 2 };
            }
            return .{ .code = bytes[at], .cid = bytes[at], .len = 1 };
        }

        // Try one byte, then two, then three, then four: the first codespace
        // range that contains the value decides the length (§9.7.6.2).
        var len: u8 = 1;
        var value: u32 = 0;
        while (len <= 4) : (len += 1) {
            if (at + len > bytes.len) break;
            value = (value << 8) | bytes[at + len - 1];
            for (cm.codespace) |space| {
                if (space.bytes != len) continue;
                if (value >= space.low and value <= space.high) {
                    return .{ .code = value, .cid = cm.lookup(value, len), .len = len };
                }
            }
        }

        // No range matched. Use the shortest codespace length there is, which
        // is what the spec says to do with an unmatched code (§9.7.6.3).
        // Seeded at the longest possible code, not at 1: seeding at 1 makes
        // the fold a no-op and quietly turns every unmatched code in a
        // two-byte CMap into a one-byte one, which desynchronises the whole
        // rest of the string.
        var shortest: u8 = 4;
        for (cm.codespace) |space| shortest = @min(shortest, space.bytes);
        const take = @min(shortest, @as(u8, @intCast(bytes.len - at)));
        var code: u32 = 0;
        for (0..@max(take, 1)) |i| code = (code << 8) | bytes[at + i];
        return .{ .code = code, .cid = cm.lookup(code, @max(take, 1)), .len = @max(take, 1) };
    }

    fn lookup(cm: CMap, code: u32, len: u8) u32 {
        for (cm.ranges) |r| {
            if (r.bytes == len and code >= r.low and code <= r.high) {
                return r.cid + (code - r.low);
            }
        }
        return 0;
    }
};

/// Parses an embedded CMap stream. Only the four operators that matter for
/// decoding are read: everything else -- `usecmap`, `/WMode` handling beyond
/// the flag, the ToUnicode operators -- is skipped.
fn parseCMap(arena: Allocator, src: []const u8) Allocator.Error!CMap {
    var codespace: std.ArrayList(CMap.Codespace) = .empty;
    var ranges: std.ArrayList(CMap.Range) = .empty;

    var lexer: Lexer = .init(src);
    // Up to three operands before an operator, which is all any of these take.
    var pending: [3]Object = .{ .null, .null, .null };
    var count: usize = 0;

    const Section = enum { none, codespace, cidrange, cidchar };
    var section: Section = .none;

    while (true) {
        const token = lexer.next(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        switch (token) {
            .eof => break,
            .integer => |v| {
                pending[count % 3] = .{ .integer = v };
                count += 1;
            },
            .string => |s| {
                pending[count % 3] = .{ .string = s };
                count += 1;
            },
            .keyword => |word| {
                if (std.mem.eql(u8, word, "begincodespacerange")) {
                    section = .codespace;
                    count = 0;
                } else if (std.mem.eql(u8, word, "begincidrange")) {
                    section = .cidrange;
                    count = 0;
                } else if (std.mem.eql(u8, word, "begincidchar")) {
                    section = .cidchar;
                    count = 0;
                } else if (std.mem.startsWith(u8, word, "end")) {
                    section = .none;
                    count = 0;
                } else {
                    count = 0;
                }
                continue;
            },
            else => {
                count = 0;
                continue;
            },
        }

        // Entries are fixed-arity, so completing one is a matter of counting.
        switch (section) {
            .none => {},
            .codespace => if (count == 2) {
                const lo = pending[0].asString() orelse "";
                const hi = pending[1].asString() orelse "";
                if (lo.len >= 1 and lo.len <= 4) {
                    try codespace.append(arena, .{
                        .low = packBytes(lo),
                        .high = packBytes(hi),
                        .bytes = @intCast(lo.len),
                    });
                }
                count = 0;
            },
            .cidrange => if (count == 3) {
                const lo = pending[0].asString() orelse "";
                const hi = pending[1].asString() orelse "";
                const cid = pending[2].asInt() orelse 0;
                if (lo.len >= 1 and lo.len <= 4 and cid >= 0) {
                    try ranges.append(arena, .{
                        .low = packBytes(lo),
                        .high = packBytes(hi),
                        .cid = @intCast(cid),
                        .bytes = @intCast(lo.len),
                    });
                }
                count = 0;
            },
            .cidchar => if (count == 2) {
                const code = pending[0].asString() orelse "";
                const cid = pending[1].asInt() orelse 0;
                if (code.len >= 1 and code.len <= 4 and cid >= 0) {
                    const packed_code = packBytes(code);
                    try ranges.append(arena, .{
                        .low = packed_code,
                        .high = packed_code,
                        .cid = @intCast(cid),
                        .bytes = @intCast(code.len),
                    });
                }
                count = 0;
            },
        }
    }

    return .{
        .codespace = codespace.items,
        .ranges = ranges.items,
        .identity = codespace.items.len == 0 and ranges.items.len == 0,
    };
}

fn packBytes(bytes: []const u8) u32 {
    var v: u32 = 0;
    for (bytes[0..@min(bytes.len, 4)]) |b| v = (v << 8) | b;
    return v;
}

// -- loading ----------------------------------------------------------------

/// Reads a font dictionary. Never fails on content: a dictionary that says
/// nothing useful produces a font with assumed widths, because the text still
/// has to be laid out.
pub fn load(arena: Allocator, doc: *Document, dict: Dict, ref: u32) Error!Font {
    var f: Font = .{ .object = ref };

    if (try doc.get(dict, "BaseFont")) |v| {
        if (v.asName()) |n| f.base_font = n;
    }

    const subtype = if (try doc.get(dict, "Subtype")) |v| v.asName() orelse "" else "";

    if (std.mem.eql(u8, subtype, "Type0")) {
        f.kind = .composite;
        try f.loadComposite(arena, doc, dict);
        return f;
    }

    if (std.mem.eql(u8, subtype, "Type3")) {
        f.kind = .type3;
        try f.loadType3(arena, doc, dict);
    }

    try f.loadSimpleWidths(arena, doc, dict);
    return f;
}

fn loadSimpleWidths(f: *Font, arena: Allocator, doc: *Document, dict: Dict) Error!void {
    if (try doc.get(dict, "FirstChar")) |v| {
        const n = v.asInt() orelse 0;
        f.first_char = if (n < 0 or n > 255) 0 else @intCast(n);
    }

    if (try doc.get(dict, "FontDescriptor")) |fd| {
        if (fd.asDict()) |descriptor| {
            if (try doc.get(descriptor, "MissingWidth")) |mw| {
                f.missing_width = mw.asNumber() orelse 0;
            }
        }
    }

    const list = if (try doc.get(dict, "Widths")) |v| v.asArray() else null;
    if (list) |entries| {
        const widths = try arena.alloc(f32, entries.len);
        for (widths, entries) |*w, entry| {
            const resolved = try doc.resolve(entry);
            w.* = @floatCast(resolved.asNumber() orelse f.missing_width);
        }
        f.widths = widths;
    }

    // No array and no `/MissingWidth`: one of the standard 14, whose metrics
    // are not in the file at all.
    f.widths_assumed = f.widths.len == 0 and f.missing_width == 0 and f.kind != .type3;
}

fn loadType3(f: *Font, arena: Allocator, doc: *Document, dict: Dict) Error!void {
    if (try doc.get(dict, "FontMatrix")) |v| {
        if (v.asArray()) |a| {
            if (a.len >= 6) {
                var m: [6]f64 = undefined;
                for (&m, a[0..6]) |*slot, entry| {
                    slot.* = (try doc.resolve(entry)).asNumber() orelse 0;
                }
                f.font_matrix = .fromOperands(m);
            }
        }
    }
    if (try doc.get(dict, "CharProcs")) |v| f.char_procs = v.asDict();
    if (try doc.get(dict, "Resources")) |v| f.resources = v.asDict();

    // `/Differences` is the only way a Type 3 code finds its procedure.
    if (try doc.get(dict, "Encoding")) |enc| {
        if (enc.asDict()) |encoding| {
            if (try doc.get(encoding, "Differences")) |diff| {
                if (diff.asArray()) |entries| {
                    const names = try arena.alloc([]const u8, 256);
                    @memset(names, "");
                    var code: usize = 0;
                    for (entries) |entry| {
                        const resolved = try doc.resolve(entry);
                        if (resolved.asInt()) |n| {
                            code = if (n < 0 or n > 255) 256 else @intCast(n);
                        } else if (resolved.asName()) |name| {
                            if (code < 256) names[code] = name;
                            code += 1;
                        }
                    }
                    f.encoding = names;
                }
            }
        }
    }
}

fn loadComposite(f: *Font, arena: Allocator, doc: *Document, dict: Dict) Error!void {
    // The encoding first: it decides how the string splits, which matters
    // even if the descendant font turns out to be missing.
    if (try doc.get(dict, "Encoding")) |enc| {
        switch (enc) {
            .name => |n| {
                f.vertical = std.mem.endsWith(u8, n, "-V") or std.mem.eql(u8, n, "V");
                // Identity, and every predefined CMap we cannot load, decode
                // as two-byte identity. See the header.
                f.cmap = .{ .identity = true };
            },
            .stream => |s| {
                const data = try doc.streamData(s);
                f.cmap = try parseCMap(arena, data.data);
                if (try doc.get(s.dict, "WMode")) |mode| {
                    f.vertical = (mode.asInt() orelse 0) == 1;
                }
            },
            else => {},
        }
    }

    const descendants = if (try doc.get(dict, "DescendantFonts")) |v| v.asArray() else null;
    const first = if (descendants) |d| (if (d.len != 0) d[0] else null) else null;
    const cid_font = if (first) |entry| (try doc.resolve(entry)).asDict() else null;
    const descendant = cid_font orelse return;

    if (try doc.get(descendant, "DW")) |v| {
        f.default_width = v.asNumber() orelse 1000;
    }
    if (try doc.get(descendant, "W")) |v| {
        if (v.asArray()) |entries| f.cid_widths = try parseW(arena, doc, entries);
    }
}

/// `/W` has two shapes, sometimes both in the same array (§9.7.4.3):
///
///     c [w1 w2 ... wn]     the n CIDs starting at c
///     cfirst clast w       every CID from cfirst to clast
///
/// Producers interleave them freely, so this is a state machine rather than
/// a loop over pairs.
fn parseW(arena: Allocator, doc: *Document, entries: []const Object) Error![]const CidRange {
    var out: std.ArrayList(CidRange) = .empty;

    var i: usize = 0;
    while (i < entries.len) {
        const first = (try doc.resolve(entries[i])).asInt() orelse {
            i += 1;
            continue;
        };
        i += 1;
        if (i >= entries.len) break;

        const second = try doc.resolve(entries[i]);
        if (second.asArray()) |list| {
            i += 1;
            for (list, 0..) |entry, k| {
                const w = (try doc.resolve(entry)).asNumber() orelse continue;
                const cid = first + @as(i64, @intCast(k));
                if (cid < 0 or cid > std.math.maxInt(u32)) continue;
                try out.append(arena, .{
                    .first = @intCast(cid),
                    .last = @intCast(cid),
                    .width = @floatCast(w),
                });
            }
            continue;
        }

        const last = second.asInt() orelse {
            i += 1;
            continue;
        };
        i += 1;
        if (i >= entries.len) break;
        const w = (try doc.resolve(entries[i])).asNumber() orelse 0;
        i += 1;

        if (first < 0 or last < first or last > std.math.maxInt(u32)) continue;
        try out.append(arena, .{
            .first = @intCast(first),
            .last = @intCast(last),
            .width = @floatCast(w),
        });
    }

    return out.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a simple font advances by its widths array" {
    const widths = [_]f32{ 500, 1000, 250 };
    const f: Font = .{ .kind = .simple, .first_char = 65, .widths = &widths };

    try testing.expectApproxEqAbs(@as(f64, 0.5), f.advance(.{ .code = 'A', .cid = 'A', .len = 1 }), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), f.advance(.{ .code = 'B', .cid = 'B', .len = 1 }), 1e-9);
    // Outside the array, and with no /MissingWidth: zero, as the spec says.
    try testing.expectApproxEqAbs(@as(f64, 0), f.advance(.{ .code = 'Z', .cid = 'Z', .len = 1 }), 1e-9);
}

test "a zero width inside the array is honoured, not treated as missing" {
    // Combining marks really do advance nothing.
    const widths = [_]f32{ 500, 0, 500 };
    const f: Font = .{ .kind = .simple, .first_char = 0, .widths = &widths, .missing_width = 999 };
    try testing.expectApproxEqAbs(@as(f64, 0), f.advance(.{ .code = 1, .cid = 1, .len = 1 }), 1e-9);
}

test "a font with no metrics at all falls back to half an em" {
    const f: Font = .{ .kind = .simple, .widths_assumed = true };
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.advance(.{ .code = 'x', .cid = 'x', .len = 1 }), 1e-9);
}

test "identity encoding takes two bytes at a time" {
    const f: Font = .{ .kind = .composite };
    const code = f.decode("\x00\x41\x00\x42", 0);
    try testing.expectEqual(@as(u32, 0x41), code.code);
    try testing.expectEqual(@as(u8, 2), code.len);

    // A trailing odd byte does not read past the end.
    const odd = f.decode("\x41", 0);
    try testing.expectEqual(@as(u8, 1), odd.len);
}

test "word spacing applies to a one-byte space and not a two-byte one" {
    const simple: Font = .{ .kind = .simple };
    try testing.expect(simple.isWordSpace(.{ .code = 32, .cid = 32, .len = 1 }));

    const composite: Font = .{ .kind = .composite };
    // The trap: CID 32 in a two-byte encoding is not a space, and applying
    // `Tw` to it shifts every line of CJK text.
    try testing.expect(!composite.isWordSpace(.{ .code = 32, .cid = 32, .len = 2 }));
}

test "CID widths come from ranges, with DW behind them" {
    const ranges = [_]CidRange{
        .{ .first = 1, .last = 1, .width = 250 },
        .{ .first = 10, .last = 20, .width = 1000 },
    };
    const f: Font = .{ .kind = .composite, .cid_widths = &ranges, .default_width = 500 };

    try testing.expectApproxEqAbs(@as(f64, 0.25), f.advance(.{ .code = 1, .cid = 1, .len = 2 }), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), f.advance(.{ .code = 15, .cid = 15, .len = 2 }), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.advance(.{ .code = 99, .cid = 99, .len = 2 }), 1e-9);
}

test "an embedded CMap decides code lengths from its codespace" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src =
        \\2 begincodespacerange
        \\<00> <80>
        \\<8140> <9ffc>
        \\endcodespacerange
        \\1 begincidrange
        \\<8140> <817e> 633
        \\endcidrange
        \\1 begincidchar
        \\<20> 1
        \\endcidchar
    ;
    const cmap = try parseCMap(arena_state.allocator(), src);
    try testing.expect(!cmap.identity);
    try testing.expectEqual(@as(usize, 2), cmap.codespace.len);

    // A byte below 0x80 is one code; a byte at 0x81 begins a two-byte one.
    const one = cmap.decode("\x20\x41", 0);
    try testing.expectEqual(@as(u8, 1), one.len);
    try testing.expectEqual(@as(u32, 1), one.cid);

    const two = cmap.decode("\x81\x41", 0);
    try testing.expectEqual(@as(u8, 2), two.len);
    try testing.expectEqual(@as(u32, 634), two.cid);
}

test "an unmatched code takes the shortest codespace length, not one byte" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // A CMap with a single two-byte codespace. `\xFF\xFF` is outside it, so
    // nothing matches -- and consuming one byte instead of two would put the
    // decoder half a code out of step for the rest of the string.
    const src =
        \\1 begincodespacerange
        \\<0000> <00ff>
        \\endcodespacerange
    ;
    const cmap = try parseCMap(arena_state.allocator(), src);
    try testing.expect(!cmap.identity);

    const unmatched = cmap.decode("\xff\xff\x00\x41", 0);
    try testing.expectEqual(@as(u8, 2), unmatched.len);
}

test "a CMap with no ranges falls back to identity" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const cmap = try parseCMap(arena_state.allocator(), "%!PS-Adobe-3.0 Resource-CMap\nend");
    try testing.expect(cmap.identity);
    try testing.expectEqual(@as(u8, 2), cmap.decode("\x00\x41", 0).len);
}

test "a Type 3 width goes through the font matrix, not through 1000" {
    // A font whose glyph space is 1/100 of text space, not the usual 1/1000.
    const widths = [_]f32{100};
    const f: Font = .{
        .kind = .type3,
        .widths = &widths,
        .first_char = 0,
        .font_matrix = .{ .a = 0.01, .d = 0.01 },
    };
    try testing.expectApproxEqAbs(@as(f64, 1.0), f.advance(.{ .code = 0, .cid = 0, .len = 1 }), 1e-9);
}
