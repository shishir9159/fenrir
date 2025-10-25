//! Box identity: a 64-bit hash of a string and its parent's key.
//!
//! This is the single idea that makes immediate-mode call sites compatible
//! with state that outlives a frame. The call site says `ui.button("Open")`
//! and nothing else; the key derived from `"Open"` and from whichever box is
//! currently the parent is what finds last frame's hover animation, last
//! frame's scroll offset, and last frame's rectangle to hit-test against.
//! Nobody allocates a widget, nobody frees one, and nobody holds a handle.
//!
//! ## Why the parent is in the hash
//!
//! Because `"Open"` appears in every dialog in the program. Seeding with the
//! parent makes the key mean "the Open button *in this panel*", so two panels
//! showing the same list of buttons do not share one animation between them,
//! and a button that moves from one panel to another correctly forgets what it
//! knew. It also means the caller almost never has to invent a unique name,
//! which is the tax that sinks most immediate-mode UIs.
//!
//! ## The two escapes
//!
//! Both are Dear ImGui's, kept because a decade of use has not found better.
//!
//! `"Save##toolbar"` displays `Save` and keys on the whole string, for two
//! buttons that read the same and are not the same.
//!
//! `"42 items###count"` displays `42 items` and keys on `count` alone, for a
//! label whose text changes every frame and whose identity must not. Without
//! it, a box that counts something is a different box every time the count
//! changes: its animation restarts, and if it is focused, the focus is lost.
//!
//! ## Collisions
//!
//! Two boxes with the same key are one box, and the second one silently
//! inherits the first's state and rectangle. At 64 bits over the few hundred
//! keys a frame contains, a hash collision is not the way that happens -- the
//! way it happens is a caller building a list without putting the index in the
//! string, which is a bug in the caller and looks like one immediately, since
//! every row of the list animates together.

const std = @import("std");

/// Zero is nil, and a nil-keyed box is a fresh one every frame with no
/// persistent state. That is the right default for pure structure -- rows,
/// spacers, containers -- which is most of a tree.
pub const Key = enum(u64) {
    nil = 0,
    _,

    pub fn isNil(k: Key) bool {
        return k == .nil;
    }

    pub fn format(k: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (k == .nil) return w.writeAll("nil");
        try w.print("{x:0>16}", .{@intFromEnum(k)});
    }
};

/// A hash seeded by the parent's key.
///
/// The empty string is nil rather than a hash of nothing, so that a caller can
/// pass `""` to mean "this box has no identity" without a second entry point.
pub fn make(seed: Key, s: []const u8) Key {
    if (s.len == 0) return .nil;
    var h: std.hash.Wyhash = .init(@intFromEnum(seed));
    h.update(s);
    // A string that happens to hash to zero would otherwise become nil and
    // lose its state on that one frame, which is the kind of bug that shows
    // up once a year and takes a day.
    const v = h.final();
    return @enumFromInt(if (v == 0) 1 else v);
}

pub const Parsed = struct {
    /// What to draw. May be empty.
    display: []const u8,
    key: Key,
};

/// Splits a call-site string into what is shown and what identifies it.
pub fn parse(seed: Key, s: []const u8) Parsed {
    // `###` first: it is a prefix of `##`, so testing the shorter one first
    // would split `a###b` at the wrong place and key on `#b`.
    if (std.mem.indexOf(u8, s, "###")) |i| {
        return .{ .display = s[0..i], .key = make(seed, s[i + 3 ..]) };
    }
    if (std.mem.indexOf(u8, s, "##")) |i| {
        return .{ .display = s[0..i], .key = make(seed, s) };
    }
    return .{ .display = s, .key = make(seed, s) };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the same string under the same parent is the same box" {
    const parent = make(.nil, "panel");
    try testing.expectEqual(make(parent, "Open"), make(parent, "Open"));
}

test "the same string under different parents is not" {
    const a = make(.nil, "left");
    const b = make(.nil, "right");
    try testing.expect(make(a, "Open") != make(b, "Open"));
}

test "an empty string has no identity" {
    try testing.expect(make(.nil, "").isNil());
    try testing.expect(parse(.nil, "").key.isNil());
    try testing.expectEqualStrings("", parse(.nil, "").display);
}

test "a double hash hides the tail from the label but not from the key" {
    const a = parse(.nil, "Save##toolbar");
    const b = parse(.nil, "Save##dialog");

    try testing.expectEqualStrings("Save", a.display);
    try testing.expectEqualStrings("Save", b.display);
    try testing.expect(a.key != b.key);
    // And neither is the plain string, which is a third button.
    try testing.expect(a.key != parse(.nil, "Save").key);
}

test "a triple hash keeps the identity while the label changes" {
    const a = parse(.nil, "0 items###count");
    const b = parse(.nil, "97 items###count");

    try testing.expectEqualStrings("0 items", a.display);
    try testing.expectEqualStrings("97 items", b.display);
    // The whole point: a label that counts something does not become a
    // different box each time the number moves.
    try testing.expectEqual(a.key, b.key);
}

test "the triple hash is recognised before the double" {
    // `###` contains `##`, so a naive search finds the wrong split and keys
    // on "#tail" -- which still works, and stops working the moment someone
    // writes `a##b` and `a###b` in the same parent.
    const t = parse(.nil, "label###tail");
    try testing.expectEqualStrings("label", t.display);
    try testing.expectEqual(make(.nil, "tail"), t.key);
}

test "a key formats as something greppable" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{make(.nil, "Open")});
    try testing.expectEqual(@as(usize, 16), w.buffered().len);

    var nil_buf: [8]u8 = undefined;
    var nw = std.Io.Writer.fixed(&nil_buf);
    try nw.print("{f}", .{Key.nil});
    try testing.expectEqualStrings("nil", nw.buffered());
}
