//! A page, with the attributes it inherits from the page tree already
//! resolved (ISO 32000-2 §7.7.3).
//!
//! Four page attributes are *inheritable*: a page dictionary that omits
//! `/Resources`, `/MediaBox`, `/CropBox`, or `/Rotate` takes the value from
//! the nearest ancestor that defines one. Callers should never have to walk
//! `/Parent` themselves, so every field here holds the effective value.
//!
//! Nothing here is optional. A page with no `/MediaBox` anywhere in its
//! ancestry is malformed, but it still has to render, so the defaults from
//! §14.11.2 and §7.8.3 are applied rather than surfaced as nulls.

const std = @import("std");

const Document = @import("Document.zig");
const object = @import("object.zig");
const Dict = object.Dict;
const Object = object.Object;
const Ref = object.Ref;

const Page = @This();

/// Zero-based position in the document, in page-tree order.
index: u32,
/// The page dictionary's own reference, so output can be checked against
/// `fenrir dump --obj N`. Zero when the page was found by scanning.
ref: Ref,
/// The page dictionary itself, for everything not inherited: `/Contents`,
/// `/Annots`, `/Group`, `/StructParents`.
dict: Dict,

/// §7.8.3. Empty rather than absent when nothing declares one, so callers
/// never branch on a null.
resources: Dict,
/// §14.11.2. The boundaries of the physical medium.
media_box: Rect,
/// The visible region, already intersected with `media_box`. Equal to it
/// when the page declares no `/CropBox`.
crop_box: Rect,
/// Clockwise display rotation, always one of the four legal values.
rotate: Rotation,

/// A PDF rectangle: two opposite corners, in user-space units of 1/72 inch,
/// with the origin at the bottom left and +Y pointing up (§7.9.5).
pub const Rect = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    /// 8.5 x 11 inches at 72 units per inch. What a missing `/MediaBox` is
    /// nearly always meant to be, and what most readers substitute.
    pub const us_letter: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };

    pub fn width(r: Rect) f64 {
        return r.x1 - r.x0;
    }

    pub fn height(r: Rect) f64 {
        return r.y1 - r.y0;
    }

    /// The spec gives two opposite corners in either order, so `[612 792 0 0]`
    /// means the same rectangle as `[0 0 612 792]`. Normalise once on the way
    /// in and no downstream code has to think about it.
    pub fn normalized(r: Rect) Rect {
        return .{
            .x0 = @min(r.x0, r.x1),
            .y0 = @min(r.y0, r.y1),
            .x1 = @max(r.x0, r.x1),
            .y1 = @max(r.y0, r.y1),
        };
    }

    /// Both inputs must already be normalised. The result can be degenerate
    /// when the rectangles do not overlap, which callers check for.
    pub fn intersect(a: Rect, b: Rect) Rect {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    /// A rectangle with no area cannot be rendered into, so it is treated as
    /// a missing value rather than an empty page.
    pub fn isDegenerate(r: Rect) bool {
        return !(r.width() > 0 and r.height() > 0);
    }

    pub fn format(r: Rect, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("[{d:.2} {d:.2} {d:.2} {d:.2}]", .{ r.x0, r.y0, r.x1, r.y1 });
    }
};

/// `/Rotate`: clockwise, and required to be a multiple of 90 (§7.7.3.3).
pub const Rotation = enum(u16) {
    none = 0,
    cw90 = 90,
    cw180 = 180,
    cw270 = 270,

    /// Negative and out-of-range values are legal and wrap; anything that is
    /// not a multiple of 90 is malformed and yields null so the caller can
    /// keep the inherited value instead of inventing one.
    pub fn fromDegrees(v: i64) ?Rotation {
        return switch (@mod(v, 360)) {
            0 => .none,
            90 => .cw90,
            180 => .cw180,
            270 => .cw270,
            else => null,
        };
    }

    pub fn degrees(r: Rotation) u16 {
        return @intFromEnum(r);
    }

    /// Quarter turns exchange width and height on screen.
    pub fn swapsAxes(r: Rotation) bool {
        return r == .cw90 or r == .cw270;
    }
};

// -- derived geometry -------------------------------------------------------

/// Width of the visible area as displayed, i.e. after `/Rotate`.
pub fn displayWidth(p: Page) f64 {
    return if (p.rotate.swapsAxes()) p.crop_box.height() else p.crop_box.width();
}

/// Height of the visible area as displayed, i.e. after `/Rotate`.
pub fn displayHeight(p: Page) f64 {
    return if (p.rotate.swapsAxes()) p.crop_box.width() else p.crop_box.height();
}

/// True when the page declares a crop box smaller than its medium, which
/// means content exists outside what a viewer shows.
pub fn isCropped(p: Page) bool {
    const c = p.crop_box;
    const m = p.media_box;
    return c.x0 != m.x0 or c.y0 != m.y0 or c.x1 != m.x1 or c.y1 != m.y1;
}

// -- content ----------------------------------------------------------------

/// The page's content stream (§7.8.2).
///
/// `/Contents` is either one stream or an array of them, and an array must be
/// concatenated *with whitespace between the parts*: the division points are
/// arbitrary, so a single token can be split across two streams. Producers
/// split content this way routinely, and joining without a separator silently
/// corrupts the operator at every seam.
///
/// The result is arena-allocated in `doc` and must not be freed.
pub fn contents(p: Page, doc: *Document) Document.Error![]const u8 {
    const obj = try doc.get(p.dict, "Contents") orelse return "";

    switch (obj) {
        .stream => |s| return (try doc.streamData(s)).data,
        .array => |parts| {
            var out: std.ArrayList(u8) = .empty;
            const arena = doc.arenaAllocator();
            for (parts) |part| {
                const stream = (try doc.resolve(part)).asStream() orelse continue;
                const data = try doc.streamData(stream);
                if (out.items.len != 0) try out.append(arena, '\n');
                try out.appendSlice(arena, data.data);
            }
            return out.items;
        },
        else => return "",
    }
}

/// Annotations on this page (§12.5). Not inheritable; returns an empty slice
/// when the page has none.
pub fn annotations(p: Page, doc: *Document) Document.Error![]const Object {
    const obj = try doc.get(p.dict, "Annots") orelse return &.{};
    return obj.asArray() orelse &.{};
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "rectangles normalise whichever corners they are given" {
    const forwards: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
    const backwards: Rect = .{ .x0 = 612, .y0 = 792, .x1 = 0, .y1 = 0 };
    try testing.expectEqual(forwards, backwards.normalized());
    try testing.expectEqual(@as(f64, 612), backwards.normalized().width());
}

test "intersection clips to the smaller rectangle" {
    const media: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
    const crop: Rect = .{ .x0 = 50, .y0 = 50, .x1 = 700, .y1 = 700 };
    const clipped = crop.intersect(media);
    try testing.expectEqual(Rect{ .x0 = 50, .y0 = 50, .x1 = 612, .y1 = 700 }, clipped);
}

test "non-overlapping rectangles are degenerate" {
    const a: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 };
    const b: Rect = .{ .x0 = 20, .y0 = 20, .x1 = 30, .y1 = 30 };
    try testing.expect(a.intersect(b).isDegenerate());
    try testing.expect(!a.isDegenerate());
}

test "rotation accepts only multiples of 90, and wraps" {
    try testing.expectEqual(Rotation.cw90, Rotation.fromDegrees(90).?);
    try testing.expectEqual(Rotation.cw270, Rotation.fromDegrees(-90).?);
    try testing.expectEqual(Rotation.none, Rotation.fromDegrees(720).?);
    try testing.expectEqual(Rotation.cw180, Rotation.fromDegrees(540).?);
    try testing.expectEqual(@as(?Rotation, null), Rotation.fromDegrees(45));
}

test "quarter turns swap the displayed axes" {
    const portrait: Page = .{
        .index = 0,
        .ref = .{ .num = 1, .gen = 0 },
        .dict = .empty,
        .resources = .empty,
        .media_box = .us_letter,
        .crop_box = .us_letter,
        .rotate = .none,
    };
    try testing.expectEqual(@as(f64, 612), portrait.displayWidth());
    try testing.expectEqual(@as(f64, 792), portrait.displayHeight());

    var landscape = portrait;
    landscape.rotate = .cw90;
    try testing.expectEqual(@as(f64, 792), landscape.displayWidth());
    try testing.expectEqual(@as(f64, 612), landscape.displayHeight());
}
