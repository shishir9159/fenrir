//! The rails: the thin columns of controls either side of the page.
//!
//! The right one is here. It carries the panel toggles at the top and the
//! page counter at the bottom, which is the arrangement the plan's sketch
//! draws and the one the design language argues for: the things you reach for
//! are at the top where the pointer already is, and the thing you *read* is
//! at the bottom, out of the way of both.
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
//! the only way to anything: the panel toggles here are latches over state
//! the reader already keeps, and the keymap will reach the same state.
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

const Fonts = fenrir.tyr.Fonts;
const Icons = thviti.Icons;
const Theme = thviti.Theme;
const UI = thviti.UI;
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
pub const Panel = enum {
    none,
    /// The highlights in this document, and what is written on them.
    annotations,
    /// The document's own outline, and the places a reader has kept.
    bookmarks,

    /// What the rail's button for it is called, and what its tooltip says.
    pub fn label(p: Panel) []const u8 {
        return switch (p) {
            .none => "",
            .annotations => "Annotations",
            .bookmarks => "Bookmarks",
        };
    }

    /// The icon id, resolved through the registry like every other.
    pub fn icon(p: Panel) []const u8 {
        return switch (p) {
            .none => "fenrir.unknown",
            .annotations => "fenrir.highlight",
            .bookmarks => "fenrir.bookmark",
        };
    }
};

/// The panels the rail has a button for, in the order it draws them.
pub const toggles = [_]Panel{ .annotations, .bookmarks };

/// What the rail shows, as the reader knows it.
pub const Right = struct {
    /// Numbered from one, as a person numbers them.
    page: u32 = 1,
    pages: u32 = 1,
};

/// What the rail was asked for. A request and not an action, as
/// `chrome.ZoomWant` is: the rail has no view to act on.
pub const Want = union(enum) {
    /// Show this one, or `.none` to close whatever is open.
    panel: Panel,
    /// Go here, numbered from one.
    page: u32,
};

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
        r.panel = if (r.panel == p) .none else p;
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
        .h = .px(@max(ui.viewport.height() - reserved_below, 1)),
        .axis = .y,
        .child_align = .center,
        .fixed_x = ui.viewport.width() - width,
        .fixed_y = 0,
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
            .on = r.panel == p,
            .accent = t.accent,
        });
        w.tool.hint(ui, tips, sig, p.label());
        if (sig.clicked) want = .{ .panel = if (r.panel == p) .none else p };
        try w.spacer(ui, .px(2));
    }

    try w.fill(ui);
    if (try counter(ui, t, st, r)) |page| want = .{ .page = page };

    return want;
}

/// How much of the window the rail leaves alone at the bottom. The status bar
/// is drawn over the same pixels the rail would otherwise reach, and a rail
/// that ran behind it would put its counter under the mode line.
pub const reserved_below: f32 = @import("chrome.zig").status_height;

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
        const want = try rightRail(&rig.ui, Fonts.fallback_font, .dark, &rig.icons, st, r, &rig.tips);
        rig.ui.end();
        return want;
    }

    fn find(rig: *Rig, name: []const u8) ?*thviti.Box {
        return rig.ui.find(key.make(key.make(rig.ui.root.key, "right rail"), name));
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
