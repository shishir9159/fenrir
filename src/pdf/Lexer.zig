//! Byte-level tokenizer for PDF syntax (ISO 32000-2 §7.2).
//!
//! The lexer is a plain cursor over a byte slice with no lookahead state, so
//! callers can save and restore `pos` freely -- `Parser` relies on that to
//! backtrack when `12 0 R` turns out to be just `12`.
//!
//! Decoded names and strings borrow from the source buffer whenever no escape
//! sequence had to be resolved, which is the overwhelmingly common case. Only
//! when an escape is present is the arena touched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Lexer = @This();

src: []const u8,
pos: usize = 0,

pub const Error = error{
    /// A construct started but the file ended before it closed.
    UnexpectedEndOfFile,
    /// A byte appeared where no token can begin, e.g. a stray `)`.
    InvalidToken,
    /// A numeric literal could not be interpreted as an integer or a real.
    InvalidNumber,
} || Allocator.Error;

pub const Token = union(enum) {
    integer: i64,
    real: f64,
    /// Escapes resolved; still raw bytes, not text.
    string: []const u8,
    /// Leading `/` and `#xx` escapes removed. An empty name (`/`) is legal.
    name: []const u8,
    array_open,
    array_close,
    dict_open,
    dict_close,
    /// `{` and `}`, which appear only inside PostScript calculator functions.
    brace_open,
    brace_close,
    /// Any bare word: `obj`, `endobj`, `stream`, `R`, `true`, `xref`,
    /// `trailer`, and every content-stream operator. The lexer deliberately
    /// does not know which words are meaningful; that is the parser's job.
    keyword: []const u8,
    eof,

    pub fn isKeyword(t: Token, word: []const u8) bool {
        return switch (t) {
            .keyword => |k| std.mem.eql(u8, k, word),
            else => false,
        };
    }
};

pub fn init(src: []const u8) Lexer {
    return .{ .src = src };
}

pub fn initAt(src: []const u8, offset: usize) Lexer {
    return .{ .src = src, .pos = @min(offset, src.len) };
}

// -- character classes (ISO 32000-2 tables 1 and 2) --------------------------

pub fn isWhitespace(c: u8) bool {
    return switch (c) {
        0x00, 0x09, 0x0a, 0x0c, 0x0d, 0x20 => true,
        else => false,
    };
}

pub fn isDelimiter(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

pub fn isRegular(c: u8) bool {
    return !isWhitespace(c) and !isDelimiter(c);
}

// -- cursor helpers ---------------------------------------------------------

fn peekByte(l: *const Lexer) ?u8 {
    return if (l.pos < l.src.len) l.src[l.pos] else null;
}

fn peekByteAt(l: *const Lexer, ahead: usize) ?u8 {
    const i = l.pos + ahead;
    return if (i < l.src.len) l.src[i] else null;
}

/// Skips whitespace and comments. A comment runs to the end of the line and is
/// whitespace as far as every other rule is concerned.
pub fn skipSpace(l: *Lexer) void {
    while (l.pos < l.src.len) {
        const c = l.src[l.pos];
        if (isWhitespace(c)) {
            l.pos += 1;
        } else if (c == '%') {
            while (l.pos < l.src.len and l.src[l.pos] != '\n' and l.src[l.pos] != '\r') l.pos += 1;
        } else {
            return;
        }
    }
}

/// Consumes one end-of-line marker: CRLF, LF, or a bare CR. Used after the
/// `stream` keyword, where the spec is precise about the delimiter.
pub fn skipEol(l: *Lexer) void {
    if (l.pos < l.src.len and l.src[l.pos] == '\r') l.pos += 1;
    if (l.pos < l.src.len and l.src[l.pos] == '\n') l.pos += 1;
}

// -- tokenizer --------------------------------------------------------------

pub fn next(l: *Lexer, arena: Allocator) Error!Token {
    l.skipSpace();
    const c = l.peekByte() orelse return .eof;

    switch (c) {
        '[' => {
            l.pos += 1;
            return .array_open;
        },
        ']' => {
            l.pos += 1;
            return .array_close;
        },
        '{' => {
            l.pos += 1;
            return .brace_open;
        },
        '}' => {
            l.pos += 1;
            return .brace_close;
        },
        '/' => return .{ .name = try l.lexName(arena) },
        '(' => return .{ .string = try l.lexLiteralString(arena) },
        '<' => {
            if (l.peekByteAt(1) == '<') {
                l.pos += 2;
                return .dict_open;
            }
            return .{ .string = try l.lexHexString(arena) };
        },
        '>' => {
            if (l.peekByteAt(1) == '>') {
                l.pos += 2;
                return .dict_close;
            }
            // A lone `>` is malformed. Skip it and carry on: recovery matters
            // more than strictness when reading files in the wild.
            l.pos += 1;
            return l.next(arena);
        },
        ')' => {
            l.pos += 1;
            return error.InvalidToken;
        },
        '+', '-', '.', '0'...'9' => return l.lexNumber(),
        else => {
            const start = l.pos;
            while (l.pos < l.src.len and isRegular(l.src[l.pos])) l.pos += 1;
            if (l.pos == start) {
                l.pos += 1;
                return error.InvalidToken;
            }
            return .{ .keyword = l.src[start..l.pos] };
        },
    }
}

/// Numbers: an optional run of signs, digits, and at most one period. Real
/// files contain `--5`, `4.`, and `-.002`; be permissive and let `parseFloat`
/// sort out whatever `parseInt` rejects.
fn lexNumber(l: *Lexer) Error!Token {
    const start = l.pos;
    var seen_dot = false;
    var seen_digit = false;

    while (l.pos < l.src.len) : (l.pos += 1) {
        switch (l.src[l.pos]) {
            '0'...'9' => seen_digit = true,
            '.' => seen_dot = true,
            '+', '-' => {},
            else => break,
        }
    }

    const text = l.src[start..l.pos];
    if (!seen_digit and !seen_dot) return error.InvalidNumber;

    if (!seen_dot) {
        if (std.fmt.parseInt(i64, text, 10)) |v| return .{ .integer = v } else |_| {
            // Out of range, or a leading `--`; fall through to the float path.
        }
    }
    const v = std.fmt.parseFloat(f64, text) catch return .{ .integer = 0 };
    return .{ .real = v };
}

/// `/Name`, with `#xx` hex escapes. Assumes the cursor is on the `/`.
fn lexName(l: *Lexer, arena: Allocator) Error![]const u8 {
    l.pos += 1; // the '/'
    const start = l.pos;
    var needs_decode = false;
    while (l.pos < l.src.len and isRegular(l.src[l.pos])) : (l.pos += 1) {
        if (l.src[l.pos] == '#') needs_decode = true;
    }
    const raw = l.src[start..l.pos];
    if (!needs_decode) return raw;

    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '#' and i + 2 < raw.len) {
            if (std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16)) |byte| {
                // `#00` is forbidden by the spec, and keeping it would produce
                // a name that cannot round-trip, so drop it.
                if (byte != 0) out.appendAssumeCapacity(byte);
                i += 3;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(raw[i]);
        i += 1;
    }
    return out.items;
}

/// `(literal string)` with nesting and backslash escapes. Assumes the cursor
/// is on the `(`.
fn lexLiteralString(l: *Lexer, arena: Allocator) Error![]const u8 {
    l.pos += 1; // the '('
    const start = l.pos;

    // Fast path: find the matching close paren, and if nothing along the way
    // needed rewriting, hand back a slice of the source.
    var depth: usize = 1;
    var clean = true;
    var i = l.pos;
    const close = while (i < l.src.len) : (i += 1) {
        switch (l.src[i]) {
            '\\' => {
                clean = false;
                i += 1; // skip the escaped byte, whatever it is
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break i;
            },
            // A bare CR, or a CRLF, must be delivered as a single LF.
            '\r' => clean = false,
            else => {},
        }
    } else return error.UnexpectedEndOfFile;

    if (clean) {
        l.pos = close + 1;
        return l.src[start..close];
    }

    var out: std.ArrayList(u8) = try .initCapacity(arena, close - start);
    l.pos = start;
    depth = 1;
    while (l.pos < l.src.len) {
        const c = l.src[l.pos];
        l.pos += 1;
        switch (c) {
            '(' => {
                depth += 1;
                try out.append(arena, c);
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return out.items;
                try out.append(arena, c);
            },
            '\r' => {
                if (l.pos < l.src.len and l.src[l.pos] == '\n') l.pos += 1;
                try out.append(arena, '\n');
            },
            '\\' => {
                const e = l.peekByte() orelse return error.UnexpectedEndOfFile;
                l.pos += 1;
                switch (e) {
                    'n' => try out.append(arena, '\n'),
                    'r' => try out.append(arena, '\r'),
                    't' => try out.append(arena, '\t'),
                    'b' => try out.append(arena, 0x08),
                    'f' => try out.append(arena, 0x0c),
                    '(', ')', '\\' => try out.append(arena, e),
                    // A backslash before an EOL is a line continuation: both
                    // the backslash and the newline vanish.
                    '\r' => {
                        if (l.pos < l.src.len and l.src[l.pos] == '\n') l.pos += 1;
                    },
                    '\n' => {},
                    '0'...'7' => {
                        // Up to three octal digits, truncated to one byte.
                        var value: u16 = e - '0';
                        var digits: usize = 1;
                        while (digits < 3) : (digits += 1) {
                            const d = l.peekByte() orelse break;
                            if (d < '0' or d > '7') break;
                            value = value * 8 + (d - '0');
                            l.pos += 1;
                        }
                        try out.append(arena, @truncate(value));
                    },
                    // Any other escaped byte stands for itself.
                    else => try out.append(arena, e),
                }
            },
            else => try out.append(arena, c),
        }
    }
    return error.UnexpectedEndOfFile;
}

/// `<48656C6C6F>`. Whitespace between digits is ignored and a trailing odd
/// digit is padded with `0`. Assumes the cursor is on the `<`.
fn lexHexString(l: *Lexer, arena: Allocator) Error![]const u8 {
    l.pos += 1; // the '<'
    const start = l.pos;
    while (l.pos < l.src.len and l.src[l.pos] != '>') l.pos += 1;
    if (l.pos >= l.src.len) return error.UnexpectedEndOfFile;
    const raw = l.src[start..l.pos];
    l.pos += 1; // the '>'

    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len / 2 + 1);
    var high: ?u8 = null;
    for (raw) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch continue;
        if (high) |h| {
            out.appendAssumeCapacity(h << 4 | digit);
            high = null;
        } else {
            high = digit;
        }
    }
    if (high) |h| out.appendAssumeCapacity(h << 4);
    return out.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn expectTokens(src: []const u8, expected: []const Token) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lexer: Lexer = .init(src);
    for (expected) |want| {
        const got = try lexer.next(arena);
        try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            .integer => |v| try testing.expectEqual(v, got.integer),
            .real => |v| try testing.expectApproxEqAbs(v, got.real, 1e-9),
            .string => |v| try testing.expectEqualStrings(v, got.string),
            .name => |v| try testing.expectEqualStrings(v, got.name),
            .keyword => |v| try testing.expectEqualStrings(v, got.keyword),
            else => {},
        }
    }
    try testing.expectEqual(Token.eof, try lexer.next(arena));
}

test "numbers" {
    try expectTokens("0 -17 +3 4. -.002 34.5", &.{
        .{ .integer = 0 },
        .{ .integer = -17 },
        .{ .integer = 3 },
        .{ .real = 4.0 },
        .{ .real = -0.002 },
        .{ .real = 34.5 },
    });
}

test "names with escapes" {
    try expectTokens("/Name1 /A;Name_With-Various***Characters? /Lime#20Green /", &.{
        .{ .name = "Name1" },
        .{ .name = "A;Name_With-Various***Characters?" },
        .{ .name = "Lime Green" },
        .{ .name = "" },
    });
}

test "literal strings" {
    try expectTokens("(balanced (parens) here) (a\\053b) (line\\\ncont) (esc\\)aped)", &.{
        .{ .string = "balanced (parens) here" },
        .{ .string = "a+b" },
        .{ .string = "linecont" },
        .{ .string = "esc)aped" },
    });
}

test "hex strings" {
    try expectTokens("<48656C6C6F> <901FA3> <901FA>", &.{
        .{ .string = "Hello" },
        .{ .string = "\x90\x1f\xa3" },
        .{ .string = "\x90\x1f\xa0" },
    });
}

test "comments are whitespace" {
    try expectTokens("12 % this is a comment\n 0 R", &.{
        .{ .integer = 12 },
        .{ .integer = 0 },
        .{ .keyword = "R" },
    });
}

test "structural tokens" {
    try expectTokens("<< /Type /Page >> [ 1 2 ]", &.{
        .dict_open,
        .{ .name = "Type" },
        .{ .name = "Page" },
        .dict_close,
        .array_open,
        .{ .integer = 1 },
        .{ .integer = 2 },
        .array_close,
    });
}

test "carriage return inside a string becomes a newline" {
    try expectTokens("(a\r\nb)", &.{.{ .string = "a\nb" }});
}
