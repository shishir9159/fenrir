//! Splits a content stream into operators and their operands (§7.8.2).
//!
//! A content stream is postfix: operands first, then the operator that
//! consumes them. So the scanner accumulates objects until it meets a bare
//! keyword, and hands the interpreter one `Op` at a time.
//!
//! ## Why this does not use `Parser`
//!
//! `Parser` would nearly work, and using it would be one line. It reads every
//! integer three tokens deep, because `12 0 R` has to be distinguished from
//! `12` -- and a content stream cannot contain an indirect reference at all
//! (§7.8.2). Path data is almost entirely numbers, so that lookahead-and-
//! rewind would triple the lexing of the hottest input in the whole reader to
//! test a hypothesis that is false by definition. Everything else about object
//! syntax is shared, so this is forty lines rather than four hundred.
//!
//! ## Inline images
//!
//! `BI ... ID <binary> EI` is the one place where PDF syntax stops being
//! self-delimiting: the bytes after `ID` are raw image data that may contain
//! anything, `EI` included. Finding the end is a documented guess in every
//! reader that exists. The three strategies here, in order of how much they
//! can be trusted, are `/L`, arithmetic on an unfiltered image's dimensions,
//! and a scan for `EI` that also checks the bytes *after* it look like
//! operators. See `endOfInlineData`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Lexer = @import("../Lexer.zig");
const object = @import("../object.zig");
const Dict = object.Dict;
const Object = object.Object;

const Scanner = @This();

lexer: Lexer,
arena: Allocator,
/// The operands seen since the last operator, oldest first.
buf: [max_operands]Object = undefined,
count: usize = 0,
/// Operands discarded because more than `max_operands` piled up before an
/// operator arrived. Nonzero means the stream is damaged.
dropped: u32 = 0,

/// No operator in the specification takes more than six operands, and the two
/// that take a variable count (`TJ`, `d`) take a single array. Anything past
/// this is junk from a damaged stream, and the operands *nearest* the operator
/// are the ones most likely to be real, so the oldest are dropped.
pub const max_operands = 32;

/// Nesting limit for arrays and dictionaries inside a content stream. The
/// deepest legitimate construct is a `/DecodeParms` array inside an inline
/// image dictionary, at three.
const max_depth = 32;

pub const Error = Lexer.Error || error{DepthExceeded};

/// One operator and the operands it consumes.
///
/// `operands` points into the scanner's own buffer and is valid only until the
/// next call to `next`. The objects it holds are arena-allocated and outlive
/// it, so an interpreter may keep a `TJ` array but not the slice around it.
pub const Op = struct {
    name: []const u8,
    operands: []const Object,
    /// Set only for `BI`, whose "operand" is an entire image.
    image: ?InlineImage = null,

    /// The last `n` operands as numbers, or null if there are not that many or
    /// one of them is not a number.
    ///
    /// Counting from the end rather than the start is deliberate. A damaged
    /// stream accumulates junk *before* the operands the operator meant to
    /// have -- a dropped operator leaves its operands on the stack -- so the
    /// tail is what to trust.
    pub fn nums(op: Op, comptime n: usize) ?[n]f64 {
        if (op.operands.len < n) return null;
        const tail = op.operands[op.operands.len - n ..];
        var out: [n]f64 = undefined;
        for (tail, 0..) |o, i| out[i] = o.asNumber() orelse return null;
        return out;
    }

    /// The last operand, or null when the operator was given none.
    pub fn last(op: Op) ?Object {
        return if (op.operands.len == 0) null else op.operands[op.operands.len - 1];
    }

    /// The last operand as a number. `Tf` and friends want exactly this.
    pub fn num(op: Op) ?f64 {
        return (op.last() orelse return null).asNumber();
    }

    /// The last operand that is a name. `Do`, `gs`, `sh`, `cs` and `BMC` all
    /// take one, and `scn` takes one *after* its components.
    pub fn nameOperand(op: Op) ?[]const u8 {
        var i = op.operands.len;
        while (i > 0) {
            i -= 1;
            if (op.operands[i].asName()) |n| return n;
        }
        return null;
    }
};

pub const InlineImage = struct {
    /// The abbreviated dictionary between `BI` and `ID`, keys exactly as
    /// written: `/W`, not `/Width`.
    dict: Dict,
    /// The bytes between `ID` and `EI`, still encoded.
    data: []const u8,
    /// How the end of the data was found, which is the single most useful
    /// thing to know when an inline image comes out as noise.
    ended_by: enum { length_entry, computed_size, scan },
};

pub fn init(src: []const u8, arena: Allocator) Scanner {
    return .{ .lexer = .init(src), .arena = arena };
}

pub fn pos(s: *const Scanner) usize {
    return s.lexer.pos;
}

/// The next operator, or null at the end of the stream. Trailing operands with
/// no operator after them are discarded, which is what every reader does with
/// a stream that was truncated mid-instruction.
pub fn next(s: *Scanner) Error!?Op {
    s.count = 0;
    s.dropped = 0;

    while (true) {
        s.lexer.skipSpace();
        const c = s.peek() orelse return null;

        // The operator is the only token that begins with a regular character
        // that cannot begin a number. Deciding on one byte is what keeps every
        // operand lexed exactly once.
        if (startsKeyword(c)) {
            const token = try s.lexer.next(s.arena);
            const word = switch (token) {
                .keyword => |k| k,
                // `skipSpace` already ran, so nothing else can appear here.
                else => continue,
            };

            if (std.mem.eql(u8, word, "true")) {
                s.push(.{ .boolean = true });
                continue;
            }
            if (std.mem.eql(u8, word, "false")) {
                s.push(.{ .boolean = false });
                continue;
            }
            if (std.mem.eql(u8, word, "null")) {
                s.push(.null);
                continue;
            }

            if (std.mem.eql(u8, word, "BI")) {
                return s.inlineImage() catch |err| switch (err) {
                    // A malformed inline image swallows the rest of the
                    // stream if we let it; reporting it as a bare `BI` lets
                    // the interpreter count it and stop.
                    error.UnexpectedEndOfFile => null,
                    else => err,
                };
            }

            return .{ .name = word, .operands = s.buf[0..s.count] };
        }

        // Anything else is an operand.
        const value = s.operand(0) catch |err| switch (err) {
            // One bad token does not end a page. Skip it and carry on: the
            // lexer has already advanced past the offending byte.
            error.InvalidToken, error.InvalidNumber => continue,
            else => return err,
        };
        s.push(value);
    }
}

fn peek(s: *const Scanner) ?u8 {
    return if (s.lexer.pos < s.lexer.src.len) s.lexer.src[s.lexer.pos] else null;
}

/// True for a byte that can only begin a bare keyword. Numbers start with a
/// sign, a dot, or a digit; everything else structural is a delimiter.
fn startsKeyword(c: u8) bool {
    return switch (c) {
        '+', '-', '.', '0'...'9' => false,
        else => Lexer.isRegular(c),
    };
}

fn push(s: *Scanner, value: Object) void {
    if (s.count == max_operands) {
        std.mem.copyForwards(Object, s.buf[0 .. max_operands - 1], s.buf[1..max_operands]);
        s.count = max_operands - 1;
        s.dropped += 1;
    }
    s.buf[s.count] = value;
    s.count += 1;
}

// -- operands ---------------------------------------------------------------

fn operand(s: *Scanner, depth: u16) Error!Object {
    if (depth >= max_depth) return error.DepthExceeded;
    const token = try s.lexer.next(s.arena);
    return s.fromToken(token, depth);
}

fn fromToken(s: *Scanner, token: Lexer.Token, depth: u16) Error!Object {
    return switch (token) {
        .integer => |v| .{ .integer = v },
        .real => |v| .{ .real = v },
        .string => |v| .{ .string = v },
        .name => |v| .{ .name = v },
        .array_open => try s.array(depth),
        .dict_open => try s.dict(depth),
        .keyword => |k| if (std.mem.eql(u8, k, "true"))
            .{ .boolean = true }
        else if (std.mem.eql(u8, k, "false"))
            .{ .boolean = false }
        else
            .null,
        // A stray closer, or a PostScript brace that escaped its function.
        // Both are noise here; report them as nulls so the operand count
        // still lines up with what the producer intended.
        .array_close, .dict_close, .brace_open, .brace_close => .null,
        .eof => error.UnexpectedEndOfFile,
    };
}

fn array(s: *Scanner, depth: u16) Error!Object {
    var items: std.ArrayList(Object) = .empty;
    while (true) {
        s.lexer.skipSpace();
        if (s.peek() == null) break;
        if (s.peek() == ']') {
            s.lexer.pos += 1;
            break;
        }
        const value = s.operand(depth + 1) catch |err| switch (err) {
            error.InvalidToken, error.InvalidNumber => continue,
            else => return err,
        };
        try items.append(s.arena, value);
    }
    return .{ .array = items.items };
}

fn dict(s: *Scanner, depth: u16) Error!Object {
    var out: Dict = .empty;
    while (true) {
        const token = try s.lexer.next(s.arena);
        switch (token) {
            .dict_close, .eof => break,
            .name => |key| {
                const value = try s.operand(depth + 1);
                try out.put(s.arena, key, value);
            },
            // A value with no key. Skip it rather than desynchronising the
            // rest of the dictionary.
            else => {},
        }
    }
    return .{ .dict = out };
}

// -- inline images ----------------------------------------------------------

/// Assembles `BI <dict> ID <bytes> EI`. The cursor is just past `BI`.
fn inlineImage(s: *Scanner) Error!?Op {
    var d: Dict = .empty;
    while (true) {
        const token = try s.lexer.next(s.arena);
        switch (token) {
            .eof => return error.UnexpectedEndOfFile,
            .keyword => |k| {
                if (std.mem.eql(u8, k, "ID")) break;
                // `EI` with no `ID` is an empty image; anything else is junk
                // inside the dictionary.
                if (std.mem.eql(u8, k, "EI")) {
                    return .{
                        .name = "BI",
                        .operands = &.{},
                        .image = .{ .dict = d, .data = "", .ended_by = .scan },
                    };
                }
            },
            .name => |key| {
                const value = try s.operand(1);
                try d.put(s.arena, key, value);
            },
            else => {},
        }
    }

    // Exactly one whitespace byte separates `ID` from the data (§8.9.7). A
    // second one belongs to the image.
    if (s.lexer.pos < s.lexer.src.len and Lexer.isWhitespace(s.lexer.src[s.lexer.pos])) {
        s.lexer.pos += 1;
    }

    const start = s.lexer.pos;
    const found = s.endOfInlineData(d, start);
    const data = s.lexer.src[start..found.end];
    s.lexer.pos = found.next;

    return .{
        .name = "BI",
        .operands = &.{},
        .image = .{ .dict = d, .data = data, .ended_by = found.how },
    };
}

const InlineEnd = struct {
    /// Last byte of image data, exclusive.
    end: usize,
    /// Where scanning resumes, past the `EI`.
    next: usize,
    how: @FieldType(InlineImage, "ended_by"),
};

/// Where the image data stops.
///
/// Three strategies, and the order matters because each is less trustworthy
/// than the one before:
///
/// 1. `/L` (or `/Length`) says so outright. Added in PDF 2.0 for exactly this
///    reason; rare in the wild but authoritative when present.
/// 2. The image is unfiltered, so its size is `H` rows of `ceil(W*bpc*n/8)`
///    bytes and arithmetic settles it.
/// 3. Scan for `EI`. This is a guess: compressed data can contain those two
///    bytes surrounded by whitespace. Requiring the *following* bytes to look
///    like operators rejects most false positives, because random binary data
///    is very unlikely to be printable ASCII for the next sixteen bytes.
fn endOfInlineData(s: *const Scanner, d: Dict, start: usize) InlineEnd {
    const src = s.lexer.src;

    if (declaredLength(d)) |n| {
        const end = @min(start + n, src.len);
        if (afterEi(src, end)) |resume_at| return .{ .end = end, .next = resume_at, .how = .length_entry };
    }

    if (!hasFilter(d)) {
        if (computedSize(d)) |n| {
            const end = @min(start + n, src.len);
            if (afterEi(src, end)) |resume_at| return .{ .end = end, .next = resume_at, .how = .computed_size };
        }
    }

    var i = start;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] != 'E' or src[i + 1] != 'I') continue;
        // `EI` must stand alone as a token: whitespace before, and a
        // delimiter or whitespace after.
        if (i > start and !Lexer.isWhitespace(src[i - 1])) continue;
        const after = i + 2;
        if (after < src.len and Lexer.isRegular(src[after])) continue;
        if (!looksLikeOperators(src[after..])) continue;
        // The whitespace byte before `EI` is a delimiter, not image data.
        const end = if (i > start) i - 1 else i;
        return .{ .end = end, .next = after, .how = .scan };
    }

    return .{ .end = src.len, .next = src.len, .how = .scan };
}

fn declaredLength(d: Dict) ?usize {
    const entry = d.get("L") orelse d.get("Length") orelse return null;
    const n = entry.asInt() orelse return null;
    return if (n >= 0) @intCast(n) else null;
}

fn hasFilter(d: Dict) bool {
    const f = d.get("F") orelse d.get("Filter") orelse return false;
    return switch (f) {
        .name => true,
        .array => |a| a.len != 0,
        else => false,
    };
}

/// Rows times bytes per row, for an image with no filter. Null when the
/// colour space is a name that has to be looked up in the page's resources,
/// which the scanner deliberately cannot do.
fn computedSize(d: Dict) ?usize {
    const w = intOf(d, "W", "Width") orelse return null;
    const h = intOf(d, "H", "Height") orelse return null;
    if (w <= 0 or h <= 0) return null;

    const mask = boolOf(d, "IM", "ImageMask") orelse false;
    const bpc: u64 = if (mask) 1 else @intCast(intOf(d, "BPC", "BitsPerComponent") orelse 8);
    if (bpc == 0 or bpc > 16) return null;

    const components: u64 = if (mask) 1 else blk: {
        const cs = d.get("CS") orelse d.get("ColorSpace") orelse break :blk 1;
        break :blk deviceComponents(cs.asName() orelse return null) orelse return null;
    };

    const row_bits = @as(u64, @intCast(w)) * bpc * components;
    const row_bytes = (row_bits + 7) / 8;
    const total = row_bytes * @as(u64, @intCast(h));
    return if (total > std.math.maxInt(u32)) null else @intCast(total);
}

/// The device spaces, by both their names and their inline abbreviations
/// (§8.9.7 table 93). `/I` is `/Indexed`, whose samples are one component
/// each whatever the base space is.
fn deviceComponents(name: []const u8) ?u64 {
    const table = .{
        .{ "G", 1 },           .{ "DeviceGray", 1 },
        .{ "RGB", 3 },         .{ "DeviceRGB", 3 },
        .{ "CMYK", 4 },        .{ "DeviceCMYK", 4 },
        .{ "I", 1 },           .{ "Indexed", 1 },
        .{ "CalGray", 1 },     .{ "CalRGB", 3 },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn intOf(d: Dict, short: []const u8, long: []const u8) ?i64 {
    const entry = d.get(short) orelse d.get(long) orelse return null;
    return entry.asInt();
}

fn boolOf(d: Dict, short: []const u8, long: []const u8) ?bool {
    const entry = d.get(short) orelse d.get(long) orelse return null;
    return entry.asBool();
}

/// Confirms that `EI` really does follow `at`, allowing whitespace.
fn afterEi(src: []const u8, at: usize) ?usize {
    var i = at;
    while (i < src.len and Lexer.isWhitespace(src[i])) i += 1;
    if (i + 1 < src.len and src[i] == 'E' and src[i + 1] == 'I') return i + 2;
    return null;
}

/// A cheap sanity check on the bytes after a candidate `EI`.
///
/// Content-stream syntax is printable ASCII apart from the interiors of
/// strings, so sixteen consecutive printable bytes after the candidate is
/// strong evidence that this `EI` is the real one. Compressed image data that
/// happens to contain ` EI ` will almost always fail it.
fn looksLikeOperators(rest: []const u8) bool {
    const window = rest[0..@min(rest.len, 16)];
    for (window) |c| {
        if (Lexer.isWhitespace(c)) continue;
        if (c < 0x20 or c > 0x7e) return false;
    }
    return true;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn scanAll(arena: Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !void {
    var s: Scanner = .init(src, arena);
    while (try s.next()) |op| try out.append(arena, op.name);
}

test "operands accumulate until an operator consumes them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("1 0 0 1 72 720 cm", arena);
    const op = (try s.next()).?;
    try testing.expectEqualStrings("cm", op.name);
    try testing.expectEqual(@as(usize, 6), op.operands.len);

    const m = op.nums(6).?;
    try testing.expectEqual(@as(f64, 72), m[4]);
    try testing.expectEqual(@as(f64, 720), m[5]);
    try testing.expectEqual(@as(?Op, null), try s.next());
}

test "a whole little page scans into the operators it contains" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var names: std.ArrayList([]const u8) = .empty;
    try scanAll(arena,
        \\q 0.5 0 0 0.5 10 10 cm
        \\  0 0 1 rg 10 10 100 50 re f
        \\  BT /F1 12 Tf 72 700 Td [(Hi) -250 (there)] TJ ET
        \\Q
    , &names);

    const expected = [_][]const u8{
        "q", "cm", "rg", "re", "f", "BT", "Tf", "Td", "TJ", "ET", "Q",
    };
    try testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "TJ keeps its array, mixed numbers and strings alike" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("[(A) -120 (B)] TJ", arena);
    const op = (try s.next()).?;
    try testing.expectEqualStrings("TJ", op.name);

    const items = op.last().?.asArray().?;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("A", items[0].asString().?);
    try testing.expectEqual(@as(?i64, -120), items[1].asInt());
}

test "true, false and null are operands, not operators" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("true false null gs", arena);
    const op = (try s.next()).?;
    try testing.expectEqualStrings("gs", op.name);
    try testing.expectEqual(@as(usize, 3), op.operands.len);
    try testing.expectEqual(true, op.operands[0].boolean);
    try testing.expect(op.operands[2].isNull());
}

test "operands past the cap drop the oldest, not the newest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Forty numbers then an operator: a stream that lost the operators that
    // were supposed to consume them.
    var src: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 40) : (i += 1) try src.print(arena, "{d} ", .{i});
    try src.appendSlice(arena, "re");

    var s: Scanner = .init(src.items, arena);
    const op = (try s.next()).?;
    try testing.expectEqual(@as(usize, max_operands), op.operands.len);
    try testing.expect(s.dropped > 0);
    // The four operands `re` actually wanted are the last four written.
    const r = op.nums(4).?;
    try testing.expectEqual(@as(f64, 36), r[0]);
    try testing.expectEqual(@as(f64, 39), r[3]);
}

test "trailing operands with no operator are discarded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("10 20 m 30 40", arena);
    try testing.expectEqualStrings("m", (try s.next()).?.name);
    try testing.expectEqual(@as(?Op, null), try s.next());
}

test "a stray delimiter does not derail the rest of the stream" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var names: std.ArrayList([]const u8) = .empty;
    try scanAll(arena, "q ) 1 0 0 1 0 0 cm Q", &names);
    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("cm", names.items[1]);
}

test "an inline image with no filter is sized by arithmetic" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 4x2 grey, 8 bits: eight bytes, and they spell out something that
    // contains `EI` so the scan strategy would get it wrong.
    const src = "BI /W 4 /H 2 /BPC 8 /CS /G ID \x00 EI\x00\xff\xfe EI Q";
    var s: Scanner = .init(src, arena);

    const op = (try s.next()).?;
    const img = op.image.?;
    try testing.expectEqual(@as(usize, 8), img.data.len);
    try testing.expectEqual(@as(@TypeOf(img.ended_by), .computed_size), img.ended_by);
    // And the stream carries on correctly afterwards.
    try testing.expectEqualStrings("Q", (try s.next()).?.name);
}

test "an inline image with a filter is found by scanning" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "BI /W 4 /H 4 /F /AHx ID 00112233 EI\nQ";
    var s: Scanner = .init(src, arena);

    const op = (try s.next()).?;
    const img = op.image.?;
    try testing.expectEqualStrings("00112233", img.data);
    try testing.expectEqual(@as(@TypeOf(img.ended_by), .scan), img.ended_by);
    try testing.expectEqualStrings("Q", (try s.next()).?.name);
}

test "a declared length is trusted over both other strategies" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "BI /W 2 /H 1 /F /Fl /L 5 ID abcde EI Q";
    var s: Scanner = .init(src, arena);
    const img = (try s.next()).?.image.?;
    try testing.expectEqualStrings("abcde", img.data);
    try testing.expectEqual(@as(@TypeOf(img.ended_by), .length_entry), img.ended_by);
}

test "binary image data containing EI does not end the image early" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The false `EI` is followed by high bytes, which no operator stream
    // contains; the real one is followed by `Q`.
    const src = "BI /W 8 /H 8 /F /Fl ID xx EI\x88\x99\xaa\xbb\xcc\xdd\xee\xff\x01\x02\x03\x04 EI Q";
    var s: Scanner = .init(src, arena);
    const img = (try s.next()).?.image.?;
    try testing.expect(img.data.len > 4);
    try testing.expectEqualStrings("Q", (try s.next()).?.name);
}

test "an inline image dictionary keeps its abbreviated keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("BI /W 1 /H 1 /IM true /D [1 0] ID \x00 EI", arena);
    const img = (try s.next()).?.image.?;
    try testing.expectEqual(@as(?i64, 1), img.dict.get("W").?.asInt());
    try testing.expectEqual(true, img.dict.get("IM").?.boolean);
    try testing.expectEqual(@as(usize, 2), img.dict.get("D").?.asArray().?.len);
}

test "a truncated inline image ends the stream instead of looping" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("q BI /W 1 /H 1", arena);
    try testing.expectEqualStrings("q", (try s.next()).?.name);
    try testing.expectEqual(@as(?Op, null), try s.next());
}

test "a nested dictionary operand parses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("/OC << /Type /OCMD /Name (layer) >> BDC", arena);
    const op = (try s.next()).?;
    try testing.expectEqualStrings("BDC", op.name);
    try testing.expectEqual(@as(usize, 2), op.operands.len);
    try testing.expectEqualStrings("OC", op.operands[0].asName().?);
    try testing.expectEqualStrings("layer", op.operands[1].find("Name").?.asString().?);
}

test "name_ finds the name a pattern operand hides behind" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Scanner = .init("0.2 0.4 0.6 /P1 scn", arena);
    const op = (try s.next()).?;
    try testing.expectEqualStrings("P1", op.nameOperand().?);
    try testing.expectEqual(@as(?[6]f64, null), op.nums(6));
}
