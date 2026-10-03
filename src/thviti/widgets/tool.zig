//! Icon buttons, and the tooltips that say what they are.
//!
//! The two belong together because one is unusable without the other: a rail
//! of square glyphs with no words on it is a rail nobody can read, and a
//! tooltip with nothing to hang off is not a thing at all.
//!
//! ## The glyph is a string, for now
//!
//! `iconButton` takes text and centres it, which is a bookmark and not a
//! design: phase two replaces it with an icon *id* resolved through a
//! registry, and nothing else about the widget changes. Taking a string
//! today keeps the rails buildable before the registry exists, and taking a
//! path -- ever -- would be the mistake the plan is written to avoid.
//!
//! ## A tooltip is recorded here and drawn at the end of the frame
//!
//! A popup is on top because it is built last, and a toolbar button is built
//! in the middle of a toolbar. So the two halves are separate calls: `hint`
//! records what the pointer is resting on, and `tooltips` draws it after the
//! chrome is finished. `Tips` is the caller's, the way a checkbox's bool is,
//! and one of them serves a whole window -- there is one pointer, so there
//! is at most one tooltip.
//!
//! It waits. A tooltip that appears the instant the pointer crosses a button
//! is noise sweeping across the screen as the pointer travels; the delay is
//! what makes it an answer to a question rather than a reflex. The clock
//! restarts whenever the pointer moves to a different box, which is why
//! `Tips` remembers a key and not just a string.

const std = @import("std");

const geom = @import("../../gelgja/geom.zig");
const paint = @import("../../gelgja/paint.zig");

const Box = @import("../Box.zig");
const Theme = @import("../Theme.zig");
const UI = @import("../UI.zig");
const key = @import("../key.zig");
const popup = @import("popup.zig");

const Color = paint.Color;
const Key = key.Key;
const Point = geom.Point;
const Signal = UI.Signal;

pub const Error = UI.Error;

/// Square, at the sizes the icon slots will use: 24 on a toolbar, 20 on a
/// rail, 16 in a menu.
pub const size: f32 = 24;

pub const Options = struct {
    size: f32 = size,
    /// Drawn in the accent: the mode you are in, the panel that is open.
    on: bool = false,
    /// A widget has no theme, so the reader passes its own.
    accent: ?Color = null,
    disabled: bool = false,
};

/// A square button with a glyph in it and no border.
///
/// No border because a rail of bordered squares is a grid of boxes rather
/// than a row of controls; the hover lift is what says it can be pressed,
/// which is the same gesture every other control here uses.
pub fn iconButton(ui: *UI, name: []const u8, glyph: []const u8, opts: Options) Error!Signal {
    const st = ui.style();
    const accent = opts.accent orelse Theme.dark.accent;

    ui.nextDefaults(.{
        .w = .px(opts.size),
        .h = .px(opts.size),
        .text_align = .center,
        .radius = .all(4),
        .fg = if (opts.on) accent else mix(st.bg, st.fg, 0.78),
        .bg = if (opts.on) mix(st.bg, accent, 0.20) else st.bg.withAlpha(0),
        .flags = .{
            .clickable = true,
            .focusable = true,
            .draw_background = true,
            .draw_text = true,
            .hot_animation = true,
            .active_animation = true,
            .disabled = opts.disabled,
        },
    });
    return ui.signal(try ui.boxText(name, glyph));
}

/// A latch, with the state the caller's -- a rail button for a panel that is
/// open, or for the mode the keymap is in.
pub fn iconToggle(ui: *UI, name: []const u8, glyph: []const u8, on: *bool, opts: Options) Error!Signal {
    var o = opts;
    o.on = on.*;
    const sig = try iconButton(ui, name, glyph, o);
    if (sig.clicked) on.* = !on.*;
    return sig;
}

// -- tooltips ---------------------------------------------------------------

/// How long the pointer rests before a tooltip appears.
pub const delay: f64 = 0.45;
/// Room around the text.
pub const tip_pad: f32 = 6;
/// The gap between the button and its tooltip.
pub const tip_gap: f32 = 6;

/// The one tooltip a window can have, and what it is waiting on.
pub const Tips = struct {
    /// Copied rather than borrowed. The text usually outlives the frame and
    /// occasionally does not -- a page title formatted into a stack buffer
    /// inside the `if` that drew the button -- and a tooltip is not worth a
    /// lifetime rule at every call site.
    buf: [96]u8 = undefined,
    len: u8 = 0,

    /// Which box asked, so that moving between two buttons restarts the wait
    /// rather than showing the second one instantly.
    on: Key = .nil,
    since: f64 = 0,
    at: Point = .origin,
    asked: bool = false,

    pub fn text(t: *const Tips) []const u8 {
        return t.buf[0..t.len];
    }
};

/// Records that the pointer is resting on something with a name.
///
/// Called where the control is built, with the signal it returned. Does
/// nothing while a button is held: a tooltip that appears over the thing
/// being dragged is in the way of the gesture it is describing.
pub fn hint(ui: *UI, t: *Tips, sig: Signal, what: []const u8) void {
    if (!sig.hovering or ui.in.buttons.any() or what.len == 0) return;

    if (t.on != sig.box.key) {
        t.on = sig.box.key;
        t.since = ui.time;
    }
    t.len = @intCast(@min(what.len, t.buf.len));
    @memcpy(t.buf[0..t.len], what[0..t.len]);
    t.at = .{ .x = sig.box.rect.min_x, .y = sig.box.rect.max_y + tip_gap };
    t.asked = true;
}

/// Draws it, if anything asked and the wait is over. Goes at the end of the
/// frame, after the chrome and after any menu.
pub fn tooltips(ui: *UI, t: *Tips) Error!void {
    defer t.asked = false;

    if (!t.asked) {
        // Nothing under the pointer: forget where it was, so returning to the
        // same button waits again.
        t.on = .nil;
        return;
    }
    if (ui.time - t.since < delay) return;

    const st = ui.style();
    const p = try popup.open(ui, "tooltip", .{
        .at = t.at,
        .w = .children,
        .h = .children,
        // No backdrop: a tooltip is shown *because* the pointer is somewhere,
        // and a box over the whole window would take the click it is waiting
        // to describe.
        .backdrop = false,
        .shadow = 8,
    });
    defer popup.close(ui, p);

    ui.pushStyle(.{ .font_size = 12, .bg = mix(st.bg, st.fg, 0.08) });
    defer ui.popStyle();

    // The padding is the text size's, not a pair of spacers: a spacer is
    // `.fill`, and a percentage inside a box that sizes to its children looks
    // past it to the nearest ancestor that has a size -- which here is the
    // root, so the tooltip would be as wide as the window.
    ui.next(.{
        .w = .text(tip_pad),
        .h = .text(tip_pad * 0.5),
        .flags = .{ .draw_text = true },
    });
    _ = try ui.boxText("text", t.text());
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
const input = @import("../input.zig");

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

/// A rail of two buttons, with the tooltip layer after it.
fn oneFrame(ui: *UI, t: *Tips, open: *bool, in: input.Input) !void {
    try ui.begin(.fromRect(0, 0, 400, 300), in);

    ui.next(.{ .w = .px(size), .h = .fill, .axis = .y });
    const rail = try ui.open("rail");
    {
        defer ui.close(rail);
        hint(ui, t, try iconButton(ui, "bookmark", "B", .{}), "Bookmarks");
        hint(ui, t, try iconToggle(ui, "notes", "N", open, .{}), "Annotations");
    }

    try tooltips(ui, t);
    ui.end();
}

fn tipBox(ui: *UI) ?*Box {
    return ui.find(key.make(key.make(ui.root.key, "tooltip"), "text"));
}

test "a toggle latches the caller's bool and shows it in the accent" {
    var ui = scratch();
    defer ui.deinit();
    var t: Tips = .{};
    var open = false;

    const at: Point = .{ .x = 12, .y = 36 };
    try oneFrame(&ui, &t, &open, .{ .mouse = at });
    try oneFrame(&ui, &t, &open, .{ .mouse = at, .buttons = .{ .left = true } });
    try testing.expect(!open);

    try oneFrame(&ui, &t, &open, .{ .mouse = at });
    try testing.expect(open);

    // The bool flips after the box that reported the click was built, so the
    // colour arrives on the frame after -- which is what an immediate call
    // site means and is invisible at any frame rate.
    try oneFrame(&ui, &t, &open, .{ .mouse = at });

    // On is the accent and off is not, and nothing else on the rail is.
    const notes = ui.find(key.make(key.make(ui.root.key, "rail"), "notes")).?;
    const bookmark = ui.find(key.make(key.make(ui.root.key, "rail"), "bookmark")).?;
    try testing.expectEqual(Theme.dark.accent, notes.style.fg);
    try testing.expect(bookmark.style.fg.b != Theme.dark.accent.b);
}

test "a tooltip waits before it appears" {
    var ui = scratch();
    defer ui.deinit();
    var t: Tips = .{};
    var open = false;

    const at: Point = .{ .x = 12, .y = 12 };
    try oneFrame(&ui, &t, &open, .{ .mouse = at });
    try oneFrame(&ui, &t, &open, .{ .mouse = at });
    try testing.expect(tipBox(&ui) == null);

    // Half a second of resting, a frame at a time.
    var n: u32 = 0;
    while (n < 40) : (n += 1) {
        try oneFrame(&ui, &t, &open, .{ .mouse = at, .dt = 1.0 / 60.0 });
    }
    try testing.expectEqualStrings("Bookmarks", tipBox(&ui).?.text);
}

test "moving to the next button starts the wait again" {
    var ui = scratch();
    defer ui.deinit();
    var t: Tips = .{};
    var open = false;

    const first: Point = .{ .x = 12, .y = 12 };
    var n: u32 = 0;
    while (n < 40) : (n += 1) try oneFrame(&ui, &t, &open, .{ .mouse = first });
    try testing.expectEqualStrings("Bookmarks", tipBox(&ui).?.text);

    // One frame on the neighbour, and the tip is gone rather than swapped.
    const second: Point = .{ .x = 12, .y = 36 };
    try oneFrame(&ui, &t, &open, .{ .mouse = second });
    try oneFrame(&ui, &t, &open, .{ .mouse = second });
    try testing.expect(tipBox(&ui).?.last_frame < ui.frame_index);

    n = 0;
    while (n < 40) : (n += 1) try oneFrame(&ui, &t, &open, .{ .mouse = second });
    try testing.expectEqualStrings("Annotations", tipBox(&ui).?.text);
}

test "a pressed button shows no tooltip" {
    var ui = scratch();
    defer ui.deinit();
    var t: Tips = .{};
    var open = false;

    const at: Point = .{ .x = 12, .y = 12 };
    var n: u32 = 0;
    while (n < 40) : (n += 1) try oneFrame(&ui, &t, &open, .{ .mouse = at });
    try testing.expect(tipBox(&ui).?.last_frame == ui.frame_index);

    try oneFrame(&ui, &t, &open, .{ .mouse = at, .buttons = .{ .left = true } });
    try testing.expect(tipBox(&ui).?.last_frame < ui.frame_index);
}

test "a tooltip near an edge is pushed back inside" {
    var ui = scratch();
    defer ui.deinit();
    var t: Tips = .{};

    const build = struct {
        fn go(u: *UI, tips: *Tips) !void {
            try u.begin(.fromRect(0, 0, 400, 300), .{ .mouse = .{ .x = 384, .y = 290 } });
            u.next(.{ .w = .px(size), .h = .px(size), .fixed_x = 372, .fixed_y = 282, .flags = .{ .floating_x = true, .floating_y = true } });
            hint(u, tips, try iconButton(u, "b", "B", .{}), "Bookmarks");
            try tooltips(u, tips);
            u.end();
        }
    }.go;

    var n: u32 = 0;
    while (n < 40) : (n += 1) try build(&ui, &t);

    const tip = ui.find(key.make(ui.root.key, "tooltip")).?;
    try testing.expect(tip.rect.max_x <= 400);
    try testing.expect(tip.rect.max_y <= 300);
}
