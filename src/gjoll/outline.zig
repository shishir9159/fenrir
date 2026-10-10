//! The document outline -- what a producer calls bookmarks (ISO 32000-2
//! §12.3.3).
//!
//! Sits beside `pages.zig` and does the same kind of job: walk a structure the
//! catalog points at, be suspicious of every field in it, and hand back a flat
//! array the layers above can use without knowing any of this.
//!
//! ## Flat, with a depth, and not a tree
//!
//! The outline *is* a tree, and it is returned as `[]Entry` with a `depth` on
//! each one. That is what a list widget wants -- `thviti/widgets/list.zig`
//! takes a row count and a row height and has a `RowOptions.indent` for
//! exactly this -- and it is what makes the whole thing testable with no
//! window: a document's outline is a sequence of titles, depths and page
//! numbers, which is a thing a test can write down.
//!
//! ## Destinations are three grammars and one answer
//!
//! An entry points at a page through `/Dest`, or through `/A` with an action
//! whose `/S` is `/GoTo`. The destination itself is an explicit array
//! (`[page /XYZ x y z]`, `/Fit`, `/FitH t`, and the rest), a name, or a byte
//! string; the last two are looked up in `/Names /Dests` -- a name tree -- or
//! in the catalog's own `/Dests` dictionary, which is how PDF 1.1 said it.
//! All of that resolves to a page index and, where the form carries one, a
//! `top` in user space. Nothing above this file sees any of the grammars.
//!
//! ## Damage tolerance, as everywhere else
//!
//! A broken outline yields no bookmarks. It never yields an error that stops
//! a document opening: an entry whose destination cannot be resolved keeps its
//! title and has no page, an entry with no title is skipped, and a `/First`
//! chain that loops is cut where it comes back round. The reason is the same
//! one `pages.zig` gives -- a reader that refuses a file because the *table of
//! contents* is malformed is worse than one that shows a short table of
//! contents.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const Page = @import("Page.zig");
const object = @import("object.zig");

const Dict = object.Dict;
const Object = object.Object;
const Ref = object.Ref;

pub const Error = Document.Error;

/// Deep enough for any table of contents anybody has written; shallow enough
/// that a malformed one cannot exhaust the stack.
pub const max_depth = 32;

/// A ceiling on work for hostile input. A six-hundred-page book has a few
/// thousand entries.
pub const max_entries = 1 << 16;

/// How far into a name tree to walk before giving up.
const max_tree_nodes = 4096;

/// One line of the table of contents.
pub const Entry = struct {
    /// Decoded to UTF-8 and owned by the document's arena, so it lives as
    /// long as the `Document` and nothing here has to be freed.
    title: []const u8,
    /// Zero for a top-level entry.
    depth: u8 = 0,
    /// Where it goes, or null when the destination could not be resolved --
    /// a named destination the file does not define, a page that is not in
    /// this document, an action that is not a `/GoTo`.
    page: ?u32 = null,
    /// How far down the page, in user space, where the destination form says
    /// so. Null for `/Fit` and friends, which mean "the whole page".
    top: ?f64 = null,
    /// Whether the entry was showing its children when the file was written.
    /// `/Count` is positive for open and negative for closed (§12.3.3).
    open: bool = false,
    /// How many entries below this one are its descendants. Zero for a leaf,
    /// and what lets a tree be collapsed without a second walk.
    descendants: u32 = 0,
};

/// The whole outline, in the order it is read.
///
/// The result is arena-allocated in `doc` and lives until `doc.deinit()`, so
/// call it once and keep the slice. `page_list` is `pages.all(doc)`: a
/// destination names a page by reference and this is what turns one into an
/// index.
///
/// An empty slice is the answer for a document with no outline, an outline
/// that is not a dictionary, and an outline whose every entry is broken. None
/// of the three is an error.
pub fn all(doc: *Document, page_list: []const Page) Error![]const Entry {
    var walk: Walk = .{
        .doc = doc,
        .arena = doc.arenaAllocator(),
        .pages = page_list,
    };
    defer {
        walk.seen.deinit(doc.gpa);
        walk.index_of.deinit(doc.gpa);
    }

    for (page_list) |p| {
        walk.index_of.put(doc.gpa, p.ref.num, p.index) catch break;
    }

    const cat = doc.catalog() catch return &.{};
    walk.dests = if (doc.get(cat, "Dests") catch null) |d| d.asDict() else null;
    walk.names = blk: {
        const names = (doc.get(cat, "Names") catch null) orelse break :blk null;
        const dict = names.asDict() orelse break :blk null;
        const tree = (doc.get(dict, "Dests") catch null) orelse break :blk null;
        break :blk tree.asDict();
    };

    const root = (doc.get(cat, "Outlines") catch null) orelse return &.{};
    const dict = root.asDict() orelse return &.{};
    const first = (doc.get(dict, "First") catch null) orelse return &.{};

    walk.chain(dict.get("First").?, first, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Anything the parser objects to stops the walk and keeps whatever
        // was read before it. Half a table of contents is useful; a document
        // that will not open is not.
        else => {},
    };
    return walk.out.items;
}

const Walk = struct {
    doc: *Document,
    arena: Allocator,
    pages: []const Page,
    out: std.ArrayList(Entry) = .empty,
    /// Object numbers already entered. An outline is a tree, so a node seen
    /// twice is a `/Next` or a `/First` that loops, and stopping at the second
    /// visit bounds the work either way.
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Page object number to page index, built once.
    index_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The catalog's `/Dests`, for PDF 1.1 named destinations.
    dests: ?Dict = null,
    /// `/Names /Dests`, the name tree that replaced it.
    names: ?Dict = null,

    /// One `/Next` chain, and everything under each link of it.
    fn chain(wk: *Walk, raw: Object, resolved: Object, depth: u8) Error!void {
        if (depth >= max_depth) return;

        var entry_raw = raw;
        var entry = resolved;
        while (true) {
            if (wk.out.items.len >= max_entries) return;
            if (entry_raw.asRef()) |r| {
                if ((try wk.seen.getOrPut(wk.doc.gpa, r.num)).found_existing) return;
            }
            const dict = entry.asDict() orelse return;
            try wk.emit(dict, depth);

            const next_raw = dict.get("Next") orelse return;
            const next = try wk.doc.resolve(next_raw);
            if (next.isNull()) return;
            entry_raw = next_raw;
            entry = next;
        }
    }

    fn emit(wk: *Walk, dict: Dict, depth: u8) Error!void {
        const title = try wk.titleOf(dict);
        // An entry with no title is a node nobody could click on. Its
        // children are still read: a producer that writes an untitled group
        // around real sections is malformed, not a reason to lose them.
        const place: usize = wk.out.items.len;
        if (title.len != 0) {
            const count = if (try wk.doc.get(dict, "Count")) |c| c.asInt() orelse 0 else 0;
            try wk.out.append(wk.arena, .{
                .title = title,
                .depth = depth,
                .page = null,
                .open = count > 0,
            });
            const dest = try wk.destinationOf(dict);
            wk.out.items[place].page = dest.page;
            wk.out.items[place].top = dest.top;
        }

        if (dict.get("First")) |first_raw| {
            const first = try wk.doc.resolve(first_raw);
            if (!first.isNull()) try wk.chain(first_raw, first, depth + 1);
        }
        if (title.len != 0) {
            wk.out.items[place].descendants = @intCast(wk.out.items.len - place - 1);
        }
    }

    /// `/Title`, decoded. Empty for anything that is not a string.
    fn titleOf(wk: *Walk, dict: Dict) Error![]const u8 {
        const obj = (try wk.doc.get(dict, "Title")) orelse return "";
        const bytes = obj.asString() orelse return "";
        return decode(wk.arena, bytes) catch error.OutOfMemory;
    }

    const Destination = struct { page: ?u32 = null, top: ?f64 = null };

    /// `/Dest`, or `/A` when the action is a `/GoTo`.
    ///
    /// `/Dest` wins where a file has both, which is what §12.3.3 says and is
    /// also the safer reading: an action can be anything, and a destination
    /// cannot be anything but a place in this document.
    fn destinationOf(wk: *Walk, dict: Dict) Error!Destination {
        if (try wk.doc.get(dict, "Dest")) |d| return wk.resolveDest(d, 0);

        const action = (try wk.doc.get(dict, "A")) orelse return .{};
        const a = action.asDict() orelse return .{};
        const kind = (try wk.doc.get(a, "S")) orelse return .{};
        // A `/URI`, a `/Launch` or a `/GoToR` goes somewhere this reader
        // cannot follow. The entry keeps its title and points at nothing,
        // which is honest and is what a missing page means everywhere here.
        if (!kind.isName("GoTo")) return .{};
        const d = (try wk.doc.get(a, "D")) orelse return .{};
        return wk.resolveDest(d, 0);
    }

    /// An explicit array, a name, or a string -- the three ways a destination
    /// is written. `hops` stops a named destination that names itself.
    fn resolveDest(wk: *Walk, dest: Object, hops: u8) Error!Destination {
        if (hops > 4) return .{};
        switch (dest) {
            .array => |arr| return wk.fromArray(arr),
            .name => |n| return wk.byName(n, hops),
            .string => |s| return wk.byName(s, hops),
            else => return .{},
        }
    }

    /// `[page /XYZ left top zoom]` and the rest of table 151.
    ///
    /// Only the forms that carry a vertical position have one: `/XYZ`,
    /// `/FitH`, `/FitBH` and the two `/FitR` corners. `/Fit`, `/FitV` and
    /// `/FitB` mean the whole page and are reported with no `top`, which the
    /// reader turns into "the start of the page" -- rather than into a zero,
    /// which in user space is the *bottom*.
    fn fromArray(wk: *Walk, arr: object.Array) Error!Destination {
        if (arr.len == 0) return .{};

        var out: Destination = .{};
        out.page = switch (arr[0]) {
            // A page by reference is how a destination inside this document
            // is written.
            .ref => |r| wk.index_of.get(r.num),
            // By index, which is legal in a remote destination and turns up
            // in local ones too. Bounds-checked against this document.
            .integer => |n| if (n >= 0 and n < wk.pages.len) @intCast(n) else null,
            else => null,
        };
        if (arr.len < 2) return out;

        const kind = arr[1].asName() orelse return out;
        const at: ?usize = if (std.mem.eql(u8, kind, "XYZ"))
            3
        else if (std.mem.eql(u8, kind, "FitH") or std.mem.eql(u8, kind, "FitBH"))
            2
        else if (std.mem.eql(u8, kind, "FitR"))
            // `[page /FitR left bottom right top]`: the top is the last of
            // the four, and it is the one a reader scrolls to.
            5
        else
            null;

        if (at) |i| {
            if (i < arr.len) {
                // A null here is legal and means "leave it where it is",
                // which is the same as having no vertical position at all.
                if ((try wk.doc.resolve(arr[i])).asNumber()) |n| {
                    if (std.math.isFinite(n)) out.top = n;
                }
            }
        }
        return out;
    }

    /// A named destination, through the name tree and then the old dictionary.
    ///
    /// Either may hold the destination array directly or a dictionary with a
    /// `/D` in it (§12.3.2.3), so both shapes are unwrapped here rather than
    /// at each of the two lookups.
    fn byName(wk: *Walk, name: []const u8, hops: u8) Error!Destination {
        const found = (try wk.lookupTree(name)) orelse
            (try wk.lookupDests(name)) orelse return .{};

        if (found.asDict()) |d| {
            const inner = (try wk.doc.get(d, "D")) orelse return .{};
            return wk.resolveDest(inner, hops + 1);
        }
        return wk.resolveDest(found, hops + 1);
    }

    fn lookupDests(wk: *Walk, name: []const u8) Error!?Object {
        const d = wk.dests orelse return null;
        return wk.doc.get(d, name);
    }

    /// The `/Names` name tree (§7.9.6), walked rather than searched.
    ///
    /// The keys are sorted and `/Limits` is there to be binary-searched on,
    /// and this does neither: it descends into a kid whose limits could hold
    /// the name and scans the leaf. A name tree in a real document has a few
    /// hundred entries and is read once when the document opens, so the
    /// search that is worth having is the one that still answers correctly
    /// when the limits are wrong -- which they are, in files that number
    /// their destinations and sort them as numbers.
    fn lookupTree(wk: *Walk, name: []const u8) Error!?Object {
        var budget: u32 = max_tree_nodes;
        return wk.descend(wk.names orelse return null, name, 0, &budget);
    }

    fn descend(wk: *Walk, node: Dict, name: []const u8, depth: u8, budget: *u32) Error!?Object {
        if (depth >= max_depth or budget.* == 0) return null;
        budget.* -= 1;

        if (try wk.doc.get(node, "Names")) |names| {
            if (names.asArray()) |pairs| {
                var i: usize = 0;
                while (i + 1 < pairs.len) : (i += 2) {
                    const key = (try wk.doc.resolve(pairs[i])).asString() orelse continue;
                    if (std.mem.eql(u8, key, name)) return try wk.doc.resolve(pairs[i + 1]);
                }
            }
        }
        const kids = (try wk.doc.get(node, "Kids")) orelse return null;
        for (kids.asArray() orelse return null) |kid| {
            const d = (try wk.doc.resolve(kid)).asDict() orelse continue;
            if (!try wk.withinLimits(d, name)) continue;
            if (try wk.descend(d, name, depth + 1, budget)) |found| return found;
        }
        return null;
    }

    /// Whether a kid's `/Limits` could contain the name. A kid with no limits,
    /// or limits that are not two strings, is searched: a wrong `/Limits` is
    /// the commonest thing to get wrong about a name tree, and skipping a
    /// subtree on its word is how a destination goes missing.
    fn withinLimits(wk: *Walk, kid: Dict, name: []const u8) Error!bool {
        const limits = (try wk.doc.get(kid, "Limits")) orelse return true;
        const arr = limits.asArray() orelse return true;
        if (arr.len < 2) return true;
        const low = (try wk.doc.resolve(arr[0])).asString() orelse return true;
        const high = (try wk.doc.resolve(arr[1])).asString() orelse return true;
        return std.mem.order(u8, name, low) != .lt and std.mem.order(u8, name, high) != .gt;
    }
};

// -- text strings -----------------------------------------------------------

/// A PDF text string as UTF-8 (§7.9.2.2).
///
/// Two encodings, told apart by a byte order mark: UTF-16BE behind `FE FF`,
/// and PDFDocEncoding otherwise. There is no third case worth handling --
/// UTF-8 behind `EF BB BF` was added in PDF 2.0 and is passed through as
/// itself by the branch below, since PDFDocEncoding leaves ASCII alone and
/// those three bytes are not ASCII... which is why they are checked for
/// first.
pub fn decode(gpa: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) {
        return fromUtf16Be(gpa, bytes[2..]);
    }
    if (bytes.len >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and bytes[2] == 0xbf) {
        return gpa.dupe(u8, bytes[3..]);
    }
    return fromPdfDoc(gpa, bytes);
}

fn fromUtf16Be(gpa: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);

    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        var cp: u21 = (@as(u21, bytes[i]) << 8) | bytes[i + 1];
        if (cp >= 0xd800 and cp <= 0xdbff and i + 3 < bytes.len) {
            const low = (@as(u21, bytes[i + 2]) << 8) | bytes[i + 3];
            if (low >= 0xdc00 and low <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                i += 2;
            }
        }
        // A lone surrogate is not a code point. It becomes the replacement
        // character rather than stopping the decode: a title with one bad
        // pair in it is still a title.
        if (cp >= 0xd800 and cp <= 0xdfff) cp = 0xfffd;

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// PDFDocEncoding is Latin-1 but for the block at `0x80`, which holds the
/// typographic characters Latin-1 puts in its control range (Annex D.2).
const pdfdoc_high = [_]u21{
    0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044,
    0x2039, 0x203a, 0x2212, 0x2030, 0x201e, 0x201c, 0x201d, 0x2018,
    0x2019, 0x201a, 0x2122, 0xfb01, 0xfb02, 0x0141, 0x0152, 0x0160,
    0x0178, 0x017d, 0x0131, 0x0142, 0x0153, 0x0161, 0x017e, 0xfffd,
    0x20ac,
};

fn fromPdfDoc(gpa: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);

    for (bytes) |b| {
        const cp: u21 = if (b >= 0x80 and b - 0x80 < pdfdoc_high.len)
            pdfdoc_high[b - 0x80]
        else
            b;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const pages = @import("pages.zig");

/// As in `pages.zig`: `startxref 0` forces the reconstruction path, which
/// finds every `N G obj` header, so these fixtures carry no hand-computed
/// offsets.
fn openStatic(src: []const u8) !Document {
    return Document.open(testing.allocator, try testing.allocator.dupe(u8, src));
}

const three_pages =
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3\n" ++
    "   /MediaBox [0 0 612 792] >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" ++
    "4 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" ++
    "5 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n";

const nested =
    "%PDF-1.7\n" ++
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>\nendobj\n" ++
    three_pages ++
    "10 0 obj\n<< /Type /Outlines /First 11 0 R /Count 2 >>\nendobj\n" ++
    "11 0 obj\n<< /Title (Introduction) /Dest [3 0 R /XYZ 72 700 0]\n" ++
    "   /First 13 0 R /Count 2 /Next 12 0 R >>\nendobj\n" ++
    "12 0 obj\n<< /Title (Conclusion) /Dest [5 0 R /Fit] >>\nendobj\n" ++
    "13 0 obj\n<< /Title (Why) /Dest [4 0 R /FitH 300] /Next 14 0 R >>\nendobj\n" ++
    "14 0 obj\n<< /Title (How) /A << /S /GoTo /D [4 0 R /XYZ null 120 null] >> >>\nendobj\n" ++
    "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

fn outlineOf(doc: *Document) ![]const Entry {
    return all(doc, try pages.all(doc));
}

test "a nested outline comes back flat, in reading order, with a depth" {
    var doc = try openStatic(nested);
    defer doc.deinit();

    const list = try outlineOf(&doc);
    try testing.expectEqual(@as(usize, 4), list.len);

    try testing.expectEqualStrings("Introduction", list[0].title);
    try testing.expectEqual(@as(u8, 0), list[0].depth);
    try testing.expectEqualStrings("Why", list[1].title);
    try testing.expectEqual(@as(u8, 1), list[1].depth);
    try testing.expectEqualStrings("How", list[2].title);
    try testing.expectEqual(@as(u8, 1), list[2].depth);
    // The `/Next` of the *first* entry, so back out to the top level.
    try testing.expectEqualStrings("Conclusion", list[3].title);
    try testing.expectEqual(@as(u8, 0), list[3].depth);
}

test "each of the destination forms lands on its page" {
    var doc = try openStatic(nested);
    defer doc.deinit();

    const list = try outlineOf(&doc);
    // `/XYZ left top zoom`: the top is the third of the three.
    try testing.expectEqual(@as(?u32, 0), list[0].page);
    try testing.expectEqual(@as(?f64, 700), list[0].top);
    // `/FitH top`: the first and only number.
    try testing.expectEqual(@as(?u32, 1), list[1].page);
    try testing.expectEqual(@as(?f64, 300), list[1].top);
    // An action, which has to be a `/GoTo` to be followed at all.
    try testing.expectEqual(@as(?u32, 1), list[2].page);
    try testing.expectEqual(@as(?f64, 120), list[2].top);
    // `/Fit` means the whole page, which is no vertical position at all --
    // not a zero, which in user space is the bottom of it.
    try testing.expectEqual(@as(?u32, 2), list[3].page);
    try testing.expectEqual(@as(?f64, null), list[3].top);
}

test "an entry knows how many entries below it are its own" {
    var doc = try openStatic(nested);
    defer doc.deinit();

    const list = try outlineOf(&doc);
    try testing.expectEqual(@as(u32, 2), list[0].descendants);
    try testing.expectEqual(@as(u32, 0), list[1].descendants);
    try testing.expectEqual(@as(u32, 0), list[3].descendants);
    // `/Count 2`, which is positive, so it was showing its children.
    try testing.expect(list[0].open);
}

test "a named destination is found in the name tree" {
    var doc = try openStatic(
        "%PDF-1.7\n" ++
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /Names 20 0 R >>\nendobj\n" ++
            three_pages ++
            "10 0 obj\n<< /First 11 0 R >>\nendobj\n" ++
            "11 0 obj\n<< /Title (Middle) /Dest (sec.2) /Next 12 0 R >>\nendobj\n" ++
            "12 0 obj\n<< /Title (Nowhere) /Dest (sec.9) >>\nendobj\n" ++
            "20 0 obj\n<< /Dests 21 0 R >>\nendobj\n" ++
            "21 0 obj\n<< /Kids [22 0 R] >>\nendobj\n" ++
            "22 0 obj\n<< /Limits [(sec.1) (sec.3)]\n" ++
            "   /Names [(sec.1) [3 0 R /Fit] (sec.2) << /D [4 0 R /XYZ 0 500 0] >>] >>\nendobj\n" ++
            "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n",
    );
    defer doc.deinit();

    const list = try outlineOf(&doc);
    try testing.expectEqual(@as(usize, 2), list.len);
    // Through the tree, through the `/D` wrapper, to a page and a position.
    try testing.expectEqual(@as(?u32, 1), list[0].page);
    try testing.expectEqual(@as(?f64, 500), list[0].top);
    // A name the file does not define keeps its title and points nowhere.
    try testing.expectEqualStrings("Nowhere", list[1].title);
    try testing.expectEqual(@as(?u32, null), list[1].page);
}

test "the catalog's own Dests is looked in when there is no name tree" {
    var doc = try openStatic(
        "%PDF-1.7\n" ++
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /Dests 20 0 R >>\nendobj\n" ++
            three_pages ++
            "10 0 obj\n<< /First 11 0 R >>\nendobj\n" ++
            "11 0 obj\n<< /Title (Third) /Dest /last >>\nendobj\n" ++
            "20 0 obj\n<< /last [5 0 R /FitH 42] >>\nendobj\n" ++
            "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n",
    );
    defer doc.deinit();

    const list = try outlineOf(&doc);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(?u32, 2), list[0].page);
    try testing.expectEqual(@as(?f64, 42), list[0].top);
}

test "a document with no outline has none, and that is not an error" {
    var doc = try openStatic(
        "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
            three_pages ++ "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n",
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), (try outlineOf(&doc)).len);
}

test "a loop in the chain is cut where it comes back round" {
    var doc = try openStatic(
        "%PDF-1.7\n" ++
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>\nendobj\n" ++
            three_pages ++
            "10 0 obj\n<< /First 11 0 R >>\nendobj\n" ++
            "11 0 obj\n<< /Title (One) /Next 12 0 R >>\nendobj\n" ++
            "12 0 obj\n<< /Title (Two) /Next 11 0 R >>\nendobj\n" ++
            "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n",
    );
    defer doc.deinit();

    const list = try outlineOf(&doc);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("One", list[0].title);
    try testing.expectEqualStrings("Two", list[1].title);
}

test "an action that is not a GoTo keeps its title and points nowhere" {
    var doc = try openStatic(
        "%PDF-1.7\n" ++
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>\nendobj\n" ++
            three_pages ++
            "10 0 obj\n<< /First 11 0 R >>\nendobj\n" ++
            "11 0 obj\n<< /Title (Homepage) /A << /S /URI /URI (https://example.com) >> >>\nendobj\n" ++
            "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n",
    );
    defer doc.deinit();

    const list = try outlineOf(&doc);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("Homepage", list[0].title);
    try testing.expectEqual(@as(?u32, null), list[0].page);
}

test "a title is decoded from both of the encodings a text string has" {
    const gpa = testing.allocator;

    // PDFDocEncoding: ASCII through, and the 0x80 block is the typography
    // Latin-1 does not have.
    const plain = try decode(gpa, "Chapter 1\x97 \x80 \x8dx\x8e");
    defer gpa.free(plain);
    try testing.expectEqualStrings("Chapter 1\u{0160} \u{2022} \u{201c}x\u{201d}", plain);

    // UTF-16BE behind its byte order mark, surrogate pair and all.
    const wide = try decode(gpa, "\xfe\xff\x00H\x00i\xd8\x3d\xde\x00");
    defer gpa.free(wide);
    try testing.expectEqualStrings("Hi\u{1f600}", wide);

    // A lone high surrogate is a replacement character, not a refusal.
    const broken = try decode(gpa, "\xfe\xff\xd8\x3d\x00!");
    defer gpa.free(broken);
    try testing.expectEqualStrings("\u{fffd}!", broken);
}

