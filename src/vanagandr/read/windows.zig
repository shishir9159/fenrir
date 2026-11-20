//! The windows and what is in them: a split made, closed and dragged,
//! tabpages and the bar that names them, and which open document a window
//! is showing.
//!
//! The arrangement is `hlidskjalf.Layout` and `Tabs`; this is the reader's
//! side of it. A file of its own so that all of it is in one place, and so
//! that a build with one window on one document can leave the file out.

const std = @import("std");
const fenrir = @import("fenrir");

const chrome_mod = @import("../chrome.zig");
const Session = @import("Session.zig");
const selection = @import("selection.zig");

const hlidskjalf = fenrir.hlidskjalf;
const lyngvi = fenrir.lyngvi;
const thviti = fenrir.thviti;

const Layout = hlidskjalf.Layout;
const View = hlidskjalf.View;

/// Points the focused window at another open document. `<C-w>n`.
pub fn showBuffer(s: *Session, delta: i32) void {
    if (s.buffers.items.len < 2) return;
    const v = s.view();
    const n: i32 = @intCast(s.buffers.items.len);
    const next: u32 = @intCast(@mod(@as(i32, @intCast(v.buffer)) + delta + n, n));
    if (next == v.buffer) return;

    // Where this window was in the old document is worth keeping: coming
    // back to it with `<C-w>b` should not have lost your place.
    s.rememberPlace(v);

    v.buffer = next;
    v.pages = s.buffer(next).pages;
    v.cursor = .{};
    v.scroll = 0;
    v.pan = 0;
    _ = s.restore(v, next, false, true);
    v.clampScroll();
    s.dirty_title = true;
}

// -- splits ------------------------------------------------------------------

/// How far either side of the line a press still counts as taking hold
/// of it. The line is two pixels; nobody can hit two pixels.
const divider_slack: f32 = 4;

/// The line between two windows, taken hold of and moved. True when the
/// gesture belongs to a divider, and nothing below should see it.
///
/// The divider is remembered for the whole drag rather than looked up
/// each frame, because the pointer runs ahead of the line the moment it
/// reaches a window's minimum -- and a lookup would then find nothing and
/// drop the gesture just as someone leans into it.
pub fn dragSplit(s: *Session, in: lyngvi.Input, down: bool, pressed: bool) bool {
    if (down and pressed and s.split_drag == null) {
        s.split_drag = s.layout().dividerAt(in.mouse, divider_slack);
    }
    const d = s.split_drag orelse return false;

    if (down) {
        s.layout().moveDivider(d, if (d.dir == .vertical) in.mouse.x else in.mouse.y);
    } else {
        s.split_drag = null;
    }

    // Everything below the early return is skipped, and that includes the
    // button bookkeeping `dragScrollbar` does. Without this the release
    // that ends a drag still looks like a press on the frame after it,
    // and the next press anywhere is swallowed.
    s.view().was_down = down;
    return true;
}

pub fn splitWindow(s: *Session, dir: Layout.Direction) void {
    // A split copies the window, and a copied selection would be two
    // windows each claiming to be selecting.
    selection.clearSelection(s);
    if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;

    const made = s.layout().split(s.gpa, dir) catch null;
    if (made == null) {
        s.status = "no room to split";
        return;
    }
    s.placed = null;
}

/// Closes the focused window. False when it was the last one anywhere,
/// which the caller turns into a quit.
///
/// The last window of a tabpage closes the tabpage, as `:q` does in Vim:
/// a tabpage with no windows in it is not a thing, so the only question
/// is whether there is another tabpage to fall back to.
pub fn closeWindow(s: *Session) bool {
    if (s.layout().count() < 2) return closeTab(s);
    s.rememberPlace(s.view());
    _ = s.layout().close(s.gpa);
    s.placed = null;
    return true;
}

/// `--split vh`: the splits a scripted shot asked for.
pub fn applySplits(s: *Session, spec: []const u8) void {
    for (spec) |c| {
        splitWindow(s, if (c == 'v') .vertical else .horizontal);
    }
}

// -- tabpages ----------------------------------------------------------------

/// A tabpage of one window, looking at whatever this one is. `:tabnew`.
///
/// Looking at the same document, and not at nothing: a reader opens a tab
/// to keep an arrangement, not to be handed an empty one. `<C-w>n` in the
/// new tab is what moves it to another buffer, exactly as it would in a
/// split.
pub fn newTab(s: *Session) void {
    const copy = leavingTab(s);
    _ = s.tabs.open(s.gpa, copy) catch {
        s.say("no memory for another tabpage", .{});
        return;
    };
    enteredTab(s);
}

/// Closes the tabpage on screen. False when it is the only one, which
/// `closeWindow` turns into a quit and `:tabclose` reports.
pub fn closeTab(s: *Session) bool {
    if (s.tabs.count() < 2) return false;

    // Every window in it, not only the focused one: the whole
    // arrangement is going, and each was somewhere in a document.
    var it = s.layout().iterator();
    while (it.next()) |v| s.rememberPlace(v);

    selection.clearSelection(s);
    if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;
    _ = s.tabs.close(s.gpa);
    enteredTab(s);
    return true;
}

/// `gt` and `gT`.
pub fn goTab(s: *Session, delta: i32) void {
    if (s.tabs.count() < 2) return;
    _ = leavingTab(s);
    s.tabs.go(delta);
    enteredTab(s);
}

/// A tabpage by number, from zero. What `:tabnext 2` and a click on the
/// bar both go through.
pub fn showTab(s: *Session, index: u32) void {
    if (index >= s.tabs.count() or index == s.tabs.active) return;
    _ = leavingTab(s);
    s.tabs.show(index);
    enteredTab(s);
}

/// The focused window, moved into a tabpage of its own. `<C-w>T`.
pub fn windowToTab(s: *Session) void {
    if (s.layout().count() < 2) {
        s.say("this window is the whole tabpage already", .{});
        return;
    }
    _ = leavingTab(s);
    _ = s.tabs.moveToNewTab(s.gpa) catch {
        s.say("no memory for another tabpage", .{});
        return;
    };
    enteredTab(s);
}

/// Everything that has to happen before this tabpage stops being the one
/// on screen, and a copy of the window that was focused in it.
///
/// A selection belongs to the window it was dragged in, and a window on
/// another tabpage is one nobody can see the selection in -- so it goes,
/// the way a split's does and for the same reason.
fn leavingTab(s: *Session) View {
    const copy = s.view().*;
    selection.clearSelection(s);
    if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;
    s.rememberPlace(s.view());
    return copy;
}

/// And after: the pages on the device belong to whichever windows are
/// showing, and which those are has just changed.
fn enteredTab(s: *Session) void {
    s.placed = null;
    s.dirty_title = true;
}

/// How much of the window the tab bar takes off the top.
///
/// Zero for a single tabpage, which is every session until somebody opens
/// a second one: a bar showing one tab says what the title bar says and
/// costs a row of the page to say it. Asked here rather than of the
/// chrome because `windowRect` needs the answer before the chrome for
/// this frame has been built.
pub fn tabInset(s: *const Session) f32 {
    return if (s.tabs.count() > 1) chrome_mod.tab_height else 0;
}

/// What is written on each tab: the document its focused window is
/// looking at, and how many windows are in it when there is more than
/// one.
///
/// The count is on the tab because it is the one thing that distinguishes
/// two tabs on the same document, which is the normal way a second tab
/// begins -- `:tabnew` opens on what you were reading.
pub fn tabLabels(s: *Session) []const []const u8 {
    const stamp = tabsKey(s);
    if (stamp == s.tabs_for) return s.tab_names.items;
    s.tabs_for = stamp;

    s.tab_text.clearRetainingCapacity();
    s.tab_ends.clearRetainingCapacity();
    s.tab_names.clearRetainingCapacity();

    var i: u32 = 0;
    while (i < s.tabs.count()) : (i += 1) {
        const l = s.tabs.at(i);
        const title = s.buffer(l.current().buffer).title;
        // Through a buffer rather than a writer over the list: the name
        // is a basename and a number, and a fixed print cannot fail on
        // anything but a pathological title -- which then keeps its own
        // name and loses only the count.
        var buf: [192]u8 = undefined;
        const name = if (l.count() > 1)
            std.fmt.bufPrint(&buf, "{s} ({d})", .{ title[0..@min(title.len, 160)], l.count() }) catch title
        else
            title;
        s.tab_text.appendSlice(s.gpa, name) catch break;
        s.tab_ends.append(s.gpa, @intCast(s.tab_text.items.len)) catch break;
    }

    // The slices last, once the bytes have stopped moving.
    var from: u32 = 0;
    for (s.tab_ends.items) |to| {
        s.tab_names.append(s.gpa, s.tab_text.items[from..to]) catch break;
        from = to;
    }
    return s.tab_names.items;
}

/// Everything the bar would draw differently, hashed. Compared rather
/// than invalidated by hand, for the reason `placementKey` is: a flag set
/// in every place that opens, closes or retitles a tab is a flag that
/// will be forgotten in one of them.
fn tabsKey(s: *Session) u64 {
    var h: u64 = 1469598103934665603;
    const mix = struct {
        fn go(acc: *u64, value: u64) void {
            acc.* = (acc.* ^ value) *% 1099511628211;
        }
    }.go;

    mix(&h, s.tabs.count());
    mix(&h, s.tabs.active);
    var i: u32 = 0;
    while (i < s.tabs.count()) : (i += 1) {
        const l = s.tabs.at(i);
        mix(&h, l.current().buffer);
        mix(&h, l.count());
    }
    return h;
}

/// What the tab bar was asked for, carried out.
///
/// A tab closed by its cross is shown first and closed after, so that
/// closing one is the same act as clicking it and typing `:tabclose` --
/// one path through the session, and the windows in it get their places
/// written down on the way out either way.
pub fn applyTabs(s: *Session, r: thviti.widgets.tabs.Result) void {
    if (r.activated) |i| showTab(s, i);
    if (r.closed) |i| {
        showTab(s, i);
        _ = closeTab(s);
    }
    if (r.added) newTab(s);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const frame = @import("frame.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const sessionOf = fixtures.sessionOf;

test "a split is two windows on one document, scrolling apart" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    splitWindow(&s, .vertical);
    try testing.expectEqual(@as(u32, 2), s.layout().count());

    // Both are looking at the same buffer...
    var it = s.layout().iterator();
    while (it.next()) |v| try testing.expectEqual(@as(u32, 0), v.buffer);

    // ...and scrolling one does not move the other, which is the whole point
    // of the scroll living in the view.
    s.view().scroll = 500;
    var others: u32 = 0;
    var walk = s.layout().iterator();
    while (walk.next()) |v| {
        if (v != s.layout().current() and v.scroll != 500) others += 1;
    }
    try testing.expectEqual(@as(u32, 1), others);
}

test "closing the last window is a quit, and closing others is not" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(!closeWindow(&s));
    splitWindow(&s, .vertical);
    try testing.expect(closeWindow(&s));
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    try testing.expect(!closeWindow(&s));
}

test "showing another document in a window keeps the place in the first" {
    const gpa = testing.allocator;
    var buf: [20]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    try s.buffers.append(gpa, .{
        .path = try gpa.dupe(u8, "/docs/b.pdf"),
        .title = "b.pdf",
        .pages = fakePages(buf[10..], 6),
    });

    s.view().scrollToPage(5);
    const was = s.view().scroll;

    showBuffer(&s, 1);
    try testing.expectEqual(@as(u32, 1), s.view().buffer);
    try testing.expectEqual(@as(usize, 6), s.view().pages.len);
    try testing.expectApproxEqAbs(@as(f32, 0), s.view().scroll, 0.001);

    // And back, which without a library does not restore the place -- so the
    // test asserts what it can: the pages are the first document's again.
    showBuffer(&s, -1);
    try testing.expectEqual(@as(u32, 0), s.view().buffer);
    try testing.expectEqual(@as(usize, 10), s.view().pages.len);
    try testing.expect(was > 0);
}

test "dragging the line between two windows resizes both of them" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    splitWindow(&s, .vertical);
    const left = s.layout().viewAt(0);
    const line = left.rect.max_x;

    // A press on the line, then a drag well to the left of it.
    s.pointer(.{ .mouse = .{ .x = line + 1, .y = 400 }, .buttons = .{ .left = true } });
    try testing.expect(s.split_drag != null);
    s.pointer(.{ .mouse = .{ .x = 300, .y = 400 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 300), left.rect.max_x, 1e-3);

    // Letting go ends it, and the gesture never became a text selection.
    s.pointer(.{ .mouse = .{ .x = 300, .y = 400 } });
    try testing.expect(s.split_drag == null);
    try testing.expect(s.drag == null);

    // A press away from the line is not a drag on it, and the next press
    // after a divider drag still registers.
    s.pointer(.{ .mouse = .{ .x = 150, .y = 400 }, .buttons = .{ .left = true } });
    try testing.expect(s.split_drag == null);
    try testing.expectApproxEqAbs(@as(f32, 300), left.rect.max_x, 1e-3);
}

test "a tabpage keeps its own windows, and gt goes between them" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    s.view().scroll = 300;
    _ = s.apply(.{ .split = .vertical });
    _ = s.apply(.new_tab);

    try testing.expectEqual(@as(u32, 2), s.tabs.count());
    // The new tabpage is one window on the same document, where that window
    // was: a tab is an arrangement, not a second file.
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    try testing.expectEqual(@as(u32, 0), s.view().buffer);
    try testing.expectApproxEqAbs(@as(f32, 300), s.view().scroll, 0.001);

    s.view().scroll = 0;
    _ = s.apply(.{ .go_tab = 1 });
    try testing.expectEqual(@as(u32, 2), s.layout().count());
    try testing.expectApproxEqAbs(@as(f32, 300), s.view().scroll, 0.001);
}

test "the last window of a tabpage closes the tabpage, not the reader" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.new_tab);
    try testing.expectEqual(@as(u32, 2), s.tabs.count());

    // `q` in a tab of one window: the tab goes and the reader stays.
    try testing.expect(!s.apply(.quit));
    try testing.expectEqual(@as(u32, 1), s.tabs.count());

    // And on the last window of the last tabpage it is a quit again.
    try testing.expect(s.apply(.quit));
}

test "a window moved to its own tabpage is one window in each" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    // Nothing to move: one window is a tabpage already, and the reader says
    // so rather than making an identical tab beside it.
    _ = s.apply(.window_to_tab);
    try testing.expectEqual(@as(u32, 1), s.tabs.count());

    _ = s.apply(.{ .split = .horizontal });
    _ = s.apply(.window_to_tab);
    try testing.expectEqual(@as(u32, 2), s.tabs.count());
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    _ = s.apply(.{ .go_tab = -1 });
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    // The window left behind took the whole rectangle back.
    try testing.expectApproxEqAbs(@as(f32, 800), s.view().rect.height(), 0.001);
}

test "the tab commands on the : line reach the same places the keys do" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(s.exec("tabnew"));
    try testing.expect(s.exec("tabnew"));
    try testing.expectEqual(@as(u32, 3), s.tabs.count());

    try testing.expect(s.exec("tabnext 1"));
    try testing.expectEqual(@as(u32, 0), s.tabs.active);
    try testing.expect(!s.exec("tabnext 9"));
    try testing.expectEqual(@as(u32, 0), s.tabs.active);
    try testing.expect(s.exec("tabprevious"));
    try testing.expectEqual(@as(u32, 2), s.tabs.active);

    try testing.expect(s.exec("tabonly"));
    try testing.expectEqual(@as(u32, 1), s.tabs.count());
    // And the only tabpage will not close: leaving is `:q`'s job.
    try testing.expect(!s.exec("tabclose"));
}

test "a tab is named for its document, and says how many windows are in it" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.new_tab);
    _ = s.apply(.{ .split = .vertical });
    _ = s.apply(.{ .split = .horizontal });

    const names = tabLabels(&s);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a.pdf", names[0]);
    try testing.expectEqualStrings("a.pdf (3)", names[1]);

    // Nothing the bar would draw has changed, so nothing is rebuilt: the
    // slices are the same bytes, not equal copies of them.
    const again = tabLabels(&s);
    try testing.expectEqual(names.ptr, again.ptr);
    try testing.expectEqual(names[1].ptr, again[1].ptr);

    // A window closed is a different bar, and the name follows it.
    _ = s.apply(.close_window);
    try testing.expectEqualStrings("a.pdf (2)", tabLabels(&s)[1]);
}

test "the bar takes a row off the pages, and only once there are two tabs" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    // One tabpage: a bar showing one tab would say what the title bar says,
    // so there is no bar and the page keeps the row.
    try testing.expectEqual(@as(f32, 0), tabInset(&s));
    _ = s.apply(.new_tab);
    try testing.expectEqual(chrome_mod.tab_height, tabInset(&s));
    _ = s.apply(.close_tab);
    try testing.expectEqual(@as(f32, 0), tabInset(&s));

    // And with no interface at all -- a test, and `--shot --path cpu` --
    // the windows get the whole thing however many tabpages there are.
    _ = s.apply(.new_tab);
    try testing.expectEqual(@as(f32, 0), frame.windowRect(&s, 1000, 800).min_y);
}
