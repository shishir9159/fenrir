//! What the interface lays over the reader and hands back: the rails, the
//! panel docked to them, the command palette and the settings page -- the
//! rows each one shows, filled when what is behind them changes rather than
//! once a frame, and what a click in one of them asks for.
//!
//! The widgets are files of their own (`rails.zig`, `panels.zig`,
//! `palette.zig`, `settings.zig`); this is the session's side of them, kept
//! together so that a build with no interface beyond the status bar can
//! leave the file out.

const std = @import("std");
const fenrir = @import("fenrir");

const chrome_mod = @import("../chrome.zig");
const library = @import("../library.zig");
const Library = library.Library;
const palette_mod = @import("../palette.zig");
const panels = @import("../panels.zig");
const rails_mod = @import("../rails.zig");
const settings_page = @import("../settings.zig");
const Session = @import("../read.zig").Session;
const compare = @import("compare.zig");
const marks = @import("marks.zig");

const galdr = fenrir.galdr;
const hlidskjalf = fenrir.hlidskjalf;
const thviti = fenrir.thviti;

const Buffer = hlidskjalf.Buffer;
const Marks = hlidskjalf.Marks;
const commands = hlidskjalf.commands;
const keys = hlidskjalf.keys;
const Theme = thviti.Theme;

// -- the settings page -------------------------------------------------------

/// Fills the settings page with what the library holds now.
///
/// Called when the page opens and after every change, and nowhere near a
/// frame: `Library.get` asks SQLite and allocates, and this reader does
/// not allocate on a frame path. With no library every row is unset,
/// which is the truth -- there is nowhere for a setting to have been
/// written.
pub fn readSettings(s: *Session) void {
    fillPluginSettings(s);
    var i: usize = 0;
    while (i < s.settings.count()) : (i += 1) {
        const lib = s.library orelse {
            s.settings.put(i, null);
            continue;
        };
        var buf: [256]u8 = undefined;
        const key = settingKey(s, &buf, i) orelse {
            s.settings.put(i, null);
            continue;
        };
        const got = lib.get(key) catch null;
        defer if (got) |g| s.gpa.free(g);
        s.settings.put(i, got);
    }
}

/// Where a row's value lives in the library.
///
/// A plugin's is under `galdr.<plugin>/`, which is where
/// `fenrir.store` already puts it -- so a setting declared and a
/// setting stored are the same bytes, and a plugin goes on reading its
/// own value with `fenrir.store.get` whether or not a person has ever
/// opened this page. A plugin row's `key` is already `<plugin>/<key>`,
/// so that two plugins which both declared `enabled` are two rows.
pub fn settingKey(s: *Session, buf: []u8, index: usize) ?[]const u8 {
    const opt = s.settings.optionAt(index);
    if (!s.settings.isPlugin(index)) return opt.key;
    return library.pluginKey(buf, "", opt.key);
}

/// Whether what plugins declared has moved since the page was filled.
///
/// Asked every frame the page is open, because a callback can declare,
/// replace or clear a setting at any point and the page is holding
/// Galdr's bytes until it is refilled.
pub fn pluginSettingsStale(s: *const Session) bool {
    const rt = s.plugins orelse return false;
    return s.settings_for != rt.revision;
}

/// The plugins' settings, borrowed from Galdr, rebuilt on a change.
///
/// The `Option` the page draws and the `Setting` a plugin declared are
/// the same fields under two names, and this is the one place they are
/// copied across: the page does not import Galdr and Galdr does not know
/// there is a page.
fn fillPluginSettings(s: *Session) void {
    const rt = s.plugins orelse return;
    if (s.settings_for == rt.revision) return;
    s.settings_for = rt.revision;
    s.plugin_settings.clearRetainingCapacity();
    for (rt.settingList()) |row| {
        if (!row.live) continue;
        s.plugin_settings.append(s.gpa, .{
            .key = row.scoped,
            .about = row.about,
            .choices = row.choices.items,
            .unset = if (row.unset.len != 0) row.unset else "not set",
        }) catch break;
    }
    s.settings.extra = s.plugin_settings.items;
}

/// One row of the settings page, written down and acted on.
///
/// Through the same doors as everything else: a theme goes through
/// `useTheme`, so the page and `:set theme=` cannot diverge, and a colour
/// is parsed before it is stored, so a row nobody could read is refused
/// where it was typed rather than on the next start.
pub fn changeSetting(s: *Session, c: settings_page.Change) void {
    if (std.mem.eql(u8, c.key, "theme")) {
        const t = Theme.byName(c.value) orelse {
            s.say("no theme called {s}", .{c.value[0..@min(c.value.len, 48)]});
            return;
        };
        s.useTheme(t);
    } else if (std.mem.eql(u8, c.key, "comment_anchor")) {
        s.comment_style = if (c.value.len == 0) .highlight else marks.commentStyleNamed(c.value) orelse {
            s.say("comment_anchor is highlight or arrow, not {s}", .{c.value[0..@min(c.value.len, 48)]});
            return;
        };
    } else if (std.mem.eql(u8, c.key, "watch")) {
        if (c.value.len != 0 and !std.mem.eql(u8, c.value, "on") and !std.mem.eql(u8, c.value, "off")) {
            s.say("watch is on or off, not {s}", .{c.value[0..@min(c.value.len, 48)]});
            return;
        }
        s.setWatching(std.mem.eql(u8, c.value, "on"));
    } else if (std.mem.eql(u8, c.key, "accent")) {
        if (c.value.len != 0) {
            const colour = Library.parseColor(c.value) orelse {
                s.say("{s} is not a colour: try a name or #rrggbb", .{
                    c.value[0..@min(c.value.len, 48)],
                });
                return;
            };
            s.chosen_accent = colour;
            s.highlight = colour;
        } else {
            s.chosen_accent = null;
        }
        s.useTheme(s.theme);
    }

    const lib = s.library orelse {
        s.say("nowhere to keep {s}: this reader has no library", .{c.key});
        return;
    };
    var buf: [256]u8 = undefined;
    const where = settingKey(s, &buf, c.index) orelse return;
    if (c.value.len == 0) lib.remove(where) catch {} else lib.set(where, c.value) catch {};
    readSettings(s);
    s.say("{s} = {s}", .{ c.key, if (c.value.len == 0) "unset" else c.value });
}

// -- the palette -------------------------------------------------------------

/// Opens it, having refilled the rows.
///
/// The built-in half comes from the registry and the plugins' half from
/// the runtime, and once they are in one array nothing downstream can
/// tell which is which -- which is the point, since a person looking for
/// a command does not know either.
pub fn showPalette(s: *Session) void {
    s.palette_rows.clearRetainingCapacity();
    _ = s.palette_text.reset(.retain_capacity);
    s.palette_rows.ensureTotalCapacity(s.gpa, commands.table.len) catch return;
    s.palette_rows.items.len = commands.table.len;
    _ = palette_mod.builtins(s.palette_rows.items);

    if (s.plugins) |rt| {
        // A key a plugin has bound is no longer the way to the command
        // that used to own it, and a palette that goes on saying so is
        // the palette lying about the reader. Only normal mode is
        // checked, which is the mode every binding in the table is
        // written for.
        const look = rt.lookup();
        for (s.palette_rows.items) |*row| {
            if (row.binding.len == 0) continue;
            const k = galdr.keyspec.parse(row.binding) catch continue;
            if (look.find(look.ptr, .normal, k) != null) row.binding = "";
        }
        // Copied, not borrowed. The palette holds its rows from the
        // frame it opens until the frame it closes, and `rt.pump()`
        // resumes a yielded callback immediately before the chrome is
        // built -- so a plugin can redefine a command, or clear its
        // group, between the two, and a borrowed description would be
        // freed under an open menu. The copies cost once per opening,
        // which is not a frame path.
        const words = s.palette_text.allocator();
        for (rt.commandNames()) |c| {
            if (!c.live) continue;
            s.palette_rows.append(s.gpa, .{
                .name = words.dupe(u8, c.name) catch break,
                .about = words.dupe(u8, c.description) catch "",
                .binding = words.dupe(u8, bindingFor(rt, c.name)) catch "",
                // The plugin's, when it named one. A registry name it got
                // wrong draws as the hollow box, which is the answer
                // everywhere else an icon is asked for by name.
                .icon = if (c.icon.len != 0) words.dupe(u8, c.icon) catch "fenrir.menu" else "fenrir.menu",
            }) catch break;
        }
    }
    s.palette.show();
}

/// The keys that reach a plugin's command without the palette.
///
/// The design language asks for a command's binding to be drawn beside
/// it, and a plugin's binding is one it made itself: a `fenrir.keymap`
/// whose action is the command line. A binding that is a *function*
/// cannot be found this way and is not claimed to be -- two things that
/// happen to do the same is not a binding for one of them.
fn bindingFor(rt: *galdr.Runtime, name: []const u8) []const u8 {
    for (rt.keymapList()) |k| {
        if (!k.live or k.line.len < name.len) continue;
        if (!std.mem.eql(u8, k.line[0..name.len], name)) continue;
        if (k.line.len != name.len and k.line[name.len] != ' ') continue;
        return k.spec;
    }
    return "";
}

/// A row chosen, or a line typed into the palette that matched nothing.
///
/// A command that needs an argument cannot be *run* from a list -- there
/// is nothing to run it with -- so it goes onto the `:` line with a space
/// after it and the caret where the argument goes. That is the one thing
/// the palette hands to the older way in rather than doing itself, and it
/// is the honest handover: the two are the same commands.
pub fn runChosen(s: *Session, chosen: palette_mod.Chosen) void {
    switch (chosen) {
        .row => |r| {
            if (!r.needs_argument) {
                _ = s.exec(r.name);
                return;
            }
            s.cmdline.clearRetainingCapacity();
            s.cmdline.appendSlice(s.gpa, r.name) catch return;
            s.cmdline.append(s.gpa, ' ') catch return;
            s.keymap.mode = .command;
        },
        .line => |line| _ = s.exec(line),
    }
}

// -- the rails ---------------------------------------------------------------

/// What the right rail shows: where you are, and how far it goes.
pub fn railLine(s: *Session) rails_mod.Right {
    const v = s.view();
    fillRailButtons(s);
    return .{
        .page = v.currentPage() + 1,
        .pages = @intCast(v.pages.len),
        .panels = s.rail_panels.items,
        .changes = s.diff != null,
        .extra = s.rail_right.items,
    };
}

/// The plugins' rail buttons, split by side, rebuilt only when a plugin
/// has added or taken one away.
///
/// `Runtime.revision` changes then and at no other time, so a reader with
/// three plugin buttons on screen sorts them into two lists once and
/// draws from the lists for the rest of the session. The labels and icon
/// names are Galdr's own bytes, borrowed: nothing here copies a string.
pub fn fillRailButtons(s: *Session) void {
    const rt = s.plugins orelse return;
    if (s.rails_for == rt.revision) return;
    s.rails_for = rt.revision;
    s.rail_left.clearRetainingCapacity();
    s.rail_right.clearRetainingCapacity();
    s.rail_panels.clearRetainingCapacity();
    for (rt.panelList()) |p| {
        if (!p.live) continue;
        s.rail_panels.append(s.gpa, .{
            .id = p.id,
            .label = p.title,
            .icon = p.icon,
        }) catch break;
    }
    for (rt.railList()) |b| {
        if (!b.live) continue;
        const into = switch (b.side) {
            .left => &s.rail_left,
            .right => &s.rail_right,
        };
        into.append(s.gpa, .{ .id = b.id, .label = b.label, .icon = b.icon }) catch break;
    }
}

/// What the left rail shows: the mode, and the colours a digit picks.
///
/// The palette is filled into a fixed array on the session rather than
/// built fresh: eight colours parsed from their names every frame would
/// be the one place in the reader that does string work on a frame path,
/// for a rail that changes when a setting does.
pub fn modeRail(s: *Session) rails_mod.Left {
    if (s.swatches[0].name.len == 0 or !std.meta.eql(s.swatches[0].color, s.highlight)) {
        for (&s.swatches, 0..) |*sw, i| {
            sw.* = .{
                .name = marks.paletteName(@intCast(i)),
                .color = marks.paletteColor(s, @intCast(i)),
            };
        }
    }
    fillRailButtons(s);
    return .{ .mode = s.keymap.mode, .palette = &s.swatches, .extra = s.rail_left.items };
}

/// What a rail asked for, carried out.
pub fn applyRail(s: *Session, want: rails_mod.Want) void {
    const c = s.chrome orelse return;
    switch (want) {
        // Through `keys`, both of them: the rail names a mode and a
        // colour, and what those mean is the keymap's to say. A button
        // that built its own command would be a second keymap.
        .mode => |m| _ = s.apply(keys.enter(&s.keymap, m)),
        .colour => |i| {
            const cmd = keys.paletteCommand(s.keymap.mode, i) orelse return;
            if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;
            _ = s.apply(cmd);
            marks.applyEffects(s);
        },
        // Nothing is filled here: which panel is open is part of what
        // makes the rows stale, and the panel is built later this same
        // frame. One place fills them, and it is `panelRows`.
        .panel => |p| c.rails.show(p),
        .page => |page| _ = s.goToPage(page),
        // The plugin's to answer, exactly as a mode button's meaning is
        // the keymap's: a rail names a thing and something else knows
        // what the thing means.
        .plugin => |id| if (s.plugins) |rt| {
            rt.runRail(id);
            marks.applyEffects(s);
        },
    }
    s.dirty_title = true;
}

// -- the panel ---------------------------------------------------------------

/// The rows the open panel shows, rebuilt only when they have gone stale.
///
/// Stale is a different panel, a different buffer, or a change to that
/// buffer's marks -- `Marks.revision` is bumped by every one of them. A
/// reader sitting still with the annotations open rebuilds nothing, which
/// is the rule about doing no work per frame that can be done on change.
pub fn panelRows(s: *Session, which: rails_mod.Panel) []const panels.Row {
    const v = s.view();
    const b = s.buffer(v.buffer);
    const stamp: @TypeOf(s.rows_for) = .{
        .which = which,
        .buffer = v.buffer,
        .revision = b.marks.revision,
        // A plugin's list changes when the plugin says it does, and
        // `fenrir.refresh` is how it says so. Without this a declared
        // panel would be asked once and then never again.
        .contributions = if (s.plugins) |rt| rt.revision else 0,
        // A comparison made again hands over new results, and the rows
        // of the old ones borrow strings from them.
        .compared = if (s.diff) |c| @intFromPtr(c.results.ptr) else 0,
        .filtered = s.panel.filtered,
    };
    if (std.meta.eql(s.rows_for, stamp)) return s.rows.items;
    s.rows_for = stamp;
    s.rows.clearRetainingCapacity();

    switch (which) {
        .none => {},
        .bookmarks => {
            // Already in reading order and already flat: `outline.zig`
            // returns the tree walked, with a depth per entry, because
            // that is the shape a list widget draws.
            for (b.outline, 0..) |e, i| {
                s.rows.append(s.gpa, .{
                    .label = e.title,
                    .page = if (e.page) |p| p + 1 else 0,
                    .depth = e.depth,
                    // From one, because zero is `State.chosen`'s "none".
                    .id = i + 1,
                }) catch break;
            }
        },
        .plugin => |id| {
            const rt = s.plugins orelse return s.rows.items;
            // Borrowed from Galdr, which holds the strings until the next
            // time a panel is asked -- and that is here, so they outlive
            // every frame drawn from them.
            for (rt.panelRows(id)) |r| {
                s.rows.append(s.gpa, .{
                    .label = r.label,
                    .detail = r.detail,
                    .page = r.page,
                    .swatch = if (r.color.len == 0) null else Library.parseColor(r.color),
                    .depth = r.depth,
                    .id = r.id,
                }) catch break;
            }
        },
        .changes => {
            const cmp = s.diff orelse return s.rows.items;
            const side: u1 = if (v.buffer == 1) 1 else 0;
            for (cmp.results, cmp.pairs, 0..) |r, p, i| {
                if (!r.differs()) continue;
                // The words when any changed, which is what somebody
                // reading the list wants; otherwise what kind of change,
                // in the few words a row has room for. The page is this
                // window's own, or where it stands beside one it lacks.
                const own = if (side == 0) p.a else p.b;
                const page = own orelse cmp.partner(side ^ 1, (if (side == 0) p.b else p.a).?);
                s.rows.append(s.gpa, .{
                    .label = if (r.detail.len != 0) r.detail else switch (r.kind) {
                        .only_a => "only in the first document",
                        .only_b => "only in the second document",
                        .failed => "could not be compared",
                        else => "pixels changed and no words did",
                    },
                    .page = page + 1,
                    .swatch = switch (r.kind) {
                        .only_a => compare.diff_removed,
                        .only_b => compare.diff_added,
                        else => null,
                    },
                    // From one: zero is `State.chosen`'s "none".
                    .id = i + 1,
                }) catch break;
            }
        },
        .annotations => {
            const filter = marks.markFilter(s);
            for (b.marks.items(), 0..) |m, i| {
                const said = b.marks.said(m.anchor);
                if (!filter.matches(m, said)) continue;
                // The comment on its anchor's first line, and the lines
                // after it a step in, under it, saying only what they
                // are: six rows of one comment would read as six.
                const lead = said.len != 0 and b.marks.leads(s.gpa, i);
                const what = if (m.kind == .ink) "ink" else m.style.label();
                s.rows.append(s.gpa, .{
                    // A row with nothing written on it still has to say
                    // something, and what it says is this panel's to
                    // decide -- `panels.Row` draws what it is given. A
                    // stroke or a mark that is not a highlight says what
                    // it is, since its chip cannot.
                    .label = if (lead)
                        said[0].text
                    else if (said.len != 0 or m.kind == .ink or m.style != .highlight)
                        what
                    else
                        "no comment",
                    .depth = @intFromBool(said.len != 0 and !lead),
                    .page = m.page + 1,
                    .swatch = m.color,
                    .id = m.key,
                }) catch break;
            }
            // Reading order, which is the order `n` walks them in and the
            // order somebody would find them by reading. The keys go with
            // the rows, so sorting here cannot lose track of which
            // highlight a row is.
            std.mem.sort(panels.Row, s.rows.items, b, lessByReading);
        },
    }
    return s.rows.items;
}

/// An outline entry, by its row id, which is its index plus one.
///
/// Not `scrollToBox`, which moves as little as it can: a bookmark is a
/// place somebody asked to be taken to, so the destination goes to the
/// top of the window rather than merely into it. An entry whose
/// destination did not resolve says so and moves nothing -- the title was
/// worth keeping even though the place was not.
fn goToBookmark(s: *Session, id: u64) void {
    const v = s.view();
    const b = s.buffer(v.buffer);
    if (id == 0 or id > b.outline.len) return;
    const entry = b.outline[id - 1];

    const page = entry.page orelse {
        s.say("\"{s}\" does not say where it goes", .{
            entry.title[0..@min(entry.title.len, 64)],
        });
        return;
    };
    if (page >= v.pages.len) return;

    v.scrollToPage(page);
    // User space counts upwards from the bottom of the page, so how far
    // down the page a destination is, is the page's height less its `top`.
    const t = entry.top orelse return;
    const height: f32 = @floatCast(v.pages[page].displayHeight());
    v.scroll += std.math.clamp(height - @as(f32, @floatCast(t)), 0, height) * v.zoom;
    v.clampScroll();
}

fn lessByReading(b: *Buffer, x: panels.Row, y: panels.Row) bool {
    const a = b.marks.byKey(x.id) orelse return false;
    const c = b.marks.byKey(y.id) orelse return true;
    return Marks.readsBefore(a.*, c.*);
}

/// The panel the rail has open, and what was clicked in it.
pub fn drawPanel(s: *Session, c: *chrome_mod.Chrome) !void {
    const which = c.rails.panel;
    if (which == .none) {
        s.panel.rect = .empty;
        // Or a panel shut while its filter had the keyboard keeps it.
        s.panel.typing = false;
        return;
    }
    s.panel.chosen = s.focus_mark orelse 0;

    // A plugin's panel names itself; the reader's own are named here.
    // Both are one call, because a panel declared in Lua is a title, a
    // sentence for when it is empty, and a list of rows -- which is all
    // the annotations panel ever was.
    const declared = declaredPanel(s, which);
    const rows = panelRows(s, which);
    // Every mark is a row unless the filter says not, so marks and no
    // rows can only be the filter.
    const marked = s.buffer(s.view().buffer).marks.count() != 0;
    const chosen = try panels.panel(
        &c.ui,
        c.face,
        c.theme,
        &c.icons,
        if (declared) |p| p.title else which.label(),
        if (declared) |p| p.empty else switch (which) {
            .none, .annotations => if (marked) "nothing matches the filter" else "no highlights yet",
            .bookmarks => "this document has no outline",
            .changes => "no differences",
            .plugin => "",
        },
        if (which == .annotations) "colour, style, ink, commented, #tag" else null,
        rows,
        &s.panel,
        c.top,
    ) orelse return;

    if (panels.wasClosed(chosen)) {
        c.rails.show(.none);
        return;
    }
    switch (which) {
        .none => {},
        .bookmarks => goToBookmark(s, chosen.id),
        // The same gesture `n` makes: the highlight goes in hand and the
        // view scrolls to it, so clicking a row and pressing `d` deletes
        // the one that was clicked.
        .annotations => marks.focusMark(s, chosen.id),
        // The pair's first change, as `]d` would land on it.
        .changes => if (s.diff) |cmp| {
            for (cmp.changes, 0..) |change, i| {
                if (change.pair + 1 != chosen.id) continue;
                compare.goToChange(s, i);
                s.say("change {d}/{d}", .{ i + 1, cmp.changes.len });
                break;
            }
        },
        // A plugin's row means whatever the plugin says it means, and a
        // row with a page on it also goes there -- which is what every
        // other panel row in this reader does, so a plugin gets it
        // without having to write it.
        .plugin => |id| if (s.plugins) |rt| {
            if (chosen.page != 0) _ = s.goToPage(chosen.page);
            rt.choosePanelRow(id, chosen.id);
            marks.applyEffects(s);
        },
    }
    s.dirty_title = true;
}

/// The plugin panel `which` names, or null for one of the reader's own.
pub fn declaredPanel(s: *Session, which: rails_mod.Panel) ?galdr.Runtime.Panel {
    const id = switch (which) {
        .plugin => |i| i,
        else => return null,
    };
    const rt = s.plugins orelse return null;
    for (rt.panelList()) |p| {
        if (p.id == id and p.live) return p;
    }
    return null;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const plugins_mod = @import("plugins.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const givePlugins = fixtures.givePlugins;
const sessionOf = fixtures.sessionOf;

test "the settings page holds the keyboard while it is open" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(!s.interfaceHasInput());
    try testing.expect(s.exec("settings"));
    try testing.expect(s.settings.open);
    // Otherwise escape would leave a mode and the arrows would scroll the
    // document out from under the page.
    try testing.expect(s.interfaceHasInput());

    try testing.expect(s.exec("settings"));
    try testing.expect(!s.settings.open);
    try testing.expect(!s.interfaceHasInput());
}

test "a setting changed on the page goes through the same door as the command" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    changeSetting(&s, .{ .key = "theme", .value = "light" });
    try testing.expectEqualStrings("light", s.theme.name);

    // A colour is parsed where it is typed, so a row nobody could read is
    // refused rather than found wrong on the next start.
    changeSetting(&s, .{ .key = "accent", .value = "not a colour" });
    try testing.expect(s.chosen_accent == null);

    changeSetting(&s, .{ .key = "accent", .value = "orange" });
    try testing.expect(s.chosen_accent != null);
    try testing.expectEqual(s.chosen_accent.?, s.accent);
    try testing.expectEqual(s.chosen_accent.?, s.highlight);
}

test "with no library every setting is unset, and saying so is not a crash" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    readSettings(&s);
    for (settings_page.builtin, 0..) |_, i| {
        try testing.expectEqual(@as(usize, 0), s.settings.valueOf(i).len);
    }
    // The theme still changes; there is simply nowhere to keep it.
    changeSetting(&s, .{ .key = "theme", .value = "light" });
    try testing.expectEqualStrings("light", s.theme.name);
}

test "the palette holds the keyboard, and opens from the key and the command" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(!s.interfaceHasInput());
    _ = s.apply(.show_commands);
    try testing.expect(s.palette.open);
    try testing.expect(s.interfaceHasInput());
    // Every built-in is in it, whether or not this build has plugins.
    try testing.expectEqual(commands.table.len, s.palette_rows.items.len);

    s.palette.hide();
    try testing.expect(s.exec("commands"));
    try testing.expect(s.palette.open);
}

test "a panel a plugin declared latches on the rail and lists what it says" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    const rt = try galdr.Runtime.create(gpa, plugins_mod.host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    try testing.expect(rt.runString("init.lua",
        \\opened = nil
        \\titles = { "Chapter one", "Chapter two" }
        \\fenrir.panel{
        \\  id = "reading", title = "Reading list", icon = "fenrir.bookmark",
        \\  empty = "nothing saved yet",
        \\  rows = function()
        \\    local out = {}
        \\    for i, t in ipairs(titles) do
        \\      out[i] = { label = t, detail = "kept", page = i * 3, id = 100 + i }
        \\    end
        \\    return out
        \\  end,
        \\  choose = function(row) opened = row end,
        \\}
    ));

    fillRailButtons(&s);
    try testing.expectEqual(@as(usize, 1), s.rail_panels.items.len);
    const id = s.rail_panels.items[0].id;
    try testing.expectEqualStrings("Reading list", s.rail_panels.items[0].label);
    try testing.expectEqualStrings("fenrir.bookmark", s.rail_panels.items[0].icon);

    const which: rails_mod.Panel = .{ .plugin = id };
    const rows = panelRows(&s, which);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Chapter two", rows[1].label);
    try testing.expectEqualStrings("kept", rows[1].detail);
    try testing.expectEqual(@as(u32, 6), rows[1].page);
    try testing.expectEqualStrings("Reading list", declaredPanel(&s, which).?.title);
    try testing.expect(declaredPanel(&s, .annotations) == null);

    // Cached until the plugin says otherwise, and rebuilt when it does.
    try testing.expect(rt.runString("more", "titles[3] = 'Chapter three'"));
    try testing.expectEqual(@as(usize, 2), panelRows(&s, which).len);
    try testing.expect(rt.runString("refresh", "fenrir.refresh()"));
    try testing.expectEqual(@as(usize, 3), panelRows(&s, which).len);
}

test "a plugin's commands and settings arrive in the palette and the page" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    const rt = try galdr.Runtime.create(gpa, plugins_mod.host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    try testing.expect(rt.runString("init.lua",
        \\fenrir.command("Read", function() end, "open the reading list", "fenrir.bookmark")
        \\fenrir.command("Sync", function() end, "fetch what is new")
        \\fenrir.keymap("n", "<C-r>", "Read", "the reading list")
        \\fenrir.setting{ key = "reading.list", about = "where the list is kept", unset = "nowhere" }
    ));

    _ = s.apply(.show_commands);
    const rows = s.palette_rows.items;
    try testing.expectEqual(commands.table.len + 2, rows.len);
    const read_row = rows[commands.table.len];
    try testing.expectEqualStrings("Read", read_row.name);
    try testing.expectEqualStrings("open the reading list", read_row.about);
    try testing.expectEqualStrings("fenrir.bookmark", read_row.icon);
    // The binding the plugin made itself, found through the command line it
    // bound -- so the palette draws it beside the row like any other.
    try testing.expectEqualStrings("<C-r>", read_row.binding);
    // A command nobody bound claims no binding, and falls back to the menu
    // icon rather than to nothing.
    try testing.expectEqual(@as(usize, 0), rows[commands.table.len + 1].binding.len);
    try testing.expectEqualStrings("fenrir.menu", rows[commands.table.len + 1].icon);

    // And the settings page lists the plugin's row after the reader's own.
    readSettings(&s);
    try testing.expectEqual(settings_page.builtin.len + 1, s.settings.count());
    const at = settings_page.builtin.len;
    try testing.expectEqualStrings("reading.list", s.settings.optionAt(at).key);
    try testing.expect(s.settings.isPlugin(at));
    // Which is where `fenrir.store` already keeps it: one key, not two.
    var key_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("galdr.reading.list", settingKey(&s, &key_buf, at).?);
    try testing.expectEqualStrings("theme", settingKey(&s, &key_buf, 0).?);

    // A key a plugin took is no longer the built-in's, and the palette says
    // so: `<C-r>` was redo's and the plugin has it now. Found by a picture --
    // the two rows sat one above the other claiming the same chord.
    for (rows) |row| {
        if (!std.mem.eql(u8, row.name, "redo")) continue;
        try testing.expectEqual(@as(usize, 0), row.binding.len);
    }
    // And a key nobody took keeps the binding the table gives it.
    for (rows) |row| {
        if (!std.mem.eql(u8, row.name, "quit")) continue;
        try testing.expectEqualStrings("q", row.binding);
    }
}

test "a row chosen in the palette runs the command it names" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    showPalette(&s);
    runChosen(&s, .{ .row = .{ .name = "split" } });
    try testing.expectEqual(@as(usize, 2), s.layout().count());

    // And a line nothing matched goes down the same path a typed one does.
    runChosen(&s, .{ .line = "page 3" });
    try testing.expectEqual(@as(u32, 2), s.view().currentPage());
}

test "a command that needs an argument lands on the : line, not in the void" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    showPalette(&s);
    const entry = commands.get(.page);
    try testing.expect(entry.needs_argument);
    runChosen(&s, .{ .row = .{ .name = entry.name, .needs_argument = true } });

    try testing.expectEqual(keys.Mode.command, s.keymap.mode);
    try testing.expectEqualStrings("page ", s.cmdline.items);
}
