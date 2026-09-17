//! One open document, and everything about it that is not about looking at it.
//!
//! The split between this and `View` is the whole design. A buffer holds what
//! is true of the *document* -- its pages, its highlights, the text maps that
//! have been built -- and a view holds what is true of *one window onto it*.
//! Two windows on one document therefore agree about highlights without being
//! told to, because there is one `Marks` and they both read it, and disagree
//! about scroll without any effort, because there are two `View`s.
//!
//! The document itself is not owned here. `fenrir.Document` fills an object
//! cache as it is read and so may not be touched from two threads at once,
//! and the rasterising thread owns it for exactly that reason; a buffer holds
//! the pointer and the `pages` array, which is resolved once when the file is
//! opened and never written again.
//!
//! ## Text maps
//!
//! A cursor needs to know where the words are, and working that out costs one
//! page interpretation. The maps are cached here, not in a view, so that
//! splitting a window does not double the cost of moving the cursor -- and so
//! that a map built for the bottom window is already there when the top one
//! asks. The cache is small and evicts the least recently asked for; a
//! document's worth of maps would be tens of megabytes on a long paper.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fenrir = @import("../root.zig");
const Marks = @import("Marks.zig");
const text = @import("text.zig");

const Buffer = @This();

/// How many pages' text maps to keep. A cursor moves between neighbouring
/// pages, and a handful covers every window that can be on screen at once.
pub const map_slots = 8;

/// The absolute path this document was opened from, and the key it is
/// remembered under in Mímir. Owned here.
path: []u8 = &.{},
/// What to call it in a title bar. Borrowed from `path`.
title: []const u8 = &.{},

doc: *fenrir.Document = undefined,
pages: []const fenrir.Page = &.{},

/// The highlights, shared by every view. See `Marks`.
marks: Marks = .{},

/// How many views are open on this buffer. A buffer with none is closed.
views: u32 = 0,

maps: [map_slots]Map = @splat(.{}),
clock: u64 = 0,

pub const Map = struct {
    page: u32 = no_page,
    used: u64 = 0,
    map: text.Page = .{},

    pub const no_page = std.math.maxInt(u32);
};

pub fn deinit(b: *Buffer, gpa: Allocator) void {
    for (&b.maps) |*m| m.map.deinit(gpa);
    b.marks.deinit(gpa);
    gpa.free(b.path);
    b.* = .{};
}

/// The text map for `page`, if it has been built. Null is not an error: it
/// means the cursor has to wait a frame while the worker builds it, the same
/// way a page's pixels are waited for.
pub fn textMap(b: *Buffer, page: u32) ?text.Page {
    b.clock += 1;
    for (&b.maps) |*m| {
        if (m.page != page) continue;
        m.used = b.clock;
        return m.map;
    }
    return null;
}

pub fn hasMap(b: Buffer, page: u32) bool {
    for (b.maps) |m| {
        if (m.page == page) return true;
    }
    return false;
}

/// Takes ownership of a text map, evicting the least recently asked for.
pub fn putMap(b: *Buffer, gpa: Allocator, page: u32, map: text.Page) void {
    b.clock += 1;

    var chosen: usize = 0;
    var oldest: u64 = std.math.maxInt(u64);
    for (&b.maps, 0..) |*m, i| {
        if (m.page == page) {
            // Already there: keep the one we have and free the newcomer,
            // rather than leaking whichever of the two loses.
            var dup = map;
            dup.deinit(gpa);
            m.used = b.clock;
            return;
        }
        if (m.page == Map.no_page) {
            chosen = i;
            break;
        }
        if (m.used < oldest) {
            oldest = m.used;
            chosen = i;
        }
    }

    b.maps[chosen].map.deinit(gpa);
    b.maps[chosen] = .{ .page = page, .used = b.clock, .map = map };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn oneLine(gpa: Allocator, y: f32) !text.Page {
    var glyphs = try gpa.alloc(fenrir.gelgja.DisplayList.Glyph, 1);
    defer gpa.free(glyphs);
    glyphs[0] = .{ .code = 'x', .offset = .origin };
    var cmds = try gpa.alloc(fenrir.gelgja.DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, y),
        .glyphs = .{ .start = 0, .count = 1 },
    } };
    return text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
}

test "a text map is cached, and asking for a page that has none is not an error" {
    const gpa = testing.allocator;
    var b: Buffer = .{};
    defer b.deinit(gpa);

    try testing.expect(b.textMap(3) == null);
    b.putMap(gpa, 3, try oneLine(gpa, 700));
    const got = b.textMap(3).?;
    try testing.expectEqual(@as(usize, 1), got.lines.len);
    try testing.expect(b.hasMap(3));
}

test "the same page put twice keeps one map and frees the other" {
    // The worker can finish the same page twice -- two views asked for it in
    // the same frame -- and whichever loses has to be freed by the code that
    // rejected it, or it is a leak that only shows up under a split.
    const gpa = testing.allocator;
    var b: Buffer = .{};
    defer b.deinit(gpa);

    b.putMap(gpa, 1, try oneLine(gpa, 700));
    b.putMap(gpa, 1, try oneLine(gpa, 700));
    var live: u32 = 0;
    for (b.maps) |m| {
        if (m.page != Buffer.Map.no_page) live += 1;
    }
    try testing.expectEqual(@as(u32, 1), live);
}

test "the least recently asked for map is the one evicted" {
    const gpa = testing.allocator;
    var b: Buffer = .{};
    defer b.deinit(gpa);

    for (0..map_slots) |i| b.putMap(gpa, @intCast(i), try oneLine(gpa, 700));
    // Touch page 0 so it is not the stalest, then overflow the cache.
    _ = b.textMap(0);
    b.putMap(gpa, 99, try oneLine(gpa, 700));

    try testing.expect(b.hasMap(0));
    try testing.expect(b.hasMap(99));
    try testing.expect(!b.hasMap(1));
}

test "highlights belong to the buffer, so every view on it sees the same list" {
    const gpa = testing.allocator;
    var b: Buffer = .{};
    defer b.deinit(gpa);

    // Two views, each having drawn the marks as they were.
    var seen_top = b.marks.revision;
    var seen_bottom = b.marks.revision;

    _ = try b.marks.add(gpa, .{ .page = 2, .box = .fromRect(100, 700, 200, 712) }, false);

    // Whichever window drew the highlight, both find out, and both find out
    // by the same comparison.
    try testing.expect(b.marks.revision != seen_top);
    try testing.expect(b.marks.revision != seen_bottom);
    seen_top = b.marks.revision;
    seen_bottom = b.marks.revision;
    try testing.expectEqual(@as(usize, 1), b.marks.count());
    try testing.expectEqual(seen_top, seen_bottom);
}
