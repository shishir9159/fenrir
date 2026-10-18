//! The rails: the thin columns of controls either side of the page.
//!
//! The right one carries the panel toggles at the top and the page counter at
//! the bottom, which is the arrangement the plan's sketch draws and the one
//! the design language argues for: the things you reach for are at the top
//! where the pointer already is, and the thing you *read* is at the bottom,
//! out of the way of both. The left one carries the modes and the highlight
//! palette, which are the two things a hand hovers over while reading.
//!
//! ## A rail is reserved, not floated
//!
//! `read.zig` takes the rail's width off the window rectangle exactly as it
//! takes the status bar's height, so a rail never covers the page and a
//! pointer over a rail is never also over a page. That costs one refit when a
//! rail is toggled -- `Layout.arrange` calls `refit` on every rectangle it
//! hands out -- and it buys away the whole question of which of the two a
//! click belonged to. The panels are the ones that overlay; see `panels.zig`.
//!
//! ## What this file knows, and what it does not
//!
//! A `Right` is a page number and a page count. A `Want` is a panel to show
//! or a page to go to. Between them there is no view, no buffer and no
//! document, which is the division `chrome.zig` draws for the status bar and
//! `settings.zig` for the settings page -- and it is what lets a rail be
//! built, hovered and clicked in a test with no window and no PDF.
//!
//! ## What a rail button is
//!
//! The same `Command` the key sends, reached a second way. A rail is never
//! the only way to anything: the panel toggles are latches over state the
//! reader already keeps, and the left rail's modes *are* `keys.Mode` -- the
//! button lights from the mode the keymap is in, and pressing one goes
//! through `keys.enter`, which is the function the `v` key would call if a
//! key could. The palette is the same arrangement one step further along:
//! `keys.paletteCommand` says what a colour means in a mode, and the digits
//! and the swatches both ask it.
//!
//! ## The counter is a control, the way the zoom is
//!
//! A number drawn in a corner that cannot be typed into is a number somebody
//! will try to type into. Clicking it turns it into a field, the same trade
//! the settings page makes for a value cell -- and with the same consequence,
//! which is that it has to ask for focus the frame it appears, because the
//! press that started the edit landed on the box the field replaced.

const std = @import("std");
const fenrir = @import("fenrir");

const thviti = fenrir.thviti;

const Color = fenrir.gelgja.Color;
const Fonts = fenrir.tyr.Fonts;
const Icons = thviti.Icons;
const Theme = thviti.Theme;
const UI = thviti.UI;
const keys = fenrir.hlidskjalf.keys;
const w = thviti.widgets;

pub const Error = UI.Error;

/// How wide a rail is. Two button-widths of icon and a five-pixel gutter
/// either side: wide enough that a three-digit page number fits under the
/// buttons, narrow enough to read as furniture rather than as a column.
pub const width: f32 = 34;

/// The button inside it, which is `tool.size`. Named here because the gutter
/// is the difference between the two and neither number means anything alone.
const button: f32 = w.tool.size;
const inset: f32 = (width - button) / 2;

/// The counter at the foot of the rail: the page over the count.
const counter_height: f32 = 38;
const counter_text: f32 = 12;

/// The longest page number worth a field. A million pages is a hundred times
/// the largest PDF anybody has made.
const page_digits = 7;

/// Which overlay is showing. One at a time: they dock to the same edge and
/// two of them would be a second split tree nobody asked for.
///
/// A union rather than an enum since a plugin can declare one: its variant
/// carries the contribution's id, because the rail cannot have a name for
/// something it has never heard of. The label and the icon of one come from
/// `Right.panels` beside it, for the same reason.
pub const Panel = union(enum) {
    none,
    /// The highlights in this document, and what is written on them.
    annotations,
    /// The document's own outline, and the places a reader has kept.
    bookmarks,
    /// A plugin's, by its contribution id.
    plugin: u32,

    pub fn eql(a: Panel, b: Panel) bool {
        return std.meta.eql(a, b);
    }

    /// What the rail's button for it is called, and what its tooltip says.
    /// Empty for a plugin's, which the rail is told separately.
    pub fn label(p: Panel) []const u8 {
        return switch (p) {
            .none, .plugin => "",
            .annotations => "Annotations",
            .bookmarks => "Bookmarks",
        };
    }

    /// The icon id, resolved through the registry like every other.
    pub fn icon(p: Panel) []const u8 {
        return switch (p) {
            .none, .plugin => "fenrir.unknown",
            .annotations => "fenrir.highlight",
            .bookmarks => "fenrir.bookmark",
        };
    }
};

/// The panels the rail has a button for, in the order it draws them.
pub const toggles = [_]Panel{ .annotations, .bookmarks };

/// A panel a plugin declared: a latch on the rail, beside the reader's own.
///
/// Above the rule and not below it, unlike `Extra`: a panel *is* one of the
/// things this rail is for, and a reader looking for the list of panels
/// should find them all in one column.
pub const PanelToggle = struct {
    id: u32,
    label: []const u8,
    icon: []const u8,
};

/// A button a plugin put here.
///
/// An icon *name* and a number, and nothing else: the rail does not know what
/// a plugin is and does not resolve the picture -- `Icons.byName` does that,
/// and a name it has never heard of draws as the hollow box, which is the
/// registry's whole answer to a missing icon and is better than a rail with a
/// hole in it.
pub const Extra = struct {
    id: u32,
    label: []const u8,
    icon: []const u8,
};

/// What the rail shows, as the reader knows it.
pub const Right = struct {
    /// Numbered from one, as a person numbers them.
    page: u32 = 1,
    pages: u32 = 1,
    /// The panels plugins declared, latching beside the reader's own.
    panels: []const PanelToggle = &.{},
    /// The plugins' buttons, under the reader's own and under a rule: the
    /// things this program does are above the things somebody added.
    extra: []const Extra = &.{},
};

/// What the rail was asked for. A request and not an action, as
/// `chrome.ZoomWant` is: the rail has no view to act on.
pub const Want = union(enum) {
    /// Show this one, or `.none` to close whatever is open.
    panel: Panel,
    /// Go here, numbered from one.
    page: u32,
    /// Go into this mode. The same `keys.Mode` the keymap has, not a
    /// parallel idea of one: `keys.enter` is what both ways in go through.
    mode: keys.Mode,
    /// The palette colour a digit picks, numbered as `keys` numbers them --
    /// zero is `1`. What it *does* depends on the mode, which is a question
    /// `keys.paletteCommand` answers for the rail and the keyboard alike.
    colour: u8,
    /// Run the plugin's button with this id. What it does is the plugin's to
    /// say, exactly as a rail button of the reader's own goes through `keys`:
    /// a rail names a thing and something else knows what the thing means.
    plugin: u32,
};

/// One colour in the left rail's palette, as the reader names it.
pub const Swatch = struct {
    /// For the tooltip. The rail does not know what colours are called.
    name: []const u8,
    color: Color,
};

/// What the left rail shows.
pub const Left = struct {
    mode: keys.Mode = .normal,
    /// The colours a digit picks, in that order: the first is `1`.
    palette: []const Swatch = &.{},
    extra: []const Extra = &.{},
};

/// The modes the rail has a button for, in the order it draws them.
///
/// Not every mode. `visual_line` is `V` and is the same button as `v` with a
/// different gesture behind it; `note` and `command` are things you are in
/// the middle of rather than places you go; `draw` has no commands behind it
/// yet and a button that does nothing is worse than no button.
pub const mode_buttons = [_]keys.Mode{ .normal, .visual, .edit };

fn modeLabel(m: keys.Mode) []const u8 {
    return switch (m) {
        .visual, .visual_line => "Visual",
        .edit, .note => "Edit",
        .command => "Command",
        .normal => "Normal",
    };
}

fn modeIcon(m: keys.Mode) []const u8 {
    return switch (m) {
        .visual, .visual_line => "fenrir.visual",
        .edit, .note => "fenrir.edit",
        .normal, .command => "fenrir.normal",
    };
}

/// The key that reaches a mode, drawn in its tooltip. The design language
/// asks for it everywhere a command has a binding, and a rail is no
/// exception: the button is the second way in, and the tooltip is where it
/// says what the first one is.
fn modeKey(m: keys.Mode) []const u8 {
    return switch (m) {
        .visual, .visual_line => "v",
        .edit, .note => "i",
        .command => ":",
        .normal => "escape",
    };
}

/// Which rail button is lit for a mode. Note mode is edit mode with a note
/// half typed, and visual-line is visual with whole lines; neither is a
/// fourth button.
fn buttonFor(m: keys.Mode) keys.Mode {
    return switch (m) {
        .visual, .visual_line => .visual,
        .edit, .note => .edit,
        .normal, .command => .normal,
    };
}

/// The rails' own state, kept by the reader for the reason a checkbox's bool
/// is: the reader has to be able to ask whether the rail is holding the
/// keyboard *before* it reads a key, and the box tree for this frame does not
/// exist yet.
pub const Rails = struct {
    /// Which overlay is open.
    panel: Panel = .none,

    /// The counter is being typed in.
    editing: bool = false,
    /// Its model. `bytes` is an interior pointer into `page_buf` and is
    /// re-aimed at it every frame, so this survives being copied -- which it
    /// has to, since a `Session` is returned by value in the reader's tests.
    field: w.Field = .{ .bytes = &.{} },
    page_buf: [page_digits]u8 = undefined,
    /// The field has just appeared and wants the keyboard. See the header.
    focus_next: bool = false,

    pub fn show(r: *Rails, p: Panel) void {
        r.panel = p;
    }

    /// The same button twice closes what it opened, which is what a latch on
    /// a rail is for.
    pub fn toggle(r: *Rails, p: Panel) void {
        r.panel = if (r.panel.eql(p)) .none else p;
    }

    /// Whether the rails are holding this frame's keyboard, which they are
    /// while a page number is being typed. Asked before the keymap reads a
    /// key, which is why it is answered from here and not from the tree.
    pub fn grabbing(r: *const Rails) bool {
        return r.editing;
    }

    /// What a click on the counter does. Named because the test drives it
    /// without a pointer, and because it is the one place the field's three
    /// pieces of setup have to happen together.
    fn beginEdit(r: *Rails, page: u32) void {
        r.editing = true;
        r.focus_next = true;
        r.field.bytes = &r.page_buf;
        var buf: [page_digits]u8 = undefined;
        // What is there already, selected: the first digit replaces it, which
        // is what every page box anywhere does.
        r.field.set(std.fmt.bufPrint(&buf, "{d}", .{page}) catch "");
        r.field.selectAll();
    }
};

/// The right rail, and what it was asked for.
///
/// Built inside the frame like the status bar and not as a popup: it is
/// chrome, it occupies reserved space, and nothing is on top of it.
pub fn rightRail(
    ui: *UI,
    face: Fonts.FontId,
    t: Theme,
    icons: *const Icons,
    st: Right,
    r: *Rails,
    tips: *w.Tips,
    top: f32,
) Error!?Want {
    // Before the build, so the field sees it in the same frame it is first
    // drawn in: `signal` reads `ui.focus`, and a focus set afterwards would
    // cost a frame of typing.
    if (r.focus_next) {
        r.focus_next = false;
        ui.setFocus(thviti.key.make(thviti.key.make(ui.root.key, "right rail"), "page"));
    }
    // Re-aimed every frame rather than on creation: see `Rails.field`.
    r.field.bytes = &r.page_buf;

    ui.pushStyle(.{ .font = face, .font_size = counter_text, .fg = t.text, .bg = t.panel });
    defer ui.popStyle();

    ui.next(.{
        .w = .px(width),
        .h = .px(@max(ui.viewport.height() - top - reserved_below, 1)),
        .axis = .y,
        .child_align = .center,
        .fixed_x = ui.viewport.width() - width,
        .fixed_y = top,
        .flags = .{
            .floating_x = true,
            .floating_y = true,
            .draw_background = true,
            .clip = true,
        },
    });
    const rail = try ui.open("right rail");
    defer ui.close(rail);

    var want: ?Want = null;

    try w.spacer(ui, .px(inset));
    for (toggles) |p| {
        const sig = try w.iconButton(ui, p.label(), icons.byName(p.icon(), .sidebar), .{
            .on = r.panel.eql(p),
            .accent = t.accent,
        });
        w.tool.hint(ui, tips, sig, p.label());
        if (sig.clicked) want = .{ .panel = if (r.panel.eql(p)) .none else p };
        try w.spacer(ui, .px(2));
    }
    for (st.panels, 0..) |p, i| {
        const which: Panel = .{ .plugin = p.id };
        // Keyed by position, not by the plugin's id, for the reason `extras`
        // gives: a panel removed should not hand the next one a new box.
        var name: [24]u8 = undefined;
        const sig = try w.iconButton(
            ui,
            std.fmt.bufPrint(&name, "panel{d}", .{i}) catch "panel",
            icons.byName(p.icon, .sidebar),
            .{ .on = r.panel.eql(which), .accent = t.accent },
        );
        w.tool.hint(ui, tips, sig, p.label);
        if (sig.clicked) want = .{ .panel = if (r.panel.eql(which)) .none else which };
        try w.spacer(ui, .px(2));
    }

    if (try extras(ui, t, icons, tips, st.extra, "right")) |id| want = .{ .plugin = id };

    try w.fill(ui);
    if (try counter(ui, t, st, r)) |page| want = .{ .page = page };

    return want;
}

/// The plugins' buttons, under a rule that separates them from the reader's.
///
/// Keyed by the rail rather than by the plugin's id, because a rail full of
/// buttons that come and go should still have one box per position -- an id
/// in the key would give the second button a new box the moment the first was
/// removed, and with it a new hover and a new animation.
fn extras(
    ui: *UI,
    t: Theme,
    icons: *const Icons,
    tips: *w.Tips,
    list: []const Extra,
    side: []const u8,
) Error!?u32 {
    if (list.len == 0) return null;
    try w.spacer(ui, .px(inset));
    ui.next(.{
        .w = .px(button - 6),
        .h = .px(1),
        .bg = t.border,
        .flags = .{ .draw_background = true },
    });
    var rule_name: [24]u8 = undefined;
    _ = try ui.box(std.fmt.bufPrint(&rule_name, "###{s} plugin rule", .{side}) catch "###plugin rule");
    try w.spacer(ui, .px(inset));

    var chosen: ?u32 = null;
    for (list, 0..) |e, i| {
        // `iconButton` goes through `boxText`, where the name is the key
        // alone and the picture is the text -- so the label has no business
        // in it, and a plugin renaming its button keeps the box it had.
        var name: [24]u8 = undefined;
        const sig = try w.iconButton(
            ui,
            std.fmt.bufPrint(&name, "plugin{d}", .{i}) catch "plugin",
            icons.byName(e.icon, .sidebar),
            .{ .accent = t.accent },
        );
        w.tool.hint(ui, tips, sig, e.label);
        if (sig.clicked) chosen = e.id;
        try w.spacer(ui, .px(2));
    }
    return chosen;
}

/// How much of the window a rail leaves alone at the bottom. The status bar
/// is drawn over the same pixels the rail would otherwise reach, and a rail
/// that ran behind it would put its counter under the mode line.
pub const reserved_below: f32 = @import("chrome.zig").status_height;

/// The left rail: which mode you are in, and what colour you are marking in.
///
/// The mode buttons are not a parallel notion of a mode. They are
/// `keys.Mode`, they light from the mode the keymap is in, and pressing one
/// goes through `keys.enter` -- the same function the `v` key would have gone
/// through if there were a way to make a key call it. A rail is the second
/// way to something the keyboard already reaches, never the only way.
pub fn leftRail(
    ui: *UI,
    face: Fonts.FontId,
    t: Theme,
    icons: *const Icons,
    st: Left,
    tips: *w.Tips,
    top: f32,
) Error!?Want {
    ui.pushStyle(.{ .font = face, .font_size = counter_text, .fg = t.text, .bg = t.panel });
    defer ui.popStyle();

    ui.next(.{
        .w = .px(width),
        .h = .px(@max(ui.viewport.height() - top - reserved_below, 1)),
        .axis = .y,
        .child_align = .center,
        .fixed_x = 0,
        .fixed_y = top,
        .flags = .{
            .floating_x = true,
            .floating_y = true,
            .draw_background = true,
            .clip = true,
        },
    });
    const rail = try ui.open("left rail");
    defer ui.close(rail);

    var want: ?Want = null;
    const lit = buttonFor(st.mode);

    try w.spacer(ui, .px(inset));
    for (mode_buttons) |m| {
        const sig = try w.iconButton(ui, modeLabel(m), icons.byName(modeIcon(m), .sidebar), .{
            .on = lit == m,
            .accent = t.accent,
        });
        var hint: [40]u8 = undefined;
        w.tool.hint(ui, tips, sig, std.fmt.bufPrint(&hint, "{s} ({s})", .{
            modeLabel(m), modeKey(m),
        }) catch modeLabel(m));
        if (sig.clicked) want = .{ .mode = m };
        try w.spacer(ui, .px(2));
    }

    if (st.palette.len != 0) {
        try w.spacer(ui, .px(inset));
        ui.next(.{
            .w = .px(button - 6),
            .h = .px(1),
            .bg = t.border,
            .flags = .{ .draw_background = true },
        });
        _ = try ui.box("###rule");
        try w.spacer(ui, .px(inset));
    }

    for (st.palette, 0..) |s, i| {
        if (try swatch(ui, t, tips, s, @intCast(i))) want = .{ .colour = @intCast(i) };
        try w.spacer(ui, .px(3));
    }

    if (try extras(ui, t, icons, tips, st.extra, "left")) |id| want = .{ .plugin = id };

    try w.fill(ui);
    return want;
}

/// One colour of the palette. A filled square and nothing else: the colour is
/// the whole content, so a glyph on top of it would be a second thing to read
/// in a control that has one.
fn swatch(ui: *UI, t: Theme, tips: *w.Tips, s: Swatch, index: u8) Error!bool {
    ui.next(.{
        .w = .px(button - 6),
        .h = .px(button - 6),
        .bg = s.color,
        .border_color = t.border,
        .radius = .all(3),
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .draw_border = true,
            .hot_animation = true,
            .active_animation = true,
        },
    });
    var name: [16]u8 = undefined;
    const sig = ui.signal(try ui.box(std.fmt.bufPrint(&name, "###colour{d}", .{index}) catch "###colour"));

    // The digit that picks it, beside its name: the rail is the second way to
    // a colour and the keyboard is the first.
    var hint: [48]u8 = undefined;
    w.tool.hint(ui, tips, sig, std.fmt.bufPrint(&hint, "{s} ({d})", .{ s.name, index + 1 }) catch s.name);
    return sig.clicked;
}

/// The page counter at the foot of the rail: the page over the count, and a
/// field when it is clicked.
fn counter(ui: *UI, t: Theme, st: Right, r: *Rails) Error!?u32 {
    if (r.editing) {
        const res = try w.field.textField(ui, "page", &r.field, .{
            .w = .px(width - 4),
            .h = .px(22),
        });
        try w.spacer(ui, .px(inset));

        if (res.cancelled) {
            r.editing = false;
            return null;
        }
        if (!res.submitted) return null;

        // Over either way. A refused number is not a reason to keep somebody
        // in a field, and the counter coming back with the old number in it
        // is what says the page did not move.
        r.editing = false;
        const typed = std.fmt.parseInt(u32, std.mem.trim(u8, r.field.slice(), " "), 10) catch
            return null;
        if (typed == 0 or typed > st.pages) return null;
        return typed;
    }

    ui.next(.{
        .w = .px(width - 4),
        .h = .px(counter_height),
        .axis = .y,
        .child_align = .center,
        .radius = .all(4),
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .hot_animation = true,
            .active_animation = true,
            .clip = true,
        },
    });
    const cell = try ui.open("page");
    const sig = ui.signal(cell);
    {
        defer ui.close(cell);
        _ = try w.labelf(ui, "{d}###now", .{st.page});
        // The count is read once and the page is read every time you move,
        // so only one of the two is drawn to be read first.
        ui.next(.{ .fg = t.text_dim, .font_size = counter_text - 1 });
        _ = try w.labelf(ui, "/{d}###of", .{st.pages});
    }
    try w.spacer(ui, .px(inset));

    if (sig.clicked) r.beginEdit(st.page);
    return null;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const key = thviti.key;
const Input = thviti.Input;
const Point = fenrir.gelgja.Point;

/// A registry with the built-in icons in it, over a `Fonts` with no faces
/// open. Nothing here rasterises, so the fallback is enough.
const Rig = struct {
    fonts: Fonts,
    icons: Icons,
    ui: UI,
    tips: w.Tips = .{},

    fn init(rig: *Rig) !void {
        rig.* = .{
            .fonts = try .init(testing.allocator, .{}),
            .icons = undefined,
            .ui = .init(testing.allocator, UI.fixed_metrics),
        };
        rig.icons = try .init(testing.allocator, &rig.fonts);
    }

    fn deinit(rig: *Rig) void {
        rig.ui.deinit();
        rig.icons.deinit();
        rig.fonts.deinit();
    }

    fn frame(rig: *Rig, st: Right, r: *Rails, in: Input) !?Want {
        try rig.ui.begin(.fromRect(0, 0, 900, 600), in);
        const want = try rightRail(&rig.ui, Fonts.fallback_font, .dark, &rig.icons, st, r, &rig.tips, 0);
        rig.ui.end();
        return want;
    }

    fn frameLeft(rig: *Rig, st: Left, in: Input) !?Want {
        try rig.ui.begin(.fromRect(0, 0, 900, 600), in);
        const want = try leftRail(&rig.ui, Fonts.fallback_font, .dark, &rig.icons, st, &rig.tips, 0);
        rig.ui.end();
        return want;
    }

    fn find(rig: *Rig, name: []const u8) ?*thviti.Box {
        return rig.ui.find(key.make(key.make(rig.ui.root.key, "right rail"), name));
    }

    fn findLeft(rig: *Rig, name: []const u8) ?*thviti.Box {
        return rig.ui.find(key.make(key.make(rig.ui.root.key, "left rail"), name));
    }

    fn clickLeft(rig: *Rig, st: Left, at: Point) !?Want {
        _ = try rig.frameLeft(st, .{ .mouse = at });
        _ = try rig.frameLeft(st, .{ .mouse = at, .buttons = .{ .left = true } });
        return rig.frameLeft(st, .{ .mouse = at });
    }

    /// Onto a box, press, release: a press only reaches a box the pointer was
    /// already over, here as with a real mouse.
    fn click(rig: *Rig, st: Right, r: *Rails, at: Point) !?Want {
        _ = try rig.frame(st, r, .{ .mouse = at });
        _ = try rig.frame(st, r, .{ .mouse = at, .buttons = .{ .left = true } });
        return rig.frame(st, r, .{ .mouse = at });
    }
};

fn middleOf(b: *thviti.Box) Point {
    return .{
        .x = (b.rect.min_x + b.rect.max_x) * 0.5,
        .y = (b.rect.min_y + b.rect.max_y) * 0.5,
    };
}

test "the rail is a column against the right edge, clear of the status bar" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var r: Rails = .{};
    _ = try rig.frame(.{ .page = 7, .pages = 48 }, &r, .{});

    const rail = rig.ui.root.first.?;
    try testing.expectEqual(@as(f32, 900 - width), rail.rect.min_x);
    try testing.expectEqual(@as(f32, 900), rail.rect.max_x);
    try testing.expectEqual(@as(f32, 0), rail.rect.min_y);
    try testing.expectEqual(600 - reserved_below, rail.rect.max_y);
}

test "the counter says where you are and how far it goes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var r: Rails = .{};
    _ = try rig.frame(.{ .page = 7, .pages = 48 }, &r, .{});

    const cell = rig.find("page").?;
    try testing.expectEqualStrings("7", rig.ui.find(key.make(cell.key, "now")).?.text);
    try testing.expectEqualStrings("/48", rig.ui.find(key.make(cell.key, "of")).?.text);
    // At the foot of the rail rather than floating in the middle of it.
    try testing.expect(cell.rect.max_y > rail_foot);
}

const rail_foot: f32 = 600 - reserved_below - counter_height - inset - 1;

test "a panel button asks for its panel, and the same button closes it" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var r: Rails = .{};
    const st: Right = .{ .page = 1, .pages = 9 };
    _ = try rig.frame(st, &r, .{});

    const at = middleOf(rig.find("Annotations").?);
    const first = (try rig.click(st, &r, at)).?;
    try testing.expectEqual(Panel.annotations, first.panel);

    // The reader is what writes it down, as with every other request here.
    r.toggle(.annotations);
    try testing.expectEqual(Panel.annotations, r.panel);

    const second = (try rig.click(st, &r, at)).?;
    try testing.expectEqual(Panel.none, second.panel);
}


test "the counter is typed in, and enter is what goes there" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var r: Rails = .{};
    const st: Right = .{ .page = 7, .pages = 48 };
    _ = try rig.frame(st, &r, .{});

    const at = middleOf(rig.find("page").?);
    try testing.expect(try rig.click(st, &r, at) == null);
    try testing.expect(r.editing);
    try testing.expect(r.grabbing());
    try testing.expectEqualStrings("7", r.field.slice());
    try testing.expect(r.field.hasSelection());

    // A frame to build the field and let it take focus, then type.
    _ = try rig.frame(st, &r, .{ .mouse = at });
    _ = try rig.frame(st, &r, .{ .mouse = at, .events = &.{.{ .text = "23" }} });
    try testing.expectEqualStrings("23", r.field.slice());

    const want = (try rig.frame(st, &r, .{
        .mouse = at,
        .events = &.{.{ .key_down = .{ .code = .enter } }},
    })).?;
    try testing.expectEqual(@as(u32, 23), want.page);
    try testing.expect(!r.editing);
}

test "escape drops the edit and asks for nothing" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var r: Rails = .{};
    const st: Right = .{ .page = 7, .pages = 48 };
    _ = try rig.frame(st, &r, .{});
    r.beginEdit(st.page);
    _ = try rig.frame(st, &r, .{});
    r.field.set("23");

    const out = try rig.frame(st, &r, .{
        .events = &.{.{ .key_down = .{ .code = .escape } }},
    });
    try testing.expect(out == null);
    try testing.expect(!r.editing);
}

test "a page past the end asks for nothing, and so does a word" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const st: Right = .{ .page = 7, .pages = 48 };
    const enter: Input = .{ .events = &.{.{ .key_down = .{ .code = .enter } }} };

    for ([_][]const u8{ "49", "0", "", "seven" }) |typed| {
        var r: Rails = .{};
        _ = try rig.frame(st, &r, .{});
        // The click, without the pointer: `beginEdit` is what one calls.
        r.beginEdit(st.page);
        _ = try rig.frame(st, &r, .{});
        r.field.set(typed);

        try testing.expect(try rig.frame(st, &r, enter) == null);
        try testing.expect(!r.editing);
    }
}

test "a rail state survives being copied, field and all" {
    // A `Session` is returned by value in the reader's own tests, so a state
    // holding a pointer into itself has to be able to take that.
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var first: Rails = .{};
    _ = try rig.frame(.{ .page = 3, .pages = 9 }, &first, .{});

    var second = first;
    second.editing = true;
    second.field.bytes = &.{};
    _ = try rig.frame(.{ .page = 3, .pages = 9 }, &second, .{});

    second.field.set("5");
    try testing.expectEqualStrings("5", second.field.slice());
    try testing.expect(second.field.bytes.ptr == &second.page_buf);
}

// -- the left rail ----------------------------------------------------------

const palette = [_]Swatch{
    .{ .name = "the usual colour", .color = .gray(0.42) },
    .{ .name = "yellow", .color = .{ .r = 1, .g = 0.9, .b = 0.2 } },
    .{ .name = "green", .color = .{ .r = 0.3, .g = 0.8, .b = 0.4 } },
};

test "the left rail is a column against the near edge" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.frameLeft(.{ .palette = &palette }, .{});
    const rail = rig.ui.root.first.?;
    try testing.expectEqual(@as(f32, 0), rail.rect.min_x);
    try testing.expectEqual(width, rail.rect.max_x);
    try testing.expectEqual(600 - reserved_below, rail.rect.max_y);
}

test "one button is lit, and it is the one for the mode the keymap is in" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    // Note mode is edit mode with a note half typed, and visual-line is
    // visual with whole lines. Neither is a fourth button.
    try testing.expectEqual(keys.Mode.edit, buttonFor(.note));
    try testing.expectEqual(keys.Mode.visual, buttonFor(.visual_line));
    try testing.expectEqual(keys.Mode.normal, buttonFor(.command));

    for ([_]keys.Mode{ .normal, .visual, .visual_line, .edit, .note }) |m| {
        _ = try rig.frameLeft(.{ .mode = m, .palette = &palette }, .{});
        var lit: u32 = 0;
        for (mode_buttons) |b| {
            const box = rig.findLeft(modeLabel(b)).?;
            // An icon button draws in the accent when it is on, and the
            // accent is the one colour in the rail that is not a grey.
            if (box.style.fg.b > box.style.fg.r + 0.05) lit += 1;
        }
        try testing.expectEqual(@as(u32, 1), lit);
    }
}

test "a mode button asks for its mode, and the keymap is what enters it" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const st: Left = .{ .mode = .normal, .palette = &palette };
    _ = try rig.frameLeft(st, .{});

    const want = (try rig.clickLeft(st, middleOf(rig.findLeft("Visual").?))).?;
    try testing.expectEqual(keys.Mode.visual, want.mode);

    // And what that means is `keys`', not the rail's: the same command `v`
    // pushes, with the mode already moved.
    var state: keys.State = .{};
    try testing.expectEqual(keys.Command.enter_visual, keys.enter(&state, want.mode));
    try testing.expectEqual(keys.Mode.visual, state.mode);
}

test "a swatch asks for the colour its digit picks" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const st: Left = .{ .mode = .visual, .palette = &palette };
    _ = try rig.frameLeft(st, .{});

    const want = (try rig.clickLeft(st, middleOf(rig.findLeft("colour1").?))).?;
    try testing.expectEqual(@as(u8, 1), want.colour);

    // Which in visual mode is the highlight the digit `2` would have made --
    // the swatch and the key go through one table, so they cannot drift.
    const cmd = keys.paletteCommand(.visual, want.colour).?;
    try testing.expectEqual(@as(?u8, 1), cmd.highlight_selection);
    // And in normal mode a colour means nothing at all, from either way in.
    try testing.expect(keys.paletteCommand(.normal, want.colour) == null);
}

test "a rail with no palette draws the modes and no rule under them" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.frameLeft(.{}, .{});
    try testing.expect(rig.findLeft("Normal") != null);
    try testing.expect(rig.findLeft("rule") == null);
    try testing.expect(rig.findLeft("colour0") == null);
}

test "a plugin's buttons sit under the reader's own, with a rule between" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const extra = [_]Extra{
        .{ .id = 7, .label = "Reading list", .icon = "fenrir.bookmark" },
        // An icon no theme has: it draws as the registry's hollow box rather
        // than leaving a hole where a button should be.
        .{ .id = 9, .label = "Sync", .icon = "nobody.has.this" },
    };

    var r: Rails = .{};
    const st: Right = .{ .page = 1, .pages = 4, .extra = &extra };
    _ = try rig.frame(st, &r, .{});

    try testing.expect(rig.find("right plugin rule") != null);
    const first = rig.find("plugin0").?;
    const second = rig.find("plugin1").?;
    // Under the reader's own toggles, in the order the plugins added them.
    try testing.expect(first.rect.min_y > rig.find("Annotations").?.rect.max_y);
    try testing.expect(second.rect.min_y > first.rect.max_y);

    try testing.expectEqual(@as(u32, 7), (try rig.click(st, &r, middleOf(first))).?.plugin);
    try testing.expectEqual(@as(u32, 9), (try rig.click(st, &r, middleOf(second))).?.plugin);

    // And the left rail takes them too, under the swatches.
    const left: Left = .{ .palette = &palette, .extra = extra[0..1] };
    _ = try rig.frameLeft(left, .{});
    try testing.expect(rig.findLeft("left plugin rule") != null);
    try testing.expectEqual(@as(u32, 7), (try rig.clickLeft(left, middleOf(rig.findLeft("plugin0").?))).?.plugin);
}

test "no plugin buttons, no rule to separate them from" {
    // Its own rig, because `UI.find` walks the tree the last frame left
    // behind: a box that is not built this frame is still findable, so the
    // absence of one can only be checked by a rail that never had it.
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var r: Rails = .{};
    _ = try rig.frame(.{ .page = 1, .pages = 4 }, &r, .{});
    try testing.expect(rig.find("Annotations") != null);
    try testing.expect(rig.find("right plugin rule") == null);
    try testing.expect(rig.find("plugin0") == null);
}

test "a plugin's panel latches beside the reader's own" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const declared = [_]PanelToggle{
        .{ .id = 5, .label = "Reading list", .icon = "fenrir.bookmark" },
    };
    var r: Rails = .{};
    const st: Right = .{ .page = 1, .pages = 4, .panels = &declared };
    _ = try rig.frame(st, &r, .{});

    // Above the rule, with the reader's own: a panel is one of the things
    // this rail is for, wherever it was declared.
    const toggle = rig.find("panel0").?;
    try testing.expect(toggle.rect.min_y > rig.find("Bookmarks").?.rect.max_y);

    const want = (try rig.click(st, &r, middleOf(toggle))).?;
    try testing.expectEqual(@as(u32, 5), want.panel.plugin);

    // And it latches: the same button again closes what it opened, which is
    // the rule every other panel toggle here follows.
    r.toggle(want.panel);
    try testing.expect(r.panel.eql(.{ .plugin = 5 }));
    r.toggle(want.panel);
    try testing.expect(r.panel.eql(.none));
    r.toggle(.{ .plugin = 5 });
    r.toggle(.annotations);
    try testing.expect(r.panel.eql(.annotations));
}
