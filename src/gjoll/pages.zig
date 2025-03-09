//! Walking the page tree (ISO 32000-2 §7.7.3).
//!
//! The page tree is a balanced tree, not a list: `/Kids` holds a mix of
//! further `/Pages` nodes and `/Page` leaves, and four attributes are
//! inherited down it. Walking top-down and carrying the inherited set along
//! is both the natural traversal and the only one that gets inheritance right
//! without repeatedly climbing `/Parent`.
//!
//! This module sits *above* `Document` and imports it, never the reverse, so
//! the one-way layering in `root.zig` still holds.
//!
//! Three things go wrong in real files and are handled here rather than left
//! to the caller: `/Count` disagreeing with the number of leaves, `/Type`
//! missing from nodes, and `/Kids` containing a cycle.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const Page = @import("Page.zig");
const object = @import("object.zig");

const Array = object.Array;
const Dict = object.Dict;
const Object = object.Object;
const Rect = Page.Rect;
const Ref = object.Ref;
const Rotation = Page.Rotation;

pub const Error = Document.Error;

/// Deep enough for any real balanced tree; shallow enough that a malformed
/// one cannot exhaust the stack.
pub const max_depth = 64;

/// A ceiling on work for hostile input. The largest PDFs in existence are
/// around a hundred thousand pages.
pub const max_pages = 1 << 20;

/// Every page in document order.
///
/// The result is arena-allocated in `doc` and lives until `doc.deinit()`, so
/// call this once and keep the slice rather than calling it per page.
///
/// Never fails on a structurally broken tree: a document whose page tree is
/// missing or yields nothing falls back to scanning for page dictionaries,
/// the same way a broken cross-reference table falls back to scanning for
/// object headers.
pub fn all(doc: *Document) Error![]const Page {
    var walk: Walk = .{ .doc = doc, .arena = doc.arenaAllocator() };
    defer walk.visited.deinit(doc.gpa);

    if (doc.catalog()) |cat| {
        if (cat.get("Pages")) |root| {
            try walk.descend(root, .{}, 0);
        }
    } else |_| {}

    if (walk.out.items.len == 0) try walk.scanForOrphanPages();
    return walk.out.items;
}

/// The page count the document claims in `/Pages /Count`. Worth comparing
/// against `all().len`: a mismatch is a reliable sign of a damaged file.
pub fn declaredCount(doc: *Document) ?i64 {
    const cat = doc.catalog() catch return null;
    const root = (doc.get(cat, "Pages") catch return null) orelse return null;
    const tree = root.asDict() orelse return null;
    const count = (doc.get(tree, "Count") catch return null) orelse return null;
    return count.asInt();
}

// -- inheritance ------------------------------------------------------------

/// The four inheritable attributes (§7.7.3.4, table 31), carried down the
/// tree. Null means "no ancestor has defined this yet".
const Inherited = struct {
    resources: ?Dict = null,
    media_box: ?Rect = null,
    crop_box: ?Rect = null,
    rotate: ?Rotation = null,

    /// Returns the set as seen from inside `dict`: anything the node defines
    /// overrides what it inherited, and anything it omits passes through.
    fn extend(self: Inherited, doc: *Document, dict: Dict) Error!Inherited {
        var next = self;

        if (try doc.get(dict, "Resources")) |v| {
            if (v.asDict()) |d| next.resources = d;
        }
        if (try readRect(doc, dict, "MediaBox")) |r| next.media_box = r;
        if (try readRect(doc, dict, "CropBox")) |r| next.crop_box = r;
        if (try doc.get(dict, "Rotate")) |v| {
            if (v.asInt()) |deg| {
                // A rotation that is not a multiple of 90 is malformed. Keep
                // the inherited value rather than inventing one.
                if (Rotation.fromDegrees(deg)) |rot| next.rotate = rot;
            }
        }
        return next;
    }
};

/// Reads a rectangle, rejecting anything that could not be rendered into.
/// Returning null lets the caller fall back to the inherited value, which is
/// what the spec's inheritance rule would have done had the entry been absent.
fn readRect(doc: *Document, dict: Dict, key: []const u8) Error!?Rect {
    const obj = try doc.get(dict, key) orelse return null;
    const arr = obj.asArray() orelse return null;
    if (arr.len < 4) return null;

    var corners: [4]f64 = undefined;
    for (&corners, arr[0..4]) |*slot, item| {
        // Individual corner coordinates are occasionally indirect references.
        const n = (try doc.resolve(item)).asNumber() orelse return null;
        if (!std.math.isFinite(n)) return null;
        slot.* = n;
    }

    const rect: Rect = .{
        .x0 = corners[0],
        .y0 = corners[1],
        .x1 = corners[2],
        .y1 = corners[3],
    };
    const normalized = rect.normalized();
    return if (normalized.isDegenerate()) null else normalized;
}

// -- the walk ---------------------------------------------------------------

const Walk = struct {
    doc: *Document,
    arena: Allocator,
    out: std.ArrayList(Page) = .empty,
    /// Object numbers already entered. A page tree is a tree, so seeing a node
    /// twice means either a cycle or a shared subtree; both are malformed, and
    /// stopping at the second visit bounds the work either way.
    visited: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn descend(w: *Walk, entry: Object, inherited: Inherited, depth: u8) Error!void {
        if (depth >= max_depth) return;
        if (w.out.items.len >= max_pages) return;

        const ref = entry.asRef();
        if (ref) |r| {
            if ((try w.visited.getOrPut(w.doc.gpa, r.num)).found_existing) return;
        }

        const dict = (try w.doc.resolve(entry)).asDict() orelse return;
        const here = try inherited.extend(w.doc, dict);

        switch (try classify(w.doc, dict)) {
            .internal => |kids| for (kids) |kid| try w.descend(kid, here, depth + 1),
            .leaf => try w.emit(dict, ref, here),
        }
    }

    fn emit(w: *Walk, dict: Dict, ref: ?Ref, inherited: Inherited) Error!void {
        const media = inherited.media_box orelse Rect.us_letter;

        // §14.11.2: the crop box is clipped to the medium. A crop box that
        // misses the medium entirely is nonsense, so ignore it in that case.
        const crop = if (inherited.crop_box) |c| clip: {
            const clipped = c.intersect(media);
            break :clip if (clipped.isDegenerate()) media else clipped;
        } else media;

        try w.out.append(w.arena, .{
            .index = @intCast(w.out.items.len),
            .ref = ref orelse .{ .num = 0, .gen = 0 },
            .dict = dict,
            .resources = inherited.resources orelse .empty,
            .media_box = media,
            .crop_box = crop,
            .rotate = inherited.rotate orelse .none,
        });
    }

    /// No page tree produced anything. Look for page dictionaries directly,
    /// in object-number order, and recover each one's inherited attributes by
    /// climbing its `/Parent` chain.
    fn scanForOrphanPages(w: *Walk) Error!void {
        var it = try w.doc.objects();
        while (try it.next()) |item| {
            if (item.entry == .free) continue;
            const dict = item.object.asDict() orelse continue;

            const kind = dict.get("Type") orelse continue;
            if (!kind.isName("Page")) continue;

            const inherited = try inheritedFromParents(w.doc, dict);
            try w.emit(dict, .{ .num = item.num, .gen = 0 }, inherited);
            if (w.out.items.len >= max_pages) return;
        }
    }
};

const NodeKind = union(enum) {
    leaf,
    internal: Array,
};

/// `/Type` is authoritative when present, but plenty of producers omit it, so
/// fall back to the shape of the node: something with kids is internal.
///
/// The `/Type /Pages` case deliberately returns an empty kid list rather than
/// falling through to `.leaf`, so an empty interior node contributes no pages
/// instead of being mistaken for one.
fn classify(doc: *Document, dict: Dict) Error!NodeKind {
    const kids: ?Array = if (try doc.get(dict, "Kids")) |k| k.asArray() else null;

    if (dict.get("Type")) |kind| {
        if (kind.isName("Page")) return .leaf;
        if (kind.isName("Pages")) return .{ .internal = kids orelse &.{} };
    }
    return if (kids) |k| .{ .internal = k } else .leaf;
}

/// Rebuilds the inherited set for a page reached without a top-down walk, by
/// collecting its ancestors and applying them outermost-first so that nearer
/// definitions win. Bounded by `max_depth`, which also breaks `/Parent` loops.
fn inheritedFromParents(doc: *Document, dict: Dict) Error!Inherited {
    var chain: [max_depth]Dict = undefined;
    var depth: usize = 0;

    var current = dict;
    while (depth < max_depth) {
        chain[depth] = current;
        depth += 1;

        const parent = try doc.get(current, "Parent") orelse break;
        current = parent.asDict() orelse break;
    }

    var acc: Inherited = .{};
    var i = depth;
    while (i > 0) {
        i -= 1;
        acc = try acc.extend(doc, chain[i]);
    }
    return acc;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Builds a document from a static string. `startxref 0` is deliberate: it
/// forces the reconstruction path, which finds every `N G obj` header, so
/// these fixtures do not have to carry hand-computed offsets.
fn openStatic(src: []const u8) !Document {
    return Document.open(testing.allocator, try testing.allocator.dupe(u8, src));
}

const flat_tree =
    "%PDF-1.7\n" ++
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3\n" ++
    "   /MediaBox [0 0 612 792] /Resources << /Font << /F1 9 0 R >> >> >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" ++
    "4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate 90 >>\nendobj\n" ++
    "5 0 obj\n<< /Type /Page /Parent 2 0 R /CropBox [50 50 562 742] >>\nendobj\n" ++
    "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

test "walks a flat tree in order" {
    var doc = try openStatic(flat_tree);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(@as(u32, 0), list[0].index);
    try testing.expectEqual(@as(u32, 3), list[0].ref.num);
    try testing.expectEqual(@as(u32, 5), list[2].ref.num);
    try testing.expectEqual(@as(?i64, 3), declaredCount(&doc));
}

test "inherits MediaBox and Resources from an ancestor" {
    var doc = try openStatic(flat_tree);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(Rect.us_letter, list[0].media_box);
    // The crop box defaults to the media box, not to null.
    try testing.expectEqual(Rect.us_letter, list[0].crop_box);
    try testing.expect(list[0].resources.contains("Font"));
    try testing.expectEqual(Rotation.none, list[0].rotate);
}

test "a page overrides what it inherits" {
    var doc = try openStatic(flat_tree);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(@as(f64, 200), list[1].media_box.width());
    try testing.expectEqual(Rotation.cw90, list[1].rotate);
    // Rotation swaps the displayed axes but not the box itself.
    try testing.expectEqual(@as(f64, 100), list[1].displayWidth());
    try testing.expectEqual(@as(f64, 200), list[1].displayHeight());
    // Resources still come from the parent.
    try testing.expect(list[1].resources.contains("Font"));
}

test "a crop box is clipped to the medium" {
    var doc = try openStatic(flat_tree);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(Rect{ .x0 = 50, .y0 = 50, .x1 = 562, .y1 = 742 }, list[2].crop_box);
    try testing.expectEqual(Rect.us_letter, list[2].media_box);
    try testing.expect(list[2].isCropped());
    try testing.expect(!list[0].isCropped());
}

const nested_tree =
    "%PDF-1.7\n" ++
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 4 /MediaBox [0 0 612 792] >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /Rotate 180 >>\nendobj\n" ++
    "4 0 obj\n<< /Type /Page /Parent 3 0 R >>\nendobj\n" ++
    "5 0 obj\n<< /Type /Page /Parent 3 0 R /Rotate 0 >>\nendobj\n" ++
    "6 0 obj\n<< /Type /Pages /Parent 2 0 R /Kids [7 0 R 8 0 R] /Count 2 >>\nendobj\n" ++
    "7 0 obj\n<< /Type /Page /Parent 6 0 R >>\nendobj\n" ++
    "8 0 obj\n<< /Type /Page /Parent 6 0 R >>\nendobj\n" ++
    "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

test "walks a nested tree depth first" {
    var doc = try openStatic(nested_tree);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(@as(usize, 4), list.len);
    for (list, [_]u32{ 4, 5, 7, 8 }) |page, expected| {
        try testing.expectEqual(expected, page.ref.num);
    }

    // Rotation is inherited from the intermediate node, and overridden on the
    // leaf that sets it back to zero.
    try testing.expectEqual(Rotation.cw180, list[0].rotate);
    try testing.expectEqual(Rotation.none, list[1].rotate);
    // The second subtree never sets /Rotate, so it stays at the default.
    try testing.expectEqual(Rotation.none, list[2].rotate);
    // MediaBox reaches every leaf from the root.
    try testing.expectEqual(Rect.us_letter, list[3].media_box);
}

test "a cycle in /Kids terminates" {
    const cyclic =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R 2 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(cyclic);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(f64, 10), list[0].media_box.width());
}

test "nodes without /Type are classified by shape" {
    const untyped =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 300 300] >>\nendobj\n" ++
        "3 0 obj\n<< /Parent 2 0 R /Contents 9 0 R >>\nendobj\n" ++
        "4 0 obj\n<< /Parent 2 0 R >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(untyped);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(f64, 300), list[0].media_box.width());
}

test "an empty interior node yields no pages" {
    const empty_node =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(empty_node);
    defer doc.deinit();

    // The tree is legitimately empty, so the fallback scan finds nothing
    // either -- and must not mistake the /Pages node itself for a page.
    try testing.expectEqual(@as(usize, 0), (try all(&doc)).len);
}

test "pages are recovered when the tree is unreachable" {
    // /Pages points at an object that does not exist, so the walk yields
    // nothing and the scan takes over. Inherited attributes come back via the
    // /Parent chain instead of top-down.
    const broken =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 99 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /MediaBox [0 0 400 500] /Rotate 270 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" ++
        "4 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(broken);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(f64, 400), list[0].media_box.width());
    try testing.expectEqual(Rotation.cw270, list[0].rotate);
    try testing.expectEqual(@as(u32, 3), list[0].ref.num);
}

test "a reversed MediaBox is normalised" {
    const reversed =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [612 792 0 0] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(reversed);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(Rect.us_letter, list[0].media_box);
}

test "a degenerate MediaBox falls back to the default" {
    const degenerate =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 0 0] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(degenerate);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqual(Rect.us_letter, list[0].media_box);
}

test "content streams in an array are joined with whitespace" {
    const split =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents [4 0 R 5 0 R] >>\nendobj\n" ++
        "4 0 obj\n<< /Length 5 >>\nstream\n1 0 0\nendstream\nendobj\n" ++
        "5 0 obj\n<< /Length 5 >>\nstream\n1 k f\nendstream\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

    var doc = try openStatic(split);
    defer doc.deinit();

    const list = try all(&doc);
    const data = try list[0].contents(&doc);
    // Without the separator the seam would read `1 0 01 k f` -- one wrong
    // operand, silently.
    try testing.expectEqualStrings("1 0 0\n1 k f", data);
}

test "a page with no /Contents has empty content" {
    var doc = try openStatic(flat_tree);
    defer doc.deinit();

    const list = try all(&doc);
    try testing.expectEqualStrings("", try list[0].contents(&doc));
}
