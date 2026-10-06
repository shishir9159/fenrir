//! An icon theme, read out of a Lua table.
//!
//! A theme is a *mapping*: an icon id on the left, and on the right either
//! path data or a code point in a font the theme brings with it. Nothing
//! else. There is no code to run, so there is nothing here that wants the
//! plugin sandbox -- this opens a Lua state with no libraries at all, loads
//! one chunk, and reads the table it returns:
//!
//!     return {
//!       font = "icons/nerd.ttf",
//!       icons = {
//!         ["fenrir.bookmark"] = "M6 2h12v20l-6-5-6 5z",
//!         ["fenrir.search"]   = { glyph = 0xf002 },
//!         ["fenrir.note"]     = { path = "M3 4h18v13H8z", slot = "menu" },
//!       },
//!     }
//!
//! A bare table of names to values is accepted too, `icons` being the only
//! reason to nest: a theme that names a font has to put it somewhere.
//!
//! **Why Lua rather than a format of its own.** Because the configuration
//! directory is already Lua and a reader who has written `init.lua` knows
//! how to write this. A second syntax would be a second parser, a second set
//! of error messages, and a second thing to document -- for a file whose
//! whole content is a table literal.
//!
//! ## What this file does not do
//!
//! It does not open the font it names, and it does not resolve slot names.
//! Both belong to whoever is applying the theme: the font is a *file*, and
//! the library layer does not open files, and `Slot` is Þviti's enum, which
//! Galdr has no business importing. So the entries come back as strings and
//! numbers, and `vanagandr/icons.zig` turns them into a registration.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lua = @import("lua.zig");

pub const Error = error{
    /// This build has no Lua, so a theme cannot be read at all.
    NoLua,
    /// The chunk did not load, did not run, or did not return a table.
    BadTheme,
    OutOfMemory,
};

/// What draws one icon, as a theme says it.
pub const Source = union(enum) {
    /// SVG path data, on the icon grid.
    path: []const u8,
    /// A code point in the theme's own font.
    glyph: u21,
};

pub const Entry = struct {
    /// The icon id, unvalidated: this file has no opinion about what a name
    /// may contain, and the registry that interns it does.
    name: []const u8,
    /// The slot this applies to, as written, or null for every slot.
    slot: ?[]const u8 = null,
    source: Source,
};

/// Everything a theme file said. All of it lives in `arena`, so a caller
/// holds one thing and frees one thing.
pub const Theme = struct {
    arena: std.heap.ArenaAllocator,
    /// A font file the theme wants opened, relative to the configuration
    /// directory. Null when every icon in it is path data.
    font: ?[]const u8 = null,
    entries: []const Entry = &.{},

    pub fn deinit(t: *Theme) void {
        t.arena.deinit();
        t.* = undefined;
    }
};

/// Why a theme was refused, in words that can be printed. Copied rather than
/// borrowed: the message belongs to a Lua state that is closed before this
/// function returns.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }
};

/// A theme is a table literal. Four megabytes is thousands of icons, and a
/// file that wants more than that is not a theme.
pub const memory_limit: usize = 4 << 20;

/// Hook ticks one load may run for. A theme has no loops in it, so this is
/// only ever reached by a file that is trying to be something else.
pub const step_limit: c_int = 200_000;

/// Reads `source` as a theme. `name` is what errors call it.
pub fn read(
    gpa: Allocator,
    name: []const u8,
    source: []const u8,
    diag: ?*Diagnostic,
) Error!Theme {
    if (!lua.available) return error.NoLua;

    var budget: Budget = .{};
    const L = lua.lua_newstate(allocate, &budget) orelse return error.OutOfMemory;
    defer lua.lua_close(L);
    lua.lua_sethook(L, hook, lua.mask_count, step_limit);

    var chunk: [128]u8 = undefined;
    const chunkname = std.fmt.bufPrintZ(&chunk, "@{s}", .{name}) catch "@theme";
    // "t" is text only: a theme must not be precompiled bytecode, which is
    // not validated by the Lua VM and can crash it.
    if (lua.luaL_loadbufferx(L, source.ptr, source.len, chunkname, "t") != lua.ok) {
        return refuse(diag, lua.toString(L, -1) orelse "cannot load");
    }
    if (lua.pcall(L, 0, 1, 0) != lua.ok) {
        return refuse(diag, lua.toString(L, -1) orelse "cannot run");
    }
    if (lua.typeOf(L, -1) != .table) {
        return refuse(diag, "a theme must return a table");
    }

    var theme: Theme = .{ .arena = .init(gpa) };
    errdefer theme.deinit();
    const a = theme.arena.allocator();

    if (lua.lua_getfield(L, -1, "font") == tag(.string)) {
        theme.font = try a.dupe(u8, lua.toString(L, -1).?);
    }
    lua.pop(L, 1);

    var entries: std.ArrayList(Entry) = .empty;
    // `icons = {...}` if there is one, and the theme table itself otherwise.
    const nested = lua.lua_getfield(L, -1, "icons") == tag(.table);
    if (!nested) lua.pop(L, 1);
    try collect(L, a, &entries);
    if (nested) lua.pop(L, 1);

    // A Lua table has no order, so two runs over the same file walk it
    // differently and a caller that numbers what it applies -- the icon face
    // does, one glyph per path -- would produce a different listing each
    // time. Sorting by name is what makes `fenrir icons --theme` a diff.
    std.mem.sort(Entry, entries.items, {}, byName);
    theme.entries = try entries.toOwnedSlice(a);
    return theme;
}

fn byName(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Reads every key of the table on top of the stack.
///
/// Entries that are not `string = source` are skipped rather than refused.
/// A theme is a file somebody edits by hand, and one line it got wrong
/// should cost that line -- the same argument `loadConfig` makes for one
/// broken plugin among several.
fn collect(L: *lua.State, a: Allocator, out: *std.ArrayList(Entry)) Error!void {
    lua.lua_pushnil(L);
    while (lua.lua_next(L, -2) != 0) {
        defer lua.pop(L, 1);

        // The key is read but never converted: `lua_tolstring` on a number
        // key rewrites it in place, and `lua_next` then loses its place in
        // the table. Checking the type first is what makes it safe.
        if (lua.typeOf(L, -2) != .string) continue;
        const key = lua.toString(L, -2) orelse continue;
        // The one reserved name, so that a flat theme can still name a font.
        if (std.mem.eql(u8, key, "font")) continue;

        var slot: ?[]const u8 = null;
        const source: ?Source = switch (lua.typeOf(L, -1)) {
            // The short form: an id and the path that draws it.
            .string => .{ .path = try a.dupe(u8, lua.toString(L, -1).?) },
            // The shorter one, for a font theme: an id and a code point.
            .number => point(lua.lua_tointegerx(L, -1, null)),
            .table => blk: {
                var s: ?Source = null;
                if (lua.lua_getfield(L, -1, "path") == tag(.string)) {
                    s = .{ .path = try a.dupe(u8, lua.toString(L, -1).?) };
                }
                lua.pop(L, 1);

                if (lua.lua_getfield(L, -1, "glyph") == tag(.number)) {
                    if (s == null) s = point(lua.lua_tointegerx(L, -1, null));
                }
                lua.pop(L, 1);

                if (lua.lua_getfield(L, -1, "slot") == tag(.string)) {
                    slot = try a.dupe(u8, lua.toString(L, -1).?);
                }
                lua.pop(L, 1);
                break :blk s;
            },
            else => null,
        };

        try out.append(a, .{
            .name = try a.dupe(u8, key),
            .slot = slot,
            .source = source orelse continue,
        });
    }
}

fn point(n: lua.Integer) ?Source {
    if (n < 0 or n > std.math.maxInt(u21)) return null;
    return .{ .glyph = @intCast(n) };
}

fn tag(t: lua.Type) c_int {
    return @intFromEnum(t);
}

fn refuse(diag: ?*Diagnostic, message: []const u8) Error {
    if (diag) |d| {
        d.len = @min(message.len, d.buf.len);
        @memcpy(d.buf[0..d.len], message[0..d.len]);
    }
    return error.BadTheme;
}

// -- the state ---------------------------------------------------------------

const Budget = struct {
    used: usize = 0,
};

fn budgetOf(L: ?*lua.State) *Budget {
    var ud: ?*anyopaque = null;
    _ = lua.lua_getallocf(L, &ud);
    return @ptrCast(@alignCast(ud.?));
}

/// Lua's allocator, counted against `memory_limit`. The same shape as
/// `Runtime`'s, and for the same reason: a file from outside this program
/// must not be able to ask for all the memory there is.
fn allocate(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const budget: *Budget = @ptrCast(@alignCast(ud.?));
    const old = if (ptr == null) 0 else osize;

    if (nsize == 0) {
        std.c.free(ptr);
        budget.used -|= old;
        return null;
    }
    if (nsize > old and budget.used - old + nsize > memory_limit) return null;

    const moved = std.c.realloc(ptr, nsize) orelse {
        if (nsize <= old) return ptr;
        return null;
    };
    budget.used = budget.used - old + nsize;
    return moved;
}

fn hook(L: ?*lua.State, _: ?*lua.Debug) callconv(.c) void {
    // Nothing here resets the count, unlike `Runtime`'s: a theme is loaded
    // once and then the state is closed, so there is no next call to budget
    // for.
    _ = budgetOf(L);
    lua.raise(L, "galdr: a theme is a table, and this one is still running");
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn themed(source: []const u8) !Theme {
    return read(testing.allocator, "theme.lua", source, null);
}

test "a flat table of ids and path data" {
    if (!lua.available) return error.SkipZigTest;

    var theme = try themed(
        \\return {
        \\  ["fenrir.bookmark"] = "M6 2h12v20z",
        \\  ["notes.pin"] = "M4 4h16v16H4z",
        \\}
    );
    defer theme.deinit();

    try testing.expectEqual(@as(usize, 2), theme.entries.len);
    try testing.expect(theme.font == null);
    for (theme.entries) |e| {
        try testing.expect(e.slot == null);
        try testing.expect(e.source == .path);
        try testing.expect(e.source.path.len > 0);
    }
}

test "entries come back in name order, whatever order Lua walked them in" {
    if (!lua.available) return error.SkipZigTest;

    var theme = try themed(
        \\return {
        \\  ["z.one"] = "M0 0h1v1H0z",
        \\  ["a.two"] = "M0 0h2v2H0z",
        \\  ["m.three"] = "M0 0h3v3H0z",
        \\}
    );
    defer theme.deinit();

    try testing.expectEqual(@as(usize, 3), theme.entries.len);
    try testing.expectEqualStrings("a.two", theme.entries[0].name);
    try testing.expectEqualStrings("m.three", theme.entries[1].name);
    try testing.expectEqualStrings("z.one", theme.entries[2].name);
}

test "a font theme names its font and its code points" {
    if (!lua.available) return error.SkipZigTest;

    var theme = try themed(
        \\return {
        \\  font = "icons/nerd.ttf",
        \\  icons = {
        \\    ["fenrir.search"] = 0xf002,
        \\    ["fenrir.note"] = { glyph = 0xf075, slot = "menu" },
        \\  },
        \\}
    );
    defer theme.deinit();

    try testing.expectEqualStrings("icons/nerd.ttf", theme.font.?);
    try testing.expectEqual(@as(usize, 2), theme.entries.len);

    for (theme.entries) |e| {
        try testing.expect(e.source == .glyph);
        if (std.mem.eql(u8, e.name, "fenrir.note")) {
            try testing.expectEqual(@as(u21, 0xf075), e.source.glyph);
            try testing.expectEqualStrings("menu", e.slot.?);
        } else {
            try testing.expectEqual(@as(u21, 0xf002), e.source.glyph);
            try testing.expect(e.slot == null);
        }
    }
}

test "the font key is not an icon, flat table or not" {
    if (!lua.available) return error.SkipZigTest;

    var theme = try themed(
        \\return { font = "a.ttf", ["fenrir.note"] = "M0 0h4v4H0z" }
    );
    defer theme.deinit();

    try testing.expectEqualStrings("a.ttf", theme.font.?);
    try testing.expectEqual(@as(usize, 1), theme.entries.len);
    try testing.expectEqualStrings("fenrir.note", theme.entries[0].name);
}

test "a line the theme got wrong costs that line" {
    if (!lua.available) return error.SkipZigTest;

    var theme = try themed(
        \\return {
        \\  ["fenrir.note"] = true,
        \\  ["fenrir.page"] = { colour = "red" },
        \\  [3] = "M0 0h4v4H0z",
        \\  ["fenrir.open"] = "M0 0h4v4H0z",
        \\}
    );
    defer theme.deinit();

    // Only the one that said something a theme can say.
    try testing.expectEqual(@as(usize, 1), theme.entries.len);
    try testing.expectEqualStrings("fenrir.open", theme.entries[0].name);
}

test "a theme that is not a table, and one that does not compile" {
    if (!lua.available) return error.SkipZigTest;

    var d: Diagnostic = .{};
    try testing.expectError(
        error.BadTheme,
        read(testing.allocator, "theme.lua", "return 7", &d),
    );
    try testing.expectEqualStrings("a theme must return a table", d.message());

    try testing.expectError(
        error.BadTheme,
        read(testing.allocator, "theme.lua", "return {", &d),
    );
    // Lua's own message, which names the line, and is the only useful thing
    // to print here.
    try testing.expect(std.mem.indexOf(u8, d.message(), "theme.lua") != null);
}

test "a theme that tries to be a program is stopped" {
    if (!lua.available) return error.SkipZigTest;

    var d: Diagnostic = .{};
    try testing.expectError(
        error.BadTheme,
        read(testing.allocator, "theme.lua", "while true do end", &d),
    );
    try testing.expect(std.mem.indexOf(u8, d.message(), "still running") != null);

    // And it has nothing to run *with*: no libraries are opened at all, so a
    // theme cannot reach the filesystem even by name.
    try testing.expectError(
        error.BadTheme,
        read(testing.allocator, "theme.lua", "return { x = require('os') }", &d),
    );
}

test "a build with no lua says so rather than pretending" {
    if (lua.available) return error.SkipZigTest;
    try testing.expectError(error.NoLua, themed("return {}"));
}
