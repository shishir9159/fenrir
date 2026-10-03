//! A draggable line between two panes.
//!
//! The protocol is one number and nothing else: the caller sizes the first
//! pane `.percentStrict(fraction.*)` and the second `.fill`, and puts this
//! between them. The splitter owns the fraction, the sizes own the layout,
//! and there is no second description of where the boundary is to fall out of
//! step with the first.
//!
//! **Strict, and that is not a detail.** `Size.percent` is loose, because a
//! percentage is usually a wish. Here it is not: if both panes are willing to
//! give way then the violation pass shares the overflow between them and the
//! line lands somewhere neither the caller nor the pointer asked for. The
//! first pane holds its fraction, the splitter holds its pixels, and the
//! second takes what is left -- which is exactly what `.fill` is for.
//!
//! `fraction` is the caller's, the way a checkbox's bool is -- a split whose
//! position lived in the box tree could not be saved, restored, or set by a
//! command.
//!
//! A drag does not ease. The same argument the scrollbar's thumb makes: a
//! line that slides towards the pointer is a line that is not under it, and
//! direct manipulation is the one place animation is wrong.

const std = @import("std");

const paint = @import("../../gelgja/paint.zig");

const Box = @import("../Box.zig");
const Theme = @import("../Theme.zig");
const UI = @import("../UI.zig");
const key = @import("../key.zig");

const Axis = Box.Axis;
const Color = paint.Color;
const Signal = UI.Signal;

pub const Error = UI.Error;

pub const Options = struct {
    /// Which way the pair is stacked. The line lies across it.
    axis: Axis = .x,
    /// Four rather than one or two: this is a target as well as a line, and
    /// a line nobody can hit is decoration.
    thickness: f32 = 4,
    /// Smallest either side may be dragged to, in pixels.
    min: f32 = 60,
    /// Drawn while it is held, so a drag that has hit its limit still looks
    /// like a drag. A widget has no theme, so the reader passes its own.
    accent: ?Color = null,
};

/// Drags `fraction`: the first pane's share of the parent, between 0 and 1.
///
/// `name` is a plain string, not a `##` label -- there is nothing to display,
/// so there is nothing to hide.
pub fn splitter(ui: *UI, name: []const u8, fraction: *f32, opts: Options) Error!Signal {
    const st = ui.style();
    const parent = ui.parent();
    const across = opts.axis == .x;

    // Whether it is held is read *before* the box is built, because the
    // colour has to be chosen then and the signal does not exist yet.
    // `active` survives the frame it was set on, so this is last frame's
    // answer -- one frame late at the start of a drag, which is a frame in
    // which the pointer has not yet moved.
    const held = ui.isActive(key.make(parent.key, name));

    ui.nextDefaults(.{
        .w = if (across) .px(opts.thickness) else .fill,
        .h = if (across) .fill else .px(opts.thickness),
        .bg = if (held) (opts.accent orelse Theme.dark.accent) else st.border_color,
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .hot_animation = true,
        },
    });
    const sig = ui.signal(try ui.box(name));

    if (sig.dragging) {
        const span = if (across) parent.rect.width() else parent.rect.height();
        const at = if (across)
            ui.in.mouse.x - parent.rect.min_x
        else
            ui.in.mouse.y - parent.rect.min_y;

        if (span > 0) {
            const lo = opts.min / span;
            const hi = 1 - (opts.min + opts.thickness) / span;
            // Both limits at once is a parent too small to hold two panes.
            // Refusing to move is the only answer that is not a lie.
            if (lo < hi) fraction.* = std.math.clamp(at / span, lo, hi);
        }
    }

    return sig;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const geom = @import("../../gelgja/geom.zig");
const input = @import("../input.zig");

const Point = geom.Point;

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

/// Two panes with a splitter between them, in a four-hundred-pixel row.
fn oneFrame(ui: *UI, share: *f32, axis: Axis, in: input.Input) !void {
    try ui.begin(.fromRect(0, 0, 400, 400), in);

    ui.next(.{ .w = .px(400), .h = .px(400), .axis = axis });
    const row = try ui.open("row");
    defer ui.close(row);

    const first: Box.Size = .percentStrict(share.*);
    ui.next(if (axis == .x)
        .{ .w = first, .h = .fill }
    else
        .{ .w = .fill, .h = first });
    _ = try ui.box("first");

    _ = try splitter(ui, "line", share, .{ .axis = axis });

    ui.next(.{ .w = .fill, .h = .fill });
    _ = try ui.box("second");

    ui.end();
}

test "dragging the line moves it, and the pane follows" {
    var ui = scratch();
    defer ui.deinit();
    var share: f32 = 0.5;

    // Onto the line first: a press is only delivered to a box the pointer
    // was already over.
    const on_line: Point = .{ .x = 201, .y = 200 };
    try oneFrame(&ui, &share, .x, .{});
    try oneFrame(&ui, &share, .x, .{ .mouse = on_line });

    try oneFrame(&ui, &share, .x, .{ .mouse = on_line, .buttons = .{ .left = true } });
    try oneFrame(&ui, &share, .x, .{ .mouse = .{ .x = 300, .y = 200 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 0.75), share, 1e-3);

    // And no easing: the pane is where the pointer is on the same frame.
    try oneFrame(&ui, &share, .x, .{ .mouse = .{ .x = 300, .y = 200 }, .buttons = .{ .left = true } });
    const first = ui.find(key.make(key.make(ui.root.key, "row"), "first")).?;
    try testing.expectApproxEqAbs(@as(f32, 300), first.rect.max_x, 1e-3);
}

test "neither pane can be dragged below its minimum" {
    var ui = scratch();
    defer ui.deinit();
    var share: f32 = 0.5;

    const on_line: Point = .{ .x = 201, .y = 200 };
    try oneFrame(&ui, &share, .x, .{});
    try oneFrame(&ui, &share, .x, .{ .mouse = on_line });
    try oneFrame(&ui, &share, .x, .{ .mouse = on_line, .buttons = .{ .left = true } });

    // All the way off the left-hand edge, and past it.
    try oneFrame(&ui, &share, .x, .{ .mouse = .{ .x = -500, .y = 200 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 60.0 / 400.0), share, 1e-3);

    // And the far side, where the thickness counts against the room as well.
    try oneFrame(&ui, &share, .x, .{ .mouse = .{ .x = 900, .y = 200 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 1 - 64.0 / 400.0), share, 1e-3);
}

test "a splitter across a column drags on the other axis" {
    var ui = scratch();
    defer ui.deinit();
    var share: f32 = 0.5;

    const on_line: Point = .{ .x = 200, .y = 201 };
    try oneFrame(&ui, &share, .y, .{});
    try oneFrame(&ui, &share, .y, .{ .mouse = on_line });
    try oneFrame(&ui, &share, .y, .{ .mouse = on_line, .buttons = .{ .left = true } });

    // Moving sideways does nothing; moving down moves it.
    try oneFrame(&ui, &share, .y, .{ .mouse = .{ .x = 380, .y = 201 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 0.5025), share, 1e-3);

    try oneFrame(&ui, &share, .y, .{ .mouse = .{ .x = 380, .y = 120 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 0.3), share, 1e-3);
}

test "a press that does not move leaves the split where it was" {
    var ui = scratch();
    defer ui.deinit();
    var share: f32 = 0.5;

    const on_line: Point = .{ .x = 201, .y = 200 };
    try oneFrame(&ui, &share, .x, .{});
    try oneFrame(&ui, &share, .x, .{ .mouse = on_line });
    try oneFrame(&ui, &share, .x, .{ .mouse = on_line, .buttons = .{ .left = true } });
    try oneFrame(&ui, &share, .x, .{ .mouse = on_line });

    // 201 of 400 rather than 200: the line is under the pointer, which is
    // where it was grabbed, and a splitter that jumped by half its thickness
    // on every press would walk across the window.
    try testing.expectApproxEqAbs(@as(f32, 201.0 / 400.0), share, 1e-3);
}
