//! Binding a display list's fonts to real glyph outlines.
//!
//! This is where Gjöll and Týr meet, and it is deliberately the only place.
//! The interpreter records a `FontId` and a character code and stops there;
//! Týr reads font programs and knows nothing about PDF; Gleipnir draws paths
//! and knows about neither. Resolving a code to an outline needs all three, so
//! it happens here, above all of them, behind
//! `gleipnir.replay.GlyphSource`.
//!
//! ## The chain
//!
//! For a **composite** font (`/Type0`) the interpreter has already run the
//! CMap, so the code recorded in the display list *is* the CID. From there:
//!
//!     CIDFontType2  ->  /CIDToGIDMap, either /Identity or a stream of u16
//!     CIDFontType0  ->  the CFF charset, which is CID-keyed
//!
//! For a **simple** font the code is one byte and has to become a glyph name
//! first (§9.6.6):
//!
//!     /Differences  ->  /BaseEncoding  ->  Standard, or the font's own
//!
//! and then that name has to become a glyph, which depends on the program:
//! CFF looks it up in its charset, TrueType in `post`, and a subsetted
//! TrueType usually has neither -- so the name becomes a Unicode code point
//! and goes through `cmap`. All four routes are tried in turn, because a
//! renderer that takes only the first one draws a large fraction of real
//! files as blanks.
//!
//! ## Standard 14
//!
//! A font with no embedded program at all -- `/BaseFont /Helvetica` and
//! nothing else -- has no outlines anywhere in the file, and there is no
//! system font loader in this project yet. Those are counted as missing
//! rather than substituted: a wrong typeface at the right widths looks like a
//! rendering bug, and silence is easier to explain.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const gleipnir = fenrir.gleipnir;
const tyr = fenrir.tyr;

const DisplayList = fenrir.gelgja.DisplayList;
const Document = fenrir.Document;
const Object = fenrir.Object;
const replay = gleipnir.replay;

const Dict = fenrir.Dict;
const GlyphOutline = replay.GlyphOutline;

/// One font of a display list, resolved.
const Binding = struct {
    face: ?tyr.Face = null,
    composite: bool = false,
    /// `/Subtype /CIDFontType0`: the descendant is a CFF whose charset maps
    /// CIDs, so a CID does not index glyphs directly.
    cid_keyed_cff: bool = false,
    /// `/CIDToGIDMap` as a stream: two big-endian bytes per CID. Empty means
    /// `/Identity`, where the glyph index is the CID. Borrowed from the
    /// document, which decoded it; never freed here.
    cid_to_gid: []const u8 = &.{},
    /// `/Differences`, 256 entries, empty where the array said nothing.
    differences: [][]u8 = &.{},
    base: tyr.encoding.Kind = .standard,
    /// The descriptor's symbolic flag. A hint, not a rule -- see `glyphFor`.
    symbolic: bool = false,
    /// True when the program came off this machine rather than out of the
    /// document. The shapes are a stand-in and the widths are still the PDF's.
    substituted: bool = false,

    fn deinit(b: *Binding, gpa: Allocator) void {
        if (b.face) |*f| f.deinit(gpa);
        for (b.differences) |d| gpa.free(d);
        gpa.free(b.differences);
        // Not `cid_to_gid`: it is `Document.streamData`'s output, which lives
        // in the document's arena -- the same trap `Program.owned` is for.
        // Freeing it is harmless under an arena and an invalid free under
        // anything else, which is how the reader crashed on the first page
        // with a composite font.
    }
};

/// A font program and who is responsible for it. See `Cache.programs`.
const Program = struct { bytes: []u8, owned: bool };

/// Every font of one document, parsed once and kept.
///
/// A `Fonts` is built from a display list and a display list is one page, but
/// a *font* is not a page's: a book sets its body text in one face, and a
/// reader that binds per page parses the same `glyf` or CFF program again for
/// every page it shows. On a typeset paper that was nine milliseconds a page
/// -- eleven per cent of the whole render -- spent producing a face byte for
/// byte identical to the one the previous page threw away.
///
/// Keyed on the font dictionary's object number, which is what makes two
/// pages' `/F1` the same font rather than two fonts with the same name. A
/// cache belongs to exactly one document, because that is what the keys mean.
///
/// This is not the outline cache in the graveyard. That one memoised the
/// *result* of decoding a glyph, which was one per cent of the run and lost.
/// This memoises opening the font program, which is a different quantity --
/// see `OPTIMIZING.md`.
pub const Cache = struct {
    gpa: Allocator,
    by_object: std.AutoHashMapUnmanaged(u32, *Binding) = .empty,
    /// Bindings for fonts with no object number of their own. There is
    /// nothing to key those on, so each is built again and simply owned here
    /// until the cache goes.
    loose: std.ArrayList(*Binding) = .empty,
    /// Font programs, kept alive because a `Face` borrows its bytes.
    ///
    /// Two owners, and the difference matters. A program read out of the
    /// document comes from `Document.streamData`, which decodes into the
    /// document's *arena* -- so it lives as long as the document and must not
    /// be freed here. A substitute read off the machine was allocated with
    /// `gpa` and must be.
    ///
    /// Freeing both was harmless for as long as every command ran on one
    /// process-wide arena, where `free` does nothing. `fenrir read` has a real
    /// allocator now, and the same line is an invalid free on the first page
    /// with an embedded font in it.
    programs: std.ArrayList(Program) = .empty,

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.by_object.valueIterator();
        while (it.next()) |slot| {
            slot.*.deinit(c.gpa);
            c.gpa.destroy(slot.*);
        }
        c.by_object.deinit(c.gpa);
        for (c.loose.items) |b| {
            b.deinit(c.gpa);
            c.gpa.destroy(b);
        }
        c.loose.deinit(c.gpa);
        for (c.programs.items) |p| {
            if (p.owned) c.gpa.free(p.bytes);
        }
        c.programs.deinit(c.gpa);
        c.* = undefined;
    }
};

/// Resolves every font a display list mentions, through a document-wide cache.
pub const Fonts = struct {
    /// For what lives exactly as long as this does: the binding table and the
    /// outline scratch. Everything a `Binding` owns -- the face, its program,
    /// its `/Differences` -- is allocated from `cache.gpa` instead, because
    /// the cache outlives this and is what will free them. Mixing the two is
    /// a cross-allocator free, which is the bug the reader's real heap turns
    /// from a silent no-op into a crash.
    gpa: Allocator,
    doc: *Document,
    /// Needed only to read a substitute font off this machine. Without it, a
    /// document that embeds nothing simply has no glyphs.
    io: ?std.Io = null,
    /// One per entry in the display list's font table, pointing into `cache`.
    /// Borrowed: this owns the slice and not what it points at.
    bindings: []*Binding,
    /// Where the bindings live. Outlives this; see `Cache`.
    cache: *Cache,
    /// The outline handed back by the last `lookup`. One buffer, reused: the
    /// interface promises the slices only until the next call, which is
    /// exactly what a page-at-a-time replay needs.
    scratch: tyr.Outline = .{},

    /// Glyphs whose face could not produce an outline, so the caller can say
    /// how much of the page is missing.
    missing: u32 = 0,
    /// The name of the font being bound, for a substitution lookup.
    base_font: []const u8 = "",
    /// How many fonts came off this machine rather than out of the document.
    substituted: u32 = 0,

    pub fn init(
        gpa: Allocator,
        doc: *Document,
        list: DisplayList,
        io: ?std.Io,
        cache: *Cache,
    ) Allocator.Error!Fonts {
        const bindings = try gpa.alloc(*Binding, list.fonts.len);
        errdefer gpa.free(bindings);

        var f: Fonts = .{
            .gpa = gpa,
            .doc = doc,
            .io = io,
            .bindings = bindings,
            .cache = cache,
        };
        for (list.fonts, 0..) |info, i| {
            f.base_font = list.stringOf(info.base_font);
            f.bindings[i] = try f.resolve(info);
            // Counted from the binding rather than in `bind`, because a
            // binding that came out of the cache did its substituting on some
            // earlier page and would otherwise go unreported here.
            if (f.bindings[i].substituted) f.substituted += 1;
        }
        return f;
    }

    /// The binding for one font of the display list: out of the cache if this
    /// document has bound it before, freshly built and put there if not.
    fn resolve(f: *Fonts, info: DisplayList.FontInfo) Allocator.Error!*Binding {
        const c = f.cache;
        const cacheable = info.object != 0;
        if (cacheable) {
            if (c.by_object.get(info.object)) |b| return b;
        }

        const b = try c.gpa.create(Binding);
        b.* = .{};
        // A font that will not load is a blank in the page, not a failed
        // render: a document with one broken font and forty good ones should
        // show the forty. The empty binding is cached too, so the next page
        // does not try the same broken font again.
        f.bind(b, info) catch {};

        if (cacheable) {
            c.by_object.put(c.gpa, info.object, b) catch {
                // Out of memory for the index only. The binding still works;
                // it is just kept in the list that is never looked up, and
                // the next page rebuilds it.
                c.loose.append(c.gpa, b) catch {
                    b.deinit(c.gpa);
                    c.gpa.destroy(b);
                    return error.OutOfMemory;
                };
            };
        } else {
            try c.loose.append(c.gpa, b);
        }
        return b;
    }

    pub fn deinit(f: *Fonts) void {
        // Not the bindings themselves: the cache owns those, and freeing one
        // here would leave every later page holding a dangling face.
        f.gpa.free(f.bindings);
        f.scratch.deinit(f.gpa);
    }

    /// How many of the display list's fonts have a usable program.
    pub fn loaded(f: Fonts) u32 {
        var n: u32 = 0;
        for (f.bindings) |b| {
            if (b.face != null) n += 1;
        }
        return n;
    }

    pub fn source(f: *Fonts) replay.GlyphSource {
        return .{ .ptr = f, .lookup = lookup };
    }

    fn lookup(ptr: *anyopaque, font: DisplayList.FontId, glyph: DisplayList.Glyph) ?GlyphOutline {
        const f: *Fonts = @ptrCast(@alignCast(ptr));
        if (font >= f.bindings.len) return null;
        const b = f.bindings[font];
        const face = b.face orelse return null;

        const gid = f.glyphFor(b, face, glyph.code) orelse return null;

        face.outline(f.gpa, gid, &f.scratch) catch return null;
        return .{
            .verbs = f.scratch.verbs.items,
            .points = f.scratch.points.items,
            .units_per_em = f.scratch.units_per_em,
        };
    }

    /// The whole encoding chain, in the order that renders the most files.
    fn glyphFor(f: *Fonts, b: *const Binding, face: tyr.Face, code: u32) ?tyr.GlyphIndex {
        _ = f;
        if (b.composite) {
            // The code recorded in the display list is already the CID: the
            // interpreter ran the CMap when it built the run.
            if (b.cid_keyed_cff) {
                if (tyr.cff.glyphForCid(face, @truncate(code))) |g| return g;
            }
            if (b.cid_to_gid.len >= 2) {
                const at = @as(usize, code) * 2;
                if (at + 2 > b.cid_to_gid.len) return null;
                return std.mem.readInt(u16, b.cid_to_gid[at..][0..2], .big);
            }
            return @truncate(code);
        }

        if (code > 0xff) return null;
        const byte: u8 = @truncate(code);

        // A symbolic font is supposed to use its own built-in encoding, and
        // for a subsetted TrueType that is the only thing that works: the
        // codes are arbitrary and the names, if any, are invented. Tried first
        // for symbolic fonts and last for the rest.
        if (b.symbolic) {
            if (face.glyphForCodepoint(byte)) |g| {
                if (g != 0) return g;
            }
            if (tyr.cff.glyphForBuiltinCode(face, byte)) |g| {
                if (g != 0) return g;
            }
            if (tyr.type1.glyphForBuiltinCode(face, byte)) |g| {
                if (g != 0) return g;
            }
        }

        const name: ?[]const u8 = blk: {
            if (byte < b.differences.len and b.differences[byte].len > 0) {
                break :blk b.differences[byte];
            }
            break :blk tyr.encoding.nameFor(b.base, byte);
        };

        if (name) |n| {
            // A name the font itself knows: CFF's charset, or TrueType's
            // `post`. Exact when it works.
            if (face.glyphForName(n)) |g| {
                if (g != 0) return g;
            }
            // `g42`, `index7`: a name that is really a glyph number, which is
            // what a subsetter that dropped its name table emits.
            if (tyr.encoding.glyphNumberForName(n)) |g| {
                if (g < face.info.num_glyphs) return g;
            }
            // The usual route for a subsetted TrueType: turn the name into a
            // code point and ask the `cmap`.
            if (tyr.encoding.unicodeForName(n)) |cp| {
                if (face.glyphForCodepoint(cp)) |g| {
                    if (g != 0) return g;
                }
            }
        }

        if (!b.symbolic) {
            if (face.glyphForCodepoint(byte)) |g| {
                if (g != 0) return g;
            }
            if (tyr.cff.glyphForBuiltinCode(face, byte)) |g| {
                if (g != 0) return g;
            }
            if (tyr.type1.glyphForBuiltinCode(face, byte)) |g| {
                if (g != 0) return g;
            }
        }
        return null;
    }

    // -- building a binding --------------------------------------------------

    fn bind(f: *Fonts, b: *Binding, info: DisplayList.FontInfo) !void {
        if (info.object == 0) return;
        const obj = try f.doc.fetch(.{ .num = info.object, .gen = 0 });
        const dict = obj.asDict() orelse return;

        b.composite = info.composite;

        // For a Type 0 font, everything about the program lives on the
        // descendant, not on the font itself.
        var program_dict = dict;
        if (b.composite) {
            const desc = try f.doc.get(dict, "DescendantFonts") orelse return;
            const resolved = try f.doc.resolve(desc);
            const arr = resolved.asArray() orelse return;
            if (arr.len == 0) return;
            const d0 = try f.doc.resolve(arr[0]);
            program_dict = d0.asDict() orelse return;

            if (try f.doc.get(program_dict, "Subtype")) |st| {
                if (st.asName()) |n| b.cid_keyed_cff = std.mem.eql(u8, n, "CIDFontType0");
            }
            if (try f.doc.get(program_dict, "CIDToGIDMap")) |m| {
                const r = try f.doc.resolve(m);
                if (r.asStream()) |s| {
                    const data = try f.doc.streamData(s);
                    b.cid_to_gid = data.data;
                }
                // A name is `/Identity`, which is what the empty map means.
            }
        } else {
            try f.readEncoding(b, dict);
        }

        const descriptor = blk: {
            const fd = try f.doc.get(program_dict, "FontDescriptor") orelse break :blk null;
            const r = try f.doc.resolve(fd);
            break :blk r.asDict();
        };
        var flags: i64 = 0;
        if (descriptor) |fd| {
            if (try f.doc.get(fd, "Flags")) |fl| {
                if (fl.asInt()) |v| {
                    flags = v;
                    b.symbolic = (v & 4) != 0 and (v & 32) == 0;
                }
            }
        }

        // The document's own program first. Only when there is none -- which
        // is legal, and is what `/BaseFont /Helvetica` with no descriptor
        // means -- does a face off this machine stand in.
        const entry: Program = blk: {
            if (descriptor) |fd| {
                // The document's arena owns this one.
                if (try f.readProgram(fd)) |p| break :blk .{ .bytes = p, .owned = false };
            }
            const sub = readSubstitute(f, f.base_font, flags) orelse return;
            b.substituted = true;
            // A stand-in is never the symbolic font the descriptor described,
            // so its own cmap must not be consulted with raw codes: the name
            // chain is the only thing that means anything now.
            b.symbolic = false;
            break :blk .{ .bytes = sub, .owned = true };
        };
        try f.cache.programs.append(f.cache.gpa, entry);
        const program = entry.bytes;

        b.face = tyr.open(f.cache.gpa, program, .{}) catch null;
        // The fallback backend opens anything and draws boxes. A box is worse
        // than a gap here: it is not what the document says and it looks like
        // a rendering bug rather than a missing feature.
        if (b.face) |face| {
            if (std.mem.eql(u8, face.backend, "fallback")) {
                var x = face;
                x.deinit(f.cache.gpa);
                b.face = null;
            }
        }
    }

    /// `/FontFile`, `/FontFile2` or `/FontFile3`, decoded into the document.s
    /// arena, which owns it and outlives this.
    fn readProgram(f: *Fonts, fd: Dict) !?[]u8 {
        for ([_][]const u8{ "FontFile2", "FontFile3", "FontFile" }) |key| {
            const v = try f.doc.get(fd, key) orelse continue;
            const r = try f.doc.resolve(v);
            const stream = r.asStream() orelse continue;
            const data = f.doc.streamData(stream) catch continue;
            // Not freed: the document.s arena will, when the document goes.
            if (data.data.len == 0) continue;
            return data.data;
        }
        return null;
    }

    /// `/Encoding`: a name, or a dictionary with a base and a difference list.
    fn readEncoding(f: *Fonts, b: *Binding, dict: Dict) !void {
        const enc = try f.doc.get(dict, "Encoding") orelse return;
        const r = try f.doc.resolve(enc);

        if (r.asName()) |n| {
            b.base = tyr.encoding.Kind.fromName(n) orelse .standard;
            return;
        }
        const ed = r.asDict() orelse return;

        if (try f.doc.get(ed, "BaseEncoding")) |be| {
            if (be.asName()) |n| b.base = tyr.encoding.Kind.fromName(n) orelse .standard;
        }

        const diff = try f.doc.get(ed, "Differences") orelse return;
        const dr = try f.doc.resolve(diff);
        const arr = dr.asArray() orelse return;

        var names = try f.cache.gpa.alloc([]u8, 256);
        errdefer f.cache.gpa.free(names);
        @memset(names, &.{});

        // The array alternates a starting code with a run of names, and a new
        // number restarts the run wherever it says. `[ 1 /a /b 5 /c ]` names
        // codes 1, 2 and 5.
        var at: u32 = 0;
        for (arr) |item| {
            const it = try f.doc.resolve(item);
            if (it.asInt()) |v| {
                at = if (v >= 0 and v < 256) @intCast(v) else 256;
                continue;
            }
            if (it.asName()) |n| {
                if (at < 256) {
                    names[at] = f.cache.gpa.dupe(u8, n) catch continue;
                    at += 1;
                }
            }
        }
        b.differences = names;
    }
};

/// One line per font: which backend opened it, how many glyphs it has, and
/// how the encoding chain is set up.
///
/// The question "why is this page blank" almost always has its answer here,
/// and it is not visible from anywhere else: a font can fail to load, load
/// with the wrong backend, or load fine and have every code miss.
pub fn describe(f: *Fonts, list: DisplayList, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (f.bindings, 0..) |b, i| {
        const info = list.fonts[i];
        try w.print("font {d}  {s:<24}", .{ i, list.stringOf(info.base_font) });
        if (b.face) |face| {
            try w.print(" {s:<9} {d:>5} glyphs  {d} upem", .{
                face.backend, face.info.num_glyphs, face.info.units_per_em,
            });
            if (b.composite) try w.writeAll("  composite");
            if (b.cid_keyed_cff) try w.writeAll("  cid-keyed");
            if (b.cid_to_gid.len > 0) try w.print("  cidtogid {d}", .{b.cid_to_gid.len / 2});
            if (b.symbolic) try w.writeAll("  symbolic");
            if (b.differences.len > 0) try w.writeAll("  differences");
            if (!b.composite) try w.print("  {s}", .{@tagName(b.base)});
        } else {
            try w.writeAll(" no usable font program");
        }
        try w.writeByte('\n');
    }
}

// -- substituting a font the document did not embed --------------------------

/// A PDF may name a font and embed nothing, on the theory that the reader has
/// it: `/BaseFont /Helvetica` with no `/FontDescriptor` at all is legal and
/// common, and so is `/BaseFont /Arial` from a Word export. There is no
/// outline anywhere in the file for those, so either something on this machine
/// stands in or the page comes out blank.
///
/// What this does is deliberately crude. It classifies the name into one of
/// four families and a weight and a slope, and looks for a file with a
/// matching name in the platform's font directory. It does not read font
/// metadata, does not consult a fontconfig, and does not try to match metrics
/// -- a substituted face has the wrong widths, so the *positions* still come
/// from the PDF's own `/Widths` and only the shapes are borrowed.
///
/// The result is legible and not typographically faithful, which is the right
/// trade: the alternative on those documents is a blank page.
const Substitute = struct {
    /// Roughly what the name is asking for. Everything unrecognised becomes
    /// `sans`, which is what a reader wants when it cannot tell.
    const Family = enum { serif, sans, mono, symbol };

    family: Family = .sans,
    bold: bool = false,
    italic: bool = false,

    fn classify(base_font: []const u8, flags: i64) Substitute {
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
    fn candidates(s: Substitute) []const []const u8 {
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
const font_dirs = switch (@import("builtin").os.tag) {
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

/// Reads a stand-in font program off this machine. The caller owns the bytes.
fn readSubstitute(f: *Fonts, base_font: []const u8, flags: i64) ?[]u8 {
    const io = f.io orelse return null;
    const s = Substitute.classify(base_font, flags);

    for (s.candidates()) |name| {
        for (font_dirs) |dir| {
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, f.cache.gpa, .limited(32 << 20)) catch continue;
            return bytes;
        }
    }
    return null;
}
