//! The highlights on a document, the one copy of them, and their history.
//!
//! This is the whole of "the same document in two windows". A mark belongs to
//! the *buffer*, never to a view, so there is exactly one list however many
//! windows are open on it: drawing a highlight in one split is not copied to
//! the others, because there was never anything to copy -- the others are
//! reading the same array.
//!
//! What the views do keep is a number. `revision` counts changes, and a view
//! that has drawn revision 7 knows it must redraw when the buffer says 8.
//! That is the entire synchronisation protocol, and it is a `u64` compare per
//! view per frame rather than a subscription list, an observer, or a diff.
//!
//! ## Editing, undo, and the database
//!
//! Every change -- add, remove, recolour, a note -- goes through a method
//! here, and each one does three things: changes the list, records how to
//! reverse it, and queues an `Effect` describing what the library must write.
//! The reader drains the effects once a frame and turns them into SQL. That
//! split is what makes undo cheap to get right: undoing a removal is *adding
//! the mark back*, through the same path as adding it the first time, so the
//! database cannot disagree with the screen about what was undone.
//!
//! A mark has two identities. `key` is this session's, handed out here and
//! never reused, and it is what history refers to. `id` is the database row,
//! which changes when an undone removal is written back as a new row. History
//! keyed on `id` would lose track of a mark the first time that happened.
//!
//! Changes are **grouped**. Highlighting a selection that spans six lines
//! makes six marks, and `u` should take all six back, not the last line.
//!
//! ## Coordinates
//!
//! A mark's box is in **PDF user space** -- points, y upwards, origin at the
//! bottom-left of its page. Not device pixels, and not the zoom the window
//! happened to be at when it was drawn: a highlight is a fact about the
//! document, so it has to be in the document's own units or it would move
//! when the window was resized and land somewhere else on the next machine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const Point = gelgja.Point;

const Marks = @This();

/// One highlight.
pub const Mark = struct {
    /// This session's name for it. Stable across undo and redo; see the note
    /// at the top of the file.
    key: u64 = 0,
    /// The row it is stored as in Mímir, or `unsaved`.
    id: i64 = unsaved,
    page: u32 = 0,
    /// In PDF user space.
    box: Bounds = .empty,
    color: Color = .{ .r = 1, .g = 0.9, .b = 0.2, .a = 1 },
    /// A note on it. Owned by the `Marks` it belongs to; see `strings`.
    note: []const u8 = &.{},

    pub const unsaved: i64 = 0;

    pub fn saved(m: Mark) bool {
        return m.id != unsaved;
    }
};

/// What the library has to do to catch up with the list.
pub const Effect = union(enum) {
    /// Write the mark with this key as a new row, and give it the row's id.
    insert: u64,
    /// This mark is gone: delete its row, if it has one. The whole mark and
    /// not only the row, so that a plugin can be told what was removed.
    delete: Mark,
    /// Rewrite the colour and note of the mark with this key.
    update: u64,
};

/// One reversible change. Both halves are whole marks rather than a diff,
/// because a mark is five numbers and a slice, and a diff would be a second
/// thing to get wrong.
const Change = struct {
    group: u32,
    kind: Kind,
    /// The mark as it was. Unused for an add.
    before: Mark = .{},
    /// The mark as it became. Unused for a remove.
    after: Mark = .{},
    /// Where in the list it was, so an undone removal goes back to the same
    /// place in the drawing order rather than on top of everything.
    index: usize = 0,

    const Kind = enum { added, removed, changed };
};

list: std.ArrayList(Mark) = .empty,

/// Bumped by every change. A view redraws when this is not the number it last
/// drew.
revision: u64 = 1,

/// Set by any change a person made, and not by loading from the library.
dirty: bool = false,

/// Database work waiting for the reader to do it.
effects: std.ArrayList(Effect) = .empty,

undo_stack: std.ArrayList(Change) = .empty,
redo_stack: std.ArrayList(Change) = .empty,

/// Note text. An arena, because a note that is edited leaves its old text
/// behind in the undo history, and freeing it would leave history pointing
/// at nothing. A document collects kilobytes of notes in a long session, not
/// megabytes, and all of it goes when the document is closed.
strings: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

next_key: u64 = 1,
group: u32 = 0,
/// Whether `group` has been used since `beginGroup`, so that a group with
/// nothing in it does not become an undo step that does nothing.
group_used: bool = false,

/// How many steps of undo to keep. Each is a few dozen bytes; the limit is
/// there so that a reader left open for a week does not grow without end.
pub const history_limit = 1000;

pub fn deinit(m: *Marks, gpa: Allocator) void {
    m.list.deinit(gpa);
    m.effects.deinit(gpa);
    m.undo_stack.deinit(gpa);
    m.redo_stack.deinit(gpa);
    m.strings.deinit();
    m.* = .{};
}

pub fn count(m: Marks) usize {
    return m.list.items.len;
}

pub fn items(m: Marks) []const Mark {
    return m.list.items;
}

pub fn indexOf(m: Marks, key: u64) ?usize {
    for (m.list.items, 0..) |mark, i| {
        if (mark.key == key) return i;
    }
    return null;
}

pub fn byKey(m: *Marks, key: u64) ?*Mark {
    const i = m.indexOf(key) orelse return null;
    return &m.list.items[i];
}

/// Starts a new undo step. Everything changed until the next call is undone
/// together.
pub fn beginGroup(m: *Marks) void {
    if (!m.group_used and m.group != 0) return;
    m.group +%= 1;
    m.group_used = false;
}

/// Hands the queued database work to the caller, who must apply all of it.
pub fn takeEffects(m: *Marks) []const Effect {
    return m.effects.items;
}

pub fn clearEffects(m: *Marks) void {
    m.effects.clearRetainingCapacity();
}

// -- changing it --------------------------------------------------------------

/// Adds a mark and returns its index.
///
/// `loading` is for marks coming back out of the library on open: they are
/// not a change to the document, so they are not dirty, not undoable, and
/// need nothing written.
pub fn add(m: *Marks, gpa: Allocator, mark: Mark, loading: bool) Allocator.Error!usize {
    var fresh = mark;
    fresh.key = m.next_key;
    m.next_key += 1;
    fresh.note = try m.own(mark.note);

    try m.list.append(gpa, fresh);
    const index = m.list.items.len - 1;
    m.revision +%= 1;
    if (loading) return index;

    m.dirty = true;
    try m.effects.append(gpa, .{ .insert = fresh.key });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .added, .after = fresh, .index = index });
    return index;
}

/// Removes the mark at `index`, returning it.
pub fn removeAt(m: *Marks, gpa: Allocator, index: usize) Allocator.Error!?Mark {
    if (index >= m.list.items.len) return null;
    // Ordered, not swap-removed: the list is drawn in the order it is held,
    // and overlapping highlights that reorder themselves when an unrelated
    // one is deleted look like a bug even though the pixels are the same.
    const gone = m.list.orderedRemove(index);
    m.revision +%= 1;
    m.dirty = true;
    try m.effects.append(gpa, .{ .delete = gone });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .removed, .before = gone, .index = index });
    return gone;
}

/// Every mark on the document, as one undo step.
pub fn clear(m: *Marks, gpa: Allocator) Allocator.Error!void {
    if (m.list.items.len == 0) return;
    m.beginGroup();
    while (m.list.items.len != 0) _ = try m.removeAt(gpa, m.list.items.len - 1);
    m.beginGroup();
}

pub fn recolour(m: *Marks, gpa: Allocator, index: usize, color: Color) Allocator.Error!void {
    if (index >= m.list.items.len) return;
    const before = m.list.items[index];
    if (std.meta.eql(before.color, color)) return;
    var after = before;
    after.color = color;
    try m.replace(gpa, index, before, after);
}

pub fn setNote(m: *Marks, gpa: Allocator, index: usize, note: []const u8) Allocator.Error!void {
    if (index >= m.list.items.len) return;
    const before = m.list.items[index];
    if (std.mem.eql(u8, before.note, note)) return;
    var after = before;
    after.note = try m.own(note);
    try m.replace(gpa, index, before, after);
}

fn replace(m: *Marks, gpa: Allocator, index: usize, before: Mark, after: Mark) Allocator.Error!void {
    m.list.items[index] = after;
    m.revision +%= 1;
    m.dirty = true;
    try m.effects.append(gpa, .{ .update = after.key });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .changed, .before = before, .after = after, .index = index });
}

/// Records the row a mark was given, once the library has written it.
pub fn setId(m: *Marks, key: u64, id: i64) void {
    const mark = m.byKey(key) orelse return;
    mark.id = id;
}

// -- undo ---------------------------------------------------------------------

/// Undoes the most recent step. Returns false when there is nothing to undo.
pub fn undo(m: *Marks, gpa: Allocator) Allocator.Error!bool {
    return m.travel(gpa, &m.undo_stack, &m.redo_stack, true);
}

pub fn redo(m: *Marks, gpa: Allocator) Allocator.Error!bool {
    return m.travel(gpa, &m.redo_stack, &m.undo_stack, false);
}

pub fn canUndo(m: Marks) bool {
    return m.undo_stack.items.len != 0;
}

pub fn canRedo(m: Marks) bool {
    return m.redo_stack.items.len != 0;
}

/// Pops one group from `from`, applies it backwards or forwards, and pushes
/// it onto `to`.
fn travel(m: *Marks, gpa: Allocator, from: *std.ArrayList(Change), to: *std.ArrayList(Change), backwards: bool) Allocator.Error!bool {
    if (from.items.len == 0) return false;
    const group = from.items[from.items.len - 1].group;

    // A group is applied in reverse order when undoing and in the original
    // order when redoing, so that indices recorded for a run of removals
    // still point where they did.
    var moved: std.ArrayList(Change) = .empty;
    defer moved.deinit(gpa);
    while (from.items.len != 0 and from.items[from.items.len - 1].group == group) {
        try moved.append(gpa, from.pop().?);
    }
    if (!backwards) std.mem.reverse(Change, moved.items);

    for (moved.items) |change| {
        const take_out = (change.kind == .added) == backwards;
        switch (change.kind) {
            .added, .removed => {
                if (take_out) {
                    // Take it out, wherever it is now.
                    const key = if (change.kind == .added) change.after.key else change.before.key;
                    const i = m.indexOf(key) orelse continue;
                    const gone = m.list.orderedRemove(i);
                    try m.effects.append(gpa, .{ .delete = gone });
                } else {
                    // Put it back, as a new row -- the old one is gone.
                    var mark = if (change.kind == .added) change.after else change.before;
                    mark.id = Mark.unsaved;
                    const slot = @min(change.index, m.list.items.len);
                    try m.list.insert(gpa, slot, mark);
                    try m.effects.append(gpa, .{ .insert = mark.key });
                }
            },
            .changed => {
                const key = change.after.key;
                const i = m.indexOf(key) orelse continue;
                var target = if (backwards) change.before else change.after;
                // The row id is whatever the mark has now, not whatever it
                // had when this was recorded -- an undo in between may have
                // rewritten it.
                target.id = m.list.items[i].id;
                m.list.items[i] = target;
                try m.effects.append(gpa, .{ .update = key });
            },
        }
        try to.append(gpa, change);
    }

    m.revision +%= 1;
    m.dirty = true;
    return true;
}

fn currentGroup(m: *Marks) u32 {
    if (m.group == 0) m.group = 1;
    m.group_used = true;
    return m.group;
}

fn record(m: *Marks, gpa: Allocator, change: Change) Allocator.Error!void {
    // A new change forks history: what could be redone no longer follows.
    m.redo_stack.clearRetainingCapacity();
    if (m.undo_stack.items.len >= history_limit) _ = m.undo_stack.orderedRemove(0);
    try m.undo_stack.append(gpa, change);
}

fn own(m: *Marks, text: []const u8) Allocator.Error![]const u8 {
    if (text.len == 0) return &.{};
    return m.strings.allocator().dupe(u8, text);
}

// -- asking about it ----------------------------------------------------------

/// The topmost mark containing `p` on `page`, which is the one a click means:
/// later marks are drawn over earlier ones, so the last match is the one
/// under the pointer.
pub fn at(m: Marks, page: u32, p: Point) ?usize {
    var i = m.list.items.len;
    while (i > 0) {
        i -= 1;
        const mark = m.list.items[i];
        if (mark.page == page and mark.box.contains(p)) return i;
    }
    return null;
}

/// Whether a box overlaps a mark already on the page.
pub fn overlaps(m: Marks, page: u32, area: Bounds) bool {
    for (m.list.items) |mark| {
        if (mark.page != page) continue;
        if (!mark.box.intersect(area).isEmpty()) return true;
    }
    return false;
}

/// Reading order: by page, then down the page, then along the line. The
/// order `n` and `N` walk highlights in, which should be the order a person
/// would find them by reading rather than the order they were made in.
pub fn readsBefore(a: Mark, b: Mark) bool {
    if (a.page != b.page) return a.page < b.page;
    // User space counts upwards, so higher on the page is a larger y.
    const ay = (a.box.min_y + a.box.max_y) * 0.5;
    const by = (b.box.min_y + b.box.max_y) * 0.5;
    if (@abs(ay - by) > 2) return ay > by;
    return a.box.min_x < b.box.min_x;
}

/// The key of the mark after (or before) `from` in reading order, wrapping.
/// With `from` null, the first (or last) one.
pub fn step(m: Marks, from: ?u64, forwards: bool) ?u64 {
    if (m.list.items.len == 0) return null;
    const current = if (from) |k| blk: {
        const i = m.indexOf(k) orelse break :blk null;
        break :blk m.list.items[i];
    } else null;

    var best: ?Mark = null;
    var wrap: ?Mark = null;
    for (m.list.items) |mark| {
        // The wrap candidate: the first mark of all, or the last.
        if (wrap == null or (if (forwards) readsBefore(mark, wrap.?) else readsBefore(wrap.?, mark))) wrap = mark;

        const c = current orelse continue;
        if (mark.key == c.key) continue;
        const ahead = if (forwards) readsBefore(c, mark) else readsBefore(mark, c);
        if (!ahead) continue;
        if (best == null or (if (forwards) readsBefore(mark, best.?) else readsBefore(best.?, mark))) best = mark;
    }
    if (current == null) return wrap.?.key;
    return (best orelse wrap.?).key;
}

/// The first mark at or after a point in reading order: where edit mode
/// starts when it is entered from the cursor.
pub fn atOrAfter(m: Marks, page: u32, p: Point) ?u64 {
    const probe: Mark = .{ .page = page, .box = .fromRect(p.x, p.y, p.x, p.y) };
    var best: ?Mark = null;
    for (m.list.items) |mark| {
        if (mark.page == page and mark.box.contains(p)) return mark.key;
        if (readsBefore(mark, probe)) continue;
        if (best == null or readsBefore(mark, best.?)) best = mark;
    }
    if (best) |b| return b.key;
    return m.step(null, true);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn box(x0: f32, y0: f32, x1: f32, y1: f32) Bounds {
    return .fromRect(x0, y0, x1, y1);
}

test "a mark added bumps the revision, which is how other views notice" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    const seen = m.revision;
    _ = try m.add(gpa, .{ .page = 0, .box = box(10, 10, 60, 24) }, false);
    try testing.expect(m.revision != seen);
}

test "marks loaded from the library are not changes: not dirty, not undoable, nothing to write" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .id = 4, .page = 0, .box = box(0, 0, 1, 1) }, true);
    try testing.expect(!m.dirty);
    try testing.expect(!m.canUndo());
    try testing.expectEqual(@as(usize, 0), m.takeEffects().len);

    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    try testing.expect(m.dirty);
    try testing.expect(m.canUndo());
    try testing.expectEqual(@as(usize, 1), m.takeEffects().len);
}

test "the mark under a point is the topmost one" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .page = 1, .box = box(0, 0, 100, 100) }, false);
    _ = try m.add(gpa, .{ .page = 1, .box = box(50, 50, 150, 150) }, false);

    try testing.expectEqual(@as(?usize, 1), m.at(1, .{ .x = 60, .y = 60 }));
    try testing.expectEqual(@as(?usize, 0), m.at(1, .{ .x = 10, .y = 10 }));
    try testing.expectEqual(@as(?usize, null), m.at(2, .{ .x = 60, .y = 60 }));
}

test "a removal is undone into the same place in the drawing order" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    for (0..3) |i| {
        m.beginGroup();
        _ = try m.add(gpa, .{ .page = 0, .box = box(@floatFromInt(i), 0, 1, 1) }, false);
    }
    const middle = m.items()[1].key;

    m.beginGroup();
    _ = try m.removeAt(gpa, 1);
    try testing.expectEqual(@as(usize, 2), m.count());

    try testing.expect(try m.undo(gpa));
    try testing.expectEqual(@as(usize, 3), m.count());
    try testing.expectEqual(middle, m.items()[1].key);

    try testing.expect(try m.redo(gpa));
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expectEqual(@as(?usize, null), m.indexOf(middle));
}

test "a group is undone as one step" {
    // Highlighting a six-line selection makes six marks, and one `u` takes
    // all six back.
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    m.beginGroup();
    for (0..6) |i| _ = try m.add(gpa, .{ .page = 1, .box = box(0, @floatFromInt(i), 1, 1) }, false);
    try testing.expectEqual(@as(usize, 7), m.count());

    try testing.expect(try m.undo(gpa));
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expect(try m.undo(gpa));
    try testing.expectEqual(@as(usize, 0), m.count());
    try testing.expect(!try m.undo(gpa));

    try testing.expect(try m.redo(gpa));
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expect(try m.redo(gpa));
    try testing.expectEqual(@as(usize, 7), m.count());
}

test "a new change after an undo forgets what could have been redone" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    _ = try m.undo(gpa);
    try testing.expect(m.canRedo());

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 2, .box = box(0, 0, 1, 1) }, false);
    try testing.expect(!m.canRedo());
}

test "recolouring and notes are undoable, and survive the undo of something else" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    const red: Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };

    m.beginGroup();
    try m.recolour(gpa, 0, red);
    m.beginGroup();
    try m.setNote(gpa, 0, "check this proof");
    try testing.expectEqualStrings("check this proof", m.items()[0].note);

    _ = try m.undo(gpa);
    try testing.expectEqualStrings("", m.items()[0].note);
    try testing.expectEqual(red, m.items()[0].color);

    _ = try m.undo(gpa);
    try testing.expect(m.items()[0].color.g > 0.5);

    _ = try m.redo(gpa);
    _ = try m.redo(gpa);
    try testing.expectEqual(red, m.items()[0].color);
    try testing.expectEqualStrings("check this proof", m.items()[0].note);
}

test "effects say exactly what the database must do, rows included" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    const key = m.items()[0].key;
    try testing.expectEqual(Effect{ .insert = key }, m.takeEffects()[0]);
    // What the reader does with an insert: write it, then record the row.
    m.setId(key, 41);
    m.clearEffects();

    m.beginGroup();
    _ = try m.removeAt(gpa, 0);
    try testing.expectEqual(@as(i64, 41), m.takeEffects()[0].delete.id);
    m.clearEffects();

    // Undoing the removal is an insert of a new row, not a resurrection of
    // row 41, which no longer exists.
    _ = try m.undo(gpa);
    try testing.expectEqual(Effect{ .insert = key }, m.takeEffects()[0]);
    try testing.expect(!m.items()[0].saved());
    m.setId(key, 42);
    m.clearEffects();

    // And the redo deletes the new row.
    _ = try m.redo(gpa);
    try testing.expectEqual(@as(i64, 42), m.takeEffects()[0].delete.id);
}

test "clearing everything is one step to undo" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    for (0..4) |i| {
        m.beginGroup();
        _ = try m.add(gpa, .{ .page = @intCast(i), .box = box(0, 0, 1, 1) }, false);
    }
    try m.clear(gpa);
    try testing.expectEqual(@as(usize, 0), m.count());
    _ = try m.undo(gpa);
    try testing.expectEqual(@as(usize, 4), m.count());
    // In the order they were in.
    for (m.items(), 0..) |mark, i| try testing.expectEqual(@as(u32, @intCast(i)), mark.page);
}

test "marks are walked in reading order, and wrap" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    // Made out of order: page 2, then the bottom of page 1, then its top.
    _ = try m.add(gpa, .{ .page = 2, .box = box(0, 700, 10, 710) }, true);
    _ = try m.add(gpa, .{ .page = 1, .box = box(0, 100, 10, 110) }, true);
    _ = try m.add(gpa, .{ .page = 1, .box = box(0, 700, 10, 710) }, true);
    const p2 = m.items()[0].key;
    const bottom = m.items()[1].key;
    const top = m.items()[2].key;

    try testing.expectEqual(top, m.step(null, true).?);
    try testing.expectEqual(bottom, m.step(top, true).?);
    try testing.expectEqual(p2, m.step(bottom, true).?);
    try testing.expectEqual(top, m.step(p2, true).?);
    try testing.expectEqual(p2, m.step(top, false).?);

    // From a point in the middle of page 1, the next is the bottom one.
    try testing.expectEqual(bottom, m.atOrAfter(1, .{ .x = 5, .y = 400 }).?);
    // And from past the end, it wraps to the start.
    try testing.expectEqual(top, m.atOrAfter(9, .{ .x = 5, .y = 400 }).?);
}

test "an empty group is not an undo step" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);
    m.beginGroup();
    m.beginGroup();
    m.beginGroup();
    try testing.expect(!try m.undo(gpa));
}
