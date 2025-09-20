//! `LZWDecode` (ISO 32000-2 §7.4.4).
//!
//! The TIFF variant of LZW: MSB-first codes that grow from 9 to 12 bits, code
//! 256 clears the table and 257 ends the stream. `/EarlyChange` (default 1)
//! makes the width grow one code sooner than the table strictly requires --
//! a quirk inherited from TIFF that must be honoured to stay in sync.
//!
//! Superseded by Flate in 1996, but plenty of long-lived documents still use it.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidLzwCode,
    LzwTableOverflow,
} || Allocator.Error;

const clear_code = 256;
const eod_code = 257;
const first_dynamic = 258;
const max_codes = 4096;

/// Each entry is a prefix code plus one byte, so a sequence is reconstructed by
/// walking backwards through the table. Storing it this way avoids allocating
/// a growable buffer per entry.
const Entry = struct {
    prev: u16,
    byte: u8,
    len: u16,
};

pub fn decode(gpa: Allocator, data: []const u8, early_change: bool) Error![]u8 {
    var table: [max_codes]Entry = undefined;
    for (0..256) |i| table[i] = .{ .prev = 0xffff, .byte = @intCast(i), .len = 1 };

    var out: std.ArrayList(u8) = try .initCapacity(gpa, data.len * 3);
    errdefer out.deinit(gpa);

    var next_code: u16 = first_dynamic;
    var code_width: u5 = 9;
    var prev_code: ?u16 = null;

    var bits: u32 = 0;
    var bit_count: u5 = 0;
    var i: usize = 0;

    while (true) {
        // Refill to at least `code_width` bits.
        while (bit_count < code_width) {
            if (i >= data.len) return out.toOwnedSlice(gpa);
            bits = bits << 8 | data[i];
            bit_count += 8;
            i += 1;
        }
        bit_count -= code_width;
        const code: u16 = @truncate(bits >> bit_count & (@as(u32, 1) << code_width) - 1);

        switch (code) {
            clear_code => {
                next_code = first_dynamic;
                code_width = 9;
                prev_code = null;
                continue;
            },
            eod_code => break,
            else => {},
        }

        if (prev_code) |prev| {
            // The classic KwKwK case: a code that refers to the entry we are
            // about to create. Its expansion is the previous sequence plus its
            // own first byte.
            const known = code < next_code;
            if (!known and code != next_code) return error.InvalidLzwCode;

            const first_byte = if (known) firstByte(&table, code) else firstByte(&table, prev);
            if (next_code < max_codes) {
                table[next_code] = .{
                    .prev = prev,
                    .byte = first_byte,
                    .len = table[prev].len + 1,
                };
                next_code += 1;
            }
            try emit(gpa, &out, &table, if (known) code else next_code - 1);
        } else {
            if (code >= next_code) return error.InvalidLzwCode;
            try emit(gpa, &out, &table, code);
        }
        prev_code = code;
        code_width = widthFor(next_code, early_change);
    }
    return out.toOwnedSlice(gpa);
}

/// Bits per code, given the next code the table will assign.
///
/// Without early change the width grows when a code that needs the extra bit
/// can first appear, i.e. `next_code == 512`. `/EarlyChange 1` -- the default,
/// and what essentially every encoder emits -- grows it one code sooner.
///
/// This boundary is the whole ballgame: off by one, the decoder stays in sync
/// for the first 253 dictionary entries and then silently desynchronises, so
/// short test vectors will not catch a mistake here.
fn widthFor(next_code: u16, early_change: bool) u5 {
    const limit = next_code + @intFromBool(early_change);
    return switch (limit) {
        0...511 => 9,
        512...1023 => 10,
        1024...2047 => 11,
        else => 12,
    };
}

fn firstByte(table: *const [max_codes]Entry, code: u16) u8 {
    var c = code;
    while (table[c].prev != 0xffff) c = table[c].prev;
    return table[c].byte;
}

/// A sequence is only reachable from its tail, so reserve the exact length and
/// fill it from the end backwards.
fn emit(gpa: Allocator, out: *std.ArrayList(u8), table: *const [max_codes]Entry, code: u16) Error!void {
    const len = table[code].len;
    const dst = try out.addManyAsSlice(gpa, len);

    var c = code;
    var i = len;
    while (i > 0) : (i -= 1) {
        dst[i - 1] = table[c].byte;
        if (table[c].prev == 0xffff) break;
        c = table[c].prev;
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the example from the specification" {
    // §7.4.4.2: the byte sequence below encodes to exactly these codes.
    const encoded = [_]u8{ 0x80, 0x0b, 0x60, 0x50, 0x22, 0x0c, 0x0c, 0x85, 0x01 };
    const out = try decode(testing.allocator, &encoded, true);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 45, 45, 45, 45, 45, 65, 45, 45, 45, 66 }, out);
}

test "code width grows at the right code, and one earlier with early change" {
    // Codes 0..511 fit in 9 bits, so without early change the width grows
    // exactly when code 512 becomes assignable.
    try testing.expectEqual(@as(u5, 9), widthFor(511, false));
    try testing.expectEqual(@as(u5, 10), widthFor(512, false));
    try testing.expectEqual(@as(u5, 11), widthFor(1024, false));
    try testing.expectEqual(@as(u5, 12), widthFor(2048, false));

    // Early change moves each of those one code earlier.
    try testing.expectEqual(@as(u5, 9), widthFor(510, true));
    try testing.expectEqual(@as(u5, 10), widthFor(511, true));
    try testing.expectEqual(@as(u5, 11), widthFor(1023, true));
    try testing.expectEqual(@as(u5, 12), widthFor(2047, true));

    // A freshly cleared table is always back to 9.
    try testing.expectEqual(@as(u5, 9), widthFor(first_dynamic, true));
}

test "decodes past the 9-bit boundary" {
    // 3000 bytes of low-entropy data builds well over 253 dictionary entries,
    // so decoding it exercises both the 9->10 and 10->11 transitions. A
    // decoder with the boundary off by one desynchronises partway through and
    // either errors or returns garbage.
    const gpa = testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var seed: u32 = 1;
    for (0..3000) |_| {
        seed = seed *% 1664525 +% 1013904223;
        // A small alphabet: enough repetition to grow the table quickly.
        try payload.append(gpa, @as(u8, @truncate(seed >> 24)) % 12 + 'a');
    }

    const encoded = try encodeForTest(gpa, payload.items);
    defer gpa.free(encoded);

    const decoded = try decode(gpa, encoded, true);
    defer gpa.free(decoded);
    try testing.expectEqualSlices(u8, payload.items, decoded);
}

/// A minimal LZW encoder, for tests only.
///
/// The decoder learns each dictionary entry one code later than the encoder
/// creates it, so at the moment code `k` crosses the wire the encoder's
/// counter is exactly one ahead of the decoder's. The two therefore express
/// the same boundary differently: the encoder against its own `next`, the
/// decoder against `next + 1`. Writing the encoder's side from its own state
/// rather than calling `widthFor` is what makes the round trip able to fail.
fn encodeForTest(gpa: Allocator, data: []const u8) ![]u8 {
    var dict: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer dict.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var bits: u32 = 0;
    var held: u6 = 0;
    var width: u5 = 9;
    var next: u16 = first_dynamic;

    const Emit = struct {
        fn put(o: *std.ArrayList(u8), a: Allocator, b: *u32, h: *u6, w: u5, code: u16) !void {
            b.* = b.* << w | code;
            h.* += w;
            while (h.* >= 8) {
                h.* -= 8;
                try o.append(a, @truncate(b.* >> @intCast(h.*)));
            }
        }
    };

    try Emit.put(&out, gpa, &bits, &held, width, clear_code);

    var prefix: ?u16 = null;
    for (data) |byte| {
        const p = prefix orelse {
            prefix = byte;
            continue;
        };
        const key = @as(u32, p) << 8 | byte;
        if (dict.get(key)) |existing| {
            prefix = existing;
            continue;
        }
        try Emit.put(&out, gpa, &bits, &held, width, p);
        if (next < max_codes) {
            try dict.put(gpa, key, next);
            next += 1;
        }
        // Early change: grow one code before the table strictly requires it.
        width = if (next <= 511) 9 else if (next <= 1023) 10 else if (next <= 2047) 11 else 12;
        prefix = byte;
    }
    if (prefix) |p| try Emit.put(&out, gpa, &bits, &held, width, p);
    try Emit.put(&out, gpa, &bits, &held, width, eod_code);

    if (held > 0) try out.append(gpa, @truncate(bits << @intCast(8 - held)));
    return out.toOwnedSlice(gpa);
}

test "clear code followed by end of data yields nothing" {
    // Two 9-bit codes, MSB first: 256 (clear) then 257 (EOD), zero-padded.
    //   100000000 100000001 000000
    const encoded = [_]u8{ 0x80, 0x40, 0x40 };
    const out = try decode(testing.allocator, &encoded, true);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}
