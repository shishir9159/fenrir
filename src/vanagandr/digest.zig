//! What each object of one document holds, as a number.
//!
//! `DisplayList.hash` names images, fonts, shadings and soft masks by object
//! number, and asks this what each number stands for. The answer is the
//! object's value with every reference in it replaced by the digest of what
//! the reference points at: a font is its dictionary, its descriptor and its
//! program's bytes, and not the numbers any of them were given. So two
//! exports of one source that number their objects apart still agree, and
//! one file revised in place -- which keeps a figure's number and replaces
//! the figure -- does not.
//!
//! Streams are digested undecoded. Equal raw bytes decode equally, and
//! decoding every image on both sides to learn that would cost what drawing
//! them does.
//!
//! Here and not in Gjöll because it is a policy about what "the same" means,
//! and the only callers are commands: `fenrir diff`, and `fenrir trace
//! --hash`, which prints what `diff` compares.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const DisplayList = fenrir.gelgja.DisplayList;
const Object = fenrir.Object;
const Wyhash = std.hash.Wyhash;

pub const Digests = struct {
    gpa: Allocator,
    doc: *fenrir.Document,
    /// By object number, because a page's forty text runs name the same
    /// three fonts, and a document's forty pages the same few again.
    memo: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Objects being digested, to stop at a reference back to one of them.
    open: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// References followed before giving up. A font is three deep; a soft
    /// mask with a form and its resources, five or six.
    const max_depth = 32;
    /// What a reference back into an object being digested contributes. A
    /// constant, so that two documents with the same cycle agree.
    const cycle: u64 = 0x6379636c65;

    pub fn init(gpa: Allocator, doc: *fenrir.Document) Digests {
        return .{ .gpa = gpa, .doc = doc };
    }

    pub fn deinit(d: *Digests) void {
        d.memo.deinit(d.gpa);
        d.open.deinit(d.gpa);
    }

    /// The interface `DisplayList.hash` takes. The pointer is to `d`, so `d`
    /// must not move while the hash runs.
    pub fn objects(d: *Digests) DisplayList.Objects {
        return .{ .ptr = d, .digest = digestOf };
    }

    fn digestOf(ptr: *anyopaque, id: fenrir.gelgja.ObjectId) ?u64 {
        const d: *Digests = @ptrCast(@alignCast(ptr));
        return d.of(id, 0);
    }

    /// Null when the object would not read, or the graph under it is deeper
    /// than any real one: either way a caller that trusted the hash would be
    /// trusting a guess.
    pub fn of(d: *Digests, num: u32, depth: u32) ?u64 {
        if (d.memo.get(num)) |known| return known;
        if (d.open.contains(num)) return cycle;
        if (depth >= max_depth) return null;

        d.open.put(d.gpa, num, {}) catch return null;
        defer _ = d.open.remove(num);

        const obj = d.doc.fetch(.{ .num = num, .gen = 0 }) catch return null;
        var h: Wyhash = .init(0);
        if (!d.feed(&h, obj, depth)) return null;
        const digest = h.final();
        d.memo.put(d.gpa, num, digest) catch {};
        return digest;
    }

    fn feed(d: *Digests, h: *Wyhash, obj: Object, depth: u32) bool {
        h.update(&.{@intFromEnum(std.meta.activeTag(obj))});
        switch (obj) {
            .null => {},
            .boolean => |v| h.update(&.{@intFromBool(v)}),
            .integer => |v| h.update(std.mem.asBytes(&v)),
            .real => |v| h.update(std.mem.asBytes(&v)),
            .string, .name => |v| sized(h, v),
            .array => |items| {
                h.update(std.mem.asBytes(&items.len));
                for (items) |item| if (!d.feed(h, item, depth)) return false;
            },
            .dict => |dict| if (!d.feedDict(h, dict, depth)) return false,
            .stream => |s| {
                if (!d.feedDict(h, s.dict, depth)) return false;
                sized(h, s.raw);
            },
            .ref => |r| {
                const digest = d.of(r.num, depth + 1) orelse return false;
                h.update(std.mem.asBytes(&digest));
            },
        }
        return true;
    }

    /// In the file's order. Two producers that write one dictionary's keys in
    /// different orders digest apart, which costs a rasterisation and never
    /// a wrong answer.
    fn feedDict(d: *Digests, h: *Wyhash, dict: fenrir.Dict, depth: u32) bool {
        h.update(std.mem.asBytes(&dict.count()));
        for (dict.keys(), dict.values()) |key, value| {
            sized(h, key);
            if (!d.feed(h, value, depth)) return false;
        }
        return true;
    }

    fn sized(h: *Wyhash, bytes: []const u8) void {
        h.update(std.mem.asBytes(&bytes.len));
        h.update(bytes);
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

/// A font and its descriptor, under whichever numbers the caller gives, and
/// a stream that refers back to the font. No cross-reference table: the
/// document rebuilds one by scanning, which is all a test needs.
fn fixture(buf: []u8, font: u32, descriptor: u32, program: []const u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\%PDF-1.4
        \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        \\2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        \\{d} 0 obj << /Type /Font /FontDescriptor {d} 0 R /Back {d} 0 R >> endobj
        \\{d} 0 obj << /Length {d} >> stream
        \\{s}
        \\endstream endobj
        \\trailer << /Root 1 0 R >>
        \\%%EOF
    , .{ font, descriptor, font, descriptor, program.len, program }) catch unreachable;
}

fn digestIn(bytes: []const u8, num: u32) !?u64 {
    var doc = try fenrir.openBorrowed(testing.allocator, bytes);
    defer doc.deinit();
    var d: Digests = .init(testing.allocator, &doc);
    defer d.deinit();
    return d.of(num, 0);
}

test "an object digests the same under other numbers, and apart with other bytes" {
    var one: [512]u8 = undefined;
    var two: [512]u8 = undefined;
    var three: [512]u8 = undefined;

    const first = (try digestIn(fixture(&one, 5, 6, "glyphs"), 5)).?;
    // Renumbered: the same font.
    try testing.expectEqual(first, (try digestIn(fixture(&two, 40, 17, "glyphs"), 40)).?);
    // Same numbers, one byte of its program changed: the case a hash over
    // numbers would have called identical.
    try testing.expect(first != (try digestIn(fixture(&three, 5, 6, "glyphz"), 5)).?);
}

test "a reference back into the object being digested ends the walk" {
    var buf: [512]u8 = undefined;
    // `/Back` refers to the font from inside the font. Without the guard
    // this recurses until the depth limit and comes back null.
    try testing.expect((try digestIn(fixture(&buf, 5, 6, "glyphs"), 5)) != null);
}
