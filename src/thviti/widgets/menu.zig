//! A menu: a popup full of rows, each a command and the key that runs it.
//!
//! `popup.zig` is the panel and the dismissal; everything here is what goes
//! inside one. The same contract applies and is the only one: build the
//! chrome, then build whatever menus are open, then end the frame.
//!
//! ## Keyboard first, and the menu says so
//!
//! The design language asks that every command's binding be drawn beside it,
//! so `item` takes one and draws it dim at the right. A button is a second
//! way to reach something the keymap already reaches, and a menu that hides
//! which key that is has broken the promise.
//!
//! Up, down, enter and escape work while the menu is open, against the item
//! count the *previous* frame built. That is exact rather than approximate: a
//! menu is built from the same list every frame, and one that changed its own
//! length while the keyboard was in it would have nowhere sensible to put the
//! highlight anyway.
//!
//! Enter cannot act where it is read, because the keys are read before any
//! item exists. It records which index it chose and `item` reports it as it
//! is built, so a row activated from the keyboard comes back through the same
//! return value as one that was clicked, and the caller cannot tell them
//! apart. That is the point.

const std = @import("std");

const geom = @import("../../gelgja/geom.zig");
const paint = @import("../../gelgja/paint.zig");

const Box = @import("../Box.zig");
const UI = @import("../UI.zig");
const popup = @import("popup.zig");
const w = @import("../widgets.zig");

const Color = paint.Color;
const Point = geom.Point;
const Popup = popup.Popup;
const Size = Box.Size;

pub const Error = UI.Error;

/// Dense, per the design language: twenty-pixel rows, not twenty-eight.
pub const item_height: f32 = 20;
pub const separator_height: f32 = 7;
/// Room above the first row and below the last.
pub const padding: f32 = 4;

/// Everything a menu remembers, which is the caller's the way a checkbox's
/// bool is. A menu whose open state lived in the box tree would be a menu
/// nothing else could open, close or ask about -- and the keymap has to be
/// able to do all three.
pub const Menu = struct {
    open: bool = false,
    /// Top-left, set when it is shown. Usually the bottom-left corner of
    /// whatever opened it.
    at: Point = .origin,

    /// The item the keyboard is on, or -1 for none.
    highlight: i32 = -1,
    /// Items built last frame, which is what the arrows wrap against.
    count: u32 = 0,
    /// The item enter chose, read by `item` as it is built and cleared by
    /// `end`.
    fired: i32 = -1,
    /// Counts items during the build.
    index: u32 = 0,

    pub fn show(m: *Menu, at: Point) void {
        m.open = true;
        m.at = at;
        m.highlight = -1;
    }

    pub fn hide(m: *Menu) void {
        m.open = false;
        m.highlight = -1;
        m.fired = -1;
    }

    pub fn toggle(m: *Menu, at: Point) void {
        if (m.open) m.hide() else m.show(at);
    }
};

pub const Options = struct {
    w: Size = .px(220),
};

/// Opens the menu, or returns null when it is closed.
pub fn begin(ui: *UI, name: []const u8, m: *Menu, opts: Options) Error!?Popup {
    if (!m.open) return null;

    keys(ui, m);
    if (!m.open) return null;

    m.index = 0;
    const p = try popup.open(ui, name, .{ .at = m.at, .w = opts.w });
    if (p.dismissed) m.hide();

    try w.spacer(ui, .px(padding));
    return p;
}

pub fn end(ui: *UI, m: *Menu, p: Popup) void {
    w.spacer(ui, .px(padding)) catch {};
    popup.close(ui, p);

    m.count = m.index;
    // Enter has been read by whichever item it named, so the menu closes here
    // rather than at the keystroke. That is what lets an item activated from
    // the keyboard report it the same way a clicked one does.
    if (m.fired >= 0) m.hide();
}

fn keys(ui: *UI, m: *Menu) void {
    for (ui.in.events) |e| switch (e) {
        .key_down => |k| switch (k.code) {
            .escape => {
                m.hide();
                return;
            },
            .down => m.highlight = step(m, 1),
            .up => m.highlight = step(m, -1),
            .enter => if (m.highlight >= 0) {
                m.fired = m.highlight;
            },
            else => {},
        },
        else => {},
    };
}

fn step(m: *Menu, by: i32) i32 {
    if (m.count == 0) return -1;
    const n: i32 = @intCast(m.count);
    // From nothing, down lands on the first row and up on the last.
    if (m.highlight < 0) return if (by > 0) 0 else n - 1;
    return @mod(m.highlight + by, n);
}

pub const ItemOptions = struct {
    /// Drawn dim at the right, where every menu in every program puts it.
    binding: []const u8 = "",
    disabled: bool = false,
};

/// One row. True when it was chosen, by the mouse or by the keyboard.
///
/// Hovering moves the highlight, so the two agree: a menu where the pointer
/// lights one row and enter takes another is a menu that has lied about what
/// it is about to do.
pub fn item(ui: *UI, m: *Menu, text: []const u8, opts: ItemOptions) Error!bool {
    const index = m.index;
    m.index += 1;

    const st = ui.style();
    const on = m.highlight == @as(i32, @intCast(index));

    ui.nextDefaults(.{
        .w = .fill,
        .h = .px(item_height),
        .axis = .x,
        .child_align = .center,
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .clip = true,
            .disabled = opts.disabled,
        },
        // Transparent rather than absent, so a highlighted row and a plain
        // one are the same box with one colour between them.
        .bg = if (on) mix(st.bg, st.fg, 0.16) else st.bg.withAlpha(0),
    });

    var name: [20]u8 = undefined;
    const b = try ui.open(std.fmt.bufPrint(&name, "###item{d}", .{index}) catch "###item");
    defer ui.close(b);

    const sig = ui.signal(b);
    if (sig.hovering) m.highlight = @intCast(index);

    try w.spacer(ui, .px(8));
    ui.next(.{ .w = .text(0), .h = .text(0), .flags = .{ .draw_text = true } });
    _ = try ui.boxText("label", text);

    if (opts.binding.len > 0) {
        try w.fill(ui);
        ui.next(.{
            .w = .text(0),
            .h = .text(0),
            .fg = mix(st.bg, st.fg, 0.62),
            .flags = .{ .draw_text = true },
        });
        _ = try ui.boxText("binding", opts.binding);
    }
    try w.spacer(ui, .px(8));

    // The arrows do not skip a disabled row -- which of them are disabled is
    // not known until they are built, and by then the key has been read. So
    // the highlight may rest on one, and enter refuses it here.
    if (opts.disabled) return false;
    return sig.clicked or m.fired == @as(i32, @intCast(index));
}

/// A rule between two groups. Not an item: it cannot be highlighted, so it
/// takes no index and the arrows do not stop on it.
pub fn separator(ui: *UI) Error!void {
    const st = ui.style();
    const gap = (separator_height - 1) * 0.5;

    try w.spacer(ui, .px(gap));
    ui.next(.{
        .w = .fill,
        .h = .px(1),
        .bg = mix(st.bg, st.fg, 0.22),
        .flags = .{ .draw_background = true },
    });
    _ = try ui.box("");
    try w.spacer(ui, .px(gap));
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
const key_make = @import("../key.zig").make;

fn scratch() UI {
    return .init(testing.allocator, UI.fixed_metrics);
}

/// A button, and the menu it opens -- built last, which is the contract.
fn oneFrame(ui: *UI, m: *Menu, in: input.Input) !bool {
    var chose = false;
    try ui.begin(.fromRect(0, 0, 400, 300), in);

    ui.next(.{ .w = .px(80), .h = .px(24) });
    if ((try w.button(ui, "File")).clicked) m.toggle(.{ .x = 0, .y = 24 });

    if (try begin(ui, "file menu", m, .{})) |p| {
        defer end(ui, m, p);
        if (try item(ui, m, "Open", .{ .binding = ":e" })) chose = true;
        try separator(ui);
        _ = try item(ui, m, "Close", .{ .binding = ":q" });
        _ = try item(ui, m, "Print", .{ .disabled = true });
    }

    ui.end();
    return chose;
}

/// The middle of the nth row, allowing for the padding and the separator
/// that sits between the first row and the second.
fn rowCentre(n: u32) Point {
    const rows: f32 = @floatFromInt(n);
    const rule: f32 = if (n > 0) separator_height else 0;
    return .{ .x = 30, .y = 24 + padding + rows * item_height + rule + item_height * 0.5 };
}

test "a menu opens under what opened it and takes the mouse first" {
    var ui = scratch();
    defer ui.deinit();
    var m: Menu = .{};

    const on_button: Point = .{ .x = 30, .y = 12 };
    _ = try oneFrame(&ui, &m, .{ .mouse = on_button });
    _ = try oneFrame(&ui, &m, .{ .mouse = on_button, .buttons = .{ .left = true } });
    _ = try oneFrame(&ui, &m, .{ .mouse = on_button });
    try testing.expect(m.open);

    const at = rowCentre(0);
    _ = try oneFrame(&ui, &m, .{ .mouse = at });
    _ = try oneFrame(&ui, &m, .{ .mouse = at });

    const menu_key = key_make(ui.root.key, "file menu");
    try testing.expect(ui.find(key_make(menu_key, "item0")).?.rect.contains(at));
    // Hovering and the keyboard share one highlight.
    try testing.expectEqual(@as(i32, 0), m.highlight);
}

test "clicking an item reports it, once, on the frame it is released" {
    var ui = scratch();
    defer ui.deinit();
    var m: Menu = .{ .open = true, .at = .{ .x = 0, .y = 24 } };

    const at = rowCentre(0);
    _ = try oneFrame(&ui, &m, .{ .mouse = at });
    _ = try oneFrame(&ui, &m, .{ .mouse = at });
    try testing.expect(!try oneFrame(&ui, &m, .{ .mouse = at, .buttons = .{ .left = true } }));

    try testing.expect(try oneFrame(&ui, &m, .{ .mouse = at }));
    try testing.expect(!try oneFrame(&ui, &m, .{ .mouse = at }));
}

test "the arrows walk the items and wrap, and escape closes" {
    var ui = scratch();
    defer ui.deinit();
    var m: Menu = .{ .open = true, .at = .{ .x = 0, .y = 24 } };

    // Nothing has been built on the first frame, so the count is only right
    // from the second -- which is when the arrows first have anywhere to go.
    _ = try oneFrame(&ui, &m, .{});
    try testing.expectEqual(@as(u32, 3), m.count);

    var down = [_]input.Event{.{ .key_down = .{ .code = .down } }};
    _ = try oneFrame(&ui, &m, .{ .events = &down });
    try testing.expectEqual(@as(i32, 0), m.highlight);
    _ = try oneFrame(&ui, &m, .{ .events = &down });
    _ = try oneFrame(&ui, &m, .{ .events = &down });
    try testing.expectEqual(@as(i32, 2), m.highlight);
    // Three items and no more: the separator is not one of them.
    _ = try oneFrame(&ui, &m, .{ .events = &down });
    try testing.expectEqual(@as(i32, 0), m.highlight);

    var up = [_]input.Event{.{ .key_down = .{ .code = .up } }};
    _ = try oneFrame(&ui, &m, .{ .events = &up });
    try testing.expectEqual(@as(i32, 2), m.highlight);

    var esc = [_]input.Event{.{ .key_down = .{ .code = .escape } }};
    _ = try oneFrame(&ui, &m, .{ .events = &esc });
    try testing.expect(!m.open);
}

test "enter chooses the highlighted item and closes the menu" {
    var ui = scratch();
    defer ui.deinit();
    var m: Menu = .{ .open = true, .at = .{ .x = 0, .y = 24 } };

    _ = try oneFrame(&ui, &m, .{});
    var down = [_]input.Event{.{ .key_down = .{ .code = .down } }};
    _ = try oneFrame(&ui, &m, .{ .events = &down });

    // The same return value a click comes back through.
    var enter = [_]input.Event{.{ .key_down = .{ .code = .enter } }};
    try testing.expect(try oneFrame(&ui, &m, .{ .events = &enter }));
    try testing.expect(!m.open);
    try testing.expectEqual(@as(i32, -1), m.fired);
}

test "a disabled item takes neither the click nor the highlight" {
    var ui = scratch();
    defer ui.deinit();
    var m: Menu = .{ .open = true, .at = .{ .x = 0, .y = 24 } };

    const at = rowCentre(2);
    _ = try oneFrame(&ui, &m, .{ .mouse = at });
    _ = try oneFrame(&ui, &m, .{ .mouse = at });

    const menu_key = key_make(ui.root.key, "file menu");
    try testing.expect(ui.find(key_make(menu_key, "item2")).?.rect.contains(at));
    try testing.expectEqual(@as(i32, -1), m.highlight);
}

test "a menu with a binding draws it beside the command" {
    var ui = scratch();
    defer ui.deinit();
    var m: Menu = .{ .open = true, .at = .{ .x = 0, .y = 24 } };

    _ = try oneFrame(&ui, &m, .{});
    _ = try oneFrame(&ui, &m, .{});

    const menu_key = key_make(ui.root.key, "file menu");
    const first = key_make(menu_key, "item0");
    const label = ui.find(key_make(first, "label")).?;
    const binding = ui.find(key_make(first, "binding")).?;

    try testing.expectEqualStrings("Open", label.text);
    try testing.expectEqualStrings(":e", binding.text);
    // Pushed to the far end by the fill between them, eight pixels in from
    // the edge, and never overlapping the label.
    try testing.expect(binding.rect.min_x > label.rect.max_x);
    try testing.expectApproxEqAbs(@as(f32, 8), 220 - binding.rect.max_x, 1e-3);
}
