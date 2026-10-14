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
//!
//! ## What a code *means*
//!
//! Decoding and advancing are about where a glyph goes. `unicodeSpans` is the
//! other question -- which letter it is -- and it is the same four entries
//! read a second way: `/ToUnicode` when the producer wrote one, and otherwise
//! the encoding chain, `/Differences` over `/BaseEncoding` over Standard,
//! ending at a glyph name that `tyr.encoding` turns into a code point.
//!
//! That import is the one edge Gjöll has outside Gelgja, and it is worth
//! saying why: the three tables behind it -- Standard, WinAnsi, MacRoman --
//! are *PDF's* encodings, Annex D of the specification, not any font format's.
//! They live in Týr because Týr was the only thing that needed them until
//! now. Copying them here to keep the layering picture tidy would be two
//! thousand lines of the same data in two places, drifting apart.

const std = @import("std");
const Allocator = std.mem.Allocator;

const DisplayList = @import("../../gelgja/DisplayList.zig");
const Document = @import("../Document.zig");
const Lexer = @import("../Lexer.zig");
const encoding = @import("../../tyr/encoding.zig");
const matrix = @import("matrix.zig");
const pdf = @import("../object.zig");

const Dict = pdf.Dict;
const Matrix = matrix.Matrix;
const Object = pdf.Object;
const UnicodeSpan = DisplayList.UnicodeSpan;

/// The most UTF-8 one code can stand for; see `DisplayList.max_unicode`.
pub const max_unicode = DisplayList.max_unicode;

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
/// `/Encoding`, or `/Encoding /BaseEncoding`, for a simple font. `.builtin`
/// when the dictionary named none.
base_encoding: encoding.Kind = .builtin,
/// `/Encoding /Differences`, 256 entries of glyph name or empty. Read for
/// every simple font, not only Type 3: it is the first link of the chain
/// that says what a code means.
differences: ?[]const []const u8 = null,

// -- what the codes mean ----------------------------------------------------

/// `/ToUnicode`, as spans into `unicode_text`. Empty when the document
/// carried none, which is when the encoding chain does the work.
to_unicode: []const UnicodeSpan = &.{},
unicode_text: []const u8 = &.{},

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

/// The glyph name a code maps to through `/Differences`, or null. It is what
/// finds a Type 3 procedure, and the first link of the chain in
/// `unicodeSpans`.
pub fn glyphName(f: *const Font, code: u32) ?[]const u8 {
    const names = f.differences orelse return null;
    if (code >= names.len) return null;
    const name = names[code];
    return if (name.len == 0) null else name;
}

// -- what the codes mean ----------------------------------------------------

/// One font's map, in the form the display list carries.
pub const Mapping = struct {
    spans: []const UnicodeSpan = &.{},
    text: []const u8 = &.{},
};

/// What this font's codes mean, as spans a display list can carry.
///
/// A composite font gets `/ToUnicode` and nothing else: its codes are CIDs
/// into an external character collection, and guessing there would read a
/// page of Japanese as Latin letters. A simple font's codes are the 256
/// bytes, so every one of them is resolved here, once, rather than carrying
/// three tables and an encoding chain into the layer that extracts text.
pub fn unicodeSpans(f: *const Font, arena: Allocator) Allocator.Error!Mapping {
    if (f.kind == .composite) return .{ .spans = f.to_unicode, .text = f.unicode_text };

    var spans: std.ArrayList(UnicodeSpan) = .empty;
    var text: std.ArrayList(u8) = .empty;
    // The code point the last span started at, so a run of codes that means a
    // run of code points can be folded into one stepping span. Printable
    // ASCII is exactly that run under all three standard encodings, so this
    // turns ninety-five spans into one and is why a Latin font's map is five
    // entries rather than two hundred.
    var last_cp: u21 = 0;
    var last_single = false;

    var buf: [max_unicode]u8 = undefined;
    for (0..256) |i| {
        const code: u32 = @intCast(i);
        const meaning = f.unicodeFor(code, &buf);
        if (meaning.len == 0) {
            last_single = false;
            continue;
        }

        const single: ?u21 = if (std.unicode.utf8CountCodepoints(meaning) catch 1 == 1)
            (std.unicode.utf8Decode(meaning) catch null)
        else
            null;

        if (single) |cp| {
            if (last_single and spans.items.len != 0) {
                const prev = &spans.items[spans.items.len - 1];
                if (prev.high + 1 == code and @as(u32, cp) == last_cp + (code - prev.low)) {
                    prev.high = code;
                    prev.step = true;
                    continue;
                }
            }
            last_cp = cp;
            last_single = true;
        } else {
            last_single = false;
        }

        const at: u32 = @intCast(text.items.len);
        try text.appendSlice(arena, meaning);
        try spans.append(arena, .{
            .low = code,
            .high = code,
            .at = at,
            .len = @intCast(meaning.len),
        });
    }

    return .{ .spans = spans.items, .text = text.items };
}

/// What one code means, in UTF-8, written into `buf`. Empty when nothing in
/// the document says.
///
/// `/ToUnicode` first, because it is the producer stating the answer. Then
/// the encoding chain: `/Differences`, the named base encoding, and Standard
/// behind both. Standard as the last resort is the specification's own
/// default (§9.6.6.2) and is right for printable ASCII under every encoding
/// a document can name; above 0x7f it is a guess, and a wrong letter there is
/// still better for a search than a hole.
pub fn unicodeFor(f: *const Font, code: u32, buf: *[max_unicode]u8) []const u8 {
    const mapped = DisplayList.unicodeIn(f.to_unicode, f.unicode_text, code, buf);
    if (mapped.len != 0) return mapped;

    if (f.kind == .composite or code > 0xff) return &.{};

    const byte: u8 = @intCast(code);
    const cp = if (f.glyphName(code)) |name|
        // A `/Differences` name nothing recognises means nothing: the base
        // encoding's letter for that code is exactly what the name was
        // written to override.
        encoding.unicodeForName(name) orelse return &.{}
    else
        encoding.codepointFor(f.base_encoding, byte) orelse
            encoding.codepointFor(.standard, byte) orelse
            return &.{};

    const len = std.unicode.utf8Encode(cp, buf) catch return &.{};
    return buf[0..len];
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

/// Parses a `/ToUnicode` CMap stream (§9.10.3).
///
/// Two operators carry everything: `bfchar` maps one code to one destination,
/// `bfrange` maps a run of them either to a run of destinations -- the string
/// form, where the last code point moves on with the code -- or to an array
/// with one destination per code. Destinations are UTF-16BE strings, so a
/// ligature and an accented letter both arrive as several code points, which
/// is the whole reason this produces text rather than code points.
///
/// A destination may also be a glyph *name*, which some producers emit; it
/// goes through the same table as the encoding chain's names do.
fn parseToUnicode(arena: Allocator, src: []const u8) Allocator.Error!Mapping {
    var spans: std.ArrayList(UnicodeSpan) = .empty;
    var text: std.ArrayList(u8) = .empty;

    var lexer: Lexer = .init(src);

    const Section = enum { none, bfchar, bfrange };
    var section: Section = .none;
    // The source codes collected so far: one for `bfchar`, two for
    // `bfrange`.
    var codes: [2]u32 = .{ 0, 0 };
    var have: usize = 0;
    // Inside a `bfrange`'s array form, and how far along it we are.
    var in_array = false;
    var index: u32 = 0;

    while (true) {
        const token = lexer.next(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };

        const destination: []const u8 = switch (token) {
            .eof => break,
            .keyword => |word| {
                if (std.mem.eql(u8, word, "beginbfchar")) {
                    section = .bfchar;
                } else if (std.mem.eql(u8, word, "beginbfrange")) {
                    section = .bfrange;
                } else {
                    section = .none;
                }
                have = 0;
                in_array = false;
                continue;
            },
            .array_open => {
                // Only meaningful once both ends of a range are in hand;
                // anywhere else it is a malformed entry to be stepped over.
                in_array = section == .bfrange and have == 2;
                index = 0;
                continue;
            },
            .array_close => {
                in_array = false;
                have = 0;
                continue;
            },
            .string => |s| s,
            .name => |n| blk: {
                // A name destination is only ever a destination, never a
                // source: sources are hex strings.
                if (section == .none or (!in_array and have == 0)) continue;
                var one: [max_unicode]u8 = undefined;
                const cp = encoding.unicodeForName(n) orelse continue;
                const len = std.unicode.utf8Encode(cp, &one) catch continue;
                break :blk try arena.dupe(u8, one[0..len]);
            },
            else => {
                if (!in_array) have = 0;
                continue;
            },
        };

        if (section == .none) continue;

        // A source code, while there is still one to collect.
        const wanted: usize = if (section == .bfchar) 1 else 2;
        if (!in_array and have < wanted) {
            if (destination.len == 0 or destination.len > 4) continue;
            codes[have] = packBytes(destination);
            have += 1;
            continue;
        }

        const low = codes[0];
        const high = if (section == .bfchar) codes[0] else codes[1];
        const at: u32 = @intCast(text.items.len);
        const len = try appendUtf8(arena, &text, destination);
        if (len != 0) {
            if (in_array) {
                // One destination per code, so nothing steps and the entry
                // covers exactly the code it was written for.
                const code = low + index;
                if (code <= high) {
                    try spans.append(arena, .{ .low = code, .high = code, .at = at, .len = len });
                }
            } else {
                try spans.append(arena, .{
                    .low = low,
                    .high = high,
                    .at = at,
                    .len = len,
                    .step = high > low,
                });
            }
        }

        if (in_array) {
            index += 1;
        } else {
            have = 0;
        }
    }

    // `unicodeIn` binary-searches these, and a producer writes its entries in
    // whatever order it likes.
    std.mem.sort(UnicodeSpan, spans.items, {}, lowerCode);
    return .{ .spans = spans.items, .text = text.items };
}

fn lowerCode(_: void, a: UnicodeSpan, b: UnicodeSpan) bool {
    return a.low < b.low;
}

/// Appends a UTF-16BE destination string to the pool as UTF-8, and says how
/// many bytes it added.
///
/// Truncated at `max_unicode`, which is thirty-two bytes and eight times the
/// longest ligature anyone has written: a destination longer than that is a
/// producer emitting a whole word for one code, and carrying it would let one
/// bad font grow the pool without bound.
fn appendUtf8(
    arena: Allocator,
    text: *std.ArrayList(u8),
    utf16be: []const u8,
) Allocator.Error!u16 {
    const before = text.items.len;
    var i: usize = 0;
    while (i + 1 < utf16be.len) : (i += 2) {
        var cp: u32 = (@as(u32, utf16be[i]) << 8) | utf16be[i + 1];
        if (cp >= 0xd800 and cp <= 0xdbff and i + 3 < utf16be.len) {
            const low = (@as(u32, utf16be[i + 2]) << 8) | utf16be[i + 3];
            if (low >= 0xdc00 and low <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                i += 2;
            }
        }
        // An unpaired surrogate, and U+0000, which producers use as filler in
        // a `bfrange` array for codes they did not want to map.
        if (cp == 0 or (cp >= 0xd800 and cp <= 0xdfff)) continue;

        var one: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &one) catch continue;
        if (text.items.len - before + len > max_unicode) break;
        try text.appendSlice(arena, one[0..len]);
    }
    return @intCast(text.items.len - before);
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

    // Before the branch: a `/ToUnicode` on a Type0 font says what its CIDs
    // mean and is the only thing that can, so it is not a simple-font detail.
    try f.loadToUnicode(arena, doc, dict);

    if (std.mem.eql(u8, subtype, "Type0")) {
        f.kind = .composite;
        try f.loadComposite(arena, doc, dict);
        return f;
    }

    if (std.mem.eql(u8, subtype, "Type3")) f.kind = .type3;

    try f.loadEncoding(arena, doc, dict);
    if (f.kind == .type3) try f.loadType3(doc, dict);
    try f.loadSimpleWidths(arena, doc, dict);
    return f;
}

fn loadToUnicode(f: *Font, arena: Allocator, doc: *Document, dict: Dict) Error!void {
    const v = try doc.get(dict, "ToUnicode") orelse return;
    const stream = v.asStream() orelse return;
    const data = try doc.streamData(stream);
    const map = try parseToUnicode(arena, data.data);
    f.to_unicode = map.spans;
    f.unicode_text = map.text;
}

/// `/Encoding`, which is either a name or a dictionary with a `/BaseEncoding`
/// and a `/Differences` array (§9.6.6).
///
/// Read for every simple font. It used to be read only for Type 3, where
/// `/Differences` is the only way a code finds its glyph procedure; the rest
/// of the chain happened in `vanagandr/glyphs.zig`, which reads the same
/// dictionary again to bind a Týr face. Both still do -- that one is about
/// finding an *outline* and this one is about finding a *letter*, and they
/// disagree on purpose for symbolic fonts.
fn loadEncoding(f: *Font, arena: Allocator, doc: *Document, dict: Dict) Error!void {
    const enc = try doc.get(dict, "Encoding") orelse return;

    if (enc.asName()) |name| {
        f.base_encoding = encoding.Kind.fromName(name) orelse .builtin;
        return;
    }

    const table = enc.asDict() orelse return;
    if (try doc.get(table, "BaseEncoding")) |base| {
        if (base.asName()) |name| {
            f.base_encoding = encoding.Kind.fromName(name) orelse .builtin;
        }
    }

    const diff = try doc.get(table, "Differences") orelse return;
    const entries = diff.asArray() orelse return;

    const names = try arena.alloc([]const u8, 256);
    @memset(names, "");
    // An integer sets the code the following names are assigned from, and
    // each name advances it: `[1 /a /b 5 /z]` is a, b, then z at 5.
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
    f.differences = names;
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

fn loadType3(f: *Font, doc: *Document, dict: Dict) Error!void {
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

test "a bfchar maps one code and a bfrange maps a run of them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src =
        \\/CIDInit /ProcSet findresource begin
        \\1 begincodespacerange <00> <ff> endcodespacerange
        \\2 beginbfchar
        \\<01> <0041>
        \\<02> <00660069>
        \\endbfchar
        \\1 beginbfrange
        \\<10> <12> <0061>
        \\endbfrange
        \\endcmap
    ;
    const map = try parseToUnicode(arena_state.allocator(), src);
    const f: Font = .{ .to_unicode = map.spans, .unicode_text = map.text };

    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("A", f.unicodeFor(0x01, &buf));
    // A ligature: one code, two letters, which is why this produces text.
    try testing.expectEqualStrings("fi", f.unicodeFor(0x02, &buf));
    try testing.expectEqualStrings("a", f.unicodeFor(0x10, &buf));
    try testing.expectEqualStrings("c", f.unicodeFor(0x12, &buf));
}

test "a bfrange array gives one destination per code and steps nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src =
        \\1 beginbfrange
        \\<20> <22> [<0041> <005A> <0030>]
        \\endbfrange
    ;
    const map = try parseToUnicode(arena_state.allocator(), src);
    const f: Font = .{ .to_unicode = map.spans, .unicode_text = map.text };

    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("A", f.unicodeFor(0x20, &buf));
    try testing.expectEqualStrings("Z", f.unicodeFor(0x21, &buf));
    try testing.expectEqualStrings("0", f.unicodeFor(0x22, &buf));
}

test "a surrogate pair is one code point, and an unpaired one is dropped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src =
        \\2 beginbfchar
        \\<01> <D83DDE00>
        \\<02> <D800>
        \\endbfchar
    ;
    const map = try parseToUnicode(arena_state.allocator(), src);
    const f: Font = .{ .to_unicode = map.spans, .unicode_text = map.text };

    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("\u{1F600}", f.unicodeFor(0x01, &buf));
    // Half a pair is not a character. Nothing, rather than U+D800, which is
    // not encodable as UTF-8 at all.
    try testing.expectEqualStrings("", f.unicodeFor(0x02, &buf));
}

test "with no /ToUnicode the encoding chain answers, differences first" {
    var names: [256][]const u8 = @splat("");
    names[0x41] = "bullet";
    const f: Font = .{ .base_encoding = .win_ansi, .differences = &names };

    var buf: [max_unicode]u8 = undefined;
    // `/Differences` beats the base encoding for the code it names.
    try testing.expectEqualStrings("\u{2022}", f.unicodeFor(0x41, &buf));
    // And the base encoding answers for every code it does not.
    try testing.expectEqualStrings("B", f.unicodeFor(0x42, &buf));
    // WinAnsi's high range, which Standard would have read differently.
    try testing.expectEqualStrings("\u{20AC}", f.unicodeFor(0x80, &buf));
}

test "a font that names no encoding still reads as ASCII" {
    // The commonest simple font there is: no /ToUnicode, no /Encoding, and
    // a search over the page still has to find the word.
    const f: Font = .{};
    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("A", f.unicodeFor('A', &buf));
    try testing.expectEqualStrings(" ", f.unicodeFor(' ', &buf));
}

test "a composite font with no /ToUnicode says nothing rather than guessing" {
    const f: Font = .{ .kind = .composite };
    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("", f.unicodeFor(0x41, &buf));
}

test "a simple font's map folds its ASCII run into one stepping span" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const f: Font = .{};
    const map = try f.unicodeSpans(arena_state.allocator());

    // Every letter and digit means itself under StandardEncoding, so the
    // whole of `0..9A..Za..z` is three spans and not sixty-two.
    var covering: ?UnicodeSpan = null;
    for (map.spans) |s| {
        if ('A' >= s.low and 'A' <= s.high) covering = s;
    }
    try testing.expect(covering != null);
    try testing.expect(covering.?.high >= 'Z');
    try testing.expect(covering.?.step);

    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("A", DisplayList.unicodeIn(map.spans, map.text, 'A', &buf));
    try testing.expectEqualStrings("~", DisplayList.unicodeIn(map.spans, map.text, '~', &buf));
}
