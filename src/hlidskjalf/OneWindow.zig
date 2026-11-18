//! One window onto one document, for a build with no splits and no tabpages.
//!
//! `Tabs` and `Layout` answer three questions for a reader that may have any
//! number of windows: which one is focused, where each one is, and every one
//! of them in turn. A reader that has one window asks the same three, and
//! each answer is a field. This is those answers, spelled the way `Tabs` and
//! `Layout` spell them -- `current`, `count`, `iterator`, `arrange` -- so the
//! session reads the same in either build and carries the code its own build
//! needs and no more: no tree to walk to find the focused view, and no list
//! of tabpages to find the tree in.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");
const View = @import("View.zig");

const Bounds = gelgja.Bounds;

const OneWindow = @This();

view: View = .{},

/// Starts with its window. The allocator is taken because `Tabs.init` takes
/// one, so the session starts either the same way; one window is a field,
/// and there is nothing to allocate.
pub fn init(w: *OneWindow, gpa: Allocator, first: View) Allocator.Error!void {
    _ = gpa;
    w.view = first;
}

pub fn deinit(w: *OneWindow, gpa: Allocator) void {
    _ = gpa;
    w.* = .{};
}

/// The window, which is the focused one because it is the only one.
pub fn current(w: *OneWindow) *View {
    return &w.view;
}

pub fn count(w: OneWindow) u32 {
    _ = w;
    return 1;
}

/// The window, once.
pub const Iterator = struct {
    w: *OneWindow,
    done: bool = false,

    pub fn next(it: *Iterator) ?*View {
        if (it.done) return null;
        it.done = true;
        return &it.w.view;
    }
};

pub fn iterator(w: *OneWindow) Iterator {
    return .{ .w = w };
}

/// Gives the window the rectangle the chrome left, as `Layout.arrange` gives
/// each of its leaves theirs.
pub fn arrange(w: *OneWindow, rect: Bounds) void {
    w.view.arrange(rect);
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

test "one window is every window, and the focused one" {
    var buf: [4]fenrir.Page = undefined;
    var w: OneWindow = .{};
    try w.init(testing.allocator, .{ .pages = fakePages(&buf, 3), .zoom = 1 });
    defer w.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), w.count());
    var it = w.iterator();
    try testing.expectEqual(w.current(), it.next().?);
    try testing.expect(it.next() == null);
}

test "the window refits when its size changes, and only then" {
    var buf: [4]fenrir.Page = undefined;
    var w: OneWindow = .{};
    try w.init(testing.allocator, .{ .pages = fakePages(&buf, 3), .zoom = 1 });
    defer w.deinit(testing.allocator);

    w.current().fitTo(.width);
    w.arrange(.fromRect(0, 0, 1000, 800));
    const fitted = w.current().zoom;
    try testing.expectApproxEqAbs((1000 - View.gap * 2) / 600.0, fitted, 1e-4);

    // The same rectangle again, as every frame hands it over: the zoom is
    // left exactly where it was, scroll and all.
    w.current().scroll = 300;
    w.arrange(.fromRect(0, 0, 1000, 800));
    try testing.expectEqual(fitted, w.current().zoom);
    try testing.expectEqual(@as(f32, 300), w.current().scroll);

    w.arrange(.fromRect(0, 0, 500, 800));
    try testing.expect(w.current().zoom < fitted);
}
