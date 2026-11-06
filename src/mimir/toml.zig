//! A small TOML: the part of it `fenrir.toml` has a use for, and a refusal
//! for the rest.
//!
//! The file is a handful of names and values, so this reads `key = value`,
//! `[table]` headers, `#` comments, and four kinds of value: strings, basic
//! and literal; integers and floats as TOML spells them; and booleans.
//! Arrays, inline tables, multi-line strings, dotted and quoted keys and
//! dates are TOML too, and nothing the file holds is one. Each is refused by
//! name, at its line, rather than misread: a file written for a fuller parser
//! should fail here where somebody can see it, not quietly mean something
//! else.
//!
//! What comes back is the entries in the order they were written, each with
//! its table and its line. Not a tree, because one level of table is all
//! there is, and a list is what the reader walks anyway when it turns
//! `[read]` back into the flags it stands for.
//!
//! Parsed once at start into an arena the document owns. Nothing here is on
//! a frame path, and one free for the lot is the right number for a file
//! that is read once.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,

    /// What a message calls this kind of value.
    pub fn kind(v: Value) []const u8 {
        return switch (v) {
            .string => "a string",
            .integer => "an integer",
            .float => "a float",
            .boolean => "true or false",
        };
    }
};

pub const Entry = struct {
    /// The `[table]` it was written under; empty above the first header.
    table: []const u8,
    key: []const u8,
    value: Value,
    /// Numbered from 1, as an editor numbers them.
    line: u32,
};

/// Why a file was refused, and where.
///
/// Whatever returns `error.Invalid` fills it in. The message is kept in the
/// struct so a caller above the parser can write one with a key in it -- the
/// reader refusing a theme nobody has -- and nothing is allocated to say so.
pub const Diagnostic = struct {
    line: u32 = 0,
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    pub fn set(d: *Diagnostic, line: u32, comptime fmt: []const u8, args: anytype) error{Invalid} {
        d.line = line;
        // Cut rather than lost: a key three hundred bytes long still gets a
        // message, and the start of it is the part worth reading.
        const said: []const u8 = std.fmt.bufPrint(&d.buf, fmt, args) catch d.buf[0..];
        d.len = said.len;
        return error.Invalid;
    }
};

pub const Error = error{Invalid} || Allocator.Error;

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(d: *Document) void {
        d.arena.deinit();
    }

    /// The entry for `key` under `table`, or null. A walk, because a file
    /// with more than a dozen lines in it is a file nobody wrote by hand.
    pub fn get(d: *const Document, table: []const u8, key: []const u8) ?Entry {
        for (d.entries) |e| {
            if (eql(e.table, table) and eql(e.key, key)) return e;
        }
        return null;
    }
};

/// Parses `source`, which stays the caller's: everything the document hands
/// back is copied into its own arena first.
pub fn parse(gpa: Allocator, source: []const u8, diag: *Diagnostic) Error!Document {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var text: []const u8 = try a.dupe(u8, source);
    // Notepad writes one, and it is not the start of the first key.
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text = text[3..];

    var entries: std.ArrayList(Entry) = .empty;
    var tables: std.ArrayList([]const u8) = .empty;
    var table: []const u8 = "";

    var number: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.unicode.utf8ValidateSlice(line)) return diag.set(number, "this line is not UTF-8", .{});

        var c: Cursor = .{ .s = line, .line = number, .diag = diag };
        c.skipSpace();
        if (c.done() or c.peek() == '#') continue;

        if (c.peek() == '[') {
            table = try c.header();
            for (tables.items) |seen| {
                if (eql(seen, table)) return diag.set(number, "[{s}] is opened twice", .{table});
            }
            // TOML's rule, and a real one here: `read = 1` and then `[read]`
            // is a file that cannot decide what `read` is.
            for (entries.items) |e| {
                if (e.table.len == 0 and eql(e.key, table)) {
                    return diag.set(number, "{s} is already a value, on line {d}", .{ table, e.line });
                }
            }
            try tables.append(a, table);
            continue;
        }

        const key = try c.key();
        c.skipSpace();
        if (!c.done() and c.peek() == '.') {
            return diag.set(number, "dotted keys are not supported: put {s} under a [table]", .{key});
        }
        if (!c.eat('=')) return diag.set(number, "{s} needs = and a value", .{key});
        c.skipSpace();
        const value = try c.value(a);
        try c.end();

        for (entries.items) |e| {
            if (eql(e.table, table) and eql(e.key, key)) {
                return diag.set(number, "{s} is already set, on line {d}", .{ key, e.line });
            }
        }
        try entries.append(a, .{ .table = table, .key = key, .value = value, .line = number });
    }
    return .{ .arena = arena, .entries = entries.items };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A bare key: what TOML allows without quotes, and all this file needs.
fn isBare(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

/// One line, and how far along it the parser is.
const Cursor = struct {
    s: []const u8,
    i: usize = 0,
    line: u32,
    diag: *Diagnostic,

    fn done(c: *const Cursor) bool {
        return c.i >= c.s.len;
    }

    fn peek(c: *const Cursor) u8 {
        return c.s[c.i];
    }

    fn rest(c: *const Cursor) []const u8 {
        return c.s[c.i..];
    }

    fn eat(c: *Cursor, ch: u8) bool {
        if (c.done() or c.peek() != ch) return false;
        c.i += 1;
        return true;
    }

    fn skipSpace(c: *Cursor) void {
        while (!c.done() and (c.peek() == ' ' or c.peek() == '\t')) c.i += 1;
    }

    fn fail(c: *const Cursor, comptime fmt: []const u8, args: anytype) error{Invalid} {
        return c.diag.set(c.line, fmt, args);
    }

    fn key(c: *Cursor) Error![]const u8 {
        const start = c.i;
        while (!c.done() and isBare(c.peek())) c.i += 1;
        if (c.i != start) return c.s[start..c.i];
        if (!c.done() and (c.peek() == '"' or c.peek() == '\'')) {
            return c.fail("quoted keys are not supported: write the name bare", .{});
        }
        return c.fail("expected a name", .{});
    }

    /// `[name]`, with nothing after it but a comment.
    fn header(c: *Cursor) Error![]const u8 {
        c.i += 1;
        if (!c.done() and c.peek() == '[') return c.fail("arrays of tables are not supported", .{});
        c.skipSpace();
        const name = try c.key();
        c.skipSpace();
        if (!c.done() and c.peek() == '.') return c.fail("[{s}.]: tables inside tables are not supported", .{name});
        if (!c.eat(']')) return c.fail("[{s} needs a closing ]", .{name});
        try c.end();
        return name;
    }

    /// Nothing but a comment may follow what a line said.
    fn end(c: *Cursor) error{Invalid}!void {
        c.skipSpace();
        if (c.done() or c.peek() == '#') return;
        return c.fail("only a comment may follow, not {s}", .{c.rest()});
    }

    fn value(c: *Cursor, a: Allocator) Error!Value {
        if (c.done() or c.peek() == '#') return c.fail("expected a value", .{});
        switch (c.peek()) {
            '"' => {
                if (std.mem.startsWith(u8, c.rest(), "\"\"\"")) return c.fail("multi-line strings are not supported", .{});
                return .{ .string = try c.basic(a) };
            },
            '\'' => {
                if (std.mem.startsWith(u8, c.rest(), "'''")) return c.fail("multi-line strings are not supported", .{});
                return .{ .string = try c.literal() };
            },
            '[' => return c.fail("arrays are not supported", .{}),
            '{' => return c.fail("inline tables are not supported", .{}),
            else => return c.scalar(),
        }
    }

    /// `"..."`, with TOML's escapes decoded.
    fn basic(c: *Cursor, a: Allocator) Error![]const u8 {
        c.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (!c.done()) {
            const ch = c.peek();
            c.i += 1;
            switch (ch) {
                '"' => return out.items,
                '\\' => try c.escape(a, &out),
                else => {
                    if (isControl(ch)) return c.fail("a control character in a string has to be escaped", .{});
                    try out.append(a, ch);
                },
            }
        }
        return c.fail("the string is never closed", .{});
    }

    fn escape(c: *Cursor, a: Allocator, out: *std.ArrayList(u8)) Error!void {
        if (c.done()) return c.fail("the string is never closed", .{});
        const ch = c.peek();
        c.i += 1;
        const byte: u8 = switch (ch) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'u', 'U' => return c.unicode(a, out, ch),
            // A Windows path in double quotes is the usual way here, and
            // the fix is the other kind of string.
            else => return c.fail("a backslash starts an escape: write \\\\, or use 'single quotes'", .{}),
        };
        try out.append(a, byte);
    }

    /// `\uXXXX` and `\UXXXXXXXX`, written out as UTF-8.
    fn unicode(c: *Cursor, a: Allocator, out: *std.ArrayList(u8), letter: u8) Error!void {
        const digits: usize = if (letter == 'u') 4 else 8;
        // `"C:\Users"` lands here, so the message says what it would for
        // any other backslash in a path.
        const bad = "\\{c} wants {d} hex digits; for a path, use 'single quotes'";
        if (c.s.len - c.i < digits) return c.fail(bad, .{ letter, digits });
        const hex = c.s[c.i..][0..digits];
        // By hand rather than through `parseInt`, which would also take a
        // sign and an underscore.
        for (hex) |h| {
            if (!std.ascii.isHex(h)) return c.fail(bad, .{ letter, digits });
        }
        const point = std.fmt.parseInt(u32, hex, 16) catch unreachable;
        if (point > 0x10ffff) return c.fail("\\U{s} is past the last character", .{hex});
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(point), &buf) catch
            return c.fail("\\u{s} is half of a surrogate pair, not a character", .{hex});
        try out.appendSlice(a, buf[0..n]);
        c.i += digits;
    }

    /// `'...'`, exactly as written. What a Windows path wants.
    fn literal(c: *Cursor) Error![]const u8 {
        c.i += 1;
        const start = c.i;
        while (!c.done() and c.peek() != '\'') : (c.i += 1) {
            if (isControl(c.peek())) return c.fail("a literal string cannot hold a control character", .{});
        }
        if (c.done()) return c.fail("the string is never closed", .{});
        const s = c.s[start..c.i];
        c.i += 1;
        return s;
    }

    /// `true`, `false`, or a number: whatever runs to the next space or
    /// comment.
    fn scalar(c: *Cursor) Error!Value {
        const start = c.i;
        while (!c.done() and c.peek() != ' ' and c.peek() != '\t' and c.peek() != '#') c.i += 1;
        const word = c.s[start..c.i];

        if (eql(word, "true")) return .{ .boolean = true };
        if (eql(word, "false")) return .{ .boolean = false };
        if (isDate(word)) return c.fail("dates and times are not supported", .{});

        const digits = std.mem.trimStart(u8, word, "+-");
        if (isFloat(digits)) {
            const f = std.fmt.parseFloat(f64, word) catch return c.fail("{s} is not a number", .{word});
            return .{ .float = f };
        }
        // TOML refuses these so that `010` is not read as eight by one
        // program and ten by another. So does this.
        if (digits.len > 1 and digits[0] == '0' and std.ascii.isDigit(digits[1])) {
            return c.fail("{s}: a number cannot start with 0", .{word});
        }
        const n = std.fmt.parseInt(i64, word, 0) catch |err| return switch (err) {
            error.Overflow => c.fail("{s} does not fit in 64 bits", .{word}),
            error.InvalidCharacter => c.fail("{s} is not a value: a string wants quotes", .{word}),
        };
        return .{ .integer = n };
    }
};

fn isControl(ch: u8) bool {
    return (ch < 0x20 and ch != '\t') or ch == 0x7f;
}

/// `1979-05-27`, `07:32:00`, and the ones made of both.
fn isDate(word: []const u8) bool {
    if (std.mem.indexOfScalar(u8, word, ':') != null) return true;
    if (word.len < 5 or word[4] != '-') return false;
    for (word[0..4]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// A float has a point, an exponent, or is one of the two words. Asked of a
/// word without its sign, and false for a hexadecimal one, whose `e` is a
/// digit.
fn isFloat(digits: []const u8) bool {
    if (eql(digits, "inf") or eql(digits, "nan")) return true;
    if (digits.len > 1 and digits[0] == '0' and std.mem.indexOfScalar(u8, "xob", digits[1]) != null) return false;
    return std.mem.indexOfAny(u8, digits, ".eE") != null;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn parsed(source: []const u8) !Document {
    var diag: Diagnostic = .{};
    return parse(testing.allocator, source, &diag) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ diag.line, diag.message() });
        return err;
    };
}

/// The line a file is refused at, and what it is refused with.
fn refusal(source: []const u8) !Diagnostic {
    var diag: Diagnostic = .{};
    var doc = parse(testing.allocator, source, &diag) catch |err| {
        try testing.expectEqual(error.Invalid, err);
        return diag;
    };
    doc.deinit();
    return error.TestExpectedError;
}

fn expectRefused(source: []const u8, line: u32, words: []const u8) !void {
    const diag = try refusal(source);
    testing.expectEqual(line, diag.line) catch |err| {
        std.debug.print("refused at {d} with: {s}\n", .{ diag.line, diag.message() });
        return err;
    };
    if (std.mem.indexOf(u8, diag.message(), words) == null) {
        std.debug.print("wanted \"{s}\" in: {s}\n", .{ words, diag.message() });
        return error.TestUnexpectedResult;
    }
}

test "the subset the file uses: tables, comments, and four kinds of value" {
    var doc = try parsed(
        \\# fenrir.toml
        \\theme = "light"   # after a value too
        \\accent='#e4572e'
        \\
        \\[read]
        \\zoom = 1.25
        \\samples = 4
        \\big = 1_000_000
        \\mask = 0xff
        \\clean = true
        \\fast = false
        \\neg = -2.5e-1
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 9), doc.entries.len);
    try testing.expectEqualStrings("light", doc.get("", "theme").?.value.string);
    // A `#` inside a string is the string's: only the parser decides where a
    // comment starts.
    try testing.expectEqualStrings("#e4572e", doc.get("", "accent").?.value.string);

    try testing.expectEqual(@as(f64, 1.25), doc.get("read", "zoom").?.value.float);
    try testing.expectEqual(@as(i64, 4), doc.get("read", "samples").?.value.integer);
    try testing.expectEqual(@as(i64, 1_000_000), doc.get("read", "big").?.value.integer);
    try testing.expectEqual(@as(i64, 255), doc.get("read", "mask").?.value.integer);
    try testing.expect(doc.get("read", "clean").?.value.boolean);
    try testing.expect(!doc.get("read", "fast").?.value.boolean);
    try testing.expectEqual(@as(f64, -0.25), doc.get("read", "neg").?.value.float);

    // A key belongs to the table it was written under, and its line is the
    // editor's.
    try testing.expect(doc.get("", "zoom") == null);
    try testing.expectEqual(@as(u32, 6), doc.get("read", "zoom").?.line);
    try testing.expectEqualStrings("read", doc.entries[2].table);
}

test "escapes are decoded, and a literal string keeps its backslashes" {
    var doc = try parsed(
        \\tab = "a\tb"
        \\quote = "say \"hi\""
        \\e = "caf\u00e9 \U0001F600"
        \\path = 'C:\Users\n\papers'
    );
    defer doc.deinit();

    try testing.expectEqualStrings("a\tb", doc.get("", "tab").?.value.string);
    try testing.expectEqualStrings("say \"hi\"", doc.get("", "quote").?.value.string);
    try testing.expectEqualStrings("café 😀", doc.get("", "e").?.value.string);
    try testing.expectEqualStrings("C:\\Users\\n\\papers", doc.get("", "path").?.value.string);
}

test "what is TOML but not this subset is refused by name, at its line" {
    try expectRefused("a = 1\nlist = [1, 2]", 2, "arrays");
    try expectRefused("point = { x = 1 }", 1, "inline tables");
    try expectRefused("s = \"\"\"\nlong\n\"\"\"", 1, "multi-line");
    try expectRefused("s = '''x'''", 1, "multi-line");
    try expectRefused("read.zoom = 2", 1, "dotted keys");
    try expectRefused("\"theme\" = \"light\"", 1, "quoted keys");
    try expectRefused("[read.window]", 1, "tables inside tables");
    try expectRefused("[[read]]", 1, "arrays of tables");
    try expectRefused("when = 1979-05-27", 1, "dates");
    try expectRefused("at = 07:32:00", 1, "dates");
}

test "a file that is not TOML at all says where and why" {
    // The one a person will write first: a name without its quotes.
    try expectRefused("theme = light", 1, "wants quotes");
    try expectRefused("theme light", 1, "needs =");
    try expectRefused("theme =", 1, "expected a value");
    try expectRefused("theme = \"light", 1, "never closed");
    try expectRefused("theme = \"light\" \"dark\"", 1, "only a comment");
    try expectRefused("path = \"C:\\papers\"", 1, "single quotes");
    try expectRefused("path = \"C:\\Users\"", 1, "single quotes");
    try expectRefused("n = 010", 1, "cannot start with 0");
    try expectRefused("n = 99999999999999999999", 1, "64 bits");
    try expectRefused("[read", 1, "closing ]");
    try expectRefused("= 1", 1, "expected a name");
}

test "a key set twice, or a table opened twice, is refused at the second" {
    try expectRefused("zoom = 1\nzoom = 2", 2, "line 1");
    try expectRefused("[read]\n[read]", 2, "opened twice");
    try expectRefused("read = 1\n[read]", 2, "already a value");

    // The same name in two tables is two keys.
    var doc = try parsed("zoom = 1\n[read]\nzoom = 2");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.get("", "zoom").?.value.integer);
    try testing.expectEqual(@as(i64, 2), doc.get("read", "zoom").?.value.integer);
}

test "a byte-order mark and CRLF endings are what Windows writes, and both read" {
    var doc = try parsed("\xef\xbb\xbftheme = \"dark\"\r\n[read]\r\nzoom = 2\r\n");
    defer doc.deinit();
    try testing.expectEqualStrings("dark", doc.get("", "theme").?.value.string);
    try testing.expectEqual(@as(i64, 2), doc.get("read", "zoom").?.value.integer);

    try expectRefused("a = 1\nb = \"\xff\"", 2, "not UTF-8");
}
