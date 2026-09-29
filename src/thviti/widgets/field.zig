//! The editing model behind a text field: a caret, a selection, and the eight
//! operations that move them.
//!
//! Split from the widget that draws it, and deliberately: everything here is
//! arithmetic over bytes, so all of it is testable with no UI, no font and no
//! window, which is where the awkward cases live. Where a caret lands after
//! backspacing over an accented letter is not a question anyone should have
//! to open a window to answer.
//!
//! ## It owns no string
//!
//! `Field.bytes` is the caller's storage and nothing here ever allocates.
//! `checkbox` takes a `*bool` for the same reason: a control whose value
//! lived inside the box would be a value nothing else could read, and a
//! search box the reader cannot read the query out of is not a search box.
//!
//! A fixed buffer rather than a list also settles the per-frame allocation
//! rule by construction. Every field in this program is bounded -- a page
//! number, a search query, a `:` line -- so `insert` returning false when it
//! is full is the whole of the overflow policy.
//!
//! ## Byte offsets, on character boundaries
//!
//! `caret` and `anchor` are offsets into the bytes, not character counts,
//! because every operation that uses them -- insert, remove, measure a prefix
//! -- wants a byte offset, and a count would be converted at each one. They
//! are kept on a boundary instead, by `before` and `after`, so no operation
//! can cut a character in half.

const std = @import("std");

/// A line of text being edited, and where the caret is in it.
pub const Field = struct {
    /// The caller's storage. Never reallocated, never freed here.
    bytes: []u8,
    len: u32 = 0,

    /// Byte offsets into `bytes[0..len]`, always on a character boundary.
    caret: u32 = 0,
    /// The other end of the selection; equal to `caret` when there is none.
    anchor: u32 = 0,

    pub fn init(storage: []u8) Field {
        return .{ .bytes = storage };
    }

    pub fn slice(f: Field) []const u8 {
        return f.bytes[0..f.len];
    }

    pub fn isEmpty(f: Field) bool {
        return f.len == 0;
    }

    pub fn hasSelection(f: Field) bool {
        return f.caret != f.anchor;
    }

    /// The selection, low end first.
    pub fn selection(f: Field) [2]u32 {
        return if (f.caret < f.anchor) .{ f.caret, f.anchor } else .{ f.anchor, f.caret };
    }

    /// Replaces the contents and puts the caret at the end, which is where
    /// someone who has just opened a field on existing text wants it.
    ///
    /// Text too long for the storage is cut, and the cut is walked back to a
    /// character boundary. Without that the invariant at the top of this
    /// struct is broken before anyone has pressed a key, and `before` goes
    /// looking for the lead byte of a character whose tail is not there.
    pub fn set(f: *Field, text: []const u8) void {
        var take: u32 = @intCast(@min(text.len, f.bytes.len));
        if (take < text.len) take = before(text, take + 1);

        @memcpy(f.bytes[0..take], text[0..take]);
        f.len = take;
        f.caret = take;
        f.anchor = take;
    }

    pub fn clear(f: *Field) void {
        f.len = 0;
        f.caret = 0;
        f.anchor = 0;
    }

    pub fn selectAll(f: *Field) void {
        f.anchor = 0;
        f.caret = f.len;
    }

    /// Inserts at the caret, replacing the selection. False when the text
    /// would not fit, in which case nothing at all is inserted -- a partial
    /// insert would cut a character in half.
    pub fn insert(f: *Field, text: []const u8) bool {
        f.deleteSelection();
        if (f.len + text.len > f.bytes.len) return false;

        const at = f.caret;
        std.mem.copyBackwards(u8, f.bytes[at + text.len .. f.len + text.len], f.bytes[at..f.len]);
        @memcpy(f.bytes[at..][0..text.len], text);
        f.len += @intCast(text.len);
        f.caret = at + @as(u32, @intCast(text.len));
        f.anchor = f.caret;
        return true;
    }

    pub fn deleteSelection(f: *Field) void {
        if (!f.hasSelection()) return;
        const sel = f.selection();
        f.removeRange(sel[0], sel[1]);
    }

    /// The character before the caret, or the selection if there is one.
    pub fn backspace(f: *Field) void {
        if (f.hasSelection()) return f.deleteSelection();
        if (f.caret == 0) return;
        f.removeRange(before(f.slice(), f.caret), f.caret);
    }

    /// The character after the caret, or the selection if there is one.
    pub fn deleteForward(f: *Field) void {
        if (f.hasSelection()) return f.deleteSelection();
        if (f.caret >= f.len) return;
        f.removeRange(f.caret, after(f.slice(), f.caret));
    }

    fn removeRange(f: *Field, from: u32, to: u32) void {
        std.mem.copyForwards(u8, f.bytes[from..], f.bytes[to..f.len]);
        f.len -= to - from;
        f.caret = from;
        f.anchor = from;
    }

    /// Puts the caret somewhere, extending the selection or collapsing it.
    pub fn moveTo(f: *Field, at: u32, extend: bool) void {
        f.caret = at;
        if (!extend) f.anchor = at;
    }

    /// One character left.
    ///
    /// Collapsing to the *near end* of a selection rather than stepping from
    /// the caret is the detail every text field has and nobody notices until
    /// it is missing: with three words selected, left goes to the start of
    /// the selection and right to the end, not one character either side of
    /// wherever the drag happened to finish.
    pub fn moveLeft(f: *Field, extend: bool) void {
        if (!extend and f.hasSelection()) {
            const sel = f.selection();
            f.caret = sel[0];
            f.anchor = sel[0];
            return;
        }
        f.moveTo(before(f.slice(), f.caret), extend);
    }

    pub fn moveRight(f: *Field, extend: bool) void {
        if (!extend and f.hasSelection()) {
            const sel = f.selection();
            f.caret = sel[1];
            f.anchor = sel[1];
            return;
        }
        f.moveTo(after(f.slice(), f.caret), extend);
    }

    pub fn moveHome(f: *Field, extend: bool) void {
        f.moveTo(0, extend);
    }

    pub fn moveEnd(f: *Field, extend: bool) void {
        f.moveTo(f.len, extend);
    }
};

// -- character boundaries -----------------------------------------------------

/// The start of the character before `at`. Continuation bytes are `10xxxxxx`,
/// so walking back over them lands on a lead byte -- which is the whole of
/// what is needed here, and needs no decoding.
pub fn before(text: []const u8, at: u32) u32 {
    if (at == 0) return 0;
    var i = at - 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

/// The start of the character after `at`.
pub fn after(text: []const u8, at: u32) u32 {
    if (at >= text.len) return @intCast(text.len);
    const n = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    return @min(at + n, @as(u32, @intCast(text.len)));
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn scratch(storage: []u8, text: []const u8) Field {
    var f: Field = .init(storage);
    f.set(text);
    return f;
}

test "typing inserts at the caret and pushes the rest along" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "ac");

    f.moveLeft(false);
    try testing.expect(f.insert("b"));
    try testing.expectEqualStrings("abc", f.slice());
    try testing.expectEqual(@as(u32, 2), f.caret);
}

test "a field that is full takes nothing rather than half a character" {
    var store: [4]u8 = undefined;
    var f = scratch(&store, "abc");

    // Two bytes into one byte of room: refused whole.
    try testing.expect(!f.insert("é"));
    try testing.expectEqualStrings("abc", f.slice());
    try testing.expect(f.insert("d"));
    try testing.expectEqualStrings("abcd", f.slice());
}

test "backspace removes a character, not a byte" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "aé");

    f.backspace();
    try testing.expectEqualStrings("a", f.slice());
    try testing.expectEqual(@as(u32, 1), f.caret);
}

test "the caret steps over a character at a time in both directions" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "aéb");

    f.moveHome(false);
    f.moveRight(false);
    try testing.expectEqual(@as(u32, 1), f.caret);
    f.moveRight(false);
    try testing.expectEqual(@as(u32, 3), f.caret); // over both bytes of é
    f.moveLeft(false);
    try testing.expectEqual(@as(u32, 1), f.caret);
}

test "a selection is replaced by what is typed over it" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "hello");

    f.selectAll();
    try testing.expect(f.hasSelection());
    try testing.expect(f.insert("bye"));
    try testing.expectEqualStrings("bye", f.slice());
    try testing.expect(!f.hasSelection());
}

test "an unextended motion collapses to the near end of the selection" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "hello");

    f.selectAll();
    f.moveLeft(false);
    try testing.expectEqual(@as(u32, 0), f.caret);

    f.selectAll();
    f.moveRight(false);
    try testing.expectEqual(@as(u32, 5), f.caret);
}

test "shift extends from the anchor and leaves it alone" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "hello");

    f.moveHome(false);
    f.moveRight(true);
    f.moveRight(true);
    try testing.expectEqual(@as(u32, 0), f.anchor);
    try testing.expectEqual(@as(u32, 2), f.caret);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, &f.selection());

    // Backwards past the anchor: the selection is still low end first.
    f.moveEnd(false);
    f.moveLeft(true);
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, &f.selection());
}

test "delete forward takes the character after the caret" {
    var store: [32]u8 = undefined;
    var f = scratch(&store, "abc");

    f.moveHome(false);
    f.deleteForward();
    try testing.expectEqualStrings("bc", f.slice());
    f.moveEnd(false);
    f.deleteForward();
    try testing.expectEqualStrings("bc", f.slice());
}

test "setting the text puts the caret where someone would carry on typing" {
    var store: [32]u8 = undefined;
    var f: Field = .init(&store);

    f.set("48");
    try testing.expectEqual(@as(u32, 2), f.caret);
    try testing.expect(!f.hasSelection());

    f.clear();
    try testing.expect(f.isEmpty());
    try testing.expectEqual(@as(u32, 0), f.caret);
}

test "text longer than the storage is truncated rather than overrunning it" {
    var store: [4]u8 = undefined;
    var f: Field = .init(&store);

    f.set("abcdefgh");
    try testing.expectEqual(@as(u32, 4), f.len);
    try testing.expectEqual(@as(u32, 4), f.caret);
}

test "a cut that lands inside a character is walked back to its start" {
    var store: [4]u8 = undefined;
    var f: Field = .init(&store);

    // Three bytes, then a two-byte character that will not fit whole.
    f.set("abcé");
    try testing.expectEqualStrings("abc", f.slice());
    try testing.expectEqual(@as(u32, 3), f.caret);

    // And the invariant holds afterwards: backspace takes a character.
    f.backspace();
    try testing.expectEqualStrings("ab", f.slice());
}
