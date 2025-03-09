//! Predictors applied *after* Flate or LZW decoding (ISO 32000-2 §7.4.4.4).
//!
//! Predictors are the single most commonly overlooked part of PDF decoding:
//! cross-reference streams almost always use `/Predictor 12`, so a reader that
//! skips them cannot even find its own objects.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Row length would overflow, or the data is not a whole number of rows.
    MalformedPredictorData,
} || Allocator.Error;

/// Values of `/Predictor` in a `/DecodeParms` dictionary.
pub const Kind = enum(u8) {
    none = 1,
    tiff = 2,
    /// 10..15 select a fixed PNG filter for every row, but the per-row filter
    /// byte is present regardless, so all of them decode identically.
    png = 10,
    _,

    pub fn fromInt(v: i64) Kind {
        return if (v >= 10) .png else if (v == 2) .tiff else .none;
    }
};

pub const Params = struct {
    kind: Kind = .none,
    /// `/Colors`: samples per pixel.
    colors: u32 = 1,
    /// `/BitsPerComponent`.
    bits: u32 = 8,
    /// `/Columns`: samples per row.
    columns: u32 = 1,

    pub const identity: Params = .{};

    pub fn isIdentity(p: Params) bool {
        return p.kind == .none;
    }

    /// Bytes per pixel, rounded up; the PNG filters address whole bytes.
    fn bytesPerPixel(p: Params) usize {
        return @max(1, (p.colors * p.bits + 7) / 8);
    }

    /// Bytes per row, rounded up.
    fn bytesPerRow(p: Params) usize {
        return (@as(usize, p.colors) * p.bits * p.columns + 7) / 8;
    }
};

/// Applies `params` to `data`, returning freshly allocated bytes. The input is
/// never modified, and the caller owns the result.
pub fn apply(gpa: Allocator, data: []const u8, params: Params) Error![]u8 {
    return switch (params.kind) {
        .none => gpa.dupe(u8, data),
        .tiff => tiff(gpa, data, params),
        .png, _ => png(gpa, data, params),
    };
}

/// PNG predictors: each row is prefixed by a filter-type byte and refers back
/// to the *decoded* previous row.
fn png(gpa: Allocator, data: []const u8, params: Params) Error![]u8 {
    const row_len = params.bytesPerRow();
    const bpp = params.bytesPerPixel();
    if (row_len == 0) return error.MalformedPredictorData;

    const rows = data.len / (row_len + 1);
    const out = try gpa.alloc(u8, rows * row_len);
    errdefer gpa.free(out);

    // The row before the first is defined to be all zeroes.
    var prev: []const u8 = &.{};
    var i: usize = 0;
    var o: usize = 0;
    while (i + row_len < data.len) : (i += row_len + 1) {
        const tag = data[i];
        const src = data[i + 1 ..][0..row_len];
        const dst = out[o..][0..row_len];
        o += row_len;

        switch (tag) {
            0 => @memcpy(dst, src), // None
            1 => for (0..row_len) |x| { // Sub
                const left = if (x >= bpp) dst[x - bpp] else 0;
                dst[x] = src[x] +% left;
            },
            2 => for (0..row_len) |x| { // Up
                const up = if (prev.len == row_len) prev[x] else 0;
                dst[x] = src[x] +% up;
            },
            3 => for (0..row_len) |x| { // Average
                const left: u16 = if (x >= bpp) dst[x - bpp] else 0;
                const up: u16 = if (prev.len == row_len) prev[x] else 0;
                dst[x] = src[x] +% @as(u8, @truncate((left + up) / 2));
            },
            4 => for (0..row_len) |x| { // Paeth
                const left: u8 = if (x >= bpp) dst[x - bpp] else 0;
                const up: u8 = if (prev.len == row_len) prev[x] else 0;
                const up_left: u8 = if (x >= bpp and prev.len == row_len) prev[x - bpp] else 0;
                dst[x] = src[x] +% paeth(left, up, up_left);
            },
            // An unknown filter tag means the stream is corrupt. Copy the row
            // through so the caller still gets something to look at.
            else => @memcpy(dst, src),
        }
        prev = dst;
    }
    return out;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// TIFF predictor 2: horizontal differencing against the previous sample in
/// the same row. Only the 8-bit case is common enough to matter; other depths
/// pass through unchanged rather than producing subtly wrong pixels.
fn tiff(gpa: Allocator, data: []const u8, params: Params) Error![]u8 {
    const out = try gpa.dupe(u8, data);
    errdefer gpa.free(out);
    if (params.bits != 8) return out;

    const row_len = params.bytesPerRow();
    if (row_len == 0) return out;
    const colors: usize = @max(1, params.colors);

    var start: usize = 0;
    while (start + row_len <= out.len) : (start += row_len) {
        const row = out[start..][0..row_len];
        var x: usize = colors;
        while (x < row_len) : (x += 1) row[x] = row[x] +% row[x - colors];
    }
    return out;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "png Up predictor" {
    // Two rows of three bytes: the first uses None, the second uses Up.
    const data = [_]u8{ 0, 10, 20, 30, 2, 1, 2, 3 };
    const out = try apply(testing.allocator, &data, .{ .kind = .png, .columns = 3 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 11, 22, 33 }, out);
}

test "png Sub predictor" {
    const data = [_]u8{ 1, 10, 5, 5 };
    const out = try apply(testing.allocator, &data, .{ .kind = .png, .columns = 3 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 10, 15, 20 }, out);
}

test "tiff horizontal differencing" {
    const data = [_]u8{ 10, 5, 5 };
    const out = try apply(testing.allocator, &data, .{ .kind = .tiff, .columns = 3 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 10, 15, 20 }, out);
}

test "identity predictor copies" {
    const data = [_]u8{ 1, 2, 3 };
    const out = try apply(testing.allocator, &data, .identity);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &data, out);
}
