//! The command registry: every `:` command in one table.
//!
//! `read.zig` dispatched on `std.meta.stringToEnum` over an enum written on
//! one line. That works and says nothing: a name has no description, no
//! abbreviation anybody wrote down, and no way to be *listed*. A palette, a
//! menu and `fenrir commands` each need the same four facts about a command,
//! and three tables of them would be three tables to keep in step.
//!
//! So the enum stays -- it is what the reader switches on, and a switch over
//! an enum is the one dispatch the compiler checks is complete -- and
//! everything else about a command moves here beside it. `exec` looks a name
//! up and runs the same switch it always ran.
//!
//! ## What is here and what is the reader's
//!
//! Names, abbreviations, what each command is for, and where it is offered.
//! Not what any of them *do*: this file cannot quit, split or zoom, has no
//! session to do it to, and imports nothing but the keymap. That is what
//! lets the whole table be asked about in a test with no window, no device
//! and no document -- and it is the same division `chrome.zig` draws for the
//! status bar and `panels.zig` for a panel row.
//!
//! ## The abbreviations are data, not a second name
//!
//! Vim's `:q`, `:sp`, `:tabn` were a second dozen enum tags, which meant
//! `.q, .quit =>` at every arm and a name nobody could enumerate. They are
//! `aliases` now, and `find` walks them -- so `fenrir commands` can print
//! them in a column and the palette can search them.
//!
//! ## The mode set
//!
//! Every built-in is offered in every mode today, and the field is not
//! decoration for that: a plugin's command declares one already -- Galdr's
//! keymaps have carried a `ModeSet` since they were written -- and the
//! palette shows both lists as one. A row that could not say which modes it
//! belongs in would have to be two kinds of row.

const std = @import("std");

const keys = @import("keys.zig");

/// The modes a command is *offered* in. Typing it always works: this is what
/// a list of commands filters by, not what `exec` enforces.
///
/// The same four the plugin runtime's keymaps use, and deliberately not the
/// six of `keys.Mode` -- note mode and the command line are somebody typing,
/// and a command offered under the keys being typed into is not offered, it
/// is in the way.
pub const ModeSet = packed struct(u8) {
    normal: bool = false,
    visual: bool = false,
    edit: bool = false,
    draw: bool = false,
    _: u4 = 0,

    pub const any: ModeSet = .{ .normal = true, .visual = true, .edit = true, .draw = true };

    pub fn has(m: ModeSet, mode: keys.Mode) bool {
        return switch (mode) {
            .normal => m.normal,
            .visual, .visual_line => m.visual,
            .edit => m.edit,
            .draw => m.draw,
            .note, .command => false,
        };
    }
};

/// What the reader switches on. One tag per command, whatever it is spelled.
pub const Id = enum {
    quit,
    quit_all,
    split,
    vsplit,
    close,
    only,
    tabnew,
    tabclose,
    tabonly,
    tabnext,
    tabprevious,
    bnext,
    bprevious,
    page,
    zoom,
    fit,
    set,
    settings,
    palette,
    undo,
    redo,
    marks,
    lua,
    messages,
    plugins,
    echo,
};

pub const Entry = struct {
    id: Id,
    /// What `:` takes, and what a list shows.
    name: []const u8,
    /// Other spellings, Vim's abbreviations first.
    aliases: []const []const u8 = &.{},
    /// What follows the name, as a usage line writes it. Empty for a command
    /// that takes nothing.
    args: []const u8 = "",
    /// The argument is not optional. What tells a list to put the name on the
    /// `:` line with a space after it rather than run it: `:page` with
    /// nothing after it is a mistake, `:marks` is a question.
    needs_argument: bool = false,
    /// One line, in the words `fenrir commands` prints and a palette row
    /// shows. Lower case and no full stop, like every other listing here.
    about: []const u8,
    /// The registered icon name, or empty for a command with no picture
    /// worth drawing. Empty and not `fenrir.unknown`: a list of twenty-five
    /// commands under twenty-five hollow boxes says less than a blank
    /// gutter, and the hollow box is for an icon that was *meant* to resolve.
    ///
    /// A name and not an `Icons.Id`, because the registry is Hliðskjálf's and
    /// the icons are Þviti's, and neither should have to know the other
    /// exists.
    icon: []const u8 = "",
    /// The keys that reach the same thing without the command line, as a
    /// binding writes them. Drawn beside the name, because the design
    /// language says every command's binding is drawn beside it.
    binding: []const u8 = "",
    modes: ModeSet = .any,
};

/// Every built-in, in the order a listing shows them: the reader, then
/// windows, tabpages and documents, then the page, then what is remembered,
/// then the plugins.
///
/// Written as a table and kept as one -- one entry a line or two, not eight
/// -- because the thing being checked by eye is that twenty-five rows agree
/// with each other, and a column somebody has to scroll past a page of
/// braces to compare is a column nobody compares.
pub const table = [_]Entry{
    .{ .id = .quit, .name = "quit", .aliases = &.{"q"}, .icon = "fenrir.close", .binding = "q", .about = "close the window, or the reader if it is the last" },
    .{ .id = .quit_all, .name = "qall", .aliases = &.{ "qa", "quitall" }, .icon = "fenrir.close", .binding = "Q", .about = "leave the reader, whatever is open" },

    .{ .id = .split, .name = "split", .aliases = &.{"sp"}, .icon = "fenrir.split", .binding = "<C-w>s", .about = "split the window across" },
    .{ .id = .vsplit, .name = "vsplit", .aliases = &.{"vs"}, .icon = "fenrir.split", .binding = "<C-w>v", .about = "split the window down" },
    .{ .id = .close, .name = "close", .icon = "fenrir.close", .binding = "<C-w>c", .about = "close the focused window" },
    .{ .id = .only, .name = "only", .icon = "fenrir.panel", .binding = "<C-w>o", .about = "close every window but this one" },

    .{ .id = .tabnew, .name = "tabnew", .icon = "fenrir.plus", .about = "a tabpage on what this window is looking at" },
    .{ .id = .tabclose, .name = "tabclose", .icon = "fenrir.close", .about = "close the tabpage on screen" },
    .{ .id = .tabonly, .name = "tabonly", .icon = "fenrir.panel", .about = "close every tabpage but this one" },
    .{ .id = .tabnext, .name = "tabnext", .aliases = &.{"tabn"}, .args = "[N]", .icon = "fenrir.chevron_right", .binding = "gt", .about = "the next tabpage, or the Nth" },
    .{ .id = .tabprevious, .name = "tabprevious", .aliases = &.{"tabp"}, .args = "[N]", .icon = "fenrir.chevron_left", .binding = "gT", .about = "the previous tabpage, or the Nth" },

    .{ .id = .bnext, .name = "bnext", .aliases = &.{"bn"}, .icon = "fenrir.chevron_right", .binding = "<C-w>n", .about = "show the next open document in this window" },
    .{ .id = .bprevious, .name = "bprevious", .aliases = &.{"bp"}, .icon = "fenrir.chevron_left", .binding = "<C-w>b", .about = "show the previous open document in this window" },

    .{ .id = .page, .name = "page", .args = "N | +N | -N", .needs_argument = true, .icon = "fenrir.page", .about = "go to a page, or so many pages along" },
    .{ .id = .zoom, .name = "zoom", .args = "PERCENT", .needs_argument = true, .icon = "fenrir.zoom_in", .binding = "+ -", .about = "set the zoom, as a percentage of the true size" },
    .{ .id = .fit, .name = "fit", .args = "[width|height|page|actual]", .icon = "fenrir.fit_width", .binding = "0", .about = "tie the zoom to the shape of the window" },

    .{ .id = .set, .name = "set", .args = "[NAME=VALUE]", .icon = "fenrir.settings", .about = "a setting, by name" },
    .{ .id = .settings, .name = "settings", .icon = "fenrir.settings", .about = "the settings page, which lists them all" },
    .{ .id = .palette, .name = "commands", .icon = "fenrir.menu", .binding = "<C-p>", .about = "every command there is, filtered as you type" },
    .{ .id = .undo, .name = "undo", .icon = "fenrir.chevron_left", .binding = "u", .about = "undo the last change to the marks" },
    .{ .id = .redo, .name = "redo", .icon = "fenrir.chevron_right", .binding = "<C-r>", .about = "redo what was undone" },
    .{ .id = .marks, .name = "marks", .args = "[clear]", .icon = "fenrir.highlight", .about = "how many highlights and lines of ink there are, or clear them" },

    .{ .id = .lua, .name = "lua", .args = "CODE", .needs_argument = true, .icon = "fenrir.menu", .about = "run a line of Lua in the plugin runtime" },
    .{ .id = .messages, .name = "messages", .icon = "fenrir.note", .about = "what the plugins have said, and why one failed" },
    .{ .id = .plugins, .name = "plugins", .icon = "fenrir.menu", .about = "which plugins loaded" },
    .{ .id = .echo, .name = "echo", .args = "TEXT", .needs_argument = true, .icon = "fenrir.note", .about = "say something on the message line" },
};

/// The entry a name or an abbreviation reaches, or null.
///
/// A walk over twenty-five entries with a length compare first, which is
/// faster than a hash for a table this size and is run once per `:` line
/// anyway -- never on a frame path.
pub fn find(name: []const u8) ?*const Entry {
    for (&table) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
        for (e.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return e;
        }
    }
    return null;
}

/// The entry for an id. Every id is in the table -- a test says so -- so this
/// answers for all of them.
pub fn get(id: Id) *const Entry {
    for (&table) |*e| {
        if (e.id == id) return e;
    }
    unreachable;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "every id is in the table exactly once" {
    for (std.enums.values(Id)) |id| {
        var seen: usize = 0;
        for (table) |e| {
            if (e.id == id) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
    try testing.expectEqual(@typeInfo(Id).@"enum".fields.len, table.len);
}

test "no two commands answer to the same word" {
    for (table, 0..) |a, i| {
        try testing.expect(find(a.name).?.id == a.id);
        for (a.aliases) |word| try testing.expect(find(word).?.id == a.id);

        for (table[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
            for (b.aliases) |word| try testing.expect(!std.mem.eql(u8, a.name, word));
            for (a.aliases) |word| {
                try testing.expect(!std.mem.eql(u8, word, b.name));
                for (b.aliases) |other| try testing.expect(!std.mem.eql(u8, word, other));
            }
        }
    }
}

test "a name nobody registered is not a command" {
    try testing.expect(find("") == null);
    try testing.expect(find("qui") == null);
    try testing.expect(find("Quit") == null);
    try testing.expect(find("quits") == null);
}

test "every entry says what it is for, in the listing's voice" {
    for (table) |e| {
        try testing.expect(e.about.len != 0);
        try testing.expect(e.about[e.about.len - 1] != '.');
        try testing.expect(!std.ascii.isUpper(e.about[0]));
        try testing.expect(e.name.len != 0);
        for (e.name) |c| try testing.expect(std.ascii.isLower(c));
        // A command that must be given something has to say what.
        if (e.needs_argument) try testing.expect(e.args.len != 0);
    }
}

test "get answers for every id" {
    for (std.enums.values(Id)) |id| try testing.expectEqual(id, get(id).id);
    try testing.expectEqualStrings("quit", get(.quit).name);
}

test "the modes a command is offered in" {
    try testing.expect(ModeSet.any.has(.normal));
    try testing.expect(ModeSet.any.has(.visual_line));
    try testing.expect(ModeSet.any.has(.edit));
    try testing.expect(ModeSet.any.has(.draw));
    // Nothing is offered while a note or a command line is being typed.
    try testing.expect(!ModeSet.any.has(.note));
    try testing.expect(!ModeSet.any.has(.command));

    const only_normal: ModeSet = .{ .normal = true };
    try testing.expect(only_normal.has(.normal));
    try testing.expect(!only_normal.has(.visual));
}
