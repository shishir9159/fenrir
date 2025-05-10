//! A PNG writer, so that what this renderer produces can be looked at.
//!
//! Sixty lines rather than a dependency, because the format's minimum viable
//! subset really is this small: a signature, three chunks, and a zlib stream
//! that `std.compress.flate` already knows how to produce. Nothing here reads
//! PNG -- decoding is a different and much larger problem, and when a PDF
//! embeds an image it will not be a PNG anyway.
//!
//! Its first job is the CPU oracle's output. Its second, later, is the
//! regression suite already planned for the page renderer: render a page,
//! write a PNG, diff it against `mutool draw` or `pdftoppm`. That is the only
//! test that can catch a renderer being subtly, consistently wrong, and it
//! needs a format both sides can read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Writer.Error || Allocator.Error;

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// Writes 8-bit RGBA, one image, no interlacing. `rgba` is `width * height`
/// pixels of four bytes, top row first.
pub fn write(gpa: Allocator, w: *Writer, rgba: []const u8, width: u32, height: u32) Error!void {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);

    var idat: Writer.Allocating = try .initCapacity(gpa, 4096);
    defer idat.deinit();
    try deflateScanlines(gpa, &idat.writer, rgba, width, height);

    try w.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bits per channel
    ihdr[9] = 6; // colour type 6: truecolour with alpha
    ihdr[10] = 0; // compression: deflate, the only one defined
    ihdr[11] = 0; // filter method: the only one defined
    ihdr[12] = 0; // no interlacing
    try chunk(w, "IHDR", &ihdr);

    try chunk(w, "IDAT", idat.written());
    try chunk(w, "IEND", "");
}

fn chunk(w: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);

    // The CRC covers the type and the data but not the length, which is the
    // one detail of this format that is easy to get wrong and impossible to
    // notice without a decoder.
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

fn deflateScanlines(
    gpa: Allocator,
    out: *Writer,
    rgba: []const u8,
    width: u32,
    height: u32,
) Error!void {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var zlib: std.compress.flate.Compress = try .init(out, window, .zlib, .default);
    const w = &zlib.writer;

    const stride = @as(usize, width) * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        // Filter type 0, None. Up (2) would compress a flat UI far better,
        // and choosing per scanline better still, but every byte of that
        // belongs with the regression suite that will care about file size,
        // not with the first image this renderer ever produced.
        try w.writeByte(0);
        try w.writeAll(rgba[y * stride ..][0..stride]);
    }
    try zlib.finish();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the header describes an 8-bit RGBA image of the right size" {
    const gpa = testing.allocator;
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }; // two pixels

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &rgba, 2, 1);

    const bytes = out.written();
    try testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    // Length, type, then the fields.
    try testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, bytes[8..12], .big));
    try testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[16..20], .big));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[20..24], .big));
    try testing.expectEqual(@as(u8, 8), bytes[24]);
    try testing.expectEqual(@as(u8, 6), bytes[25]);
    try testing.expect(std.mem.endsWith(u8, bytes, "\x00\x00\x00\x00IEND\xae\x42\x60\x82"));
}

test "the pixels survive the round trip through zlib" {
    // The test that makes this file trustworthy: not that it produced bytes,
    // but that a decoder gets back exactly what went in. std has the inflater,
    // so the scanlines can be checked without a PNG library.
    const gpa = testing.allocator;

    var rgba: [16 * 4 * 4]u8 = undefined;
    for (&rgba, 0..) |*b, i| b.* = @truncate(i * 7);

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &rgba, 16, 4);

    // Walk the chunks to find IDAT rather than assuming its offset.
    const bytes = out.written();
    var i: usize = 8;
    var idat: []const u8 = &.{};
    while (i + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const kind = bytes[i + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "IDAT")) idat = bytes[i + 8 ..][0..len];
        i += 12 + len;
    }
    try testing.expect(idat.len > 0);

    var reader: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &window);

    var raw: Writer.Allocating = .init(gpa);
    defer raw.deinit();
    _ = try inflate.reader.streamRemaining(&raw.writer);

    const got = raw.written();
    try testing.expectEqual(@as(usize, 4 * (1 + 16 * 4)), got.len);
    var y: usize = 0;
    while (y < 4) : (y += 1) {
        const row = got[y * 65 ..][0..65];
        try testing.expectEqual(@as(u8, 0), row[0]); // filter: None
        try testing.expectEqualSlices(u8, rgba[y * 64 ..][0..64], row[1..]);
    }
}
