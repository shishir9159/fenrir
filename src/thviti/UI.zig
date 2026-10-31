//! The UI core: a box tree built by immediate calls, over state that persists.
//!
//! Following RAD Debugger's `ui` layer, and the reason for it is worth stating
//! once here rather than being rediscovered. "Immediate versus retained"
//! conflates two independent questions -- what the call site looks like, and
//! whether per-widget state survives a frame -- and picking the same answer
//! for both is what makes each pure form painful. Dear ImGui is immediate for
//! both and pays in awkward animation, awkward focus, and layout that lags a
//! frame. Qt and GTK are retained for both and pay in ownership, invalidation
//! and diffing. This is immediate call sites over retained *state*: boxes live
//! in a hash table across frames, keyed by a string and the parent's key, and
//! carry hover, focus and scroll for nothing.
//!
//! A frame is:
//!
//!     try ui.begin(viewport, input);
//!     ... calls that build boxes ...
//!     ui.end();
//!
//! Between those, `open`/`close` nest boxes and `signal` reads interaction out
//! of them. Nothing is allocated by the caller, nothing is freed, and no
//! handle outlives the call that made it.
//!
//! ## The five passes
//!
//! Layout is not done while building. It is five walks over the finished tree,
//! run twice -- once per axis -- because the two axes never depend on each
//! other:
//!
//!   1. **Standalone.** Sizes that depend on nothing: pixels, and text.
//!   2. **Upward-dependent.** Percentages, which need an ancestor's size, so
//!      the walk is pre-order.
//!   3. **Downward-dependent.** Sums of children, so the walk is post-order.
//!   4. **Violations.** Where the children of a box do not fit, take the
//!      shortfall out of them in proportion to what each is *willing* to give.
//!   5. **Positions.** Relative offsets become absolute rectangles.
//!
//! Splitting 2 and 3 is what makes both directions expressible in one tree:
//! a toolbar as wide as its window containing a label as wide as its text
//! containing nothing, all solved in one frame with no fixpoint iteration.
//!
//! Pass 4 is the one with a compromise in it. Shrinking a box invalidates any
//! percentage its descendants computed from it in pass 2, and the honest fix
//! is to re-run 2 and 3 for that subtree, which is quadratic in the worst
//! case. RAD does not, and neither does this: a percentage under a box that
//! was itself squeezed comes out one frame stale. The escape is
//! `overflow_x`/`overflow_y`, which excuses a box from being squeezed at all
//! and is what a scroll view uses.
//!
//! ## What costs a frame
//!
//! Hit testing runs against the rectangle the *previous* frame solved, because
//! this frame's is not known while the tree is still being built. That is the
//! whole price of immediate call sites, it is one frame, and it is only ever
//! visible on the frame a box first appears -- where there is nothing to
//! interact with yet anyway.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");

const Box = @import("Box.zig");
const input = @import("input.zig");
const key = @import("key.zig");

const Bounds = geom.Bounds;
const Point = geom.Point;

const Axis = Box.Axis;
const Flags = Box.Flags;
const Input = input.Input;
const Key = key.Key;
const MouseButton = input.MouseButton;
const Next = Box.Next;
const Size = Box.Size;
const Style = Box.Style;
const StylePatch = Box.StylePatch;

const UI = @This();

pub const Error = Allocator.Error;

/// Same depth and same policy as `gleipnir.DrawList`: an overflow re-pushes
/// the top rather than failing, so `defer`-balanced call sites stay balanced.
pub const stack_depth = 64;

/// Frames a box may go untouched before it is dropped. Not one, because a
/// panel hidden behind a tab for a frame should keep its scroll position, and
/// not many, because every one of them is a live allocation.
pub const prune_after: u64 = 8;

/// Time constant for hover and press animation, in reciprocal seconds. The
/// blend is `1 - exp(-dt * rate)` rather than a fixed fraction, so the same
/// curve plays at 60 and at 144 hertz.
pub const animation_rate: f32 = 24;
pub const scroll_rate: f32 = 30;

pub const double_click_seconds: f64 = 0.35;

/// The longest a single frame is allowed to claim to have taken. A window
/// drag, a breakpoint, or a swap chain rebuild all produce a `dt` of seconds,
/// and without a clamp every animation in the frame completes instantly and
/// every smooth scroll teleports.
pub const max_dt: f32 = 1.0 / 15.0;

// -- text measurement -------------------------------------------------------

/// How the solver asks how big a string is.
///
/// An interface rather than a `*Fonts`, so that the layout solver -- the part
/// most worth testing and the part with no graphics in it -- can be tested
/// against a stand-in whose advances are known exactly. `thviti/text.zig`
/// provides the real one.
pub const Metrics = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Width and height of `text` in device pixels.
        measure: *const fn (ptr: *anyopaque, text: []const u8, font: u16, px: f32) Error!Point,
        /// Baseline to baseline.
        lineHeight: *const fn (ptr: *anyopaque, font: u16, px: f32) f32,
    };

    pub fn measure(m: Metrics, text: []const u8, font: u16, px: f32) Error!Point {
        return m.vtable.measure(m.ptr, text, font, px);
    }

    pub fn lineHeight(m: Metrics, font: u16, px: f32) f32 {
        return m.vtable.lineHeight(m.ptr, font, px);
    }
};

/// A stand-in with a half-em advance and a 1.2-em line, matching the
/// box-drawing fallback face. Enough to build and test a whole layout with no
/// font layer present at all.
pub const fixed_metrics: Metrics = .{
    .ptr = @constCast(@ptrCast(&fixed_tag)),
    .vtable = &fixed_vtable,
};

const fixed_tag: u8 = 0;

const fixed_vtable: Metrics.VTable = .{
    .measure = fixedMeasure,
    .lineHeight = fixedLineHeight,
};

fn fixedMeasure(_: *anyopaque, text: []const u8, _: u16, px: f32) Error!Point {
    return .{ .x = @as(f32, @floatFromInt(text.len)) * px * 0.5, .y = px };
}

fn fixedLineHeight(_: *anyopaque, _: u16, px: f32) f32 {
    return px * 1.2;
}

// -- signals ----------------------------------------------------------------

/// What happened to a box, as of the moment it was built.
pub const Signal = struct {
    box: *Box,

    /// The mouse is over this box and no box in front of it claimed the
    /// position.
    hovering: bool = false,
    /// The left button went down over it this frame.
    pressed: bool = false,
    /// The left button came up while this box held it, wherever the mouse was.
    released: bool = false,
    /// Pressed and released over the same box: the one that means "do it".
    clicked: bool = false,
    right_clicked: bool = false,
    middle_clicked: bool = false,
    double_clicked: bool = false,

    /// The left button is held on this box. True whether or not the mouse is
    /// still over it, which is what makes dragging work past the edge.
    dragging: bool = false,
    /// Movement since the press.
    drag_delta: Point = .origin,

    /// Wheel movement, in pixels, delivered to the innermost scrollable box
    /// under the mouse and to nothing else.
    scroll: Point = .origin,

    focused: bool = false,
    /// Text typed this frame, non-empty only when focused.
    text: []const u8 = "",

    pub fn isHot(s: Signal) bool {
        return s.hovering or s.dragging;
    }
};

// -- state ------------------------------------------------------------------

gpa: Allocator,
arena: std.heap.ArenaAllocator,
metrics: Metrics,

/// The persistent half. Keyed by the raw hash rather than by `Key`, because a
/// `u64` map needs no hashing of its own.
boxes: std.AutoHashMapUnmanaged(u64, *Box) = .empty,
stale: std.ArrayList(u64) = .empty,
focus_ring: std.ArrayList(Key) = .empty,

root: *Box = undefined,
viewport: Bounds = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 },

frame_index: u64 = 0,
time: f64 = 0,
dt: f32 = 0,

parents: [stack_depth]*Box = undefined,
parent_top: u32 = 0,
clips: [stack_depth]Bounds = undefined,
clip_top: u32 = 0,
styles: [stack_depth]Style = undefined,
style_top: u32 = 0,
pending: Next = .{},

in: Input = .{},
prev_buttons: input.Buttons = .{},
went_down: [input.button_count]bool = @splat(false),
went_up: [input.button_count]bool = @splat(false),
typed: []const u8 = "",

/// The box the mouse is over, resolved from last frame's build order so that
/// the last box to claim the position -- which is the one drawn on top -- wins.
hot: Key = .nil,
hot_next: Key = .nil,
/// Who holds each button, from press until release.
active: [input.button_count]Key = @splat(.nil),
press_pos: [input.button_count]Point = @splat(.origin),
focus: Key = .nil,

last_click_key: Key = .nil,
last_click_time: f64 = -1000,

building: bool = false,
overflows: u32 = 0,

pub fn init(gpa: Allocator, metrics: Metrics) UI {
    return .{ .gpa = gpa, .arena = .init(gpa), .metrics = metrics };
}

pub fn deinit(ui: *UI) void {
    var it = ui.boxes.valueIterator();
    while (it.next()) |b| ui.gpa.destroy(b.*);
    ui.boxes.deinit(ui.gpa);
    ui.stale.deinit(ui.gpa);
    ui.focus_ring.deinit(ui.gpa);
    ui.arena.deinit();
    ui.* = undefined;
}

// -- the frame --------------------------------------------------------------

pub fn begin(ui: *UI, viewport: Bounds, in: Input) Error!void {
    std.debug.assert(!ui.building);
    ui.building = true;
    ui.frame_index += 1;
    ui.dt = std.math.clamp(in.dt, 0, max_dt);
    ui.time += ui.dt;
    ui.viewport = viewport;

    // Frame-scoped strings die here: box labels, and the text typed this
    // frame. Nothing above holds a pointer into them past `end`.
    _ = ui.arena.reset(.retain_capacity);

    ui.in = in;
    for (0..input.button_count) |i| {
        const which: MouseButton = @enumFromInt(i);
        const down = in.buttons.isDown(which);
        const was = ui.prev_buttons.isDown(which);
        ui.went_down[i] = down and !was;
        ui.went_up[i] = was and !down;
    }
    ui.prev_buttons = in.buttons;
    ui.typed = try ui.collectText(in);

    // Hover was accumulated during the previous frame's build, where the order
    // of the calls said which box is in front. Resolving it here rather than
    // during the build is what makes "the last one to claim it wins" mean "the
    // one on top" rather than "the one built first".
    ui.hot = ui.hot_next;
    ui.hot_next = .nil;

    ui.parent_top = 0;
    ui.clip_top = 0;
    ui.clips[0] = viewport;
    ui.style_top = 0;
    ui.styles[0] = .{};
    ui.pending = .{};

    const root_key = key.make(.nil, "thviti.root");
    ui.root = try ui.acquire(root_key);
    ui.root.beginFrame(ui.frame_index);
    ui.root.style = ui.styles[0];
    ui.root.pref = .{ .px(viewport.width()), .px(viewport.height()) };
    ui.root.flags = .{ .clip = true };
    ui.root.clip_rect = viewport;
    ui.parents[0] = ui.root;
}

pub fn end(ui: *UI) void {
    std.debug.assert(ui.building);
    ui.building = false;

    // A button released anywhere ends its grab, including when it was released
    // over a different box or outside the window entirely. Done after the
    // build, so that the box holding it still saw `released` this frame.
    for (0..input.button_count) |i| {
        if (ui.went_up[i]) ui.active[i] = .nil;
    }

    ui.layout();
    ui.resolveHot();
    ui.animate(ui.root);
    ui.moveFocusIfAsked();
    ui.prune();
}

fn collectText(ui: *UI, in: Input) Error![]const u8 {
    var total: usize = 0;
    for (in.events) |e| switch (e) {
        .text => |t| total += t.len,
        else => {},
    };
    if (total == 0) return "";

    const buf = try ui.arena.allocator().alloc(u8, total);
    var n: usize = 0;
    for (in.events) |e| switch (e) {
        .text => |t| {
            @memcpy(buf[n..][0..t.len], t);
            n += t.len;
        },
        else => {},
    };
    return buf;
}

// -- stacks -----------------------------------------------------------------

pub fn parent(ui: *const UI) *Box {
    return ui.parents[ui.parent_top];
}

pub fn style(ui: *const UI) Style {
    return ui.styles[ui.style_top];
}

pub fn clip(ui: *const UI) Bounds {
    return ui.clips[ui.clip_top];
}

/// Merges `patch` onto the current style for a scope.
pub fn pushStyle(ui: *UI, patch: StylePatch) void {
    const merged = Box.applyPatch(ui.styles[ui.style_top], patch);
    if (ui.style_top + 1 >= stack_depth) {
        ui.overflows += 1;
        return;
    }
    ui.style_top += 1;
    ui.styles[ui.style_top] = merged;
}

pub fn popStyle(ui: *UI) void {
    if (ui.style_top > 0) ui.style_top -= 1;
}

/// Convenience for the commonest scope: a preferred size for everything
/// inside it.
pub fn pushSize(ui: *UI, w: Size, h: Size) void {
    ui.pushStyle(.{ .pref = .{ w, h } });
}

/// Overrides for the next box only, cleared as soon as one is built.
pub fn next(ui: *UI, n: Next) void {
    ui.pending = n;
}

/// Fills in what nobody has asked for yet: anything already set on the
/// pending override stays, and flags are merged rather than replaced.
///
/// This is what a widget uses. `button` needs its box to be clickable and to
/// draw its background, and has an opinion about its default size -- but a
/// caller who wrote `ui.next(.{ .w = .fill })` before calling it meant that,
/// and a widget that overwrote the pending override would silently discard it.
/// Every helper in `widgets.zig` goes through here for exactly that reason.
pub fn nextDefaults(ui: *UI, n: Next) void {
    inline for (@typeInfo(Next).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "flags")) {
            ui.pending.flags = ui.pending.flags.merge(n.flags);
        } else if (@field(ui.pending, name) == null) {
            @field(ui.pending, name) = @field(n, name);
        }
    }
}

pub fn pushParent(ui: *UI, b: *Box) void {
    if (ui.parent_top + 1 >= stack_depth) {
        ui.overflows += 1;
        return;
    }
    ui.parent_top += 1;
    ui.parents[ui.parent_top] = b;

    // The clip and the parent are pushed together because clipping is
    // inherited by descendants and by nothing else. It uses the box's
    // *previous* rectangle, which is what hit testing runs against anyway.
    if (b.flags.clip) {
        const narrowed = ui.clips[ui.clip_top].intersect(b.rect);
        if (ui.clip_top + 1 < stack_depth) {
            ui.clip_top += 1;
            ui.clips[ui.clip_top] = narrowed;
        } else {
            ui.overflows += 1;
        }
    }
}

pub fn popParent(ui: *UI) void {
    if (ui.parent_top == 0) return;
    if (ui.parents[ui.parent_top].flags.clip and ui.clip_top > 0) ui.clip_top -= 1;
    ui.parent_top -= 1;
}

// -- building ---------------------------------------------------------------

/// A box, keyed by `label` under the current parent. See `key.zig` for what
/// `##` and `###` do to that string.
pub fn box(ui: *UI, label: []const u8) Error!*Box {
    const parsed = key.parse(ui.parent().key, label);
    return ui.makeBox(parsed.key, parsed.display);
}

/// `box` with a formatted label. The formatted string is the key too, so a
/// list built with the index in the label gets one box per row -- which is
/// what is wanted, and is the reason this exists rather than being left to the
/// caller and a stack buffer.
pub fn boxf(ui: *UI, comptime fmt: []const u8, args: anytype) Error!*Box {
    const text = try std.fmt.allocPrint(ui.arena.allocator(), fmt, args);
    const parsed = key.parse(ui.parent().key, text);
    return ui.makeBox(parsed.key, parsed.display);
}

/// A box whose display text and key are given separately.
///
/// `box` and `boxf` take one string and split it on `###`, which is right for
/// a label the caller wrote and wrong for text the caller did not write: a
/// search field holding `a###b` would split on the user's own hashes, key on
/// `b`, and draw half the query. Anything that shows text from outside the
/// program -- a field, a search result, a document's title -- uses this.
pub fn boxText(ui: *UI, name: []const u8, text: []const u8) Error!*Box {
    return ui.makeBox(key.make(ui.parent().key, name), text);
}

/// A box that becomes the parent for everything up to the matching `close`.
pub fn open(ui: *UI, label: []const u8) Error!*Box {
    const b = try ui.box(label);
    ui.pushParent(b);
    return b;
}

pub fn close(ui: *UI, b: *Box) void {
    std.debug.assert(ui.parents[ui.parent_top] == b);
    ui.popParent();
}

fn makeBox(ui: *UI, k: Key, display: []const u8) Error!*Box {
    const b = try ui.acquire(k);
    b.beginFrame(ui.frame_index);

    const base = ui.styles[ui.style_top];
    const n = ui.pending;
    ui.pending = .{};

    b.style = Box.applyPatch(base, .{
        .bg = n.bg,
        .fg = n.fg,
        .border_color = n.border_color,
        .shadow_color = n.shadow_color,
        .radius = n.radius,
        .border = n.border,
        .shadow = n.shadow,
        .hot_lift = n.hot_lift,
        .active_lift = n.active_lift,
        .disabled_fade = n.disabled_fade,
        .font = n.font,
        .font_size = n.font_size,
        .text_align = n.text_align,
        .child_align = n.child_align,
        .axis = n.axis,
    });
    b.flags = n.flags;
    b.pref = .{ n.w orelse base.pref[0], n.h orelse base.pref[1] };
    b.fixed = .{ n.fixed_x orelse 0, n.fixed_y orelse 0 };
    b.clip_rect = ui.clips[ui.clip_top];

    if (display.len > 0) {
        b.text = try ui.arena.allocator().dupe(u8, display);
        // Measured only when something will read it, because a label that is
        // neither drawn nor sized by its text is a key and nothing more.
        if (b.flags.draw_text or b.pref[0].kind == .text or b.pref[1].kind == .text) {
            const e = try ui.metrics.measure(b.text, b.style.font, b.style.font_size);
            b.text_size = .{ e.x, e.y };
        }
    }

    ui.attach(b);
    return b;
}

fn acquire(ui: *UI, k: Key) Error!*Box {
    // A keyless box is pure structure -- a row, a spacer, a container -- and
    // has nothing worth remembering, so it comes from the frame arena and
    // disappears with it. That is most of a tree, and it keeps the persistent
    // table down to the boxes that actually hold state.
    if (k.isNil()) {
        const b = try ui.arena.allocator().create(Box);
        b.* = .{ .key = .nil, .first_frame = ui.frame_index };
        return b;
    }

    const gop = try ui.boxes.getOrPut(ui.gpa, @intFromEnum(k));
    if (!gop.found_existing) {
        const b = ui.gpa.create(Box) catch |err| {
            _ = ui.boxes.remove(@intFromEnum(k));
            return err;
        };
        b.* = .{ .key = k, .first_frame = ui.frame_index };
        gop.value_ptr.* = b;
    }
    return gop.value_ptr.*;
}

fn attach(ui: *UI, b: *Box) void {
    if (b == ui.root) return;
    const p = ui.parent();
    b.parent = p;
    if (p.last) |last| {
        last.next = b;
        b.prev = last;
        p.last = b;
    } else {
        p.first = b;
        p.last = b;
    }
    p.child_count += 1;
}

// -- interaction ------------------------------------------------------------

/// What happened to `b`, judged against the rectangle it had last frame.
pub fn signal(ui: *UI, b: *Box) Signal {
    var s: Signal = .{ .box = b };
    if (b.flags.disabled) return s;

    const takes_mouse = b.flags.clickable or b.flags.scrollable;
    const m = ui.in.mouse;
    const inside = takes_mouse and b.rect.contains(m) and b.clip_rect.contains(m);

    // A keyless box cannot take part in the arbitration -- there is nothing to
    // record as hot -- so it answers from the geometry alone. Anything that
    // overlaps other clickable boxes wants a key.
    s.hovering = if (b.key.isNil()) inside else inside and ui.hot == b.key;

    if (b.flags.clickable) ui.mouseSignals(b, &s, inside, m);

    if (b.flags.scrollable and s.hovering) s.scroll = ui.in.scroll;

    if (b.flags.focusable and !b.key.isNil()) {
        s.focused = ui.focus == b.key;
        if (s.focused) s.text = ui.typed;
    }

    return s;
}

fn mouseSignals(ui: *UI, b: *Box, s: *Signal, inside: bool, m: Point) void {
    for (0..input.button_count) |i| {
        if (ui.went_down[i] and s.hovering) {
            ui.active[i] = b.key;
            ui.press_pos[i] = m;
            if (i == 0) {
                s.pressed = true;
                if (b.flags.focusable) ui.focus = b.key;
            }
        }

        // Recomputed after the press, so that the frame a button goes down is
        // also a frame it is being dragged. A drag that only began on the
        // *next* frame would lose the first few pixels of every gesture.
        const held = !b.key.isNil() and ui.active[i] == b.key;
        if (!held) continue;

        if (i == 0) {
            // Dragging follows the mouse outside the box, which is what makes
            // a scrollbar thumb usable: releasing the pointer over the
            // document should not drop the drag.
            s.dragging = true;
            s.drag_delta = .{ .x = m.x - ui.press_pos[i].x, .y = m.y - ui.press_pos[i].y };
        }

        if (!ui.went_up[i]) continue;
        if (i == 0) s.released = true;
        if (!inside) continue;

        switch (i) {
            0 => {
                s.clicked = true;
                if (ui.last_click_key == b.key and ui.time - ui.last_click_time <= double_click_seconds) {
                    s.double_clicked = true;
                    // Consumed, so that a third click is a fresh single rather
                    // than a second double.
                    ui.last_click_time = -1000;
                } else {
                    ui.last_click_key = b.key;
                    ui.last_click_time = ui.time;
                }
            },
            1 => s.right_clicked = true,
            else => s.middle_clicked = true,
        }
    }
}

/// Decides which box the mouse is over, for the *next* frame's signals.
///
/// Run after layout rather than during the build, which is the difference
/// between a one-frame answer and a two-frame one. During the build a box
/// knows only the rectangle it had last frame, and a box created this frame
/// has none at all; here every rectangle is this frame's, so a control that
/// appears is interactive on the very next frame.
///
/// Depth first in build order, last match wins. That is the same order the
/// renderer draws in, which is what makes "the box on top" and "the box that
/// gets the mouse" the same box without either of them sorting anything.
fn resolveHot(ui: *UI) void {
    ui.hot_next = .nil;
    ui.hotWalk(ui.root, ui.viewport);
}

fn hotWalk(ui: *UI, b: *Box, clip_in: Bounds) void {
    const takes = (b.flags.clickable or b.flags.scrollable) and
        !b.flags.disabled and !b.key.isNil();
    if (takes and b.rect.contains(ui.in.mouse) and clip_in.contains(ui.in.mouse)) {
        ui.hot_next = b.key;
    }

    // A box's own clip applies to its children, not to itself: a scroll view
    // is hit-testable over its whole area even though its rows are not.
    const inner = if (b.flags.clip) clip_in.intersect(b.rect) else clip_in;
    var it = b.children();
    while (it.next()) |c| ui.hotWalk(c, inner);
}

pub fn setFocus(ui: *UI, k: Key) void {
    ui.focus = k;
}

pub fn isActive(ui: *const UI, k: Key) bool {
    if (k.isNil()) return false;
    for (ui.active) |a| {
        if (a == k) return true;
    }
    return false;
}

/// Tab and shift-tab, resolved after the build because the ring is the tree in
/// build order and the tree is not finished until then.
fn moveFocusIfAsked(ui: *UI) void {
    if (!ui.in.pressedOnce(.tab)) return;

    ui.focus_ring.clearRetainingCapacity();
    collectFocusable(ui.root, &ui.focus_ring, ui.gpa) catch return;
    const ring = ui.focus_ring.items;
    if (ring.len == 0) return;

    const back = ui.in.modifiers.shift;
    const at = std.mem.indexOfScalar(Key, ring, ui.focus);
    if (at) |i| {
        const n = ring.len;
        ui.focus = if (back) ring[(i + n - 1) % n] else ring[(i + 1) % n];
    } else {
        ui.focus = if (back) ring[ring.len - 1] else ring[0];
    }
}

fn collectFocusable(b: *Box, out: *std.ArrayList(Key), gpa: Allocator) Error!void {
    if (b.flags.focusable and !b.flags.disabled and !b.key.isNil()) try out.append(gpa, b.key);
    var it = b.children();
    while (it.next()) |c| try collectFocusable(c, out, gpa);
}

// -- layout -----------------------------------------------------------------

fn layout(ui: *UI) void {
    ui.root.pos = .{ ui.viewport.min_x, ui.viewport.min_y };

    for ([_]Axis{ .x, .y }) |axis| {
        sizeStandalone(ui.root, axis);
        sizeUpward(ui.root, axis);
        sizeDownward(ui.root, axis);
        solveViolations(ui.root, axis);
        positions(ui.root, axis);
    }

    finishRects(ui.root);
}

/// Pass 1. Sizes that depend on nothing else in the tree.
fn sizeStandalone(b: *Box, axis: Axis) void {
    const i = axis.index();
    switch (b.pref[i].kind) {
        .none => b.size[i] = 0,
        .pixels => b.size[i] = b.pref[i].value,
        // The padding is doubled because it is per side; a label with four
        // pixels of padding is eight wider than its text.
        .text => b.size[i] = b.text_size[i] + b.pref[i].value * 2,
        .percent_of_parent, .children_sum => {},
    }
    var it = b.children();
    while (it.next()) |c| sizeStandalone(c, axis);
}

/// Pass 2, pre-order. A percentage is of the nearest ancestor whose own size
/// is already settled -- which is any kind but `children_sum`, since that one
/// is not known until pass 3 and taking a percentage of it would be circular.
fn sizeUpward(b: *Box, axis: Axis) void {
    const i = axis.index();
    if (b.pref[i].kind == .percent_of_parent) {
        var reference: ?*Box = null;
        var p = b.parent;
        while (p) |a| : (p = a.parent) {
            switch (a.pref[i].kind) {
                .pixels, .text, .percent_of_parent => {
                    reference = a;
                    break;
                },
                .none, .children_sum => {},
            }
        }
        // The root is always pixels, so the only way to reach zero here is to
        // be the root, which never asks for a percentage.
        b.size[i] = if (reference) |r| r.size[i] * b.pref[i].value else 0;
    }
    var it = b.children();
    while (it.next()) |c| sizeUpward(c, axis);
}

/// Pass 3, post-order. A container is as big as what it contains: the sum
/// along the axis it stacks on, the largest across it.
fn sizeDownward(b: *Box, axis: Axis) void {
    var it = b.children();
    while (it.next()) |c| sizeDownward(c, axis);

    const i = axis.index();
    if (b.pref[i].kind != .children_sum) return;

    var total: f32 = 0;
    var kids = b.children();
    while (kids.next()) |c| {
        // A floating child is positioned by hand and is not part of the flow,
        // so counting it would make a tooltip enlarge the panel under it.
        if (c.flags.floating(axis)) continue;
        if (axis == b.style.axis) total += c.size[i] else total = @max(total, c.size[i]);
    }
    b.size[i] = total;
}

/// Pass 4, pre-order. Where the children of a box do not fit inside it, take
/// the difference out of them.
///
/// The rule is proportional to what each child is *willing* to give up, not to
/// how big it is: a strict box gives nothing however large, and two equally
/// loose boxes give equally. That is what makes the result independent of the
/// order the children happened to be built in, which a first-come-first-served
/// rule would not be.
fn solveViolations(b: *Box, axis: Axis) void {
    const i = axis.index();

    if (b.child_count > 0 and !b.flags.overflows(axis)) {
        if (axis == b.style.axis) {
            var total: f32 = 0;
            var budget: f32 = 0;
            var it = b.children();
            while (it.next()) |c| {
                if (c.flags.floating(axis)) continue;
                total += c.size[i];
                budget += c.size[i] * (1 - c.pref[i].strictness);
            }

            const violation = total - b.size[i];
            if (violation > 0 and budget > 0) {
                const taken = @min(violation, budget);
                var kids = b.children();
                while (kids.next()) |c| {
                    if (c.flags.floating(axis)) continue;
                    const give = c.size[i] * (1 - c.pref[i].strictness);
                    c.size[i] -= taken * (give / budget);
                }
            }
        } else {
            // Across the layout axis the children do not compete: each one
            // either fits its parent or is cut down to it on its own.
            var it = b.children();
            while (it.next()) |c| {
                if (c.flags.floating(axis)) continue;
                const excess = c.size[i] - b.size[i];
                if (excess <= 0) continue;
                const give = c.size[i] * (1 - c.pref[i].strictness);
                c.size[i] -= std.math.clamp(excess, 0, give);
            }
        }
    }

    var it = b.children();
    while (it.next()) |c| solveViolations(c, axis);
}

/// Pass 5, pre-order. Relative offsets become absolute positions, with the
/// parent's scroll subtracted on the way.
fn positions(b: *Box, axis: Axis) void {
    const i = axis.index();
    var pen: f32 = 0;

    var it = b.children();
    while (it.next()) |c| {
        if (c.flags.floating(axis)) {
            c.rel_pos[i] = c.fixed[i];
        } else if (axis == b.style.axis) {
            c.rel_pos[i] = pen;
            pen += c.size[i];
        } else {
            c.rel_pos[i] = switch (b.style.child_align) {
                .start => 0,
                .center => (b.size[i] - c.size[i]) * 0.5,
                .end => b.size[i] - c.size[i],
            };
        }

        // Scrolling moves the flow and leaves floating children alone, which
        // is what makes a header pinned inside a scroll view possible.
        const scrolled = if (c.flags.floating(axis)) 0 else b.view_off[i];
        c.pos[i] = b.pos[i] + c.rel_pos[i] - scrolled;
    }

    var kids = b.children();
    while (kids.next()) |c| positions(c, axis);
}

fn finishRects(b: *Box) void {
    b.rect = .{
        .min_x = b.pos[0],
        .min_y = b.pos[1],
        .max_x = b.pos[0] + b.size[0],
        .max_y = b.pos[1] + b.size[1],
    };
    var it = b.children();
    while (it.next()) |c| finishRects(c);
}

fn animate(ui: *UI, b: *Box) void {
    const blend = 1 - @exp(-ui.dt * animation_rate);
    const scroll_blend = 1 - @exp(-ui.dt * scroll_rate);

    const hot_target: f32 = if (!b.key.isNil() and ui.hot_next == b.key) 1 else 0;
    const active_target: f32 = if (ui.isActive(b.key)) 1 else 0;
    const disabled_target: f32 = if (b.flags.disabled) 1 else 0;

    // A box that did not ask for animation snaps, so that the same field can
    // be read unconditionally by the drawing code.
    b.hot_t = if (b.flags.hot_animation) b.hot_t + (hot_target - b.hot_t) * blend else hot_target;
    b.active_t = if (b.flags.active_animation) b.active_t + (active_target - b.active_t) * blend else active_target;
    b.disabled_t += (disabled_target - b.disabled_t) * blend;

    for (0..2) |i| {
        b.view_off[i] += (b.view_off_target[i] - b.view_off[i]) * scroll_blend;
        // Below a twentieth of a pixel the difference cannot be drawn, and
        // leaving it means every scroll view redraws for ever.
        if (@abs(b.view_off_target[i] - b.view_off[i]) < 0.05) b.view_off[i] = b.view_off_target[i];
    }

    var it = b.children();
    while (it.next()) |c| ui.animate(c);
}

/// Drops boxes no call site has asked for in a while.
///
/// Best-effort: if the list of victims cannot be grown, they are left for the
/// next frame. Failing to free memory is not a reason to fail a frame.
fn prune(ui: *UI) void {
    ui.stale.clearRetainingCapacity();
    var it = ui.boxes.iterator();
    while (it.next()) |e| {
        if (ui.frame_index -| e.value_ptr.*.last_frame > prune_after) {
            ui.stale.append(ui.gpa, e.key_ptr.*) catch break;
        }
    }
    for (ui.stale.items) |k| {
        if (ui.boxes.fetchRemove(k)) |removed| {
            if (ui.focus == @as(Key, @enumFromInt(k))) ui.focus = .nil;
            ui.gpa.destroy(removed.value);
        }
    }
}

// -- reading it back --------------------------------------------------------

pub fn boxCount(ui: *const UI) u32 {
    return ui.boxes.count();
}

pub fn find(ui: *const UI, k: Key) ?*Box {
    if (k.isNil()) return null;
    return ui.boxes.get(@intFromEnum(k));
}

/// Depth-first, in build order, which is also draw order.
pub fn walk(b: *Box, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Box, u32) void) void {
    walkAt(b, ctx, f, 0);
}

fn walkAt(b: *Box, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Box, u32) void, depth: u32) void {
    f(ctx, b, depth);
    var it = b.children();
    while (it.next()) |c| walkAt(c, ctx, f, depth + 1);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn scratch() UI {
    return .init(testing.allocator, fixed_metrics);
}

fn frame(ui: *UI, in: Input) !void {
    try ui.begin(.fromRect(0, 0, 400, 300), in);
}

test "a frame builds a tree under a root the size of the viewport" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    ui.next(.{ .w = .px(100), .h = .px(50) });
    _ = try ui.box("a");
    ui.end();

    try testing.expectEqual(Bounds.fromRect(0, 0, 400, 300), ui.root.rect);
    try testing.expectEqual(@as(u32, 1), ui.root.child_count);
    try testing.expectEqual(Bounds.fromRect(0, 0, 100, 50), ui.root.first.?.rect);
}

test "pixels, text, percent and sum all resolve in one pass" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        // A column as tall as its children, containing a fixed bar, a label
        // sized by its text, and a pane taking half the root's width.
        ui.next(.{ .w = .px(400), .h = .children, .axis = .y });
        const col = try ui.open("column");
        defer ui.close(col);

        ui.next(.{ .w = .fill, .h = .px(30) });
        _ = try ui.box("bar");

        // Six characters at fourteen pixels: half an em each is 42, plus four
        // pixels of padding on each side.
        ui.next(.{ .w = .text(4), .h = .px(20), .flags = .{ .draw_text = true } });
        _ = try ui.box("Fenrir");

        ui.next(.{ .w = .percent(0.5), .h = .px(10) });
        _ = try ui.box("pane");
    }
    ui.end();

    const col = ui.root.first.?;
    const bar = col.first.?;
    const label = bar.next.?;
    const pane = label.next.?;

    try testing.expectEqual(@as(f32, 400), bar.size[0]);
    try testing.expectApproxEqAbs(@as(f32, 6 * 7 + 8), label.size[0], 1e-4);
    try testing.expectEqual(@as(f32, 200), pane.size[0]);
    // The column is as tall as the three of them stacked.
    try testing.expectEqual(@as(f32, 60), col.size[1]);
}

test "children stack along the layout axis and share the other one" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(300), .h = .px(40), .axis = .x });
        const row = try ui.open("row");
        defer ui.close(row);

        ui.pushSize(.px(100), .fill);
        defer ui.popStyle();
        _ = try ui.box("one");
        _ = try ui.box("two");
        _ = try ui.box("three");
    }
    ui.end();

    const row = ui.root.first.?;
    var x: f32 = 0;
    var it = row.children();
    while (it.next()) |c| {
        try testing.expectEqual(x, c.rect.min_x);
        try testing.expectEqual(@as(f32, 40), c.size[1]);
        x += 100;
    }
    try testing.expectEqual(@as(f32, 300), x);
}

test "a shortfall is taken from what each child will give, not from its size" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(100), .h = .px(20), .axis = .x });
        const row = try ui.open("row");
        defer ui.close(row);

        // 200 pixels of children in a 100 pixel row. The strict one keeps
        // every pixel and the loose one absorbs the whole violation.
        ui.next(.{ .w = .px(100), .h = .fill });
        _ = try ui.box("strict");
        ui.next(.{ .w = .pxLoose(100, 0), .h = .fill });
        _ = try ui.box("loose");
    }
    ui.end();

    const row = ui.root.first.?;
    try testing.expectEqual(@as(f32, 100), row.first.?.size[0]);
    try testing.expectEqual(@as(f32, 0), row.last.?.size[0]);
}

test "two equally loose children give equally, whatever order they were built" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(100), .h = .px(20), .axis = .x });
        const row = try ui.open("row");
        defer ui.close(row);

        ui.pushSize(.pxLoose(80, 0.5), .fill);
        defer ui.popStyle();
        _ = try ui.box("a");
        _ = try ui.box("b");
    }
    ui.end();

    const row = ui.root.first.?;
    // 160 wanted, 100 available: 60 of violation over 80 of total budget,
    // taken half from each.
    try testing.expectApproxEqAbs(@as(f32, 50), row.first.?.size[0], 1e-3);
    try testing.expectApproxEqAbs(row.first.?.size[0], row.last.?.size[0], 1e-4);
}

test "overflow excuses a box from being squeezed, which is what scrolling needs" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(100), .h = .px(100), .axis = .y, .flags = .{ .overflow_y = true, .clip = true } });
        const view = try ui.open("view");
        defer ui.close(view);

        ui.pushSize(.fill, .pxLoose(40, 0));
        defer ui.popStyle();
        var i: u32 = 0;
        while (i < 10) : (i += 1) _ = try ui.boxf("row {d}", .{i});
    }
    ui.end();

    const view = ui.root.first.?;
    // Four hundred pixels of rows in a hundred pixel view, kept at full size.
    var it = view.children();
    while (it.next()) |c| try testing.expectEqual(@as(f32, 40), c.size[1]);
    try testing.expectEqual(@as(f32, 360), view.last.?.rel_pos[1]);
}

test "scrolling moves the flow and leaves floating children alone" {
    var ui = scratch();
    defer ui.deinit();

    // Two frames: the offset is applied by the second, after `animate` has
    // moved `view_off` towards its target.
    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(100), .h = .px(100), .flags = .{ .overflow_y = true } });
        const view = try ui.open("view");
        defer ui.close(view);
        ui.next(.{ .w = .fill, .h = .px(40) });
        _ = try ui.box("row");
        ui.next(.{ .w = .fill, .h = .px(20), .flags = .{ .floating_y = true }, .fixed_y = 5 });
        _ = try ui.box("pinned");
    }
    ui.end();

    const view = ui.find(key.make(ui.root.key, "view")).?;
    view.view_off = .{ 0, 30 };
    view.view_off_target = .{ 0, 30 };

    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(100), .h = .px(100), .flags = .{ .overflow_y = true } });
        const v = try ui.open("view");
        defer ui.close(v);
        ui.next(.{ .w = .fill, .h = .px(40) });
        _ = try ui.box("row");
        ui.next(.{ .w = .fill, .h = .px(20), .flags = .{ .floating_y = true }, .fixed_y = 5 });
        _ = try ui.box("pinned");
    }
    ui.end();

    try testing.expectEqual(@as(f32, -30), view.first.?.rect.min_y);
    try testing.expectEqual(@as(f32, 5), view.last.?.rect.min_y);
}

test "a box keeps its state across frames and a keyless one does not exist between them" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    ui.next(.{ .w = .px(10), .h = .px(10) });
    const first = try ui.box("keeper");
    _ = try ui.box("");
    ui.end();

    first.view_off_target = .{ 0, 77 };
    const before = ui.boxCount();

    try frame(&ui, .{});
    ui.next(.{ .w = .px(10), .h = .px(10) });
    const again = try ui.box("keeper");
    _ = try ui.box("");
    ui.end();

    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(f32, 77), again.view_off_target[1]);
    // The keyless box never entered the table, so the count did not move.
    try testing.expectEqual(before, ui.boxCount());
}

test "a box nobody asks for is dropped, after a grace period" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    ui.next(.{ .w = .px(10), .h = .px(10) });
    _ = try ui.box("transient");
    ui.end();
    try testing.expectEqual(@as(u32, 2), ui.boxCount()); // root and it

    var n: u64 = 0;
    while (n <= prune_after) : (n += 1) {
        try frame(&ui, .{});
        ui.end();
    }
    // The root is still asked for every frame; the other is not.
    try testing.expectEqual(@as(u32, 1), ui.boxCount());
}

test "hovering, pressing, and clicking follow the mouse over the rectangle" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !Signal {
            u.next(.{ .w = .px(100), .h = .px(40), .flags = .{ .clickable = true } });
            const b = try u.box("Open");
            return u.signal(b);
        }
    }.go;

    // Frame one: the box has no rectangle yet, so nothing can be over it.
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 } });
    var s = try build(&ui);
    ui.end();
    try testing.expect(!s.hovering);

    // Frame two: it has one, and nothing else claimed the position.
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 } });
    s = try build(&ui);
    ui.end();
    try testing.expect(s.hovering);
    try testing.expect(!s.pressed);

    // Press.
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 }, .buttons = .{ .left = true } });
    s = try build(&ui);
    ui.end();
    try testing.expect(s.pressed and s.dragging and !s.clicked);

    // Release over the same box is a click.
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 } });
    s = try build(&ui);
    ui.end();
    try testing.expect(s.released and s.clicked);
}

test "a press that wanders off and comes up elsewhere is not a click" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !Signal {
            u.next(.{ .w = .px(100), .h = .px(40), .flags = .{ .clickable = true } });
            const b = try u.box("Open");
            return u.signal(b);
        }
    }.go;

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 } });
    _ = try build(&ui);
    ui.end();

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 }, .buttons = .{ .left = true } });
    _ = try build(&ui);
    ui.end();

    // Still held, now outside: dragging continues, which is what a scrollbar
    // thumb needs.
    try frame(&ui, .{ .mouse = .{ .x = 300, .y = 200 }, .buttons = .{ .left = true } });
    var s = try build(&ui);
    ui.end();
    try testing.expect(s.dragging and !s.hovering);
    try testing.expectApproxEqAbs(@as(f32, 250), s.drag_delta.x, 1e-4);

    try frame(&ui, .{ .mouse = .{ .x = 300, .y = 200 } });
    s = try build(&ui);
    ui.end();
    try testing.expect(s.released and !s.clicked);
}

test "the box built last is the one the mouse is over" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) ![2]Signal {
            u.next(.{ .w = .px(200), .h = .px(200), .flags = .{ .clickable = true, .floating_x = true, .floating_y = true } });
            const back = try u.box("behind");
            const a = u.signal(back);

            u.next(.{ .w = .px(200), .h = .px(200), .flags = .{ .clickable = true, .floating_x = true, .floating_y = true } });
            const front = try u.box("in front");
            const b = u.signal(front);
            return .{ a, b };
        }
    }.go;

    try frame(&ui, .{ .mouse = .{ .x = 100, .y = 100 } });
    _ = try build(&ui);
    ui.end();

    try frame(&ui, .{ .mouse = .{ .x = 100, .y = 100 } });
    const s = try build(&ui);
    ui.end();

    // They overlap exactly; the later call site is drawn on top and so is the
    // one that gets the mouse.
    try testing.expect(!s[0].hovering);
    try testing.expect(s[1].hovering);
}

test "a clip stops the mouse reaching what is scrolled out of view" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !Signal {
            u.next(.{ .w = .px(100), .h = .px(50), .flags = .{ .clip = true, .overflow_y = true } });
            const view = try u.open("view");
            defer u.close(view);

            u.next(.{ .w = .fill, .h = .px(40), .flags = .{ .clickable = true } });
            const row = try u.box("row 0");
            u.next(.{ .w = .fill, .h = .px(40), .flags = .{ .clickable = true } });
            const below = try u.box("row 1");
            _ = u.signal(row);
            return u.signal(below);
        }
    }.go;

    // The second row sits from y=40 to y=80, and the view ends at 50. A mouse
    // at y=70 is over the row's rectangle and outside the clip.
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 70 } });
    _ = try build(&ui);
    ui.end();

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 70 } });
    const s = try build(&ui);
    ui.end();
    try testing.expect(!s.hovering);
}

test "the wheel reaches the innermost scrollable box and no other" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) ![2]Signal {
            u.next(.{ .w = .px(200), .h = .px(200), .flags = .{ .scrollable = true } });
            const outer = try u.open("outer");
            defer u.close(outer);

            u.next(.{ .w = .px(100), .h = .px(100), .flags = .{ .scrollable = true } });
            const inner = try u.box("inner");

            return .{ u.signal(outer), u.signal(inner) };
        }
    }.go;

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 50 } });
    _ = try build(&ui);
    ui.end();

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 50 }, .scroll = .{ .x = 0, .y = -120 } });
    const s = try build(&ui);
    ui.end();

    try testing.expectEqual(@as(f32, 0), s[0].scroll.y);
    try testing.expectEqual(@as(f32, -120), s[1].scroll.y);
}

test "two clicks in quick succession are a double click, and three are not four" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !Signal {
            u.next(.{ .w = .px(100), .h = .px(40), .flags = .{ .clickable = true } });
            return u.signal(try u.box("target"));
        }
    }.go;

    const over: Point = .{ .x = 50, .y = 20 };
    try frame(&ui, .{ .mouse = over });
    _ = try build(&ui);
    ui.end();

    var doubles: u32 = 0;
    var singles: u32 = 0;
    var n: u32 = 0;
    while (n < 3) : (n += 1) {
        try frame(&ui, .{ .mouse = over, .buttons = .{ .left = true } });
        _ = try build(&ui);
        ui.end();

        try frame(&ui, .{ .mouse = over });
        const s = try build(&ui);
        ui.end();
        if (s.double_clicked) doubles += 1;
        if (s.clicked) singles += 1;
    }

    try testing.expectEqual(@as(u32, 3), singles);
    // Click, double, then a fresh single -- not a second double, which would
    // make a triple click open two things.
    try testing.expectEqual(@as(u32, 1), doubles);
}

test "tab walks the focusable boxes in build order and wraps" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !void {
            u.pushSize(.px(50), .px(20));
            defer u.popStyle();
            u.next(.{ .flags = .{ .focusable = true } });
            _ = try u.box("first");
            u.next(.{ .flags = .{ .focusable = true } });
            _ = try u.box("second");
            // Not focusable: skipped entirely rather than being a dead stop.
            _ = try u.box("scenery");
        }
    }.go;

    const tab = [_]input.Event{.{ .key_down = .{ .code = .tab } }};

    try frame(&ui, .{});
    try build(&ui);
    ui.end();
    try testing.expect(ui.focus.isNil());

    try frame(&ui, .{ .events = &tab });
    try build(&ui);
    ui.end();
    try testing.expectEqual(key.make(ui.root.key, "first"), ui.focus);

    try frame(&ui, .{ .events = &tab });
    try build(&ui);
    ui.end();
    try testing.expectEqual(key.make(ui.root.key, "second"), ui.focus);

    // Wraps rather than stopping.
    try frame(&ui, .{ .events = &tab });
    try build(&ui);
    ui.end();
    try testing.expectEqual(key.make(ui.root.key, "first"), ui.focus);
}

test "typed text reaches the focused box and nothing else" {
    var ui = scratch();
    defer ui.deinit();

    const events = [_]input.Event{.{ .text = "hi" }};

    try frame(&ui, .{});
    ui.pushSize(.px(50), .px(20));
    ui.next(.{ .flags = .{ .focusable = true } });
    const field = try ui.box("field");
    ui.next(.{ .flags = .{ .focusable = true } });
    const other = try ui.box("other");
    ui.popStyle();
    ui.end();

    ui.setFocus(field.key);

    try frame(&ui, .{ .events = &events });
    ui.pushSize(.px(50), .px(20));
    ui.next(.{ .flags = .{ .focusable = true } });
    const s = ui.signal(try ui.box("field"));
    ui.next(.{ .flags = .{ .focusable = true } });
    const t = ui.signal(try ui.box("other"));
    ui.popStyle();
    ui.end();

    _ = other;
    try testing.expect(s.focused);
    try testing.expectEqualStrings("hi", s.text);
    try testing.expect(!t.focused);
    try testing.expectEqualStrings("", t.text);
}

test "animation approaches its target at a rate the frame time cannot change" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !*Box {
            u.next(.{
                .w = .px(100),
                .h = .px(40),
                .flags = .{ .clickable = true, .hot_animation = true },
            });
            const b = try u.box("Open");
            _ = u.signal(b);
            return b;
        }
    }.go;

    // Fifty milliseconds of hover, covered in one step and in five. Both runs
    // start from zero, and the step stays under `max_dt` so the clamp does not
    // quietly shorten one of them.
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 } });
    const b = try build(&ui);
    ui.end();

    b.hot_t = 0;
    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 }, .dt = 0.05 });
    _ = try build(&ui);
    ui.end();
    const after_one = b.hot_t;

    b.hot_t = 0;
    var n: u32 = 0;
    while (n < 5) : (n += 1) {
        try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 }, .dt = 0.01 });
        _ = try build(&ui);
        ui.end();
    }

    // The property: `1 - exp(-dt * rate)` composes, so the same wall-clock
    // time produces the same value whatever the frame rate was. A fixed
    // fraction per frame -- the usual shortcut -- would not, and the same UI
    // would animate at twice the speed on a 144 hertz display.
    try testing.expectApproxEqAbs(after_one, b.hot_t, 1e-3);
    try testing.expect(after_one > 0.5 and after_one < 1.0);
}

test "an enormous frame time does not make every animation jump" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{ .dt = 4.0 });
    ui.end();
    try testing.expectEqual(max_dt, ui.dt);
}

test "overflowing a stack keeps the pairing rather than corrupting the rest" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    var n: u32 = 0;
    while (n < stack_depth + 8) : (n += 1) ui.pushStyle(.{ .font_size = 20 });
    try testing.expect(ui.overflows > 0);
    n = 0;
    while (n < stack_depth + 8) : (n += 1) ui.popStyle();
    try testing.expectEqual(@as(u32, 0), ui.style_top);
    try testing.expectEqual(@as(f32, 14), ui.style().font_size);
    ui.end();
}

test "a style scope changes what it names and restores on the way out" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        ui.pushStyle(.{ .font_size = 22 });
        defer ui.popStyle();
        ui.next(.{ .w = .px(10), .h = .px(10) });
        const inner = try ui.box("inner");
        try testing.expectEqual(@as(f32, 22), inner.style.font_size);
        // Untouched fields come through the scope unchanged.
        try testing.expectEqual((Style{}).fg, inner.style.fg);
    }
    ui.next(.{ .w = .px(10), .h = .px(10) });
    const outer = try ui.box("outer");
    try testing.expectEqual(@as(f32, 14), outer.style.font_size);
    ui.end();
}

test "a one-shot override applies once and does not leak to the next box" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    ui.pushSize(.px(10), .px(10));
    defer ui.popStyle();

    ui.next(.{ .font_size = 30, .flags = .{ .draw_border = true } });
    const a = try ui.box("a");
    const b = try ui.box("b");
    ui.end();

    try testing.expectEqual(@as(f32, 30), a.style.font_size);
    try testing.expect(a.flags.draw_border);
    // The classic immediate-mode bug this guards against: a colour set for one
    // button that quietly applies to the next forty.
    try testing.expectEqual(@as(f32, 14), b.style.font_size);
    try testing.expect(!b.flags.draw_border);
}

test "the same label under two parents is two boxes with separate state" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    ui.pushSize(.px(50), .px(20));
    defer ui.popStyle();

    const left = try ui.open("left");
    const a = try ui.box("Open");
    ui.close(left);

    const right = try ui.open("right");
    const b = try ui.box("Open");
    ui.close(right);
    ui.end();

    try testing.expect(a != b);
    try testing.expect(a.key != b.key);
}

test "child alignment centres across the layout axis" {
    var ui = scratch();
    defer ui.deinit();

    try frame(&ui, .{});
    {
        ui.next(.{ .w = .px(200), .h = .px(100), .axis = .y, .child_align = .center });
        const col = try ui.open("col");
        defer ui.close(col);
        ui.next(.{ .w = .px(50), .h = .px(20) });
        _ = try ui.box("centred");
    }
    ui.end();

    try testing.expectEqual(@as(f32, 75), ui.root.first.?.first.?.rect.min_x);
}

test "a disabled box takes no input at all" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !Signal {
            u.next(.{ .w = .px(100), .h = .px(40), .flags = .{ .clickable = true, .disabled = true } });
            return u.signal(try u.box("Open"));
        }
    }.go;

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 } });
    _ = try build(&ui);
    ui.end();

    try frame(&ui, .{ .mouse = .{ .x = 50, .y = 20 }, .buttons = .{ .left = true } });
    const s = try build(&ui);
    ui.end();
    try testing.expect(!s.hovering and !s.pressed);
}

test "boxText keys on its name and not on the text it is showing" {
    var ui: UI = .init(testing.allocator, fixed_metrics);
    defer ui.deinit();

    // A query with hashes in it. Through `box` this would split on the user's
    // own `###`, key on `b`, and draw `a` -- which is why fields use this.
    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    const first = try ui.boxText("query", "a###b");
    ui.end();

    try testing.expectEqualStrings("a###b", first.text);

    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    const second = try ui.boxText("query", "something else");
    ui.end();

    // The same box across a complete change of text, which is what a field
    // being typed into needs: its focus and its animation survive.
    try testing.expectEqual(first, second);
    try testing.expectEqual(key.make(ui.root.key, "query"), second.key);
}
