//! Character codes to glyph names to code points: the table-lookup half of
//! turning a byte in a content stream into a shape.
//!
//! A PDF simple font addresses its glyphs with single bytes, and what those
//! bytes mean is decided by a chain of fallbacks that the specification lays
//! out over several pages (§9.6.6) and that every producer bends slightly:
//!
//!     /Differences  ->  the font program's built-in encoding
//!                   ->  /BaseEncoding
//!                   ->  StandardEncoding or the symbolic font's own cmap
//!
//! The output of that chain is a *glyph name*, not a glyph. A name reaches an
//! actual outline in one of three ways depending on the font program: through
//! CFF's charset, through TrueType's `post` table, or -- most often, because
//! subsetted TrueType fonts usually have no usable `post` -- by turning the
//! name into a Unicode code point and going through the `cmap`. That last hop
//! is what `unicodeForName` is for.
//!
//! ## Why these three tables and not the AGL
//!
//! Adobe's full glyph list is about four thousand names and would be most of
//! this file's weight for names no PDF encoding can produce. What is here is
//! the union of what the four standard encodings can name, plus the two
//! algorithmic forms -- `uniXXXX` and `uXXXXXX` -- which is how every name
//! outside the standard set is written in practice.
//!
//! ## Symbolic fonts
//!
//! A font whose descriptor sets the symbolic flag is *supposed* to ignore all
//! of this and use its own built-in encoding. Producers set that flag on
//! ordinary text fonts constantly, so the flag is a hint here rather than a
//! rule: the caller tries the font's own cmap first and falls back to the name
//! chain, which is what every reader that renders real documents does.

const std = @import("std");

pub const Kind = enum {
    standard,
    win_ansi,
    mac_roman,
    /// `/MacExpertEncoding`. Recognised so that a font naming it is not
    /// silently given Standard instead, but its names are not tabulated: it
    /// addresses small caps and old-style figures that a subsetted font
    /// almost never carries.
    mac_expert,
    /// No base encoding: the font program's own.
    builtin,

    pub fn fromName(name: []const u8) ?Kind {
        if (std.mem.eql(u8, name, "WinAnsiEncoding")) return .win_ansi;
        if (std.mem.eql(u8, name, "MacRomanEncoding")) return .mac_roman;
        if (std.mem.eql(u8, name, "StandardEncoding")) return .standard;
        if (std.mem.eql(u8, name, "MacExpertEncoding")) return .mac_expert;
        return null;
    }

    pub fn table(k: Kind) ?*const [256]?[]const u8 {
        return switch (k) {
            .standard => &standard,
            .win_ansi => &win_ansi,
            .mac_roman => &mac_roman,
            .mac_expert, .builtin => null,
        };
    }
};

/// The glyph name a code means under one of the standard encodings.
pub fn nameFor(k: Kind, code: u8) ?[]const u8 {
    const t = k.table() orelse return null;
    return t[code];
}

/// The Unicode code point a glyph name stands for.
///
/// Three sources, in order: the algorithmic `uniXXXX` forms, which are exact
/// and are how anything outside the standard set is spelled; the table below;
/// and a single-character name, which means itself (`A` is U+0041) and is what
/// a badly built subsetter emits.
pub fn unicodeForName(name: []const u8) ?u21 {
    if (name.len == 0) return null;

    // `uniXXXX`, and the multi-value form `uni0041004200430044` of which only
    // the first is the base character.
    if (name.len >= 7 and std.mem.startsWith(u8, name, "uni")) {
        if (std.fmt.parseInt(u16, name[3..7], 16)) |v| {
            return @intCast(v);
        } else |_| {}
    }
    // `uXXXX` through `uXXXXXX`.
    if (name.len >= 5 and name.len <= 7 and name[0] == 'u') {
        if (std.fmt.parseInt(u32, name[1..], 16)) |v| {
            if (v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF)) return @intCast(v);
        } else |_| {}
    }

    // A name with a suffix: `a.sc`, `one.oldstyle`, `f_f_i.liga`. The part
    // before the first dot is the name proper (§ Adobe's glyph list
    // specification), and ignoring the suffix is much better than failing.
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) return unicodeForName(name[0..dot]);
    }

    for (name_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.cp;
    }

    if (name.len == 1 and name[0] >= 0x20 and name[0] < 0x7f) return name[0];
    return null;
}

/// `g42`, `glyph42`, `index42`, `cid42`: a name that is really a glyph number.
///
/// Subsetters that drop the `post` table emit these, and a reader that does
/// not understand them renders nothing for a font that is otherwise perfectly
/// intact.
pub fn glyphNumberForName(name: []const u8) ?u16 {
    const prefixes = [_][]const u8{ "glyph", "index", "cid", "g" };
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, name, p)) continue;
        const rest = name[p.len..];
        if (rest.len == 0) continue;
        return std.fmt.parseInt(u16, rest, 10) catch continue;
    }
    return null;
}

const Named = struct { name: []const u8, cp: u21 };

/// Every name the three tables below can produce, with its code point.
///
/// Built by hand from the encoding tables rather than from the AGL, so it is
/// exactly as large as it needs to be: a name that no standard encoding can
/// name reaches Unicode through `uniXXXX` instead.
const name_table = [_]Named{
    .{ .name = "space", .cp = 0x0020 },          .{ .name = "exclam", .cp = 0x0021 },
    .{ .name = "quotedbl", .cp = 0x0022 },       .{ .name = "numbersign", .cp = 0x0023 },
    .{ .name = "dollar", .cp = 0x0024 },         .{ .name = "percent", .cp = 0x0025 },
    .{ .name = "ampersand", .cp = 0x0026 },      .{ .name = "quotesingle", .cp = 0x0027 },
    .{ .name = "quoteright", .cp = 0x2019 },     .{ .name = "parenleft", .cp = 0x0028 },
    .{ .name = "parenright", .cp = 0x0029 },     .{ .name = "asterisk", .cp = 0x002A },
    .{ .name = "plus", .cp = 0x002B },           .{ .name = "comma", .cp = 0x002C },
    .{ .name = "hyphen", .cp = 0x002D },         .{ .name = "period", .cp = 0x002E },
    .{ .name = "slash", .cp = 0x002F },          .{ .name = "zero", .cp = 0x0030 },
    .{ .name = "one", .cp = 0x0031 },            .{ .name = "two", .cp = 0x0032 },
    .{ .name = "three", .cp = 0x0033 },          .{ .name = "four", .cp = 0x0034 },
    .{ .name = "five", .cp = 0x0035 },           .{ .name = "six", .cp = 0x0036 },
    .{ .name = "seven", .cp = 0x0037 },          .{ .name = "eight", .cp = 0x0038 },
    .{ .name = "nine", .cp = 0x0039 },           .{ .name = "colon", .cp = 0x003A },
    .{ .name = "semicolon", .cp = 0x003B },      .{ .name = "less", .cp = 0x003C },
    .{ .name = "equal", .cp = 0x003D },          .{ .name = "greater", .cp = 0x003E },
    .{ .name = "question", .cp = 0x003F },       .{ .name = "at", .cp = 0x0040 },
    .{ .name = "bracketleft", .cp = 0x005B },    .{ .name = "backslash", .cp = 0x005C },
    .{ .name = "bracketright", .cp = 0x005D },   .{ .name = "asciicircum", .cp = 0x005E },
    .{ .name = "underscore", .cp = 0x005F },     .{ .name = "grave", .cp = 0x0060 },
    .{ .name = "quoteleft", .cp = 0x2018 },      .{ .name = "braceleft", .cp = 0x007B },
    .{ .name = "bar", .cp = 0x007C },            .{ .name = "braceright", .cp = 0x007D },
    .{ .name = "asciitilde", .cp = 0x007E },     .{ .name = "exclamdown", .cp = 0x00A1 },
    .{ .name = "cent", .cp = 0x00A2 },           .{ .name = "sterling", .cp = 0x00A3 },
    .{ .name = "fraction", .cp = 0x2044 },       .{ .name = "yen", .cp = 0x00A5 },
    .{ .name = "florin", .cp = 0x0192 },         .{ .name = "section", .cp = 0x00A7 },
    .{ .name = "currency", .cp = 0x00A4 },       .{ .name = "quotedblleft", .cp = 0x201C },
    .{ .name = "guillemotleft", .cp = 0x00AB },  .{ .name = "guilsinglleft", .cp = 0x2039 },
    .{ .name = "guilsinglright", .cp = 0x203A }, .{ .name = "fi", .cp = 0xFB01 },
    .{ .name = "fl", .cp = 0xFB02 },             .{ .name = "endash", .cp = 0x2013 },
    .{ .name = "dagger", .cp = 0x2020 },         .{ .name = "daggerdbl", .cp = 0x2021 },
    .{ .name = "periodcentered", .cp = 0x00B7 }, .{ .name = "paragraph", .cp = 0x00B6 },
    .{ .name = "bullet", .cp = 0x2022 },         .{ .name = "quotesinglbase", .cp = 0x201A },
    .{ .name = "quotedblbase", .cp = 0x201E },   .{ .name = "quotedblright", .cp = 0x201D },
    .{ .name = "guillemotright", .cp = 0x00BB }, .{ .name = "ellipsis", .cp = 0x2026 },
    .{ .name = "perthousand", .cp = 0x2030 },    .{ .name = "questiondown", .cp = 0x00BF },
    .{ .name = "acute", .cp = 0x00B4 },          .{ .name = "circumflex", .cp = 0x02C6 },
    .{ .name = "tilde", .cp = 0x02DC },          .{ .name = "macron", .cp = 0x00AF },
    .{ .name = "breve", .cp = 0x02D8 },          .{ .name = "dotaccent", .cp = 0x02D9 },
    .{ .name = "dieresis", .cp = 0x00A8 },       .{ .name = "ring", .cp = 0x02DA },
    .{ .name = "cedilla", .cp = 0x00B8 },        .{ .name = "hungarumlaut", .cp = 0x02DD },
    .{ .name = "ogonek", .cp = 0x02DB },         .{ .name = "caron", .cp = 0x02C7 },
    .{ .name = "emdash", .cp = 0x2014 },         .{ .name = "AE", .cp = 0x00C6 },
    .{ .name = "ordfeminine", .cp = 0x00AA },    .{ .name = "Lslash", .cp = 0x0141 },
    .{ .name = "Oslash", .cp = 0x00D8 },         .{ .name = "OE", .cp = 0x0152 },
    .{ .name = "ordmasculine", .cp = 0x00BA },   .{ .name = "ae", .cp = 0x00E6 },
    .{ .name = "dotlessi", .cp = 0x0131 },       .{ .name = "lslash", .cp = 0x0142 },
    .{ .name = "oslash", .cp = 0x00F8 },         .{ .name = "oe", .cp = 0x0153 },
    .{ .name = "germandbls", .cp = 0x00DF },     .{ .name = "Aacute", .cp = 0x00C1 },
    .{ .name = "Acircumflex", .cp = 0x00C2 },    .{ .name = "Adieresis", .cp = 0x00C4 },
    .{ .name = "Agrave", .cp = 0x00C0 },         .{ .name = "Aring", .cp = 0x00C5 },
    .{ .name = "Atilde", .cp = 0x00C3 },         .{ .name = "Ccedilla", .cp = 0x00C7 },
    .{ .name = "Eacute", .cp = 0x00C9 },         .{ .name = "Ecircumflex", .cp = 0x00CA },
    .{ .name = "Edieresis", .cp = 0x00CB },      .{ .name = "Egrave", .cp = 0x00C8 },
    .{ .name = "Iacute", .cp = 0x00CD },         .{ .name = "Icircumflex", .cp = 0x00CE },
    .{ .name = "Idieresis", .cp = 0x00CF },      .{ .name = "Igrave", .cp = 0x00CC },
    .{ .name = "Ntilde", .cp = 0x00D1 },         .{ .name = "Oacute", .cp = 0x00D3 },
    .{ .name = "Ocircumflex", .cp = 0x00D4 },    .{ .name = "Odieresis", .cp = 0x00D6 },
    .{ .name = "Ograve", .cp = 0x00D2 },         .{ .name = "Otilde", .cp = 0x00D5 },
    .{ .name = "Scaron", .cp = 0x0160 },         .{ .name = "Thorn", .cp = 0x00DE },
    .{ .name = "Uacute", .cp = 0x00DA },         .{ .name = "Ucircumflex", .cp = 0x00DB },
    .{ .name = "Udieresis", .cp = 0x00DC },      .{ .name = "Ugrave", .cp = 0x00D9 },
    .{ .name = "Yacute", .cp = 0x00DD },         .{ .name = "Ydieresis", .cp = 0x0178 },
    .{ .name = "Zcaron", .cp = 0x017D },         .{ .name = "aacute", .cp = 0x00E1 },
    .{ .name = "acircumflex", .cp = 0x00E2 },    .{ .name = "adieresis", .cp = 0x00E4 },
    .{ .name = "agrave", .cp = 0x00E0 },         .{ .name = "aring", .cp = 0x00E5 },
    .{ .name = "atilde", .cp = 0x00E3 },         .{ .name = "ccedilla", .cp = 0x00E7 },
    .{ .name = "eacute", .cp = 0x00E9 },         .{ .name = "ecircumflex", .cp = 0x00EA },
    .{ .name = "edieresis", .cp = 0x00EB },      .{ .name = "egrave", .cp = 0x00E8 },
    .{ .name = "iacute", .cp = 0x00ED },         .{ .name = "icircumflex", .cp = 0x00EE },
    .{ .name = "idieresis", .cp = 0x00EF },      .{ .name = "igrave", .cp = 0x00EC },
    .{ .name = "ntilde", .cp = 0x00F1 },         .{ .name = "oacute", .cp = 0x00F3 },
    .{ .name = "ocircumflex", .cp = 0x00F4 },    .{ .name = "odieresis", .cp = 0x00F6 },
    .{ .name = "ograve", .cp = 0x00F2 },         .{ .name = "otilde", .cp = 0x00F5 },
    .{ .name = "scaron", .cp = 0x0161 },         .{ .name = "thorn", .cp = 0x00FE },
    .{ .name = "uacute", .cp = 0x00FA },         .{ .name = "ucircumflex", .cp = 0x00FB },
    .{ .name = "udieresis", .cp = 0x00FC },      .{ .name = "ugrave", .cp = 0x00F9 },
    .{ .name = "yacute", .cp = 0x00FD },         .{ .name = "ydieresis", .cp = 0x00FF },
    .{ .name = "zcaron", .cp = 0x017E },         .{ .name = "brokenbar", .cp = 0x00A6 },
    .{ .name = "copyright", .cp = 0x00A9 },      .{ .name = "logicalnot", .cp = 0x00AC },
    .{ .name = "registered", .cp = 0x00AE },     .{ .name = "degree", .cp = 0x00B0 },
    .{ .name = "plusminus", .cp = 0x00B1 },      .{ .name = "twosuperior", .cp = 0x00B2 },
    .{ .name = "threesuperior", .cp = 0x00B3 },  .{ .name = "mu", .cp = 0x00B5 },
    .{ .name = "onesuperior", .cp = 0x00B9 },    .{ .name = "onequarter", .cp = 0x00BC },
    .{ .name = "onehalf", .cp = 0x00BD },        .{ .name = "threequarters", .cp = 0x00BE },
    .{ .name = "multiply", .cp = 0x00D7 },       .{ .name = "divide", .cp = 0x00F7 },
    .{ .name = "Eth", .cp = 0x00D0 },            .{ .name = "eth", .cp = 0x00F0 },
    .{ .name = "trademark", .cp = 0x2122 },      .{ .name = "Euro", .cp = 0x20AC },
    .{ .name = "Delta", .cp = 0x2206 },          .{ .name = "Omega", .cp = 0x2126 },
    .{ .name = "pi", .cp = 0x03C0 },             .{ .name = "summation", .cp = 0x2211 },
    .{ .name = "product", .cp = 0x220F },        .{ .name = "radical", .cp = 0x221A },
    .{ .name = "infinity", .cp = 0x221E },       .{ .name = "integral", .cp = 0x222B },
    .{ .name = "approxequal", .cp = 0x2248 },    .{ .name = "notequal", .cp = 0x2260 },
    .{ .name = "lessequal", .cp = 0x2264 },      .{ .name = "greaterequal", .cp = 0x2265 },
    .{ .name = "lozenge", .cp = 0x25CA },        .{ .name = "partialdiff", .cp = 0x2202 },
    .{ .name = "nbspace", .cp = 0x00A0 },        .{ .name = "nonbreakingspace", .cp = 0x00A0 },
    .{ .name = "softhyphen", .cp = 0x00AD },     .{ .name = "minus", .cp = 0x2212 },
};

/// Codes 0x20..0x7E are ASCII in all three tables, and writing them out three
/// times invites one of the copies to be wrong. This fills that range from a
/// single list and each table then overrides what it differs on.
const ascii_names = blk: {
    var t: [256]?[]const u8 = @splat(null);
    const low = [_][]const u8{
        "space",     "exclam",    "quotedbl",  "numbersign",   "dollar",
        "percent",   "ampersand", "quoteright", "parenleft",   "parenright",
        "asterisk",  "plus",      "comma",     "hyphen",       "period",
        "slash",     "zero",      "one",       "two",          "three",
        "four",      "five",      "six",       "seven",        "eight",
        "nine",      "colon",     "semicolon", "less",         "equal",
        "greater",   "question",  "at",
    };
    for (low, 0..) |n, i| t[0x20 + i] = n;
    for (0..26) |i| {
        t[0x41 + i] = &[_]u8{@intCast('A' + i)};
        t[0x61 + i] = &[_]u8{@intCast('a' + i)};
    }
    const punct = [_]struct { u8, []const u8 }{
        .{ 0x5B, "bracketleft" }, .{ 0x5C, "backslash" },  .{ 0x5D, "bracketright" },
        .{ 0x5E, "asciicircum" }, .{ 0x5F, "underscore" }, .{ 0x60, "quoteleft" },
        .{ 0x7B, "braceleft" },   .{ 0x7C, "bar" },        .{ 0x7D, "braceright" },
        .{ 0x7E, "asciitilde" },
    };
    for (punct) |p| t[p[0]] = p[1];
    break :blk t;
};

/// §D.2. The default for a non-symbolic font with no `/Encoding`.
pub const standard = blk: {
    var t = ascii_names;
    const high = [_]struct { u8, []const u8 }{
        .{ 0xA1, "exclamdown" },     .{ 0xA2, "cent" },           .{ 0xA3, "sterling" },
        .{ 0xA4, "fraction" },       .{ 0xA5, "yen" },            .{ 0xA6, "florin" },
        .{ 0xA7, "section" },        .{ 0xA8, "currency" },       .{ 0xA9, "quotesingle" },
        .{ 0xAA, "quotedblleft" },   .{ 0xAB, "guillemotleft" },  .{ 0xAC, "guilsinglleft" },
        .{ 0xAD, "guilsinglright" }, .{ 0xAE, "fi" },             .{ 0xAF, "fl" },
        .{ 0xB1, "endash" },         .{ 0xB2, "dagger" },         .{ 0xB3, "daggerdbl" },
        .{ 0xB4, "periodcentered" }, .{ 0xB6, "paragraph" },      .{ 0xB7, "bullet" },
        .{ 0xB8, "quotesinglbase" }, .{ 0xB9, "quotedblbase" },   .{ 0xBA, "quotedblright" },
        .{ 0xBB, "guillemotright" }, .{ 0xBC, "ellipsis" },       .{ 0xBD, "perthousand" },
        .{ 0xBF, "questiondown" },   .{ 0xC1, "grave" },          .{ 0xC2, "acute" },
        .{ 0xC3, "circumflex" },     .{ 0xC4, "tilde" },          .{ 0xC5, "macron" },
        .{ 0xC6, "breve" },          .{ 0xC7, "dotaccent" },      .{ 0xC8, "dieresis" },
        .{ 0xCA, "ring" },           .{ 0xCB, "cedilla" },        .{ 0xCD, "hungarumlaut" },
        .{ 0xCE, "ogonek" },         .{ 0xCF, "caron" },          .{ 0xD0, "emdash" },
        .{ 0xE1, "AE" },             .{ 0xE3, "ordfeminine" },    .{ 0xE8, "Lslash" },
        .{ 0xE9, "Oslash" },         .{ 0xEA, "OE" },             .{ 0xEB, "ordmasculine" },
        .{ 0xF1, "ae" },             .{ 0xF5, "dotlessi" },       .{ 0xF8, "lslash" },
        .{ 0xF9, "oslash" },         .{ 0xFA, "oe" },             .{ 0xFB, "germandbls" },
    };
    for (high) |p| t[p[0]] = p[1];
    break :blk t;
};

/// §D.2. Windows code page 1252, and by a wide margin the commonest encoding
/// in real files.
pub const win_ansi = blk: {
    var t = ascii_names;
    // WinAnsi differs from Standard down here: code 39 is a straight quote and
    // 96 a backtick, not the curly pair Standard names.
    t[0x27] = "quotesingle";
    t[0x60] = "grave";
    const high = [_]struct { u8, []const u8 }{
        .{ 0x80, "Euro" },           .{ 0x82, "quotesinglbase" }, .{ 0x83, "florin" },
        .{ 0x84, "quotedblbase" },   .{ 0x85, "ellipsis" },       .{ 0x86, "dagger" },
        .{ 0x87, "daggerdbl" },      .{ 0x88, "circumflex" },     .{ 0x89, "perthousand" },
        .{ 0x8A, "Scaron" },         .{ 0x8B, "guilsinglleft" },  .{ 0x8C, "OE" },
        .{ 0x8E, "Zcaron" },         .{ 0x91, "quoteleft" },      .{ 0x92, "quoteright" },
        .{ 0x93, "quotedblleft" },   .{ 0x94, "quotedblright" },  .{ 0x95, "bullet" },
        .{ 0x96, "endash" },         .{ 0x97, "emdash" },         .{ 0x98, "tilde" },
        .{ 0x99, "trademark" },      .{ 0x9A, "scaron" },         .{ 0x9B, "guilsinglright" },
        .{ 0x9C, "oe" },             .{ 0x9E, "zcaron" },         .{ 0x9F, "Ydieresis" },
        .{ 0xA0, "space" },          .{ 0xA1, "exclamdown" },     .{ 0xA2, "cent" },
        .{ 0xA3, "sterling" },       .{ 0xA4, "currency" },       .{ 0xA5, "yen" },
        .{ 0xA6, "brokenbar" },      .{ 0xA7, "section" },        .{ 0xA8, "dieresis" },
        .{ 0xA9, "copyright" },      .{ 0xAA, "ordfeminine" },    .{ 0xAB, "guillemotleft" },
        .{ 0xAC, "logicalnot" },     .{ 0xAD, "hyphen" },         .{ 0xAE, "registered" },
        .{ 0xAF, "macron" },         .{ 0xB0, "degree" },         .{ 0xB1, "plusminus" },
        .{ 0xB2, "twosuperior" },    .{ 0xB3, "threesuperior" },  .{ 0xB4, "acute" },
        .{ 0xB5, "mu" },             .{ 0xB6, "paragraph" },      .{ 0xB7, "periodcentered" },
        .{ 0xB8, "cedilla" },        .{ 0xB9, "onesuperior" },    .{ 0xBA, "ordmasculine" },
        .{ 0xBB, "guillemotright" }, .{ 0xBC, "onequarter" },     .{ 0xBD, "onehalf" },
        .{ 0xBE, "threequarters" },  .{ 0xBF, "questiondown" },   .{ 0xC0, "Agrave" },
        .{ 0xC1, "Aacute" },         .{ 0xC2, "Acircumflex" },    .{ 0xC3, "Atilde" },
        .{ 0xC4, "Adieresis" },      .{ 0xC5, "Aring" },          .{ 0xC6, "AE" },
        .{ 0xC7, "Ccedilla" },       .{ 0xC8, "Egrave" },         .{ 0xC9, "Eacute" },
        .{ 0xCA, "Ecircumflex" },    .{ 0xCB, "Edieresis" },      .{ 0xCC, "Igrave" },
        .{ 0xCD, "Iacute" },         .{ 0xCE, "Icircumflex" },    .{ 0xCF, "Idieresis" },
        .{ 0xD0, "Eth" },            .{ 0xD1, "Ntilde" },         .{ 0xD2, "Ograve" },
        .{ 0xD3, "Oacute" },         .{ 0xD4, "Ocircumflex" },    .{ 0xD5, "Otilde" },
        .{ 0xD6, "Odieresis" },      .{ 0xD7, "multiply" },       .{ 0xD8, "Oslash" },
        .{ 0xD9, "Ugrave" },         .{ 0xDA, "Uacute" },         .{ 0xDB, "Ucircumflex" },
        .{ 0xDC, "Udieresis" },      .{ 0xDD, "Yacute" },         .{ 0xDE, "Thorn" },
        .{ 0xDF, "germandbls" },     .{ 0xE0, "agrave" },         .{ 0xE1, "aacute" },
        .{ 0xE2, "acircumflex" },    .{ 0xE3, "atilde" },         .{ 0xE4, "adieresis" },
        .{ 0xE5, "aring" },          .{ 0xE6, "ae" },             .{ 0xE7, "ccedilla" },
        .{ 0xE8, "egrave" },         .{ 0xE9, "eacute" },         .{ 0xEA, "ecircumflex" },
        .{ 0xEB, "edieresis" },      .{ 0xEC, "igrave" },         .{ 0xED, "iacute" },
        .{ 0xEE, "icircumflex" },    .{ 0xEF, "idieresis" },      .{ 0xF0, "eth" },
        .{ 0xF1, "ntilde" },         .{ 0xF2, "ograve" },         .{ 0xF3, "oacute" },
        .{ 0xF4, "ocircumflex" },    .{ 0xF5, "otilde" },         .{ 0xF6, "odieresis" },
        .{ 0xF7, "divide" },         .{ 0xF8, "oslash" },         .{ 0xF9, "ugrave" },
        .{ 0xFA, "uacute" },         .{ 0xFB, "ucircumflex" },    .{ 0xFC, "udieresis" },
        .{ 0xFD, "yacute" },         .{ 0xFE, "thorn" },          .{ 0xFF, "ydieresis" },
    };
    for (high) |p| t[p[0]] = p[1];
    break :blk t;
};

/// §D.2. What a PDF written on a Mac before about 2005 uses.
pub const mac_roman = blk: {
    var t = ascii_names;
    t[0x27] = "quotesingle";
    t[0x60] = "grave";
    const high = [_]struct { u8, []const u8 }{
        .{ 0x80, "Adieresis" },      .{ 0x81, "Aring" },          .{ 0x82, "Ccedilla" },
        .{ 0x83, "Eacute" },         .{ 0x84, "Ntilde" },         .{ 0x85, "Odieresis" },
        .{ 0x86, "Udieresis" },      .{ 0x87, "aacute" },         .{ 0x88, "agrave" },
        .{ 0x89, "acircumflex" },    .{ 0x8A, "adieresis" },      .{ 0x8B, "atilde" },
        .{ 0x8C, "aring" },          .{ 0x8D, "ccedilla" },       .{ 0x8E, "eacute" },
        .{ 0x8F, "egrave" },         .{ 0x90, "ecircumflex" },    .{ 0x91, "edieresis" },
        .{ 0x92, "iacute" },         .{ 0x93, "igrave" },         .{ 0x94, "icircumflex" },
        .{ 0x95, "idieresis" },      .{ 0x96, "ntilde" },         .{ 0x97, "oacute" },
        .{ 0x98, "ograve" },         .{ 0x99, "ocircumflex" },    .{ 0x9A, "odieresis" },
        .{ 0x9B, "otilde" },         .{ 0x9C, "uacute" },         .{ 0x9D, "ugrave" },
        .{ 0x9E, "ucircumflex" },    .{ 0x9F, "udieresis" },      .{ 0xA0, "dagger" },
        .{ 0xA1, "degree" },         .{ 0xA2, "cent" },           .{ 0xA3, "sterling" },
        .{ 0xA4, "section" },        .{ 0xA5, "bullet" },         .{ 0xA6, "paragraph" },
        .{ 0xA7, "germandbls" },     .{ 0xA8, "registered" },     .{ 0xA9, "copyright" },
        .{ 0xAA, "trademark" },      .{ 0xAB, "acute" },          .{ 0xAC, "dieresis" },
        .{ 0xAD, "notequal" },       .{ 0xAE, "AE" },             .{ 0xAF, "Oslash" },
        .{ 0xB0, "infinity" },       .{ 0xB1, "plusminus" },      .{ 0xB2, "lessequal" },
        .{ 0xB3, "greaterequal" },   .{ 0xB4, "yen" },            .{ 0xB5, "mu" },
        .{ 0xB6, "partialdiff" },    .{ 0xB7, "summation" },      .{ 0xB8, "product" },
        .{ 0xB9, "pi" },             .{ 0xBA, "integral" },       .{ 0xBB, "ordfeminine" },
        .{ 0xBC, "ordmasculine" },   .{ 0xBD, "Omega" },          .{ 0xBE, "ae" },
        .{ 0xBF, "oslash" },         .{ 0xC0, "questiondown" },   .{ 0xC1, "exclamdown" },
        .{ 0xC2, "logicalnot" },     .{ 0xC3, "radical" },        .{ 0xC4, "florin" },
        .{ 0xC5, "approxequal" },    .{ 0xC6, "Delta" },          .{ 0xC7, "guillemotleft" },
        .{ 0xC8, "guillemotright" }, .{ 0xC9, "ellipsis" },       .{ 0xCA, "space" },
        .{ 0xCB, "Agrave" },         .{ 0xCC, "Atilde" },         .{ 0xCD, "Otilde" },
        .{ 0xCE, "OE" },             .{ 0xCF, "oe" },             .{ 0xD0, "endash" },
        .{ 0xD1, "emdash" },         .{ 0xD2, "quotedblleft" },   .{ 0xD3, "quotedblright" },
        .{ 0xD4, "quoteleft" },      .{ 0xD5, "quoteright" },     .{ 0xD6, "divide" },
        .{ 0xD7, "lozenge" },        .{ 0xD8, "ydieresis" },      .{ 0xD9, "Ydieresis" },
        .{ 0xDA, "fraction" },       .{ 0xDB, "currency" },       .{ 0xDC, "guilsinglleft" },
        .{ 0xDD, "guilsinglright" }, .{ 0xDE, "fi" },             .{ 0xDF, "fl" },
        .{ 0xE0, "daggerdbl" },      .{ 0xE1, "periodcentered" }, .{ 0xE2, "quotesinglbase" },
        .{ 0xE3, "quotedblbase" },   .{ 0xE4, "perthousand" },    .{ 0xE5, "Acircumflex" },
        .{ 0xE6, "Ecircumflex" },    .{ 0xE7, "Aacute" },         .{ 0xE8, "Edieresis" },
        .{ 0xE9, "Egrave" },         .{ 0xEA, "Iacute" },         .{ 0xEB, "Icircumflex" },
        .{ 0xEC, "Idieresis" },      .{ 0xED, "Igrave" },         .{ 0xEE, "Oacute" },
        .{ 0xEF, "Ocircumflex" },    .{ 0xF1, "Ograve" },         .{ 0xF2, "Uacute" },
        .{ 0xF3, "Ucircumflex" },    .{ 0xF4, "Ugrave" },         .{ 0xF5, "dotlessi" },
        .{ 0xF6, "circumflex" },     .{ 0xF7, "tilde" },          .{ 0xF8, "macron" },
        .{ 0xF9, "breve" },          .{ 0xFA, "dotaccent" },      .{ 0xFB, "ring" },
        .{ 0xFC, "cedilla" },        .{ 0xFD, "hungarumlaut" },   .{ 0xFE, "ogonek" },
        .{ 0xFF, "caron" },
    };
    for (high) |p| t[p[0]] = p[1];
    break :blk t;
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the three encodings agree on ASCII and differ where they should" {
    // Letters and digits are the same in all three, which is what makes a
    // wrong /Encoding survive most of a page before anyone notices.
    for ([_]Kind{ .standard, .win_ansi, .mac_roman }) |k| {
        try testing.expectEqualStrings("A", nameFor(k, 'A').?);
        try testing.expectEqualStrings("z", nameFor(k, 'z').?);
        try testing.expectEqualStrings("five", nameFor(k, '5').?);
        try testing.expectEqualStrings("space", nameFor(k, ' ').?);
    }

    // Code 39 is the one difference inside ASCII, and it is the reason an
    // apostrophe comes out as a curly quote in files that pick the wrong one.
    try testing.expectEqualStrings("quoteright", nameFor(.standard, 0x27).?);
    try testing.expectEqualStrings("quotesingle", nameFor(.win_ansi, 0x27).?);
    try testing.expectEqualStrings("quotesingle", nameFor(.mac_roman, 0x27).?);

    // And high codes diverge completely.
    try testing.expectEqualStrings("Adieresis", nameFor(.mac_roman, 0x80).?);
    try testing.expectEqualStrings("Euro", nameFor(.win_ansi, 0x80).?);
    try testing.expect(nameFor(.standard, 0x80) == null);
}

test "an encoding is recognised by name and unknown ones are not guessed at" {
    try testing.expectEqual(Kind.win_ansi, Kind.fromName("WinAnsiEncoding").?);
    try testing.expectEqual(Kind.mac_roman, Kind.fromName("MacRomanEncoding").?);
    try testing.expectEqual(Kind.standard, Kind.fromName("StandardEncoding").?);
    // Recognised but deliberately untabulated: better an empty table than
    // Standard's names silently standing in for expert forms.
    try testing.expectEqual(Kind.mac_expert, Kind.fromName("MacExpertEncoding").?);
    try testing.expect(Kind.mac_expert.table() == null);
    try testing.expect(Kind.fromName("Identity-H") == null);
}

test "names reach code points three ways" {
    try testing.expectEqual(@as(u21, 'A'), unicodeForName("A").?);
    try testing.expectEqual(@as(u21, 0x00E9), unicodeForName("eacute").?);
    try testing.expectEqual(@as(u21, 0xFB01), unicodeForName("fi").?);
    try testing.expectEqual(@as(u21, 0x20AC), unicodeForName("Euro").?);

    // The algorithmic forms, which is how everything outside the tables is
    // spelled.
    try testing.expectEqual(@as(u21, 0x0041), unicodeForName("uni0041").?);
    try testing.expectEqual(@as(u21, 0x4E2D), unicodeForName("uni4E2D").?);
    try testing.expectEqual(@as(u21, 0x1F600), unicodeForName("u1F600").?);
    // A multi-value uniXXXX names a ligature; the first is the base.
    try testing.expectEqual(@as(u21, 0x0066), unicodeForName("uni00660066").?);

    // A suffix is a variant of the same character, not a different one.
    try testing.expectEqual(@as(u21, 'a'), unicodeForName("a.sc").?);
    try testing.expectEqual(@as(u21, 0x0031), unicodeForName("one.oldstyle").?);

    try testing.expect(unicodeForName("") == null);
    try testing.expect(unicodeForName("notaglyphname") == null);
    // A surrogate is not a character, and a font naming one is damaged.
    try testing.expect(unicodeForName("uD800") == null);
}

test "a name that is really a glyph number is read as one" {
    // Emitted by subsetters that drop the post table, and a reader that does
    // not understand them draws nothing for an intact font.
    try testing.expectEqual(@as(u16, 42), glyphNumberForName("g42").?);
    try testing.expectEqual(@as(u16, 7), glyphNumberForName("glyph7").?);
    try testing.expectEqual(@as(u16, 300), glyphNumberForName("index300").?);
    try testing.expectEqual(@as(u16, 1), glyphNumberForName("cid1").?);
    // Real names that merely start with the same letters must not be caught.
    try testing.expect(glyphNumberForName("g") == null);
    try testing.expect(glyphNumberForName("germandbls") == null);
    try testing.expect(glyphNumberForName("grave") == null);
}

test "every name a standard encoding can produce reaches a code point" {
    // The invariant that makes the name table exactly as large as it needs to
    // be: if an encoding can name it, this file can resolve it. A gap here is
    // a character that renders as nothing on a page that is otherwise fine.
    var missing: usize = 0;
    for ([_]Kind{ .standard, .win_ansi, .mac_roman }) |k| {
        const t = k.table().?;
        for (t, 0..) |maybe, code| {
            const name = maybe orelse continue;
            if (unicodeForName(name) == null) {
                std.debug.print("{s} code {d} names '{s}', which resolves to nothing\n", .{
                    @tagName(k), code, name,
                });
                missing += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}
