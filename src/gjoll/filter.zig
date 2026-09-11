//! The stream filter pipeline (ISO 32000-2 §7.4).
//!
//! This module is deliberately document-free: it takes already-resolved filter
//! names and parameters, so it can be tested on plain byte slices and cannot
//! accidentally reach back into the object graph. `Document.streamData` does
//! the resolving and builds the `Spec` chain.
//!
//! Image codecs (DCT, JPX, CCITT, JBIG2) are *not* decoded here. They produce
//! pixels rather than bytes, which belongs to the rendering layer, and their
//! encoded form is usually what a caller extracting an image actually wants.
//! The chain stops when it reaches one and reports which filter it stopped at.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ascii = @import("filter/ascii.zig");
const lzw = @import("filter/lzw.zig");

pub const jpeg = @import("filter/jpeg.zig");
pub const predictor = @import("filter/predictor.zig");
pub const Predictor = predictor.Params;

pub const Error = error{
    /// Flate rejected the data. `Document` keeps the raw bytes in this case.
    CorruptFlateStream,
} || ascii.Error || lzw.Error || predictor.Error || Allocator.Error;

/// A filter to apply, with its already-resolved `/DecodeParms`.
pub const Spec = struct {
    kind: Kind,
    predictor: Predictor = .identity,
    /// `/EarlyChange`, LZW only. Defaults to 1 per the spec.
    early_change: bool = true,
};

pub const Kind = enum {
    flate,
    lzw,
    ascii_hex,
    ascii_85,
    run_length,
    /// Recognised but passed through: these carry image data, not bytes.
    dct,
    jpx,
    ccitt_fax,
    jbig2,
    /// `/Crypt` with an identity handler, or a filter we do not know.
    unknown,

    /// Maps a `/Filter` name, including the abbreviations that inline images
    /// use (§8.9.7 table 93), onto a kind.
    pub fn fromName(name: []const u8) Kind {
        const table = .{
            .{ "FlateDecode", Kind.flate },
            .{ "Fl", Kind.flate },
            .{ "LZWDecode", Kind.lzw },
            .{ "LZW", Kind.lzw },
            .{ "ASCIIHexDecode", Kind.ascii_hex },
            .{ "AHx", Kind.ascii_hex },
            .{ "ASCII85Decode", Kind.ascii_85 },
            .{ "A85", Kind.ascii_85 },
            .{ "RunLengthDecode", Kind.run_length },
            .{ "RL", Kind.run_length },
            .{ "DCTDecode", Kind.dct },
            .{ "DCT", Kind.dct },
            .{ "JPXDecode", Kind.jpx },
            .{ "CCITTFaxDecode", Kind.ccitt_fax },
            .{ "CCF", Kind.ccitt_fax },
            .{ "JBIG2Decode", Kind.jbig2 },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }

    /// True for codecs whose output is an image, not a byte stream.
    pub fn isImageCodec(k: Kind) bool {
        return switch (k) {
            .dct, .jpx, .ccitt_fax, .jbig2 => true,
            else => false,
        };
    }

    pub fn displayName(k: Kind) []const u8 {
        return switch (k) {
            .flate => "FlateDecode",
            .lzw => "LZWDecode",
            .ascii_hex => "ASCIIHexDecode",
            .ascii_85 => "ASCII85Decode",
            .run_length => "RunLengthDecode",
            .dct => "DCTDecode",
            .jpx => "JPXDecode",
            .ccitt_fax => "CCITTFaxDecode",
            .jbig2 => "JBIG2Decode",
            .unknown => "unknown",
        };
    }

    /// The conventional file extension for an image codec's encoded bytes, so
    /// `fenrir extract` can name what it writes.
    pub fn imageExtension(k: Kind) ?[]const u8 {
        return switch (k) {
            .dct => "jpg",
            .jpx => "jp2",
            .ccitt_fax => "g4",
            .jbig2 => "jbig2",
            else => null,
        };
    }
};

/// Decoded bytes plus a note about where the chain stopped.
pub const Result = struct {
    /// Always heap-allocated and owned by the caller, even when no filter ran.
    data: []u8,
    /// Set when decoding halted at an image codec; `data` then holds that
    /// codec's still-encoded bytes.
    stopped_at: ?Kind = null,

    pub fn deinit(r: Result, gpa: Allocator) void {
        gpa.free(r.data);
    }
};

/// Runs `chain` over `raw` in order. An empty chain copies the input, so the
/// caller always owns the result and never has to branch on ownership.
pub fn decode(gpa: Allocator, raw: []const u8, chain: []const Spec) Error!Result {
    var current = try gpa.dupe(u8, raw);
    errdefer gpa.free(current);

    for (chain) |spec| {
        if (spec.kind.isImageCodec()) {
            return .{ .data = current, .stopped_at = spec.kind };
        }

        const decoded: []u8 = switch (spec.kind) {
            .flate => try inflate(gpa, current),
            .lzw => try lzw.decode(gpa, current, spec.early_change),
            .ascii_hex => try ascii.hexDecode(gpa, current),
            .ascii_85 => try ascii.a85Decode(gpa, current),
            .run_length => try ascii.runLengthDecode(gpa, current),
            // An unrecognised filter leaves the bytes alone rather than
            // failing the whole object.
            .unknown => continue,
            .dct, .jpx, .ccitt_fax, .jbig2 => unreachable,
        };
        gpa.free(current);
        current = decoded;

        if (!spec.predictor.isIdentity()) {
            const undone = try predictor.apply(gpa, current, spec.predictor);
            gpa.free(current);
            current = undone;
        }
    }
    return .{ .data = current };
}

/// Flate, with the two tolerances every PDF reader needs: a truncated stream
/// keeps whatever was recovered, and a missing zlib header falls back to raw
/// deflate (some producers emit one, some the other).
fn inflate(gpa: Allocator, data: []const u8) Error![]u8 {
    if (inflateContainer(gpa, data, .zlib)) |out| return out else |_| {}

    // A valid zlib header has CMF/FLG such that the pair is a multiple of 31;
    // if it does not look like one, the stream is probably raw deflate.
    if (inflateContainer(gpa, data, .raw)) |out| return out else |_| {}

    // Some writers prepend junk before the zlib header. Skipping a byte is a
    // cheap last resort that rescues a surprising number of files.
    if (data.len > 1) {
        if (inflateContainer(gpa, data[1..], .zlib)) |out| return out else |_| {}
    }
    return error.CorruptFlateStream;
}

fn inflateContainer(
    gpa: Allocator,
    data: []const u8,
    container: std.compress.flate.Container,
) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var stream: std.compress.flate.Decompress = .init(&in, container, &window);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    stream.reader.appendRemainingUnlimited(gpa, &out) catch |err| switch (err) {
        // Truncated or corrupt tail: keep the prefix we managed to decode,
        // which is often the whole useful part of the object.
        error.ReadFailed => if (out.items.len == 0) return error.CorruptFlateStream,
        else => return err,
    };
    return out.toOwnedSlice(gpa);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "filter names and abbreviations" {
    try testing.expectEqual(Kind.flate, Kind.fromName("FlateDecode"));
    try testing.expectEqual(Kind.flate, Kind.fromName("Fl"));
    try testing.expectEqual(Kind.dct, Kind.fromName("DCTDecode"));
    try testing.expectEqual(Kind.unknown, Kind.fromName("Crypt"));
    try testing.expect(Kind.jbig2.isImageCodec());
    try testing.expect(!Kind.flate.isImageCodec());
}

test "an empty chain still yields owned bytes" {
    const result = try decode(testing.allocator, "abc", &.{});
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("abc", result.data);
    try testing.expectEqual(@as(?Kind, null), result.stopped_at);
}

test "ascii85 through the chain" {
    const result = try decode(testing.allocator, "87cURD]i,\"Ebo80~>", &.{
        .{ .kind = .ascii_85 },
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello World!", result.data);
}

test "filters chain in order" {
    // "hi" -> hex "6869" -> that text ASCII85-encoded. Decoding runs the
    // chain left to right, undoing the outermost encoding first.
    const result = try decode(testing.allocator, "2E3TT~>", &.{
        .{ .kind = .ascii_85 },
        .{ .kind = .ascii_hex },
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", result.data);
}

/// Wraps `payload` in a zlib stream containing a single stored (uncompressed)
/// deflate block. Hand-building one keeps the filter tests independent of the
/// compressor, and a stored block is the shape a "compressed" xref stream
/// takes when a producer gives up on compression.
fn storedZlib(gpa: Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &.{ 0x78, 0x01 }); // CM=deflate, no preset dict
    try out.append(gpa, 0x01); // BFINAL=1, BTYPE=stored

    const len: u16 = @intCast(payload.len);
    const nlen: u16 = ~len;
    try out.appendSlice(gpa, &.{ @truncate(len), @truncate(len >> 8) });
    try out.appendSlice(gpa, &.{ @truncate(nlen), @truncate(nlen >> 8) });
    try out.appendSlice(gpa, payload);

    const sum = std.hash.Adler32.hash(payload);
    try out.appendSlice(gpa, &.{
        @truncate(sum >> 24), @truncate(sum >> 16),
        @truncate(sum >> 8),  @truncate(sum),
    });
    return out.toOwnedSlice(gpa);
}

test "flate round trip" {
    const payload = "the quick brown fox jumps over the lazy dog";

    const compressed = try storedZlib(testing.allocator, payload);
    defer testing.allocator.free(compressed);

    const result = try decode(testing.allocator, compressed, &.{.{ .kind = .flate }});
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings(payload, result.data);
}

test "flate followed by a png predictor" {
    // Two three-byte rows: None, then Up.
    const rows = [_]u8{ 0, 10, 20, 30, 2, 1, 2, 3 };
    const compressed = try storedZlib(testing.allocator, &rows);
    defer testing.allocator.free(compressed);

    const result = try decode(testing.allocator, compressed, &.{.{
        .kind = .flate,
        .predictor = .{ .kind = .png, .columns = 3 },
    }});
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 11, 22, 33 }, result.data);
}

test "the chain stops at an image codec" {
    const result = try decode(testing.allocator, "\xff\xd8\xff", &.{
        .{ .kind = .dct },
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(?Kind, .dct), result.stopped_at);
    try testing.expectEqualStrings("\xff\xd8\xff", result.data);
}

test {
    _ = jpeg;
    _ = predictor;
}
