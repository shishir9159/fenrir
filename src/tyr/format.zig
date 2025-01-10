//! Sniffing a font program, so a backend can be chosen before one is loaded.
//!
//! This lives in Týr's core rather than in a backend because backend selection
//! has to happen *first*: asking every compiled-in backend to try opening the
//! bytes and keeping whichever succeeds means the choice depends on error
//! messages, and a backend that half-opens a file it cannot really render is
//! then indistinguishable from one that succeeded.
//!
//! PDF names the format in the font descriptor -- `/FontFile` is Type 1,
//! `/FontFile2` is TrueType, `/FontFile3` carries a `/Subtype` -- but producers
//! get this wrong often enough that the bytes are the more reliable witness.
//! Files that declare `/FontFile2` and contain bare CFF are not rare.

const std = @import("std");

pub const Format = enum {
    /// `glyf`/`loca` outlines: quadratic B-splines. `/FontFile2`.
    truetype,
    /// An OpenType wrapper (`OTTO`) whose outlines are a CFF table: cubics.
    opentype_cff,
    /// Bare CFF, no SFNT wrapper. `/FontFile3` with `/Type1C` or
    /// `/CIDFontType0C` -- much the commonest subsetted-font encoding in PDF.
    cff,
    /// PostScript Type 1, either PFB (segmented, binary) or PFA (hex).
    /// `/FontFile`, with `/Length1` `/Length2` `/Length3` splitting the parts.
    type1,
    /// A TrueType collection, `ttcf`. Legal in PDF only via `/FontFile3`
    /// `/OpenType`, and needs a face index.
    collection,
    /// WOFF or WOFF2. Not legal in a PDF, but web-derived producers emit it.
    woff,
    unknown,

    /// The capability a backend must advertise to open this format.
    pub fn requirement(f: Format) Requirement {
        return switch (f) {
            .truetype, .collection => .truetype,
            .opentype_cff, .cff => .cff,
            .type1 => .type1,
            .woff, .unknown => .none,
        };
    }

    pub fn label(f: Format) []const u8 {
        return @tagName(f);
    }
};

pub const Requirement = enum { truetype, cff, type1, none };

/// Identifies a font program from its leading bytes.
pub fn sniff(bytes: []const u8) Format {
    if (bytes.len < 4) return .unknown;
    const tag = bytes[0..4].*;

    if (std.mem.eql(u8, &tag, "OTTO")) return .opentype_cff;
    if (std.mem.eql(u8, &tag, "ttcf")) return .collection;
    if (std.mem.eql(u8, &tag, "true")) return .truetype;
    // Apple's other legacy SFNT tag, seen on old Mac-authored PDFs.
    if (std.mem.eql(u8, &tag, "typ1")) return .type1;
    if (std.mem.eql(u8, &tag, "wOFF") or std.mem.eql(u8, &tag, "wOF2")) return .woff;
    if (std.mem.readInt(u32, &tag, .big) == 0x0001_0000) return .truetype;

    // PFB: a segment header of 0x80, then a type byte of 1 (ASCII), 2 (binary)
    // or 3 (EOF), then a little-endian length.
    if (bytes[0] == 0x80 and bytes[1] >= 1 and bytes[1] <= 3) return .type1;
    // PFA and anything else that opens with a PostScript comment.
    if (std.mem.startsWith(u8, bytes, "%!")) return .type1;

    // Bare CFF has no magic, only a plausible header: major 1, minor 0, a
    // header size of at least 4, and an offset size in 1..4. Checked last so a
    // real magic always wins.
    if (bytes[0] == 1 and bytes[1] == 0 and bytes[2] >= 4 and
        bytes[3] >= 1 and bytes[3] <= 4) return .cff;

    return .unknown;
}

/// What the font descriptor claimed, for the cases where the bytes are mute.
/// `subtype` is the `/Subtype` of a `/FontFile3` stream, empty otherwise.
pub fn fromDescriptor(key: []const u8, subtype: []const u8) Format {
    if (std.mem.eql(u8, key, "FontFile")) return .type1;
    if (std.mem.eql(u8, key, "FontFile2")) return .truetype;
    if (std.mem.eql(u8, key, "FontFile3")) {
        if (std.mem.eql(u8, subtype, "Type1C")) return .cff;
        if (std.mem.eql(u8, subtype, "CIDFontType0C")) return .cff;
        if (std.mem.eql(u8, subtype, "OpenType")) return .truetype;
    }
    return .unknown;
}

/// The bytes win when they say anything at all; the descriptor is the fallback.
/// Producers mislabel far more often than they corrupt the first four bytes.
pub fn resolve(bytes: []const u8, declared: Format) Format {
    const sniffed = sniff(bytes);
    return if (sniffed == .unknown) declared else sniffed;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "sniffs the SFNT family" {
    try testing.expectEqual(Format.truetype, sniff(&.{ 0, 1, 0, 0, 0, 9 }));
    try testing.expectEqual(Format.truetype, sniff("true\x00\x09"));
    try testing.expectEqual(Format.opentype_cff, sniff("OTTO\x00\x09"));
    try testing.expectEqual(Format.collection, sniff("ttcf\x00\x01"));
    try testing.expectEqual(Format.woff, sniff("wOFF\x00\x01"));
}

test "sniffs PostScript and bare CFF" {
    try testing.expectEqual(Format.type1, sniff("%!PS-AdobeFont-1.0"));
    try testing.expectEqual(Format.type1, sniff(&.{ 0x80, 0x01, 0x40, 0x00 }));
    // major 1, minor 0, hdrSize 4, offSize 2.
    try testing.expectEqual(Format.cff, sniff(&.{ 1, 0, 4, 2, 0, 0 }));
}

test "an SFNT version never reads as CFF" {
    // 0x00010000 also has a 0 and a 1 in it; ordering of the checks decides.
    try testing.expectEqual(Format.truetype, sniff(&.{ 0, 1, 0, 0 }));
}

test "short and empty input is unknown, not a crash" {
    try testing.expectEqual(Format.unknown, sniff(""));
    try testing.expectEqual(Format.unknown, sniff("OT"));
    try testing.expectEqual(Format.unknown, sniff(&.{ 0xff, 0xfe, 0xfd, 0xfc }));
}

test "the bytes override a mislabelling descriptor" {
    // A /FontFile2 stream that actually holds bare CFF: common enough that
    // trusting the dictionary here would misroute real files.
    const declared = fromDescriptor("FontFile2", "");
    try testing.expectEqual(Format.truetype, declared);
    try testing.expectEqual(Format.cff, resolve(&.{ 1, 0, 4, 2 }, declared));
}

test "the descriptor is used when the bytes say nothing" {
    try testing.expectEqual(Format.cff, resolve(&.{ 0xde, 0xad, 0xbe, 0xef }, .cff));
}

test "each format maps to the capability a backend must have" {
    try testing.expectEqual(Requirement.truetype, Format.truetype.requirement());
    try testing.expectEqual(Requirement.cff, Format.opentype_cff.requirement());
    try testing.expectEqual(Requirement.cff, Format.cff.requirement());
    try testing.expectEqual(Requirement.type1, Format.type1.requirement());
}
