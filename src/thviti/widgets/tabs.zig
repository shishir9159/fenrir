//! A tab bar: one row of documents, with an accent bar on the active one.
//!
//! Drawn the way the design language asks and not the way a desktop toolkit
//! would. There is no raised shape, no notch and no trapezium: the active tab
//! is the one with a two-pixel accent bar down its left edge, which is the
//! only thing on the bar drawn in the accent colour and is therefore
//! unmistakable at a glance. Colour carries meaning here and never decoration.
//!
//! ## A tab is as wide as a tab
//!
//! Not as wide as its title. A bar whose tabs all move when a document is
//! opened is a bar nobody can aim at, and a document called `2024-q3-final
//! (revised).pdf` would otherwise take the whole window. So a tab asks for
//! `max_width` pixels and is loose about it, and when there are more tabs
//! than room the solver takes the shortfall out of all of them equally --
//! which is what a strictness is for, and is why there is no minimum width
//! here to get wrong. The label inside gives up its own width the same way
//! and the tab clips, so a long title is cut rather than pushing the cross
//! out of the tab.
//!
//! ## The cross is a box inside the tab
//!
//! Both are clickable, and the inner one wins: hover is resolved depth first
//! in build order with the last match taking it, so a cross built inside a
//! tab is in front of it. That also means the tab does not report a click
//! when the cross is the thing that was hit, with nothing to arbitrate and
//! no rectangle subtracted from another.

const std = @import("std");

const paint = @import("../../gelgja/paint.zig");

const Box = @import("../Box.zig");
const Theme = @import("../Theme.zig");
const UI = @import("../UI.zig");
const w = @import("../widgets.zig");

const Color = paint.Color;
const Size = Box.Size;

pub const Error = UI.Error;

/// Dense, like every other row in this interface.
pub const height: f32 = 26;
pub const mark_width: f32 = 2;
pub const cross_size: f32 = 14;

pub const Options = struct {
    h: f32 = height,
    /// The one colour on the bar that means something. Defaults to the dark
    /// theme's, because a widget has no theme; the reader passes its own.
    accent: ?Color = null,
    /// How wide a tab would like to be, and how much of that it keeps when
    /// there is not room. Nought would let a tab vanish; one would let the
    /// bar overflow rather than share the loss.
    max_width: f32 = 180,
    strictness: f32 = 0.55,
    /// A close cross on every tab.
    closable: bool = true,
    /// A `+` after the last tab.
    add: bool = false,
};

pub const Result = struct {
    /// A tab was clicked. Not set when the click landed on its cross.
    activated: ?u32 = null,
    /// A tab's cross was clicked, or the tab was middle-clicked.
    closed: ?u32 = null,
    added: bool = false,
};

/// The bar. `active` is the caller's, as a checkbox's bool is: which tab is
/// current is a fact about the session, not about the box tree.
pub fn tabBar(
    ui: *UI,
    name: []const u8,
    labels: []const []const u8,
    active: u32,
    opts: Options,
) Error!Result {
    const st = ui.style();
    const accent = opts.accent orelse Theme.dark.accent;

    ui.nextDefaults(.{
        .w = .fill,
        .h = .px(opts.h),
        .axis = .x,
        .flags = .{ .draw_background = true, .clip = true },
    });
    const bar = try ui.open(name);
    defer ui.close(bar);

    var out: Result = .{};

    for (labels, 0..) |label, i| {
        const index: u32 = @intCast(i);
        const current = index == active;

        ui.next(.{
            .w = .{ .kind = .pixels, .value = opts.max_width, .strictness = opts.strictness },
            .h = .fill,
            .axis = .x,
            .child_align = .center,
            .flags = .{
                .clickable = true,
                .draw_background = true,
                .hot_animation = true,
                .clip = true,
            },
            .bg = if (current) mix(st.bg, st.fg, 0.10) else st.bg,
        });

        var name_buf: [20]u8 = undefined;
        const tab = try ui.open(std.fmt.bufPrint(&name_buf, "###tab{d}", .{index}) catch "###tab");
        const sig = ui.signal(tab);
        {
            defer ui.close(tab);

            // Built whether or not it is the active tab, so that every label
            // starts at the same x and the row does not shift by two pixels
            // as the selection moves.
            ui.next(.{
                .w = .px(mark_width),
                .h = .fill,
                .bg = if (current) accent else st.bg.withAlpha(0),
                .flags = .{ .draw_background = true },
            });
            _ = try ui.box("mark");

            try w.spacer(ui, .px(8));
            ui.next(.{
                .w = .fill,
                .h = .text(0),
                .fg = if (current) st.fg else mix(st.bg, st.fg, 0.70),
                .flags = .{ .draw_text = true },
            });
            _ = try ui.boxText("label", label);
            try w.spacer(ui, .px(6));

            if (opts.closable) {
                ui.next(.{
                    .w = .px(cross_size),
                    .h = .px(cross_size),
                    .text_align = .center,
                    .radius = .all(3),
                    .bg = st.bg.withAlpha(0),
                    .flags = .{
                        .clickable = true,
                        .draw_background = true,
                        .draw_text = true,
                        .hot_animation = true,
                    },
                });
                if (ui.signal(try ui.box("x###close")).clicked) out.closed = index;
                try w.spacer(ui, .px(6));
            }
        }

        if (sig.clicked) out.activated = index;
        // The gesture every tab bar has had for twenty years, and the only
        // way to close one when the cross has been squeezed off the end.
        if (sig.middle_clicked) out.closed = index;

        ui.next(.{
            .w = .px(1),
            .h = .fill,
            .bg = st.border_color,
            .flags = .{ .draw_background = true },
        });
        _ = try ui.box("");
    }

    if (opts.add) {
        ui.next(.{
            .w = .px(opts.h),
            .h = .fill,
            .text_align = .center,
            .bg = st.bg,
            .flags = .{
                .clickable = true,
                .draw_background = true,
                .draw_text = true,
                .hot_animation = true,
            },
        });
        out.added = ui.signal(try ui.box("+###add")).clicked;
    }

    return out;
}

fn mix(a: Color, b: Color, k: f32) Color {
    const t = std.math.clamp(k, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const geom = @import("../../gelgja/geom.zig");
const input = @import("../input.zig");
const key_make = @import("../key.zig").make;

const Point = geom.Point;

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

const three = [_][]const u8{ "paper.pdf", "notes.pdf", "gylfaginning.pdf" };

fn oneFrame(ui: *UI, labels: []const []const u8, in: input.Input) !Result {
    try ui.begin(.fromRect(0, 0, 800, 200), in);
    const r = try tabBar(ui, "tabs", labels, 1, .{ .add = true });
    ui.end();
    return r;
}

/// The middle of tab `n`, which is the only geometry these tests need.
fn tabCentre(ui: *UI, n: u32) Point {
    var buf: [20]u8 = undefined;
    const k = key_make(key_make(ui.root.key, "tabs"), std.fmt.bufPrint(&buf, "tab{d}", .{n}) catch unreachable);
    const r = ui.find(k).?.rect;
    return .{ .x = r.min_x + 40, .y = (r.min_y + r.max_y) * 0.5 };
}

test "clicking a tab reports it and nothing else" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, &three, .{});
    const at = tabCentre(&ui, 2);

    _ = try oneFrame(&ui, &three, .{ .mouse = at });
    _ = try oneFrame(&ui, &three, .{ .mouse = at, .buttons = .{ .left = true } });
    const r = try oneFrame(&ui, &three, .{ .mouse = at });

    try testing.expectEqual(@as(?u32, 2), r.activated);
    try testing.expectEqual(@as(?u32, null), r.closed);
    try testing.expect(!r.added);
}

test "clicking the cross closes that tab without activating it" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, &three, .{});
    const tab = key_make(key_make(ui.root.key, "tabs"), "tab0");
    const cross = ui.find(key_make(tab, "close")).?.rect;
    const at: Point = .{ .x = (cross.min_x + cross.max_x) * 0.5, .y = (cross.min_y + cross.max_y) * 0.5 };

    _ = try oneFrame(&ui, &three, .{ .mouse = at });
    _ = try oneFrame(&ui, &three, .{ .mouse = at, .buttons = .{ .left = true } });
    const r = try oneFrame(&ui, &three, .{ .mouse = at });

    // The cross is inside the tab and is built after it, so it is in front:
    // the tab never sees the click it did not get.
    try testing.expectEqual(@as(?u32, 0), r.closed);
    try testing.expectEqual(@as(?u32, null), r.activated);
}

test "the middle button closes a tab wherever it lands on it" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, &three, .{});
    const at = tabCentre(&ui, 1);

    _ = try oneFrame(&ui, &three, .{ .mouse = at });
    _ = try oneFrame(&ui, &three, .{ .mouse = at, .buttons = .{ .middle = true } });
    const r = try oneFrame(&ui, &three, .{ .mouse = at });

    try testing.expectEqual(@as(?u32, 1), r.closed);
}

test "the accent marks the active tab and nothing else on the bar" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, &three, .{});
    const bar = key_make(ui.root.key, "tabs");

    for (0..three.len) |i| {
        var buf: [20]u8 = undefined;
        const tab = key_make(bar, std.fmt.bufPrint(&buf, "tab{d}", .{i}) catch unreachable);
        const mark = ui.find(key_make(tab, "mark")).?;

        // Built on every tab so the labels stay aligned, and coloured on one.
        try testing.expectEqual(@as(f32, mark_width), mark.size[0]);
        if (i == 1) {
            try testing.expectEqual(Theme.dark.accent, mark.style.bg);
        } else {
            try testing.expectEqual(@as(f32, 0), mark.style.bg.a);
        }
    }
}

test "the plus reports itself and is not a tab" {
    var ui = scratch();
    defer ui.deinit();

    _ = try oneFrame(&ui, &three, .{});
    const plus = ui.find(key_make(key_make(ui.root.key, "tabs"), "add")).?.rect;
    const at: Point = .{ .x = (plus.min_x + plus.max_x) * 0.5, .y = (plus.min_y + plus.max_y) * 0.5 };

    _ = try oneFrame(&ui, &three, .{ .mouse = at });
    _ = try oneFrame(&ui, &three, .{ .mouse = at, .buttons = .{ .left = true } });
    const r = try oneFrame(&ui, &three, .{ .mouse = at });

    try testing.expect(r.added);
    try testing.expectEqual(@as(?u32, null), r.activated);
}

test "too many tabs share the shortfall rather than one of them taking it" {
    var ui = scratch();
    defer ui.deinit();

    // Ten tabs wanting a hundred and eighty pixels each, in eight hundred.
    const many: [10][]const u8 = @splat("a.pdf");
    _ = try oneFrame(&ui, &many, .{});
    _ = try oneFrame(&ui, &many, .{});

    const bar = key_make(ui.root.key, "tabs");
    const first = ui.find(key_make(bar, "tab0")).?;
    const last = ui.find(key_make(bar, "tab9")).?;

    // Equally, whatever order they were built in: the solver distributes a
    // violation in proportion to what each box is willing to give up, and
    // these are all willing to give up the same.
    try testing.expectApproxEqAbs(first.size[0], last.size[0], 1e-3);
    // And the floor is the strictness, not a number written down anywhere:
    // a tab keeps 55% of what it asked for and no less.
    try testing.expectApproxEqAbs(@as(f32, 180 * 0.55), first.size[0], 1e-3);

    // The label gives up its width the same way, inside the shrunken tab.
    const label = ui.find(key_make(key_make(bar, "tab0"), "label")).?;
    try testing.expect(label.rect.max_x <= first.rect.max_x + 1e-3);
}
