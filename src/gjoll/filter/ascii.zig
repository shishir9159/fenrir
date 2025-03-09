//! The three text-safe filters (ISO 32000-2 §7.4.2, §7.4.3, §7.4.5).
//!
//! None of these compress usefully; they exist so that binary data can survive
//! transports that mangle high bytes. They are also the easiest way to make a
//! hand-written test PDF readable.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidAscii85,
    InvalidRunLength,
} || Allocator.Error;

/// `ASCIIHexDecode`: hex digits, whitespace ignored, terminated by `>`. An odd
/// final digit is padded with `0`.
pub fn hexDecode(gpa: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, data.len / 2 + 1);
    errdefer out.deinit(gpa);

    var high: ?u8 = null;
    for (data) |c| {
        if (c == '>') break;
        const digit = std.fmt.charToDigit(c, 16) catch continue;
        if (high) |h| {
            out.appendAssumeCapacity(h << 4 | digit);
            high = null;
        } else {
            high = digit;
        }
    }
    if (high) |h| try out.append(gpa, h << 4);
    return out.toOwnedSlice(gpa);
}

/// `ASCII85Decode`: base-85 in groups of five, `z` for four zero bytes,
/// terminated by `~>`. A leading `<~` is not part of the PDF variant but some
/// producers emit it anyway.
pub fn a85Decode(gpa: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, data.len * 4 / 5 + 4);
    errdefer out.deinit(gpa);

    var input = data;
    if (std.mem.startsWith(u8, input, "<~")) input = input[2..];

    var group: [5]u8 = undefined;
    var count: usize = 0;
    for (input) |c| {
        if (c == '~') break;
        if (std.ascii.isWhitespace(c)) continue;

        if (c == 'z' and count == 0) {
            try out.appendSlice(gpa, &.{ 0, 0, 0, 0 });
            continue;
        }
        if (c < '!' or c > 'u') return error.InvalidAscii85;

        group[count] = c - '!';
        count += 1;
        if (count == 5) {
            try emitGroup(gpa, &out, group, 5);
            count = 0;
        }
    }

    // A partial final group is padded with the maximum digit, and yields one
    // fewer byte than it has digits.
    if (count > 0) {
        if (count == 1) return error.InvalidAscii85;
        for (count..5) |i| group[i] = 84;
        try emitGroup(gpa, &out, group, count);
    }
    return out.toOwnedSlice(gpa);
}

fn emitGroup(gpa: Allocator, out: *std.ArrayList(u8), group: [5]u8, digits: usize) Error!void {
    var value: u32 = 0;
    for (group) |d| value = value *% 85 +% d;

    const bytes = [4]u8{
        @truncate(value >> 24),
        @truncate(value >> 16),
        @truncate(value >> 8),
        @truncate(value),
    };
    try out.appendSlice(gpa, bytes[0 .. digits - 1]);
}

/// `RunLengthDecode`: a length byte, then either a literal run (0..127 means
/// `n + 1` bytes follow) or a repeat (129..255 means the next byte repeated
/// `257 - n` times). 128 ends the stream.
pub fn runLengthDecode(gpa: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, data.len * 2);
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < data.len) {
        const n = data[i];
        i += 1;
        if (n == 128) break;
        if (n < 128) {
            const len = @as(usize, n) + 1;
            if (i + len > data.len) return error.InvalidRunLength;
            try out.appendSlice(gpa, data[i..][0..len]);
            i += len;
        } else {
            if (i >= data.len) return error.InvalidRunLength;
            try out.appendNTimes(gpa, data[i], 257 - @as(usize, n));
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "hex decode" {
    const out = try hexDecode(testing.allocator, "48 65 6C6C6F>");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello", out);
}

test "hex decode pads an odd digit" {
    const out = try hexDecode(testing.allocator, "901FA>");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x90, 0x1f, 0xa0 }, out);
}

test "ascii85 round trip of a known vector" {
    const out = try a85Decode(testing.allocator, "87cURD]i,\"Ebo80~>");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello World!", out);
}

test "ascii85 z shorthand" {
    const out = try a85Decode(testing.allocator, "z~>");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out);
}

test "run length" {
    // Literal run of 3, then 'x' repeated 4 times, then EOD.
    const data = [_]u8{ 2, 'a', 'b', 'c', 253, 'x', 128 };
    const out = try runLengthDecode(testing.allocator, &data);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abcxxxx", out);
}
