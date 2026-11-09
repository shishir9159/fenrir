//! The marks on a document, the one copy of them, and their history.
//!
//! Two kinds, and one list. A highlight is a box over some words; a stroke is
//! where a pen went. They are the same kind of *fact* -- something a person
//! put on a page, in the page's own coordinates, which the reader keeps
//! beside the document rather than writing into it -- and everything this
//! file does to one it does to the other: one revision number, one undo
//! history, one order, one panel. A `kind` and a point list is what that
//! costs, against a second list with a second history that `u` would have had
//! to choose between.
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
//! Every change -- add, remove, recolour, a comment -- goes through a method
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
//! ## Anchors and comments
//!
//! Those six marks are also one **anchor**: they share a number, and that
//! is what a comment is made on. Comments are a second list in the same
//! history, so `u` after a comment takes the comment back and `u` after a
//! deletion brings the marks and what was written on them back together.
//! Many comments may hang from one anchor, and they read in the order they
//! were made.
//!
//! The numbers are the ones a PDF's `/NM` will carry -- Mímir writes them
//! as `f` and base 36 -- and they are handed out here, one past the highest
//! seen, because a comment has to name its anchor before either has a row.
//! The first comment on an anchor takes the anchor's own number, since in a
//! PDF it is the anchor's `/Contents`; later ones take numbers of their own.
//! An anchor whose last mark goes takes its comments with it.
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

/// What a mark is: a box over words, or a line a pen drew.
///
/// A tag on the struct rather than a union, because every field but two is
/// shared and the parts that walk this list -- undo, the effects queue,
/// reading order, the panel -- want a `Mark` and not a switch. The two that
/// are not shared are `points` and `width`, and both are empty on a block, as
/// a mark nobody has commented on has no comments.
pub const Kind = enum { block, ink };

/// How a block marks its words: PDF's four text-markup subtypes, so that
/// writing one into a file is a name and not a translation -- and an arrow,
/// which points at them from the margin and puts no colour on the text.
///
/// The arrow is the one that is not a text-markup subtype. A PDF holds it as
/// a `/Line` with an arrowhead at the words' end, drawn from its anchor's
/// first line, so it is still one annotation an anchor. It is what `c`
/// leaves when the `comment_anchor` setting is `arrow`, for a reader who
/// wants the page to stay as it was printed.
pub const Style = enum {
    highlight,
    underline,
    strikeout,
    squiggly,
    arrow,

    /// What a person calls it, where the tag is what PDF does.
    pub fn label(s: Style) []const u8 {
        return switch (s) {
            .highlight => "highlight",
            .underline => "underline",
            .strikeout => "strike-through",
            .squiggly => "squiggle",
            .arrow => "arrow",
        };
    }
};

/// One mark.
pub const Mark = struct {
    /// This session's name for it. Stable across undo and redo; see the note
    /// at the top of the file.
    key: u64 = 0,
    /// The row it is stored as in Mímir, or `unsaved`.
    id: i64 = unsaved,
    kind: Kind = .block,
    page: u32 = 0,
    /// In PDF user space. For ink this is where the pen went, bounded -- see
    /// `inkBounds` -- so that everything asking *where* a mark is can ask one
    /// field whichever kind it is.
    box: Bounds = .empty,
    color: Color = .{ .r = 1, .g = 0.9, .b = 0.2, .a = 1 },
    /// How a block is drawn. Ink is drawn as it went and ignores it.
    style: Style = .highlight,
    /// The anchor this mark is a line of; see "Anchors and comments" at the
    /// top. Zero until `add` gives it one, which makes it an anchor alone.
    anchor: u64 = 0,
    /// Where the pen went, in PDF user space, or empty for a block. Owned by
    /// the `Marks` it belongs to; see `owned`.
    points: []const Point = &.{},
    /// The pen's width in those same points, so a stroke keeps its weight
    /// against the type it was drawn over at every zoom. Zero on a block.
    width: f32 = 0,

    pub const unsaved: i64 = 0;

    pub fn saved(m: Mark) bool {
        return m.id != unsaved;
    }

    /// Whether a point is *on* this mark, which is a different question from
    /// whether it is in its box.
    ///
    /// For a block the two are the same. For ink they are not, and taking the
    /// box for the answer is what would make a circle drawn round a figure
    /// swallow every click inside the figure: a stroke is a line, so the test
    /// is the distance to that line. `slack` is how far off it a pointer may
    /// still be, in user-space points, since nobody can hit a hairline.
    pub fn hits(m: Mark, p: Point, slack: f32) bool {
        if (m.kind != .ink) return m.box.contains(p);
        // The box first: it rejects most of the list for the cost of four
        // compares, and a point outside it cannot be near the line inside.
        const reach = m.width * 0.5 + slack;
        if (!Bounds.fromRect(
            m.box.min_x - reach,
            m.box.min_y - reach,
            m.box.max_x + reach,
            m.box.max_y + reach,
        ).contains(p)) return false;

        const limit = reach * reach;
        var i: usize = 1;
        while (i < m.points.len) : (i += 1) {
            if (distanceSquared(m.points[i - 1], m.points[i], p) <= limit) return true;
        }
        return false;
    }
};

/// How far `p` is from the segment `a`-`b`, squared. Squared because every
/// caller compares it against a squared limit, and a square root per segment
/// per click is a root nobody reads.
fn distanceSquared(a: Point, b: Point, p: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = dx * dx + dy * dy;
    // A segment of no length is a point, which is the case a stroke of
    // repeated samples is made of.
    var t: f32 = 0;
    if (len > 0) {
        t = std.math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len, 0, 1);
    }
    const qx = a.x + t * dx - p.x;
    const qy = a.y + t * dy - p.y;
    return qx * qx + qy * qy;
}

/// The box a stroke covers, the pen's width included: what goes in `box`.
///
/// Half the width on every side, because the pen is a circle centred on the
/// path and the ink reaches that far past the last point. Without it the
/// bounds of a horizontal stroke would be a line of zero height, which every
/// `Bounds` test in this program would report as empty.
pub fn inkBounds(points: []const Point, width: f32) Bounds {
    if (points.len == 0) return .empty;
    var b: Bounds = .empty;
    for (points) |p| b = b.add(p);
    const r = @max(width * 0.5, 0.5);
    return .fromRect(b.min_x - r, b.min_y - r, b.max_x + r, b.max_y + r);
}

/// Thins a stroke down to the points that are actually a shape, in place,
/// returning the prefix that is left.
///
/// The pointer is sampled once a frame, so a slow careful line arrives as
/// hundreds of points a fraction of a point apart, nearly all of them on a
/// line between their neighbours. Two passes over them, both cheap:
///
///   * a point closer to the last kept one than `tolerance` is a sample of
///     the same place and is dropped;
///   * a point whose distance from the line between its neighbours is under
///     `tolerance` is on that line, and the line is already being drawn.
///
/// Not Douglas-Peucker, which would take a recursion and a stack to find a
/// slightly better subset of an input that is already at pointer resolution.
/// The first and last points are always kept: they are where the pen went
/// down and came up, which is the one thing about a stroke a reader aimed.
pub fn simplify(points: []Point, tolerance: f32) []Point {
    if (points.len < 3) return points;

    var out: usize = 1;
    const limit = tolerance * tolerance;
    for (points[1 .. points.len - 1]) |p| {
        const last = points[out - 1];
        const dx = p.x - last.x;
        const dy = p.y - last.y;
        if (dx * dx + dy * dy <= limit) continue;
        points[out] = p;
        out += 1;
    }
    points[out] = points[points.len - 1];
    out += 1;

    if (out < 3) return points[0..out];

    // The second pass, over what the first left: a point still between two
    // that describe it is not describing anything.
    var kept: usize = 1;
    var i: usize = 1;
    while (i < out - 1) : (i += 1) {
        if (distanceSquared(points[kept - 1], points[i + 1], points[i]) <= limit) continue;
        points[kept] = points[i];
        kept += 1;
    }
    points[kept] = points[out - 1];
    return points[0 .. kept + 1];
}

/// A comment, on an anchor.
pub const Comment = struct {
    /// This session's name for it, as a mark's `key` is.
    key: u64 = 0,
    /// The row it is stored as in Mímir, or `Mark.unsaved`.
    id: i64 = Mark.unsaved,
    /// The anchor it is on: the `anchor` of the marks it is about.
    anchor: u64 = 0,
    /// Its own number, which a link names it by. The first comment on an
    /// anchor has the anchor's; see the top of the file.
    name: u64 = 0,
    /// Owned by the `Marks` it belongs to; see `owned`.
    text: []const u8 = &.{},

    pub fn saved(c: Comment) bool {
        return c.id != Mark.unsaved;
    }
};

/// What the library has to do to catch up with the list.
pub const Effect = union(enum) {
    /// Write the mark with this key as a new row, and give it the row's id.
    insert: u64,
    /// This mark is gone: delete its row, if it has one. The whole mark and
    /// not only the row, so that a plugin can be told what was removed.
    delete: Mark,
    /// Rewrite the colour and style of the mark with this key.
    update: u64,
    /// The same three for a comment, whose update is its text.
    comment_insert: u64,
    comment_delete: Comment,
    comment_update: u64,
};

/// One reversible change. Both halves are whole records rather than a diff,
/// because a mark is five numbers and a slice, and a diff would be a second
/// thing to get wrong.
const Change = struct {
    group: u32,
    kind: Action,
    /// As it was. Unused for an add.
    before: Item = .{ .mark = .{} },
    /// As it became. Unused for a remove.
    after: Item = .{ .mark = .{} },
    /// Where in the list it was, so an undone removal goes back to the same
    /// place in the drawing order rather than on top of everything. Unused
    /// for a comment, whose place is worked out from its anchor.
    index: usize = 0,

    /// Named for the edit and not `Kind`, which is now what a mark is.
    const Action = enum { added, removed, changed };
    const Item = union(enum) { mark: Mark, comment: Comment };
};

list: std.ArrayList(Mark) = .empty,

/// Every comment, ordered by anchor and then by when it was made, so that
/// the comments on one anchor are one run found by a binary search. That is
/// asked once per mark per frame, by the tab drawn on a commented mark.
comments: std.ArrayList(Comment) = .empty,

/// The next anchor or comment number to hand out.
next_name: u64 = 1,

/// For each anchor, the index of its first line in reading order: the mark
/// a comment is shown on, and an arrow drawn from. Worked out again when
/// `revision` has moved past `led_revision`, never per frame; see `heads`.
led: std.AutoHashMapUnmanaged(u64, usize) = .empty,
led_revision: u64 = 0,

/// Bumped by every change. A view redraws when this is not the number it last
/// drew.
revision: u64 = 1,

/// Set by any change a person made, and not by loading from the library.
dirty: bool = false,

/// Database work waiting for the reader to do it.
effects: std.ArrayList(Effect) = .empty,

undo_stack: std.ArrayList(Change) = .empty,
redo_stack: std.ArrayList(Change) = .empty,

/// Comment text, and the points of every stroke. An arena, because a
/// comment that is edited leaves its old bytes behind in the undo history,
/// and freeing them would leave history pointing at nothing. A document
/// collects kilobytes of these in a long session, not megabytes, and all of
/// it goes when the document is closed.
///
/// It was `strings` when notes were the only thing in it. A stroke's points
/// are here for the same argument and under the same lifetime, so the field
/// is named for what it does rather than for what was first put in it.
owned: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

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
    m.comments.deinit(gpa);
    m.led.deinit(gpa);
    m.effects.deinit(gpa);
    m.undo_stack.deinit(gpa);
    m.redo_stack.deinit(gpa);
    m.owned.deinit();
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
///
/// A stroke may be handed in with the caller's own points and an empty box:
/// both are copied and computed here, so that the one place a mark is made
/// is also the one place its bounds are worked out and nothing downstream
/// can be holding the scratch buffer the pointer was sampled into.
pub fn add(m: *Marks, gpa: Allocator, mark: Mark, loading: bool) Allocator.Error!usize {
    var fresh = mark;
    fresh.key = m.next_key;
    m.next_key += 1;
    if (mark.anchor == 0) fresh.anchor = m.newName() else m.claim(mark.anchor);
    if (mark.kind == .ink) {
        fresh.points = try m.ownPoints(mark.points);
        fresh.box = inkBounds(fresh.points, fresh.width);
    }

    try m.list.append(gpa, fresh);
    const index = m.list.items.len - 1;
    m.revision +%= 1;
    if (loading) return index;

    m.dirty = true;
    try m.effects.append(gpa, .{ .insert = fresh.key });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .added, .after = .{ .mark = fresh }, .index = index });
    return index;
}

/// A number no anchor or comment has. The lines of one selection are given
/// one before the first of them is added, which is what makes them one
/// anchor.
pub fn newName(m: *Marks) u64 {
    defer m.next_name += 1;
    return m.next_name;
}

/// Keeps the next number past one already in use: each mark and comment
/// read back from the library passes through here.
fn claim(m: *Marks, n: u64) void {
    m.next_name = @max(m.next_name, n +| 1);
}

/// Removes the mark at `index`, returning it.
///
/// When it was the last line of its anchor, the comments on the anchor go
/// too, in the same undo step: there is nothing left for them to be about,
/// and one `u` brings the words and what was said about them back together.
pub fn removeAt(m: *Marks, gpa: Allocator, index: usize) Allocator.Error!?Mark {
    if (index >= m.list.items.len) return null;
    // Ordered, not swap-removed: the list is drawn in the order it is held,
    // and overlapping highlights that reorder themselves when an unrelated
    // one is deleted look like a bug even though the pixels are the same.
    const gone = m.list.orderedRemove(index);
    m.revision +%= 1;
    m.dirty = true;
    try m.effects.append(gpa, .{ .delete = gone });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .removed, .before = .{ .mark = gone }, .index = index });
    if (m.lineCount(gone.anchor) == 0) {
        while (m.said(gone.anchor).len != 0) _ = try m.removeComment(gpa, m.saidRange(gone.anchor)[0]);
    }
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

/// A block drawn another way. A stroke has no other way, and stays as it is.
pub fn restyle(m: *Marks, gpa: Allocator, index: usize, style: Style) Allocator.Error!void {
    if (index >= m.list.items.len) return;
    const before = m.list.items[index];
    if (before.kind == .ink or before.style == style) return;
    var after = before;
    after.style = style;
    try m.replace(gpa, index, before, after);
}

fn replace(m: *Marks, gpa: Allocator, index: usize, before: Mark, after: Mark) Allocator.Error!void {
    m.list.items[index] = after;
    m.revision +%= 1;
    m.dirty = true;
    try m.effects.append(gpa, .{ .update = after.key });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .changed, .before = .{ .mark = before }, .after = .{ .mark = after }, .index = index });
}

/// Records the row a mark was given, once the library has written it.
pub fn setId(m: *Marks, key: u64, id: i64) void {
    const mark = m.byKey(key) orelse return;
    mark.id = id;
}

// -- comments -----------------------------------------------------------------

/// Adds a comment on `comment.anchor` and returns its index. `loading` is
/// as for `add`.
///
/// A comment handed in without a number is given one: the anchor's own when
/// no comment on the anchor has it yet, and a new one otherwise.
pub fn addComment(m: *Marks, gpa: Allocator, comment: Comment, loading: bool) Allocator.Error!usize {
    std.debug.assert(comment.anchor != 0);
    var fresh = comment;
    fresh.key = m.next_key;
    m.next_key += 1;
    fresh.text = try m.own(comment.text);
    if (comment.name == 0) {
        fresh.name = if (m.named(comment.anchor)) m.newName() else comment.anchor;
    } else m.claim(comment.name);

    const index = m.commentSlot(fresh);
    try m.comments.insert(gpa, index, fresh);
    m.revision +%= 1;
    if (loading) return index;

    m.dirty = true;
    try m.effects.append(gpa, .{ .comment_insert = fresh.key });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .added, .after = .{ .comment = fresh } });
    return index;
}

pub fn removeComment(m: *Marks, gpa: Allocator, index: usize) Allocator.Error!?Comment {
    if (index >= m.comments.items.len) return null;
    const gone = m.comments.orderedRemove(index);
    m.revision +%= 1;
    m.dirty = true;
    try m.effects.append(gpa, .{ .comment_delete = gone });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .removed, .before = .{ .comment = gone } });
    return gone;
}

pub fn setText(m: *Marks, gpa: Allocator, index: usize, text: []const u8) Allocator.Error!void {
    if (index >= m.comments.items.len) return;
    const before = m.comments.items[index];
    if (std.mem.eql(u8, before.text, text)) return;
    var after = before;
    after.text = try m.own(text);
    m.comments.items[index] = after;
    m.revision +%= 1;
    m.dirty = true;
    try m.effects.append(gpa, .{ .comment_update = after.key });
    try m.record(gpa, .{ .group = m.currentGroup(), .kind = .changed, .before = .{ .comment = before }, .after = .{ .comment = after } });
}

/// Files the comments on one anchor under another, each as a removal and an
/// addition, since a comment moved is a different comment to the library.
///
/// What marking words again does: a highlight made over a commented one
/// replaces its marks, and the comments follow the words rather than going
/// with the marks they were first made on.
pub fn moveComments(m: *Marks, gpa: Allocator, from: u64, to: u64) Allocator.Error!void {
    if (from == to) return;
    while (m.said(from).len != 0) {
        const gone = (try m.removeComment(gpa, m.saidRange(from)[0])).?;
        _ = try m.addComment(gpa, .{ .anchor = to, .text = gone.text }, false);
    }
}

/// Records the row a comment was given, once the library has written it.
pub fn setCommentId(m: *Marks, key: u64, id: i64) void {
    const i = m.commentIndex(key) orelse return;
    m.comments.items[i].id = id;
}

pub fn commentIndex(m: Marks, key: u64) ?usize {
    for (m.comments.items, 0..) |c, i| {
        if (c.key == key) return i;
    }
    return null;
}

/// The comments on an anchor, oldest first.
pub fn said(m: Marks, anchor: u64) []const Comment {
    const r = m.saidRange(anchor);
    return m.comments.items[r[0]..r[1]];
}

/// Where the comments on an anchor are in `comments`.
pub fn saidRange(m: Marks, anchor: u64) [2]usize {
    const list = m.comments.items;
    const below = struct {
        fn f(a: u64, c: Comment) bool {
            return c.anchor < a;
        }
    }.f;
    const upto = struct {
        fn f(a: u64, c: Comment) bool {
            return c.anchor <= a;
        }
    }.f;
    const lo = std.sort.partitionPoint(Comment, list, anchor, below);
    return .{ lo, lo + std.sort.partitionPoint(Comment, list[lo..], anchor, upto) };
}

/// How many marks are lines of `anchor`.
pub fn lineCount(m: Marks, anchor: u64) usize {
    var n: usize = 0;
    for (m.list.items) |mark| n += @intFromBool(mark.anchor == anchor);
    return n;
}

/// Whether a comment on `anchor` already has the anchor's own number.
fn named(m: Marks, anchor: u64) bool {
    for (m.said(anchor)) |c| {
        if (c.name == anchor) return true;
    }
    return false;
}

/// Where a comment goes so that `comments` stays ordered by anchor, then by
/// key -- and keys are handed out in the order things are made.
fn commentSlot(m: Marks, c: Comment) usize {
    const before = struct {
        fn f(new: Comment, x: Comment) bool {
            return x.anchor < new.anchor or (x.anchor == new.anchor and x.key < new.key);
        }
    }.f;
    return std.sort.partitionPoint(Comment, m.comments.items, c, before);
}

/// Whether the mark at `index` is the first of its anchor's lines in
/// reading order: where an arrow is drawn from.
///
/// Asked of every mark every frame, so the answer is a table rebuilt when
/// the marks change rather than a walk of the anchor's lines per mark.
pub fn heads(m: *Marks, gpa: Allocator, index: usize) bool {
    if (m.led_revision != m.revision) m.relead(gpa) catch return false;
    return m.led.get(m.list.items[index].anchor) == index;
}

/// Whether the mark at `index` is where its anchor's comments are shown:
/// its first line, on an anchor that has any.
pub fn leads(m: *Marks, gpa: Allocator, index: usize) bool {
    return m.said(m.list.items[index].anchor).len != 0 and m.heads(gpa, index);
}

fn relead(m: *Marks, gpa: Allocator) Allocator.Error!void {
    m.led.clearRetainingCapacity();
    for (m.list.items, 0..) |mark, i| {
        const lead = try m.led.getOrPut(gpa, mark.anchor);
        if (!lead.found_existing or readsBefore(mark, m.list.items[lead.value_ptr.*])) lead.value_ptr.* = i;
    }
    m.led_revision = m.revision;
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
    //
    // Popping gives both of those with no reordering here, and a
    // `std.mem.reverse` on the redo path is wrong however obvious it looks:
    // `record` appends chronologically, so an undo pops the group reversed
    // and pushes it to the redo stack that way, and popping it back off is
    // already chronological. Reversing it again replayed six insertions at
    // indices 6,5,4,3,2,1 against a list growing 1,2,3 -- wrong stacking
    // order, the wrong note restored, and the undo stack left reversed so
    // the next undo was wrong too.
    var moved: std.ArrayList(Change) = .empty;
    defer moved.deinit(gpa);
    while (from.items.len != 0 and from.items[from.items.len - 1].group == group) {
        try moved.append(gpa, from.pop().?);
    }

    for (moved.items) |change| {
        const take_out = (change.kind == .added) == backwards;
        switch (change.kind) {
            .added, .removed => {
                const item = if (change.kind == .added) change.after else change.before;
                if (take_out) switch (item) {
                    // Take it out, wherever it is now.
                    .mark => |mark| {
                        const i = m.indexOf(mark.key) orelse continue;
                        try m.effects.append(gpa, .{ .delete = m.list.orderedRemove(i) });
                    },
                    .comment => |c| {
                        const i = m.commentIndex(c.key) orelse continue;
                        try m.effects.append(gpa, .{ .comment_delete = m.comments.orderedRemove(i) });
                    },
                } else switch (item) {
                    // Put it back, as a new row -- the old one is gone.
                    .mark => |mark| {
                        var back = mark;
                        back.id = Mark.unsaved;
                        try m.list.insert(gpa, @min(change.index, m.list.items.len), back);
                        try m.effects.append(gpa, .{ .insert = back.key });
                    },
                    .comment => |c| {
                        var back = c;
                        back.id = Mark.unsaved;
                        try m.comments.insert(gpa, m.commentSlot(back), back);
                        try m.effects.append(gpa, .{ .comment_insert = back.key });
                    },
                }
            },
            // The row id is whatever the record has now, not whatever it had
            // when this was recorded -- an undo in between may have
            // rewritten it.
            .changed => switch (if (backwards) change.before else change.after) {
                .mark => |mark| {
                    const i = m.indexOf(mark.key) orelse continue;
                    var target = mark;
                    target.id = m.list.items[i].id;
                    m.list.items[i] = target;
                    try m.effects.append(gpa, .{ .update = mark.key });
                },
                .comment => |c| {
                    const i = m.commentIndex(c.key) orelse continue;
                    var target = c;
                    target.id = m.comments.items[i].id;
                    m.comments.items[i] = target;
                    try m.effects.append(gpa, .{ .comment_update = c.key });
                },
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
    return m.owned.allocator().dupe(u8, text);
}

fn ownPoints(m: *Marks, points: []const Point) Allocator.Error![]const Point {
    if (points.len == 0) return &.{};
    return m.owned.allocator().dupe(Point, points);
}

// -- asking about it ----------------------------------------------------------

/// How far off a stroke a pointer may be and still be taken to have hit it,
/// in user-space points. About a millimetre, which is the slack every
/// interface gives a line you are asked to click on.
pub const ink_slack: f32 = 3;

/// The topmost mark under `p` on `page`, which is the one a click means:
/// later marks are drawn over earlier ones, so the last match is the one
/// under the pointer.
pub fn at(m: Marks, page: u32, p: Point) ?usize {
    var i = m.list.items.len;
    while (i > 0) {
        i -= 1;
        const mark = m.list.items[i];
        if (mark.page == page and mark.hits(p, ink_slack)) return i;
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

/// A colour a filter can name, by the name its swatch goes by.
pub const Swatch = struct { name: []const u8, color: Color };

/// What the annotations panel shows, and so what `]a` and `]c` walk, and
/// edit mode's `i`, `n`, `N` and `d`.
///
/// Typed as words. Words of one sort are alternatives, and every sort named
/// must hold: `yellow green #question` is a yellow or green mark with a
/// comment that says `#question`. The sorts are a swatch's name; a style, or
/// `ink`; `commented`; and any other word, which a comment on the mark's
/// anchor must contain -- so a `#tag` is only a word, and needs no syntax of
/// its own. Case is ignored.
pub const Filter = struct {
    pub const max_terms = 8;

    terms: u8 = 0,
    styles: std.EnumSet(Style) = .empty,
    ink: bool = false,
    commented: bool = false,
    colours: [max_terms]Color = undefined,
    colour_count: u8 = 0,
    /// Borrowed from the text parsed, which must outlive the filter.
    words: [max_terms][]const u8 = undefined,
    word_count: u8 = 0,

    pub fn parse(text: []const u8, swatches: []const Swatch) Filter {
        var f: Filter = .{};
        var it = std.mem.tokenizeAny(u8, text, " \t");
        while (it.next()) |word| : (f.terms += 1) {
            if (f.terms == max_terms) break;
            if (styleNamed(word)) |s| {
                f.styles.insert(s);
            } else if (std.ascii.eqlIgnoreCase(word, "ink")) {
                f.ink = true;
            } else if (std.ascii.eqlIgnoreCase(word, "commented")) {
                f.commented = true;
            } else if (swatchNamed(swatches, word)) |c| {
                f.colours[f.colour_count] = c;
                f.colour_count += 1;
            } else {
                f.words[f.word_count] = word;
                f.word_count += 1;
            }
        }
        return f;
    }

    pub fn isEmpty(f: *const Filter) bool {
        return f.terms == 0;
    }

    /// `written` is what was written on the mark's anchor: `Marks.said`.
    pub fn matches(f: *const Filter, m: Mark, written: []const Comment) bool {
        if (f.ink or f.styles.count() != 0) {
            if (!(if (m.kind == .ink) f.ink else f.styles.contains(m.style))) return false;
        }
        if (f.colour_count != 0) {
            for (f.colours[0..f.colour_count]) |c| {
                if (sameColour(c, m.color)) break;
            } else return false;
        }
        if (f.commented and written.len == 0) return false;
        for (f.words[0..f.word_count]) |w| {
            for (written) |c| {
                if (std.ascii.findIgnoreCase(c.text, w) != null) break;
            } else return false;
        }
        return true;
    }

    fn styleNamed(word: []const u8) ?Style {
        inline for (@typeInfo(Style).@"enum".field_names) |name| {
            const s = @field(Style, name);
            if (std.ascii.eqlIgnoreCase(word, name) or std.ascii.eqlIgnoreCase(word, s.label())) return s;
        }
        return null;
    }

    fn swatchNamed(swatches: []const Swatch, word: []const u8) ?Color {
        for (swatches) |s| {
            if (std.ascii.eqlIgnoreCase(word, s.name)) return s.color;
        }
        return null;
    }

    /// Equal as the library stores them, a byte a channel: a mark read back
    /// from `#f7e733` is the yellow swatch, whatever float it was made from.
    fn sameColour(a: Color, b: Color) bool {
        const byte = struct {
            fn of(v: f32) u8 {
                return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
            }
        }.of;
        return byte(a.r) == byte(b.r) and byte(a.g) == byte(b.g) and byte(a.b) == byte(b.b);
    }
};

/// Where `jump` landed, and where that is among the marks it could have.
pub const Jumped = struct {
    key: u64,
    /// It went past the last (or the first) and came round again.
    wrapped: bool,
    /// From 1, in reading order, among the marks that qualified.
    place: usize,
    of: usize,
};

/// The mark after (or before) `from` in reading order, wrapping, among those
/// `filter` lets through. Null when none does.
///
/// `from` is a place, not necessarily a mark: a point is a mark with a key of
/// zero, which no mark has, and a box of no size -- the probe `atOrAfter`
/// makes. A real mark is skipped as itself, so stepping from one never lands
/// on it again unless it is the only one.
pub fn jump(m: Marks, from: Mark, forwards: bool, filter: *const Filter) ?Jumped {
    var best: ?Mark = null;
    var wrap: ?Mark = null;
    for (m.list.items) |mark| {
        if (!filter.matches(mark, m.said(mark.anchor))) continue;
        if (wrap == null or (if (forwards) readsBefore(mark, wrap.?) else readsBefore(wrap.?, mark))) wrap = mark;
        if (mark.key == from.key) continue;
        const ahead = if (forwards) readsBefore(from, mark) else readsBefore(mark, from);
        if (!ahead) continue;
        if (best == null or (if (forwards) readsBefore(mark, best.?) else readsBefore(best.?, mark))) best = mark;
    }
    const to = best orelse wrap orelse return null;
    const where = m.placeOf(to, filter);
    return .{ .key = to.key, .wrapped = best == null, .place = where.place, .of = where.of };
}

pub const Place = struct { place: usize, of: usize };

/// Where `mark` falls in reading order among the marks `filter` lets
/// through: from 1, of how many. One count for the jump and the status
/// line, so that the line's `edit 2/5` is the count `n` steps through.
pub fn placeOf(m: Marks, mark: Mark, filter: *const Filter) Place {
    var where: Place = .{ .place = 1, .of = 0 };
    for (m.list.items) |other| {
        if (!filter.matches(other, m.said(other.anchor))) continue;
        where.of += 1;
        if (readsBefore(other, mark)) where.place += 1;
    }
    return where;
}

/// Where `jumpComment` landed.
pub const JumpedComment = struct {
    /// The comment, and the line it is shown on.
    key: u64,
    mark: u64,
    wrapped: bool,
    /// From 1, in the order `jumpComment` reads, among those that qualified.
    place: usize,
    of: usize,
};

/// The comment after (or before) a place, wrapping, among those on marks
/// `filter` lets through. Null when there is none.
///
/// Comments are read in the order of the lines they are shown on, and those
/// on one anchor in the order they were made, so `]c` reads a thread through
/// before it moves on. `after` is the comment the walk stands on, if it
/// stands on one. From a mark that is not one, it starts with that mark's
/// own comments: the walk stands before them.
pub fn jumpComment(m: *Marks, gpa: Allocator, from: Mark, after: ?u64, forwards: bool, filter: *const Filter) ?JumpedComment {
    if (m.led_revision != m.revision) m.relead(gpa) catch return null;

    var stand: Spot = .{ .mark = from, .key = 0 };
    if (from.key != 0) {
        if (m.leadLine(from.anchor)) |i| stand.mark = m.list.items[i];
    }
    if (after) |k| {
        if (m.commentIndex(k)) |i| {
            const c = m.comments.items[i];
            if (m.leadLine(c.anchor)) |l| stand = .{ .mark = m.list.items[l], .key = c.key };
        }
    }

    var best: ?Spot = null;
    var wrap: ?Spot = null;
    for (m.comments.items) |c| {
        const spot = m.spotOf(c, filter) orelse continue;
        if (wrap == null or (if (forwards) spot.before(wrap.?) else wrap.?.before(spot))) wrap = spot;
        if (c.key == stand.key) continue;
        const ahead = if (forwards) stand.before(spot) else spot.before(stand);
        if (!ahead) continue;
        if (best == null or (if (forwards) spot.before(best.?) else best.?.before(spot))) best = spot;
    }
    const to = best orelse wrap orelse return null;

    var place: usize = 1;
    var of: usize = 0;
    for (m.comments.items) |c| {
        const spot = m.spotOf(c, filter) orelse continue;
        of += 1;
        if (spot.before(to)) place += 1;
    }
    return .{ .key = to.key, .mark = to.mark.key, .wrapped = best == null, .place = place, .of = of };
}

/// Every comment that is on a line, by its index in `comments`, in the order
/// `jumpComment` reads them: what a plugin's `fenrir.comments()` lists.
pub fn readOrder(m: *Marks, gpa: Allocator, out: *std.ArrayList(usize)) Allocator.Error!void {
    if (m.led_revision != m.revision) try m.relead(gpa);
    out.clearRetainingCapacity();
    const any: Filter = .{};
    for (m.comments.items, 0..) |c, i| {
        if (m.spotOf(c, &any) != null) try out.append(gpa, i);
    }
    const by = struct {
        fn less(marks: *Marks, a: usize, b: usize) bool {
            const none: Filter = .{};
            const x = marks.spotOf(marks.comments.items[a], &none).?;
            const y = marks.spotOf(marks.comments.items[b], &none).?;
            return x.before(y);
        }
    }.less;
    std.mem.sort(usize, out.items, m, by);
}

/// The index of an anchor's first line in reading order, when it has one:
/// where a comment is shown, and the page a plugin is told it is on.
pub fn firstLine(m: *Marks, gpa: Allocator, anchor: u64) ?usize {
    if (m.led_revision != m.revision) m.relead(gpa) catch return null;
    return m.leadLine(anchor);
}

/// A comment's place in `jumpComment`'s order: the line it is shown on, then
/// when it was made.
const Spot = struct {
    mark: Mark,
    key: u64,

    fn before(a: Spot, b: Spot) bool {
        if (a.mark.key == b.mark.key) return a.key < b.key;
        return readsBefore(a.mark, b.mark);
    }
};

/// Where a comment is read, or null when it is not to be: on an anchor
/// with no line left, or on a mark the filter hides. Needs `led` current.
fn spotOf(m: *const Marks, c: Comment, filter: *const Filter) ?Spot {
    const i = m.leadLine(c.anchor) orelse return null;
    const mark = m.list.items[i];
    if (!filter.matches(mark, m.said(c.anchor))) return null;
    return .{ .mark = mark, .key = c.key };
}

/// The index of an anchor's first line in reading order, if it has a line.
/// Needs `led` current.
fn leadLine(m: *const Marks, anchor: u64) ?usize {
    return m.led.get(anchor);
}

/// The first mark `filter` lets through at or after a point in reading
/// order, wrapping: where edit mode starts when it is entered from the
/// cursor. Null when none does.
pub fn atOrAfter(m: Marks, page: u32, p: Point, filter: *const Filter) ?u64 {
    const probe: Mark = .{ .page = page, .box = .fromRect(p.x, p.y, p.x, p.y) };
    var best: ?Mark = null;
    var first: ?Mark = null;
    for (m.list.items) |mark| {
        if (!filter.matches(mark, m.said(mark.anchor))) continue;
        if (mark.page == page and mark.box.contains(p)) return mark.key;
        if (first == null or readsBefore(mark, first.?)) first = mark;
        if (readsBefore(mark, probe)) continue;
        if (best == null or readsBefore(mark, best.?)) best = mark;
    }
    const to = best orelse first orelse return null;
    return to.key;
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

test "a group is undone as one step, and redone in the order it was made" {
    // Highlighting a six-line selection makes six marks, and one `u` takes
    // all six back.
    //
    // The order is asserted and not only the count: this test passed while
    // `travel` reversed the redo path, because six marks are six marks
    // whichever way round they go back in. See the comment in `travel`.
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    m.beginGroup();
    for (0..6) |i| {
        const y: f32 = @floatFromInt(i);
        _ = try m.add(gpa, .{ .page = 1, .box = box(0, y, 1, y + 1) }, false);
    }
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
    for (0..6) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), m.items()[i + 1].box.min_y);
    }

    // And the undo stack the redo rebuilt is in the same order the first one
    // was, so a second round trip lands in the same place.
    try testing.expect(try m.undo(gpa));
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expect(try m.redo(gpa));
    for (0..6) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), m.items()[i + 1].box.min_y);
    }
}

test "a comment changed twice in one group redoes to the last of them" {
    // The other half of the reversal: a `.changed` run replayed backwards
    // restores the first value instead of the last.
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    const anchor = m.items()[0].anchor;
    _ = try m.addComment(gpa, .{ .anchor = anchor }, false);
    m.beginGroup();
    try m.setText(gpa, 0, "first");
    try m.setText(gpa, 0, "second");
    try testing.expectEqualStrings("second", m.said(anchor)[0].text);

    try testing.expect(try m.undo(gpa));
    try testing.expectEqualStrings("", m.said(anchor)[0].text);
    try testing.expect(try m.redo(gpa));
    try testing.expectEqualStrings("second", m.said(anchor)[0].text);
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

test "recolouring and comments are undoable, and survive the undo of something else" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1) }, false);
    const anchor = m.items()[0].anchor;
    const red: Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };

    m.beginGroup();
    try m.recolour(gpa, 0, red);
    m.beginGroup();
    _ = try m.addComment(gpa, .{ .anchor = anchor, .text = "check this proof" }, false);
    try testing.expectEqualStrings("check this proof", m.said(anchor)[0].text);

    _ = try m.undo(gpa);
    try testing.expectEqual(@as(usize, 0), m.said(anchor).len);
    try testing.expectEqual(red, m.items()[0].color);

    _ = try m.undo(gpa);
    try testing.expect(m.items()[0].color.g > 0.5);

    _ = try m.redo(gpa);
    _ = try m.redo(gpa);
    try testing.expectEqual(red, m.items()[0].color);
    try testing.expectEqualStrings("check this proof", m.said(anchor)[0].text);
}

test "a style is undoable and written, and a stroke has none to change" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 10, 10) }, true);
    const pen = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 9 } };
    _ = try m.add(gpa, .{ .kind = .ink, .page = 0, .points = &pen, .width = 1 }, true);

    m.beginGroup();
    try m.restyle(gpa, 0, .squiggly);
    try testing.expectEqual(Style.squiggly, m.items()[0].style);
    try testing.expectEqual(@as(u64, m.items()[0].key), m.takeEffects()[0].update);

    // The same style again is no change, and ink is drawn as it went.
    const revision = m.revision;
    try m.restyle(gpa, 0, .squiggly);
    try m.restyle(gpa, 1, .underline);
    try testing.expectEqual(revision, m.revision);
    try testing.expectEqual(Style.highlight, m.items()[1].style);

    _ = try m.undo(gpa);
    try testing.expectEqual(Style.highlight, m.items()[0].style);
    _ = try m.redo(gpa);
    try testing.expectEqual(Style.squiggly, m.items()[0].style);
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
    const p2 = m.items()[0];
    const bottom = m.items()[1];
    const top = m.items()[2];
    const any: Filter = .{};

    try testing.expectEqual(bottom.key, m.jump(top, true, &any).?.key);
    try testing.expectEqual(p2.key, m.jump(bottom, true, &any).?.key);
    try testing.expectEqual(top.key, m.jump(p2, true, &any).?.key);
    try testing.expectEqual(p2.key, m.jump(top, false, &any).?.key);

    // From a point in the middle of page 1, the next is the bottom one.
    try testing.expectEqual(bottom.key, m.atOrAfter(1, .{ .x = 5, .y = 400 }, &any).?);
    // And from past the end, it wraps to the start.
    try testing.expectEqual(top.key, m.atOrAfter(9, .{ .x = 5, .y = 400 }, &any).?);
}

test "a jump goes to the next mark from a point or a mark, and can ask for a comment" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .page = 1, .box = box(0, 700, 10, 710) }, true);
    _ = try m.add(gpa, .{ .page = 1, .box = box(0, 400, 10, 410) }, true);
    _ = try m.add(gpa, .{ .page = 2, .box = box(0, 700, 10, 710) }, true);
    _ = try m.addComment(gpa, .{ .anchor = m.items()[1].anchor, .text = "why?" }, true);
    const top = m.items()[0];
    const noted = m.items()[1];
    const p2 = m.items()[2];
    const any: Filter = .{};
    const commented: Filter = .{ .commented = true };

    // From a point between the first two: forwards is the middle one,
    // backwards the top one, and neither wrapped.
    const between: Mark = .{ .page = 1, .box = box(5, 500, 5, 500) };
    const fwd = m.jump(between, true, &any).?;
    try testing.expectEqual(noted.key, fwd.key);
    try testing.expect(!fwd.wrapped);
    try testing.expectEqual(@as(usize, 2), fwd.place);
    try testing.expectEqual(@as(usize, 3), fwd.of);
    try testing.expectEqual(top.key, m.jump(between, false, &any).?.key);

    // From a mark it never lands on itself, and past the end it wraps.
    try testing.expectEqual(p2.key, m.jump(noted, true, &any).?.key);
    const round = m.jump(p2, true, &any).?;
    try testing.expectEqual(top.key, round.key);
    try testing.expect(round.wrapped);

    // Only the commented one counts for a comment, whichever way and from
    // where.
    const c = m.jump(p2, true, &commented).?;
    try testing.expectEqual(noted.key, c.key);
    try testing.expect(c.wrapped);
    try testing.expectEqual(@as(usize, 1), c.of);
    try testing.expectEqual(noted.key, m.jump(noted, false, &commented).?.key);

    // And with no comment anywhere there is nothing to go to.
    var bare: Marks = .{};
    defer bare.deinit(gpa);
    _ = try bare.add(gpa, .{ .page = 0, .box = box(0, 0, 10, 10) }, true);
    try testing.expect(bare.jump(between, true, &commented) == null);
}

test "a filter's words of one sort are alternatives, and every sort must hold" {
    const yellow: Color = .{ .r = 247.0 / 255.0, .g = 231.0 / 255.0, .b = 51.0 / 255.0, .a = 1 };
    const green: Color = .{ .r = 63.0 / 255.0, .g = 163.0 / 255.0, .b = 77.0 / 255.0, .a = 1 };
    const swatches = [_]Swatch{ .{ .name = "yellow", .color = yellow }, .{ .name = "green", .color = green } };

    const question: Mark = .{ .color = yellow };
    const thread = [_]Comment{ .{ .text = "Is this settled?" }, .{ .text = "a #Question for Tuesday" } };
    const plain: Mark = .{ .color = green, .style = .underline };
    const pen: Mark = .{ .kind = .ink, .color = green };

    const f = Filter.parse("YELLOW green #question", &swatches);
    try testing.expectEqual(@as(u8, 3), f.terms);
    // A word may be in any comment on the anchor, not only the first.
    try testing.expect(f.matches(question, &thread));
    try testing.expect(!f.matches(question, thread[0..1]));
    try testing.expect(!f.matches(plain, &.{})); // green, but says nothing

    // A style and ink are one sort: either will do.
    const shapes = Filter.parse("strike-through ink", &swatches);
    try testing.expect(shapes.matches(pen, &.{}));
    try testing.expect(!shapes.matches(plain, &.{}));
    try testing.expect(Filter.parse("underline", &swatches).matches(plain, &.{}));

    try testing.expect(!Filter.parse("commented", &swatches).matches(plain, &.{}));
    try testing.expect(Filter.parse("commented", &swatches).matches(plain, thread[0..1]));
    try testing.expect(Filter.parse("  ", &swatches).isEmpty());

    // A colour read back from the library is a byte a channel off the float
    // it was made from, and is still that swatch.
    var faded = question;
    faded.color.g += 0.001;
    try testing.expect(Filter.parse("yellow", &swatches).matches(faded, &.{}));
}

test "a jump walks only what the filter lets through" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 700, 10, 710) }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 600, 10, 610) }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 500, 10, 510) }, true);
    _ = try m.addComment(gpa, .{ .anchor = m.items()[0].anchor, .text = "#q one" }, true);
    _ = try m.addComment(gpa, .{ .anchor = m.items()[2].anchor, .text = "#q two" }, true);

    const f = Filter.parse("#q", &.{});
    const to = m.jump(m.items()[0], true, &f).?;
    try testing.expectEqual(m.items()[2].key, to.key);
    try testing.expectEqual(@as(usize, 2), to.place);
    try testing.expectEqual(@as(usize, 2), to.of);

    // Edit mode taken up inside the unmatched mark starts at the next that
    // matches, and one past the last that matches wraps to the first.
    try testing.expectEqual(m.items()[2].key, m.atOrAfter(0, .{ .x = 5, .y = 605 }, &f).?);
    try testing.expectEqual(m.items()[0].key, m.atOrAfter(0, .{ .x = 5, .y = 100 }, &f).?);
    try testing.expect(m.atOrAfter(0, .{ .x = 5, .y = 605 }, &Filter.parse("#nothing", &.{})) == null);

    // The unmatched one is still counted among them all.
    const all: Filter = .{};
    try testing.expectEqual(Place{ .place = 2, .of = 3 }, m.placeOf(m.items()[1], &all));
    try testing.expectEqual(Place{ .place = 2, .of = 2 }, m.placeOf(m.items()[2], &f));
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

test "a stroke is a mark, and its box is where the pen went plus the pen" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    const drawn = [_]Point{
        .{ .x = 100, .y = 500 },
        .{ .x = 140, .y = 520 },
        .{ .x = 180, .y = 500 },
    };
    // Handed in with no box: `add` works it out, so nothing above has to.
    const i = try m.add(gpa, .{
        .kind = .ink,
        .page = 1,
        .points = &drawn,
        .width = 4,
    }, false);

    const mark = m.items()[i];
    try testing.expectEqual(drawn.len, mark.points.len);
    try testing.expectApproxEqAbs(@as(f32, 98), mark.box.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 182), mark.box.max_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 498), mark.box.min_y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 522), mark.box.max_y, 0.001);

    // Copied, not borrowed: the caller's buffer is scratch and is about to be
    // used for the next stroke.
    try testing.expect(mark.points.ptr != &drawn);
}

test "a click hits the line a stroke is, not the box around it" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    // Three sides of a box, as somebody ringing a figure would draw it. The
    // middle is inside the bounds and is not on the ink.
    const ring = [_]Point{
        .{ .x = 100, .y = 400 },
        .{ .x = 300, .y = 400 },
        .{ .x = 300, .y = 600 },
        .{ .x = 100, .y = 600 },
    };
    _ = try m.add(gpa, .{ .kind = .ink, .page = 0, .points = &ring, .width = 2 }, false);

    try testing.expectEqual(@as(?usize, 0), m.at(0, .{ .x = 200, .y = 400 }));
    try testing.expectEqual(@as(?usize, 0), m.at(0, .{ .x = 300, .y = 500 }));
    // Well inside the bounds, nowhere near the line.
    try testing.expectEqual(@as(?usize, null), m.at(0, .{ .x = 200, .y = 500 }));
    // And a hair off the line is still a hit; nobody can click a hairline.
    try testing.expectEqual(@as(?usize, 0), m.at(0, .{ .x = 200, .y = 402 }));
}

test "simplify keeps the shape, the ends, and throws the samples away" {
    // What a frame-sampled drag of a straight line looks like: fifty points
    // where two would do.
    var line: [50]Point = undefined;
    for (&line, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 0 };
    const straight = simplify(&line, 0.5);
    try testing.expectEqual(@as(usize, 2), straight.len);
    try testing.expectApproxEqAbs(@as(f32, 0), straight[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 49), straight[straight.len - 1].x, 0.001);

    // A corner is a shape and survives.
    var bent: [21]Point = undefined;
    for (bent[0..11], 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 0 };
    for (bent[11..], 0..) |*p, i| p.* = .{ .x = 10, .y = @floatFromInt(i + 1) };
    const corner = simplify(&bent, 0.5);
    try testing.expectEqual(@as(usize, 3), corner.len);
    try testing.expectApproxEqAbs(@as(f32, 10), corner[1].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), corner[1].y, 0.001);

    // Two points are already a stroke and are left alone.
    var pair = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };
    try testing.expectEqual(@as(usize, 2), simplify(&pair, 0.5).len);
}

test "ink and highlights undo through one history, in the order they were made" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    const drawn = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 } };
    m.beginGroup();
    _ = try m.add(gpa, .{ .page = 0, .box = box(10, 10, 60, 24) }, false);
    m.beginGroup();
    _ = try m.add(gpa, .{ .kind = .ink, .page = 0, .points = &drawn, .width = 2 }, false);
    try testing.expectEqual(@as(usize, 2), m.count());

    // One `u` takes the stroke back and leaves the highlight, because there
    // is one history and the stroke was the last thing in it.
    try testing.expect(try m.undo(gpa));
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqual(Kind.block, m.items()[0].kind);

    // And the redo brings it back with its points, which outlived the undo
    // because they are in the arena and not in the caller's buffer.
    try testing.expect(try m.redo(gpa));
    try testing.expectEqual(Kind.ink, m.items()[1].kind);
    try testing.expectEqual(@as(usize, 2), m.items()[1].points.len);
}

test "a selection's lines are one anchor, and its comments hang from it in order" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    // What came back from the library: a name past which new ones go.
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 1, 1), .anchor = 7 }, true);

    m.beginGroup();
    const anchor = m.newName();
    try testing.expectEqual(@as(u64, 8), anchor);
    for (0..3) |i| {
        const y: f32 = @floatFromInt(i * 10);
        _ = try m.add(gpa, .{ .page = 1, .box = box(0, y, 9, y + 9), .anchor = anchor }, false);
    }
    try testing.expectEqual(@as(usize, 3), m.lineCount(anchor));
    // A mark made alone is an anchor alone.
    _ = try m.add(gpa, .{ .page = 2, .box = box(0, 0, 1, 1) }, false);
    try testing.expectEqual(@as(u64, 9), m.items()[4].anchor);

    // The first comment takes the anchor's number, as the PDF's `/Contents`
    // of the anchor; the next is a reply with a number of its own. One on
    // another anchor made in between does not get between them.
    _ = try m.addComment(gpa, .{ .anchor = anchor, .text = "is this right?" }, false);
    _ = try m.addComment(gpa, .{ .anchor = 7, .text = "elsewhere" }, false);
    _ = try m.addComment(gpa, .{ .anchor = anchor, .text = "no" }, false);
    const thread = m.said(anchor);
    try testing.expectEqual(@as(usize, 2), thread.len);
    try testing.expectEqual(anchor, thread[0].name);
    try testing.expectEqualStrings("is this right?", thread[0].text);
    try testing.expectEqual(@as(u64, 10), thread[1].name);
    try testing.expectEqualStrings("no", thread[1].text);
    try testing.expectEqual(@as(u64, 7), m.said(7)[0].name);
    try testing.expectEqual(@as(usize, 0), m.said(9).len);
}

test "the last line of an anchor takes its comments, and one u brings both back" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    const anchor = m.newName();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 10, 9, 19), .anchor = anchor }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 9, 9), .anchor = anchor }, true);
    _ = try m.addComment(gpa, .{ .anchor = anchor, .text = "one", .id = 4 }, true);
    _ = try m.addComment(gpa, .{ .anchor = anchor, .text = "two", .id = 5 }, true);

    // One line of two: the comments stay with the line that is left.
    m.beginGroup();
    _ = try m.removeAt(gpa, 0);
    try testing.expectEqual(@as(usize, 2), m.said(anchor).len);
    m.clearEffects();

    // The last: they go too, and the library is told to delete their rows.
    m.beginGroup();
    _ = try m.removeAt(gpa, 0);
    try testing.expectEqual(@as(usize, 0), m.said(anchor).len);
    var deleted: usize = 0;
    for (m.takeEffects()) |e| deleted += @intFromBool(e == .comment_delete and e.comment_delete.saved());
    try testing.expectEqual(@as(usize, 2), deleted);
    m.clearEffects();

    // One undo puts the line and both comments back, as new rows, in the
    // order they were written.
    _ = try m.undo(gpa);
    try testing.expectEqual(@as(usize, 1), m.count());
    const back = m.said(anchor);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("one", back[0].text);
    try testing.expectEqualStrings("two", back[1].text);
    try testing.expect(!back[0].saved());
    var inserted: usize = 0;
    for (m.takeEffects()) |e| inserted += @intFromBool(e == .comment_insert);
    try testing.expectEqual(@as(usize, 2), inserted);
}

test "marking words again moves their comments onto the new anchor" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 9, 9) }, true);
    const old = m.items()[0].anchor;
    _ = try m.addComment(gpa, .{ .anchor = old, .text = "keep me" }, true);

    m.beginGroup();
    const fresh = m.newName();
    try m.moveComments(gpa, old, fresh);
    _ = try m.removeAt(gpa, 0);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 0, 9, 9), .anchor = fresh }, false);
    try testing.expectEqual(@as(usize, 0), m.said(old).len);
    try testing.expectEqualStrings("keep me", m.said(fresh)[0].text);
    // On its new anchor it is the first comment, so it takes that name.
    try testing.expectEqual(fresh, m.said(fresh)[0].name);

    _ = try m.undo(gpa);
    try testing.expectEqualStrings("keep me", m.said(old)[0].text);
    try testing.expectEqual(@as(usize, 0), m.said(fresh).len);
}

test "an anchor's comment is shown on its first line in reading order" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    const anchor = m.newName();
    // Made bottom line first, as a selection dragged upwards would be.
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 600, 9, 610), .anchor = anchor }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 700, 9, 710), .anchor = anchor }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 500, 9, 510) }, true);
    try testing.expect(!m.leads(gpa, 1));

    _ = try m.addComment(gpa, .{ .anchor = anchor, .text = "here" }, true);
    try testing.expect(m.leads(gpa, 1));
    try testing.expect(!m.leads(gpa, 0));
    try testing.expect(!m.leads(gpa, 2));
}

test "]c reads each comment, a thread through before the next anchor" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    // Two lines of one anchor high on the page, a plain mark, and one low
    // down -- commented first, so it is the page that orders them and not
    // the order they were written in.
    const two = m.newName();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 700, 9, 710), .anchor = two }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 690, 9, 700), .anchor = two }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 500, 9, 510) }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 300, 9, 310) }, true);
    _ = try m.addComment(gpa, .{ .anchor = m.items()[3].anchor, .text = "low" }, true);
    _ = try m.addComment(gpa, .{ .anchor = two, .text = "first" }, true);
    _ = try m.addComment(gpa, .{ .anchor = two, .text = "reply" }, true);
    const keyOf = struct {
        fn f(marks: *Marks, text: []const u8) u64 {
            for (marks.comments.items) |c| {
                if (std.mem.eql(u8, c.text, text)) return c.key;
            }
            unreachable;
        }
    }.f;
    const any: Filter = .{};

    // From the top of the page: the thread in order, the low one, and round.
    const top: Mark = .{ .page = 0, .box = box(0, 800, 0, 800) };
    const first = m.jumpComment(gpa, top, null, true, &any).?;
    try testing.expectEqual(keyOf(&m, "first"), first.key);
    try testing.expectEqual(m.items()[0].key, first.mark);
    try testing.expectEqual(@as(usize, 1), first.place);
    try testing.expectEqual(@as(usize, 3), first.of);
    const reply = m.jumpComment(gpa, m.items()[0], first.key, true, &any).?;
    try testing.expectEqual(keyOf(&m, "reply"), reply.key);
    const low = m.jumpComment(gpa, m.items()[0], reply.key, true, &any).?;
    try testing.expectEqual(keyOf(&m, "low"), low.key);
    try testing.expectEqual(@as(usize, 3), low.place);
    const round = m.jumpComment(gpa, m.items()[3], low.key, true, &any).?;
    try testing.expectEqual(keyOf(&m, "first"), round.key);
    try testing.expect(round.wrapped);

    // Backwards from the low one is the end of the thread, not its start.
    try testing.expectEqual(keyOf(&m, "reply"), m.jumpComment(gpa, m.items()[3], low.key, false, &any).?.key);

    // From a mark with no comment in hand its own come first, from any line
    // of its anchor; from a mark with none, onward.
    try testing.expectEqual(keyOf(&m, "first"), m.jumpComment(gpa, m.items()[1], null, true, &any).?.key);
    try testing.expectEqual(keyOf(&m, "low"), m.jumpComment(gpa, m.items()[2], null, true, &any).?.key);

    // What the filter hides, the walk does not read.
    const f = Filter.parse("low", &.{});
    const only = m.jumpComment(gpa, top, null, true, &f).?;
    try testing.expectEqual(keyOf(&m, "low"), only.key);
    try testing.expectEqual(@as(usize, 1), only.of);
}

test "an anchor's first line heads it, with or without a comment" {
    const gpa = testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);

    // An arrow over two lines, the lower made first, and nothing said yet:
    // the arrow is drawn from the upper one all the same.
    const anchor = m.newName();
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 600, 9, 610), .anchor = anchor, .style = .arrow }, true);
    _ = try m.add(gpa, .{ .page = 0, .box = box(0, 700, 9, 710), .anchor = anchor, .style = .arrow }, true);
    try testing.expect(m.heads(gpa, 1));
    try testing.expect(!m.heads(gpa, 0));
    try testing.expect(!m.leads(gpa, 1));

    // And it is a style like the others, which a filter can name.
    try testing.expect(Filter.parse("arrow", &.{}).matches(m.items()[0], &.{}));
    try testing.expectEqualStrings("arrow", Style.arrow.label());
}
