//! The panels that dock to the right rail, and the rows they are made of.
//!
//! ## One vocabulary, not one panel per thing
//!
//! A `Row` is a label, a page, a colour chip, a depth and an id, and every
//! panel in the reader is a list of them. The annotations panel is the first;
//! the outline is the second and needs the depth, and the plugin panels of
//! phase eight are declared in Lua as exactly this shape. A panel written per
//! feature would be a fourth widget set by the time there were four features,
//! and a plugin could not reach any of it without being handed a box tree.
//!
//! ## An overlay, not a third column
//!
//! It floats over the page, docked against the rail. A panel that reflowed
//! the windows would refit every fitted view on every toggle -- and there are
//! four fit modes now, so that is four kinds of jump for the sake of a list
//! somebody opened to glance at.
//!
//! The price is that a panel and a page share pixels, which the rails
//! deliberately do not. So the panel records `State.rect` as it is built and
//! the reader asks it, before handing a press to the page. Last frame's
//! rectangle again, and the right one: it is the rectangle that was under the
//! pointer when the button went down.
//!
//! ## What this file knows, and what it does not
//!
//! Rows and a title. Not what a highlight is, not what a buffer is, and
//! certainly not how to scroll one -- the panel reports the row that was
//! activated and the reader does the rest, which is the division `chrome.zig`
//! and `rails.zig` both draw.
//!
//! ## The rows are the caller's, and are not rebuilt per frame
//!
//! `rows` is a borrowed slice whose labels are the document's own bytes. The
//! reader holds the array and refills it when the thing behind it changes --
//! a highlight added, a document opened -- and not once a frame, because
//! that would be an allocation and a sort on the frame path for a list that
//! changes when somebody presses a key and at no other time.

const std = @import("std");
const fenrir = @import("fenrir");

const rails = @import("rails.zig");
const thviti = fenrir.thviti;

const Bounds = fenrir.gelgja.Bounds;
const Color = fenrir.gelgja.Color;
const Fonts = fenrir.tyr.Fonts;
const Icons = thviti.Icons;
const Theme = thviti.Theme;
const UI = thviti.UI;
const w = thviti.widgets;

pub const Error = UI.Error;

/// How wide a panel is. Wide enough for a sentence of somebody's note at
/// thirteen pixels, narrow enough to leave a column of a two-column paper
/// readable underneath it.
pub const width: f32 = 280;

/// The bar at the top of it, with the title and the way out.
const head_height: f32 = 26;
const row_height: f32 = 30;
const pad: f32 = 8;
/// The colour chip at the near edge of a row that has one.
const chip: f32 = 5;
/// How far a row is pushed in per level of depth, for a tree drawn flat.
const indent: f32 = 12;

/// One line of a panel.
///
/// Everything a panel row can say, in a shape Lua can build and Þviti can lay
/// out without a plugin ever touching a box. Deliberately small and flat:
/// a row that could hold another row would be a tree, and a tree is what
/// `depth` is for.
pub const Row = struct {
    /// What it says. Borrowed, and must outlive the frame it is drawn in.
    label: []const u8 = "",
    /// Where it points, numbered from one. Zero for a row that points at no
    /// page, which is drawn without the number rather than with a zero.
    page: u32 = 0,
    /// A chip at the near edge: a highlight's colour, a plugin's category.
    swatch: ?Color = null,
    /// How deep in a tree drawn as a flat list.
    depth: u8 = 0,
    /// Whatever the caller needs to find what this row is about again. A
    /// highlight's session key, for the annotations panel.
    id: u64 = 0,
};

/// What a panel remembers between frames.
pub const State = struct {
    /// The row last activated, by its id. Zero for none.
    chosen: u64 = 0,

    /// Last frame's rectangle, or empty when nothing was open.
    ///
    /// The reader asks this before it hands a press to the page: a panel is
    /// an overlay, so unlike a rail it does share pixels with the document
    /// underneath, and something has to say which of the two a click was for.
    rect: Bounds = .empty,

    /// True while a row should be brought into view -- set when the reader
    /// moves the selection with a key rather than a click, because the panel
    /// is the only thing that knows where its rows are.
    reveal: bool = false,

    pub fn holds(st: *const State, p: fenrir.gelgja.Point) bool {
        return st.rect.contains(p);
    }
};

/// The panel, and the row that was activated in it.
///
/// Built after the bar and the rails and before the popups, which is where it
/// belongs in the stack: over the page, under anything modal.
pub fn panel(
    ui: *UI,
    face: Fonts.FontId,
    t: Theme,
    icons: *const Icons,
    title: []const u8,
    empty: []const u8,
    rows: []const Row,
    st: *State,
    top: f32,
) Error!?Row {
    ui.pushStyle(.{ .font = face, .font_size = 13, .fg = t.text, .bg = t.panel });
    defer ui.popStyle();

    const height = @max(ui.viewport.height() - top - rails.reserved_below, 1);
    ui.next(.{
        .w = .px(width),
        .h = .px(height),
        .axis = .y,
        .fixed_x = ui.viewport.width() - rails.width - width,
        .fixed_y = top,
        .border_color = t.divider,
        .flags = .{
            .floating_x = true,
            .floating_y = true,
            // Clickable so that a press inside it is not a press on the page
            // behind it even before `State.rect` is consulted.
            .clickable = true,
            .draw_background = true,
            .draw_border = true,
            .clip = true,
        },
    });
    const box = try ui.open("panel");
    defer ui.close(box);
    st.rect = box.rect;

    var closing = false;
    {
        ui.next(.{ .w = .fill, .h = .px(head_height), .axis = .x, .child_align = .center });
        const head = try ui.open("head");
        defer ui.close(head);

        try w.spacer(ui, .px(pad));
        ui.next(.{ .fg = t.text_dim, .font_size = 12 });
        _ = try w.labelf(ui, "{s}###title", .{title});
        try w.fill(ui);
        closing = (try w.iconButton(ui, "close", icons.byName("fenrir.close", .toolbar_small), .{
            .size = 18,
        })).clicked;
        try w.spacer(ui, .px(pad * 0.5));
    }

    if (rows.len == 0) {
        ui.next(.{ .w = .fill, .h = .fill, .axis = .y, .child_align = .center });
        const none = try ui.open("empty");
        defer ui.close(none);
        try w.spacer(ui, .px(pad * 2));
        ui.next(.{ .fg = t.text_dim, .font_size = 12 });
        _ = try w.labelf(ui, "{s}###said", .{empty});
        return if (closing) closed else null;
    }

    var out: ?Row = null;
    ui.next(.{ .w = .fill, .h = .fill, .axis = .x });
    const body = try ui.open("body");
    {
        defer ui.close(body);

        ui.next(.{ .w = .fill, .h = .fill });
        const l = try w.list.open(ui, "rows", .{
            .count = @intCast(rows.len),
            .row_height = row_height,
        });
        {
            defer w.list.close(ui, l);
            var it = l.rows();
            while (it.next()) |n| {
                const r = rows[n];
                if (try line(ui, t, l, n, r, st.chosen != 0 and st.chosen == r.id)) out = r;
            }
        }

        // Where the keyboard's selection is, rather than where the scroll
        // was: `scrollTo` is safe for a row outside the built range, which is
        // the point -- the row a key has just chosen is usually not on screen.
        if (st.reveal) {
            st.reveal = false;
            for (rows, 0..) |r, i| {
                if (r.id == st.chosen) l.scrollTo(@intCast(i));
            }
        }

        ui.next(.{ .bg = t.ground });
        try w.list.scrollBar(ui, "bar", l);
    }

    if (closing) return closed;
    return out;
}

/// What `panel` returns when the way out was pressed: a row that is no row,
/// which the reader reads as "close me". A separate return would be a second
/// thing every call site has to handle for a cross nobody has clicked.
pub const closed: Row = .{ .id = std.math.maxInt(u64) };

pub fn wasClosed(r: Row) bool {
    return r.id == closed.id;
}

/// One row: a chip, what it says, and where it is.
///
/// Keyed `###row{d}` exactly as `list.row` keys its own, so that a panel
/// mixing the two would still have one row per index.
fn line(ui: *UI, t: Theme, l: w.List, index: u32, r: Row, selected: bool) Error!bool {
    ui.next(.{
        .w = .fill,
        .h = .px(l.row_height),
        .axis = .x,
        .child_align = .center,
        .bg = if (selected) t.selection else t.panel.withAlpha(0),
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .hot_animation = true,
            .clip = true,
        },
    });
    var name: [16]u8 = undefined;
    const b = try ui.open(std.fmt.bufPrint(&name, "###row{d}", .{index}) catch "###row");
    defer ui.close(b);
    const sig = ui.signal(b);

    // The chip is a box and not a border, because a border is a style and
    // this is the row's one piece of colour from the document itself.
    ui.next(.{
        .w = .px(chip),
        .h = .fill,
        .bg = r.swatch orelse t.panel.withAlpha(0),
        .flags = .{ .draw_background = true },
    });
    _ = try ui.box("###chip");

    try w.spacer(ui, .px(pad - chip + @as(f32, @floatFromInt(r.depth)) * indent));

    // The label goes in a box of its own that clips, because a box does not
    // clip the text it draws itself -- only what its children draw. Without
    // this a long heading runs out from under its own row and over the page
    // number beside it, which is what the first outline drawn here did. The
    // same rule the status bar's left group uses, and for the same reason:
    // let the sizes elide, rather than measuring a string every frame.
    {
        ui.next(.{
            .w = .fill,
            .h = .fill,
            .axis = .x,
            .child_align = .center,
            .flags = .{ .clip = true, .overflow_x = true },
        });
        const room = try ui.open("###room");
        defer ui.close(room);

        ui.next(.{
            .w = .text(0),
            .h = .text(0),
            .fg = if (r.label.len == 0) t.text_dim else t.text,
            .flags = .{ .draw_text = true },
        });
        // `boxText` and not `box`: the label is a document's, and a note with
        // `###` typed into it would otherwise split and key on its own tail.
        _ = try ui.boxText("label", if (r.label.len == 0) "no note" else r.label);
    }

    if (r.page != 0) {
        try w.spacer(ui, .px(pad));
        ui.next(.{ .fg = t.text_dim, .font_size = 11 });
        _ = try w.labelf(ui, "{d}###page", .{r.page});
    }
    try w.spacer(ui, .px(pad));

    return sig.clicked;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const key = thviti.key;
const Input = thviti.Input;
const Point = fenrir.gelgja.Point;

const Rig = struct {
    fonts: Fonts,
    icons: Icons,
    ui: UI,

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

    fn frame(rig: *Rig, rows: []const Row, st: *State, in: Input) !?Row {
        try rig.ui.begin(.fromRect(0, 0, 900, 600), in);
        const out = try panel(
            &rig.ui,
            Fonts.fallback_font,
            .dark,
            &rig.icons,
            "Annotations",
            "no highlights yet",
            rows,
            st,
            0,
        );
        rig.ui.end();
        return out;
    }

    fn find(rig: *Rig, path: []const []const u8) ?*thviti.Box {
        var k = key.make(rig.ui.root.key, "panel");
        for (path) |name| k = key.make(k, name);
        return rig.ui.find(k);
    }

    fn click(rig: *Rig, rows: []const Row, st: *State, at: Point) !?Row {
        _ = try rig.frame(rows, st, .{ .mouse = at });
        _ = try rig.frame(rows, st, .{ .mouse = at, .buttons = .{ .left = true } });
        return rig.frame(rows, st, .{ .mouse = at });
    }
};

fn middleOf(b: *thviti.Box) Point {
    return .{
        .x = (b.rect.min_x + b.rect.max_x) * 0.5,
        .y = (b.rect.min_y + b.rect.max_y) * 0.5,
    };
}

const three = [_]Row{
    .{ .label = "worth checking", .page = 2, .id = 11, .swatch = .{ .r = 1, .g = 0.9, .b = 0.2 } },
    .{ .label = "", .page = 5, .id = 12 },
    .{ .label = "the whole argument", .page = 9, .id = 13 },
};

test "the panel docks against the rail and stops above the status bar" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var st: State = .{};
    _ = try rig.frame(&three, &st, .{});

    const box = rig.ui.root.first.?;
    try testing.expectEqual(900 - rails.width, box.rect.max_x);
    try testing.expectEqual(900 - rails.width - width, box.rect.min_x);
    try testing.expectEqual(600 - rails.reserved_below, box.rect.max_y);

    // A second frame before it can say where it is, and that is the contract
    // rather than a wrinkle in the test: `rect` is read as the box is built,
    // which is before this frame is solved and after the last one was. What
    // a press needs is exactly that -- where the panel was when the button
    // went down.
    _ = try rig.frame(&three, &st, .{});
    try testing.expect(st.holds(middleOf(box)));
    try testing.expect(!st.holds(.{ .x = 40, .y = 40 }));
}

test "a row says what is written on it, or that nothing is" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var st: State = .{};
    _ = try rig.frame(&three, &st, .{});

    const rows = rig.find(&.{ "body", "rows" }).?;
    try testing.expectEqualStrings(
        "worth checking",
        rig.ui.find(key.make(key.make(key.make(rows.key, "row0"), "room"), "label")).?.text,
    );
    try testing.expectEqualStrings(
        "no note",
        rig.ui.find(key.make(key.make(key.make(rows.key, "row1"), "room"), "label")).?.text,
    );
    try testing.expectEqualStrings(
        "9",
        rig.ui.find(key.make(key.make(rows.key, "row2"), "page")).?.text,
    );
}

test "clicking a row hands it back whole" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var st: State = .{};
    _ = try rig.frame(&three, &st, .{});

    const rows = rig.find(&.{ "body", "rows" }).?;
    const row = rig.ui.find(key.make(rows.key, "row2")).?;
    const out = (try rig.click(&three, &st, middleOf(row))).?;
    try testing.expectEqual(@as(u64, 13), out.id);
    try testing.expectEqual(@as(u32, 9), out.page);
    try testing.expect(!wasClosed(out));
}

test "the way out is a row that is no row" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var st: State = .{};
    _ = try rig.frame(&three, &st, .{});

    const cross = rig.find(&.{ "head", "close" }).?;
    const out = (try rig.click(&three, &st, middleOf(cross))).?;
    try testing.expect(wasClosed(out));
}

test "an empty panel says so rather than showing an empty list" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var st: State = .{};
    _ = try rig.frame(&.{}, &st, .{});

    try testing.expectEqualStrings("no highlights yet", rig.find(&.{ "empty", "said" }).?.text);
    try testing.expect(rig.find(&.{ "body", "rows" }) == null);
}

test "only the rows the panel can see are built" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    // Six hundred highlights, which is a well-read paper and not a stress
    // test. The panel is about twenty rows tall.
    var many: [600]Row = undefined;
    for (&many, 0..) |*r, i| r.* = .{ .label = "note", .page = @intCast(i + 1), .id = i + 1 };

    var st: State = .{};
    _ = try rig.frame(&many, &st, .{});
    _ = try rig.frame(&many, &st, .{});

    const rows = rig.find(&.{ "body", "rows" }).?;
    var built: u32 = 0;
    var it = rows.children();
    while (it.next()) |_| built += 1;
    // The two spacers standing in for what is above and below, and a couple
    // of rows of overscan either side of what fits.
    try testing.expect(built < 30);
}
