//! Builds `Object` values out of the token stream (ISO 32000-2 §7.3).
//!
//! The parser is deliberately ignorant of documents: it never resolves an
//! indirect reference, and it never needs to. That keeps the dependency edge
//! one-way (Lexer -> Parser -> XRef -> Document) and means the same code parses
//! the file body, the interior of an object stream, and a content stream.
//!
//! Streams are the one place where that ignorance costs something: `/Length`
//! may itself be an indirect reference, which we cannot follow. Instead, a
//! direct `/Length` is *verified* by checking that `endstream` really does
//! follow, and anything else falls back to scanning for the `endstream`
//! keyword. Real files get `/Length` wrong often enough that a viewer needs
//! that fallback regardless.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Lexer = @import("Lexer.zig");
const object = @import("object.zig");
const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;
const Stream = object.Stream;

const Parser = @This();

lexer: Lexer,
arena: Allocator,
/// Guards against `<<` nested a few million deep in a hostile file.
depth: u16 = 0,

const max_depth = 256;

pub const Error = Lexer.Error || error{
    /// Nesting exceeded `max_depth`.
    DepthExceeded,
    /// A token appeared where an object was required.
    UnexpectedToken,
    /// `N G obj` was expected and something else was found.
    NotAnIndirectObject,
    /// A `stream` keyword whose data never terminates.
    UnterminatedStream,
};

/// One indirect object as it appears in the file body.
pub const Indirect = struct {
    ref: Ref,
    object: Object,
};

pub fn init(src: []const u8, arena: Allocator) Parser {
    return .{ .lexer = .init(src), .arena = arena };
}

pub fn initAt(src: []const u8, offset: usize, arena: Allocator) Parser {
    return .{ .lexer = .initAt(src, offset), .arena = arena };
}

pub fn pos(p: *const Parser) usize {
    return p.lexer.pos;
}

pub fn seek(p: *Parser, offset: usize) void {
    p.lexer.pos = @min(offset, p.lexer.src.len);
}

// -- objects ----------------------------------------------------------------

/// Parses one object. `12 0 R` collapses into `.ref`; `12 0 obj` does not, so
/// that `parseIndirect` can recognise it.
pub fn parseObject(p: *Parser) Error!Object {
    const token = try p.lexer.next(p.arena);
    return p.parseFromToken(token);
}

/// Like `parseObject`, but returns null at end of input instead of an error.
/// Content-stream and object-stream loops want this shape.
pub fn parseObjectOrEof(p: *Parser) Error!?Object {
    const token = try p.lexer.next(p.arena);
    if (token == .eof) return null;
    return try p.parseFromToken(token);
}

fn parseFromToken(p: *Parser, token: Lexer.Token) Error!Object {
    if (p.depth >= max_depth) return error.DepthExceeded;

    return switch (token) {
        .integer => |v| p.maybeReference(v),
        .real => |v| .{ .real = v },
        .string => |v| .{ .string = v },
        .name => |v| .{ .name = v },
        .array_open => try p.parseArray(),
        .dict_open => try p.parseDictOrStream(),
        .keyword => |k| if (std.mem.eql(u8, k, "true"))
            .{ .boolean = true }
        else if (std.mem.eql(u8, k, "false"))
            .{ .boolean = false }
        else if (std.mem.eql(u8, k, "null"))
            .null
        else
            error.UnexpectedToken,
        .array_close, .dict_close, .brace_open, .brace_close => error.UnexpectedToken,
        .eof => error.UnexpectedEndOfFile,
    };
}

/// An integer might be the head of `num gen R`. Look ahead two tokens and
/// rewind if it is not, which is why the lexer keeps no hidden state.
fn maybeReference(p: *Parser, first: i64) Error!Object {
    if (first < 0 or first > std.math.maxInt(u32)) return .{ .integer = first };

    const save = p.lexer.pos;
    errdefer p.lexer.pos = save;

    const second = p.lexer.next(p.arena) catch {
        p.lexer.pos = save;
        return .{ .integer = first };
    };
    const gen = switch (second) {
        .integer => |g| g,
        else => {
            p.lexer.pos = save;
            return .{ .integer = first };
        },
    };
    if (gen < 0 or gen > std.math.maxInt(u16)) {
        p.lexer.pos = save;
        return .{ .integer = first };
    }

    const third = p.lexer.next(p.arena) catch {
        p.lexer.pos = save;
        return .{ .integer = first };
    };
    if (!third.isKeyword("R")) {
        p.lexer.pos = save;
        return .{ .integer = first };
    }

    return .{ .ref = .{ .num = @intCast(first), .gen = @intCast(gen) } };
}

fn parseArray(p: *Parser) Error!Object {
    p.depth += 1;
    defer p.depth -= 1;

    var items: std.ArrayList(Object) = .empty;
    while (true) {
        const token = try p.lexer.next(p.arena);
        switch (token) {
            .array_close => break,
            // An unterminated array at EOF is malformed but recoverable: keep
            // what we have rather than losing the whole object.
            .eof => break,
            // A stray `>>` means the array was never closed. Do not consume it;
            // the enclosing dictionary still needs to see it.
            .dict_close => {
                p.lexer.pos -= 2;
                break;
            },
            else => try items.append(p.arena, try p.parseFromToken(token)),
        }
    }
    return .{ .array = items.items };
}

fn parseDictOrStream(p: *Parser) Error!Object {
    p.depth += 1;
    defer p.depth -= 1;

    var dict: Dict = .empty;
    while (true) {
        const token = try p.lexer.next(p.arena);
        const key = switch (token) {
            .dict_close, .eof => break,
            .name => |n| n,
            // A non-name key is malformed. Skip its value and keep going.
            else => {
                _ = p.parseFromToken(token) catch {};
                continue;
            },
        };
        const value = try p.parseObject();
        // A later duplicate key wins, matching how most readers behave.
        try dict.put(p.arena, key, value);
    }

    // `stream` may follow a dictionary, turning it into a stream object.
    const save = p.lexer.pos;
    const after = p.lexer.next(p.arena) catch {
        p.lexer.pos = save;
        return .{ .dict = dict };
    };
    if (!after.isKeyword("stream")) {
        p.lexer.pos = save;
        return .{ .dict = dict };
    }

    return .{ .stream = try p.parseStreamData(dict) };
}

/// Cursor is just past the `stream` keyword. Per §7.3.8.1 the keyword is
/// followed by CRLF or LF -- never a bare CR -- but tolerate one anyway.
fn parseStreamData(p: *Parser, dict: Dict) Error!*const Stream {
    p.lexer.skipEol();
    const start = p.lexer.pos;

    const raw = if (dict.get("Length")) |len_obj| blk: {
        const len = len_obj.asInt() orelse break :blk try p.scanForEndstream(start);
        if (len < 0) break :blk try p.scanForEndstream(start);
        const end = start +| @as(usize, @intCast(len));
        if (end > p.lexer.src.len) break :blk try p.scanForEndstream(start);
        // Trust /Length only if `endstream` actually appears where it claims.
        if (!endstreamFollows(p.lexer.src, end)) break :blk try p.scanForEndstream(start);
        p.lexer.pos = end;
        break :blk p.lexer.src[start..end];
    } else try p.scanForEndstream(start);

    // Step past the `endstream` keyword so the caller lands on `endobj`.
    p.skipKeyword("endstream");

    const stream = try p.arena.create(Stream);
    stream.* = .{ .dict = dict, .raw = raw };
    return stream;
}

/// True if only whitespace separates `at` from an `endstream` keyword. The
/// spec allows one EOL; files in the wild add stray spaces and blank lines.
fn endstreamFollows(src: []const u8, at: usize) bool {
    var i = at;
    var slack: usize = 0;
    while (i < src.len and Lexer.isWhitespace(src[i]) and slack < 4) : ({
        i += 1;
        slack += 1;
    }) {}
    return std.mem.startsWith(u8, src[i..], "endstream");
}

/// `/Length` was missing, indirect, or wrong. Find the next `endstream` and
/// trim the single EOL that precedes it.
fn scanForEndstream(p: *Parser, start: usize) Error![]const u8 {
    const idx = std.mem.indexOfPos(u8, p.lexer.src, start, "endstream") orelse
        return error.UnterminatedStream;

    var end = idx;
    if (end > start and p.lexer.src[end - 1] == '\n') end -= 1;
    if (end > start and p.lexer.src[end - 1] == '\r') end -= 1;

    p.lexer.pos = idx;
    return p.lexer.src[start..end];
}

/// Consumes `word` if it is the next token; otherwise leaves the cursor put.
fn skipKeyword(p: *Parser, word: []const u8) void {
    const save = p.lexer.pos;
    const token = p.lexer.next(p.arena) catch {
        p.lexer.pos = save;
        return;
    };
    if (!token.isKeyword(word)) p.lexer.pos = save;
}

// -- indirect objects -------------------------------------------------------

/// Parses `N G obj ... endobj` at the current position.
pub fn parseIndirect(p: *Parser) Error!Indirect {
    const num_token = try p.lexer.next(p.arena);
    const num = switch (num_token) {
        .integer => |v| v,
        else => return error.NotAnIndirectObject,
    };
    const gen_token = try p.lexer.next(p.arena);
    const gen = switch (gen_token) {
        .integer => |v| v,
        else => return error.NotAnIndirectObject,
    };
    const obj_token = try p.lexer.next(p.arena);
    if (!obj_token.isKeyword("obj")) return error.NotAnIndirectObject;
    if (num < 0 or num > std.math.maxInt(u32)) return error.NotAnIndirectObject;
    if (gen < 0 or gen > std.math.maxInt(u16)) return error.NotAnIndirectObject;

    // `N 0 obj endobj` is legal and means the null object.
    const save = p.lexer.pos;
    const peeked = p.lexer.next(p.arena) catch Lexer.Token.eof;
    const value: Object = if (peeked.isKeyword("endobj")) .null else v: {
        p.lexer.pos = save;
        break :v try p.parseObject();
    };
    p.skipKeyword("endobj");

    return .{
        .ref = .{ .num = @intCast(num), .gen = @intCast(gen) },
        .object = value,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .arena_state = .init(testing.allocator) };
    }
    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
    }
    fn parser(f: *Fixture, src: []const u8) Parser {
        return .init(src, f.arena_state.allocator());
    }
};

test "scalars" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("true false null /Nm (str) 42 3.5");
    try testing.expectEqual(true, (try p.parseObject()).boolean);
    try testing.expectEqual(false, (try p.parseObject()).boolean);
    try testing.expect((try p.parseObject()).isNull());
    try testing.expectEqualStrings("Nm", (try p.parseObject()).name);
    try testing.expectEqualStrings("str", (try p.parseObject()).string);
    try testing.expectEqual(@as(i64, 42), (try p.parseObject()).integer);
    try testing.expectApproxEqAbs(@as(f64, 3.5), (try p.parseObject()).real, 1e-9);
}

test "indirect references and their lookalikes" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("[ 12 0 R 3 4 5 ]");
    const arr = (try p.parseObject()).array;
    try testing.expectEqual(@as(usize, 4), arr.len);
    try testing.expectEqual(Ref{ .num = 12, .gen = 0 }, arr[0].ref);
    try testing.expectEqual(@as(i64, 3), arr[1].integer);
    try testing.expectEqual(@as(i64, 4), arr[2].integer);
    try testing.expectEqual(@as(i64, 5), arr[3].integer);
}

test "nested dictionaries" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("<< /Type /Page /MediaBox [0 0 612 792] /Sub << /A 1 >> >>");
    const obj = try p.parseObject();
    try testing.expect(obj.find("Type").?.isName("Page"));
    try testing.expectEqual(@as(usize, 4), obj.find("MediaBox").?.array.len);
    try testing.expectEqual(@as(i64, 1), obj.find("Sub").?.find("A").?.integer);
}

test "stream with a correct /Length" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("<< /Length 5 >>\nstream\nHELLO\nendstream\nendobj");
    const stream = (try p.parseObject()).stream;
    try testing.expectEqualStrings("HELLO", stream.raw);
}

test "stream with an indirect /Length falls back to scanning" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("<< /Length 9 0 R >>\nstream\nHELLO\nendstream");
    const stream = (try p.parseObject()).stream;
    try testing.expectEqualStrings("HELLO", stream.raw);
}

test "stream with a wrong /Length is corrected" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("<< /Length 2 >>\nstream\nHELLO\nendstream");
    const stream = (try p.parseObject()).stream;
    try testing.expectEqualStrings("HELLO", stream.raw);
}

test "indirect object" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("7 0 obj << /Count 3 >> endobj");
    const indirect = try p.parseIndirect();
    try testing.expectEqual(Ref{ .num = 7, .gen = 0 }, indirect.ref);
    try testing.expectEqual(@as(i64, 3), indirect.object.find("Count").?.integer);
}

test "empty indirect object is null" {
    var f: Fixture = .init();
    defer f.deinit();

    var p = f.parser("7 0 obj endobj");
    const indirect = try p.parseIndirect();
    try testing.expect(indirect.object.isNull());
}
