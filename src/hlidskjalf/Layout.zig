//! The split tree: which views exist, where each one is, and which has focus.
//!
//! Modelled on Vim's window layout, because that model is correct and forty
//! years of people using it have worked the corners out. A node is either a
//! **leaf** holding one pane, or a **row** or **column** holding children that
//! divide its rectangle. Splitting a leaf turns it into a row or column of
//! two; closing the last child of a node collapses the node into its parent.
//!
//! ## Why a tree and not a list of rectangles
//!
//! Because closing a window has to give its space to a neighbour, and the
//! neighbour has to be the one it was split from. With a flat list, closing
//! the middle of three columns leaves a hole that has to be filled by a rule
//! made up on the spot; with a tree, the answer falls out of the structure --
//! the sibling takes the parent's rectangle, and if there is only one sibling
//! left the parent stops existing.
//!
//! ## Storage
//!
//! Nodes and views live in arrays and refer to one another by index. There
//! are never more than a handful of either, and a closed slot is reused
//! rather than compacted, so an index handed out stays valid for as long as
//! the thing it names is open -- which is what lets `focus` be a number
//! rather than a pointer that a reallocation would invalidate.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");
const View = @import("View.zig");

const Bounds = gelgja.Bounds;
const Point = gelgja.Point;

const Layout = @This();

/// The thickness of the line between two views, in device pixels. Drawn, and
/// subtracted from both sides, so neighbouring pages never touch.
pub const border = 2.0;

/// Smallest a view may be squeezed to before a split is refused. Below this
/// there is no room for a page and a scrollbar, and a split that produces a
/// window you cannot read is not a split worth allowing.
pub const min_side = 120.0;

pub const Direction = enum { horizontal, vertical };

/// Which way to look for a neighbour, spelled the way Vim spells it.
pub const Side = enum { left, right, up, down };

/// What a leaf holds.
///
/// A view index until now, and a union from here on, because the canvas
/// planned beside the page is another *kind of leaf in this tree* rather than
/// a second layout system beside it. Splitting, closing, focusing by geometry
/// and dragging the line between two of them are the same operations whatever
/// the leaves are, and they are written once here.
pub const Pane = union(enum) {
    /// A window onto a document: an index into `views`.
    document: u32,
    /// A node claimed but not yet pointed at anything, and every row and
    /// column, which hold children rather than content.
    empty,

    /// The view this holds, or null for a pane that is not one.
    pub fn view(p: Pane) ?u32 {
        return switch (p) {
            .document => |v| v,
            .empty => null,
        };
    }
};

pub const Node = struct {
    kind: Kind = .free,
    /// The node this hangs from, or `none` for the root.
    parent: u32 = none,
    /// For a leaf: what is in it. For a row or column: `.empty`.
    pane: Pane = .empty,
    /// For a row or column: its children, in order left-to-right or
    /// top-to-bottom. Vim allows any number per level and so does this, which
    /// is what makes three side-by-side windows one row rather than a row
    /// containing a row.
    children: std.ArrayList(u32) = .empty,
    /// Each child's share of this node's length, summing to one. Kept so that
    /// resizing the window preserves the proportions a person set up rather
    /// than resetting them to equal.
    shares: std.ArrayList(f32) = .empty,
    /// The rectangle this node was last given, in device pixels.
    rect: Bounds = .fromRect(0, 0, 1, 1),

    pub const Kind = enum { free, leaf, row, column };
};

pub const none: u32 = std.math.maxInt(u32);

nodes: std.ArrayList(Node) = .empty,
views: std.ArrayList(View) = .empty,
/// Which view slots are in use. A closed view's slot is kept so that indices
/// stay stable, and reused by the next split.
live: std.ArrayList(bool) = .empty,

root: u32 = none,
/// The focused *node*, always a leaf.
focus: u32 = none,

pub fn deinit(l: *Layout, gpa: Allocator) void {
    for (l.nodes.items) |*n| {
        n.children.deinit(gpa);
        n.shares.deinit(gpa);
    }
    l.nodes.deinit(gpa);
    l.views.deinit(gpa);
    l.live.deinit(gpa);
    l.* = .{};
}

/// Starts a layout with one view filling everything.
pub fn init(l: *Layout, gpa: Allocator, first: View) Allocator.Error!void {
    const v = try l.newView(gpa, first);
    const n = try l.newNode(gpa);
    l.asLeaf(n, .{ .document = v }, none);
    l.root = n;
    l.focus = n;
}

fn newView(l: *Layout, gpa: Allocator, v: View) Allocator.Error!u32 {
    for (l.live.items, 0..) |in_use, i| {
        if (in_use) continue;
        l.views.items[i] = v;
        l.live.items[i] = true;
        return @intCast(i);
    }
    try l.views.append(gpa, v);
    try l.live.append(gpa, true);
    return @intCast(l.views.items.len - 1);
}

/// A node index nobody else holds.
///
/// The slot is *claimed* before it is returned -- `kind` stops being `.free`
/// -- because two calls in a row are the normal case, and a version of this
/// that left the slot free handed the same index out twice and quietly built
/// a tree where one node was its own sibling.
fn newNode(l: *Layout, gpa: Allocator) Allocator.Error!u32 {
    for (l.nodes.items, 0..) |*n, i| {
        if (n.kind != .free) continue;
        n.kind = .leaf;
        n.parent = none;
        n.pane = .empty;
        n.children.clearRetainingCapacity();
        n.shares.clearRetainingCapacity();
        return @intCast(i);
    }
    try l.nodes.append(gpa, .{ .kind = .leaf });
    return @intCast(l.nodes.items.len - 1);
}

/// Points an already-claimed node at a pane, without touching its lists --
/// which a whole-struct assignment would replace, leaking whatever capacity
/// the recycled slot had.
fn asLeaf(l: *Layout, node: u32, pane: Pane, parent: u32) void {
    const n = &l.nodes.items[node];
    n.kind = .leaf;
    n.pane = pane;
    n.parent = parent;
    n.children.clearRetainingCapacity();
    n.shares.clearRetainingCapacity();
}

// -- asking about the layout --------------------------------------------------

pub fn count(l: Layout) u32 {
    var n: u32 = 0;
    for (l.live.items) |in_use| {
        if (in_use) n += 1;
    }
    return n;
}

/// The focused view, which always exists while a layout does.
pub fn current(l: *Layout) *View {
    return &l.views.items[l.currentIndex()];
}

pub fn currentIndex(l: Layout) u32 {
    return l.nodes.items[l.focus].pane.view().?;
}

pub fn viewAt(l: *Layout, index: u32) *View {
    return &l.views.items[index];
}

/// Every open view, in no particular order. Closed slots are skipped.
pub const Iterator = struct {
    l: *Layout,
    i: usize = 0,

    pub fn next(it: *Iterator) ?*View {
        while (it.i < it.l.live.items.len) {
            const at = it.i;
            it.i += 1;
            if (it.l.live.items[at]) return &it.l.views.items[at];
        }
        return null;
    }
};

pub fn iterator(l: *Layout) Iterator {
    return .{ .l = l };
}

/// The leaf nodes, in layout order: left to right, top to bottom. This is the
/// order `<C-w>w` cycles in and the order views are drawn in.
pub fn leaves(l: *Layout, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (l.root == none) return;
    try l.collect(l.root, out, gpa);
}

fn collect(l: *Layout, node: u32, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
    const n = &l.nodes.items[node];
    if (n.kind == .leaf) {
        try out.append(gpa, node);
        return;
    }
    // Indexed rather than iterated: `collect` does not resize `children`, but
    // taking a slice of an ArrayList field and recursing through it is a
    // habit that stops being safe the moment someone adds an append.
    var i: usize = 0;
    while (i < n.children.items.len) : (i += 1) {
        try l.collect(l.nodes.items[node].children.items[i], out, gpa);
    }
}

/// The view under a window point, for a click that should move focus.
pub fn viewUnder(l: *Layout, p: Point) ?u32 {
    for (l.nodes.items, 0..) |n, i| {
        if (n.kind != .leaf) continue;
        if (n.rect.contains(p)) return @intCast(i);
    }
    return null;
}

// -- changing it --------------------------------------------------------------

/// Splits the focused window, putting a copy of its view in the new one and
/// focusing the new one -- which is what `:split` does and what anyone coming
/// from Vim will expect.
///
/// Returns the new view's index, or null when there is no room. The copy
/// shares the buffer, so the two are immediately two windows onto one
/// document: highlight in either and both show it.
pub fn split(l: *Layout, gpa: Allocator, dir: Direction) Allocator.Error!?u32 {
    const leaf = l.focus;
    if (leaf == none) return null;

    const rect = l.nodes.items[leaf].rect;
    const along = if (dir == .vertical) rect.width() else rect.height();
    if (along / 2 < min_side) return null;

    const copy = l.views.items[l.currentIndex()];
    const v = try l.newView(gpa, copy);
    errdefer l.live.items[v] = false;

    const want: Node.Kind = if (dir == .vertical) .row else .column;
    const parent = l.nodes.items[leaf].parent;

    // A leaf inside a row being split vertically joins that row rather than
    // nesting a row inside it. Vim does the same, and it is the difference
    // between three splits being three equal columns and being a column and
    // then a column of a column.
    if (parent != none and l.nodes.items[parent].kind == want) {
        const at = indexOf(l.nodes.items[parent].children.items, leaf).?;
        const fresh = try l.newNode(gpa);
        l.asLeaf(fresh, .{ .document = v }, parent);

        const p = &l.nodes.items[parent];
        try p.children.insert(gpa, at + 1, fresh);
        try p.shares.insert(gpa, at + 1, p.shares.items[at] / 2);
        p.shares.items[at] /= 2;
        // Then everything in this row is made equal again, which is what Vim
        // does by default (`'equalalways'`) and what makes three `<C-w>v` in
        // a row three equal columns rather than a half and two quarters.
        // `<C-w>=` is the same operation asked for by hand.
        even(p);

        l.focus = fresh;
        l.arrange(l.nodes.items[l.root].rect);
        return v;
    }

    // Otherwise the leaf becomes a row or column of two: itself, moved into a
    // new node, and the new window.
    const moved = try l.newNode(gpa);
    const fresh = try l.newNode(gpa);

    l.asLeaf(moved, l.nodes.items[leaf].pane, leaf);
    l.asLeaf(fresh, .{ .document = v }, leaf);

    const holder = &l.nodes.items[leaf];
    holder.kind = want;
    holder.pane = .empty;
    holder.children.clearRetainingCapacity();
    holder.shares.clearRetainingCapacity();
    try holder.children.appendSlice(gpa, &.{ moved, fresh });
    try holder.shares.appendSlice(gpa, &.{ 0.5, 0.5 });

    l.focus = fresh;
    l.arrange(l.nodes.items[l.root].rect);
    return v;
}

/// Closes the focused window. Returns the view index that was freed, or null
/// when this is the last window -- which is a request to quit, and the
/// caller's decision rather than this one's.
pub fn close(l: *Layout, gpa: Allocator) ?u32 {
    const leaf = l.focus;
    if (leaf == none or leaf == l.root) return null;

    const gone = l.nodes.items[leaf].pane.view().?;
    const parent = l.nodes.items[leaf].parent;
    const at = indexOf(l.nodes.items[parent].children.items, leaf).?;

    l.live.items[gone] = false;
    l.release(gpa, leaf);

    const p = &l.nodes.items[parent];
    _ = p.children.orderedRemove(at);
    const freed = p.shares.orderedRemove(at);
    // The space goes to the neighbours in proportion, so closing a window
    // does not reset every other size on screen.
    if (p.shares.items.len != 0) {
        const each = freed / @as(f32, @floatFromInt(p.shares.items.len));
        for (p.shares.items) |*s| s.* += each;
    }

    // A node with one child left is not a split any more: it becomes that
    // child, which is what gives the space back to the window it was taken
    // from rather than to an arbitrary one.
    if (p.children.items.len == 1) {
        const survivor = p.children.items[0];
        const kept = l.nodes.items[survivor];
        l.release(gpa, survivor);

        const into = &l.nodes.items[parent];
        into.kind = kept.kind;
        into.pane = kept.pane;
        into.children.clearRetainingCapacity();
        into.shares.clearRetainingCapacity();
        into.children.appendSlice(gpa, kept.children.items) catch {};
        into.shares.appendSlice(gpa, kept.shares.items) catch {};
        for (into.children.items) |c| l.nodes.items[c].parent = parent;
    }

    l.focus = l.firstLeaf(if (l.nodes.items[parent].kind == .free) l.root else parent);
    l.arrange(l.nodes.items[l.root].rect);
    return gone;
}

/// Closes every window but the focused one. `<C-w>o`.
pub fn only(l: *Layout, gpa: Allocator) void {
    const keep = l.focus;
    if (keep == none or keep == l.root) return;

    const kept = l.nodes.items[keep].pane;
    const view = kept.view().?;
    for (l.live.items, 0..) |*in_use, i| {
        if (i != view) in_use.* = false;
    }

    // Everything but the root and the kept leaf goes back on the free list.
    for (l.nodes.items, 0..) |*n, i| {
        if (i == l.root) continue;
        if (n.kind == .free) continue;
        n.children.clearRetainingCapacity();
        n.shares.clearRetainingCapacity();
        n.kind = .free;
        n.parent = none;
        n.pane = .empty;
    }

    const r = &l.nodes.items[l.root];
    r.kind = .leaf;
    r.pane = kept;
    r.children.clearRetainingCapacity();
    r.shares.clearRetainingCapacity();
    l.focus = l.root;
    _ = gpa;
    l.arrange(r.rect);
}

/// Gives every child of a node the same share.
fn even(n: *Node) void {
    if (n.shares.items.len == 0) return;
    const each = 1.0 / @as(f32, @floatFromInt(n.shares.items.len));
    for (n.shares.items) |*s| s.* = each;
}

/// Makes every window the same size, as far as the tree allows -- `<C-w>=`.
/// Sizes are equalised within each row and column, which for a tree of nested
/// splits is what Vim means by it too.
pub fn equalise(l: *Layout) void {
    for (l.nodes.items) |*n| {
        if (n.kind == .row or n.kind == .column) even(n);
    }
    l.arrange(l.nodes.items[l.root].rect);
}

fn release(l: *Layout, gpa: Allocator, node: u32) void {
    _ = gpa;
    const n = &l.nodes.items[node];
    n.children.clearRetainingCapacity();
    n.shares.clearRetainingCapacity();
    n.kind = .free;
    n.parent = none;
    n.pane = .empty;
}

fn firstLeaf(l: *Layout, node: u32) u32 {
    var at = node;
    while (l.nodes.items[at].kind != .leaf) {
        if (l.nodes.items[at].children.items.len == 0) return l.root;
        at = l.nodes.items[at].children.items[0];
    }
    return at;
}

// -- moving between windows ---------------------------------------------------

/// The next window in layout order, wrapping. `<C-w>w`.
pub fn cycle(l: *Layout, gpa: Allocator, backwards: bool) void {
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    l.leaves(&order, gpa) catch return;
    if (order.items.len < 2) return;

    const at = indexOf(order.items, l.focus) orelse 0;
    const next = if (backwards)
        (at + order.items.len - 1) % order.items.len
    else
        (at + 1) % order.items.len;
    l.focus = order.items[next];
}

/// The window in a direction, by geometry rather than by tree position.
///
/// Geometry, because that is what the keys mean: `<C-w>l` is "the window to
/// the right of this one", and in a layout of a tall window beside two short
/// ones the answer depends on where the cursor is, not on how the tree
/// happens to be nested. The candidate is the nearest leaf whose rectangle
/// starts past this one's edge and whose span overlaps it.
pub fn focusSide(l: *Layout, side: Side) bool {
    const from = l.nodes.items[l.focus].rect;
    var best: u32 = none;
    var best_d: f32 = std.math.floatMax(f32);

    for (l.nodes.items, 0..) |n, i| {
        if (n.kind != .leaf or i == l.focus) continue;
        const to = n.rect;

        const d: f32 = switch (side) {
            .left => from.min_x - to.max_x,
            .right => to.min_x - from.max_x,
            .up => from.min_y - to.max_y,
            .down => to.min_y - from.max_y,
        };
        // Must be on that side at all: a negative distance is a window that
        // overlaps or is behind.
        if (d < -border) continue;

        const overlaps = switch (side) {
            .left, .right => to.min_y < from.max_y and to.max_y > from.min_y,
            .up, .down => to.min_x < from.max_x and to.max_x > from.min_x,
        };
        if (!overlaps) continue;

        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }

    if (best == none) return false;
    l.focus = best;
    return true;
}

/// Focuses whichever window is under a point. Returns true when that changed
/// the focus, so a click that only moves focus can be swallowed.
pub fn focusAt(l: *Layout, p: Point) bool {
    const under = l.viewUnder(p) orelse return false;
    if (under == l.focus) return false;
    l.focus = under;
    return true;
}

// -- geometry -----------------------------------------------------------------

/// Gives every window its rectangle. Called whenever the window resizes or
/// the tree changes; cheap enough to call every frame and not called that
/// often.
pub fn arrange(l: *Layout, rect: Bounds) void {
    if (l.root == none) return;
    l.place(l.root, rect);
}

fn place(l: *Layout, node: u32, rect: Bounds) void {
    l.nodes.items[node].rect = rect;
    const n = &l.nodes.items[node];

    switch (n.kind) {
        .free => {},
        .leaf => {
            const v = &l.views.items[n.pane.view().?];
            const resized = v.rect.width() != rect.width() or v.rect.height() != rect.height();
            v.rect = rect;
            // Only on a change of size: `arrange` runs every frame, and a
            // refit is a zoom about the middle of the view, which with a
            // scroll in flight would nudge the page a sub-pixel per frame.
            // The height counts as well as the width now that a page can be
            // fitted down the window.
            if (resized) v.refit();
            v.clampScroll();
        },
        .row, .column => {
            const vertical = n.kind == .column;
            const total = if (vertical) rect.height() else rect.width();
            const kids: f32 = @floatFromInt(n.children.items.len);
            // The borders come out of the total before it is shared, so a
            // split of two equal halves stays equal however thick the line is.
            const usable = @max(1, total - border * (kids - 1));

            var at = if (vertical) rect.min_y else rect.min_x;
            var i: usize = 0;
            while (i < n.children.items.len) : (i += 1) {
                const child = n.children.items[i];
                const share = n.shares.items[i];
                const last = i + 1 == n.children.items.len;
                // The last one takes what is left rather than its share, so
                // rounding never leaves a one-pixel strip of background down
                // the right-hand edge.
                const size = if (last)
                    (if (vertical) rect.max_y else rect.max_x) - at
                else
                    @round(usable * share);

                const sub: Bounds = if (vertical)
                    .fromRect(rect.min_x, at, rect.max_x, at + size)
                else
                    .fromRect(at, rect.min_y, at + size, rect.max_y);
                l.place(child, sub);
                at += size + border;
            }
        },
    }
}

/// The lines between windows, for drawing. Each is the gap between two
/// siblings, in device pixels.
pub fn borders(l: *Layout, out: *std.ArrayList(Bounds), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (l.nodes.items) |n| {
        if (n.kind != .row and n.kind != .column) continue;
        var i: usize = 1;
        while (i < n.children.items.len) : (i += 1) {
            const before = l.nodes.items[n.children.items[i - 1]].rect;
            const after = l.nodes.items[n.children.items[i]].rect;
            try out.append(gpa, if (n.kind == .column)
                .fromRect(n.rect.min_x, before.max_y, n.rect.max_x, after.min_y)
            else
                .fromRect(before.max_x, n.rect.min_y, after.min_x, n.rect.max_y));
        }
    }
}

/// One line between two windows: which node owns it, which pair it divides,
/// and where it is.
///
/// Named by the node and the index rather than by the rectangle, because a
/// drag re-lays the tree on every frame. A divider that knew only where it
/// had been would have to be found again after each move, and would be lost
/// the moment it reached a window's minimum and stopped moving under the
/// pointer.
pub const Divider = struct {
    node: u32,
    /// The gap between children `after - 1` and `after`.
    after: u32,
    /// `vertical` between two side-by-side windows, matching the direction
    /// the split that made it was asked for in.
    dir: Direction,
    rect: Bounds,
};

/// The divider under a point, or null.
///
/// `slack` widens each line across its thickness. A two-pixel line is a
/// two-pixel target and nobody can hit one; widening it here rather than
/// drawing it thicker keeps what is grabbed and what is seen independent,
/// which is the only way to have a hairline you can still take hold of.
pub fn dividerAt(l: *Layout, p: Point, slack: f32) ?Divider {
    for (l.nodes.items, 0..) |n, node| {
        if (n.kind != .row and n.kind != .column) continue;

        var i: usize = 1;
        while (i < n.children.items.len) : (i += 1) {
            const before = l.nodes.items[n.children.items[i - 1]].rect;
            const after = l.nodes.items[n.children.items[i]].rect;
            const stacked = n.kind == .column;

            const rect: Bounds = if (stacked)
                .fromRect(n.rect.min_x, before.max_y, n.rect.max_x, after.min_y)
            else
                .fromRect(before.max_x, n.rect.min_y, after.min_x, n.rect.max_y);

            const grab: Bounds = if (stacked)
                .fromRect(rect.min_x, rect.min_y - slack, rect.max_x, rect.max_y + slack)
            else
                .fromRect(rect.min_x - slack, rect.min_y, rect.max_x + slack, rect.max_y);

            if (grab.contains(p)) return .{
                .node = @intCast(node),
                .after = @intCast(i),
                .dir = if (stacked) .horizontal else .vertical,
                .rect = rect,
            };
        }
    }
    return null;
}

/// Moves a divider so its line lands at `at` -- device pixels along the axis
/// the pair is stacked on -- and re-lays the tree, as `split` and `close` do.
///
/// Only the two windows either side move: their shares sum to the same number
/// afterwards, so dragging one line in a row of four leaves the other two
/// exactly where they were. Neither side goes below `min_side`, which is the
/// same floor a split refuses to go under, so a window can never be dragged
/// smaller than one that could have been made.
pub fn moveDivider(l: *Layout, d: Divider, at: f32) void {
    if (l.root == none or d.node >= l.nodes.items.len) return;
    const n = &l.nodes.items[d.node];
    if (d.after == 0 or d.after >= n.children.items.len) return;

    const i = d.after;
    const stacked = n.kind == .column;
    const total = if (stacked) n.rect.height() else n.rect.width();
    const kids: f32 = @floatFromInt(n.children.items.len);
    const usable = @max(1, total - border * (kids - 1));

    const pair = n.shares.items[i - 1] + n.shares.items[i];
    const room = usable * pair;
    if (room < min_side * 2) return;

    const first = l.nodes.items[n.children.items[i - 1]].rect;
    const start = if (stacked) first.min_y else first.min_x;

    const want = std.math.clamp(at - start, min_side, room - min_side);
    n.shares.items[i - 1] = want / usable;
    n.shares.items[i] = pair - n.shares.items[i - 1];

    l.arrange(l.nodes.items[l.root].rect);
}

fn indexOf(items: []const u32, want: u32) ?usize {
    for (items, 0..) |it, i| {
        if (it == want) return i;
    }
    return null;
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

fn started(gpa: Allocator, pages: []fenrir.Page) !Layout {
    var l: Layout = .{};
    try l.init(gpa, .{ .pages = pages, .zoom = 1 });
    l.arrange(.fromRect(0, 0, 1000, 800));
    return l;
}

test "a fresh layout is one window filling everything" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), l.count());
    try testing.expectEqual(@as(f32, 1000), l.current().rect.width());
    try testing.expectEqual(@as(f32, 800), l.current().rect.height());
    // The last window cannot be closed: that is a quit, and not this
    // module's decision.
    try testing.expectEqual(@as(?u32, null), l.close(gpa));
}

test "every leaf holds a document pane, and every branch holds none" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    _ = try l.split(gpa, .vertical);
    try testing.expectEqual(l.currentIndex(), l.nodes.items[l.focus].pane.document);

    for (l.nodes.items) |n| switch (n.kind) {
        .leaf => try testing.expect(n.pane.view() != null),
        .row, .column, .free => try testing.expectEqual(Pane.empty, n.pane),
    };
}

test "a vertical split makes two columns, and focus follows the new one" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    const first = l.currentIndex();
    const second = (try l.split(gpa, .vertical)).?;
    try testing.expectEqual(@as(u32, 2), l.count());
    try testing.expectEqual(second, l.currentIndex());
    try testing.expect(first != second);

    // Side by side, sharing the width less the border, and the full height.
    const a = l.viewAt(first).rect;
    const b = l.viewAt(second).rect;
    try testing.expectApproxEqAbs(@as(f32, 0), a.min_x, 0.001);
    try testing.expectApproxEqAbs(a.max_x + border, b.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1000), b.max_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 800), a.height(), 0.001);
    try testing.expectApproxEqAbs(a.width(), b.width(), 1.0);
}

test "a split shares the buffer, which is what makes two windows one document" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    l.current().buffer = 7;
    l.current().scroll = 250;
    const second = (try l.split(gpa, .horizontal)).?;

    // Same document...
    try testing.expectEqual(@as(u32, 7), l.viewAt(second).buffer);
    // ...and the scroll came with it, the way `:split` leaves you where you
    // were. They diverge from here.
    try testing.expectApproxEqAbs(@as(f32, 250), l.viewAt(second).scroll, 0.001);
    l.viewAt(second).scroll = 0;
    try testing.expectApproxEqAbs(@as(f32, 250), l.viewAt(l.nodes.items[l.root].children.items[0]).scroll, 250);
}

test "three splits the same way are three equal windows, not nested pairs" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    _ = try l.split(gpa, .vertical);
    _ = try l.split(gpa, .vertical);
    try testing.expectEqual(@as(u32, 3), l.count());

    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try l.leaves(&order, gpa);
    try testing.expectEqual(@as(usize, 3), order.items.len);

    // One row of three, so every window is a third wide. Nesting would give
    // a half and two quarters.
    for (order.items) |leaf| {
        try testing.expectApproxEqAbs(@as(f32, 1000 - 2 * border) / 3, l.nodes.items[leaf].rect.width(), 1.5);
    }
}

test "closing gives the space back to the window it was taken from" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    const first = l.currentIndex();
    const second = (try l.split(gpa, .vertical)).?;
    try testing.expectEqual(second, l.close(gpa).?);

    try testing.expectEqual(@as(u32, 1), l.count());
    try testing.expectEqual(first, l.currentIndex());
    // The whole window again, not half of it with a gap.
    try testing.expectApproxEqAbs(@as(f32, 1000), l.current().rect.width(), 0.001);
}

test "only leaves the focused window and nothing else" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    _ = try l.split(gpa, .vertical);
    _ = try l.split(gpa, .horizontal);
    _ = try l.split(gpa, .vertical);
    try testing.expectEqual(@as(u32, 4), l.count());

    const kept = l.currentIndex();
    l.only(gpa);
    try testing.expectEqual(@as(u32, 1), l.count());
    try testing.expectEqual(kept, l.currentIndex());
    try testing.expectApproxEqAbs(@as(f32, 1000), l.current().rect.width(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 800), l.current().rect.height(), 0.001);
}

test "focus moves by geometry, so the keys mean what they say" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    const left = l.currentIndex();
    const right = (try l.split(gpa, .vertical)).?;
    try testing.expectEqual(right, l.currentIndex());

    try testing.expect(l.focusSide(.left));
    try testing.expectEqual(left, l.currentIndex());
    // Nothing further left: the focus stays put rather than wrapping, which
    // is what Vim does and what stops a held key walking off the layout.
    try testing.expect(!l.focusSide(.left));
    try testing.expectEqual(left, l.currentIndex());

    try testing.expect(l.focusSide(.right));
    try testing.expectEqual(right, l.currentIndex());
    // Up and down have no neighbours in a row of two.
    try testing.expect(!l.focusSide(.up));
    try testing.expect(!l.focusSide(.down));
}

test "cycling visits every window and comes back" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    _ = try l.split(gpa, .vertical);
    _ = try l.split(gpa, .horizontal);

    const start = l.currentIndex();
    var seen: [4]u32 = @splat(Layout.none);
    for (0..3) |i| {
        seen[i] = l.currentIndex();
        l.cycle(gpa, false);
    }
    try testing.expectEqual(start, l.currentIndex());
    try testing.expect(seen[0] != seen[1] and seen[1] != seen[2] and seen[0] != seen[2]);

    // And backwards is the way it came.
    l.cycle(gpa, true);
    try testing.expectEqual(seen[2], l.currentIndex());
}

test "a window too small to read is not split" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l: Layout = .{};
    defer l.deinit(gpa);
    try l.init(gpa, .{ .pages = fakePages(&buf, 3), .zoom = 1 });
    l.arrange(.fromRect(0, 0, 200, 700));

    // 200 wide halves to 100, under the minimum: refused rather than
    // producing a window with no room for a page.
    try testing.expectEqual(@as(?u32, null), try l.split(gpa, .vertical));
    // The same window splits the other way, where there is height to spare.
    try testing.expect((try l.split(gpa, .horizontal)) != null);
}

test "a click focuses the window under it" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    const left = l.currentIndex();
    const right = (try l.split(gpa, .vertical)).?;

    try testing.expect(l.focusAt(.{ .x = 100, .y = 400 }));
    try testing.expectEqual(left, l.currentIndex());
    try testing.expect(l.focusAt(.{ .x = 900, .y = 400 }));
    try testing.expectEqual(right, l.currentIndex());
    // A click in the window that already has focus is not a focus change,
    // so the caller can let it through to the page.
    try testing.expect(!l.focusAt(.{ .x = 900, .y = 400 }));
}

test "resizing keeps the proportions rather than resetting them" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    const a = l.currentIndex();
    const b = (try l.split(gpa, .vertical)).?;
    const before = l.viewAt(a).rect.width() / l.viewAt(b).rect.width();

    l.arrange(.fromRect(0, 0, 1600, 900));
    const after = l.viewAt(a).rect.width() / l.viewAt(b).rect.width();
    try testing.expectApproxEqAbs(before, after, 0.02);
    try testing.expectApproxEqAbs(@as(f32, 1600), l.viewAt(b).rect.max_x, 0.001);
}

test "splitting a fitted window refits both halves to their own width" {
    // The bug a GPU capture showed: the page fitted to a 1400-pixel window,
    // then split, left two 700-pixel windows each showing the middle of a
    // page 1400 pixels wide.
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    l.current().fitTo(.width);
    const whole = l.current().pageSize(0)[0];
    try testing.expectApproxEqAbs(@as(f32, 1000 - 2 * View.gap), whole, 1.5);

    _ = try l.split(gpa, .vertical);
    var it = l.iterator();
    while (it.next()) |v| {
        // Each page fits its own half, less the margins.
        try testing.expectApproxEqAbs(v.width() - 2 * View.gap, v.pageSize(0)[0], 1.5);
        try testing.expect(v.pageSize(0)[0] < whole * 0.6);
    }

    // And closing one gives the survivor the whole width back, refitted.
    _ = l.close(gpa);
    try testing.expectApproxEqAbs(whole, l.current().pageSize(0)[0], 1.5);
}

test "a window at a chosen zoom keeps it through a split" {
    // The other half of the rule: fit-width is a mode, and a number is not.
    // Someone who zoomed to 200% and split wants two windows at 200%.
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    l.current().fitTo(.width);
    l.current().setZoom(2);
    try testing.expect(l.current().fit == .free);

    _ = try l.split(gpa, .vertical);
    var it = l.iterator();
    while (it.next()) |v| try testing.expectApproxEqAbs(@as(f32, 2), v.zoom, 0.001);
}

test "the line between two windows is found by a point near it" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    _ = try l.split(gpa, .vertical);
    const d = l.dividerAt(.{ .x = 500, .y = 400 }, 4).?;
    try testing.expectEqual(Direction.vertical, d.dir);
    try testing.expectEqual(@as(u32, 1), d.after);
    // Two pixels wide, in the middle, and the full height.
    try testing.expectApproxEqAbs(@as(f32, border), d.rect.width(), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 800), d.rect.height(), 1e-3);

    // The slack is what makes it hittable; without it a two-pixel line is a
    // two-pixel target.
    try testing.expect(l.dividerAt(.{ .x = 504, .y = 400 }, 4) != null);
    try testing.expect(l.dividerAt(.{ .x = 504, .y = 400 }, 0) == null);
    try testing.expect(l.dividerAt(.{ .x = 200, .y = 400 }, 4) == null);
}

test "dragging the line resizes both windows and nothing else" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    // Three columns: a third each.
    const a = l.currentIndex();
    const b = (try l.split(gpa, .vertical)).?;
    const c = (try l.split(gpa, .vertical)).?;
    const third = l.viewAt(c).rect;

    const d = l.dividerAt(.{ .x = l.viewAt(a).rect.max_x + 1, .y = 400 }, 4).?;
    l.moveDivider(d, 200);

    try testing.expectApproxEqAbs(@as(f32, 200), l.viewAt(a).rect.max_x, 1e-3);
    // The third window did not move: a drag takes from one neighbour, not
    // from every window in the row.
    try testing.expectApproxEqAbs(third.min_x, l.viewAt(c).rect.min_x, 1e-3);
    try testing.expectApproxEqAbs(third.max_x, l.viewAt(c).rect.max_x, 1e-3);
    // And the pair still fills what it filled before.
    try testing.expectApproxEqAbs(third.min_x - border, l.viewAt(b).rect.max_x, 1e-3);
}

test "neither window can be dragged below the width a split needs" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var l = try started(gpa, fakePages(&buf, 3));
    defer l.deinit(gpa);

    const a = l.currentIndex();
    const b = (try l.split(gpa, .horizontal)).?;

    const d = l.dividerAt(.{ .x = 500, .y = l.viewAt(a).rect.max_y + 1 }, 4).?;
    try testing.expectEqual(Direction.horizontal, d.dir);

    l.moveDivider(d, -400);
    try testing.expectApproxEqAbs(@as(f32, min_side), l.viewAt(a).rect.height(), 1e-3);

    l.moveDivider(l.dividerAt(.{ .x = 500, .y = l.viewAt(a).rect.max_y + 1 }, 4).?, 5000);
    try testing.expectApproxEqAbs(@as(f32, min_side), l.viewAt(b).rect.height(), 1e-3);
}
