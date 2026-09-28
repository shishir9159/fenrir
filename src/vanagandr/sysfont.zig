//! Finding a font on the machine this is running on.
//!
//! Two callers want the same three things -- a list of names worth trying, a
//! list of directories to try them in, and the open that gives up quietly --
//! and they want them for different reasons. `glyphs.zig` needs a stand-in
//! for a font a document named and did not embed. The reader needs a face to
//! draw its own interface with, because Þviti measures and lays out text and
//! has nowhere to get an outline from.
//!
//! It lives in Vánagandr rather than in Týr because **the library layer does
//! not open files and the CLI does**. Týr reads font *programs*, as bytes
//! handed to it; where those bytes came from is not its business, and giving
//! it a filesystem would give it a platform. Galdr is split the same way and
//! says so in `Host.zig`.
//!
//! Nothing here reads font metadata. It matches on file names, which is
//! crude and is the right kind of crude: the alternative is a font
//! configuration library, and the whole project is an argument against
//! reaching for one.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A cap on what will be read as a font. A CJK face is twenty megabytes and
/// a font nobody would ship is more; past this it is not a font, it is a
/// file that happens to sit in a font directory.
const max_bytes = 32 << 20;

pub const Substitute = struct {
    /// Roughly what the name is asking for. Everything unrecognised becomes
    /// `sans`, which is what a reader wants when it cannot tell.
    pub const Family = enum { serif, sans, mono, symbol };

    family: Family = .sans,
    bold: bool = false,
    italic: bool = false,

    pub fn classify(base_font: []const u8, flags: i64) Substitute {
        // `ABCDEF+Helvetica-Bold` -- the subset tag is six letters and a plus,
        // and carries no information about the typeface.
        var name = base_font;
        if (std.mem.indexOfScalar(u8, name, '+')) |plus| {
            if (plus == 6) name = name[plus + 1 ..];
        }

        var s: Substitute = .{};
        // Bit 1 is FixedPitch, bit 2 Serif, bit 7 Italic (numbered from 1).
        if (flags & 1 != 0) s.family = .mono;
        if (flags & 2 != 0) s.family = .serif;
        if (flags & 64 != 0) s.italic = true;

        if (containsAny(name, &.{ "Courier", "Mono", "Consol", "Typewriter", "CMTT" })) {
            s.family = .mono;
        } else if (containsAny(name, &.{ "Times", "Serif", "Georgia", "Book", "Roman", "Garamond", "Minion", "CMR", "Nimbus" })) {
            s.family = .serif;
        } else if (containsAny(name, &.{ "Helvetica", "Arial", "Sans", "Verdana", "Calibri", "Segoe", "Tahoma" })) {
            s.family = .sans;
        }
        if (containsAny(name, &.{ "Symbol", "Dingbat", "Wingding" })) s.family = .symbol;

        if (containsAny(name, &.{ "Bold", "Black", "Heavy", "Semibold", "-BX", "CMBX" })) s.bold = true;
        if (containsAny(name, &.{ "Italic", "Oblique", "-IT", "CMTI", "CMMI" })) s.italic = true;

        return s;
    }

    fn containsAny(hay: []const u8, needles: []const []const u8) bool {
        for (needles) |n| {
            if (std.mem.indexOf(u8, hay, n) != null) return true;
        }
        return false;
    }

    /// File names to try, best first. Windows names come first because that is
    /// where this runs today; the rest cost one failed open each.
    pub fn candidates(s: Substitute) []const []const u8 {
        return switch (s.family) {
            .symbol => &.{ "symbol.ttf", "seguisym.ttf", "DejaVuSans.ttf" },
            .mono => if (s.bold and s.italic)
                &.{ "courbi.ttf", "DejaVuSansMono-BoldOblique.ttf", "LiberationMono-BoldItalic.ttf" }
            else if (s.bold)
                &.{ "courbd.ttf", "DejaVuSansMono-Bold.ttf", "LiberationMono-Bold.ttf" }
            else if (s.italic)
                &.{ "couri.ttf", "DejaVuSansMono-Oblique.ttf", "LiberationMono-Italic.ttf" }
            else
                &.{ "cour.ttf", "DejaVuSansMono.ttf", "LiberationMono-Regular.ttf" },
            .serif => if (s.bold and s.italic)
                &.{ "timesbi.ttf", "DejaVuSerif-BoldItalic.ttf", "LiberationSerif-BoldItalic.ttf" }
            else if (s.bold)
                &.{ "timesbd.ttf", "DejaVuSerif-Bold.ttf", "LiberationSerif-Bold.ttf" }
            else if (s.italic)
                &.{ "timesi.ttf", "DejaVuSerif-Italic.ttf", "LiberationSerif-Italic.ttf" }
            else
                &.{ "times.ttf", "DejaVuSerif.ttf", "LiberationSerif-Regular.ttf" },
            .sans => if (s.bold and s.italic)
                &.{ "arialbi.ttf", "DejaVuSans-BoldOblique.ttf", "LiberationSans-BoldItalic.ttf" }
            else if (s.bold)
                &.{ "arialbd.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf" }
            else if (s.italic)
                &.{ "ariali.ttf", "DejaVuSans-Oblique.ttf", "LiberationSans-Italic.ttf" }
            else
                &.{ "arial.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf" },
        };
    }
};

/// Where a platform keeps its fonts. Searched in order.
pub const dirs = switch (@import("builtin").os.tag) {
    .windows => [_][]const u8{
        "C:/Windows/Fonts",
        "C:/WINDOWS/Fonts",
    },
    .macos => [_][]const u8{
        "/System/Library/Fonts",
        "/Library/Fonts",
    },
    else => [_][]const u8{
        "/usr/share/fonts/truetype/dejavu",
        "/usr/share/fonts/truetype/liberation",
        "/usr/share/fonts/TTF",
        "/usr/share/fonts",
    },
};

/// The interface's own face: a sans face at a normal weight, whatever this
/// machine calls that.
///
/// The platform's *user interface* font comes first and is not in
/// `Substitute`'s lists, because the two questions differ. A document that
/// says `/Helvetica` is asking for Helvetica and Arial is the honest
/// stand-in; a toolbar is asking for "whatever this system draws toolbars
/// in", which on Windows is Segoe UI and on macOS is San Francisco. Falling
/// through to the sans list means a machine with neither still gets a face.
pub fn interfaceNames() []const []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => &.{ "segoeui.ttf", "tahoma.ttf", "arial.ttf", "DejaVuSans.ttf" },
        .macos => &.{ "SFNS.ttf", "SFNSText.ttf", "Helvetica.ttc", "Arial.ttf" },
        else => &.{
            "DejaVuSans.ttf",
            "LiberationSans-Regular.ttf",
            "NotoSans-Regular.ttf",
            "FreeSans.ttf",
        },
    };
}

/// The first of `names` that exists under any of `dirs`, read whole. The
/// caller owns the bytes.
///
/// Every failure is a `continue`: a directory that is not there, a file that
/// is not there, a file too large to be a font. There is no error to report
/// because there is nothing the caller could do about it that this has not
/// already done, and the one thing a caller must be able to tell -- whether
/// it got a font -- is the null.
pub fn read(io: std.Io, gpa: Allocator, names: []const []const u8) ?[]u8 {
    for (names) |name| {
        for (dirs) |dir| {
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch continue;
            return bytes;
        }
    }
    return null;
}

/// A stand-in for a font a document named and did not embed. `flags` is the
/// descriptor's `/Flags`.
pub fn forBaseFont(io: ?std.Io, gpa: Allocator, base_font: []const u8, flags: i64) ?[]u8 {
    const have = io orelse return null;
    return read(have, gpa, Substitute.classify(base_font, flags).candidates());
}

/// A face to draw the interface with, or null on a machine with none -- in
/// which case Týr's fallback draws every character as a box, which is
/// legible enough to lay out against and unmistakable enough to report.
pub fn forInterface(io: ?std.Io, gpa: Allocator) ?[]u8 {
    const have = io orelse return null;
    return read(have, gpa, interfaceNames());
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a subset tag is not part of the name" {
    // `ABCDEF+Helvetica-Bold`: six letters and a plus, carrying nothing.
    const s = Substitute.classify("ABCDEF+Helvetica-Bold", 0);
    try testing.expectEqual(Substitute.Family.sans, s.family);
    try testing.expect(s.bold);
    try testing.expect(!s.italic);
}

test "the descriptor flags classify a font the name does not" {
    // Bit 1 is FixedPitch, bit 2 Serif, bit 7 Italic, numbered from 1.
    try testing.expectEqual(Substitute.Family.mono, Substitute.classify("Unknown", 1).family);
    try testing.expectEqual(Substitute.Family.serif, Substitute.classify("Unknown", 2).family);
    try testing.expect(Substitute.classify("Unknown", 64).italic);
    // The name outranks the flags, because a producer that sets neither is
    // commoner than one that sets them wrongly.
    try testing.expectEqual(Substitute.Family.serif, Substitute.classify("Times-Roman", 1).family);
}

test "every classification offers somewhere to look" {
    const names = [_][]const u8{ "Courier", "Times", "Helvetica", "Symbol", "Unknown" };
    for (names) |n| {
        for ([_]i64{ 0, 1, 2, 64, 66 }) |flags| {
            try testing.expect(Substitute.classify(n, flags).candidates().len > 0);
        }
    }
    try testing.expect(interfaceNames().len > 0);
    try testing.expect(dirs.len > 0);
}

test "an interface face is asked for before a document's stand-in" {
    // Not the same question, and the lists say so: the first name the
    // interface tries is not the first name a `/Helvetica` would.
    const sans: Substitute = .{ .family = .sans };
    try testing.expect(!std.mem.eql(u8, interfaceNames()[0], sans.candidates()[0]));
}

test "a font is not looked for without an Io to look with" {
    try testing.expect(forInterface(null, testing.allocator) == null);
    try testing.expect(forBaseFont(null, testing.allocator, "Helvetica", 0) == null);
}
