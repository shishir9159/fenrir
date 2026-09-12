//! Decoding a display list's images, and keeping them for the replay.
//!
//! The image half of what `glyphs.zig` does for fonts, and the same shape: a
//! display list records *which object* an image is, Gjöll knows how to turn
//! that object into pixels, Gleipnir knows how to sample pixels onto a page,
//! and none of the three may depend on the other two. So the wiring lives
//! here, behind `gleipnir.replay.ImageSource`.
//!
//! ## Cached by object number
//!
//! A page that draws the same logo in forty places refers to one object forty
//! times, and a document whose every page carries a letterhead refers to it
//! on every page. Decoding is expensive -- a JPEG is an inverse DCT per block
//! -- so a decoded image is kept until the whole cache is dropped, and the
//! pixels handed to the replay are borrowed from it.
//!
//! Inline images (`BI ... ID ... EI`) have no object number and carry their
//! samples in the display list itself. They are not handled here yet: the
//! display list has them, and reaching them needs the same decode path
//! pointed at `Image.data` instead of at a stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const gleipnir = fenrir.gleipnir;
const image = fenrir.image;
const replay = gleipnir.replay;

const DisplayList = fenrir.gelgja.DisplayList;
const Document = fenrir.Document;

pub const Images = struct {
    gpa: Allocator,
    doc: *Document,
    /// The page's resources, for a `/ColorSpace` named rather than given.
    resources: ?fenrir.Dict = null,

    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

    /// What was skipped, and why, so a page can say what is missing from it
    /// rather than looking finished.
    decoded: u32 = 0,
    codec: u32 = 0,
    malformed: u32 = 0,
    too_big: u32 = 0,
    jpeg_variant: u32 = 0,

    const Entry = union(enum) {
        bitmap: image.Bitmap,
        /// Tried once and could not be decoded. Remembered so a page that
        /// draws the same undecodable image forty times tries once.
        failed: void,
    };

    pub fn init(gpa: Allocator, doc: *Document, resources: ?fenrir.Dict) Images {
        return .{ .gpa = gpa, .doc = doc, .resources = resources };
    }

    pub fn deinit(im: *Images) void {
        var it = im.entries.valueIterator();
        while (it.next()) |e| {
            switch (e.*) {
                .bitmap => |b| b.deinit(im.gpa),
                .failed => {},
            }
        }
        im.entries.deinit(im.gpa);
    }

    pub fn source(im: *Images) replay.ImageSource {
        return .{ .ptr = im, .lookup = lookup };
    }

    fn lookup(ptr: *anyopaque, object: u32, name: []const u8) ?replay.ImageSource.Bitmap {
        _ = name;
        const im: *Images = @ptrCast(@alignCast(ptr));
        if (object == 0) return null;

        if (im.entries.get(object)) |e| {
            return switch (e) {
                .bitmap => |b| .{
                    .pixels = b.pixels,
                    .width = b.width,
                    .height = b.height,
                    .is_mask = b.is_mask,
                },
                .failed => null,
            };
        }

        const bmp = im.decode(object) orelse {
            im.entries.put(im.gpa, object, .failed) catch {};
            return null;
        };
        im.entries.put(im.gpa, object, .{ .bitmap = bmp }) catch {
            bmp.deinit(im.gpa);
            return null;
        };
        im.decoded += 1;
        return .{
            .pixels = bmp.pixels,
            .width = bmp.width,
            .height = bmp.height,
            .is_mask = bmp.is_mask,
        };
    }

    fn decode(im: *Images, object: u32) ?image.Bitmap {
        const obj = im.doc.fetch(.{ .num = object, .gen = 0 }) catch return null;
        const stream = obj.asStream() orelse return null;

        const result = image.decode(
            im.gpa,
            im.doc.arenaAllocator(),
            im.doc,
            stream,
            im.resources,
        ) catch return null;

        return switch (result) {
            .bitmap => |b| b,
            .skipped => |why| {
                switch (why) {
                    .codec => im.codec += 1,
                    .malformed => im.malformed += 1,
                    .too_big => im.too_big += 1,
                    .jpeg_variant => im.jpeg_variant += 1,
                }
                return null;
            },
        };
    }

    /// A one-line account of what did not decode, or nothing when everything
    /// did.
    pub fn report(im: *const Images, out: *std.Io.Writer) void {
        const missing = im.codec + im.malformed + im.too_big + im.jpeg_variant;
        if (im.decoded == 0 and missing == 0) return;
        out.print("         {d} image{s} decoded", .{
            im.decoded,
            if (im.decoded == 1) "" else "s",
        }) catch return;
        if (missing == 0) {
            out.print("\n", .{}) catch {};
            return;
        }
        out.print(", {d} not:", .{missing}) catch return;
        if (im.codec != 0) out.print(" {d} JPX/CCITT/JBIG2", .{im.codec}) catch {};
        if (im.jpeg_variant != 0) out.print(" {d} progressive JPEG", .{im.jpeg_variant}) catch {};
        if (im.malformed != 0) out.print(" {d} malformed", .{im.malformed}) catch {};
        if (im.too_big != 0) out.print(" {d} too large", .{im.too_big}) catch {};
        out.print("\n", .{}) catch {};
    }
};
