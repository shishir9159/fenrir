//! A panel that floats over everything else, and what dismisses it.
//!
//! Floated against the root rather than laid out where it was called from,
//! so it escapes the panel that opened it and is positioned in viewport
//! coordinates. That is the whole of the mechanism: there is no second layer,
//! no z order, and nothing sorts.
//!
//! Menus, tooltips and the command palette are all this box with different
//! things inside it.
//!
//! ## Build popups last
//!
//! `UI` draws in build order and resolves hover in build order, last match
//! wins -- which is what makes "the box on top" and "the box that gets the
//! mouse" the same box without either of them sorting anything. A popup is on
//! top because it is built last, so the contract for the caller is one line:
//! build the chrome, then build whatever popups are open, then end the frame.
//! A menu opened from a toolbar button is *not* built where the button is;
//! the button records where it should go and the popup is built at the end.
//!
//! It also has to be built where the clip stack is the viewport, which is the
//! same place. A popup built inside a clipped panel would inherit that
//! panel's clip for hit testing, and a menu that hangs below its sidebar
//! would stop taking the mouse half way down.
//!
//! ## Dismissal, and the frame of latency that makes it work
//!
//! An open popup puts a clickable box over the whole viewport behind itself.
//! A press that lands on it is a press that missed the popup.
//!
//! The awkward case is the press that *opened* the popup: it must not also
//! close it. It cannot, and not by luck. Hover is resolved after the build
//! from this frame's geometry but read on the *next* frame, and a press is
//! only delivered to a box the pointer was already over -- so the backdrop,
//! which did not exist when hover was last resolved, cannot take the press
//! that built it. The same holds when a popup is reopened: its backdrop box
//! is still in the table with its old rectangle, and is still not hot,
//! because hover is resolved by walking the tree it was absent from.
//!
//! Open a popup on `clicked` rather than on `pressed`. Both work, and
//! `clicked` is what the rest of the interface uses.

const std = @import("std");

const geom = @import("../../gelgja/geom.zig");

const Box = @import("../Box.zig");
const UI = @import("../UI.zig");
const key = @import("../key.zig");

const Point = geom.Point;
const Size = Box.Size;

pub const Error = UI.Error;

pub const Options = struct {
    /// Top-left, in viewport coordinates, before it is pushed back inside.
    at: Point,
    w: Size = .px(220),
    h: Size = .children,
    /// A box behind it that takes the press that dismisses it. Off for a
    /// popup that must not swallow the interface underneath -- a tooltip,
    /// which is shown *because* the pointer is somewhere and would be
    /// dismissed by its own existence.
    backdrop: bool = true,
};

pub const Popup = struct {
    box: *Box,
    /// A press landed outside it this frame.
    dismissed: bool = false,
};

/// Opens the panel. The caller fills it and calls `close`.
pub fn open(ui: *UI, name: []const u8, opts: Options) Error!Popup {
    // Against the root, so the coordinates are the viewport's and no
    // enclosing panel clips it.
    ui.pushParent(ui.root);

    var out: Popup = .{ .box = undefined };

    if (opts.backdrop) {
        ui.next(.{
            .w = .fill,
            .h = .fill,
            .fixed_x = 0,
            .fixed_y = 0,
            .flags = .{ .clickable = true, .floating_x = true, .floating_y = true },
        });
        var buf: [48]u8 = undefined;
        const b = try ui.box(std.fmt.bufPrint(&buf, "###{s} backdrop", .{name}) catch "###backdrop");
        out.dismissed = ui.signal(b).pressed;
    }

    const at = clampInto(ui, name, opts);

    ui.nextDefaults(.{
        .w = opts.w,
        .h = opts.h,
        .axis = .y,
        .fixed_x = at.x,
        .fixed_y = at.y,
        .radius = .all(6),
        .flags = .{
            .floating_x = true,
            .floating_y = true,
            .draw_background = true,
            .draw_border = true,
            .draw_shadow = true,
            .clip = true,
        },
    });
    out.box = try ui.open(name);
    return out;
}

pub fn close(ui: *UI, p: Popup) void {
    ui.close(p.box);
    ui.popParent();
}

/// Pushes a popup back inside the viewport.
///
/// The width is known -- the caller gave it -- and the height usually is not,
/// because a menu is as tall as its items. Last frame's rectangle answers
/// that, the way every other geometry a call site reads here does, so a popup
/// opening near the bottom edge hangs over it for one frame and then sits
/// against it.
fn clampInto(ui: *UI, name: []const u8, opts: Options) Point {
    const view = ui.viewport;
    const k = key.make(ui.parent().key, name);

    const width = if (opts.w.kind == .pixels) opts.w.value else 0;
    const height = if (ui.find(k)) |b| b.rect.height() else 0;

    return .{
        .x = @max(view.min_x, @min(opts.at.x, view.max_x - width)),
        .y = @max(view.min_y, @min(opts.at.y, view.max_y - height)),
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const input = @import("../input.zig");
const w = @import("../widgets.zig");

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

/// A button, and the popup it opens -- built last, which is the contract.
fn oneFrame(ui: *UI, showing: *bool, in: input.Input) !void {
    try ui.begin(.fromRect(0, 0, 400, 300), in);

    ui.next(.{ .w = .px(80), .h = .px(24) });
    if ((try w.button(ui, "File")).clicked) showing.* = !showing.*;

    if (showing.*) {
        const p = try open(ui, "pop", .{ .at = .{ .x = 0, .y = 24 } });
        defer close(ui, p);
        if (p.dismissed) showing.* = false;

        ui.next(.{ .w = .fill, .h = .px(60), .flags = .{ .clickable = true } });
        _ = try ui.box("body");
    }

    ui.end();
}

test "the press that opens a popup is not also the press that closes it" {
    var ui = scratch();
    defer ui.deinit();
    var showing = false;

    const on_button: Point = .{ .x = 30, .y = 12 };
    try oneFrame(&ui, &showing, .{ .mouse = on_button });
    try oneFrame(&ui, &showing, .{ .mouse = on_button, .buttons = .{ .left = true } });
    try testing.expect(!showing);

    // The release is the click, and the popup opens on the same frame its
    // backdrop is first built. Nothing behind it may take that press.
    try oneFrame(&ui, &showing, .{ .mouse = on_button });
    try testing.expect(showing);

    // Still open with the pointer resting where the backdrop now is.
    try oneFrame(&ui, &showing, .{ .mouse = on_button });
    try oneFrame(&ui, &showing, .{ .mouse = on_button });
    try testing.expect(showing);
}

test "a press outside dismisses it and a press inside does not" {
    var ui = scratch();
    defer ui.deinit();
    var showing = true;

    const inside: Point = .{ .x = 40, .y = 40 };
    try oneFrame(&ui, &showing, .{ .mouse = inside });
    try oneFrame(&ui, &showing, .{ .mouse = inside, .buttons = .{ .left = true } });
    try testing.expect(showing);

    const outside: Point = .{ .x = 350, .y = 250 };
    try oneFrame(&ui, &showing, .{ .mouse = outside });
    try oneFrame(&ui, &showing, .{ .mouse = outside });
    try oneFrame(&ui, &showing, .{ .mouse = outside, .buttons = .{ .left = true } });
    try testing.expect(!showing);
}

test "a popup is on top of what was built before it" {
    var ui = scratch();
    defer ui.deinit();
    var showing = true;

    // Over the button, which the popup does not cover -- but the backdrop
    // does, and the backdrop is built later.
    const on_button: Point = .{ .x = 30, .y = 12 };
    try oneFrame(&ui, &showing, .{ .mouse = on_button });
    try oneFrame(&ui, &showing, .{ .mouse = on_button });

    const button = ui.find(key.make(ui.root.key, "File")).?;
    try testing.expect(button.rect.contains(on_button));
    try testing.expect(!ui.signal(button).hovering);
}

test "a popup opening past an edge is pushed back inside" {
    var ui = scratch();
    defer ui.deinit();

    const build = struct {
        fn go(u: *UI) !*Box {
            try u.begin(.fromRect(0, 0, 400, 300), .{});
            const p = try open(u, "pop", .{ .at = .{ .x = 380, .y = 290 }, .w = .px(220) });
            {
                defer close(u, p);
                u.next(.{ .w = .fill, .h = .px(60) });
                _ = try u.box("body");
            }
            u.end();
            return p.box;
        }
    }.go;

    // The width is the caller's, so x is right on the first frame.
    var p = try build(&ui);
    try testing.expectApproxEqAbs(@as(f32, 180), p.rect.min_x, 1e-3);

    // The height is last frame's, so y takes one more.
    p = try build(&ui);
    try testing.expectApproxEqAbs(@as(f32, 240), p.rect.min_y, 1e-3);
}
