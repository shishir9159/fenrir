//! Tab pages: several split trees, one of them on screen.
//!
//! Vim's model again, and for the same reason `Layout` is Vim's: a tabpage is
//! not a document and it is not a window, it is *an arrangement of windows*
//! somebody wants to keep while they go and look at a different one. Two
//! papers open side by side, and a third read whole, are three layouts and
//! one set of buffers -- which is exactly what this is, because the buffers
//! belong to the session and a `Layout` owns only views onto them.
//!
//! ## Why the layouts are a list and not a tree
//!
//! Because nothing divides a tabpage. A window has to give its space back to
//! a neighbour when it closes, which is what made `Layout` a tree; a tabpage
//! has the whole rectangle, so closing one is "show another" and the answer
//! is an index, not a structure.
//!
//! ## The rectangle is remembered here
//!
//! `arrange` is called once a frame with whatever the chrome left over, and
//! it lays out only the tab on screen -- laying out three trees to draw one
//! is work per frame that can be done on change. The rectangle is kept so
//! that a tab *becoming* active can be given it at once: without that, the
//! frame after `gt` would draw the new tab at whatever size it was when it
//! was last looked at, which for a tab made while the window was another size
//! is visibly wrong for one frame.
//!
//! ## What a closed tab takes with it
//!
//! Its views, and nothing else. The buffers stay open -- `:tabclose` on the
//! last window onto a document does not close the document, in this reader or
//! in Vim -- so the session's list is untouched and a `:tabnew` can point
//! straight back at it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");
const Layout = @import("Layout.zig");
const View = @import("View.zig");

const Bounds = gelgja.Bounds;

const Tabs = @This();

/// The tabpages, in the order they are shown and cycled. Never empty while a
/// session is open: closing the last one is a quit, and the caller's decision
/// rather than this one's, exactly as `Layout.close` leaves it.
pages: std.ArrayList(Layout) = .empty,
/// Which one is on screen. Always a valid index into `pages`.
active: u32 = 0,

/// The rectangle the windows were last given. See the note above.
rect: Bounds = .fromRect(0, 0, 1, 1),

pub fn deinit(t: *Tabs, gpa: Allocator) void {
    for (t.pages.items) |*l| l.deinit(gpa);
    t.pages.deinit(gpa);
    t.* = .{};
}

/// Starts with one tabpage of one window.
pub fn init(t: *Tabs, gpa: Allocator, first: View) Allocator.Error!void {
    try t.pages.append(gpa, .{});
    errdefer _ = t.pages.pop();
    try t.pages.items[0].init(gpa, first);
    t.active = 0;
}

// -- asking about them --------------------------------------------------------

/// The tabpage on screen, which always exists.
pub fn current(t: *Tabs) *Layout {
    return &t.pages.items[t.active];
}

pub fn at(t: *Tabs, index: u32) *Layout {
    return &t.pages.items[index];
}

pub fn count(t: Tabs) u32 {
    return @intCast(t.pages.items.len);
}

/// Every view in every tabpage, including the ones nobody is looking at.
///
/// For the things that are about the session rather than about the frame:
/// writing down where each window was left, and asking whether a page any
/// window holds is still wanted. Drawing and rasterising use
/// `current().iterator()` instead, because a tab that is not on screen has
/// nothing to draw and no reason to be rendered ahead.
pub const Iterator = struct {
    t: *Tabs,
    page: u32 = 0,
    inner: ?Layout.Iterator = null,

    pub fn next(it: *Iterator) ?*View {
        while (true) {
            if (it.inner) |*inner| {
                if (inner.next()) |v| return v;
                it.inner = null;
                it.page += 1;
            }
            if (it.page >= it.t.pages.items.len) return null;
            it.inner = it.t.pages.items[it.page].iterator();
        }
    }
};

pub fn iterator(t: *Tabs) Iterator {
    return .{ .t = t };
}

// -- changing them ------------------------------------------------------------

/// Opens a tabpage holding one window on `v`, after the active one, and
/// shows it. `:tabnew`.
///
/// After rather than at the end, because that is where Vim puts it and
/// because it is the answer that keeps `gT` meaning "back to what I was just
/// reading" -- a tab opened at the far end of the bar would leave the tab it
/// came from a keystroke further away the more tabs there were.
pub fn open(t: *Tabs, gpa: Allocator, v: View) Allocator.Error!u32 {
    const at_index = t.active + 1;
    try t.pages.insert(gpa, at_index, .{});
    errdefer _ = t.pages.orderedRemove(at_index);

    try t.pages.items[at_index].init(gpa, v);
    t.active = at_index;
    t.current().arrange(t.rect);
    return at_index;
}

/// Closes the tabpage on screen and shows its neighbour. False when it is the
/// last one, which is a request to quit and the caller's to decide.
///
/// The neighbour is the one to the right, as in Vim, falling back to the left
/// at the end of the bar -- so closing several in a row walks along rather
/// than jumping to the beginning.
pub fn close(t: *Tabs, gpa: Allocator) bool {
    if (t.pages.items.len < 2) return false;

    var gone = t.pages.orderedRemove(t.active);
    gone.deinit(gpa);

    if (t.active >= t.pages.items.len) t.active = @intCast(t.pages.items.len - 1);
    t.current().arrange(t.rect);
    return true;
}

/// Closes every tabpage but the one on screen. `:tabonly`.
pub fn only(t: *Tabs, gpa: Allocator) void {
    if (t.pages.items.len < 2) return;

    for (t.pages.items, 0..) |*l, i| {
        if (i != t.active) l.deinit(gpa);
    }
    // Moved down rather than cleared and re-appended: this way there is no
    // allocation to fail on the path that is giving memory back.
    t.pages.items[0] = t.pages.items[t.active];
    t.pages.shrinkRetainingCapacity(1);
    t.active = 0;
}

/// Moves the focused window into a tabpage of its own, closing it where it
/// was. `<C-w>T`.
///
/// Nothing happens when it is the only window in its tab: that is already a
/// tabpage holding one window, and Vim refuses it for the same reason. The
/// view is copied *before* the close, because closing frees its slot and the
/// next `init` is entitled to reuse it.
pub fn moveToNewTab(t: *Tabs, gpa: Allocator) Allocator.Error!bool {
    if (t.current().count() < 2) return false;

    const copy = t.current().current().*;
    _ = t.current().close(gpa);
    _ = try t.open(gpa, copy);
    return true;
}

/// `gt` and `gT`: the next tabpage or the previous one, wrapping.
pub fn go(t: *Tabs, delta: i32) void {
    const n: i32 = @intCast(t.pages.items.len);
    if (n < 2) return;
    t.show(@intCast(@mod(@as(i32, @intCast(t.active)) + delta, n)));
}

/// A tabpage by number, ignoring one that is not there. What `:tabnext 2` and
/// a click on the bar both go through.
pub fn show(t: *Tabs, index: u32) void {
    if (index >= t.pages.items.len or index == t.active) return;
    t.active = index;
    // The tab arriving on screen gets this frame's rectangle rather than the
    // one it had when it left it.
    t.current().arrange(t.rect);
}

// -- geometry -----------------------------------------------------------------

/// Gives the tabpage on screen its rectangle, and remembers it for whichever
/// one arrives next.
pub fn arrange(t: *Tabs, rect: Bounds) void {
    t.rect = rect;
    t.current().arrange(rect);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;
const fenrir = @import("../root.zig");

fn fakePages(buf: []fenrir.Page, n: usize) []fenrir.Page {
    const letter: fenrir.Page.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 600, .y1 = 800 };
    for (buf[0..n], 0..) |*p, i| p.* = .{
        .index = @intCast(i),
        .ref = .{ .num = 0, .gen = 0 },
        .dict = .empty,
        .resources = .empty,
        .media_box = letter,
        .crop_box = letter,
        .rotate = .none,
    };
    return buf[0..n];
}

fn started(gpa: Allocator, pages: []fenrir.Page) !Tabs {
    var t: Tabs = .{};
    try t.init(gpa, .{ .pages = pages, .zoom = 1 });
    t.arrange(.fromRect(0, 0, 1000, 800));
    return t;
}

test "a fresh session is one tabpage of one window" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), t.count());
    try testing.expectEqual(@as(u32, 1), t.current().count());
    // The last tabpage cannot be closed: that is a quit, and not this
    // module's decision.
    try testing.expect(!t.close(gpa));
}

test "a new tabpage opens after the active one and takes the screen" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    try testing.expectEqual(@as(u32, 3), t.count());
    try testing.expectEqual(@as(u32, 2), t.active);

    // Back to the first, then open: the new one lands between them rather
    // than at the end of the bar.
    t.show(0);
    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    try testing.expectEqual(@as(u32, 1), t.active);
    try testing.expectEqual(@as(u32, 4), t.count());
}

test "a tabpage arrives already the size of the window" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    try testing.expectEqual(@as(f32, 1000), t.current().current().rect.width());

    // The window resizes while the second tab is on screen, and the first one
    // still gets the new size the frame it comes back.
    t.arrange(.fromRect(0, 0, 600, 400));
    t.go(-1);
    try testing.expectEqual(@as(u32, 0), t.active);
    try testing.expectEqual(@as(f32, 600), t.current().current().rect.width());
}

test "each tabpage keeps its own splits and its own scroll" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    _ = try t.current().split(gpa, .vertical);
    t.current().current().scroll = 250;

    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    try testing.expectEqual(@as(u32, 1), t.current().count());
    try testing.expectEqual(@as(f32, 0), t.current().current().scroll);

    t.go(-1);
    try testing.expectEqual(@as(u32, 2), t.current().count());
    try testing.expectEqual(@as(f32, 250), t.current().current().scroll);
}

test "gt and gT wrap, and a single tabpage does not move" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    t.go(1);
    try testing.expectEqual(@as(u32, 0), t.active);

    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    try testing.expectEqual(@as(u32, 2), t.active);
    t.go(1);
    try testing.expectEqual(@as(u32, 0), t.active);
    t.go(-1);
    try testing.expectEqual(@as(u32, 2), t.active);
}

test "closing walks right, and off the end walks left" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    t.show(0);

    try testing.expect(t.close(gpa));
    try testing.expectEqual(@as(u32, 2), t.count());
    try testing.expectEqual(@as(u32, 0), t.active);

    t.show(1);
    try testing.expect(t.close(gpa));
    try testing.expectEqual(@as(u32, 0), t.active);
}

test "a window moved to its own tabpage leaves the one it was in" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    // The only window in the only tab is already a tab of its own.
    try testing.expect(!try t.moveToNewTab(gpa));

    _ = try t.current().split(gpa, .vertical);
    t.current().current().scroll = 120;
    try testing.expect(try t.moveToNewTab(gpa));

    try testing.expectEqual(@as(u32, 2), t.count());
    try testing.expectEqual(@as(u32, 1), t.current().count());
    try testing.expectApproxEqAbs(@as(f32, 120), t.current().current().scroll, 0.001);
    // And the tab it came from is one window again, filling the width.
    t.go(-1);
    try testing.expectEqual(@as(u32, 1), t.current().count());
    try testing.expectEqual(@as(f32, 1000), t.current().current().rect.width());
}

test "tabonly keeps the one on screen and frees the rest" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    _ = try t.current().split(gpa, .horizontal);
    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    t.show(1);

    t.only(gpa);
    try testing.expectEqual(@as(u32, 1), t.count());
    try testing.expectEqual(@as(u32, 0), t.active);
    // The splits inside the kept tab survive; it is the other tabs that go.
    try testing.expectEqual(@as(u32, 2), t.current().count());
}

test "the iterator reaches every window in every tabpage" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var t = try started(gpa, fakePages(&buf, 3));
    defer t.deinit(gpa);

    _ = try t.current().split(gpa, .vertical);
    _ = try t.open(gpa, .{ .pages = t.current().current().pages, .zoom = 1 });
    _ = try t.current().split(gpa, .horizontal);
    _ = try t.current().split(gpa, .horizontal);

    var seen: u32 = 0;
    var it = t.iterator();
    while (it.next()) |_| seen += 1;
    try testing.expectEqual(@as(u32, 5), seen);
}
