//! The settings page: what the reader remembers about itself, on screen.
//!
//! Until now the only way to change any of this was `fenrir config` in
//! another terminal, or `:set` for the one setting that has a command. Both
//! stay -- a person who lives in a terminal should not have to open a panel
//! to change a colour -- but neither of them *lists* what there is to change,
//! and a setting nobody can find is a setting nobody uses.
//!
//! ## What this file knows, and what it does not
//!
//! It knows the table of settings, what each one is for, and how to draw a
//! row for one. It does not know what a library is, cannot open one, and
//! never writes anything: `State.put` is how the reader hands it the values
//! it found, and `Change` is how it hands a new one back. That is the same
//! division `chrome.zig` draws for the status bar and `Host.zig` draws for
//! Galdr, and it is what lets the whole panel be built and clicked in a test
//! with no database, no window and no device.
//!
//! ## Why the values are stored here and read on a change
//!
//! `Library.settings` asks SQLite and allocates. Doing that per frame would
//! make this the one thing in the reader that allocates on a frame path, for
//! a panel whose contents change when somebody types in it and at no other
//! time. So the values live in a fixed store on the `State`, the reader
//! fills it when the panel opens and after every change, and the frame path
//! reads bytes.
//!
//! ## Rows are a choice or a field, and never both
//!
//! A setting with a short, known set of values -- the theme -- cycles on a
//! click. Everything else is text somebody types. A combo box that does both
//! is a third widget with a third set of keyboard rules, and neither of
//! these two settings is worth one.

const std = @import("std");
const fenrir = @import("fenrir");

const thviti = fenrir.thviti;

const Color = fenrir.gelgja.Color;
const Point = fenrir.gelgja.Point;
const Theme = thviti.Theme;
const UI = thviti.UI;
const w = thviti.widgets;

/// One setting, as the page presents it.
pub const Option = struct {
    key: []const u8,
    /// What it is for, in the middle column. The same sentence
    /// `fenrir config` prints, so the two descriptions cannot drift.
    about: []const u8,
    /// The values it may take. A row with choices cycles through them on a
    /// click; a row without becomes a text field.
    choices: []const []const u8 = &.{},
    /// What happens when nothing is set, in words rather than as a value:
    /// this is drawn dim in the value box and is never written anywhere.
    unset: []const u8 = "not set",
};

/// The settings the reader keeps, in the order the page lists them.
///
/// Not every key in the database -- a plugin's store lives in the same table
/// and most of it is that plugin's business and not a person's. This is the
/// list `fenrir config` documents, in one place so the two agree; a plugin
/// adds to it by declaring a setting, and those are drawn after these with a
/// heading, because they are the same kind of thing kept in the same place
/// and the only difference worth drawing is who put them there.
pub const builtin = [_]Option{
    .{
        .key = "theme",
        .about = "the colours the interface is drawn in",
        .choices = &.{ "dark", "light" },
        .unset = "dark",
    },
    .{
        .key = "accent",
        .about = "the colour it draws its own marks in",
        .unset = "the theme's",
    },
    .{
        .key = "author",
        .about = "the name annotations are signed with",
        .unset = "nobody",
    },
    .{
        .key = "zoom",
        .about = "the zoom a document opens at, or fit",
        .unset = "fit",
    },
};

/// The longest value worth showing. A colour is seven bytes and a name is a
/// name; anything longer than this belongs in a file, not in a panel.
pub const value_max = 64;

/// How many rows the page will draw. The reader's four and room for a
/// configuration full of plugins; past this the page stops listing rather
/// than growing, because a settings page longer than a screen is a list and
/// not a page.
pub const max_options = 28;

/// What the page was asked to change. The reader writes it down and applies
/// it; nothing here does either.
pub const Change = struct {
    key: []const u8,
    value: []const u8,
    /// Which row it was. The key alone is not enough to write it back: a
    /// plugin's value lives under a name of its own, and the row is the one
    /// thing that says which kind this is.
    index: usize = 0,
};

pub const State = struct {
    open: bool = false,

    /// Which row is being typed in, or null. One at a time, because there is
    /// one field: a panel with four live fields is four carets to keep track
    /// of and no reason to.
    editing: ?usize = null,
    /// The field's model. `bytes` is an interior pointer into `edit_buf` and
    /// is re-aimed at it every frame by `page`, so this struct survives being
    /// copied -- which it has to, since a `Session` is returned by value in
    /// the tests.
    field: w.Field = .{ .bytes = &.{} },
    edit_buf: [value_max]u8 = undefined,
    /// The field has just appeared and wants the keyboard. Focus follows a
    /// press, and the press that started the edit landed on the cell the
    /// field replaced -- so this is the one control in the interface that
    /// asks for focus rather than being given it.
    focus_next: bool = false,

    /// The settings plugins declared, after the reader's own. Borrowed from
    /// Galdr, which owns the bytes and outlives any frame drawn from them.
    extra: []const Option = &.{},

    /// The current values, as the reader last read them. Empty means unset.
    values: [max_options][value_max]u8 = @splat(@splat(0)),
    lens: [max_options]u8 = @splat(0),

    /// How many rows there are: the reader's, then the plugins'.
    pub fn count(st: *const State) usize {
        return @min(builtin.len + st.extra.len, max_options);
    }

    pub fn optionAt(st: *const State, index: usize) Option {
        if (index < builtin.len) return builtin[index];
        return st.extra[index - builtin.len];
    }

    /// Whether the row at `index` is a plugin's. The reader asks, because a
    /// plugin's value is written under a different name.
    pub fn isPlugin(st: *const State, index: usize) bool {
        _ = st;
        return index >= builtin.len;
    }

    pub fn show(st: *State) void {
        st.open = true;
        st.editing = null;
    }

    pub fn hide(st: *State) void {
        st.open = false;
        st.editing = null;
    }

    pub fn toggle(st: *State) void {
        if (st.open) st.hide() else st.show();
    }

    /// What the reader found for `options[index]`, or null for nothing.
    pub fn put(st: *State, index: usize, text: ?[]const u8) void {
        const value = text orelse "";
        const n = @min(value.len, value_max);
        @memcpy(st.values[index][0..n], value[0..n]);
        st.lens[index] = @intCast(n);
    }

    pub fn valueOf(st: *const State, index: usize) []const u8 {
        return st.values[index][0..st.lens[index]];
    }

    /// The value after the one showing, wrapping. A row with no choices has
    /// none, and a value nobody recognises starts again at the first -- which
    /// is what a database edited by hand deserves.
    fn nextChoice(st: *const State, index: usize) []const u8 {
        const choices = st.optionAt(index).choices;
        if (choices.len == 0) return "";
        const now = st.valueOf(index);
        for (choices, 0..) |c, i| {
            if (std.mem.eql(u8, c, now)) return choices[(i + 1) % choices.len];
        }
        return choices[0];
    }
};

/// How wide the page is, and how its three columns divide it.
const page_width: f32 = 520;
const key_width: f32 = 84;
const value_width: f32 = 140;
const row_height: f32 = 28;
const pad: f32 = 12;

/// The page, and what it was asked to change.
///
/// Built after everything else, because it is a popup and a popup is on top
/// by being built last.
pub fn page(ui: *UI, face: u16, t: Theme, st: *State) !?Change {
    if (!st.open) return null;

    // Re-aimed every frame rather than on creation: see `State.field`.
    st.field.bytes = &st.edit_buf;

    for (ui.in.events) |e| switch (e) {
        .key_down => |k| switch (k.code) {
            // Escape closes the page, unless a field has it first -- then it
            // is that edit being abandoned, which `textField` reports.
            .escape => if (st.editing == null) {
                st.hide();
                return null;
            },
            else => {},
        },
        else => {},
    };

    // Before the build, so the field sees it in the same frame it is first
    // drawn in: `signal` reads `ui.focus`, and a focus set afterwards would
    // cost a frame of typing.
    if (st.focus_next) {
        st.focus_next = false;
        if (st.editing) |i| ui.setFocus(fieldKey(ui, i));
    }

    ui.pushStyle(.{ .font = face, .font_size = 13, .fg = t.text });
    defer ui.popStyle();

    const plugin_rows = st.count() - builtin.len;
    const heading: f32 = if (plugin_rows == 0) 0 else row_height;
    const height = pad * 3 + 24 + @as(f32, @floatFromInt(st.count())) * row_height + heading + 22;
    const p = try w.popup.open(ui, "settings", .{
        .at = .{
            .x = @round((ui.viewport.width() - page_width) * 0.5),
            .y = @round((ui.viewport.height() - height) * 0.4),
        },
        .w = .px(page_width),
        .h = .px(height),
    });
    defer w.popup.close(ui, p);
    if (p.dismissed) {
        st.hide();
        return null;
    }

    try w.spacer(ui, .px(pad));
    {
        ui.next(.{ .w = .fill, .h = .px(18), .axis = .x, .child_align = .center });
        const head = try ui.open("###head");
        defer ui.close(head);

        try w.spacer(ui, .px(pad));
        _ = try w.label(ui, "Settings");
        try w.fill(ui);
        // Where they go, because a panel that writes somewhere should say
        // where: a setting changed here is the same setting `fenrir config`
        // prints in a terminal.
        ui.next(.{ .fg = t.text_dim });
        _ = try w.label(ui, "kept in the library");
        try w.spacer(ui, .px(pad));
    }
    try w.spacer(ui, .px(pad));

    var change: ?Change = null;
    var i: usize = 0;
    while (i < st.count()) : (i += 1) {
        // The one line that says whose settings the rest of the page is.
        // Not a second panel and not a tab: they are kept in the same place
        // and changed the same way, so they are one list with a rule in it.
        if (i == builtin.len) {
            ui.next(.{ .w = .fill, .h = .px(row_height), .axis = .x, .child_align = .center });
            const head = try ui.open("###plugins");
            defer ui.close(head);
            try w.spacer(ui, .px(pad));
            ui.next(.{ .fg = t.text_dim, .font_size = 11 });
            _ = try w.label(ui, "from plugins");
            try w.fill(ui);
        }
        if (try optionRow(ui, t, st, i, st.optionAt(i))) |c| change = c;
    }

    try w.spacer(ui, .px(pad));
    {
        ui.next(.{ .w = .fill, .h = .px(14), .axis = .x, .child_align = .center });
        const foot = try ui.open("###foot");
        defer ui.close(foot);
        try w.spacer(ui, .px(pad));
        ui.next(.{ .fg = t.text_dim, .font_size = 11 });
        _ = try w.label(ui, "enter to keep an edit, escape to drop it");
        try w.spacer(ui, .px(pad));
    }

    return change;
}

/// Where a row's value box will be, worked out rather than remembered. Keys
/// are a hash of the call-site string seeded with the parent's, so a box's
/// key is known before the box is: popup, row, value.
fn fieldKey(ui: *const UI, index: usize) thviti.key.Key {
    var name: [24]u8 = undefined;
    const row = thviti.key.make(
        thviti.key.make(ui.root.key, "settings"),
        std.fmt.bufPrint(&name, "row{d}", .{index}) catch "row",
    );
    return thviti.key.make(row, "value");
}

fn optionRow(ui: *UI, t: Theme, st: *State, index: usize, opt: Option) !?Change {
    ui.next(.{ .w = .fill, .h = .px(row_height), .axis = .x, .child_align = .center });
    var name: [24]u8 = undefined;
    const row = try ui.open(std.fmt.bufPrint(&name, "###row{d}", .{index}) catch "###row");
    defer ui.close(row);

    try w.spacer(ui, .px(pad));
    ui.next(.{ .w = .px(key_width), .h = .text(0), .flags = .{ .draw_text = true } });
    _ = try ui.boxText("key", opt.key);

    ui.next(.{
        .w = .fill,
        .h = .text(0),
        .fg = t.text_dim,
        .flags = .{ .draw_text = true, .clip = true },
    });
    _ = try ui.boxText("about", opt.about);

    try w.spacer(ui, .px(pad));
    const out = try valueCell(ui, t, st, index, opt);
    try w.spacer(ui, .px(pad));
    return out;
}

/// The right-hand column: a button that cycles, or a field that is typed in.
fn valueCell(ui: *UI, t: Theme, st: *State, index: usize, opt: Option) !?Change {
    const value = st.valueOf(index);

    if (st.editing != null and st.editing.? == index) {
        const r = try w.field.textField(ui, "value", &st.field, .{
            .w = .px(value_width),
            .h = .px(22),
            .placeholder = opt.unset,
        });

        if (r.cancelled) {
            st.editing = null;
            return null;
        }
        if (r.submitted) {
            st.editing = null;
            // The bytes belong to the state and outlive this frame, which is
            // what lets a `Change` be a slice rather than a copy.
            return .{ .key = opt.key, .value = st.field.slice(), .index = index };
        }
        return null;
    }

    ui.next(.{
        .w = .px(value_width),
        .h = .px(22),
        .axis = .x,
        .child_align = .center,
        .bg = t.panel_hi,
        .fg = if (value.len == 0) t.text_dim else t.text,
        .radius = .all(4),
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .draw_border = true,
            .hot_animation = true,
            .active_animation = true,
            .clip = true,
        },
    });
    const cell = try ui.open("value");
    const sig = ui.signal(cell);
    {
        defer ui.close(cell);
        try w.spacer(ui, .px(6));
        ui.next(.{ .w = .fill, .h = .text(0), .flags = .{ .draw_text = true } });
        _ = try ui.boxText("shown", if (value.len == 0) opt.unset else value);
    }

    if (!sig.clicked) return null;

    if (opt.choices.len != 0) return .{ .key = opt.key, .value = st.nextChoice(index), .index = index };

    // Into the field, with what is there already selected: the first thing
    // typed replaces it, which is what every settings row anywhere does.
    st.editing = index;
    st.focus_next = true;
    st.field.bytes = &st.edit_buf;
    st.field.set(value);
    st.field.selectAll();
    return null;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const key = thviti.key;
const Input = thviti.Input;

fn frame(ui: *UI, st: *State, in: Input) !?Change {
    try ui.begin(.fromRect(0, 0, 900, 700), in);
    const out = try page(ui, 0, .dark, st);
    ui.end();
    return out;
}

fn cellOf(ui: *UI, index: usize) *thviti.Box {
    var name: [24]u8 = undefined;
    const row = key.make(
        key.make(ui.root.key, "settings"),
        std.fmt.bufPrint(&name, "row{d}", .{index}) catch unreachable,
    );
    return ui.find(key.make(row, "value")).?;
}

fn middleOf(b: *thviti.Box) Point {
    return .{
        .x = (b.rect.min_x + b.rect.max_x) * 0.5,
        .y = (b.rect.min_y + b.rect.max_y) * 0.5,
    };
}

/// Onto a box, press, release: a press only reaches a box the pointer was
/// already over, here as with a real mouse.
fn clickAt(ui: *UI, st: *State, at: Point) !?Change {
    _ = try frame(ui, st, .{ .mouse = at });
    _ = try frame(ui, st, .{ .mouse = at, .buttons = .{ .left = true } });
    return frame(ui, st, .{ .mouse = at });
}

test "a closed page builds nothing and asks for nothing" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var st: State = .{};

    try testing.expect(try frame(&ui, &st, .{}) == null);
    try testing.expect(ui.find(key.make(ui.root.key, "settings")) == null);
}

test "every setting the page lists has a row, in order" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var st: State = .{};
    st.show();

    _ = try frame(&ui, &st, .{});
    for (builtin, 0..) |opt, i| {
        var name: [24]u8 = undefined;
        const row = key.make(
            key.make(ui.root.key, "settings"),
            std.fmt.bufPrint(&name, "row{d}", .{i}) catch unreachable,
        );
        try testing.expectEqualStrings(opt.key, ui.find(key.make(row, "key")).?.text);
        try testing.expectEqualStrings(opt.about, ui.find(key.make(row, "about")).?.text);
    }
}

test "a value nobody has set shows what happens instead, dimmed" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var st: State = .{};
    st.show();

    _ = try frame(&ui, &st, .{});
    const shown = ui.find(key.make(cellOf(&ui, 2).key, "shown")).?;
    try testing.expectEqualStrings("nobody", shown.text);

    st.put(2, "Nahid Hasan");
    _ = try frame(&ui, &st, .{});
    try testing.expectEqualStrings("Nahid Hasan", shown.text);
}

test "a setting with choices cycles through them and wraps" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var st: State = .{};
    st.show();
    st.put(0, "dark");

    _ = try frame(&ui, &st, .{});
    const at = middleOf(cellOf(&ui, 0));

    const first = (try clickAt(&ui, &st, at)).?;
    try testing.expectEqualStrings("theme", first.key);
    try testing.expectEqualStrings("light", first.value);

    // The reader is what writes it down, so the page only knows what it was
    // told: told "light", the next click comes back round to "dark".
    st.put(0, "light");
    const second = (try clickAt(&ui, &st, at)).?;
    try testing.expectEqualStrings("dark", second.value);
}

test "a setting with no choices is typed in, and enter is what keeps it" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var st: State = .{};
    st.show();
    st.put(2, "old");

    _ = try frame(&ui, &st, .{});
    const at = middleOf(cellOf(&ui, 2));
    try testing.expect(try clickAt(&ui, &st, at) == null);
    try testing.expectEqual(@as(?usize, 2), st.editing);
    // What was there is selected, so the first character replaces it.
    try testing.expectEqualStrings("old", st.field.slice());
    try testing.expect(st.field.hasSelection());

    // A frame to build the field and let it take focus, then type.
    _ = try frame(&ui, &st, .{ .mouse = at });
    _ = try frame(&ui, &st, .{ .mouse = at, .events = &.{.{ .text = "new" }} });
    try testing.expectEqualStrings("new", st.field.slice());

    const out = (try frame(&ui, &st, .{
        .mouse = at,
        .events = &.{.{ .key_down = .{ .code = .enter } }},
    })).?;
    try testing.expectEqualStrings("author", out.key);
    try testing.expectEqualStrings("new", out.value);
    try testing.expect(st.editing == null);
}

test "escape drops an edit, and then closes the page" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var st: State = .{};
    st.show();
    st.put(2, "kept");

    _ = try frame(&ui, &st, .{});
    const at = middleOf(cellOf(&ui, 2));
    _ = try clickAt(&ui, &st, at);
    _ = try frame(&ui, &st, .{ .mouse = at });
    _ = try frame(&ui, &st, .{ .mouse = at, .events = &.{.{ .text = "typed" }} });

    const escape: Input = .{
        .mouse = at,
        .events = &.{.{ .key_down = .{ .code = .escape } }},
    };
    _ = try frame(&ui, &st, escape);
    // The edit went and the page stayed: one escape is one thing.
    try testing.expect(st.editing == null);
    try testing.expect(st.open);
    try testing.expectEqualStrings("kept", st.valueOf(2));

    _ = try frame(&ui, &st, escape);
    try testing.expect(!st.open);
}

test "a page state survives being copied, field and all" {
    // A `Session` is returned by value in the reader's own tests, so a state
    // holding a pointer into itself has to be able to take that.
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    var first: State = .{};
    first.show();
    first.put(2, "before");
    _ = try frame(&ui, &first, .{});

    var second = first;
    second.editing = 2;
    second.field.bytes = &.{};
    _ = try frame(&ui, &second, .{});

    second.field.set("after");
    try testing.expectEqualStrings("after", second.field.slice());
    try testing.expect(second.field.bytes.ptr == &second.edit_buf);
}

test "a plugin's settings come after the reader's own, under a heading" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    const extra = [_]Option{
        .{ .key = "reading.list", .about = "where the list is kept", .unset = "nowhere" },
        .{ .key = "reading.sort", .about = "how it is ordered", .choices = &.{ "added", "title" } },
    };
    var st: State = .{ .extra = &extra };
    st.show();
    try testing.expectEqual(builtin.len + 2, st.count());

    _ = try frame(&ui, &st, .{});
    const first = builtin.len;
    try testing.expect(ui.find(key.make(key.make(ui.root.key, "settings"), "plugins")) != null);

    var name: [24]u8 = undefined;
    const row = key.make(
        key.make(ui.root.key, "settings"),
        std.fmt.bufPrint(&name, "row{d}", .{first}) catch unreachable,
    );
    try testing.expectEqualStrings("reading.list", ui.find(key.make(row, "key")).?.text);
    try testing.expectEqualStrings("nowhere", ui.find(key.make(key.make(row, "value"), "shown")).?.text);

    // Clicking a plugin's row works the way the reader's own does: a list
    // cycles, a bare one becomes a field -- and the change names the row, so
    // the reader knows which store to write it to.
    const cycled = (try clickAt(&ui, &st, middleOf(cellOf(&ui, first + 1)))).?;
    try testing.expectEqualStrings("reading.sort", cycled.key);
    try testing.expectEqualStrings("added", cycled.value);
    try testing.expectEqual(first + 1, cycled.index);
    try testing.expect(st.isPlugin(cycled.index));
    try testing.expect(!st.isPlugin(0));

    _ = try clickAt(&ui, &st, middleOf(cellOf(&ui, first)));
    try testing.expectEqual(@as(?usize, first), st.editing);
}
