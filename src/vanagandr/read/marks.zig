//! Marks and the comments on them: made from a selection or the caret,
//! taken in hand and changed in edit mode, walked with `]a` and `]c`,
//! journaled in the library, read back from it and from the file's own
//! annotations, and drawn over the page. Writing the journal into the file
//! is `journal.zig`'s.
//!
//! A file of its own so that all of it is in one place, and so that a build
//! with no marks can leave the file out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const library = @import("../library.zig");
const save = @import("../save.zig");
const Library = library.Library;
const Session = @import("Session.zig");
const frame = @import("frame.zig");
const selection = @import("selection.zig");
const plugins_mod = @import("plugins.zig");

const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const hlidskjalf = fenrir.hlidskjalf;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const Point = gelgja.Point;
const DrawList = gleipnir.DrawList;

const Buffer = hlidskjalf.Buffer;
const Marks = hlidskjalf.Marks;
const View = hlidskjalf.View;
const keys = hlidskjalf.keys;
const text = hlidskjalf.text;

const caps = fenrir.build_options;

/// How wide a stroke is, in PDF points, when nothing says otherwise: a row
/// stored with no width, and the pen the reader starts with. About the weight
/// of a fineliner against ten-point type, which is what somebody underlining
/// a line of a paper is holding.
pub const default_pen_width: f32 = save.default_pen_width;

/// What ink that names no colour is drawn in: a stroke stored without one,
/// and the pen until a digit picks another. See `ink.penColor`.
pub const ink_colour: Color = .{ .r = 0.13, .g = 0.19, .b = 0.35, .a = 1 };

/// The colour a digit names. `1` is the default highlight colour, which is
/// the accent when the reader has chosen one, so the key a person reaches
/// for first gives the colour they set; the rest are the named colours
/// `fenrir config accent` accepts, in rainbow order.
/// The colours a digit picks, from `2` onwards. `1` is whatever the
/// reader highlights with by default, which is a setting and not a name.
const palette_names = [_][]const u8{
    "yellow", "green", "blue", "pink", "orange", "purple", "red",
};

pub fn paletteColor(s: *const Session, index: ?u8) Color {
    const i = index orelse return s.highlight;
    if (i == 0 or i > palette_names.len) return s.highlight;
    return Library.parseColor(palette_names[i - 1]).?;
}

/// The annotations panel's filter, read out of its field. Parsed where it
/// is asked for -- on a key, or when the rows are rebuilt -- and never
/// held, so it cannot outlive the text its words point into.
pub fn markFilter(s: *Session) Marks.Filter {
    // Typed into the panel and kept there, so a build with no panel has no
    // filter, and every mark is let through.
    if (!caps.panels) return .{};
    var swatches: [palette_names.len + 1]Marks.Swatch = undefined;
    swatches[0] = .{ .name = "default", .color = s.highlight };
    for (palette_names, swatches[1..]) |name, *sw| sw.* = .{ .name = name, .color = Library.parseColor(name).? };
    return .parse(s.panel.filterText(), &swatches);
}

/// Said wherever a filter has left nothing to walk.
const unmatched = "nothing matches the filter -- :filter with nothing after it clears it";

pub fn paletteName(index: u8) []const u8 {
    if (index == 0 or index > palette_names.len) return "the usual colour";
    return palette_names[index - 1];
}

/// Highlights a run of boxes as one undo step.
///
/// A box laid mostly over an existing highlight replaces it rather than
/// stacking on it, so selecting highlighted words and pressing `3`
/// recolours them instead of darkening them.
pub fn highlightBoxes(s: *Session, buffer_index: u32, boxes: []const selection.PageBox, color: Color) void {
    _ = markBoxes(s, buffer_index, boxes, color, .highlight);
}

/// Marks each box, replacing what mostly covered the same words: marking
/// a line again in another colour or style is changing its mark.
///
/// Every box is a line of one new anchor, returned. A replaced mark that
/// was the last line of its anchor hands its comments to the new one
/// first, so marking commented words again keeps what was said about
/// them.
pub fn markBoxes(s: *Session, buffer_index: u32, boxes: []const selection.PageBox, color: Color, style: Marks.Style) u64 {
    const b = s.buffer(buffer_index);
    b.marks.beginGroup();
    defer b.marks.beginGroup();
    const anchor = b.marks.newName();

    for (boxes) |pb| {
        var i = b.marks.count();
        while (i > 0) {
            i -= 1;
            const mark = b.marks.items()[i];
            if (mark.page != pb.page) continue;
            const shared = mark.box.intersect(pb.box);
            if (shared.isEmpty()) continue;
            if (area(shared) < area(mark.box) * 0.5) continue;
            if (b.marks.lineCount(mark.anchor) == 1) b.marks.moveComments(s.gpa, mark.anchor, anchor) catch return anchor;
            _ = b.marks.removeAt(s.gpa, i) catch return anchor;
        }
        _ = b.marks.add(s.gpa, .{
            .page = pb.page,
            .box = pb.box,
            .color = color,
            .style = style,
            .anchor = anchor,
        }, false) catch return anchor;
    }
    return anchor;
}

fn area(box: Bounds) f32 {
    if (box.isEmpty()) return 0;
    return box.width() * box.height();
}

/// `m` in normal mode: highlight the cursor's line, or remove the
/// highlight the cursor is inside.
pub fn toggleMark(s: *Session) void {
    const v = s.view();
    const b = s.buffer(v.buffer);

    // A selection dragged with the mouse leaves normal mode holding
    // words, not a line, and `m` means those words -- otherwise the only
    // way to highlight a mouse selection would be to make it again with
    // the keyboard.
    if (s.drag != null) return highlightSelection(s, null, .highlight);

    if (!v.cursor.visible or v.cursor.caret.isEmpty()) return;

    const at: Point = .{
        .x = v.cursor.caret.min_x,
        .y = (v.cursor.caret.min_y + v.cursor.caret.max_y) * 0.5,
    };
    if (b.marks.at(v.cursor.page, at)) |index| {
        b.marks.beginGroup();
        _ = b.marks.removeAt(s.gpa, index) catch {};
        return;
    }

    const map = b.textMap(v.cursor.page) orelse return;
    if (map.isEmpty()) return;
    const line = map.lines[@min(v.cursor.line, map.lines.len - 1)];
    highlightBoxes(s, v.buffer, &.{.{ .page = v.cursor.page, .box = line.box }}, s.highlight);
}

pub fn clearMarks(s: *Session) void {
    const b = s.buffer(s.view().buffer);
    b.marks.clear(s.gpa) catch {};
    s.status = if (b.marks.canUndo()) "marks cleared -- u to bring them back" else "";
}

/// Visual mode's `m`, enter or a digit -- and `m` over a selection the
/// mouse made, which is the only way a drag becomes a highlight: letting
/// go of one does not, and `y` does not.
pub fn highlightSelection(s: *Session, colour: ?u8, style: Marks.Style) void {
    const v = s.view();
    const sel = selection.activeSelection(s, v) orelse return;
    defer selection.clearSelection(s);

    var boxes: std.ArrayList(selection.PageBox) = .empty;
    defer boxes.deinit(s.gpa);
    selection.selectionBoxes(s, v.buffer, sel[0], sel[1], selection.lineSelection(s), &boxes) catch return;
    _ = markBoxes(s, v.buffer, boxes.items, paletteColor(s, colour), style);
}

/// Visual mode's `d`: every highlight the selection touches goes.
pub fn unhighlightSelection(s: *Session) void {
    const v = s.view();
    const sel = selection.activeSelection(s, v) orelse return;
    defer selection.clearSelection(s);
    const b = s.buffer(v.buffer);

    var boxes: std.ArrayList(selection.PageBox) = .empty;
    defer boxes.deinit(s.gpa);
    selection.selectionBoxes(s, v.buffer, sel[0], sel[1], selection.lineSelection(s), &boxes) catch return;

    b.marks.beginGroup();
    defer b.marks.beginGroup();
    var removed: u32 = 0;
    var i = b.marks.count();
    while (i > 0) {
        i -= 1;
        const mark = b.marks.items()[i];
        for (boxes.items) |pb| {
            if (pb.page != mark.page or mark.box.intersect(pb.box).isEmpty()) continue;
            _ = b.marks.removeAt(s.gpa, i) catch return;
            removed += 1;
            break;
        }
    }
    if (removed == 0) s.status = "no highlights in the selection";
}

/// `i`: take hold of the highlight at or after the cursor, among those
/// the filter lets through -- the first of what `n` will walk.
pub fn enterEdit(s: *Session) void {
    const v = s.view();
    const b = s.buffer(v.buffer);
    if (b.marks.count() == 0) {
        s.keymap.mode = .normal;
        s.status = "no highlights to edit -- select text with v and press m";
        return;
    }

    const filter = markFilter(s);
    const key = if (v.cursor.visible and !v.cursor.caret.isEmpty())
        b.marks.atOrAfter(v.cursor.page, .{
            .x = v.cursor.caret.min_x,
            .y = (v.cursor.caret.min_y + v.cursor.caret.max_y) * 0.5,
        }, &filter)
    else blk: {
        const page = v.currentPage();
        break :blk b.marks.atOrAfter(page, .{ .x = 0, .y = v.pageBox(page).max_y }, &filter);
    };
    if (key == null) {
        s.keymap.mode = .normal;
        s.status = unmatched;
        return;
    }
    focusMark(s, key);
}

/// Puts a highlight in hand: scrolls to it, and brings the cursor along so
/// that leaving edit mode leaves you where you were working.
pub fn focusMark(s: *Session, key: ?u64) void {
    s.focus_mark = key;
    s.focus_comment = null;
    const k = key orelse return;
    const v = s.view();
    const b = s.buffer(v.buffer);
    const mark = b.marks.byKey(k) orelse return;
    const said = b.marks.said(mark.anchor);
    if (said.len != 0) s.focus_comment = said[0].key;
    if (mark.page >= v.pages.len) return;

    v.scrollToBox(mark.page, mark.box);
    if (b.textMap(mark.page)) |map| {
        if (!map.isEmpty()) {
            const line = map.lineAt(mark.box.min_x, (mark.box.min_y + mark.box.max_y) * 0.5);
            v.cursorTo(.{
                .page = mark.page,
                .line = line,
                .column = map.columnAt(line, mark.box.min_x),
            }, map);
        }
    }
}

pub fn focusedMarkIndex(s: *Session) ?usize {
    const key = s.focus_mark orelse return null;
    return s.buffer(s.view().buffer).marks.indexOf(key);
}

/// The comment in hand, by its index in `comments`: the one `]c` took,
/// while it is still on the anchor in hand, and otherwise the first on
/// that anchor. Null when the anchor has none.
pub fn focusedComment(s: *Session) ?usize {
    const i = focusedMarkIndex(s) orelse return null;
    const b = s.buffer(s.view().buffer);
    const anchor = b.marks.items()[i].anchor;
    if (s.focus_comment) |k| {
        if (b.marks.commentIndex(k)) |c| {
            if (b.marks.comments.items[c].anchor == anchor) return c;
        }
    }
    const range = b.marks.saidRange(anchor);
    return if (range[0] == range[1]) null else range[0];
}

pub const Jumped = struct {
    buffer: u32,
    key: u64,
    caret: Bounds,
    /// The comment `]c` landed on, so the next `]c` reads on from it
    /// rather than from the start of its thread.
    comment: ?u64 = null,
};

pub const Typing = union(enum) {
    /// The comment with this key, changed.
    comment: u64,
    /// A new comment on the anchor with this number.
    new: u64,
};

/// `]a`, `[a`, `]c`, `[c`. In edit mode from the highlight in hand, which
/// the jump then replaces. Otherwise from where the reader is: the mark
/// jumped to last while the caret has stayed where that left it, else the
/// caret, else the top of the page in front of the window.
///
/// The first of those is not a nicety. A stroke of ink has no text for the
/// caret to land on, so a jump from the caret alone would find the same
/// stroke again, every time.
pub fn jumpMark(s: *Session, j: keys.Command.Jump) void {
    const v = s.view();
    const b = s.buffer(v.buffer);
    const from: Marks.Mark = from: {
        if (s.keymap.mode == .edit) {
            if (s.focus_mark) |k| if (b.marks.byKey(k)) |m| break :from m.*;
        }
        if (s.last_jump) |last| {
            if (last.buffer == v.buffer and std.meta.eql(last.caret, v.cursor.caret)) {
                if (b.marks.byKey(last.key)) |m| break :from m.*;
            }
        }
        if (v.cursor.visible and !v.cursor.caret.isEmpty()) {
            const c = v.cursor.caret;
            const y = (c.min_y + c.max_y) * 0.5;
            break :from .{ .page = v.cursor.page, .box = .fromRect(c.min_x, y, c.min_x, y) };
        }
        const page = v.currentPage();
        const top = v.pageBox(page).max_y;
        break :from .{ .page = page, .box = .fromRect(0, top, 0, top) };
    };

    // What the panel shows, whether or not it is open: a filter is set to
    // be walked, and the status line says when one is in force.
    var filter = markFilter(s);
    const filtered = !filter.isEmpty();
    if (j.comments) return jumpComment(s, from, j.forwards, &filter, filtered);
    const to = b.marks.jump(from, j.forwards, &filter) orelse {
        s.status = if (filtered)
            unmatched
        else if (j.comments)
            "no comments in this document -- a in edit mode writes one"
        else
            "no marks in this document";
        return;
    };

    // Normal mode has no highlight in hand, and landing on one must not
    // give it one: `focus_mark` is what edit mode outlines and deletes.
    const held = s.focus_mark;
    focusMark(s, to.key);
    if (s.keymap.mode != .edit) s.focus_mark = held;
    s.last_jump = .{ .buffer = v.buffer, .key = to.key, .caret = v.cursor.caret };

    const round: []const u8 = if (!to.wrapped) "" else if (j.forwards) ", from the top" else ", from the end";
    const of: []const u8 = if (filtered) " that match" else "";
    s.say("mark {d}/{d}{s}{s}", .{ to.place, to.of, of, round });
}

/// `]c` and `[c`: each comment in turn, a thread read through before the
/// next anchor's, from the comment the reader stands on. In edit mode
/// the comment is taken in hand, so `a` changes the one that was read.
fn jumpComment(s: *Session, from: Marks.Mark, forwards: bool, filter: *const Marks.Filter, filtered: bool) void {
    const v = s.view();
    const b = s.buffer(v.buffer);
    const after: ?u64 = if (s.keymap.mode == .edit)
        s.focus_comment
    else if (s.last_jump) |last|
        (if (last.buffer == v.buffer and last.key == from.key) last.comment else null)
    else
        null;
    const to = b.marks.jumpComment(s.gpa, from, after, forwards, filter) orelse {
        s.status = if (filtered)
            unmatched
        else
            "no comments in this document -- c on a selection writes one";
        return;
    };

    const held = s.focus_mark;
    const held_comment = s.focus_comment;
    focusMark(s, to.mark);
    if (s.keymap.mode == .edit) {
        s.focus_comment = to.key;
    } else {
        s.focus_mark = held;
        s.focus_comment = held_comment;
    }
    s.last_jump = .{ .buffer = v.buffer, .key = to.mark, .caret = v.cursor.caret, .comment = to.key };

    const round: []const u8 = if (!to.wrapped) "" else if (forwards) ", from the top" else ", from the end";
    const of: []const u8 = if (filtered) " that match" else "";
    const c = b.marks.comments.items[b.marks.commentIndex(to.key).?];
    s.say("comment {d}/{d}{s}{s}: {s}", .{ to.place, to.of, of, round, c.text });
}

/// The first thing written on a mark's anchor, or nothing: what a line
/// of the status bar or of the panel has room for.
pub fn firstComment(b: *Buffer, mark: Marks.Mark) []const u8 {
    const said = b.marks.said(mark.anchor);
    return if (said.len == 0) "" else said[0].text;
}

pub fn recolourMark(s: *Session, colour: u8) void {
    const i = focusedMarkIndex(s) orelse return;
    const b = s.buffer(s.view().buffer);
    b.marks.beginGroup();
    b.marks.recolour(s.gpa, i, paletteColor(s, colour)) catch {};
}

pub fn restyleMark(s: *Session, style: Marks.Style) void {
    const i = focusedMarkIndex(s) orelse return;
    const b = s.buffer(s.view().buffer);
    if (b.marks.items()[i].kind == .ink) {
        s.status = "ink is drawn as it went -- only marked words have a style";
        return;
    }
    b.marks.beginGroup();
    b.marks.restyle(s.gpa, i, style) catch {};
}

/// `d` in edit mode: delete the highlight in hand and take hold of the
/// next one, so that deleting several in a row is `ddd`.
///
/// The next of what `n` walks, so `ddd` under a filter deletes only what
/// the panel shows, and stops when the filter has nothing left rather
/// than going on into marks the panel hides.
pub fn deleteMark(s: *Session) void {
    const i = focusedMarkIndex(s) orelse return;
    const b = s.buffer(s.view().buffer);
    const filter = markFilter(s);
    const next = if (b.marks.jump(b.marks.items()[i], true, &filter)) |to| to.key else null;

    b.marks.beginGroup();
    _ = b.marks.removeAt(s.gpa, i) catch return;

    if (next == null or next == s.focus_mark) {
        s.focus_mark = null;
        s.keymap.mode = .normal;
        s.status = if (b.marks.count() == 0)
            "that was the last highlight"
        else
            "that was the last that matches -- :filter with nothing after it clears it";
        return;
    }
    focusMark(s, next);
}

/// `a`: note mode opens on the comment in hand, to change it, or on
/// nothing when the anchor has none, to write its first.
pub fn beginNote(s: *Session) void {
    const b = s.buffer(s.view().buffer);
    const i = focusedMarkIndex(s) orelse {
        s.keymap.mode = if (b.marks.count() == 0) .normal else .edit;
        return;
    };
    s.note.clearRetainingCapacity();
    if (focusedComment(s)) |c| {
        const comment = b.marks.comments.items[c];
        s.typing = .{ .comment = comment.key };
        s.note.appendSlice(s.gpa, comment.text) catch {};
    } else {
        s.typing = .{ .new = b.marks.items()[i].anchor };
    }
}

/// `c` in edit mode: note mode opens empty, for another comment on the
/// anchor in hand.
pub fn beginComment(s: *Session) void {
    const b = s.buffer(s.view().buffer);
    const i = focusedMarkIndex(s) orelse {
        s.keymap.mode = if (b.marks.count() == 0) .normal else .edit;
        return;
    };
    s.note.clearRetainingCapacity();
    s.typing = .{ .new = b.marks.items()[i].anchor };
}

/// `c` in visual mode: the selection is highlighted as one anchor, taken
/// in hand, and note mode opens for the first comment on it. Escape
/// keeps the highlight, which `u` takes back like any other.
pub fn commentSelection(s: *Session) void {
    const v = s.view();
    const sel = selection.activeSelection(s, v) orelse return noAnchor(s);
    defer selection.clearSelection(s);
    var boxes: std.ArrayList(selection.PageBox) = .empty;
    defer boxes.deinit(s.gpa);
    selection.selectionBoxes(s, v.buffer, sel[0], sel[1], selection.lineSelection(s), &boxes) catch return noAnchor(s);
    if (boxes.items.len == 0) return noAnchor(s);

    const b = s.buffer(v.buffer);
    const anchor = markBoxes(s, v.buffer, boxes.items, s.highlight, s.comment_style);
    var first: ?Marks.Mark = null;
    for (b.marks.items()) |m| {
        if (m.anchor != anchor) continue;
        if (first == null or Marks.readsBefore(m, first.?)) first = m;
    }
    focusMark(s, first.?.key);
    s.note.clearRetainingCapacity();
    s.typing = .{ .new = anchor };
}

/// A comment begun where no words are selected, or none are known yet.
fn noAnchor(s: *Session) void {
    s.keymap.mode = .normal;
    s.typing = null;
    s.status = "nothing to comment on -- select some words first";
}

pub fn noteChar(s: *Session, c: u21) void {
    if (s.note.items.len >= Session.max_note) return;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch return;
    s.note.appendSlice(s.gpa, buf[0..n]) catch {};
}

/// Removes the last *character*, not the last byte: a note is UTF-8, and
/// cutting an accented letter in half leaves a note the library would
/// store as invalid text.
pub fn noteBackspace(s: *Session) void {
    var n = s.note.items.len;
    if (n == 0) return;
    n -= 1;
    while (n > 0 and s.note.items[n] & 0xc0 == 0x80) n -= 1;
    s.note.shrinkRetainingCapacity(n);
}

/// Keeps what was typed: the comment it was begun on changed, or none at
/// all when everything was rubbed out; or a new comment, taken in hand,
/// unless nothing was typed.
pub fn commitNote(s: *Session) void {
    defer s.note.clearRetainingCapacity();
    const typing = s.typing orelse return;
    s.typing = null;
    const b = s.buffer(s.view().buffer);
    b.marks.beginGroup();
    switch (typing) {
        .comment => |key| {
            const at = b.marks.commentIndex(key) orelse return;
            if (s.note.items.len == 0) {
                _ = b.marks.removeComment(s.gpa, at) catch {};
            } else {
                b.marks.setText(s.gpa, at, s.note.items) catch {};
            }
        },
        .new => |anchor| {
            if (s.note.items.len == 0) return;
            // The anchor may have gone while this was typed, to an undo
            // from a plugin's key; a comment on nothing would be lost.
            if (b.marks.lineCount(anchor) == 0) return;
            const at = b.marks.addComment(s.gpa, .{ .anchor = anchor, .text = s.note.items }, false) catch return;
            s.focus_comment = b.marks.comments.items[at].key;
        },
    }
}

pub fn undoMarks(s: *Session, forwards: bool) void {
    const b = s.buffer(s.view().buffer);
    const done = (if (forwards) b.marks.redo(s.gpa) else b.marks.undo(s.gpa)) catch false;
    if (!done) {
        s.status = if (forwards) "already at newest change" else "already at oldest change";
        return;
    }
    // The highlight in hand may be the thing that was undone.
    if (s.focus_mark) |k| {
        if (b.marks.indexOf(k) == null) {
            s.focus_mark = null;
            if (s.keymap.mode == .edit) enterEdit(s);
        }
    }
}

// -- the library -------------------------------------------------------------

/// Writes whatever the highlights' history says has changed. Once a frame,
/// after the commands, so that a burst of edits is written as it settles
/// rather than one statement per keystroke inside the handler.
pub fn applyEffects(s: *Session) void {
    writeEffects(s, false);
}

/// `:w`'s pass: what the library refused before is tried again even when
/// nothing new has come to carry it.
pub fn retryEffects(s: *Session) void {
    writeEffects(s, true);
}

/// The changes no library has yet, over every open document: what the
/// status line counts.
pub fn unsaved(s: *Session) usize {
    var n: usize = 0;
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) n += s.buffer(i).marks.owed();
    return n;
}

/// What the library refused is tried again first, in order, and on the
/// next pass that brings something new rather than every frame: a disk
/// that is full, or a library another process holds locked, is not going
/// to change its mind in a sixtieth of a second, and asking every frame
/// would be a failed statement a frame for as long as it lasts.
///
/// **Nothing refused is dropped.** This cleared the queue and swallowed
/// every error once, so an insert that failed left its mark with no row
/// for good, and its later recolours and its delete were skipped as being
/// for a mark the library never had. Do not go back to clearing first.
fn writeEffects(s: *Session, retry: bool) void {
    var at: u32 = 0;
    while (at < s.bufferCount()) : (at += 1) {
        const b = s.buffer(at);
        // Not while its save is out: the rows are being written into the
        // file and cleared, and a row written now would be cleared with
        // them unwritten. What comes meanwhile waits, queued.
        if (s.disk(at).save == .posted) continue;
        const fresh = b.marks.takeEffects().len != 0;
        if (!fresh and !(retry and b.marks.owed() != 0)) continue;
        const was = b.marks.owed();

        var done: usize = 0;
        for (b.marks.unwritten.items) |e| {
            writeEffect(s, b, e) catch break;
            done += 1;
        }
        b.marks.wrote(done);

        // Taken out of the buffer before anything is told about them: a
        // plugin handler for `highlight` may make another change, and
        // that change belongs to the next pass rather than to this list.
        const effects = s.gpa.dupe(Marks.Effect, b.marks.takeEffects()) catch continue;
        defer s.gpa.free(effects);
        b.marks.clearEffects();

        for (effects, 0..) |e, i| {
            // Behind what is still held, whether or not it would go now.
            if (b.marks.owed() == 0) {
                writeEffect(s, b, e) catch |err| {
                    s.say("the library would not take that ({t}) -- kept, and tried again on the next change or :w", .{err});
                    b.marks.keep(s.gpa, effects[i .. i + 1]) catch {};
                };
            } else b.marks.keep(s.gpa, effects[i .. i + 1]) catch {};
            plugins_mod.announceEffect(s, at, b, e);
        }
        if (was != 0 and b.marks.owed() == 0) s.say("{s}: the library has every change now", .{b.title});
        noteNames(s, b);
    }
}

/// Tells the library how far this document's names have been handed out,
/// when that has moved: the rows alone would give a deleted mark's name
/// to the next one made. Once a pass, not once a name.
fn noteNames(s: *Session, b: *Buffer) void {
    const lib = s.library orelse return;
    const high = b.marks.next_name - 1;
    if (high <= b.marks.told) return;
    lib.noteName(b.path, high) catch return;
    b.marks.told = high;
}

/// One queued change, written.
///
/// The kind is read off the mark rather than carried on the effect: an
/// `Effect` says *what happened* to a mark, and which table that is is a
/// fact about the mark. A delete carries the whole mark for this reason,
/// so a row can still be found after the mark has left the list.
///
/// A change to what is no longer there, or never got a row, has nothing
/// left to write and is done: an insert of a mark deleted since, an
/// update of one whose insert is held in front of it, which writes the
/// mark as it is now.
///
/// **A change to something the file holds is journaled too.** The library
/// wins by name on the next open, so a recolour, a restyle or a line taken
/// off one of the file's anchors writes a row for every line it has left
/// (`adopt`), and deleting the last of them, or one of the file's
/// comments, writes a `gone` row. Without them a recolour of Acrobat's
/// highlight came back in Acrobat's colour, and a deleted one came back.
fn writeEffect(s: *Session, b: *Buffer, e: Marks.Effect) Library.Error!void {
    const lib = s.library orelse return;
    switch (e) {
        .insert => |key| {
            const mark = b.marks.byKey(key) orelse return;
            if (mark.saved()) return;
            // The file's, put back by an undo: its anchor is the reader's
            // version of the file's from here on.
            if (inFile(s, b, mark.anchor)) return adopt(s, b, mark.anchor);
            const id = try insertRow(s, b, mark.*, false);
            b.marks.setId(key, id);
        },
        // A mark that went before its held insert was tried again never
        // got a row: the insert found nothing to write.
        .delete => |mark| {
            if (mark.saved()) switch (mark.kind) {
                .block => try lib.removeMark(mark.id),
                .ink => try lib.removeStroke(mark.id),
            };
            if (!inFile(s, b, mark.anchor)) return;
            if (b.marks.lineCount(mark.anchor) != 0) return adopt(s, b, mark.anchor);
            const anchor = try nameUnnamed(s, b, mark.anchor);
            var name: [Library.name_len]u8 = undefined;
            try lib.addGone(b.path, .{ .nm = @constCast(spell(b, anchor, &name)), .page = mark.page });
        },
        .update => |key| {
            const mark = b.marks.byKey(key) orelse return;
            if (!mark.saved()) {
                if (inFile(s, b, mark.anchor)) try adopt(s, b, mark.anchor);
                return;
            }
            var hex: [7]u8 = undefined;
            switch (mark.kind) {
                .block => try lib.updateMark(mark.id, hexOf(mark.color, &hex), @tagName(mark.style)),
                .ink => try lib.updateStroke(mark.id, hexOf(mark.color, &hex)),
            }
        },
        .comment_insert => |key| {
            const was = b.marks.comments.items[b.marks.commentIndex(key) orelse return];
            if (was.saved()) return;
            try insertComment(s, b, key);
        },
        .comment_delete => |c| {
            if (c.saved()) try lib.removeComment(c.id);
            if (!inFile(s, b, c.name)) return;
            // On an anchor that went with it: the anchor's `gone` row takes
            // the annotation and its replies out together.
            if (b.marks.lineCount(c.anchor) == 0 and inFile(s, b, c.anchor)) return;
            const name = try nameUnnamed(s, b, c.name);
            var buf: [Library.name_len]u8 = undefined;
            try lib.addGone(b.path, .{ .nm = @constCast(spell(b, name, &buf)), .page = anchorPage(s, b, c.anchor), .comment = true });
        },
        .comment_update => |key| {
            const c = b.marks.comments.items[b.marks.commentIndex(key) orelse return];
            if (c.saved()) return lib.updateComment(c.id, c.text, now(s));
            if (inFile(s, b, c.name)) try insertComment(s, b, key);
        },
    }
}

/// A row for a mark, as it is now. `edit` when it is the reader's version
/// of one of the file's.
fn insertRow(s: *Session, b: *Buffer, mark: Marks.Mark, edit: bool) Library.Error!i64 {
    const lib = s.library.?;
    var hex: [7]u8 = undefined;
    var name: [Library.name_len]u8 = undefined;
    const anchor = spell(b, mark.anchor, &name);
    return switch (mark.kind) {
        .block => lib.addMark(b.path, .{
            .page = mark.page,
            .x0 = mark.box.min_x,
            .y0 = mark.box.min_y,
            .x1 = mark.box.max_x,
            .y1 = mark.box.max_y,
            .color = @constCast(hexOf(mark.color, &hex)),
            .style = @constCast(@tagName(mark.style)),
            .anchor = @constCast(anchor),
            .edit = edit,
        }, now(s)),
        .ink => lib.addStroke(b.path, .{
            .page = mark.page,
            .color = @constCast(hexOf(mark.color, &hex)),
            .width = mark.width,
            .points = @constCast(mark.points),
            .anchor = @constCast(anchor),
            .edit = edit,
        }, now(s)),
    };
}

/// A row for every line of one of the file's anchors that has none, so
/// that the library holds the whole anchor as the reader has it: it wins
/// by name, and an anchor it held half of would come back as that half.
/// Asked again after a refusal it writes only what is still missing.
fn adopt(s: *Session, b: *Buffer, was: u64) Library.Error!void {
    const anchor = try nameUnnamed(s, b, was);
    for (b.marks.items(), 0..) |m, i| {
        if (m.anchor != anchor or m.saved()) continue;
        b.marks.list.items[i].id = try insertRow(s, b, m, true);
    }
}

/// A comment's row: one the reader wrote, or its version of one of the
/// file's. Whatever came with no usable name is given one first, the
/// anchor and the comment both, or the row would name nothing.
fn insertComment(s: *Session, b: *Buffer, key: u64) Library.Error!void {
    const lib = s.library.?;
    const first = b.marks.comments.items[b.marks.commentIndex(key).?];
    _ = try nameUnnamed(s, b, first.anchor);
    _ = try nameUnnamed(s, b, b.marks.comments.items[b.marks.commentIndex(key).?].name);
    // Asked again: a name given just now has moved it in the list.
    const c = b.marks.comments.items[b.marks.commentIndex(key).?];
    var anchor: [Library.name_len]u8 = undefined;
    var own: [Library.name_len]u8 = undefined;
    const id = try lib.addComment(b.path, .{
        .anchor = @constCast(spell(b, c.anchor, &anchor)),
        .nm = @constCast(spell(b, c.name, &own)),
        .page = anchorPage(s, b, c.anchor),
        .text = @constCast(c.text),
        .edit = inFile(s, b, c.name),
    }, now(s));
    b.marks.setCommentId(key, id);
}

/// The page an anchor begins on, which is the page another program's name
/// for it belongs to.
fn anchorPage(s: *Session, b: *Buffer, anchor: u64) u32 {
    const first = b.marks.firstLine(s.gpa, anchor) orelse return 0;
    return b.marks.items()[first].page;
}

/// Whether the file holds something by this name, whoever's it is now.
fn inFile(s: *Session, b: *Buffer, name: u64) bool {
    const t = takenOf(s, b) orelse return false;
    return t.contains(name);
}

pub fn hexOf(c: Color, buf: *[7]u8) []const u8 {
    const byte = struct {
        fn of(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.of;
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ byte(c.r), byte(c.g), byte(c.b) }) catch unreachable;
}

fn now(s: *const Session) i64 {
    const io = s.io orelse return 0;
    return library.now(io);
}

/// An anchor read from the file with no name of its own, or one its page
/// repeats, is given one of fenrir's the first time something about it is
/// written down, and the library notes which annotation that is by its
/// shape; the save that next writes the file puts the name in it, once.
/// Until then it has a number that spells as nothing, and a comment row
/// naming it would name nothing on the next open. Returns the name it has
/// now, which is the one it came with when it had one.
fn nameUnnamed(s: *Session, b: *Buffer, anchor: u64) Library.Error!u64 {
    const at = b.marks.unnamed.get(anchor) orelse return anchor;
    const lib = s.library orelse return anchor;
    const named = b.marks.newName();
    var buf: [Library.name_len]u8 = undefined;
    try lib.nameAnnotation(b.path, at.page, at.shape, Library.makeName(&buf, named));
    b.marks.rename(anchor, named);
    // Still the file's, under its new name: a reload forgets it by that.
    if (takenOf(s, b)) |t| {
        if (t.remove(anchor)) t.put(s.gpa, named, {}) catch {};
    }
    return named;
}

/// The names read out of `b`'s file rather than its library.
fn takenOf(s: *Session, b: *Buffer) ?*std.AutoHashMapUnmanaged(u64, void) {
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) {
        if (s.buffer(i) == b) return &s.disk(i).taken;
    }
    return null;
}

/// Reads this document's marks, and the comments on them, into its
/// buffer. A row with no name becomes an anchor of its own.
pub fn loadMarks(s: *Session, index: u32) void {
    const lib = s.library orelse return;
    const b = s.buffer(index);
    // Past every name this document has handed out, still in use or not.
    b.marks.told = lib.highestName(b.path) catch 0;
    b.marks.reserve(b.marks.told);

    const list = lib.marks(b.path) catch return;
    defer lib.freeMarks(list, list.len);

    for (list) |h| {
        const color = Library.parseColor(h.color) orelse s.highlight;
        _ = b.marks.add(s.gpa, .{
            .id = h.id,
            .page = h.page,
            .box = .fromRect(h.x0, h.y0, h.x1, h.y1),
            .color = color,
            .style = std.meta.stringToEnum(Marks.Style, h.style) orelse .highlight,
            .anchor = (nameOf(s, b, h.page, h.anchor) catch return) orelse 0,
        }, true) catch return;
    }

    // The ink after the highlights, so a stroke drawn over a highlight is
    // on top of it -- which is the order they were made in and the order
    // an opaque pen over a wash has to be drawn in to look right.
    const ink = lib.strokes(b.path) catch return;
    defer lib.freeStrokes(ink, ink.len);

    for (ink) |k| {
        _ = b.marks.add(s.gpa, .{
            .id = k.id,
            .kind = .ink,
            .page = k.page,
            .points = k.points,
            .width = if (k.width > 0) k.width else default_pen_width,
            .color = Library.parseColor(k.color) orelse ink_colour,
            .anchor = (nameOf(s, b, k.page, k.anchor) catch return) orelse 0,
        }, true) catch return;
    }

    const said = lib.comments(b.path) catch return;
    defer lib.freeComments(said, said.len);

    for (said) |c| {
        const anchor = (nameOf(s, b, c.page, c.anchor) catch return) orelse continue;
        _ = b.marks.addComment(s.gpa, .{
            .id = c.id,
            .anchor = anchor,
            .name = (nameOf(s, b, c.page, c.nm) catch return) orelse 0,
            .text = c.text,
        }, true) catch return;
    }
}

/// The number a written name stands for in this buffer: one of fenrir's
/// read as the number it spells, which is the document's; anybody else's
/// held as it was written, which is its page's (`Marks.foreignName`).
/// Null for no name.
fn nameOf(s: *Session, b: *Buffer, page: u32, nm: []const u8) Allocator.Error!?u64 {
    if (nm.len == 0) return null;
    if (fenrirName(nm)) |n| return n;
    return try b.marks.foreignName(s.gpa, page, nm);
}

fn fenrirName(nm: []const u8) ?u64 {
    const n = Library.nameNumber(nm) orelse return null;
    return if (n < Marks.foreign_base) n else null;
}

/// How a name is written down: the other half of `nameOf`.
pub fn spell(b: *const Buffer, n: u64, buf: *[Library.name_len]u8) []const u8 {
    return b.marks.spelling(n) orelse Library.makeName(buf, n);
}

/// Takes the marks and comments already in the file: a highlight made
/// in Acrobat or Zotero, its note and the replies to it.
///
/// Every page, once, at open, on this thread: no page of the document
/// has been asked of the rasterising thread yet, so it is still this
/// thread's to read. The whole document rather than each page as it is
/// wanted, because it costs little -- 3.5 ms for 1,486 annotations on
/// 286 pages, 1.0 ms for a paper with 328, best of five, ReleaseFast --
/// and a page at a time, the panel, `]c` and the next free name would
/// each wait on pages nobody had scrolled to. `--time` prints it.
///
/// **The library wins.** Its rows are what this reader changed since the
/// file was written, so a name it already holds is not read again from
/// the file: an anchor's lines, or a comment.
///
/// A reload hands in what the worker read beside the file
/// (`watch.Loaded.annots`), so that the frame thread does not walk the
/// file again: on a 286-page book that walk was most of what installing
/// a reload cost.
pub fn readAnnots(s: *Session, index: u32, already: ?[]const []const fenrir.annots.Annot) void {
    const b = s.buffer(index);
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const lists = a.alloc([]const fenrir.annots.Annot, b.pages.len) catch return;
    for (b.pages, lists, 0..) |p, *list, page| {
        list.* = if (already) |read| (if (page < read.len) read[page] else &.{}) else fenrir.annots.read(a, b.doc, p) catch &.{};
    }

    // Every name of fenrir's the file holds is spent before any is handed
    // out: a page read late would otherwise find its `f12` given already,
    // to an annotation on an earlier page that came with no name.
    for (lists) |list| {
        for (list) |annot| {
            if (fenrirName(annot.name)) |n| b.marks.reserve(n);
        }
    }

    // What the library put there, asked once rather than once per
    // annotation: `lineCount` walks every mark.
    var held: Held = .{};
    for (b.marks.items()) |m| held.anchors.put(a, m.anchor, {}) catch return;
    for (b.marks.comments.items) |c| held.comments.put(a, c.name, {}) catch return;
    if (s.library) |lib| readJournal(s, b, lib, &held, a) catch return;
    renumberClashes(s, b, lists, &held, a) catch return;

    // The names given before to annotations that came with none.
    var named: Named = .empty;
    if (s.library) |lib| {
        const given: []Library.Naming = lib.namings(b.path) catch &.{};
        defer lib.freeNamings(given, given.len);
        for (given) |g| {
            const n = fenrirName(g.nm) orelse continue;
            named.put(a, .{ g.page, g.shape }, n) catch return;
        }
    }

    // What a reload takes away and reads again.
    const taken: ?*std.AutoHashMapUnmanaged(u64, void) = if (index < s.disks.items.len) &s.disks.items[index].taken else null;
    for (lists, 0..) |list, page| {
        if (list.len == 0) continue;
        takeAnnots(s, a, b, @intCast(page), list, &held, taken, &named) catch return;
    }
}

/// Names given to annotations that came with none, by page and shape.
const Named = std.AutoHashMapUnmanaged(struct { u32, u64 }, u64);

/// What the library says of the file beyond its rows: what the reader
/// deleted that the file still holds, and which rows are its versions of
/// the file's, which no newer copy can clash with.
fn readJournal(s: *Session, b: *Buffer, lib: Library, held: *Held, a: Allocator) !void {
    const gone = try lib.gones(b.path);
    defer lib.freeGones(gone, gone.len);
    for (gone) |g| {
        const n = (try nameOf(s, b, g.page, g.nm)) orelse continue;
        try (if (g.comment) &held.comments else &held.gone).put(a, n, {});
    }
    const changed = try lib.edits(b.path);
    defer lib.freeNames(changed);
    for (changed) |nm| {
        if (fenrirName(nm)) |n| try held.edits.put(a, n, {});
    }
}

/// What the library holds, which the file does not get to say again: an
/// anchor's lines, and a comment, apart. The first comment on an anchor has
/// the anchor's name, so one set would let a comment written on another
/// program's highlight hide the highlight it was written on.
const Held = struct {
    anchors: std.AutoHashMapUnmanaged(u64, void) = .empty,
    comments: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Anchors the reader deleted, which the file still holds, with their
    /// replies: none of it is read.
    gone: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Names whose rows are the reader's versions of the file's.
    edits: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn contains(h: Held, n: u64) bool {
        return h.anchors.contains(n) or h.comments.contains(n);
    }
};

/// A name the library holds for something the reader made, which the file
/// now holds for something else: a newer copy, annotated by another
/// fenrir before this one's rows were written into it. The library's is
/// given a new name, everywhere, and the file's is read as it is.
///
/// **Only a name with nothing in common.** A row the reader wrote over
/// one of the file's -- recoloured, a line taken off, a comment changed
/// -- is the same thing under the same name, and the library wins it, as
/// it does at open; so is a row a save wrote in and did not live to clear.
/// Each of those keeps a line where the file's is, or answers the same
/// anchor. Asked once a name over the whole file, since one of fenrir's
/// anchors may be on several pages and changed on only some of them.
fn renumberClashes(
    s: *Session,
    b: *Buffer,
    lists: []const []const fenrir.annots.Annot,
    held: *Held,
    a: Allocator,
) Allocator.Error!void {
    var shared: std.AutoArrayHashMapUnmanaged(u64, bool) = .empty;
    for (lists, 0..) |list, page| {
        for (list) |annot| {
            const n = fenrirName(annot.name) orelse continue;
            if (!held.contains(n) or held.edits.contains(n)) continue;
            const got = try shared.getOrPut(a, n);
            if (!got.found_existing) got.value_ptr.* = false;
            if (try sameThing(s, b, @intCast(page), list, n, annot)) got.value_ptr.* = true;
        }
    }
    for (shared.keys(), shared.values()) |n, same| {
        if (same) continue;
        const fresh = b.marks.newName();
        b.marks.rename(n, fresh);
        if (held.anchors.remove(n)) try held.anchors.put(a, fresh, {});
        if (held.comments.remove(n)) try held.comments.put(a, fresh, {});
        var from: [Library.name_len]u8 = undefined;
        var to: [Library.name_len]u8 = undefined;
        if (s.library) |lib| lib.renumber(b.path, Library.makeName(&from, n), Library.makeName(&to, fresh)) catch {};
        s.say("{s}: the file has another {s}; what this reader made under that name is {s} now", .{
            b.title,
            Library.makeName(&from, n),
            Library.makeName(&to, fresh),
        });
    }
}

/// Whether what the reader holds as `n` and what the file draws as `annot`
/// on `page` are one thing: a line or a stroke of it where one of the
/// file's is, to the hundredth of a point a save keeps; for a reply, the
/// same anchor answered. When the file does not say what a reply answers
/// by a name, it is taken as the same: the library winning is what was
/// done before there was a question, and a wrong renaming is worse.
fn sameThing(s: *Session, b: *Buffer, page: u32, list: []const fenrir.annots.Annot, n: u64, annot: fenrir.annots.Annot) Allocator.Error!bool {
    if (annot.kind == .reply) {
        const thread = list[annot.thread orelse return true];
        if (thread.name.len == 0) return true;
        const answers = (try nameOf(s, b, page, thread.name)).?;
        for (b.marks.comments.items) |c| {
            if (c.name == n) return c.anchor == answers;
        }
        return false;
    }
    for (b.marks.items()) |m| {
        if (m.anchor != n or m.page != page) continue;
        if (m.kind == .ink) {
            for (annot.paths) |path| {
                if (samePath(m.points, path)) return true;
            }
        } else for (annot.lines) |box| {
            if (sameBox(m.box, box)) return true;
        }
    }
    return false;
}

fn sameBox(x: gelgja.Bounds, y: gelgja.Bounds) bool {
    return near(x.min_x, y.min_x) and near(x.min_y, y.min_y) and near(x.max_x, y.max_x) and near(x.max_y, y.max_y);
}

fn samePath(x: []const Point, y: []const Point) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (!near(p.x, q.x) or !near(p.y, q.y)) return false;
    }
    return true;
}

fn near(x: f32, y: f32) bool {
    return @abs(x - y) <= 0.006;
}

/// The number an annotation is held by: its name, unless it has none or
/// its page repeats it, and then the name given it before by its shape,
/// or a number that spells as nothing until one is (`nameUnnamed`).
fn nameAt(
    s: *Session,
    b: *Buffer,
    page: u32,
    annot: fenrir.annots.Annot,
    repeated: *const std.StringHashMapUnmanaged(u32),
    named: *const Named,
) Allocator.Error!u64 {
    if (annot.name.len != 0 and (repeated.get(annot.name) orelse 0) < 2) return (try nameOf(s, b, page, annot.name)).?;
    const shape = fenrir.annots.shapeOf(annot);
    if (named.get(.{ page, shape })) |n| return n;
    return b.marks.unnamedName(s.gpa, .{ .page = page, .shape = shape });
}

fn takeAnnots(
    s: *Session,
    a: Allocator,
    b: *Buffer,
    page: u32,
    list: []const fenrir.annots.Annot,
    held: *const Held,
    taken: ?*std.AutoHashMapUnmanaged(u64, void),
    named: *const Named,
) Allocator.Error!void {
    // A name the page gives twice names neither: §12.5.2 makes `/NM` the
    // page's own, and two annotations under one are two things it cannot
    // tell apart. Both are taken as having none.
    var repeated: std.StringHashMapUnmanaged(u32) = .empty;
    for (list) |annot| {
        if (annot.name.len == 0) continue;
        const got = try repeated.getOrPut(a, annot.name);
        got.value_ptr.* = if (got.found_existing) got.value_ptr.* + 1 else 1;
    }

    // The anchor each was taken as, so a reply finds its thread's, or
    // null for one the reader deleted, whose replies went with it.
    const anchors = try a.alloc(?u64, list.len);
    for (list, anchors) |annot, *anchor| {
        if (annot.kind == .reply) continue;
        const n = try nameAt(s, b, page, annot, &repeated, named);
        anchor.* = n;
        // Whatever the library says of it, the file holds it: a change to
        // it is a change to one of the file's.
        if (taken) |t| try t.put(s.gpa, n, {});
        // Deleted, unless an undo has put lines of it back since.
        if (held.gone.contains(n) and !held.anchors.contains(n)) {
            anchor.* = null;
            continue;
        }
        // The lines and the note apart: either may be the library's.
        const lines = !held.anchors.contains(n);
        const note = annot.text.len != 0 and !held.comments.contains(n);
        if (!lines and !note) continue;

        if (lines) switch (annot.kind) {
            .ink => for (annot.paths) |path| {
                _ = try b.marks.add(s.gpa, .{
                    .kind = .ink,
                    .page = page,
                    .points = path,
                    .width = if (annot.width > 0) annot.width else default_pen_width,
                    .color = annot.color orelse ink_colour,
                    .anchor = n,
                }, true);
            },
            else => for (annot.lines) |box| {
                _ = try b.marks.add(s.gpa, .{
                    .page = page,
                    .box = box,
                    .color = annot.color orelse s.highlight,
                    .style = styleOfAnnot(annot.kind),
                    .anchor = n,
                }, true);
            },
        };
        // The markup's own note is the first comment, and has its name.
        if (note) {
            _ = try b.marks.addComment(s.gpa, .{ .anchor = n, .name = n, .text = annot.text }, true);
        }
    }

    for (list) |annot| {
        if (annot.kind != .reply or annot.text.len == 0) continue;
        const thread = annot.thread orelse continue;
        // A reply with no name of its own gets a number rather than the
        // anchor's, which would make it the note on the markup.
        const on = anchors[thread] orelse continue;
        const name = try nameAt(s, b, page, annot, &repeated, named);
        if (taken) |t| try t.put(s.gpa, name, {});
        if (held.comments.contains(name)) continue;
        _ = try b.marks.addComment(s.gpa, .{ .anchor = on, .name = name, .text = annot.text }, true);
    }
}

fn styleOfAnnot(kind: fenrir.annots.Kind) Marks.Style {
    return switch (kind) {
        .highlight => .highlight,
        .underline => .underline,
        .strikeout => .strikeout,
        .squiggly => .squiggly,
        .arrow => .arrow,
        .ink, .reply => unreachable,
    };
}

/// What `comment_anchor` says, or a highlight when it says nothing this
/// build knows.
pub fn rememberedCommentStyle(s: *Session) Marks.Style {
    const lib = s.library orelse return .highlight;
    const said = (lib.get("comment_anchor") catch null) orelse return .highlight;
    defer s.gpa.free(said);
    return commentStyleNamed(said) orelse .highlight;
}

pub fn commentStyleNamed(name: []const u8) ?Marks.Style {
    if (std.mem.eql(u8, name, "highlight")) return .highlight;
    if (std.mem.eql(u8, name, "arrow")) return .arrow;
    return null;
}

// -- on the page -------------------------------------------------------------

/// The marks over words on the pages a window can see.
///
/// Drawn over the page rather than under it, with alpha, because a PDF's
/// paper is opaque: a highlight beneath it would not be visible at all.
/// That means dark text shows through a light wash, which is what a
/// highlighter does to paper. An underline, a strike-through and a
/// squiggle are solid, being lines and not washes.
///
/// The one in hand in edit mode is stronger and outlined, and the first
/// line of an anchor with a comment carries a small tab at its top-right
/// corner -- the comment's text is in the title bar while the highlight
/// is in hand, since the title bar is the only text this window draws.
///
/// The whole range at once, rather than a call per page: a buffer's marks
/// are one list in no particular page order, so a call per page would
/// walk all of them once for each page on screen, and a well-marked
/// document with four windows open would walk it a dozen times a frame.
pub fn drawMarks(
    s: *Session,
    v: *View,
    b: *Buffer,
    range: View.Visible,
    over: *DrawList,
) !void {
    const editing = s.keymap.mode == .edit or s.keymap.mode == .note;
    const in_focus = v == s.layout().current();
    for (b.marks.items(), 0..) |mark, i| {
        if (mark.kind != .block) continue;
        if (mark.page < range.first or mark.page >= range.end) continue;
        const page = mark.page;
        const box = v.windowBox(page, mark.box);
        const held = editing and in_focus and s.focus_mark == mark.key;
        const c = mark.color;
        switch (mark.style) {
            .highlight => try over.rounded(
                frame.blockOf(box, v.zoom),
                .all(frame.markRadius(v.zoom)),
                .{ .r = c.r, .g = c.g, .b = c.b, .a = if (held) 0.55 else 0.35 },
            ),
            .underline, .strikeout => try over.fill(ruleOf(box, mark.style), c),
            .squiggly => try squiggle(over, box, c),
            // From the first line only: the arrow says where the words
            // begin, and the outline in edit mode says where they run.
            .arrow => if (b.marks.heads(s.gpa, i)) try arrow(over, box, lineStart(v, b, mark, box), c),
        }
        if (held) {
            const pad = 2.0;
            try over.border(
                .fromRect(box.min_x - pad, box.min_y - pad, box.max_x + pad, box.max_y + pad),
                .all(2),
                2,
                .{ .r = c.r * 0.6, .g = c.g * 0.6, .b = c.b * 0.6, .a = 1 },
            );
        }
        // On the anchor's first line only: six lines of one comment
        // carry one tab.
        if (b.marks.leads(s.gpa, i)) {
            const tab = @max(4.0, 3.0 * v.zoom);
            try over.fill(
                .fromRect(box.max_x - tab, box.min_y - tab * 0.5, box.max_x + tab * 0.5, box.min_y + tab),
                .{ .r = c.r * 0.7, .g = c.g * 0.7, .b = c.b * 0.7, .a = 1 },
            );
        }
    }
}

/// How heavy an underline, a strike-through or a squiggle is: a twelfth
/// of the line it marks, so it keeps its weight against the type at
/// every zoom, and never under a pixel.
fn ruleWeight(box: Bounds) f32 {
    return @max(1.0, box.height() / 12);
}

/// An underline at the foot of the box, or a strike-through across its
/// middle. One rect, as a highlight is one.
pub fn ruleOf(box: Bounds, style: Marks.Style) Bounds {
    const t = ruleWeight(box);
    const top = if (style == .underline) box.max_y - t else (box.min_y + box.max_y - t) * 0.5;
    return .fromRect(box.min_x, top, box.max_x, top + t);
}

/// Where the line a mark is on begins, in window x, so that an arrow
/// stops short of the line's first word and not of the mark's: a
/// selection begun mid-line would otherwise have its arrow drawn over
/// the words before it. The mark's own edge when the text is not known.
fn lineStart(v: *View, b: *Buffer, mark: Marks.Mark, box: Bounds) f32 {
    const map = b.textMap(mark.page) orelse return box.min_x;
    if (map.isEmpty()) return box.min_x;
    const line = map.lines[map.lineAt(mark.box.min_x, (mark.box.min_y + mark.box.max_y) * 0.5)].box;
    const start = v.windowBox(mark.page, .fromRect(line.min_x, line.min_y, line.min_x + 1, line.max_y));
    return @min(start.min_x, box.min_x);
}

/// An arrow in the margin, pointing at the line `box` is on from left of
/// `start`, where its words begin: a shaft and a head, in the mark's
/// colour darkened to read on paper.
///
/// The overlay draws axis-aligned boxes and nothing else, so the head is
/// a stack of slices about a pixel wide, each shorter than the last: a
/// triangle at any size worth drawing, for about a line's height in
/// instances, and only on an anchor's first line.
pub fn arrow(over: *DrawList, box: Bounds, start: f32, color: Color) !void {
    const h = @max(box.height(), 4);
    const tip = start - h * 0.25;
    const head = h * 0.5;
    const half = h * 0.3;
    const mid = (box.min_y + box.max_y) * 0.5;
    const t = @max(1.0, h * 0.1);
    const ink: Color = .{ .r = color.r * 0.75, .g = color.g * 0.75, .b = color.b * 0.75, .a = 1 };
    try over.fill(.fromRect(tip - head - h * 1.2, mid - t * 0.5, tip - head + 0.5, mid + t * 0.5), ink);

    const slices: f32 = std.math.clamp(@ceil(head), 2, 24);
    const step = head / slices;
    var j: f32 = 0;
    while (j < slices) : (j += 1) {
        const y = half * (1 - (j + 0.5) / slices);
        const x = tip - head + j * step;
        try over.fill(.fromRect(x, mid - y, x + step + 0.25, mid + y), ink);
    }
}

/// A squiggle along the foot of the box: half rings, the top of one and
/// the bottom of the next, each clipped to its half. Two halves meet with
/// the same upright tangent, so the chain is a smooth wave.
///
/// Not ink's stamping, which it began as: a disc every half pixel was
/// 562 instances a line at 120%, fifty thousand for a page of squiggles,
/// rebuilt every frame. This is one a half wave, a fifth of that.
pub fn squiggle(over: *DrawList, box: Bounds, color: Color) !void {
    const t = ruleWeight(box);
    // To the middle of the stroke, and to its outside edge.
    const r = 1.25 * t;
    const outer = r + t * 0.5;
    const y = box.max_y - outer;
    over.pushClip(box);
    defer over.popClip();

    var x = box.min_x + r;
    var up = true;
    while (x - r < box.max_x) : ({
        x += 2 * r;
        up = !up;
    }) {
        over.pushClip(.fromRect(x - outer, if (up) y - outer else y, x + outer, if (up) y else y + outer));
        defer over.popClip();
        try over.border(.fromRect(x - outer, y - outer, x + outer, y + outer), .all(outer), t, color);
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const windows = @import("windows.zig");
const interface = @import("interface.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const giveLibrary = fixtures.giveLibrary;
const putText = fixtures.putText;
const sessionOf = fixtures.sessionOf;

test "a highlight made in one window is in the other" {
    // The requirement in one test: two views, one underlying document, and a
    // change made through one visible through the other with nothing copied.
    if (!caps.splits) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    windows.splitWindow(&s, .vertical);
    const before = s.buffer(0).marks.revision;

    highlightBoxes(&s, 0, &.{.{ .page = 1, .box = .fromRect(100, 700, 300, 712) }}, s.accent);

    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
    try testing.expect(s.buffer(0).marks.revision != before);

    var it = s.layout().iterator();
    while (it.next()) |v| {
        try testing.expect(v.marks_seen != s.buffer(v.buffer).marks.revision);
    }
}

test "visual mode: select with motions, highlight in a colour, undo it" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    // `v`, `j`, `w`, `3`: what the keymap turns those keys into.
    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    try testing.expect(s.view().anchor != null);
    _ = s.apply(.{ .move_cursor = .down });
    _ = s.apply(.{ .move_cursor = .word_next });
    s.keymap.mode = .normal;
    _ = s.apply(.{ .highlight_selection = 2 });

    const marks = &s.buffer(0).marks;
    // Two lines selected, so two marks, in the third palette colour.
    try testing.expectEqual(@as(usize, 2), marks.count());
    try testing.expectEqual(Library.parseColor("green").?, marks.items()[0].color);
    try testing.expect(s.view().anchor == null);

    // And one `u` takes both back.
    _ = s.apply(.undo);
    try testing.expectEqual(@as(usize, 0), marks.count());
    _ = s.apply(.redo);
    try testing.expectEqual(@as(usize, 2), marks.count());
}

test "a change the library refuses is kept, counted, and written once it will take it" {
    // The open gap this closes: the queue was cleared before writing and
    // every error swallowed, so the mark below would have had no row for
    // good, and its recolour been skipped as a change to nothing stored.
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var buf: [2]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 1), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    const b = s.buffer(0);

    // A table that is not there is a write that fails, as a full disk's is.
    try lib.db.exec("ALTER TABLE mark RENAME TO away");
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 300, 712) }}, s.accent);
    applyEffects(&s);
    try testing.expectEqual(@as(usize, 1), b.marks.owed());
    try testing.expectEqual(@as(u32, 1), s.statusLine().unsaved);
    try testing.expect(std.mem.indexOf(u8, s.status, "kept") != null);

    // Changed again while it is held: behind it, and not tried every frame.
    b.marks.beginGroup();
    try b.marks.recolour(gpa, 0, Library.parseColor("green").?);
    applyEffects(&s);
    try testing.expectEqual(@as(usize, 2), b.marks.owed());
    applyEffects(&s);
    try testing.expectEqual(@as(usize, 2), b.marks.owed());

    // The library can take it again, and `:w` does not wait for a change.
    try lib.db.exec("ALTER TABLE away RENAME TO mark");
    try testing.expect(s.exec("w"));
    try testing.expectEqual(@as(usize, 0), b.marks.owed());
    try testing.expectEqual(@as(u32, 0), s.statusLine().unsaved);

    const rows = try lib.marks("/docs/a.pdf");
    defer lib.freeMarks(rows, rows.len);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("#3fa34d", rows[0].color);
    try testing.expect(b.marks.items()[0].saved());
}

/// A page carrying what Acrobat leaves and what a save by fenrir would: a
/// highlight of two lines with a note and a reply, under names that are not
/// fenrir's, and a stroke named `f7`.
const annotated_pdf =
    \\%PDF-1.7
    \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    \\2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    \\3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800]
    \\  /Annots [30 0 R 31 0 R 32 0 R 33 0 R] >> endobj
    \\30 0 obj << /Subtype /Highlight /Rect [87 521 273 570] /NM (305e35fa) /C [1 0.75 0]
    \\  /Contents (why) /QuadPoints [134 569 272 569 134 557 272 557 87 557 272 557 87 545 272 545] >> endobj
    \\31 0 obj << /Subtype /Text /Rect [0 0 20 20] /IRT 30 0 R /NM (ccbe0138) /Contents (because) >> endobj
    \\32 0 obj << /Subtype /Ink /Rect [0 0 99 99] /NM (f7) /InkList [[10 10 40 40]] >> endobj
    \\33 0 obj << /Subtype /Link /Rect [0 0 99 99] >> endobj
    \\trailer << /Root 1 0 R /Size 40 >>
    \\startxref 0
    \\%%EOF
    \\
;

test "the file's annotations are marks and comments, and the library's names win" {
    const gpa = testing.allocator;
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};
    var s = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&s);
    const b = s.buffer(0);
    b.doc = &doc;

    // The library already holds the stroke, as a journal row newer than
    // the file -- recoloured, where the file has it -- and it is not read
    // a second time.
    const red = Library.parseColor("red").?;
    _ = try b.marks.add(gpa, .{ .kind = .ink, .points = &.{ .{ .x = 10, .y = 10 }, .{ .x = 40, .y = 40 } }, .color = red, .anchor = 7 }, true);
    readAnnots(&s, 0, null);

    const marks = &b.marks;
    try testing.expectEqual(@as(usize, 3), marks.count());
    const line = marks.items()[1];
    try testing.expectEqual(Marks.Style.highlight, line.style);
    try testing.expectApproxEqAbs(@as(f32, 545), marks.items()[2].box.min_y, 1e-3);
    try testing.expectEqual(line.anchor, marks.items()[2].anchor);

    // The note is the first comment and has the highlight's name; the reply
    // keeps its own. Both are spelled back as they were written.
    const said = marks.said(line.anchor);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqualStrings("why", said[0].text);
    try testing.expectEqualStrings("because", said[1].text);
    var name: [Library.name_len]u8 = undefined;
    try testing.expectEqualStrings("305e35fa", spell(b, said[0].name, &name));
    try testing.expectEqualStrings("ccbe0138", spell(b, said[1].name, &name));

    // None of it is a change, and fenrir's next name is past the stroke's.
    try testing.expect(!marks.dirty);
    try testing.expect(marks.newName() > 7);
}

test "a name the reader made, which the file holds for something else, is given another" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};
    var s = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    const b = s.buffer(0);
    b.doc = &doc;

    // A highlight this reader made as f7, not yet in the file, where a copy
    // annotated elsewhere has a stroke under the same name.
    _ = try lib.addMark("/docs/a.pdf", .{ .page = 0, .x0 = 300, .y0 = 100, .x1 = 400, .y1 = 112, .anchor = @constCast("f7") }, 1);
    _ = try lib.addComment("/docs/a.pdf", .{ .anchor = @constCast("f7"), .nm = @constCast("f7"), .text = @constCast("mine") }, 1);
    loadMarks(&s, 0);
    readAnnots(&s, 0, null);

    // Both are there: the file's stroke as f7, the highlight under a name
    // past every one the file holds, its comment with it.
    try testing.expectEqual(@as(usize, 4), b.marks.count());
    const mine = b.marks.items()[0];
    try testing.expect(mine.anchor > 7);
    try testing.expectEqualStrings("mine", b.marks.said(mine.anchor)[0].text);
    try testing.expectEqual(mine.anchor, b.marks.said(mine.anchor)[0].name);
    for (b.marks.items()) |m| {
        if (m.kind == .ink) try testing.expectEqual(@as(u64, 7), m.anchor);
    }
    var name: [Library.name_len]u8 = undefined;
    const rows = try lib.marks("/docs/a.pdf");
    defer lib.freeMarks(rows, rows.len);
    try testing.expectEqualStrings(Library.makeName(&name, mine.anchor), rows[0].anchor);
    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqualStrings(rows[0].anchor, said[0].nm);
}

/// Two highlights under one name, which their page may not repeat, and an
/// underline with none.
const unnamed_pdf =
    \\%PDF-1.7
    \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    \\2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    \\3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Annots [30 0 R 31 0 R 32 0 R] >> endobj
    \\30 0 obj << /Subtype /Highlight /Rect [100 700 300 712] /NM (dup) /QuadPoints [100 712 300 712 100 700 300 700] >> endobj
    \\31 0 obj << /Subtype /Highlight /Rect [100 600 300 612] /NM (dup) /QuadPoints [100 612 300 612 100 600 300 600] >> endobj
    \\32 0 obj << /Subtype /Underline /Rect [100 500 300 512] /QuadPoints [100 512 300 512 100 500 300 500] >> endobj
    \\trailer << /Root 1 0 R /Size 40 >>
    \\startxref 0
    \\%%EOF
    \\
;

test "an annotation with no name, or one its page repeats, is named when written about, and found by its shape" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, unnamed_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};
    var s = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    const b = s.buffer(0);
    b.doc = &doc;
    loadMarks(&s, 0);
    readAnnots(&s, 0, null);

    // Three anchors, none of them spelled, and fenrir's count unspent.
    try testing.expectEqual(@as(usize, 3), b.marks.count());
    const items = b.marks.items();
    try testing.expect(items[0].anchor != items[1].anchor);
    var name: [Library.name_len]u8 = undefined;
    for (items) |m| try testing.expectEqualStrings("", spell(b, m.anchor, &name));
    try testing.expectEqual(@as(u64, 1), b.marks.next_name);

    // A comment on the underline gives it fenrir's first name, written
    // down by its shape, and the comment goes under that name.
    const loose = items[2].anchor;
    b.marks.beginGroup();
    _ = try b.marks.addComment(gpa, .{ .anchor = loose, .text = "underlined" }, false);
    applyEffects(&s);
    const named = b.marks.items()[2].anchor;
    try testing.expectEqual(@as(u64, 1), named);
    try testing.expectEqualStrings("underlined", b.marks.said(named)[0].text);
    try testing.expect(s.disk(0).taken.contains(named));
    const given = try lib.namings("/docs/a.pdf");
    defer lib.freeNamings(given, given.len);
    try testing.expectEqual(@as(usize, 1), given.len);
    try testing.expectEqualStrings("f1", given[0].nm);

    // The next open finds the underline by its shape, and the comment on it.
    var again = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&again);
    try giveLibrary(&again, lib);
    again.buffer(0).doc = &doc;
    loadMarks(&again, 0);
    readAnnots(&again, 0, null);
    const back = again.buffer(0).marks.items();
    try testing.expectEqual(@as(usize, 3), back.len);
    try testing.expectEqual(@as(u64, 1), back[2].anchor);
    try testing.expectEqualStrings("underlined", again.buffer(0).marks.said(1)[0].text);
    // And the name stays spent: the next is past it.
    try testing.expect(again.buffer(0).marks.newName() > 1);
}

test "a name handed out is not handed out again after its mark is gone" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var buf: [2]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 1), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);

    const made = markBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 300, 712) }}, s.accent, .highlight);
    applyEffects(&s);
    s.buffer(0).marks.beginGroup();
    _ = try s.buffer(0).marks.removeAt(gpa, 0);
    applyEffects(&s);

    // Counted from the rows, which are gone, the next open would give the
    // same name to the next thing made, and a link to the old would land on it.
    var again = try sessionOf(gpa, fakePages(&buf, 1), 1, 1000, 800);
    defer closeSession(&again);
    try giveLibrary(&again, lib);
    loadMarks(&again, 0);
    try testing.expect(again.buffer(0).marks.newName() > made);
}

/// A session on `annotated_pdf` with the library, its marks loaded and the
/// file's read, as an open leaves it.
fn openAnnotated(gpa: Allocator, lib: Library, doc: *fenrir.Document, buf: *[1]fenrir.Page) !Session {
    var s = try sessionOf(gpa, buf, 1, 1000, 800);
    errdefer closeSession(&s);
    try giveLibrary(&s, lib);
    s.buffer(0).doc = doc;
    loadMarks(&s, 0);
    readAnnots(&s, 0, null);
    return s;
}

/// The marks of the file's highlight, by its name.
fn linesOf(b: *Buffer, nm: []const u8) usize {
    var n: usize = 0;
    for (b.marks.items()) |m| {
        if (std.mem.eql(u8, b.marks.spelling(m.anchor) orelse "", nm)) n += 1;
    }
    return n;
}

test "a change to the file's own mark is kept, and the next open shows it" {
    // The two open gaps this closes: a recolour of a mark read from the
    // file came back in the file's colour, and a deleted one came back.
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};

    {
        var s = try openAnnotated(gpa, lib, &doc, &buf);
        defer closeSession(&s);
        const b = s.buffer(0);
        // The first line of Acrobat's highlight recoloured, and the stroke
        // deleted.
        b.marks.beginGroup();
        try b.marks.recolour(gpa, 0, Library.parseColor("blue").?);
        const stroke = for (b.marks.items(), 0..) |m, i| {
            if (m.kind == .ink) break i;
        } else unreachable;
        _ = try b.marks.removeAt(gpa, stroke);
        applyEffects(&s);
        // Both lines are the library's now, and only one changed colour.
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try testing.expectEqualStrings("305e35fa", rows[0].anchor);
        try testing.expect(!std.mem.eql(u8, rows[0].color, rows[1].color));
    }

    var s = try openAnnotated(gpa, lib, &doc, &buf);
    defer closeSession(&s);
    const b = s.buffer(0);
    try testing.expectEqual(@as(usize, 2), b.marks.count());
    try testing.expectEqual(@as(usize, 2), linesOf(b, "305e35fa"));
    try testing.expectEqual(Library.parseColor("blue").?, b.marks.items()[0].color);
    for (b.marks.items()) |m| try testing.expect(m.kind != .ink);
    // The note and the reply are still the file's, on the library's lines.
    const said = b.marks.said(b.marks.items()[0].anchor);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqualStrings("why", said[0].text);
}

test "the file's comments changed or cleared stay so, and a deleted anchor takes its replies" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};

    {
        var s = try openAnnotated(gpa, lib, &doc, &buf);
        defer closeSession(&s);
        const b = s.buffer(0);
        const anchor = b.marks.items()[0].anchor;
        b.marks.beginGroup();
        // The reply said again, the note on the highlight cleared.
        try b.marks.setText(gpa, b.marks.saidRange(anchor)[0] + 1, "because so");
        _ = try b.marks.removeComment(gpa, b.marks.saidRange(anchor)[0]);
        applyEffects(&s);
    }
    {
        var s = try openAnnotated(gpa, lib, &doc, &buf);
        defer closeSession(&s);
        const b = s.buffer(0);
        // Clearing the note left the highlight, as the design says.
        try testing.expectEqual(@as(usize, 2), linesOf(b, "305e35fa"));
        const said = b.marks.said(b.marks.items()[0].anchor);
        try testing.expectEqual(@as(usize, 1), said.len);
        try testing.expectEqualStrings("because so", said[0].text);

        // Now the highlight goes, both lines in one step, and its reply
        // with it.
        b.marks.beginGroup();
        var i = b.marks.count();
        while (i > 0) {
            i -= 1;
            if (b.marks.items()[i].kind != .ink) _ = try b.marks.removeAt(gpa, i);
        }
        applyEffects(&s);
    }

    var s = try openAnnotated(gpa, lib, &doc, &buf);
    defer closeSession(&s);
    const b = s.buffer(0);
    try testing.expectEqual(@as(usize, 1), b.marks.count());
    try testing.expectEqual(Marks.Kind.ink, b.marks.items()[0].kind);
    try testing.expectEqual(@as(usize, 0), b.marks.comments.items.len);
}

test "an undone deletion of the file's mark is the library's, and wins over its own deletion" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};

    {
        var s = try openAnnotated(gpa, lib, &doc, &buf);
        defer closeSession(&s);
        const b = s.buffer(0);
        const stroke = for (b.marks.items(), 0..) |m, i| {
            if (m.kind == .ink) break i;
        } else unreachable;
        b.marks.beginGroup();
        _ = try b.marks.removeAt(gpa, stroke);
        applyEffects(&s);
        _ = try b.marks.undo(gpa);
        applyEffects(&s);
    }

    var s = try openAnnotated(gpa, lib, &doc, &buf);
    defer closeSession(&s);
    var strokes: usize = 0;
    for (s.buffer(0).marks.items()) |m| strokes += @intFromBool(m.kind == .ink);
    try testing.expectEqual(@as(usize, 1), strokes);
}

test "the reader's version of the file's mark is never taken for a clash, wherever the file has moved it" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};

    // f7 recoloured by this reader where it once was; another program has
    // since moved the stroke. Still one thing under one name.
    var points = [_]Point{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    _ = try lib.addStroke("/docs/a.pdf", .{ .points = &points, .anchor = @constCast("f7"), .edit = true }, 1);
    var s = try openAnnotated(gpa, lib, &doc, &buf);
    defer closeSession(&s);
    var strokes: usize = 0;
    for (s.buffer(0).marks.items()) |m| {
        if (m.kind != .ink) continue;
        strokes += 1;
        try testing.expectEqual(@as(u64, 7), m.anchor);
    }
    try testing.expectEqual(@as(usize, 1), strokes);
}

test "a comment on another program's highlight is stored under that program's name" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};
    var s = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    const b = s.buffer(0);
    b.doc = &doc;
    readAnnots(&s, 0, null);

    const anchor = b.marks.items()[0].anchor;
    _ = try b.marks.addComment(gpa, .{ .anchor = anchor, .text = "and so" }, false);
    applyEffects(&s);

    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 1), said.len);
    try testing.expectEqualStrings("305e35fa", said[0].anchor);
    // Its own name is fenrir's: the anchor's went to the note in the file.
    try testing.expect(Library.nameNumber(said[0].nm) != null);

    // Read back on the next open, it lands on the same highlight.
    var again = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&again);
    try giveLibrary(&again, lib);
    again.buffer(0).doc = &doc;
    loadMarks(&again, 0);
    readAnnots(&again, 0, null);
    const lines = again.buffer(0).marks.items();
    try testing.expectEqual(@as(usize, 3), again.buffer(0).marks.said(lines[0].anchor).len);
}

test "c on a selection makes one anchor and its first comment, and c in edit mode another" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    try putText(&s, 0, 3, 4);

    // `v`, `j`, `c`, then the comment, as the keymap sends them.
    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .down });
    s.keymap.mode = .note;
    _ = s.apply(.comment_selection);
    for ("why") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    applyEffects(&s);

    // Two lines, one anchor, and the comment on it named as the anchor is.
    const marks = &s.buffer(0).marks;
    try testing.expectEqual(@as(usize, 2), marks.count());
    const anchor = marks.items()[0].anchor;
    try testing.expectEqual(anchor, marks.items()[1].anchor);
    try testing.expectEqual(anchor, marks.said(anchor)[0].name);
    try testing.expect(s.view().anchor == null);
    try testing.expectEqualStrings("why", s.statusLine().note);

    // `c` in edit mode is a reply on the same anchor, taken in hand.
    _ = s.apply(.add_comment);
    try testing.expectEqualStrings("", s.note.items);
    s.keymap.mode = .note;
    for ("because") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    try testing.expectEqual(@as(usize, 2), marks.said(anchor).len);
    try testing.expectEqualStrings("because", s.statusLine().note);

    // `a` changes the one in hand, which is the reply, not the first.
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    try testing.expectEqualStrings("because", s.note.items);
    _ = s.apply(.{ .note_char = '!' });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    applyEffects(&s);
    try testing.expectEqualStrings("why", marks.said(anchor)[0].text);
    try testing.expectEqualStrings("because!", marks.said(anchor)[1].text);

    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqualStrings(said[0].anchor, said[1].anchor);
    try testing.expect(!std.mem.eql(u8, said[0].nm, said[1].nm));
    try testing.expectEqualStrings("because!", said[1].text);

    // With nothing selected there is nothing to comment on, and no mark.
    s.keymap.mode = .note;
    _ = s.apply(.comment_selection);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expectEqual(@as(usize, 2), marks.count());
}

test "]c reads each comment of a thread, and in edit mode takes it in hand" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    try commentOn(marks, gpa, 0, "is this right?");
    try commentOn(marks, gpa, 0, "no");
    try commentOn(marks, gpa, 1, "see here");

    // Normal mode reads them in order without taking any in hand.
    const next: keys.Command = .{ .jump_mark = .{ .forwards = true, .comments = true } };
    _ = s.apply(next);
    try testing.expect(std.mem.endsWith(u8, s.status, "is this right?"));
    _ = s.apply(next);
    try testing.expect(std.mem.startsWith(u8, s.status, "comment 2/3"));
    try testing.expect(std.mem.endsWith(u8, s.status, "no"));
    _ = s.apply(next);
    try testing.expect(std.mem.endsWith(u8, s.status, "see here"));
    try testing.expect(s.focus_mark == null);

    // Edit mode takes up the first mark with its first comment in hand;
    // `]c` moves on to the reply and takes that, so `a` opens it.
    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqualStrings("is this right?", s.statusLine().note);
    _ = s.apply(next);
    try testing.expectEqual(marks.items()[0].key, s.focus_mark.?);
    try testing.expectEqualStrings("no", s.statusLine().note);
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    try testing.expectEqualStrings("no", s.note.items);
}

test "a selection's lines are one anchor, and marking them again keeps its comment" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    const lines = [_]selection.PageBox{
        .{ .page = 0, .box = .fromRect(100, 700, 300, 712) },
        .{ .page = 0, .box = .fromRect(100, 686, 300, 698) },
        .{ .page = 0, .box = .fromRect(100, 672, 200, 684) },
    };
    const anchor = markBoxes(&s, 0, &lines, s.accent, .highlight);
    const marks = &s.buffer(0).marks;
    for (marks.items()) |m| try testing.expectEqual(anchor, m.anchor);
    try commentOn(marks, gpa, 0, "one claim");

    // The comment on the first line, and the other two under it.
    if (caps.panels) {
        const rows = interface.panelRows(&s, .annotations);
        try testing.expectEqual(@as(usize, 3), rows.len);
        try testing.expectEqualStrings("one claim", rows[0].label);
        try testing.expectEqual(@as(u8, 0), rows[0].depth);
        try testing.expectEqual(@as(u8, 1), rows[2].depth);
    }

    // Underlined over the same words: new marks, a new anchor, and the
    // comment moved onto it rather than lost with the old marks.
    const again = markBoxes(&s, 0, &lines, s.accent, .underline);
    try testing.expect(again != anchor);
    try testing.expectEqual(@as(usize, 3), marks.count());
    try testing.expectEqual(@as(usize, 0), marks.said(anchor).len);
    try testing.expectEqualStrings("one claim", marks.said(again)[0].text);

    // One `u` is one step back to the old marks with their comment.
    _ = s.apply(.undo);
    try testing.expectEqualStrings("one claim", marks.said(anchor)[0].text);
    for (marks.items()) |m| try testing.expectEqual(anchor, m.anchor);
}

test "highlighting over a highlight replaces it rather than stacking" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    const line: selection.PageBox = .{ .page = 0, .box = .fromRect(100, 695, 160, 710) };
    highlightBoxes(&s, 0, &.{line}, Library.parseColor("yellow").?);
    highlightBoxes(&s, 0, &.{line}, Library.parseColor("blue").?);
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
    try testing.expectEqual(Library.parseColor("blue").?, s.buffer(0).marks.items()[0].color);
}

test "visual d removes the highlights the selection touches" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    // A highlight on each of the three lines.
    const map = s.buffer(0).textMap(0).?;
    for (map.lines) |l| highlightBoxes(&s, 0, &.{.{ .page = 0, .box = l.box }}, s.accent);
    try testing.expectEqual(@as(usize, 3), s.buffer(0).marks.count());

    // Select from the second line to the third, and delete.
    s.view().cursorTo(.{ .page = 0, .line = 1, .column = 0 }, map);
    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .down });
    s.keymap.mode = .normal;
    _ = s.apply(.unhighlight_selection);

    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
}

test "a selection underlined, then squiggled in edit mode, keeps its style in the library" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    try putText(&s, 0, 3, 4);

    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .word_next });
    s.keymap.mode = .normal;
    _ = s.apply(.{ .style_selection = .underline });
    applyEffects(&s);
    const marks = &s.buffer(0).marks;
    try testing.expectEqual(Marks.Style.underline, marks.items()[0].style);

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    _ = s.apply(.{ .restyle_mark = .squiggly });
    applyEffects(&s);

    // Read back as the next session would.
    marks.deinit(gpa);
    loadMarks(&s, 0);
    try testing.expectEqual(Marks.Style.squiggly, marks.items()[0].style);
}

test "an underline is one rect at the foot of the line, and a squiggle stays inside it" {
    const gpa = testing.allocator;
    const box: Bounds = .fromRect(100, 200, 400, 224);
    const under = ruleOf(box, .underline);
    try testing.expectEqual(box.max_y, under.max_y);
    try testing.expectApproxEqAbs(@as(f32, 2), under.height(), 1e-4);
    const through = ruleOf(box, .strikeout);
    try testing.expectApproxEqAbs((box.min_y + box.max_y) * 0.5, (through.min_y + through.max_y) * 0.5, 1e-4);

    var d: DrawList = .init(gpa, .fromRect(0, 0, 1000, 1000));
    defer d.deinit();
    try squiggle(&d, box, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    var ink: Bounds = .empty;
    for (d.instances.items) |i| ink = ink.add(.{ .x = i.dst[0], .y = i.dst[1] }).add(.{ .x = i.dst[2], .y = i.dst[3] });
    try testing.expect(ink.max_y <= box.max_y + 1e-3 and ink.min_y >= box.min_y);
    // A half ring every five pixels of a line 24 tall: what it costs a frame.
    try testing.expectEqual(@as(usize, 60), d.instances.items.len);
}

test "edit mode walks highlights in reading order, recolours, comments and deletes, and the library follows" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);

    // Made bottom first, so reading order and creation order differ.
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 600, 200, 612) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    applyEffects(&s);
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 2), rows.len);
    }

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    const marks = &s.buffer(0).marks;
    // No cursor out, so the first in reading order: the higher one.
    try testing.expectApproxEqAbs(@as(f32, 700), marks.items()[focusedMarkIndex(&s).?].box.min_y, 0.01);

    _ = s.apply(.next_mark);
    try testing.expectApproxEqAbs(@as(f32, 600), marks.items()[focusedMarkIndex(&s).?].box.min_y, 0.01);

    _ = s.apply(.{ .recolour_mark = 4 });
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    for ("check") |c| _ = s.apply(.{ .note_char = c });
    _ = s.apply(.note_backspace);
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    applyEffects(&s);

    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        var found = false;
        for (rows) |r| {
            if (r.y0 != 600) continue;
            found = true;
            try testing.expectEqualStrings("#ef476f", r.color);
            // Written on its anchor, named as the anchor is.
            const said = try lib.comments("/docs/a.pdf");
            defer lib.freeComments(said, said.len);
            try testing.expectEqual(@as(usize, 1), said.len);
            try testing.expectEqualStrings("chec", said[0].text);
            try testing.expectEqualStrings(r.anchor, said[0].anchor);
            try testing.expectEqualStrings(r.anchor, said[0].nm);
        }
        try testing.expect(found);
    }

    // Delete it: focus moves on to the other one, and the row goes, and
    // the comment with it, since it was the anchor's only line.
    _ = s.apply(.delete_mark);
    applyEffects(&s);
    try testing.expectEqual(@as(usize, 1), marks.count());
    try testing.expect(s.focus_mark != null);
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 1), rows.len);
        const said = try lib.comments("/docs/a.pdf");
        defer lib.freeComments(said, said.len);
        try testing.expectEqual(@as(usize, 0), said.len);
    }

    // Undo the deletion: a row again, with its colour and its comment.
    _ = s.apply(.undo);
    applyEffects(&s);
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 2), rows.len);
        const said = try lib.comments("/docs/a.pdf");
        defer lib.freeComments(said, said.len);
        try testing.expectEqual(@as(usize, 1), said.len);
        try testing.expectEqualStrings("chec", said[0].text);
    }

    // Rubbing the comment out keeps none, rather than an empty one.
    _ = s.apply(.next_mark);
    try testing.expectApproxEqAbs(@as(f32, 600), marks.items()[focusedMarkIndex(&s).?].box.min_y, 0.01);
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    for ("chec") |_| _ = s.apply(.note_backspace);
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    applyEffects(&s);
    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 0), said.len);
}

/// A comment on the anchor of the mark at `index`, as `a` in edit mode
/// would write it.
fn commentOn(marks: *Marks, gpa: Allocator, index: usize, text_: []const u8) !void {
    _ = try marks.addComment(gpa, .{ .anchor = marks.items()[index].anchor, .text = text_ }, false);
}

test "edit mode on a document with no highlights says so and stays in normal" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expect(s.status.len != 0);
}

test "]a and ]c walk the marks from where the reader is, and come round again" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    // Nothing to go to says so, rather than doing nothing.
    _ = s.apply(.{ .jump_mark = .{ .forwards = true } });
    try testing.expect(s.status.len != 0);
    try testing.expect(s.last_jump == null);

    // These pages have no text, so the caret never moves: the case a stroke
    // of ink is, and the one a jump from the caret alone would get stuck on.
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 300, 200, 312) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 1, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    var top: u64 = 0;
    var mid: u64 = 0;
    var p1: u64 = 0;
    for (marks.items()) |m| {
        if (m.page == 1) p1 = m.key else if (m.box.min_y > 600) top = m.key else mid = m.key;
    }
    try commentOn(marks, gpa, marks.indexOf(mid).?, "why?");

    // From the top of the page in front of the window, in reading order.
    const next: keys.Command = .{ .jump_mark = .{ .forwards = true } };
    _ = s.apply(next);
    try testing.expectEqual(top, s.last_jump.?.key);
    _ = s.apply(next);
    try testing.expectEqual(mid, s.last_jump.?.key);
    _ = s.apply(next);
    try testing.expectEqual(p1, s.last_jump.?.key);
    // Past the last it comes round, and the status line says it did.
    _ = s.apply(next);
    try testing.expectEqual(top, s.last_jump.?.key);
    try testing.expect(std.mem.indexOf(u8, s.status, "from the top") != null);
    // Normal mode lands on a mark without taking hold of it.
    try testing.expect(s.focus_mark == null);

    // A comment passes over the marks with none, and reads the comment out.
    _ = s.apply(.{ .jump_mark = .{ .forwards = true, .comments = true } });
    try testing.expectEqual(mid, s.last_jump.?.key);
    try testing.expect(std.mem.endsWith(u8, s.status, "why?"));
    _ = s.apply(.{ .jump_mark = .{ .forwards = false, .comments = true } });
    try testing.expectEqual(mid, s.last_jump.?.key);

    // In edit mode the jump moves the highlight in hand, and the : line
    // reaches the same place the keys do.
    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    const held = s.focus_mark.?;
    try testing.expect(s.exec("mprevious"));
    try testing.expect(s.focus_mark.? != held);
    try testing.expectEqual(s.last_jump.?.key, s.focus_mark.?);
}

test "]a walks what :filter lets the panel show, and the rows are those" {
    if (!caps.panels) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 600, 200, 612) }}, Library.parseColor("green").?);
    highlightBoxes(&s, 0, &.{.{ .page = 1, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    try commentOn(marks, gpa, 0, "#question one");
    try commentOn(marks, gpa, 2, "a #question too");

    try testing.expect(s.exec("filter #question"));
    try testing.expectEqualStrings("2 of 3 marks match", s.status);
    try testing.expectEqual(@as(usize, 2), interface.panelRows(&s, .annotations).len);

    // Over the green one, which the panel does not show.
    _ = s.apply(.{ .jump_mark = .{ .forwards = true } });
    try testing.expectEqual(marks.items()[0].key, s.last_jump.?.key);
    _ = s.apply(.{ .jump_mark = .{ .forwards = true } });
    try testing.expectEqual(marks.items()[2].key, s.last_jump.?.key);
    try testing.expect(std.mem.indexOf(u8, s.status, "that match") != null);

    // A colour by its swatch's name; then nothing, which is everything.
    try testing.expect(s.exec("filter green"));
    try testing.expectEqual(@as(usize, 1), interface.panelRows(&s, .annotations).len);
    try testing.expect(s.exec("filter"));
    try testing.expectEqual(@as(usize, 3), interface.panelRows(&s, .annotations).len);
}

// The author asked for edit mode to walk the filter as `]a` does. `n` and `N`
// stepping every mark while the panel shows a few is what this pins.
test "edit mode's i, n, N and d walk what the filter lets through" {
    if (!caps.panels) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    // A question, a plain one, and another question, down the page.
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 600, 200, 612) }}, s.accent);
    highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    try commentOn(marks, gpa, 0, "#question one");
    try commentOn(marks, gpa, 2, "#question two");
    const one = marks.items()[0].key;
    const plain = marks.items()[1].key;
    const two = marks.items()[2].key;
    try testing.expect(s.exec("filter #question"));

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqual(one, s.focus_mark.?);
    try testing.expectEqualStrings("-- EDIT -- 1/2", s.statusLine().mode);

    // Over the plain one, both ways.
    _ = s.apply(.next_mark);
    try testing.expectEqual(two, s.focus_mark.?);
    try testing.expectEqualStrings("-- EDIT -- 2/2", s.statusLine().mode);
    _ = s.apply(.previous_mark);
    try testing.expectEqual(one, s.focus_mark.?);

    // A click can still take hold of the plain one, which is then counted
    // among them all.
    s.focus_mark = plain;
    try testing.expectEqualStrings("-- EDIT -- 2/3", s.statusLine().mode);

    // `d` goes on to the next question, and after the last stops, leaving
    // the plain one where it was.
    s.focus_mark = one;
    _ = s.apply(.delete_mark);
    try testing.expectEqual(two, s.focus_mark.?);
    _ = s.apply(.delete_mark);
    try testing.expect(s.focus_mark == null);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expectEqual(@as(usize, 1), marks.count());
    try testing.expectEqual(plain, marks.items()[0].key);

    // And `i` with nothing to match does not take hold of what is left.
    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expect(std.mem.startsWith(u8, s.status, "nothing matches"));
}

test "backspace in a note removes a character, not a byte" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    noteChar(&s, 'a');
    noteChar(&s, 0xe9); // two bytes in UTF-8
    noteBackspace(&s);
    try testing.expectEqualStrings("a", s.note.items);
}

test "the cursor's line can be highlighted and cleared again" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{
        .code = 'a',
        .offset = .{ .x = 10 * @as(f32, @floatFromInt(i)), .y = 0 },
    };
    var cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700),
        .glyphs = .{ .start = 0, .count = 3 },
    } };
    const map = try text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    s.buffer(0).putMap(gpa, 0, map);

    s.view().cursorToPage(0, s.buffer(0).textMap(0).?, false);
    toggleMark(&s);
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());

    // Again on the same line: the cursor is inside the mark it just made, so
    // this takes it away rather than stacking a second one on top.
    toggleMark(&s);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "highlights come back out of the library the next time it is opened" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;

    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    s.ctx = undefined;

    // Written through the session, so the row and the in-memory mark are
    // made by the same call a keypress would make.
    _ = try lib.addMark(s.buffer(0).path, .{
        .page = 2,
        .x0 = 100,
        .y0 = 700,
        .x1 = 300,
        .y1 = 712,
        .color = @constCast("#ff0000"),
    }, 1);

    var reopened = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&reopened);
    reopened.library = lib;
    loadMarks(&reopened, 0);

    try testing.expectEqual(@as(usize, 1), reopened.buffer(0).marks.count());
    const mark = reopened.buffer(0).marks.items()[0];
    try testing.expectEqual(@as(u32, 2), mark.page);
    try testing.expectApproxEqAbs(@as(f32, 1), mark.color.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), mark.color.g, 0.01);
    // Loading is not an edit, so closing again writes nothing back.
    try testing.expect(!reopened.buffer(0).marks.dirty);
}

test "a comment typed on a stroke is written to the library and comes back" {
    // A stroke is focusable, so `note` mode accepts a comment on one -- and
    // the ink arm of the writer was once `updateStroke(id, colour)`, with no
    // column behind it, so what was typed lived for the session and was gone
    // at the next open. A stroke is an anchor like any mark, and its comment
    // is a row like any other; do not let ink fall out of that again.
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;

    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);

    // Drawn with the pen, so the mark and its row are made by the calls a
    // drag makes.
    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 100, .y = 700 }).?, .buttons = .{ .left = true } });
    var x: f32 = 110;
    while (x <= 300) : (x += 10) {
        s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = x, .y = 700 }).?, .buttons = .{ .left = true } });
    }
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 300, .y = 700 }).?, .buttons = .{} });
    applyEffects(&s);
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expect(focusedMarkIndex(&s) != null);
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    for ("the margin") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    applyEffects(&s);

    {
        const rows = try lib.strokes(s.buffer(0).path);
        defer lib.freeStrokes(rows, rows.len);
        try testing.expectEqual(@as(usize, 1), rows.len);
        const said = try lib.comments(s.buffer(0).path);
        defer lib.freeComments(said, said.len);
        try testing.expectEqual(@as(usize, 1), said.len);
        try testing.expectEqualStrings(rows[0].anchor, said[0].anchor);
        try testing.expectEqualStrings("the margin", said[0].text);
    }

    // And the next open has it.
    var reopened = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&reopened);
    reopened.library = lib;
    loadMarks(&reopened, 0);

    const marks = reopened.buffer(0).marks.items();
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqual(Marks.Kind.ink, marks[0].kind);
    try testing.expectEqualStrings("the margin", firstComment(reopened.buffer(0), marks[0]));
}

test "comment_anchor = arrow makes c point at the words, kept and read back" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    try putText(&s, 0, 3, 4);

    // Refused by name, so a misspelling is not a highlight by default.
    try testing.expect(!s.exec("set comment_anchor=arow"));
    try testing.expect(s.exec("set comment_anchor=arrow"));
    try testing.expectEqual(Marks.Style.arrow, s.comment_style);

    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .down });
    s.keymap.mode = .note;
    _ = s.apply(.comment_selection);
    for ("see") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    applyEffects(&s);
    for (s.buffer(0).marks.items()) |m| try testing.expectEqual(Marks.Style.arrow, m.style);
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqualStrings("arrow", rows[0].style);
    }

    // The next reader opens with it.
    var again = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&again);
    try giveLibrary(&again, lib);
    try testing.expectEqual(Marks.Style.arrow, rememberedCommentStyle(&again));
}

test "an arrow sits in the margin, its tip short of the words" {
    const gpa = testing.allocator;
    const line: Bounds = .fromRect(100, 200, 400, 220);
    var d: DrawList = .init(gpa, .fromRect(0, 0, 1000, 1000));
    defer d.deinit();
    // A mark begun mid-line, on a line whose words begin at 60.
    try arrow(&d, line, 60, .{ .r = 1, .g = 0.9, .b = 0.2, .a = 1 });

    var ink: Bounds = .empty;
    for (d.instances.items) |i| ink = ink.add(.{ .x = i.dst[0], .y = i.dst[1] }).add(.{ .x = i.dst[2], .y = i.dst[3] });
    // Nothing on the text, the line's earlier words included, and nothing
    // taller than the line it points at.
    try testing.expect(ink.max_x <= 60);
    try testing.expect(ink.min_y >= line.min_y and ink.max_y <= line.max_y);
    // A shaft and ten slices of head, for a line twenty tall.
    try testing.expectEqual(@as(usize, 11), d.instances.items.len);
}
