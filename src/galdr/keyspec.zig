//! Key names, the way Neovim writes them: `g`, `<C-k>`, `<A-x>`, `<Space>`.
//!
//! One key per binding. Neovim also binds *sequences* -- `gg`, `<leader>ff`
//! -- and those need a pending buffer and a timeout in the keymap, the way
//! `<C-w>` has one. They are refused here by name rather than half-supported:
//! a binding for `gg` that fired on the first `g` would be worse than an error
//! saying sequences are not supported yet.

const std = @import("std");

const keys = @import("../hlidskjalf/keys.zig");

pub const Error = error{
    Empty,
    /// More than one key: `gg`, or `<C-w>v`.
    Sequence,
    /// `<Foo>`, or `<C->`.
    UnknownName,
    InvalidUtf8,
};

pub fn parse(spec: []const u8) Error!keys.Key {
    if (spec.len == 0) return error.Empty;

    if (spec[0] == '<' and spec.len > 1) {
        const close = std.mem.indexOfScalar(u8, spec, '>') orelse return error.UnknownName;
        if (close != spec.len - 1) return error.Sequence;
        return named(spec[1..close]);
    }

    const len = std.unicode.utf8ByteSequenceLength(spec[0]) catch return error.InvalidUtf8;
    if (len > spec.len) return error.InvalidUtf8;
    if (len != spec.len) return error.Sequence;
    const c = std.unicode.utf8Decode(spec[0..len]) catch return error.InvalidUtf8;
    return .{ .char = c };
}

/// The inside of `<...>`: modifiers, then a key.
fn named(inner: []const u8) Error!keys.Key {
    var key: keys.Key = .{ .char = 0 };
    var rest = inner;

    // `C-`, `A-` and `M-` in any order and any case, as Neovim accepts them.
    while (rest.len >= 2 and rest[1] == '-') {
        switch (std.ascii.toLower(rest[0])) {
            'c' => key.ctrl = true,
            'a', 'm' => key.alt = true,
            else => return error.UnknownName,
        }
        rest = rest[2..];
    }
    if (rest.len == 0) return error.UnknownName;

    const words = [_]struct { []const u8, u21 }{
        .{ "space", ' ' },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "bar", '|' },
        .{ "bslash", '\\' },
        .{ "minus", '-' },
    };
    for (words) |w| {
        if (std.ascii.eqlIgnoreCase(rest, w[0])) {
            key.char = w[1];
            return finish(key);
        }
    }

    const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.InvalidUtf8;
    if (len != rest.len) return error.UnknownName;
    key.char = std.unicode.utf8Decode(rest) catch return error.InvalidUtf8;
    return finish(key);
}

/// A chord matches the letter printed on the key, which the platform reports
/// in one case; `<C-K>` and `<C-k>` are the same chord, as they are in Neovim.
fn finish(key: keys.Key) Error!keys.Key {
    if (!key.ctrl and !key.alt) {
        if (key.char == 0) return error.UnknownName;
        return key;
    }
    var k = key;
    if (k.char >= 'A' and k.char <= 'Z') k.char += 32;
    return k;
}

/// What the error means, for a message a person reads.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Empty => "an empty key",
        error.Sequence => "a sequence of keys; bind one key, like \"g\" or \"<C-k>\"",
        error.UnknownName => "not a key name Galdr knows",
        error.InvalidUtf8 => "not valid UTF-8",
    };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "single characters are keys, in any script" {
    try testing.expectEqual(keys.Key{ .char = 'g' }, try parse("g"));
    try testing.expectEqual(keys.Key{ .char = 'G' }, try parse("G"));
    try testing.expectEqual(keys.Key{ .char = 0xdf }, try parse("\xc3\x9f")); // ß
    try testing.expectEqual(keys.Key{ .char = '<' }, try parse("<"));
}

test "modifiers are written the way Neovim writes them" {
    try testing.expectEqual(keys.Key{ .char = 'k', .ctrl = true }, try parse("<C-k>"));
    try testing.expectEqual(keys.Key{ .char = 'k', .ctrl = true }, try parse("<c-K>"));
    try testing.expectEqual(keys.Key{ .char = 'x', .alt = true }, try parse("<A-x>"));
    try testing.expectEqual(keys.Key{ .char = 'x', .alt = true }, try parse("<M-x>"));
    try testing.expectEqual(keys.Key{ .char = 's', .ctrl = true, .alt = true }, try parse("<C-A-s>"));
    try testing.expectEqual(keys.Key{ .char = ' ' }, try parse("<Space>"));
    try testing.expectEqual(keys.Key{ .char = ' ', .ctrl = true }, try parse("<C-Space>"));
    try testing.expectEqual(keys.Key{ .char = '<' }, try parse("<lt>"));
}

test "sequences and nonsense are refused by name" {
    try testing.expectError(error.Sequence, parse("gg"));
    try testing.expectError(error.Sequence, parse("<C-w>v"));
    try testing.expectError(error.UnknownName, parse("<Foo>"));
    try testing.expectError(error.UnknownName, parse("<C->"));
    try testing.expectError(error.UnknownName, parse("<X-k>"));
    try testing.expectError(error.Empty, parse(""));
}
