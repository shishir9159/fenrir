//! A handful of widgets, which is not a widget set.
//!
//! These exist to prove that the core is usable, not to be the library. Each
//! one is a few lines of `next`, `box` and `signal` and nothing else -- no
//! privileged access, no fields only a widget may touch -- which is the claim
//! being made: everything a widget needs is on the public surface, so a
//! caller's own controls are no harder to write than these.
//!
//! The real set -- text fields with selection and an IME, menus, tab bars,
//! trees, splitters, drag-and-drop -- is a layer written *on* this one, and
//! writing it before there is a window to put it in would mean designing
//! against an interface nobody has used yet. That is the same reasoning that
//! kept the Vulkan backend from being written before Lyngvi.
//!
//! ## The pattern
//!
//! Every one of them reads the same way. Describe the box, make it, ask what
//! happened to it:
//!
//!     ui.next(.{ ... });
//!     const b = try ui.box(label);
//!     return ui.signal(b);
//!
//! The signal is about the rectangle the box had *last* frame, which is the
//! one the user was looking at when they clicked.

const std = @import("std");

const Box = @import("Box.zig");
const UI = @import("UI.zig");

const Axis = Box.Axis;
const Signal = UI.Signal;
const Size = Box.Size;

pub const Error = UI.Error;

/// A gap. Nil-keyed, so it never enters the persistent table -- a spacer with
/// state would be a bug waiting to be found.
pub fn spacer(ui: *UI, size: Size) Error!void {
    const along = ui.parent().style.axis;
    ui.nextDefaults(if (along == .x)
        .{ .w = size, .h = .fill }
    else
        .{ .w = .fill, .h = size });
    _ = try ui.box("");
}

/// Everything left over on the parent's axis, which is how two things are
/// pushed to opposite ends of a toolbar.
pub fn fill(ui: *UI) Error!void {
    return spacer(ui, .{ .kind = .percent_of_parent, .value = 1, .strictness = 0 });
}

/// Text, sized to itself.
pub fn label(ui: *UI, s: []const u8) Error!*Box {
    ui.nextDefaults(.{ .w = .text(0), .h = .text(0), .flags = .{ .draw_text = true } });
    return ui.box(s);
}

pub fn labelf(ui: *UI, comptime fmt: []const u8, args: anytype) Error!*Box {
    ui.nextDefaults(.{ .w = .text(0), .h = .text(0), .flags = .{ .draw_text = true } });
    return ui.boxf(fmt, args);
}

pub const ButtonOptions = struct {
    w: ?Size = null,
    h: ?Size = null,
    disabled: bool = false,
};

/// The one everything else is measured against.
pub fn button(ui: *UI, s: []const u8) Error!Signal {
    return buttonWith(ui, s, .{});
}

pub fn buttonWith(ui: *UI, s: []const u8, opts: ButtonOptions) Error!Signal {
    ui.nextDefaults(.{
        .w = opts.w orelse .text(10),
        .h = opts.h orelse .text(6),
        .text_align = .center,
        .flags = .{
            .clickable = true,
            .focusable = true,
            .draw_background = true,
            .draw_border = true,
            .draw_text = true,
            .hot_animation = true,
            .active_animation = true,
            .disabled = opts.disabled,
        },
    });
    return ui.signal(try ui.box(s));
}

/// A latch. The state is the caller's, because a checkbox whose value lived in
/// the box would be a checkbox nothing else could read.
pub fn checkbox(ui: *UI, s: []const u8, on: *bool) Error!Signal {
    ui.nextDefaults(.{
        .w = .text(8),
        .h = .text(6),
        .flags = .{
            .clickable = true,
            .focusable = true,
            .draw_background = true,
            .draw_border = true,
            .draw_text = true,
            .hot_animation = true,
            .active_animation = true,
        },
        .bg = if (on.*) .{ .r = 0.20, .g = 0.42, .b = 0.72 } else null,
    });
    const sig = ui.signal(try ui.box(s));
    if (sig.clicked) on.* = !on.*;
    return sig;
}

/// A container with a background, a border and a corner radius.
///
/// Opened, not made: the caller fills it and calls `ui.close`. Returning the
/// box rather than taking a closure keeps the call site's control flow its
/// own, which is the entire argument for immediate mode.
pub fn openPanel(ui: *UI, s: []const u8, axis: Axis) Error!*Box {
    ui.nextDefaults(.{
        .axis = axis,
        .flags = .{ .draw_background = true, .draw_border = true, .clip = true },
        .radius = .all(6),
    });
    return ui.open(s);
}

/// A row or a column, with no appearance of its own.
pub fn openRow(ui: *UI, s: []const u8) Error!*Box {
    ui.nextDefaults(.{ .w = .fill, .h = .children, .axis = .x });
    return ui.open(s);
}

pub fn openColumn(ui: *UI, s: []const u8) Error!*Box {
    ui.nextDefaults(.{ .w = .fill, .h = .children, .axis = .y });
    return ui.open(s);
}

pub const ScrollView = struct {
    box: *Box,
    signal: Signal,

    /// How far down the content currently is.
    pub fn offset(v: ScrollView) f32 {
        return v.box.view_off[1];
    }
};

/// A vertically scrolling region.
///
/// `content_height` is what the caller is about to put inside it, which the
/// caller knows and the layout does not until a frame later. Passing it in
/// rather than measuring it afterwards is what stops the scroll limit lagging
/// a frame behind the content -- the visible symptom of which is a list that
/// can be scrolled one row too far the first time it grows.
pub fn openScroll(ui: *UI, s: []const u8, content_height: f32) Error!ScrollView {
    ui.nextDefaults(.{
        .axis = .y,
        .flags = .{ .scrollable = true, .clip = true, .overflow_y = true },
    });
    const b = try ui.open(s);
    const sig = ui.signal(b);

    if (sig.scroll.y != 0) {
        const limit = @max(content_height - b.rect.height(), 0);
        b.view_off_target[1] = std.math.clamp(b.view_off_target[1] - sig.scroll.y, 0, limit);
    } else {
        // Re-clamped every frame anyway, because the content can shrink under
        // a view that is already scrolled past the new end.
        const limit = @max(content_height - b.rect.height(), 0);
        b.view_off_target[1] = std.math.clamp(b.view_off_target[1], 0, limit);
    }

    return .{ .box = b, .signal = sig };
}

/// The visible half of a scroll position, as a draggable thumb.
///
/// Drawn as two boxes, which is also the whole implementation: a track that
/// takes the drag, and a thumb positioned inside it. The thumb is not
/// clickable, because a drag that started on the track should keep working
/// after the thumb has moved out from under the pointer.
pub fn scrollBar(ui: *UI, s: []const u8, view: ScrollView, content_height: f32) Error!void {
    const height = view.box.rect.height();
    const limit = @max(content_height - height, 0);

    ui.nextDefaults(.{
        .w = .px(10),
        .h = .fill,
        .axis = .y,
        .flags = .{ .clickable = true, .draw_background = true },
        .radius = .all(5),
    });
    const track = try ui.open(s);
    defer ui.close(track);

    const sig = ui.signal(track);
    const span = track.rect.height();
    if (sig.dragging and limit > 0 and span > 0) {
        const at = std.math.clamp((ui.in.mouse.y - track.rect.min_y) / span, 0, 1);
        view.box.view_off_target[1] = at * limit;
        // A drag is a direct manipulation, so it does not ease: the thumb has
        // to stay under the finger.
        view.box.view_off[1] = view.box.view_off_target[1];
    }

    const visible = if (content_height > 0) @min(height / content_height, 1) else 1;
    const at = if (limit > 0) view.box.view_off[1] / limit else 0;
    const thumb_h = @max(visible * span, 20);

    ui.nextDefaults(.{
        .w = .fill,
        .h = .px(thumb_h),
        .fixed_y = at * @max(span - thumb_h, 0),
        .flags = .{ .floating_y = true, .draw_background = true, .hot_animation = true },
        .bg = .{ .r = 0.42, .g = 0.44, .b = 0.50 },
        .radius = .all(5),
    });
    _ = try ui.box("thumb");
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

test "a button reports a click on the frame the mouse comes up" {
    var ui = scratch();
    defer ui.deinit();

    const at: geom_Point = .{ .x = 20, .y = 10 };

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at });
    _ = try button(&ui, "Open");
    ui.end();

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at, .buttons = .{ .left = true } });
    const down = try button(&ui, "Open");
    ui.end();
    try testing.expect(down.pressed and !down.clicked);

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at });
    const up = try button(&ui, "Open");
    ui.end();
    try testing.expect(up.clicked);
}

const geom_Point = @import("../gelgja/geom.zig").Point;

test "a checkbox toggles its caller's variable and nothing of its own" {
    var ui = scratch();
    defer ui.deinit();

    var on = false;
    const at: geom_Point = .{ .x = 20, .y = 10 };

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at });
    _ = try checkbox(&ui, "Wrap", &on);
    ui.end();

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at, .buttons = .{ .left = true } });
    _ = try checkbox(&ui, "Wrap", &on);
    ui.end();
    try testing.expect(!on);

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at });
    _ = try checkbox(&ui, "Wrap", &on);
    ui.end();
    try testing.expect(on);
}

test "a spacer stretches along whichever axis its parent stacks on" {
    var ui = scratch();
    defer ui.deinit();

    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    {
        ui.next(.{ .w = .px(200), .h = .px(40), .axis = .x });
        const row = try ui.open("row");
        defer ui.close(row);
        try spacer(&ui, .px(30));
    }
    ui.end();

    const gap = ui.root.first.?.first.?;
    try testing.expectEqual(@as(f32, 30), gap.size[0]);
    try testing.expectEqual(@as(f32, 40), gap.size[1]);
}

test "a fill pushes what follows it to the far end" {
    var ui = scratch();
    defer ui.deinit();

    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    {
        ui.next(.{ .w = .px(200), .h = .px(40), .axis = .x });
        const row = try ui.open("row");
        defer ui.close(row);
        ui.next(.{ .w = .px(30), .h = .fill });
        _ = try ui.box("left");
        try fill(&ui);
        ui.next(.{ .w = .px(50), .h = .fill });
        _ = try ui.box("right");
    }
    ui.end();

    const row = ui.root.first.?;
    try testing.expectEqual(@as(f32, 0), row.first.?.rect.min_x);
    try testing.expectEqual(@as(f32, 200), row.last.?.rect.max_x);
}

test "the wheel scrolls a view, and not past its content" {
    var ui = scratch();
    defer ui.deinit();

    const content: f32 = 500;
    const build = struct {
        fn go(u: *UI, h: f32) !void {
            u.next(.{ .w = .px(100), .h = .px(100) });
            const v = try openScroll(u, "list", h);
            u.close(v.box);
        }
    }.go;

    try ui.begin(.fromRect(0, 0, 200, 200), .{});
    try build(&ui, content);
    ui.end();

    // Wheel down a long way, several frames, so the easing settles.
    var n: u32 = 0;
    while (n < 40) : (n += 1) {
        try ui.begin(.fromRect(0, 0, 200, 200), .{
            .mouse = .{ .x = 50, .y = 50 },
            .scroll = .{ .x = 0, .y = -200 },
            .dt = 0.05,
        });
        try build(&ui, content);
        ui.end();
    }

    const view = ui.find(key_make(ui.root.key, "list")).?;
    // Four hundred is the whole of the overflow and not a pixel more.
    try testing.expectApproxEqAbs(@as(f32, 400), view.view_off_target[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 400), view.view_off[1], 0.1);
}

const key_make = @import("key.zig").make;

test "a view scrolled past the end of shrunken content is pulled back" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI, h: f32) !void {
            u.next(.{ .w = .px(100), .h = .px(100) });
            const v = try openScroll(u, "list", h);
            u.close(v.box);
        }
    }.go;

    try ui.begin(.fromRect(0, 0, 200, 200), .{});
    try build(&ui, 500);
    ui.end();

    const view = ui.find(key_make(ui.root.key, "list")).?;
    view.view_off_target[1] = 400;
    view.view_off[1] = 400;

    // The list loses most of its rows while it is scrolled to the bottom.
    try ui.begin(.fromRect(0, 0, 200, 200), .{});
    try build(&ui, 150);
    ui.end();

    try testing.expectApproxEqAbs(@as(f32, 50), view.view_off_target[1], 1e-3);
}

test "dragging the scrollbar moves the view without easing" {
    var ui = scratch();
    defer ui.deinit();

    const content: f32 = 500;
    const build = struct {
        fn go(u: *UI, h: f32) !void {
            u.next(.{ .w = .px(110), .h = .px(100), .axis = .x });
            const row = try u.open("row");
            defer u.close(row);

            u.next(.{ .w = .px(100), .h = .fill });
            const v = try openScroll(u, "list", h);
            u.close(v.box);

            try scrollBar(u, "bar", v, h);
        }
    }.go;

    try ui.begin(.fromRect(0, 0, 200, 200), .{});
    try build(&ui, content);
    ui.end();

    // Move onto the track first. A press is only delivered to the box the
    // pointer was already over, which is true of a real mouse and is the one
    // place the frame of latency in hover resolution is observable.
    const on_bar: geom_Point = .{ .x = 105, .y = 50 };
    try ui.begin(.fromRect(0, 0, 200, 200), .{ .mouse = on_bar });
    try build(&ui, content);
    ui.end();

    // Press at the half-way point and hold.
    try ui.begin(.fromRect(0, 0, 200, 200), .{ .mouse = on_bar, .buttons = .{ .left = true } });
    try build(&ui, content);
    ui.end();

    const view = ui.find(key_make(key_make(ui.root.key, "row"), "list")).?;
    // Half of four hundred, applied immediately: a thumb that eased towards
    // the pointer would slide out from under it.
    try testing.expectApproxEqAbs(@as(f32, 200), view.view_off[1], 1);
    try testing.expectApproxEqAbs(view.view_off_target[1], view.view_off[1], 1e-4);
}

test "a label is exactly as wide as its text" {
    var ui = scratch();
    defer ui.deinit();

    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    const l = try label(&ui, "Fenrir");
    ui.end();

    // Six characters, half an em each, at the default fourteen pixels.
    try testing.expectApproxEqAbs(@as(f32, 42), l.size[0], 1e-3);
}

test "a formatted label keeps its identity when only the number changes" {
    var ui = scratch();
    defer ui.deinit();

    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    const a = try labelf(&ui, "{d} pages###pages", .{3});
    ui.end();

    try ui.begin(.fromRect(0, 0, 200, 100), .{});
    const b = try labelf(&ui, "{d} pages###pages", .{97});
    ui.end();

    try testing.expectEqual(a, b);
    try testing.expectEqualStrings("97 pages", b.text);
}

test "a disabled button cannot be clicked" {
    var ui = scratch();
    defer ui.deinit();

    const at: geom_Point = .{ .x = 20, .y = 10 };
    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at });
    _ = try buttonWith(&ui, "Open", .{ .disabled = true });
    ui.end();

    try ui.begin(.fromRect(0, 0, 200, 100), .{ .mouse = at, .buttons = .{ .left = true } });
    const s = try buttonWith(&ui, "Open", .{ .disabled = true });
    ui.end();
    try testing.expect(!s.pressed and !s.hovering);
}
