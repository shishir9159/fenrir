//! One Lua state, sandboxed, with the `fenrir` table in it.
//!
//! Like Neovim, there is one state for all plugins: `init.lua` and every file
//! in `plugins/` share globals and can `require` each other's modules. Unlike
//! Neovim, that state is not the whole of Lua.
//!
//! ## The sandbox
//!
//! A PDF reader is a program people point at files from strangers, and a
//! plugin directory is a place people paste code from strangers. So the state
//! holds only:
//!
//! * `base`, without `dofile` and `loadfile`, and with `load` replaced by one
//!   that refuses bytecode -- Lua does not verify bytecode, and a crafted
//!   chunk can crash the interpreter;
//! * `string`, `table`, `math`, `utf8` and `coroutine`;
//! * `print`, which goes to the reader's message line;
//! * `require`, which reads only `lua/<name>.lua` under the configuration
//!   directory;
//! * `fenrir`, which is the `Host` and nothing else.
//!
//! No `io`, `os`, `package` or `debug`: no files, no processes, no native
//! modules, no reaching into other functions' locals.
//!
//! Two limits keep a script from taking the reader down with it. **Memory**:
//! every byte Lua allocates is counted, and past `memory_limit` an allocation
//! fails, which Lua turns into an ordinary error. **Time**: a count hook runs
//! every few thousand instructions, and a single call into Lua that runs past
//! `step_limit` is stopped with an error -- so `while true do end` in a key
//! binding costs a fraction of a second, and the reader carries on.
//!
//! ## Errors
//!
//! Nothing a script does is fatal to the reader. Every entry into Lua is a
//! protected call with a traceback; a failure is recorded in `messages`, shown
//! on the message line, and the plugin that failed stays loaded as far as it
//! got. See `lua.zig` for the one rule this imposes on the Zig functions Lua
//! calls.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Host = @import("Host.zig");
const keys = @import("../hlidskjalf/keys.zig");
const keyspec = @import("keyspec.zig");
const lua = @import("lua.zig");

const Runtime = @This();

pub const Event = enum {
    /// Every plugin is loaded and the window is open.
    start,
    /// A document was opened. `{path, title, pages}`.
    open,
    /// The focused window's current page changed. The new page, from 1.
    page,
    /// The mode changed. Its name: "normal", "visual", "edit", ...
    mode,
    /// A highlight was added, removed or changed. `{action, id, page, ...}`.
    highlight,
    /// The reader is about to close.
    quit,
};

pub const Payload = union(Event) {
    start,
    open: Host.Document,
    page: u32,
    mode: []const u8,
    highlight: struct { action: []const u8, highlight: Host.Highlight },
    quit,
};

pub const Options = struct {
    /// Bytes every script together may hold. Enough for any plugin a reader
    /// needs, and small enough that a runaway table is an error message
    /// rather than a machine swapping.
    memory_limit: usize = 64 << 20,
    /// Hook ticks one call into Lua may run for; each tick is `hook_interval`
    /// instructions. The default is a few hundred milliseconds of pure Lua on
    /// a current machine: far more than any key binding should take.
    step_limit: u64 = 5_000,
    hook_interval: c_int = 10_000,
};

const ModeSet = packed struct(u8) {
    normal: bool = false,
    visual: bool = false,
    edit: bool = false,
    _: u5 = 0,

    fn has(s: ModeSet, mode: keys.Mode) bool {
        return switch (mode) {
            .normal => s.normal,
            .visual, .visual_line => s.visual,
            .edit => s.edit,
            .note, .command => false,
        };
    }

    fn overlaps(a: ModeSet, b: ModeSet) bool {
        return @as(u8, @bitCast(a)) & @as(u8, @bitCast(b)) != 0;
    }
};

const Keymap = struct {
    modes: ModeSet,
    key: keys.Key,
    /// The Lua function, or `lua.no_ref` when the binding is a command line.
    ref: c_int,
    /// A `:` command line to run instead of a function.
    line: []u8,
    spec: []u8,
    description: []u8,
    live: bool = true,
};

const UserCommand = struct {
    name: []u8,
    ref: c_int,
    description: []u8,
};

const Handler = struct {
    id: u32,
    event: Event,
    ref: c_int,
    live: bool = true,
};

pub const Plugin = struct {
    name: []u8,
    ok: bool,
};

gpa: Allocator,
host: Host,
L: *lua.State,
options: Options,

memory_used: usize = 0,
steps: u64 = 0,
/// How many calls into Lua are on the stack. The step budget is reset only by
/// the outermost, so a key binding that runs a command that fires an event is
/// one budget and not three.
depth: u32 = 0,
/// How deep events are nested inside event handlers. A handler for `page`
/// that turns the page would otherwise recurse until the stack ran out.
emitting: u32 = 0,

keymaps: std.ArrayList(Keymap) = .empty,
commands: std.ArrayList(UserCommand) = .empty,
handlers: std.ArrayList(Handler) = .empty,
next_handler: u32 = 1,

/// Every error a script has raised this session, oldest first, capped. What
/// `:messages` shows.
messages: std.ArrayList([]u8) = .empty,
plugins: std.ArrayList(Plugin) = .empty,

pub const max_messages = 100;
pub const max_event_depth = 4;

pub const Error = error{ NoLua, CannotCreate } || Allocator.Error;

pub fn create(gpa: Allocator, host: Host, options: Options) Error!*Runtime {
    if (!lua.available) return error.NoLua;

    const rt = try gpa.create(Runtime);
    errdefer gpa.destroy(rt);
    rt.* = .{ .gpa = gpa, .host = host, .L = undefined, .options = options };

    rt.L = lua.lua_newstate(allocate, rt) orelse return error.CannotCreate;
    errdefer lua.lua_close(rt.L);

    // Everything below runs Lua code that can fail -- for memory, if nothing
    // else -- so it runs inside a protected call of its own.
    lua.lua_pushcclosure(rt.L, setup, 0);
    if (lua.pcall(rt.L, 0, 0, 0) != lua.ok) return error.CannotCreate;
    lua.lua_sethook(rt.L, hook, lua.mask_count, options.hook_interval);
    return rt;
}

pub fn destroy(rt: *Runtime) void {
    if (!lua.available) return;
    const gpa = rt.gpa;
    lua.lua_close(rt.L);
    for (rt.keymaps.items) |k| {
        gpa.free(k.line);
        gpa.free(k.spec);
        gpa.free(k.description);
    }
    rt.keymaps.deinit(gpa);
    for (rt.commands.items) |c| {
        gpa.free(c.name);
        gpa.free(c.description);
    }
    rt.commands.deinit(gpa);
    rt.handlers.deinit(gpa);
    for (rt.messages.items) |m| gpa.free(m);
    rt.messages.deinit(gpa);
    for (rt.plugins.items) |p| gpa.free(p.name);
    rt.plugins.deinit(gpa);
    gpa.destroy(rt);
}

fn of(L: ?*lua.State) *Runtime {
    var ud: ?*anyopaque = null;
    _ = lua.lua_getallocf(L, &ud);
    return @ptrCast(@alignCast(ud.?));
}

// -- the two limits -----------------------------------------------------------

/// Lua's allocator: libc's, counted against the budget.
///
/// libc's rather than `gpa` because Lua frees by pointer and the size it
/// passes is the size of the *object* it thinks it freed, which after a shrink
/// Lua is entitled to have failed is not the size of the block -- and a Zig
/// allocator needs the exact length back. The budget uses Lua's numbers,
/// which is what it can promise about.
fn allocate(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const rt: *Runtime = @ptrCast(@alignCast(ud.?));
    // For a new block Lua passes the *type* of the object in `osize`, not a
    // size, so it counts as nothing.
    const old = if (ptr == null) 0 else osize;

    if (nsize == 0) {
        std.c.free(ptr);
        rt.memory_used -|= old;
        return null;
    }
    // Growing past the budget fails; shrinking never does, which is a promise
    // Lua relies on.
    if (nsize > old and rt.memory_used - old + nsize > rt.options.memory_limit) return null;

    const moved = std.c.realloc(ptr, nsize) orelse {
        if (nsize <= old) return ptr;
        return null;
    };
    rt.memory_used = rt.memory_used - old + nsize;
    return moved;
}

fn hook(L: ?*lua.State, _: ?*lua.Debug) callconv(.c) void {
    const rt = of(L);
    rt.steps += 1;
    if (rt.steps > rt.options.step_limit) {
        // Reset first, or the error handler -- which is Lua code -- trips the
        // same limit before it can build the message.
        rt.steps = 0;
        lua.raise(L, "galdr: the script ran too long and was stopped");
    }
}

// -- setting up the state -----------------------------------------------------

fn setup(L: ?*lua.State) callconv(.c) c_int {
    const libs = [_]struct { [*:0]const u8, lua.CFunction }{
        .{ "_G", lua.luaopen_base },
        .{ "coroutine", lua.luaopen_coroutine },
        .{ "table", lua.luaopen_table },
        .{ "string", lua.luaopen_string },
        .{ "math", lua.luaopen_math },
        .{ "utf8", lua.luaopen_utf8 },
    };
    for (libs) |lib| {
        lua.luaL_requiref(L, lib[0], lib[1], 1);
        lua.pop(L, 1);
    }

    // The parts of `base` that reach outside the state.
    for ([_][*:0]const u8{ "dofile", "loadfile" }) |name| {
        lua.lua_pushnil(L);
        lua.lua_setglobal(L, name);
    }
    lua.lua_pushcclosure(L, apiLoad, 0);
    lua.lua_setglobal(L, "load");
    lua.lua_pushcclosure(L, apiPrint, 0);
    lua.lua_setglobal(L, "print");
    lua.lua_pushcclosure(L, apiRequire, 0);
    lua.lua_setglobal(L, "require");

    // Modules `require` has loaded, by name.
    lua.newTable(L);
    lua.lua_setfield(L, lua.registry_index, "galdr.loaded");

    lua.newTable(L);
    lua.luaL_setfuncs(L, &api, 0);
    lua.pushString(L, "0.0.1");
    lua.lua_setfield(L, -2, "version");
    lua.pushString(L, "Lua 5.4");
    lua.lua_setfield(L, -2, "lua");

    lua.newTable(L);
    lua.luaL_setfuncs(L, &store_api, 0);
    lua.lua_setfield(L, -2, "store");

    lua.lua_setglobal(L, "fenrir");
    return 0;
}

const api = [_]lua.Reg{
    .{ .name = "notify", .func = apiNotify },
    .{ .name = "exec", .func = apiExec },
    .{ .name = "keymap", .func = apiKeymap },
    .{ .name = "unmap", .func = apiUnmap },
    .{ .name = "command", .func = apiCommand },
    .{ .name = "on", .func = apiOn },
    .{ .name = "off", .func = apiOff },
    .{ .name = "document", .func = apiDocument },
    .{ .name = "page", .func = apiPage },
    .{ .name = "go", .func = apiGo },
    .{ .name = "zoom", .func = apiZoom },
    .{ .name = "mode", .func = apiMode },
    .{ .name = "cursor", .func = apiCursor },
    .{ .name = "selection", .func = apiSelection },
    .{ .name = "highlights", .func = apiHighlights },
    .{ .name = "highlight", .func = apiHighlight },
    .{ .name = "unhighlight", .func = apiUnhighlight },
    .{ .name = null, .func = null },
};

const store_api = [_]lua.Reg{
    .{ .name = "get", .func = apiStoreGet },
    .{ .name = "set", .func = apiStoreSet },
    .{ .name = null, .func = null },
};

// -- calling into Lua ---------------------------------------------------------

/// Builds a traceback for an error, as the message handler of every call.
fn traceback(L: ?*lua.State) callconv(.c) c_int {
    if (lua.lua_tolstring(L, 1, null)) |msg| {
        lua.luaL_traceback(L, L, @ptrCast(msg), 1);
    } else {
        lua.pushString(L, "(an error that is not a string)");
    }
    return 1;
}

/// A call into a function a plugin registered, with what to pass it.
///
/// Everything that allocates -- building the payload table, pushing the
/// argument string -- happens inside `trampoline`, which runs protected. Done
/// before the protected call instead, an allocation that fails at the memory
/// limit would raise with no `pcall` to catch it, and Lua's answer to that
/// is to abort the process.
const Job = struct {
    ref: c_int,
    args: ?[]const u8 = null,
    payload: ?Payload = null,
};

fn trampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *const Job = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    _ = lua.lua_rawgeti(L, lua.registry_index, job.ref);
    var n: c_int = 0;
    if (job.args) |a| {
        lua.pushString(L, a);
        n += 1;
    }
    if (job.payload) |p| {
        pushPayload(L, p);
        n += 1;
    }
    lua.lua_callk(L, n, 0, 0, null);
    return 0;
}

fn invoke(rt: *Runtime, job: Job, what: []const u8) bool {
    // A light C function and a light userdata: neither allocates.
    lua.lua_pushcclosure(rt.L, trampoline, 0);
    lua.lua_pushlightuserdata(rt.L, @constCast(&job));
    return rt.call(1, 0, what);
}

/// Calls the function below `nargs` arguments on the stack, protected.
/// Returns false, having recorded why, when it raised.
fn call(rt: *Runtime, nargs: c_int, nresults: c_int, what: []const u8) bool {
    const L = rt.L;
    const base = lua.lua_gettop(L) - nargs;
    // A light C function: pushing it allocates nothing, so this cannot raise
    // outside the protected call it is setting up.
    lua.lua_pushcclosure(L, traceback, 0);
    lua.lua_rotate(L, base, 1);

    if (rt.depth == 0) rt.steps = 0;
    rt.depth += 1;
    const status = lua.pcall(L, nargs, nresults, base);
    rt.depth -= 1;

    // The handler sits under the results, or under the error message.
    lua.lua_rotate(L, base, -1);
    lua.pop(L, 1);

    if (status == lua.ok) return true;
    const message = lua.toString(L, -1) orelse "(no message)";
    rt.report(what, message);
    lua.pop(L, 1);
    return false;
}

/// Records an error and puts its first line on the message line.
fn report(rt: *Runtime, what: []const u8, message: []const u8) void {
    const full = std.fmt.allocPrint(rt.gpa, "{s}: {s}", .{ what, message }) catch return;
    if (rt.messages.items.len >= max_messages) rt.gpa.free(rt.messages.orderedRemove(0));
    rt.messages.append(rt.gpa, full) catch {
        rt.gpa.free(full);
        return;
    };
    const first = std.mem.sliceTo(full, '\n');
    rt.host.notify(first);
}

/// Runs a chunk of Lua source. `name` is what errors call it.
pub fn runString(rt: *Runtime, name: []const u8, source: []const u8) bool {
    if (!lua.available) return false;
    var chunk: [256]u8 = undefined;
    const chunkname = std.fmt.bufPrintZ(&chunk, "@{s}", .{name}) catch "@?";
    if (lua.luaL_loadbufferx(rt.L, source.ptr, source.len, chunkname, "t") != lua.ok) {
        rt.report(name, lua.toString(rt.L, -1) orelse "cannot load");
        lua.pop(rt.L, 1);
        return false;
    }
    return rt.call(0, 0, name);
}

/// Runs `init.lua`, then every plugin, in order of name.
///
/// A plugin is `plugins/<name>.lua` or `plugins/<name>/init.lua`. Each one
/// that fails is recorded and skipped; the rest still load, because one
/// broken plugin should cost that plugin and not the others.
pub fn loadConfig(rt: *Runtime) void {
    if (!lua.available) return;
    if (rt.host.readFile(rt.gpa, "init.lua")) |source| {
        defer rt.gpa.free(source);
        rt.addPlugin("init.lua", rt.runString("init.lua", source));
    }

    const entries = rt.host.listDir(rt.gpa, "plugins") orelse return;
    defer Host.freeList(rt.gpa, entries);

    for (entries) |entry| {
        var buf: [512]u8 = undefined;
        const path = if (std.mem.endsWith(u8, entry, "/"))
            std.fmt.bufPrint(&buf, "plugins/{s}init.lua", .{entry}) catch continue
        else if (std.mem.endsWith(u8, entry, ".lua"))
            std.fmt.bufPrint(&buf, "plugins/{s}", .{entry}) catch continue
        else
            continue;

        const name = std.mem.trimEnd(u8, if (std.mem.endsWith(u8, entry, ".lua")) entry[0 .. entry.len - 4] else entry, "/");
        const source = rt.host.readFile(rt.gpa, path) orelse continue;
        defer rt.gpa.free(source);
        rt.addPlugin(name, rt.runString(path, source));
    }
}

fn addPlugin(rt: *Runtime, name: []const u8, ok: bool) void {
    const owned = rt.gpa.dupe(u8, name) catch return;
    rt.plugins.append(rt.gpa, .{ .name = owned, .ok = ok }) catch rt.gpa.free(owned);
}

// -- what the reader asks of it -----------------------------------------------

/// The keymap's view of the bindings plugins have made.
pub fn lookup(rt: *Runtime) keys.Lookup {
    return .{ .ptr = rt, .find = findKey };
}

fn findKey(ptr: *anyopaque, mode: keys.Mode, key: keys.Key) ?u32 {
    const rt: *Runtime = @ptrCast(@alignCast(ptr));
    for (rt.keymaps.items, 0..) |k, i| {
        if (!k.live or !k.modes.has(mode)) continue;
        if (std.meta.eql(k.key, key)) return @intCast(i);
    }
    return null;
}

/// Runs the binding the keymap reported.
pub fn runKeymap(rt: *Runtime, id: u32) void {
    if (!lua.available) return;
    if (id >= rt.keymaps.items.len) return;
    const k = rt.keymaps.items[id];
    if (!k.live) return;
    if (k.ref == lua.no_ref) {
        _ = rt.host.exec(k.line);
        return;
    }
    var what: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&what, "key {s}", .{k.spec}) catch "key";
    _ = rt.invoke(.{ .ref = k.ref }, label);
}

/// Runs a command a plugin registered. Null when there is none by that name,
/// so the reader can say "not a command"; otherwise whether it succeeded.
pub fn runCommand(rt: *Runtime, name: []const u8, args: []const u8) ?bool {
    if (!lua.available) return null;
    for (rt.commands.items) |c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        var what: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&what, ":{s}", .{name}) catch "command";
        return rt.invoke(.{ .ref = c.ref, .args = args }, label);
    }
    return null;
}

/// Tells every handler of an event about it.
pub fn emit(rt: *Runtime, payload: Payload) void {
    if (!lua.available) return;
    if (rt.emitting >= max_event_depth) return;
    rt.emitting += 1;
    defer rt.emitting -= 1;

    const event = std.meta.activeTag(payload);
    // By index, and to the length at the start: a handler may add or remove
    // handlers, and those take effect from the next event.
    const count = rt.handlers.items.len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const h = rt.handlers.items[i];
        if (!h.live or h.event != event) continue;
        var what: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&what, "on {s}", .{@tagName(event)}) catch "event";
        _ = rt.invoke(.{ .ref = h.ref, .payload = payload }, label);
    }
}

fn pushPayload(L: ?*lua.State, payload: Payload) void {
    switch (payload) {
        .start, .quit => lua.lua_pushnil(L),
        .page => |p| lua.lua_pushinteger(L, p),
        .mode => |m| lua.pushString(L, m),
        .open => |d| pushDocument(L, d),
        .highlight => |h| {
            pushHighlight(L, h.highlight);
            lua.pushString(L, h.action);
            lua.lua_setfield(L, -2, "action");
        },
    }
}

/// Every command name plugins have registered, for `:commands`.
pub fn commandNames(rt: *const Runtime) []const UserCommand {
    return rt.commands.items;
}

pub fn keymapList(rt: *const Runtime) []const Keymap {
    return rt.keymaps.items;
}

// -- the fenrir table ---------------------------------------------------------

fn apiNotify(L: ?*lua.State) callconv(.c) c_int {
    var len: usize = 0;
    const message = lua.luaL_tolstring(L, 1, &len);
    of(L).host.notify(message[0..len]);
    return 0;
}

fn apiPrint(L: ?*lua.State) callconv(.c) c_int {
    // `print(a, b)` is `a\tb`, as in stock Lua, on the message line.
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const top = lua.lua_gettop(L);
    var i: c_int = 1;
    while (i <= top) : (i += 1) {
        var len: usize = 0;
        const s = lua.luaL_tolstring(L, i, &len);
        if (i > 1 and n < buf.len) {
            buf[n] = '\t';
            n += 1;
        }
        const take = @min(len, buf.len - n);
        @memcpy(buf[n..][0..take], s[0..take]);
        n += take;
        lua.pop(L, 1);
    }
    of(L).host.notify(buf[0..n]);
    return 0;
}

fn apiLoad(L: ?*lua.State) callconv(.c) c_int {
    if (lua.typeOf(L, 1) != .string) lua.raise(L, "galdr: load takes a string of source");
    const source = lua.checkString(L, 1);
    const name_arg = lua.optString(L, 2) orelse "=(load)";

    var chunk: [256]u8 = undefined;
    const name = std.fmt.bufPrintZ(&chunk, "{s}", .{name_arg[0..@min(name_arg.len, 200)]}) catch "=(load)";
    // Always text, whatever mode the caller asked for.
    if (lua.luaL_loadbufferx(L, source.ptr, source.len, name, "t") != lua.ok) {
        // `load` returns nil and the message rather than raising.
        lua.lua_pushnil(L);
        lua.lua_rotate(L, -2, 1);
        return 2;
    }
    // A fourth argument is the chunk's environment, as in stock Lua.
    if (lua.lua_gettop(L) >= 5 and lua.typeOf(L, 4) != .nil) {
        lua.lua_pushvalue(L, 4);
        _ = lua.lua_setupvalue(L, -2, 1);
    }
    return 1;
}

fn apiRequire(L: ?*lua.State) callconv(.c) c_int {
    const name = lua.checkString(L, 1);
    for (name) |c| {
        const fine = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!fine) lua.raise(L, "galdr: require takes a module name like \"foo\" or \"foo.bar\"");
    }
    if (name.len == 0 or name.len > 200) lua.raise(L, "galdr: require takes a module name like \"foo\" or \"foo.bar\"");

    _ = lua.lua_getfield(L, lua.registry_index, "galdr.loaded");
    const loaded = lua.lua_gettop(L);
    lua.lua_pushvalue(L, 1);
    _ = lua.lua_rawget(L, loaded);
    if (lua.typeOf(L, -1) != .nil) return 1;
    lua.pop(L, 1);

    // `foo.bar` is `lua/foo/bar.lua`, or `lua/foo/bar/init.lua`.
    var dotted: [256]u8 = undefined;
    @memcpy(dotted[0..name.len], name);
    std.mem.replaceScalar(u8, dotted[0..name.len], '.', '/');
    const stem = dotted[0..name.len];

    const rt = of(L);
    var first: [512]u8 = undefined;
    var second: [512]u8 = undefined;
    const candidates = [_][]const u8{
        std.fmt.bufPrint(&first, "lua/{s}.lua", .{stem}) catch unreachable,
        std.fmt.bufPrint(&second, "lua/{s}/init.lua", .{stem}) catch unreachable,
    };

    for (candidates) |path| {
        // Read, load, free -- in that order, and before anything that can
        // raise, so the file's bytes are never held across a `longjmp`.
        const source = rt.host.readFile(rt.gpa, path) orelse continue;
        var chunk: [520]u8 = undefined;
        const chunkname = std.fmt.bufPrintZ(&chunk, "@{s}", .{path}) catch unreachable;
        const status = lua.luaL_loadbufferx(L, source.ptr, source.len, chunkname, "t");
        rt.gpa.free(source);
        if (status != lua.ok) _ = lua.lua_error(L);

        // Marked loaded before it runs, so two modules that require each
        // other get `true` rather than recursing forever.
        lua.lua_pushvalue(L, 1);
        lua.lua_pushboolean(L, 1);
        lua.lua_rawset(L, loaded);

        lua.lua_pushvalue(L, 1);
        lua.lua_callk(L, 1, 1, 0, null);
        if (lua.typeOf(L, -1) == .nil) {
            lua.pop(L, 1);
            lua.lua_pushboolean(L, 1);
        }
        lua.lua_pushvalue(L, 1);
        lua.lua_pushvalue(L, -2);
        lua.lua_rawset(L, loaded);
        return 1;
    }

    var msg: [600]u8 = undefined;
    lua.raise(L, std.fmt.bufPrint(&msg, "galdr: module '{s}' not found in lua/ of the configuration directory", .{name}) catch "galdr: module not found");
}

fn apiExec(L: ?*lua.State) callconv(.c) c_int {
    const line = lua.checkString(L, 1);
    lua.lua_pushboolean(L, @intFromBool(of(L).host.exec(line)));
    return 1;
}

/// `fenrir.keymap(modes, key, action, description)`.
///
/// `modes` is `"n"`, `"v"`, `"e"`, a string of several, or a table of them.
/// `action` is a function, or a string that is run as a `:` command line.
fn apiKeymap(L: ?*lua.State) callconv(.c) c_int {
    const modes = checkModes(L, 1);
    const spec = lua.checkString(L, 2);
    const key = keyspec.parse(spec) catch |err| {
        var msg: [256]u8 = undefined;
        lua.raise(L, std.fmt.bufPrint(&msg, "galdr: \"{s}\" is {s}", .{
            spec[0..@min(spec.len, 32)], keyspec.describe(err),
        }) catch "galdr: bad key");
    };
    const kind = lua.typeOf(L, 3);
    if (kind != .function and kind != .string) lua.raise(L, "galdr: a key binding needs a function or a command line");
    const description = lua.optString(L, 4) orelse "";

    // Every argument is checked. From here, Lua calls come before Zig
    // allocations, and a failed allocation undoes what Lua did.
    var ref: c_int = lua.no_ref;
    if (kind == .function) {
        lua.lua_pushvalue(L, 3);
        ref = lua.luaL_ref(L, lua.registry_index);
    }

    const rt = of(L);
    rt.unbind(modes, key);
    const line = if (kind == .string) lua.toString(L, 3).? else "";

    // All or nothing, freed by hand: `errdefer` would not run across the
    // `longjmp` that `outOfMemory` ends in.
    const owned_line = rt.gpa.dupe(u8, line) catch null;
    const owned_spec = rt.gpa.dupe(u8, spec) catch null;
    const owned_desc = rt.gpa.dupe(u8, description) catch null;
    const added = if (owned_line != null and owned_spec != null and owned_desc != null)
        (if (rt.keymaps.append(rt.gpa, .{
            .modes = modes,
            .key = key,
            .ref = ref,
            .line = owned_line.?,
            .spec = owned_spec.?,
            .description = owned_desc.?,
        })) true else |_| false)
    else
        false;
    if (!added) {
        if (owned_line) |s| rt.gpa.free(s);
        if (owned_spec) |s| rt.gpa.free(s);
        if (owned_desc) |s| rt.gpa.free(s);
        return rt.outOfMemory(L, ref);
    }
    return 0;
}

fn outOfMemory(rt: *Runtime, L: ?*lua.State, ref: c_int) c_int {
    _ = rt;
    if (ref != lua.no_ref) lua.luaL_unref(L, lua.registry_index, ref);
    lua.raise(L, "galdr: out of memory");
}

/// Removes a binding for these modes and this key. A binding for more modes
/// than these keeps the others: unmapping `n` from an `nv` binding leaves `v`.
fn unbind(rt: *Runtime, modes: ModeSet, key: keys.Key) void {
    for (rt.keymaps.items) |*k| {
        if (!k.live or !std.meta.eql(k.key, key) or !k.modes.overlaps(modes)) continue;
        const left: ModeSet = @bitCast(@as(u8, @bitCast(k.modes)) & ~@as(u8, @bitCast(modes)));
        if (@as(u8, @bitCast(left)) != 0) {
            k.modes = left;
            continue;
        }
        k.live = false;
        if (k.ref != lua.no_ref) lua.luaL_unref(rt.L, lua.registry_index, k.ref);
        k.ref = lua.no_ref;
    }
}

fn apiUnmap(L: ?*lua.State) callconv(.c) c_int {
    const modes = checkModes(L, 1);
    const spec = lua.checkString(L, 2);
    const key = keyspec.parse(spec) catch lua.raise(L, "galdr: not a key");
    of(L).unbind(modes, key);
    return 0;
}

fn checkModes(L: ?*lua.State, arg: c_int) ModeSet {
    var set: ModeSet = .{};
    switch (lua.typeOf(L, arg)) {
        .string => for (lua.toString(L, arg).?) |c| addMode(L, &set, c),
        .table => {
            const n: lua.Integer = @intCast(lua.lua_rawlen(L, arg));
            var i: lua.Integer = 1;
            while (i <= n) : (i += 1) {
                _ = lua.lua_rawgeti(L, arg, i);
                const s = lua.toString(L, -1) orelse lua.raise(L, "galdr: modes are \"n\", \"v\" and \"e\"");
                for (s) |c| addMode(L, &set, c);
                lua.pop(L, 1);
            }
        },
        else => lua.raise(L, "galdr: modes are \"n\", \"v\" and \"e\", or a table of them"),
    }
    if (@as(u8, @bitCast(set)) == 0) lua.raise(L, "galdr: a binding needs at least one mode");
    return set;
}

fn addMode(L: ?*lua.State, set: *ModeSet, c: u8) void {
    switch (c) {
        'n' => set.normal = true,
        'v', 'x' => set.visual = true,
        'e' => set.edit = true,
        else => lua.raise(L, "galdr: modes are \"n\" (normal), \"v\" (visual) and \"e\" (edit)"),
    }
}

/// `fenrir.command(name, function, description)`: a `:name args` command.
fn apiCommand(L: ?*lua.State) callconv(.c) c_int {
    const name = lua.checkString(L, 1);
    lua.luaL_checktype(L, 2, @intFromEnum(lua.Type.function));
    const description = lua.optString(L, 3) orelse "";

    const valid = name.len > 0 and name.len <= 64 and std.ascii.isAlphabetic(name[0]) and for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break false;
    } else true;
    if (!valid) lua.raise(L, "galdr: a command name is a letter followed by letters, digits, _ or -");

    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.registry_index);

    const rt = of(L);
    for (rt.commands.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        // Redefining a command replaces it, as `:command!` does.
        lua.luaL_unref(L, lua.registry_index, c.ref);
        c.ref = ref;
        return 0;
    }
    const owned = rt.gpa.dupe(u8, name) catch return rt.outOfMemory(L, ref);
    const desc = rt.gpa.dupe(u8, description) catch {
        rt.gpa.free(owned);
        return rt.outOfMemory(L, ref);
    };
    rt.commands.append(rt.gpa, .{ .name = owned, .ref = ref, .description = desc }) catch {
        rt.gpa.free(owned);
        rt.gpa.free(desc);
        return rt.outOfMemory(L, ref);
    };
    return 0;
}

/// `fenrir.on(event, function)`, returning an id for `fenrir.off`.
fn apiOn(L: ?*lua.State) callconv(.c) c_int {
    const name = lua.checkString(L, 1);
    lua.luaL_checktype(L, 2, @intFromEnum(lua.Type.function));
    const event = std.meta.stringToEnum(Event, name) orelse
        lua.raise(L, "galdr: events are start, open, page, mode, highlight and quit");

    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.registry_index);

    const rt = of(L);
    const id = rt.next_handler;
    rt.handlers.append(rt.gpa, .{ .id = id, .event = event, .ref = ref }) catch return rt.outOfMemory(L, ref);
    rt.next_handler += 1;
    lua.lua_pushinteger(L, id);
    return 1;
}

fn apiOff(L: ?*lua.State) callconv(.c) c_int {
    const id = lua.luaL_checkinteger(L, 1);
    const rt = of(L);
    for (rt.handlers.items) |*h| {
        if (h.id != id or !h.live) continue;
        h.live = false;
        lua.luaL_unref(L, lua.registry_index, h.ref);
    }
    return 0;
}

fn pushDocument(L: ?*lua.State, d: Host.Document) void {
    lua.lua_createtable(L, 0, 3);
    lua.pushString(L, d.path);
    lua.lua_setfield(L, -2, "path");
    lua.pushString(L, d.title);
    lua.lua_setfield(L, -2, "title");
    lua.lua_pushinteger(L, d.pages);
    lua.lua_setfield(L, -2, "pages");
}

fn apiDocument(L: ?*lua.State) callconv(.c) c_int {
    const d = of(L).host.document() orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    pushDocument(L, d);
    return 1;
}

fn apiPage(L: ?*lua.State) callconv(.c) c_int {
    if (of(L).host.page()) |p| lua.lua_pushinteger(L, p) else lua.lua_pushnil(L);
    return 1;
}

/// `fenrir.go(page, offset)`: to a page, from 1, and optionally some points
/// down it.
fn apiGo(L: ?*lua.State) callconv(.c) c_int {
    const page = lua.luaL_checkinteger(L, 1);
    const offset = lua.luaL_optnumber(L, 2, 0);
    if (page < 1 or page > std.math.maxInt(u32)) lua.raise(L, "galdr: pages are numbered from 1");
    lua.lua_pushboolean(L, @intFromBool(of(L).host.goTo(@intCast(page), @floatCast(offset))));
    return 1;
}

/// `fenrir.zoom()` is the percentage; `fenrir.zoom(150)` sets it.
fn apiZoom(L: ?*lua.State) callconv(.c) c_int {
    const rt = of(L);
    if (lua.lua_gettop(L) >= 1 and lua.typeOf(L, 1) != .nil) {
        const percent = lua.luaL_checknumber(L, 1);
        if (!(percent > 0) or !std.math.isFinite(percent)) lua.raise(L, "galdr: a zoom is a positive percentage");
        rt.host.setZoom(@floatCast(percent));
    }
    if (rt.host.zoom()) |z| lua.lua_pushnumber(L, z) else lua.lua_pushnil(L);
    return 1;
}

fn apiMode(L: ?*lua.State) callconv(.c) c_int {
    lua.pushString(L, of(L).host.mode());
    return 1;
}

fn pushPosition(L: ?*lua.State, p: Host.Position) void {
    lua.lua_createtable(L, 0, 3);
    lua.lua_pushinteger(L, p.page);
    lua.lua_setfield(L, -2, "page");
    lua.lua_pushinteger(L, p.line);
    lua.lua_setfield(L, -2, "line");
    lua.lua_pushinteger(L, p.column);
    lua.lua_setfield(L, -2, "column");
}

fn apiCursor(L: ?*lua.State) callconv(.c) c_int {
    if (of(L).host.cursor()) |p| pushPosition(L, p) else lua.lua_pushnil(L);
    return 1;
}

fn apiSelection(L: ?*lua.State) callconv(.c) c_int {
    const sel = of(L).host.selection() orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    lua.lua_createtable(L, 0, 2);
    pushPosition(L, sel[0]);
    lua.lua_setfield(L, -2, "from");
    pushPosition(L, sel[1]);
    lua.lua_setfield(L, -2, "to");
    return 1;
}

fn pushHighlight(L: ?*lua.State, h: Host.Highlight) void {
    lua.lua_createtable(L, 0, 8);
    lua.lua_pushinteger(L, @intCast(h.id));
    lua.lua_setfield(L, -2, "id");
    lua.lua_pushinteger(L, h.page);
    lua.lua_setfield(L, -2, "page");
    inline for (.{ "x0", "y0", "x1", "y1" }) |field| {
        lua.lua_pushnumber(L, @field(h, field));
        lua.lua_setfield(L, -2, field);
    }
    lua.pushString(L, h.color);
    lua.lua_setfield(L, -2, "color");
    lua.pushString(L, h.note);
    lua.lua_setfield(L, -2, "note");
}

fn apiHighlights(L: ?*lua.State) callconv(.c) c_int {
    const rt = of(L);
    const n = rt.host.highlightCount();
    lua.lua_createtable(L, @intCast(@min(n, 1 << 20)), 0);
    var i: usize = 0;
    var out: lua.Integer = 1;
    while (i < n) : (i += 1) {
        const h = rt.host.highlightAt(i) orelse continue;
        pushHighlight(L, h);
        lua.lua_rawseti(L, -2, out);
        out += 1;
    }
    return 1;
}

/// `fenrir.highlight{page=, x0=, y0=, x1=, y1=, color=, note=}`, returning
/// the new highlight's id.
fn apiHighlight(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, @intFromEnum(lua.Type.table));
    var h: Host.Highlight = .{ .page = 0, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    _ = lua.lua_getfield(L, 1, "page");
    const page = lua.lua_tointegerx(L, -1, null);
    if (page < 1 or page > std.math.maxInt(u32)) lua.raise(L, "galdr: a highlight needs page, from 1");
    h.page = @intCast(page);
    lua.pop(L, 1);

    inline for (.{ "x0", "y0", "x1", "y1" }) |field| {
        _ = lua.lua_getfield(L, 1, field);
        var isnum: c_int = 0;
        const v = lua.lua_tonumberx(L, -1, &isnum);
        if (isnum == 0 or !std.math.isFinite(v)) lua.raise(L, "galdr: a highlight needs x0, y0, x1 and y1 in points");
        @field(h, field) = @floatCast(v);
        lua.pop(L, 1);
    }

    // The strings stay on the stack until the host has copied them.
    _ = lua.lua_getfield(L, 1, "color");
    h.color = lua.toString(L, -1) orelse "";
    _ = lua.lua_getfield(L, 1, "note");
    h.note = lua.toString(L, -1) orelse "";

    if (of(L).host.addHighlight(h)) |id| lua.lua_pushinteger(L, @intCast(id)) else lua.lua_pushnil(L);
    return 1;
}

fn apiUnhighlight(L: ?*lua.State) callconv(.c) c_int {
    const id = lua.luaL_checkinteger(L, 1);
    const removed = id > 0 and of(L).host.removeHighlight(@intCast(id));
    lua.lua_pushboolean(L, @intFromBool(removed));
    return 1;
}

fn apiStoreGet(L: ?*lua.State) callconv(.c) c_int {
    const key = lua.checkString(L, 1);
    const rt = of(L);
    const value = rt.host.storeGet(rt.gpa, key) orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    // Pushed, then freed. If the push fails for memory the value leaks,
    // which is a few bytes in a session that has already run out; freeing
    // first would push freed memory, which is not.
    lua.pushString(L, value);
    rt.gpa.free(value);
    return 1;
}

fn apiStoreSet(L: ?*lua.State) callconv(.c) c_int {
    const key = lua.checkString(L, 1);
    const value = if (lua.typeOf(L, 2) == .nil or lua.typeOf(L, 2) == .none) null else lua.checkString(L, 2);
    lua.lua_pushboolean(L, @intFromBool(of(L).host.storeSet(key, value)));
    return 1;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// A host made of fields: what a script asked for is written down, and what
/// it reads comes from here.
const FakeHost = struct {
    notes: std.ArrayList([]u8) = .empty,
    execs: std.ArrayList([]u8) = .empty,
    files: []const [2][]const u8 = &.{},
    page_now: u32 = 3,
    zoom_now: f32 = 100,
    highlights: std.ArrayList(Host.Highlight) = .empty,
    stored: ?[]u8 = null,

    fn deinit(f: *FakeHost) void {
        for (f.notes.items) |n| testing.allocator.free(n);
        f.notes.deinit(testing.allocator);
        for (f.execs.items) |n| testing.allocator.free(n);
        f.execs.deinit(testing.allocator);
        f.highlights.deinit(testing.allocator);
        if (f.stored) |s| testing.allocator.free(s);
    }

    fn host(f: *FakeHost) Host {
        return .{ .ptr = f, .vtable = &vtable };
    }

    fn self(ptr: *anyopaque) *FakeHost {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: Host.VTable = .{
        .notify = struct {
            fn f(ptr: *anyopaque, m: []const u8) void {
                self(ptr).notes.append(testing.allocator, testing.allocator.dupe(u8, m) catch return) catch {};
            }
        }.f,
        .exec = struct {
            fn f(ptr: *anyopaque, m: []const u8) bool {
                self(ptr).execs.append(testing.allocator, testing.allocator.dupe(u8, m) catch return false) catch {};
                return true;
            }
        }.f,
        .document = struct {
            fn f(_: *anyopaque) ?Host.Document {
                return .{ .path = "/docs/paper.pdf", .title = "paper.pdf", .pages = 12 };
            }
        }.f,
        .page = struct {
            fn f(ptr: *anyopaque) ?u32 {
                return self(ptr).page_now;
            }
        }.f,
        .goTo = struct {
            fn f(ptr: *anyopaque, p: u32, _: f32) bool {
                self(ptr).page_now = p;
                return true;
            }
        }.f,
        .zoom = struct {
            fn f(ptr: *anyopaque) ?f32 {
                return self(ptr).zoom_now;
            }
        }.f,
        .setZoom = struct {
            fn f(ptr: *anyopaque, z: f32) void {
                self(ptr).zoom_now = z;
            }
        }.f,
        .mode = struct {
            fn f(_: *anyopaque) []const u8 {
                return "normal";
            }
        }.f,
        .cursor = struct {
            fn f(_: *anyopaque) ?Host.Position {
                return .{ .page = 3, .line = 7, .column = 2 };
            }
        }.f,
        .selection = struct {
            fn f(_: *anyopaque) ?[2]Host.Position {
                return null;
            }
        }.f,
        .highlightCount = struct {
            fn f(ptr: *anyopaque) usize {
                return self(ptr).highlights.items.len;
            }
        }.f,
        .highlightAt = struct {
            fn f(ptr: *anyopaque, i: usize) ?Host.Highlight {
                const hs = self(ptr).highlights.items;
                return if (i < hs.len) hs[i] else null;
            }
        }.f,
        .addHighlight = struct {
            fn f(ptr: *anyopaque, h: Host.Highlight) ?u64 {
                const fake = self(ptr);
                var copy = h;
                copy.id = fake.highlights.items.len + 1;
                // Strings are borrowed from Lua for the length of the call;
                // a real host copies them, and this one forgets them.
                copy.color = "";
                copy.note = "";
                fake.highlights.append(testing.allocator, copy) catch return null;
                return copy.id;
            }
        }.f,
        .removeHighlight = struct {
            fn f(ptr: *anyopaque, id: u64) bool {
                const fake = self(ptr);
                for (fake.highlights.items, 0..) |h, i| {
                    if (h.id != id) continue;
                    _ = fake.highlights.orderedRemove(i);
                    return true;
                }
                return false;
            }
        }.f,
        .storeGet = struct {
            fn f(ptr: *anyopaque, gpa: Allocator, _: []const u8) ?[]u8 {
                const s = self(ptr).stored orelse return null;
                return gpa.dupe(u8, s) catch null;
            }
        }.f,
        .storeSet = struct {
            fn f(ptr: *anyopaque, _: []const u8, value: ?[]const u8) bool {
                const fake = self(ptr);
                if (fake.stored) |s| testing.allocator.free(s);
                fake.stored = if (value) |v| testing.allocator.dupe(u8, v) catch null else null;
                return true;
            }
        }.f,
        .readFile = struct {
            fn f(ptr: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
                for (self(ptr).files) |file| {
                    if (std.mem.eql(u8, file[0], path)) return gpa.dupe(u8, file[1]) catch null;
                }
                return null;
            }
        }.f,
        .listDir = struct {
            fn f(ptr: *anyopaque, gpa: Allocator, dir: []const u8) ?[][]u8 {
                var out: std.ArrayList([]u8) = .empty;
                for (self(ptr).files) |file| {
                    if (!std.mem.startsWith(u8, file[0], dir) or file[0].len <= dir.len + 1) continue;
                    const rest = file[0][dir.len + 1 ..];
                    const entry = if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest[0 .. slash + 1] else rest;
                    var seen = false;
                    for (out.items) |e| seen = seen or std.mem.eql(u8, e, entry);
                    if (!seen) out.append(gpa, gpa.dupe(u8, entry) catch return null) catch return null;
                }
                std.mem.sort([]u8, out.items, {}, struct {
                    fn less(_: void, a: []u8, b: []u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.less);
                return out.toOwnedSlice(gpa) catch null;
            }
        }.f,
    };
};

fn start(fake: *FakeHost) !*Runtime {
    return create(testing.allocator, fake.host(), .{});
}

test "the sandbox has the safe half of the standard library and none of the rest" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("check",
        \\assert(io == nil, "io")
        \\assert(os == nil, "os")
        \\assert(package == nil, "package")
        \\assert(debug == nil, "debug")
        \\assert(dofile == nil, "dofile")
        \\assert(loadfile == nil, "loadfile")
        \\assert(string.format("%d", 42) == "42")
        \\assert(math.floor(2.5) == 2)
        \\assert(utf8.len("\u{e9}") == 1)
        \\assert(type(coroutine.wrap) == "function")
        \\assert(fenrir.version ~= nil)
    ));
    try testing.expectEqual(@as(usize, 0), rt.messages.items.len);
}

test "load refuses bytecode, whatever mode is asked for" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("check",
        \\local f = load("return 1 + 1")
        \\assert(f() == 2)
        \\local dumped = string.dump(f)
        \\local g, err = load(dumped, "x", "b")
        \\assert(g == nil and err ~= nil, "bytecode was accepted")
        \\local env = { y = 5 }
        \\assert(load("return y", "=e", "t", env)() == 5, "env")
    ));
}

test "an error is recorded and shown, and the reader carries on" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(!rt.runString("broken.lua", "local x = nil + 1"));
    try testing.expectEqual(@as(usize, 1), rt.messages.items.len);
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "broken.lua") != null);
    // The message line gets the first line, not the traceback.
    try testing.expect(std.mem.indexOfScalar(u8, fake.notes.items[0], '\n') == null);

    // And the state still works.
    try testing.expect(rt.runString("after", "fenrir.notify('still here')"));
    try testing.expectEqualStrings("still here", fake.notes.items[fake.notes.items.len - 1]);

    // A syntax error is the same kind of failure.
    try testing.expect(!rt.runString("syntax.lua", "if then"));
    try testing.expectEqual(@as(usize, 2), rt.messages.items.len);
}

test "a script that never ends is stopped" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try create(testing.allocator, fake.host(), .{ .step_limit = 50 });
    defer rt.destroy();

    try testing.expect(!rt.runString("loop", "while true do end"));
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "too long") != null);
    // The budget is per call, so the next one has all of it again.
    try testing.expect(rt.runString("quick", "local x = 0 for i = 1, 100 do x = x + i end"));
}

test "a script that eats memory is stopped, and the memory comes back" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try create(testing.allocator, fake.host(), .{ .memory_limit = 4 << 20 });
    defer rt.destroy();

    try testing.expect(!rt.runString("hog", "local t = {} for i = 1, 1e8 do t[i] = string.rep('x', 100) .. i end"));
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "memory") != null);

    _ = lua.lua_gc(rt.L, 2); // LUA_GCCOLLECT
    try testing.expect(rt.memory_used < 1 << 20);
    try testing.expect(rt.runString("after", "local s = string.rep('y', 1000)"));
}

test "keymaps: a function, a command line, a replacement, and unmapping one mode" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\fenrir.keymap("n", "g", function() fenrir.notify("pressed g") end, "say so")
        \\fenrir.keymap("nv", "<C-k>", "split")
    ));

    const look = rt.lookup();
    const g = look.find(look.ptr, .normal, .{ .char = 'g' }).?;
    try testing.expect(look.find(look.ptr, .visual, .{ .char = 'g' }) == null);
    rt.runKeymap(g);
    try testing.expectEqualStrings("pressed g", fake.notes.items[fake.notes.items.len - 1]);

    const ck = look.find(look.ptr, .visual_line, .{ .char = 'k', .ctrl = true }).?;
    rt.runKeymap(ck);
    try testing.expectEqualStrings("split", fake.execs.items[0]);

    // Rebinding replaces; unmapping one mode leaves the other.
    try testing.expect(rt.runString("again",
        \\fenrir.keymap("n", "g", function() fenrir.notify("second") end)
        \\fenrir.unmap("n", "<C-k>")
    ));
    rt.runKeymap(look.find(look.ptr, .normal, .{ .char = 'g' }).?);
    try testing.expectEqualStrings("second", fake.notes.items[fake.notes.items.len - 1]);
    try testing.expect(look.find(look.ptr, .normal, .{ .char = 'k', .ctrl = true }) == null);
    try testing.expect(look.find(look.ptr, .visual, .{ .char = 'k', .ctrl = true }) != null);

    // A key Galdr cannot bind is an error in the script, not a silent no-op.
    try testing.expect(!rt.runString("bad", "fenrir.keymap('n', 'gg', function() end)"));
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "sequence") != null);
}

test "commands take their arguments, and unknown ones are left to the reader" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\fenrir.command("Twice", function(args) fenrir.notify(args .. args) end)
    ));
    try testing.expectEqual(@as(?bool, true), rt.runCommand("Twice", "ab"));
    try testing.expectEqualStrings("abab", fake.notes.items[fake.notes.items.len - 1]);
    try testing.expectEqual(@as(?bool, null), rt.runCommand("Nope", ""));

    try testing.expect(!rt.runString("bad", "fenrir.command('1up', function() end)"));
}

test "events reach their handlers, which can be turned off" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\seen = {}
        \\local id = fenrir.on("page", function(p) seen[#seen + 1] = p end)
        \\fenrir.on("open", function(d) opened = d.title .. ":" .. d.pages end)
        \\fenrir.on("highlight", function(h) action = h.action .. h.page end)
        \\off_id = id
    ));
    rt.emit(.{ .page = 4 });
    rt.emit(.{ .open = .{ .path = "/a.pdf", .title = "a.pdf", .pages = 9 } });
    rt.emit(.{ .highlight = .{ .action = "add", .highlight = .{ .page = 2, .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 } } });
    try testing.expect(rt.runString("check",
        \\assert(seen[1] == 4)
        \\assert(opened == "a.pdf:9")
        \\assert(action == "add2")
        \\fenrir.off(off_id)
    ));
    rt.emit(.{ .page = 5 });
    try testing.expect(rt.runString("check2", "assert(#seen == 1, 'handler still ran')"));

    try testing.expect(!rt.runString("bad", "fenrir.on('nonsense', function() end)"));
}

test "a handler that causes its own event does not recurse forever" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    // A host whose goTo emits `page` would loop; the depth limit ends it.
    try testing.expect(rt.runString("init.lua", "count = 0 fenrir.on('page', function() count = count + 1 end)"));
    for (0..3) |_| rt.emit(.{ .page = 1 });
    try testing.expect(rt.runString("check", "assert(count == 3)"));

    rt.emitting = max_event_depth;
    rt.emit(.{ .page = 1 });
    rt.emitting = 0;
    try testing.expect(rt.runString("check", "assert(count == 3)"));
}

test "the reader's state reads out and writes back" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("check",
        \\assert(fenrir.page() == 3)
        \\assert(fenrir.go(7))
        \\assert(fenrir.page() == 7)
        \\assert(fenrir.zoom() == 100)
        \\assert(fenrir.zoom(150) == 150)
        \\assert(fenrir.document().pages == 12)
        \\assert(fenrir.mode() == "normal")
        \\assert(fenrir.cursor().line == 7)
        \\assert(fenrir.selection() == nil)
        \\local id = fenrir.highlight{ page = 2, x0 = 10, y0 = 700, x1 = 90, y1 = 712, color = "#ff0000" }
        \\assert(#fenrir.highlights() == 1)
        \\assert(fenrir.highlights()[1].page == 2)
        \\assert(fenrir.unhighlight(id))
        \\assert(#fenrir.highlights() == 0)
        \\assert(fenrir.store.get("k") == nil)
        \\fenrir.store.set("k", "v")
        \\assert(fenrir.store.get("k") == "v")
        \\assert(fenrir.exec("vsplit"))
    ));
    try testing.expectEqualStrings("vsplit", fake.execs.items[0]);
    try testing.expect(!rt.runString("bad", "fenrir.go(0)"));
    try testing.expect(!rt.runString("bad", "fenrir.highlight{ page = 1 }"));
}

test "init.lua, then plugins by name, and require reads lua/" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{ .files = &.{
        .{ "init.lua", "order = { 'init' }" },
        .{ "plugins/b.lua", "table.insert(order, 'b') local u = require('util.greet') u.hi()" },
        .{ "plugins/a/init.lua", "table.insert(order, 'a')" },
        .{ "plugins/c.lua", "error('c is broken')" },
        .{ "plugins/notes.txt", "not lua" },
        .{ "lua/util/greet.lua", "loads = (loads or 0) + 1 return { hi = function() fenrir.notify('hi') end }" },
    } };
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    rt.loadConfig();
    try testing.expect(rt.runString("check",
        \\assert(table.concat(order, ",") == "init,a,b", table.concat(order, ","))
        \\require("util.greet")
        \\assert(loads == 1, "a module ran twice")
    ));

    try testing.expectEqual(@as(usize, 4), rt.plugins.items.len);
    try testing.expectEqualStrings("a", rt.plugins.items[1].name);
    try testing.expect(rt.plugins.items[2].ok);
    try testing.expect(!rt.plugins.items[3].ok);

    try testing.expect(!rt.runString("bad", "require('../../etc/passwd')"));
    try testing.expect(!rt.runString("bad", "require('missing')"));
}
