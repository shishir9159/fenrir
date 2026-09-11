//! An image XObject, decoded to pixels a rasteriser can sample.
//!
//! The last thing between a rendered page and the real one. Everything else
//! on a page is geometry; an image is the one place a PDF carries samples,
//! and without this a document's figures, photographs and scans come out as
//! white rectangles -- which does not look like a missing feature, it looks
//! like a page that happens to be blank there.
//!
//! ## What it has to get through
//!
//! Four things stand between the stream and a pixel, and all four are
//! independent:
//!
//! * **The filter.** `/FlateDecode` and friends produce the samples
//!   directly; `/DCTDecode` produces a JPEG that `filter/jpeg.zig` decodes.
//!   `filter.decode` already stops at an image codec and says which, so this
//!   only has to notice.
//! * **The packing.** One, two, four, eight or sixteen bits a component, rows
//!   padded to byte boundaries. A four-bit indexed image is two pixels a byte
//!   and a sixteen-bit one is big-endian.
//! * **The colour space.** `content/color.zig` already knows all of them --
//!   including `/Indexed` palettes and `/Separation` tint transforms -- so
//!   this converts through `ColorSpace.toColor` and fast-paths the three
//!   device spaces at eight bits, which is the overwhelming majority.
//! * **The transparency.** `/ImageMask` makes the image a stencil painted
//!   with the fill colour; `/SMask` is a second greyscale image that supplies
//!   alpha and need not be the same size.
//!
//! ## What it does not do
//!
//! `/JPXDecode` (JPEG 2000), `/CCITTFaxDecode` and `/JBIG2Decode` are not
//! decoded. The first is a wavelet codec of its own; the other two are
//! bilevel codecs that a scanned document uses and a born-digital one never
//! does. Each is counted and skipped rather than approximated.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const color = @import("content/color.zig");
const filter = @import("filter.zig");
const jpeg = @import("filter/jpeg.zig");
const object = @import("object.zig");
const paint = @import("../gelgja/paint.zig");

const ColorSpace = color.ColorSpace;
const Dict = object.Dict;
const Object = object.Object;
const Stream = object.Stream;

pub const Error = Document.Error;

/// A decoded image: straight (not premultiplied) RGBA, eight bits a channel.
///
/// RGBA and not the source's own layout, because the rasteriser samples it
/// per device pixel and a branch per sample on colour space and bit depth
/// would cost more than the conversion does once.
pub const Bitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    /// `/ImageMask`: `pixels` is still RGBA, but only the alpha means
    /// anything -- the colour comes from the fill in force at the `Do`.
    is_mask: bool = false,

    pub fn deinit(b: Bitmap, gpa: Allocator) void {
        gpa.free(b.pixels);
    }
};

/// Why an image was not decoded, for the report at the end of a render.
pub const Skipped = enum {
    /// `/JPXDecode`, `/CCITTFaxDecode` or `/JBIG2Decode`.
    codec,
    /// A progressive or twelve-bit JPEG.
    jpeg_variant,
    /// Dimensions or a bit depth that make no sense.
    malformed,
    /// Bigger than `max_pixels`.
    too_big,
};

pub const Result = union(enum) {
    bitmap: Bitmap,
    skipped: Skipped,
};

/// A ceiling on one decoded image, in pixels. Four bytes each, so this is a
/// quarter of a gigabyte at the limit.
pub const max_pixels: u64 = 64 << 20;

/// Decodes an image XObject.
///
/// `arena` is the document's, for the colour space; `gpa` owns the returned
/// pixels. Two allocators because the colour space outlives this call by
/// exactly as long as the document does and the pixels do not.
pub fn decode(
    gpa: Allocator,
    arena: Allocator,
    doc: *Document,
    stream: *const Stream,
    resources: ?Dict,
) Error!Result {
    const dict = stream.dict;

    const width = intOf(doc, dict, &.{ "Width", "W" }) orelse 0;
    const height = intOf(doc, dict, &.{ "Height", "H" }) orelse 0;
    if (width <= 0 or height <= 0) return .{ .skipped = .malformed };
    if (@as(u64, @intCast(width)) * @as(u64, @intCast(height)) > max_pixels) {
        return .{ .skipped = .too_big };
    }
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    const is_mask = boolOf(doc, dict, &.{ "ImageMask", "IM" }) orelse false;
    var bpc: u32 = @intCast(intOf(doc, dict, &.{ "BitsPerComponent", "BPC" }) orelse 8);
    if (is_mask) bpc = 1;
    switch (bpc) {
        1, 2, 4, 8, 16 => {},
        else => return .{ .skipped = .malformed },
    }

    const data = doc.streamData(stream) catch return .{ .skipped = .malformed };

    if (data.stopped_at) |kind| {
        switch (kind) {
            .dct => {
                const img = jpeg.decode(gpa, data.data) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return .{ .skipped = .jpeg_variant },
                };
                defer img.deinit(gpa);
                return fromJpeg(gpa, arena, doc, dict, resources, img, w, h);
            },
            else => return .{ .skipped = .codec },
        }
    }

    if (is_mask) return maskFrom(gpa, doc, dict, data.data, w, h);

    const space = try loadSpace(arena, doc, dict, resources) orelse ColorSpace.device_gray;
    const n = @max(1, @as(u32, space.components));

    var decode_array: [color.max_components * 2]f64 = undefined;
    const decodes = try readDecode(doc, dict, n, &decode_array);

    const pixels = try samplesToRgba(gpa, data.data, w, h, bpc, n, &space, decodes);
    var bmp: Bitmap = .{ .pixels = pixels, .width = w, .height = h };
    errdefer bmp.deinit(gpa);

    try applySoftMask(gpa, arena, doc, dict, resources, &bmp);
    return .{ .bitmap = bmp };
}

/// A JPEG's samples, through the PDF's colour space rather than the file's.
///
/// The two can disagree, and the PDF wins: a four-component JPEG with no
/// Adobe marker is CMYK if the `/ColorSpace` says so, and an `/Indexed` image
/// can even be DCT-coded. The one thing taken from the JPEG is its own
/// YCbCr-to-RGB step, which is part of the codec and not of the page.
fn fromJpeg(
    gpa: Allocator,
    arena: Allocator,
    doc: *Document,
    dict: Dict,
    resources: ?Dict,
    img: jpeg.Image,
    want_w: u32,
    want_h: u32,
) Error!Result {
    const space = try loadSpace(arena, doc, dict, resources) orelse switch (img.components) {
        1 => ColorSpace.device_gray,
        4 => ColorSpace.device_cmyk,
        else => ColorSpace.device_rgb,
    };

    var decode_array: [color.max_components * 2]f64 = undefined;
    const decodes = try readDecode(doc, dict, img.components, &decode_array);

    // Adobe's four-component JPEGs store CMYK inverted (§7.4.8 and every
    // implementation since): a value of 255 means no ink. The `/Decode
    // [1 0 1 0 1 0 1 0]` such files usually carry says the same thing, so
    // applying both would cancel out -- the inversion is folded into the
    // decode array here rather than done twice.
    const invert_cmyk = img.components == 4 and img.adobe_transform != null and decodes == null;

    const n: u32 = img.components;
    const pixels = try gpa.alloc(u8, @as(usize, want_w) * want_h * 4);
    errdefer gpa.free(pixels);

    var comps: [color.max_components]f64 = undefined;
    var y: u32 = 0;
    while (y < want_h) : (y += 1) {
        // A JPEG is allowed to be a different size from the dictionary, and a
        // few real files are off by a pixel. Clamping is what every other
        // reader does.
        const sy = @min(img.height - 1, y * img.height / want_h);
        var x: u32 = 0;
        while (x < want_w) : (x += 1) {
            const sx = @min(img.width - 1, x * img.width / want_w);
            const src = (@as(usize, sy) * img.width + sx) * n;
            for (0..n) |i| {
                var v = @as(f64, @floatFromInt(img.pixels[src + i])) / 255.0;
                if (invert_cmyk) v = 1.0 - v;
                comps[i] = applyDecode(decodes, i, v, 1.0);
            }
            writeRgba(pixels, (@as(usize, y) * want_w + x) * 4, space.toColor(comps[0..n]));
        }
    }

    var bmp: Bitmap = .{ .pixels = pixels, .width = want_w, .height = want_h };
    errdefer bmp.deinit(gpa);
    try applySoftMask(gpa, arena, doc, dict, resources, &bmp);
    return .{ .bitmap = bmp };
}

/// `/ImageMask`: one bit a pixel, and the bit says whether to paint.
///
/// Zero paints by default (§8.9.6.2) -- the opposite of what a coverage
/// buffer usually means -- and `/Decode [1 0]` flips it. The colour is the
/// fill in force at the `Do`, which the rasteriser supplies, so only alpha is
/// filled in here.
fn maskFrom(
    gpa: Allocator,
    doc: *Document,
    dict: Dict,
    data: []const u8,
    w: u32,
    h: u32,
) Error!Result {
    var one_paints = false;
    if (try doc.get(dict, "Decode") orelse try doc.get(dict, "D")) |v| {
        const arr = (try doc.resolve(v)).asArray() orelse &.{};
        if (arr.len >= 1) {
            const first = (try doc.resolve(arr[0])).asNumber() orelse 0;
            one_paints = first == 1;
        }
    }

    const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(pixels);

    const row_bytes = (@as(usize, w) + 7) / 8;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const at = y * row_bytes + x / 8;
            const bit: u1 = if (at < data.len)
                @truncate(data[at] >> @intCast(7 - (x % 8)))
            else
                1;
            const paints = if (one_paints) bit == 1 else bit == 0;
            const o = (@as(usize, y) * w + x) * 4;
            pixels[o + 0] = 255;
            pixels[o + 1] = 255;
            pixels[o + 2] = 255;
            pixels[o + 3] = if (paints) 255 else 0;
        }
    }
    return .{ .bitmap = .{ .pixels = pixels, .width = w, .height = h, .is_mask = true } };
}

/// Unpacked samples through the colour space.
fn samplesToRgba(
    gpa: Allocator,
    data: []const u8,
    w: u32,
    h: u32,
    bpc: u32,
    n: u32,
    space: *const ColorSpace,
    decodes: ?[]const f64,
) Allocator.Error![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    // Rows are padded to a byte boundary (§8.9.5.1), which is why this is not
    // one running bit offset across the whole image.
    const row_bits = @as(usize, w) * n * bpc;
    const row_bytes = (row_bits + 7) / 8;
    const max: f64 = @floatFromInt((@as(u32, 1) << @intCast(bpc)) - 1);

    // `/Indexed` components are palette *indices*, not fractions, so an
    // absent decode array maps a sample back to itself rather than to a
    // fraction. Every other space wants 0..1.
    const default_hi: f64 = if (space.kind == .indexed) max else 1.0;

    // The common case, by a wide margin: eight bits, a device space, no
    // decode array. Straight through, no float arithmetic at all.
    const fast = bpc == 8 and decodes == null and switch (space.kind) {
        .gray => n == 1,
        .rgb => n == 3,
        else => false,
    };

    var comps: [color.max_components]f64 = undefined;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * row_bytes;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (@as(usize, y) * w + x) * 4;
            if (fast) {
                const src = row + @as(usize, x) * n;
                if (src + n > data.len) break;
                pixels[o + 0] = data[src];
                pixels[o + 1] = if (n == 3) data[src + 1] else data[src];
                pixels[o + 2] = if (n == 3) data[src + 2] else data[src];
                pixels[o + 3] = 255;
                continue;
            }
            for (0..n) |i| {
                const index = (@as(usize, x) * n + i) * bpc;
                const raw = readBits(data, row, index, bpc);
                comps[i] = applyDecode(decodes, i, @as(f64, @floatFromInt(raw)) / max, default_hi);
            }
            writeRgba(pixels, o, space.toColor(comps[0..n]));
        }
    }
    return pixels;
}

/// `bpc` bits at bit offset `index` within the row starting at byte `row`.
fn readBits(data: []const u8, row: usize, index: usize, bpc: u32) u32 {
    switch (bpc) {
        8 => {
            const at = row + index / 8;
            return if (at < data.len) data[at] else 0;
        },
        16 => {
            const at = row + index / 8;
            if (at + 1 >= data.len) return 0;
            return (@as(u32, data[at]) << 8) | data[at + 1];
        },
        else => {
            var v: u32 = 0;
            var i: usize = 0;
            while (i < bpc) : (i += 1) {
                const bit = index + i;
                const at = row + bit / 8;
                const b: u1 = if (at < data.len)
                    @truncate(data[at] >> @intCast(7 - (bit % 8)))
                else
                    0;
                v = (v << 1) | b;
            }
            return v;
        },
    }
}

/// `/Decode` remaps a sample onto the range its colour space wants
/// (§8.9.5.2).
///
/// `v` is always the raw sample divided by its maximum, so it is in `[0, 1]`
/// whatever the bit depth. `default_hi` is what the space wants when there is
/// no decode array: one for every space whose components are fractions, and
/// the sample maximum for `/Indexed`, whose components are palette indices
/// and whose default decode is therefore `[0, 2ⁿ − 1]`.
fn applyDecode(decodes: ?[]const f64, i: usize, v: f64, default_hi: f64) f64 {
    const d = decodes orelse return v * default_hi;
    if (i * 2 + 1 >= d.len) return v * default_hi;
    const lo = d[i * 2];
    const hi = d[i * 2 + 1];
    return lo + v * (hi - lo);
}

fn writeRgba(pixels: []u8, at: usize, c: paint.Color) void {
    pixels[at + 0] = toByte(c.r);
    pixels[at + 1] = toByte(c.g);
    pixels[at + 2] = toByte(c.b);
    pixels[at + 3] = toByte(c.a);
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
}

/// `/SMask`: a greyscale image whose samples are this one's alpha.
///
/// Its size need not match, so it is sampled rather than indexed -- a
/// quarter-resolution mask over a full-resolution photograph is common and
/// perfectly legal.
fn applySoftMask(
    gpa: Allocator,
    arena: Allocator,
    doc: *Document,
    dict: Dict,
    resources: ?Dict,
    bmp: *Bitmap,
) Error!void {
    const entry = try doc.get(dict, "SMask") orelse return;
    const resolved = try doc.resolve(entry);
    const stream = resolved.asStream() orelse return;

    const result = decode(gpa, arena, doc, stream, resources) catch return;
    const mask = switch (result) {
        .bitmap => |b| b,
        .skipped => return,
    };
    defer mask.deinit(gpa);
    if (mask.width == 0 or mask.height == 0) return;

    var y: u32 = 0;
    while (y < bmp.height) : (y += 1) {
        const my = @min(mask.height - 1, y * mask.height / bmp.height);
        var x: u32 = 0;
        while (x < bmp.width) : (x += 1) {
            const mx = @min(mask.width - 1, x * mask.width / bmp.width);
            // The mask is greyscale, so any of its colour channels is its
            // value; red is as good as the others and needs no averaging.
            const a = mask.pixels[(@as(usize, my) * mask.width + mx) * 4];
            const o = (@as(usize, y) * bmp.width + x) * 4 + 3;
            bmp.pixels[o] = @intCast((@as(u32, bmp.pixels[o]) * a + 127) / 255);
        }
    }
}

fn loadSpace(
    arena: Allocator,
    doc: *Document,
    dict: Dict,
    resources: ?Dict,
) Error!?ColorSpace {
    const entry = try doc.get(dict, "ColorSpace") orelse
        try doc.get(dict, "CS") orelse return null;
    return color.load(arena, doc, entry, resources, 0);
}

fn readDecode(doc: *Document, dict: Dict, n: u32, out: *[color.max_components * 2]f64) Error!?[]f64 {
    const entry = try doc.get(dict, "Decode") orelse
        try doc.get(dict, "D") orelse return null;
    const arr = (try doc.resolve(entry)).asArray() orelse return null;
    const want = @min(@as(usize, n) * 2, out.len);
    if (arr.len < want) return null;
    for (0..want) |i| {
        out[i] = (try doc.resolve(arr[i])).asNumber() orelse 0;
    }
    return out[0..want];
}

fn intOf(doc: *Document, dict: Dict, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        const v = (doc.get(dict, key) catch null) orelse continue;
        const r = doc.resolve(v) catch continue;
        if (r.asInt()) |n| return n;
    }
    return null;
}

fn boolOf(doc: *Document, dict: Dict, keys: []const []const u8) ?bool {
    for (keys) |key| {
        const v = (doc.get(dict, key) catch null) orelse continue;
        const r = doc.resolve(v) catch continue;
        if (r.asBool()) |b| return b;
    }
    return null;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "bits are read most significant first, and rows are byte aligned" {
    // The packing rule that decides whether a 1-bit image comes out as the
    // picture or as diagonal stripes.
    const data = [_]u8{ 0b1011_0000, 0b0100_0000 };

    // Four 1-bit samples from the first row: 1, 0, 1, 1.
    try testing.expectEqual(@as(u32, 1), readBits(&data, 0, 0, 1));
    try testing.expectEqual(@as(u32, 0), readBits(&data, 0, 1, 1));
    try testing.expectEqual(@as(u32, 1), readBits(&data, 0, 2, 1));
    try testing.expectEqual(@as(u32, 1), readBits(&data, 0, 3, 1));

    // Two 4-bit samples: 0b1011 and 0b0000.
    try testing.expectEqual(@as(u32, 0b1011), readBits(&data, 0, 0, 4));
    try testing.expectEqual(@as(u32, 0), readBits(&data, 0, 4, 4));

    // A second row starting at byte 1, which is what "byte aligned" means.
    try testing.expectEqual(@as(u32, 0), readBits(&data, 1, 0, 1));
    try testing.expectEqual(@as(u32, 1), readBits(&data, 1, 1, 1));

    // Eight and sixteen bits take their own paths.
    try testing.expectEqual(@as(u32, 0b1011_0000), readBits(&data, 0, 0, 8));
    try testing.expectEqual(@as(u32, 0b1011_0000_0100_0000), readBits(&data, 0, 0, 16));

    // Past the end is zero rather than a crash: a truncated image should show
    // what it has.
    try testing.expectEqual(@as(u32, 0), readBits(&data, 0, 900, 8));
}

test "a device RGB image at eight bits goes straight through" {
    const gpa = testing.allocator;
    const data = [_]u8{ 255, 0, 0, 0, 255, 0 };
    const space = ColorSpace.device_rgb;

    const pixels = try samplesToRgba(gpa, &data, 2, 1, 8, 3, &space, null);
    defer gpa.free(pixels);

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixels[0..4].*);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixels[4..8].*);
}

test "a greyscale image fills all three channels" {
    const gpa = testing.allocator;
    const data = [_]u8{ 0, 128, 255 };
    const space = ColorSpace.device_gray;

    const pixels = try samplesToRgba(gpa, &data, 3, 1, 8, 1, &space, null);
    defer gpa.free(pixels);

    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixels[0..4].*);
    try testing.expectEqual([4]u8{ 128, 128, 128, 255 }, pixels[4..8].*);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixels[8..12].*);
}

test "a four-bit greyscale image unpacks two pixels a byte" {
    const gpa = testing.allocator;
    // 0x0F, then 0x80: black, white, half, black.
    const data = [_]u8{ 0x0F, 0x80 };
    const space = ColorSpace.device_gray;

    const pixels = try samplesToRgba(gpa, &data, 4, 1, 4, 1, &space, null);
    defer gpa.free(pixels);

    try testing.expectEqual(@as(u8, 0), pixels[0]);
    try testing.expectEqual(@as(u8, 255), pixels[4]);
    // 8 of 15 is just over half.
    try testing.expect(pixels[8] > 128 and pixels[8] < 145);
    try testing.expectEqual(@as(u8, 0), pixels[12]);
}
