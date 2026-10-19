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
//! ## Capabilities
//!
//! There is no global `fenrir`. Every chunk runs with an environment of its
//! own -- an empty table whose metatable reads and writes through to `_G` --
//! and `fenrir` is a field of *that* table. So a plugin that declares a
//! manifest asking for less gets a smaller table, and the enforcement is
//! structural rather than a check per call: **an ungranted function is not
//! refused, it is `nil`**.
//!
//! A manifest is `plugins/<name>/plugin.lua` returning a table, or a
//! `fenrir.manifest{...}` call at the top of a single-file plugin. A plugin
//! that declares nothing keeps everything, which is what it had before there
//! was a manifest to write; declaring one is opting in, and `fenrir health`
//! says which plugins have.
//!
//! One state means one set of globals, so a plugin that asks for little can
//! still be *handed* a function by one that asked for much. That is the price
//! of Neovim's model and it is not worth a state per plugin: the manifest is
//! a statement of what a plugin intends, checked against what it can reach,
//! and it is read by a person before the plugin is installed.
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

/// What a plugin can listen for.
///
/// Written the way Vim writes an autocommand, in the case Lua spells them in,
/// because `@tagName` is then the name a script types and there is no second
/// table mapping one to the other. Half of them name features that do not
/// exist yet: the names are reserved so a plugin written against them keeps
/// working when they arrive, and `Event.fires` is what says which is which.
pub const Event = enum {
    /// Every plugin is loaded and the window is open.
    Start,
    /// A document was opened. `{path, title, pages}`.
    DocOpen,
    /// The focused window's current page changed. `{page}`, from 1.
    PageChanged,
    /// The mode changed. `{mode}`: "normal", "visual", "edit", ...
    ModeChanged,
    /// The selection moved or was cleared. `{from, to}`, or neither.
    SelectionChanged,
    /// A highlight was made, taken away, or recoloured or annotated.
    AnnotationAdd,
    AnnotationRemove,
    AnnotationChange,
    /// One page finished rasterising. `{page}`. Once per page, on the frame
    /// thread -- never per frame, and never on the rasterising thread, which
    /// owns the `Document` and cannot also own a Lua state.
    PageRender,
    /// The reader is about to close.
    Quit,

    /// The interface's colours changed. **Reserved**: the theme landed in
    /// phase three and `Session.useTheme` is the one place that would fire
    /// this, but nothing does yet.
    ThemeChanged,
    /// **Reserved.** fenrir cannot write PDFs at all.
    DocSave,
    /// **Reserved.** Annotations draw from appearance streams; none of them
    /// is interactive.
    FormFieldFocus,
    /// **Reserved.** No redaction exists.
    BeforeRedact,

    /// Whether anything fires it. A handler on one that does not is not an
    /// error -- it is a plugin written against a version that will have it --
    /// but `fenrir health` says so, because a plugin that never runs and a
    /// plugin that never fires look identical from inside.
    pub fn fires(e: Event) bool {
        return switch (e) {
            .ThemeChanged, .DocSave, .FormFieldFocus, .BeforeRedact => false,
            else => true,
        };
    }
};

/// What an event carries, past the two fields every one of them has.
pub const Data = union(enum) {
    none,
    document: Host.Document,
    page: u32,
    /// A mode's name.
    mode: []const u8,
    /// Null for a selection that was cleared, which is a change like any
    /// other and is the reason this is an optional rather than no event.
    selection: ?[2]Host.Position,
    highlight: Host.Highlight,
};

/// One event, as the reader hands it over.
///
/// `path` is what a handler's pattern is matched against, so every event
/// carries one whether or not its data mentions a document. Empty for the
/// ones that are about the reader rather than about a file, which `*` still
/// matches.
pub const Payload = struct {
    event: Event,
    path: []const u8 = "",
    data: Data = .none,
};

/// What a plugin may reach, as a manifest asks for it.
///
/// The names are the manifest's, with a dot, because `document.read` and
/// `document.write` are two halves of one thing and a reader glancing at a
/// manifest should see that they are.
pub const Capability = enum {
    /// Where the reader is and what is under it: the document, the page, the
    /// cursor, the selection, the highlights that exist.
    document_read,
    /// Changing what is on the page: making and removing highlights.
    document_write,
    /// Saying things, binding keys, adding commands, moving the view, and
    /// putting controls in the interface. The broadest of them, because
    /// `fenrir.exec` runs any `:` command the reader has.
    ui,
    /// Reading files under the configuration directory. Reserved: nothing in
    /// the `fenrir` table opens a file today, and `require` is not gated by
    /// it because a plugin with no modules is not a plugin.
    filesystem,
    /// Reserved. Nothing behind it.
    network,
    /// Reserved. Nothing behind it.
    clipboard,
    /// Reserved. fenrir cannot sign a document.
    signature,
    /// Reserved. fenrir cannot redact one either.
    redaction,

    /// What a manifest writes.
    pub fn name(c: Capability) []const u8 {
        return switch (c) {
            .document_read => "document.read",
            .document_write => "document.write",
            .ui => "ui",
            .filesystem => "filesystem",
            .network => "network",
            .clipboard => "clipboard",
            .signature => "signature",
            .redaction => "redaction",
        };
    }

    pub fn parse(text: []const u8) ?Capability {
        inline for (@typeInfo(Capability).@"enum".fields) |f| {
            const c: Capability = @enumFromInt(f.value);
            if (std.mem.eql(u8, text, c.name())) return c;
        }
        return null;
    }

    /// Whether anything is behind it yet. `fenrir health` prints this, so a
    /// reserved name is not mistaken for a granted power.
    pub fn reserved(c: Capability) bool {
        return switch (c) {
            .document_read, .document_write, .ui => false,
            .filesystem, .network, .clipboard, .signature, .redaction => true,
        };
    }
};

/// A set of them, in the enum's order so that a bit is a tag.
pub const Caps = packed struct(u8) {
    document_read: bool = false,
    document_write: bool = false,
    ui: bool = false,
    filesystem: bool = false,
    network: bool = false,
    clipboard: bool = false,
    signature: bool = false,
    redaction: bool = false,

    /// What a plugin that says nothing is trusted with.
    pub const all: Caps = @bitCast(@as(u8, 0xff));

    pub fn has(c: Caps, one: Capability) bool {
        return @as(u8, @bitCast(c)) & bit(one) != 0;
    }

    pub fn add(c: *Caps, one: Capability) void {
        c.* = @bitCast(@as(u8, @bitCast(c.*)) | bit(one));
    }

    fn bit(one: Capability) u8 {
        return @as(u8, 1) << @intFromEnum(one);
    }
};

/// What a plugin said about itself, or the defaults for one that said
/// nothing.
pub const Manifest = struct {
    /// Whether there was a manifest at all. A plugin that declared none is
    /// not a plugin that asked for none.
    declared: bool = false,
    caps: Caps = .all,
    /// Owned. Empty when unsaid.
    about: []u8 = &.{},
    version: []u8 = &.{},
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
    /// How many times a yielded handler may be resumed before the reader
    /// gives up on it. A handler that yields once a frame and is still going
    /// after this has been running for minutes and is not coming back.
    resume_limit: u32 = 100_000,
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

/// One `fenrir.keymap`, as the runtime keeps it.
pub const Keymap = struct {
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

pub const UserCommand = struct {
    name: []u8,
    ref: c_int,
    description: []u8,
    /// A registered icon name, or empty. The palette draws a picture beside
    /// every row and a plugin's rows all looked the same without one.
    icon: []u8,
};

/// One `fenrir.on`, as the runtime keeps it.
pub const Handler = struct {
    id: u32,
    event: Event,
    /// The glob the event's path has to match. Owned; `*` for every path,
    /// which is what a handler that gave none gets.
    pattern: []u8,
    /// What `fenrir.clear` takes away in one call. Owned, empty for none.
    group: []u8,
    ref: c_int,
    live: bool = true,
};

/// Which rail a plugin's button goes on.
pub const Side = enum { left, right };

/// A button a plugin put on a rail.
///
/// The icon is a *name* in the reader's registry and never a path, so a
/// plugin cannot reach the filesystem through a picture and a theme can
/// restyle a plugin's button along with everything else. A name the registry
/// does not have draws as its hollow box, which is a button saying something
/// is missing rather than a button that is missing.
pub const RailButton = struct {
    id: u32,
    side: Side,
    icon: []u8,
    label: []u8,
    /// The Lua function, or `lua.no_ref` when the button is a command line.
    ref: c_int,
    line: []u8,
    /// What `fenrir.clear` takes it away with. Owned, empty for none.
    group: []u8,
    live: bool = true,
};

/// A panel a plugin declared.
///
/// The rows are not kept here: a plugin's list is made of whatever the plugin
/// knows, and a copy this file held would be stale the moment anything
/// changed. `rows` is a function the reader calls when it needs the list --
/// when the panel is opened, and when the plugin says with `fenrir.refresh`
/// that it is different now.
pub const Panel = struct {
    id: u32,
    /// The plugin's own name for it. For the commands that print panels; the
    /// reader addresses one by `id`.
    name: []u8,
    title: []u8,
    icon: []u8,
    /// What the panel says when the list comes back empty.
    empty: []u8,
    rows_ref: c_int,
    /// Called with a row's id when one is chosen, or `lua.no_ref`.
    choose_ref: c_int,
    group: []u8,
    live: bool = true,
};

/// One row of a plugin's panel, as `panelRows` leaves it.
///
/// The same five things `panels.Row` draws, in the vocabulary a plugin writes
/// them in: a colour is `#rrggbb` here and a `Color` there, because Galdr
/// does not import Gelgja and a plugin should not have to write three floats.
/// The slices point into `rows_arena` and are good until the next build.
pub const PanelRow = struct {
    label: []const u8 = "",
    detail: []const u8 = "",
    icon: []const u8 = "",
    color: []const u8 = "",
    page: u32 = 0,
    depth: u8 = 0,
    id: u64 = 0,
};

/// A setting a plugin declared, so that the settings page can list it.
///
/// A plugin's value has always lived in `fenrir.store`, which is a key and
/// some bytes and no way for a person to find out that either exists. This is
/// the other half: the same bytes, with a sentence saying what they are for
/// and the values they may take, so that the page can draw a row for it and
/// the plugin can go on reading it with `fenrir.store.get`.
pub const Setting = struct {
    /// The store key. Owned.
    key: []u8,
    about: []u8,
    /// The values it cycles through on a click, each owned. Empty for a row
    /// that is typed into instead.
    choices: std.ArrayList([]const u8) = .empty,
    /// What happens when it is not set, in words.
    unset: []u8,
    group: []u8,
    live: bool = true,
};

/// A handler that yielded, waiting for the host to resume it.
const Pending = struct {
    /// The coroutine, referenced in the registry so that it is not collected
    /// between one resumption and the next.
    ref: c_int,
    thread: *lua.State,
    id: u32,
    event: Event,
    resumes: u32 = 0,
};

pub const Plugin = struct {
    name: []u8,
    /// Whether its chunk ran to the end. Set after it has, so a plugin that
    /// is still loading -- which is when a manifest is declared -- is already
    /// in the list for `fenrir.manifest` to find.
    ok: bool = false,
    manifest: Manifest = .{},
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
/// The handlers that are part way through, oldest first. See `pump`.
pending: std.ArrayList(Pending) = .empty,

/// What plugins have put in the interface, and a number that changes when
/// any of it does.
///
/// The reader reads these back rather than being pushed them, which is what
/// `lookup` and `commandNames` already do for keys and commands -- the
/// strings live here and the reader borrows them, so nothing has to be
/// copied into a window and nothing has a second owner. `revision` is what
/// lets the reader do that once per change instead of once per frame.
rails: std.ArrayList(RailButton) = .empty,
settings: std.ArrayList(Setting) = .empty,
panels: std.ArrayList(Panel) = .empty,
revision: u32 = 0,
next_contribution: u32 = 1,

/// The last list of rows a panel gave back, and the bytes it points into.
///
/// One buffer for whichever panel was asked last, because one panel is open
/// at a time -- and reset rather than freed, so a list rebuilt when a plugin
/// says it changed costs no allocator traffic after the first time.
rows: std.ArrayList(PanelRow) = .empty,
rows_arena: std.heap.ArenaAllocator,

/// Every error a script has raised this session, oldest first, capped. What
/// `:messages` shows.
messages: std.ArrayList([]u8) = .empty,
plugins: std.ArrayList(Plugin) = .empty,

/// The environment `runString` and `:lua` use: everything granted, and the
/// one that outlives any particular plugin.
console_env: c_int = lua.no_ref,
/// The environment of the chunk running now. What `require` gives a module,
/// and what `fenrir.manifest` narrows.
env_ref: c_int = lua.no_ref,
/// Which of `plugins` is being loaded, for `fenrir.manifest` to write on.
loading: ?usize = null,

pub const max_messages = 100;
pub const max_event_depth = 4;

pub const Error = error{ NoLua, CannotCreate } || Allocator.Error;

pub fn create(gpa: Allocator, host: Host, options: Options) Error!*Runtime {
    if (!lua.available) return error.NoLua;

    const rt = try gpa.create(Runtime);
    errdefer gpa.destroy(rt);
    rt.* = .{
        .gpa = gpa,
        .host = host,
        .L = undefined,
        .options = options,
        .rows_arena = .init(gpa),
    };

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
        gpa.free(c.icon);
    }
    rt.commands.deinit(gpa);
    for (rt.handlers.items) |h| {
        gpa.free(h.pattern);
        gpa.free(h.group);
    }
    rt.handlers.deinit(gpa);
    rt.pending.deinit(gpa);
    for (rt.rails.items) |b| {
        gpa.free(b.icon);
        gpa.free(b.label);
        gpa.free(b.line);
        gpa.free(b.group);
    }
    rt.rails.deinit(gpa);
    for (rt.settings.items) |*s| freeSetting(gpa, s);
    rt.settings.deinit(gpa);
    for (rt.panels.items) |p| {
        gpa.free(p.name);
        gpa.free(p.title);
        gpa.free(p.icon);
        gpa.free(p.empty);
        gpa.free(p.group);
    }
    rt.panels.deinit(gpa);
    rt.rows.deinit(gpa);
    rt.rows_arena.deinit();
    for (rt.messages.items) |m| gpa.free(m);
    rt.messages.deinit(gpa);
    for (rt.plugins.items) |p| {
        gpa.free(p.name);
        gpa.free(p.manifest.about);
        gpa.free(p.manifest.version);
    }
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

    const rt = of(L);
    rt.console_env = newEnv(L, .all);
    rt.env_ref = rt.console_env;
    return 0;
}

/// One entry of the `fenrir` table: what Lua calls it, what a manifest has to
/// ask for before it is there at all, and the two lines of prose a person
/// needs to use it.
///
/// The prose is here rather than in a manual because a manual is a second
/// copy: this table is what builds the table Lua sees, so a function added
/// without a sentence is a compile error and a function whose arguments
/// changed is a diff in the line that documents it. `fenrir plugins --api`
/// prints it, which makes the whole reference a thing the binary knows rather
/// than a file somebody remembers to update.
pub const Entry = struct {
    name: [:0]const u8,
    /// Null for the globals, which are set up by hand rather than from here.
    func: ?lua.CFunction = null,
    /// What a manifest has to ask for before this is in the table at all.
    /// Null for the ones every plugin has, which are the ones that can do
    /// nothing on their own: declaring itself, listening, and its own store.
    cap: ?Capability = null,
    /// The arguments as a person writes them, braces and all.
    args: []const u8 = "",
    /// What comes back, or empty for nothing.
    returns: []const u8 = "",
    about: []const u8,
};

pub const api = [_]Entry{
    .{
        .name = "manifest",
        .func = apiManifest,
        .args = "{ about =, version =, capabilities = {...} }",
        .about = "declares what a plugin is, and narrows its fenrir table to what it asks for",
    },
    .{
        .name = "on",
        .func = apiOn,
        .args = "(event, pattern, fn, group)",
        .returns = "id",
        .about = "runs fn on a coroutine when event happens to a path matching pattern",
    },
    .{ .name = "off", .func = apiOff, .args = "(id)", .about = "stops one handler, by the id fenrir.on gave back" },
    .{
        .name = "clear",
        .func = apiClear,
        .args = "(group)",
        .returns = "n",
        .about = "stops every handler and removes every contribution in a group",
    },

    .{ .name = "notify", .func = apiNotify, .cap = .ui, .args = "(message)", .about = "says a line where the reader says things" },
    .{ .name = "exec", .func = apiExec, .cap = .ui, .args = "(line)", .returns = "ok", .about = "runs a : command line" },
    .{
        .name = "keymap",
        .func = apiKeymap,
        .cap = .ui,
        .args = "(modes, key, action, description)",
        .about = "binds a key in normal, visual or edit mode; action is a function or a : line",
    },
    .{ .name = "unmap", .func = apiUnmap, .cap = .ui, .args = "(modes, key)", .about = "takes a binding away" },
    .{
        .name = "command",
        .func = apiCommand,
        .cap = .ui,
        .args = "(name, fn, description, icon)",
        .about = "adds a :name args command, which the palette then lists and ranks",
    },
    .{ .name = "go", .func = apiGo, .cap = .ui, .args = "(page, offset)", .returns = "ok", .about = "scrolls the focused window to a page, numbered from 1" },
    .{ .name = "zoom", .func = apiZoom, .cap = .ui, .args = "(percent)", .returns = "percent", .about = "reads the zoom, or sets it" },
    .{ .name = "mode", .func = apiMode, .cap = .ui, .returns = "name", .about = "which mode the keymap is in" },
    .{
        .name = "rail",
        .func = apiRail,
        .cap = .ui,
        .args = "{ side =, icon =, label =, action =, group = }",
        .returns = "id",
        .about = "puts a button on a rail; the icon is a registry name, never a path",
    },
    .{ .name = "unrail", .func = apiUnrail, .cap = .ui, .args = "(id)", .about = "takes a rail button away, by the id fenrir.rail gave back" },
    .{
        .name = "setting",
        .func = apiSetting,
        .cap = .ui,
        .args = "{ key =, about =, choices = {...}, unset =, group = }",
        .about = "lists one of this plugin's store keys on the settings page",
    },
    .{
        .name = "panel",
        .func = apiPanel,
        .cap = .ui,
        .args = "{ id =, title =, icon =, empty =, rows =, choose =, group = }",
        .returns = "id",
        .about = "declares a panel: a latch on the rail, and a rows function that builds its list",
    },
    .{ .name = "refresh", .func = apiRefresh, .cap = .ui, .about = "the lists this plugin declared are out of date" },

    .{ .name = "document", .func = apiDocument, .cap = .document_read, .returns = "{ path, title, pages }", .about = "the document in the focused window, or nil" },
    .{ .name = "page", .func = apiPage, .cap = .document_read, .returns = "n", .about = "the page it is showing, from 1" },
    .{ .name = "cursor", .func = apiCursor, .cap = .document_read, .returns = "{ page, line, column }", .about = "where the caret is, or nil" },
    .{ .name = "selection", .func = apiSelection, .cap = .document_read, .returns = "{ from, to }", .about = "what is selected, either way it was made, or nil" },
    .{ .name = "highlights", .func = apiHighlights, .cap = .document_read, .returns = "list", .about = "every highlight in the focused document" },

    .{
        .name = "highlight",
        .func = apiHighlight,
        .cap = .document_write,
        .args = "{ page =, x0 =, y0 =, x1 =, y1 =, color =, note = }",
        .returns = "id",
        .about = "makes one, in PDF points, so it survives zoom and reopening",
    },
    .{ .name = "unhighlight", .func = apiUnhighlight, .cap = .document_write, .args = "(id)", .returns = "ok", .about = "removes one, by the id fenrir.highlight gave back" },
};

/// `fenrir.store`, which every plugin has: its own key space in the library,
/// and the place a declared setting's value lives.
pub const store = [_]Entry{
    .{ .name = "get", .func = apiStoreGet, .args = "(key)", .returns = "value", .about = "a value this plugin kept, or nil" },
    .{ .name = "set", .func = apiStoreSet, .args = "(key, value)", .returns = "ok", .about = "keeps one, or with nil removes it" },
};

/// What the sandbox leaves in the globals that is not stock Lua's, and the
/// two fields of the table that are not functions. Listed for the same
/// reason as the rest: a person writing a plugin needs to know what `require`
/// can reach as much as what `fenrir.go` does.
pub const globals = [_]Entry{
    .{ .name = "print", .args = "(...)", .about = "stock print, onto the reader's message line" },
    .{ .name = "require", .args = "(name)", .returns = "module", .about = "loads lua/<name>.lua under the configuration directory, and nothing else" },
    .{ .name = "load", .args = "(source, name, mode, env)", .returns = "fn", .about = "stock load, refusing bytecode whatever mode is asked for" },
    .{ .name = "fenrir.version", .about = "this reader's plugin API version" },
    .{ .name = "fenrir.lua", .about = "the Lua the sandbox is built on" },
};

/// The `fenrir` table a plugin with these capabilities sees.
///
/// The whole of the enforcement. A function that was not asked for is not in
/// the table, so calling it is the error Lua already has a message for --
/// "attempt to call a nil value" -- rather than a refusal this file would
/// have to invent, and a plugin can ask `if fenrir.highlight then` without
/// anything else being added for it to ask with.
fn pushFenrir(L: ?*lua.State, caps: Caps) void {
    lua.lua_createtable(L, 0, api.len + 3);
    for (api) |entry| {
        if (entry.cap) |c| {
            if (!caps.has(c)) continue;
        }
        lua.lua_pushcclosure(L, entry.func.?, 0);
        lua.lua_setfield(L, -2, entry.name.ptr);
    }
    lua.pushString(L, "0.0.1");
    lua.lua_setfield(L, -2, "version");
    lua.pushString(L, "Lua 5.4");
    lua.lua_setfield(L, -2, "lua");

    // A plugin's own values, always: the key space is the plugin's and
    // nothing else can be reached through it.
    lua.lua_createtable(L, 0, store.len);
    for (store) |entry| {
        lua.lua_pushcclosure(L, entry.func.?, 0);
        lua.lua_setfield(L, -2, entry.name.ptr);
    }
    lua.lua_setfield(L, -2, "store");
}

/// An environment for one chunk: `fenrir`, and `_G` behind it.
///
/// Reads fall through to the globals and so do writes, so `x = 1` in a plugin
/// is still seen by the next one -- which is the shared state Neovim's model
/// promises. Only `fenrir` is the chunk's own, which is the only thing that
/// differs between two plugins. Returns the registry reference.
fn newEnv(L: ?*lua.State, caps: Caps) c_int {
    lua.newTable(L);
    pushFenrir(L, caps);
    lua.lua_setfield(L, -2, "fenrir");

    lua.newTable(L);
    _ = lua.lua_getglobal(L, "_G");
    lua.lua_pushvalue(L, -1);
    lua.lua_setfield(L, -3, "__index");
    lua.lua_setfield(L, -2, "__newindex");
    _ = lua.lua_setmetatable(L, -2);
    return lua.luaL_ref(L, lua.registry_index);
}

const EnvJob = struct {
    caps: Caps,
    ref: c_int = lua.no_ref,
};

fn envTrampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *EnvJob = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    job.ref = newEnv(L, job.caps);
    return 0;
}

/// An environment, built inside a protected call because building one
/// allocates. `lua.no_ref` when there was no memory for it.
fn makeEnv(rt: *Runtime, caps: Caps) c_int {
    var job: EnvJob = .{ .caps = caps };
    lua.lua_pushcclosure(rt.L, envTrampoline, 0);
    lua.lua_pushlightuserdata(rt.L, &job);
    if (!rt.call(1, 0, "galdr")) return lua.no_ref;
    return job.ref;
}

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
};

fn trampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *const Job = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    _ = lua.lua_rawgeti(L, lua.registry_index, job.ref);
    var n: c_int = 0;
    if (job.args) |a| {
        lua.pushString(L, a);
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

/// Runs a chunk of Lua source in an environment. `name` is what errors call
/// it.
fn runChunk(rt: *Runtime, name: []const u8, source: []const u8, env: c_int) bool {
    var chunk: [256]u8 = undefined;
    const chunkname = std.fmt.bufPrintZ(&chunk, "@{s}", .{name}) catch "@?";
    if (lua.luaL_loadbufferx(rt.L, source.ptr, source.len, chunkname, "t") != lua.ok) {
        rt.report(name, lua.toString(rt.L, -1) orelse "cannot load");
        lua.pop(rt.L, 1);
        return false;
    }
    // Upvalue one of a main chunk is `_ENV`, which is where every global it
    // reads goes through -- so this is the whole of how a plugin gets its
    // own `fenrir` without there being a global one.
    _ = lua.lua_rawgeti(rt.L, lua.registry_index, env);
    _ = lua.lua_setupvalue(rt.L, -2, 1);

    const saved = rt.env_ref;
    rt.env_ref = env;
    defer rt.env_ref = saved;
    return rt.call(0, 0, name);
}

/// Runs a chunk with everything granted: `:lua`, and the tests.
pub fn runString(rt: *Runtime, name: []const u8, source: []const u8) bool {
    if (!lua.available) return false;
    return rt.runChunk(name, source, rt.console_env);
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
        rt.loadOne("init.lua", "init.lua", source, null);
    }

    const entries = rt.host.listDir(rt.gpa, "plugins") orelse return;
    defer Host.freeList(rt.gpa, entries);

    for (entries) |entry| {
        const folder = std.mem.endsWith(u8, entry, "/");
        var buf: [512]u8 = undefined;
        const path = if (folder)
            std.fmt.bufPrint(&buf, "plugins/{s}init.lua", .{entry}) catch continue
        else if (std.mem.endsWith(u8, entry, ".lua"))
            std.fmt.bufPrint(&buf, "plugins/{s}", .{entry}) catch continue
        else
            continue;

        // A folder may carry its manifest beside its code. A single file has
        // nowhere to put one, which is what `fenrir.manifest` is for.
        var manifest_buf: [512]u8 = undefined;
        const manifest = if (folder)
            std.fmt.bufPrint(&manifest_buf, "plugins/{s}plugin.lua", .{entry}) catch null
        else
            null;

        const name = std.mem.trimEnd(u8, if (std.mem.endsWith(u8, entry, ".lua")) entry[0 .. entry.len - 4] else entry, "/");
        const source = rt.host.readFile(rt.gpa, path) orelse continue;
        defer rt.gpa.free(source);
        rt.loadOne(name, path, source, manifest);
    }
}

/// One plugin: its entry, its environment, its manifest and its chunk.
///
/// The entry goes in before the chunk runs, because `fenrir.manifest` writes
/// on it while the chunk is running.
fn loadOne(rt: *Runtime, name: []const u8, path: []const u8, source: []const u8, manifest: ?[]const u8) void {
    const owned = rt.gpa.dupe(u8, name) catch return;
    rt.plugins.append(rt.gpa, .{ .name = owned }) catch {
        rt.gpa.free(owned);
        return;
    };
    const at = rt.plugins.items.len - 1;

    const env = rt.makeEnv(.all);
    if (env == lua.no_ref) return;
    // The registry's hold, not the table's life: every closure the plugin
    // makes keeps `_ENV` as an upvalue, so the environment lives exactly as
    // long as the plugin's functions do.
    defer lua.luaL_unref(rt.L, lua.registry_index, env);

    rt.loading = at;
    rt.env_ref = env;
    defer {
        rt.loading = null;
        rt.env_ref = rt.console_env;
    }

    if (manifest) |rel| {
        if (rt.host.readFile(rt.gpa, rel)) |text| {
            defer rt.gpa.free(text);
            // A manifest that does not parse is a plugin that does not load:
            // it asked for something and the answer cannot be guessed.
            if (!rt.runManifest(rel, text)) return;
        }
    }
    rt.plugins.items[at].ok = rt.runChunk(path, source, env);
}

const ManifestJob = struct {
    name: []const u8,
    source: []const u8,
};

/// `plugins/<name>/plugin.lua`: a chunk that returns a table and nothing
/// else.
///
/// It runs with an empty environment -- no `fenrir`, no `string`, no `_G` --
/// because a manifest is data. A file that wants to compute what it asks for
/// is a file asking for the answer not to be readable.
fn manifestTrampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *const ManifestJob = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    var chunk: [512]u8 = undefined;
    const chunkname = std.fmt.bufPrintZ(&chunk, "@{s}", .{job.name}) catch "@plugin.lua";
    if (lua.luaL_loadbufferx(L, job.source.ptr, job.source.len, chunkname, "t") != lua.ok) {
        _ = lua.lua_error(L);
    }
    lua.newTable(L);
    _ = lua.lua_setupvalue(L, -2, 1);
    lua.lua_callk(L, 0, 1, 0, null);
    if (lua.typeOf(L, -1) != .table) lua.raise(L, "galdr: a plugin.lua returns a table");
    applyManifest(L, lua.lua_gettop(L));
    return 0;
}

fn runManifest(rt: *Runtime, name: []const u8, source: []const u8) bool {
    var job: ManifestJob = .{ .name = name, .source = source };
    lua.lua_pushcclosure(rt.L, manifestTrampoline, 0);
    lua.lua_pushlightuserdata(rt.L, &job);
    return rt.call(1, 0, name);
}

const bad_capability = "galdr: capabilities are a list of names like \"document.read\"";

/// Reads a manifest table and narrows the environment to what it asks for.
fn applyManifest(L: ?*lua.State, index: c_int) void {
    const rt = of(L);
    const at = rt.loading orelse lua.raise(L, "galdr: a manifest belongs at the top of a plugin");

    var caps: Caps = .{};
    _ = lua.lua_getfield(L, index, "capabilities");
    switch (lua.typeOf(L, -1)) {
        // Asking for nothing is asking for nothing. The way to keep
        // everything is to write no manifest at all.
        .nil => {},
        .table => {
            const n: lua.Integer = @intCast(lua.lua_rawlen(L, -1));
            var i: lua.Integer = 1;
            while (i <= n) : (i += 1) {
                _ = lua.lua_rawgeti(L, -1, i);
                const text = lua.toString(L, -1) orelse lua.raise(L, bad_capability);
                caps.add(Capability.parse(text) orelse {
                    var msg: [160]u8 = undefined;
                    lua.raise(L, std.fmt.bufPrint(&msg, "galdr: \"{s}\" is not a capability", .{
                        text[0..@min(text.len, 40)],
                    }) catch bad_capability);
                });
                lua.pop(L, 1);
            }
        },
        else => lua.raise(L, bad_capability),
    }
    lua.pop(L, 1);

    _ = lua.lua_getfield(L, index, "about");
    const about = lua.toString(L, -1) orelse "";
    _ = lua.lua_getfield(L, index, "version");
    const version = lua.toString(L, -1) orelse "";

    // Written down before the table is rebuilt: the plugin entry owns these
    // bytes, so a raise from the rebuild below frees them at `destroy` rather
    // than losing them.
    const p = &rt.plugins.items[at];
    rt.gpa.free(p.manifest.about);
    rt.gpa.free(p.manifest.version);
    p.manifest = .{
        .declared = true,
        .caps = caps,
        .about = rt.gpa.dupe(u8, about) catch &.{},
        .version = rt.gpa.dupe(u8, version) catch &.{},
    };
    lua.pop(L, 2);

    _ = lua.lua_rawgeti(L, lua.registry_index, rt.env_ref);
    pushFenrir(L, caps);
    lua.lua_setfield(L, -2, "fenrir");
    lua.pop(L, 1);
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

// -- the event bus ------------------------------------------------------------

/// Tells every handler of an event about it.
///
/// Each one starts on a coroutine of its own, resumed once here and then by
/// `pump` for as long as it keeps yielding. That is what "async by default"
/// can mean in a reader: a handler that has more to do than a frame has time
/// for yields and is picked up next frame, instead of being killed at the
/// step limit or holding the window still until it is done.
pub fn emit(rt: *Runtime, payload: Payload) void {
    if (!lua.available) return;
    if (rt.emitting >= max_event_depth) return;
    rt.emitting += 1;
    defer rt.emitting -= 1;

    // By index, and to the length at the start: a handler may add or remove
    // handlers, and those take effect from the next event.
    const count = rt.handlers.items.len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const h = rt.handlers.items[i];
        if (!h.live or h.event != payload.event) continue;
        if (!matches(h.pattern, payload.path)) continue;
        rt.spawn(h.id, h.ref, payload);
    }
}

/// How many handlers are part way through. What the reader asks to know
/// whether `pump` has anything to do, and what `fenrir health` prints.
pub fn waiting(rt: *const Runtime) usize {
    return rt.pending.items.len;
}

/// Resumes every handler that yielded, once each.
///
/// Called once a frame by the reader. Once each rather than to completion:
/// a handler that yields is asking for the frame back, and resuming it in a
/// loop until it finished would be refusing to give it.
pub fn pump(rt: *Runtime) void {
    if (!lua.available) return;
    var i: usize = 0;
    while (i < rt.pending.items.len) {
        // Re-read every time: a resumed handler can emit, and an emit can
        // append here and move the array out from under a pointer.
        const p = rt.pending.items[i];
        if (p.resumes >= rt.options.resume_limit) {
            var what: [80]u8 = undefined;
            rt.report(
                std.fmt.bufPrint(&what, "on {s}", .{@tagName(p.event)}) catch "event",
                "the handler yielded too many times and was dropped",
            );
            rt.finish(i);
            continue;
        }
        rt.pending.items[i].resumes += 1;
        if (rt.step(p.thread, 0, p.event) == lua.yield) {
            i += 1;
            continue;
        }
        rt.finish(i);
    }
}

/// Drops the pending handler at `index`, letting the coroutine be collected.
fn finish(rt: *Runtime, index: usize) void {
    const p = rt.pending.items[index];
    lua.luaL_unref(rt.L, lua.registry_index, p.ref);
    _ = rt.pending.orderedRemove(index);
}

const SpawnJob = struct {
    ref: c_int,
    payload: Payload,
    thread: ?*lua.State = null,
    thread_ref: c_int = lua.no_ref,
};

/// Makes the coroutine and puts the handler and its table on it.
///
/// Everything that allocates happens here, inside a protected call, for the
/// reason `trampoline` gives: at the memory limit an allocation that failed
/// outside one would raise with no `pcall` to catch it, and Lua's answer to
/// that is to abort the process. The table is built on the main state and
/// moved across, because a raise on a coroutine nobody has resumed yet is
/// exactly that unprotected case.
fn spawnTrampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *SpawnJob = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    const rt = of(L);

    const co = lua.lua_newthread(L) orelse lua.raise(L, "galdr: no memory for a handler");
    // Hooks are per thread in Lua 5.4 and a new one inherits none, so the
    // step limit has to be put on every coroutine by hand -- otherwise a
    // handler is the one place in the sandbox where `while true do end` runs
    // forever.
    lua.lua_sethook(co, hook, lua.mask_count, rt.options.hook_interval);

    _ = lua.lua_rawgeti(L, lua.registry_index, job.ref);
    pushPayload(L, job.payload);
    if (lua.lua_checkstack(co, 2) == 0) lua.raise(L, "galdr: no stack for a handler");
    lua.lua_xmove(L, co, 2);

    job.thread = co;
    job.thread_ref = lua.luaL_ref(L, lua.registry_index);
    return 0;
}

fn spawn(rt: *Runtime, id: u32, ref: c_int, payload: Payload) void {
    var job: SpawnJob = .{ .ref = ref, .payload = payload };
    lua.lua_pushcclosure(rt.L, spawnTrampoline, 0);
    lua.lua_pushlightuserdata(rt.L, &job);

    var what: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&what, "on {s}", .{@tagName(payload.event)}) catch "event";
    if (!rt.call(1, 0, label)) return;
    const co = job.thread orelse return;

    // One argument: the table. The function itself sits under it on the
    // coroutine's stack and is not counted, which is what starting a
    // coroutine means as against calling a function.
    if (rt.step(co, 1, payload.event) != lua.yield) {
        lua.luaL_unref(rt.L, lua.registry_index, job.thread_ref);
        return;
    }
    rt.pending.append(rt.gpa, .{
        .ref = job.thread_ref,
        .thread = co,
        .id = id,
        .event = payload.event,
    }) catch lua.luaL_unref(rt.L, lua.registry_index, job.thread_ref);
}

/// One resumption of a coroutine, with the step budget it is allowed.
///
/// The budget is per resumption rather than per handler, which is the whole
/// of what a coroutine buys: a handler with a million lines of work yields,
/// gets a fresh budget next frame, and finishes -- where the same work in a
/// plain call is stopped as a runaway.
fn step(rt: *Runtime, co: *lua.State, nargs: c_int, event: Event) c_int {
    rt.steps = 0;
    var results: c_int = 0;
    const status = lua.lua_resume(co, rt.L, nargs, &results);
    if (status == lua.ok or status == lua.yield) {
        lua.lua_settop(co, 0);
        return status;
    }

    var what: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&what, "on {s}", .{@tagName(event)}) catch "event";
    // The traceback is of the coroutine's stack and is built on the main
    // one, because the coroutine is in an error state and pushing to it is
    // not a thing to be doing.
    const message = lua.toString(co, -1) orelse "(no message)";
    lua.pushString(rt.L, message);
    lua.luaL_traceback(rt.L, co, @ptrCast(lua.lua_tolstring(rt.L, -1, null)), 0);
    rt.report(label, lua.toString(rt.L, -1) orelse message);
    lua.pop(rt.L, 2);
    lua.lua_settop(co, 0);
    return status;
}

/// The one table a handler is given.
///
/// Every event is the same shape -- `event` and `path`, then whatever that
/// event is about -- so a function registered for three of them can tell
/// which fired without three signatures to remember.
fn pushPayload(L: ?*lua.State, payload: Payload) void {
    lua.lua_createtable(L, 0, 8);
    lua.pushString(L, @tagName(payload.event));
    lua.lua_setfield(L, -2, "event");
    lua.pushString(L, payload.path);
    lua.lua_setfield(L, -2, "path");

    switch (payload.data) {
        .none => {},
        .page => |p| {
            lua.lua_pushinteger(L, p);
            lua.lua_setfield(L, -2, "page");
        },
        .mode => |m| {
            lua.pushString(L, m);
            lua.lua_setfield(L, -2, "mode");
        },
        .document => |d| {
            lua.pushString(L, d.title);
            lua.lua_setfield(L, -2, "title");
            lua.lua_pushinteger(L, d.pages);
            lua.lua_setfield(L, -2, "pages");
        },
        .selection => |maybe| if (maybe) |sel| {
            pushPosition(L, sel[0]);
            lua.lua_setfield(L, -2, "from");
            pushPosition(L, sel[1]);
            lua.lua_setfield(L, -2, "to");
        },
        .highlight => |h| {
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
        },
    }
}

/// Whether a document path matches a handler's pattern.
///
/// `*` is any run of characters and `?` is one, which is the whole of what a
/// pattern in an autocommand has ever needed. Two liberties, both because
/// these are file names: a separator matches either spelling, so a pattern
/// written with `/` finds a path Windows wrote with `\`; and case is folded,
/// because half the machines this runs on have a case-insensitive filesystem
/// and a pattern that works on one should work on the other.
pub fn matches(pattern: []const u8, path: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    // Where to come back to when a `*` has to swallow one more character.
    var star: ?usize = null;
    var mark: usize = 0;

    while (s < path.len) {
        if (p < pattern.len and (pattern[p] == '?' or same(pattern[p], path[s]))) {
            p += 1;
            s += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            mark = s;
            p += 1;
        } else if (star) |at| {
            p = at + 1;
            mark += 1;
            s = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn same(a: u8, b: u8) bool {
    if (a == '\\' or a == '/') return b == '\\' or b == '/';
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Every command name plugins have registered, for `:commands`.
pub fn commandNames(rt: *const Runtime) []const UserCommand {
    return rt.commands.items;
}

pub fn keymapList(rt: *const Runtime) []const Keymap {
    return rt.keymaps.items;
}

/// Every `fenrir.on` that is still live, for the commands that print them.
pub fn handlerList(rt: *const Runtime) []const Handler {
    return rt.handlers.items;
}

/// Every button a plugin put on a rail, in the order they were added.
pub fn railList(rt: *const Runtime) []const RailButton {
    return rt.rails.items;
}

/// Every setting a plugin declared, for the page that lists them.
pub fn settingList(rt: *const Runtime) []const Setting {
    return rt.settings.items;
}

/// Every panel a plugin declared, for the rail that latches them.
pub fn panelList(rt: *const Runtime) []const Panel {
    return rt.panels.items;
}

/// Asks a panel for its rows.
///
/// The result lives until the next call and belongs to the runtime, which is
/// what lets it be a list of borrowed slices rather than a list the reader
/// has to free. Called when a panel is opened and when `fenrir.refresh` says
/// the list has changed, and never on a frame path: a plugin's `rows`
/// function is Lua and Lua does not run sixty times a second here.
pub fn panelRows(rt: *Runtime, id: u32) []const PanelRow {
    rt.rows.clearRetainingCapacity();
    if (!lua.available) return &.{};
    _ = rt.rows_arena.reset(.retain_capacity);

    for (rt.panels.items) |p| {
        if (p.id != id or !p.live) continue;
        var what: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&what, "panel {s}", .{
            p.name[0..@min(p.name.len, 40)],
        }) catch "panel";
        var job: RowJob = .{ .ref = p.rows_ref };
        lua.lua_pushcclosure(rt.L, rowsTrampoline, 0);
        lua.lua_pushlightuserdata(rt.L, &job);
        _ = rt.call(1, 0, label);
        return rt.rows.items;
    }
    return &.{};
}

/// Tells a panel that one of its rows was chosen.
pub fn choosePanelRow(rt: *Runtime, id: u32, row: u64) void {
    if (!lua.available) return;
    for (rt.panels.items) |p| {
        if (p.id != id or !p.live or p.choose_ref == lua.no_ref) continue;
        var what: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&what, "panel {s}", .{
            p.name[0..@min(p.name.len, 40)],
        }) catch "panel";
        var job: ChooseJob = .{ .ref = p.choose_ref, .row = row };
        lua.lua_pushcclosure(rt.L, chooseTrampoline, 0);
        lua.lua_pushlightuserdata(rt.L, &job);
        _ = rt.call(1, 0, label);
        return;
    }
}

const RowJob = struct { ref: c_int };
const ChooseJob = struct { ref: c_int, row: u64 };

fn chooseTrampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *const ChooseJob = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    _ = lua.lua_rawgeti(L, lua.registry_index, job.ref);
    lua.lua_pushinteger(L, @intCast(job.row));
    lua.lua_callk(L, 1, 0, 0, null);
    return 0;
}

/// Calls a panel's `rows` function and reads the list it returns.
///
/// Every string is copied out into the arena before this returns, because the
/// table it came from is Lua's and is collectable the moment the call is
/// over. Copying is the price of the reader being able to hold the list
/// across frames without a Lua reference of its own.
fn rowsTrampoline(L: ?*lua.State) callconv(.c) c_int {
    const job: *const RowJob = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    const rt = of(L);
    _ = lua.lua_rawgeti(L, lua.registry_index, job.ref);
    lua.lua_callk(L, 0, 1, 0, null);
    if (lua.typeOf(L, -1) != .table) lua.raise(L, "galdr: a panel's rows function returns a list of rows");

    const arena = rt.rows_arena.allocator();
    const n: lua.Integer = @intCast(lua.lua_rawlen(L, -1));
    var i: lua.Integer = 1;
    while (i <= n and i <= max_panel_rows) : (i += 1) {
        _ = lua.lua_rawgeti(L, -1, i);
        if (lua.typeOf(L, -1) != .table) lua.raise(L, "galdr: a panel row is a table");
        var row: PanelRow = .{};
        inline for (.{ "label", "detail", "icon", "color" }) |field| {
            _ = lua.lua_getfield(L, -1, field);
            if (lua.toString(L, -1)) |text| {
                @field(row, field) = arena.dupe(u8, text[0..@min(text.len, 512)]) catch "";
            }
            lua.pop(L, 1);
        }
        _ = lua.lua_getfield(L, -1, "page");
        row.page = clampTo(u32, lua.lua_tointegerx(L, -1, null));
        lua.pop(L, 1);
        _ = lua.lua_getfield(L, -1, "depth");
        row.depth = clampTo(u8, lua.lua_tointegerx(L, -1, null));
        lua.pop(L, 1);
        // From one, because zero is the panel's "nothing chosen". A row that
        // gave none gets its place in the list, which is a number a plugin
        // can use as well as any it would have invented.
        _ = lua.lua_getfield(L, -1, "id");
        const given = lua.lua_tointegerx(L, -1, null);
        row.id = if (given > 0) @intCast(given) else @intCast(i);
        lua.pop(L, 1);

        rt.rows.append(rt.gpa, row) catch break;
        lua.pop(L, 1);
    }
    return 0;
}

fn clampTo(comptime T: type, value: lua.Integer) T {
    return @intCast(std.math.clamp(value, 0, std.math.maxInt(T)));
}

/// The most rows a panel will show. Long enough for a chapter list or a
/// session's worth of notes, short enough that a plugin with a bug does not
/// take the reader's memory with it.
pub const max_panel_rows = 4096;

/// What a rail button was for, run.
///
/// The same two ways in a key binding has, for the same reason: a button that
/// is a `:` line is the commonest kind and needs no function written round
/// it, and a button that is a function reaches things the command line does
/// not have a name for.
pub fn runRail(rt: *Runtime, id: u32) void {
    if (!lua.available) return;
    for (rt.rails.items) |b| {
        if (b.id != id or !b.live) continue;
        if (b.ref == lua.no_ref) {
            _ = rt.host.exec(b.line);
            return;
        }
        var what: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&what, "rail {s}", .{
            b.label[0..@min(b.label.len, 40)],
        }) catch "rail";
        _ = rt.invoke(.{ .ref = b.ref }, label);
        return;
    }
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

        // The module runs in the environment of whoever required it, so a
        // narrowed plugin's modules are narrowed too. Modules are cached, so
        // the first requirer's environment is the one they keep -- the same
        // wrinkle Neovim has, and for the same reason.
        _ = lua.lua_rawgeti(L, lua.registry_index, rt.env_ref);
        _ = lua.lua_setupvalue(L, -2, 1);

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

/// `fenrir.manifest{ about =, version =, capabilities = {...} }`.
///
/// What a single-file plugin writes instead of a `plugin.lua`. It takes
/// effect from where it is called, which is why it belongs on the first line:
/// a plugin that calls it halfway down has already had the whole table for
/// half a file, and the manifest is a description of the plugin rather than a
/// gate in front of it.
fn apiManifest(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, @intFromEnum(lua.Type.table));
    applyManifest(L, 1);
    return 0;
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

/// `fenrir.command(name, function, description, icon)`: a `:name args`
/// command.
///
/// The description and the icon are what the palette draws, and they are the
/// whole difference between a plugin's command being findable and being
/// something you have to already know the name of.
fn apiCommand(L: ?*lua.State) callconv(.c) c_int {
    const name = lua.checkString(L, 1);
    lua.luaL_checktype(L, 2, @intFromEnum(lua.Type.function));
    const description = lua.optString(L, 3) orelse "";
    const icon = lua.optString(L, 4) orelse "";

    const valid = name.len > 0 and name.len <= 64 and std.ascii.isAlphabetic(name[0]) and for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break false;
    } else true;
    if (!valid) lua.raise(L, "galdr: a command name is a letter followed by letters, digits, _ or -");

    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.registry_index);

    const rt = of(L);
    for (rt.commands.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        // Redefining a command replaces it, as `:command!` does -- all of
        // it, because a plugin that changed what a command *does* and was
        // left with the old sentence beside it in the palette would be the
        // palette lying about the reader.
        lua.luaL_unref(L, lua.registry_index, c.ref);
        c.ref = ref;
        if (rt.gpa.dupe(u8, description)) |d| {
            rt.gpa.free(c.description);
            c.description = d;
        } else |_| {}
        if (rt.gpa.dupe(u8, icon)) |p| {
            rt.gpa.free(c.icon);
            c.icon = p;
        } else |_| {}
        rt.revision +%= 1;
        return 0;
    }
    const owned = rt.gpa.dupe(u8, name) catch null;
    const desc = rt.gpa.dupe(u8, description) catch null;
    const picture = rt.gpa.dupe(u8, icon) catch null;
    const added = owned != null and desc != null and picture != null and
        (if (rt.commands.append(rt.gpa, .{
            .name = owned.?,
            .ref = ref,
            .description = desc.?,
            .icon = picture.?,
        })) true else |_| false);
    if (!added) {
        if (owned) |s| rt.gpa.free(s);
        if (desc) |s| rt.gpa.free(s);
        if (picture) |s| rt.gpa.free(s);
        return rt.outOfMemory(L, ref);
    }
    rt.revision +%= 1;
    return 0;
}

/// `fenrir.on(event, pattern, function, group)`, returning an id for
/// `fenrir.off`.
///
/// Vim's autocommand, with Vim's arguments: what happened, which files it has
/// to have happened to, and what to do. The pattern may be left out --
/// `fenrir.on("Quit", f)` -- because three of the events are about the reader
/// and have no file to match. The group may be left out too, and is what
/// `fenrir.clear` takes away when a plugin is reloaded and wants its own
/// handlers gone before it registers them again.
fn apiOn(L: ?*lua.State) callconv(.c) c_int {
    const name = lua.checkString(L, 1);
    const event = std.meta.stringToEnum(Event, name) orelse {
        var msg: [200]u8 = undefined;
        lua.raise(L, std.fmt.bufPrint(&msg, "galdr: \"{s}\" is not an event; `fenrir health` lists them", .{
            name[0..@min(name.len, 40)],
        }) catch "galdr: not an event");
    };

    // Two shapes, told apart by what is in the second place. A string there
    // is a pattern and a function there is the handler.
    const shifted = lua.typeOf(L, 2) == .function;
    const pattern = if (shifted) "*" else lua.checkString(L, 2);
    const at: c_int = if (shifted) 2 else 3;
    lua.luaL_checktype(L, at, @intFromEnum(lua.Type.function));
    const group = lua.optString(L, at + 1) orelse "";

    lua.lua_pushvalue(L, at);
    const ref = lua.luaL_ref(L, lua.registry_index);

    const rt = of(L);
    const owned_pattern = rt.gpa.dupe(u8, pattern) catch null;
    const owned_group = rt.gpa.dupe(u8, group) catch null;
    const id = rt.next_handler;
    const added = owned_pattern != null and owned_group != null and
        (if (rt.handlers.append(rt.gpa, .{
            .id = id,
            .event = event,
            .pattern = owned_pattern.?,
            .group = owned_group.?,
            .ref = ref,
        })) true else |_| false);
    if (!added) {
        if (owned_pattern) |s| rt.gpa.free(s);
        if (owned_group) |s| rt.gpa.free(s);
        return rt.outOfMemory(L, ref);
    }
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

/// `fenrir.clear(group)`: every handler and every contribution registered
/// under that name, gone. Returns how many there were, so a plugin reloading
/// itself can say so.
///
/// One call for both because a plugin reloading itself wants one call. The
/// group is the plugin's name by convention and nothing enforces that: a
/// group is a label a plugin puts on its own work, not a namespace.
fn apiClear(L: ?*lua.State) callconv(.c) c_int {
    const group = lua.checkString(L, 1);
    if (group.len == 0) lua.raise(L, "galdr: a group has a name");
    const rt = of(L);
    var cleared: lua.Integer = 0;
    for (rt.handlers.items) |*h| {
        if (!h.live or !std.mem.eql(u8, h.group, group)) continue;
        h.live = false;
        lua.luaL_unref(L, lua.registry_index, h.ref);
        cleared += 1;
    }
    for (rt.rails.items) |*b| {
        if (!b.live or !std.mem.eql(u8, b.group, group)) continue;
        b.live = false;
        if (b.ref != lua.no_ref) lua.luaL_unref(L, lua.registry_index, b.ref);
        b.ref = lua.no_ref;
        rt.revision +%= 1;
        cleared += 1;
    }
    for (rt.settings.items) |*s| {
        if (!s.live or !std.mem.eql(u8, s.group, group)) continue;
        s.live = false;
        rt.revision +%= 1;
        cleared += 1;
    }
    for (rt.panels.items) |*p| {
        if (!p.live or !std.mem.eql(u8, p.group, group)) continue;
        p.live = false;
        if (p.rows_ref != lua.no_ref) lua.luaL_unref(L, lua.registry_index, p.rows_ref);
        if (p.choose_ref != lua.no_ref) lua.luaL_unref(L, lua.registry_index, p.choose_ref);
        p.rows_ref = lua.no_ref;
        p.choose_ref = lua.no_ref;
        rt.revision +%= 1;
        cleared += 1;
    }
    lua.lua_pushinteger(L, cleared);
    return 1;
}

/// `fenrir.rail{ side =, icon =, label =, action =, group = }`, returning an
/// id for `fenrir.unrail`.
///
/// A table rather than four positional arguments because five of the six
/// fields have sensible defaults and a call with three `nil`s in it is a call
/// nobody can read. `action` is a function or a `:` command line.
fn apiRail(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, @intFromEnum(lua.Type.table));

    _ = lua.lua_getfield(L, 1, "side");
    const side_text = lua.toString(L, -1) orelse "right";
    const side = std.meta.stringToEnum(Side, side_text) orelse
        lua.raise(L, "galdr: a rail is \"left\" or \"right\"");
    lua.pop(L, 1);

    _ = lua.lua_getfield(L, 1, "label");
    const label = lua.toString(L, -1) orelse lua.raise(L, "galdr: a rail button needs a label");
    if (label.len == 0 or label.len > 64) lua.raise(L, "galdr: a rail button's label is one to sixty-four bytes");

    _ = lua.lua_getfield(L, 1, "icon");
    const icon = lua.toString(L, -1) orelse "fenrir.unknown";

    _ = lua.lua_getfield(L, 1, "group");
    const group = lua.toString(L, -1) orelse "";

    _ = lua.lua_getfield(L, 1, "action");
    const kind = lua.typeOf(L, -1);
    if (kind != .function and kind != .string) lua.raise(L, "galdr: a rail button needs a function or a command line");
    const line = if (kind == .string) lua.toString(L, -1).? else "";

    // Every argument is checked; from here Lua calls come before Zig
    // allocations, as `apiKeymap` does and for the same reason.
    //
    // The strings stay on the stack until they have been copied: `line`
    // borrows the very value `luaL_ref` would have popped.
    var ref: c_int = lua.no_ref;
    if (kind == .function) ref = lua.luaL_ref(L, lua.registry_index);

    const rt = of(L);
    const owned_icon = rt.gpa.dupe(u8, icon) catch null;
    const owned_label = rt.gpa.dupe(u8, label) catch null;
    const owned_line = rt.gpa.dupe(u8, line) catch null;
    const owned_group = rt.gpa.dupe(u8, group) catch null;
    const id = rt.next_contribution;
    const added = owned_icon != null and owned_label != null and owned_line != null and owned_group != null and
        (if (rt.rails.append(rt.gpa, .{
            .id = id,
            .side = side,
            .icon = owned_icon.?,
            .label = owned_label.?,
            .ref = ref,
            .line = owned_line.?,
            .group = owned_group.?,
        })) true else |_| false);
    if (!added) {
        if (owned_icon) |s| rt.gpa.free(s);
        if (owned_label) |s| rt.gpa.free(s);
        if (owned_line) |s| rt.gpa.free(s);
        if (owned_group) |s| rt.gpa.free(s);
        return rt.outOfMemory(L, ref);
    }
    rt.next_contribution += 1;
    rt.revision +%= 1;
    lua.lua_pushinteger(L, id);
    return 1;
}

/// `fenrir.setting{ key =, about =, choices = {...}, unset = }`.
///
/// Declaring one does not store anything and does not read anything back:
/// the value is `fenrir.store.get(key)` before and after, and this only says
/// what the key means so the settings page can draw a row for it. A plugin
/// that wants a default gives `unset` the words for it and keeps treating an
/// absent value as that default -- which it had to do anyway, because a
/// person can always clear the row.
fn apiSetting(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, @intFromEnum(lua.Type.table));

    _ = lua.lua_getfield(L, 1, "key");
    const key = lua.toString(L, -1) orelse lua.raise(L, "galdr: a setting needs a key");
    const fine = key.len > 0 and key.len <= 48 and for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') break false;
    } else true;
    if (!fine) lua.raise(L, "galdr: a setting's key is letters, digits, _ - or .");

    _ = lua.lua_getfield(L, 1, "about");
    const about = lua.toString(L, -1) orelse "";
    _ = lua.lua_getfield(L, 1, "unset");
    const unset = lua.toString(L, -1) orelse "not set";
    _ = lua.lua_getfield(L, 1, "group");
    const group = lua.toString(L, -1) orelse "";

    const rt = of(L);
    var row: Setting = .{
        .key = rt.gpa.dupe(u8, key) catch lua.raise(L, "galdr: out of memory"),
        .about = rt.gpa.dupe(u8, about) catch &.{},
        .unset = rt.gpa.dupe(u8, unset) catch &.{},
        .group = rt.gpa.dupe(u8, group) catch &.{},
    };

    _ = lua.lua_getfield(L, 1, "choices");
    if (lua.typeOf(L, -1) == .table) {
        const n: lua.Integer = @intCast(lua.lua_rawlen(L, -1));
        var i: lua.Integer = 1;
        while (i <= n) : (i += 1) {
            _ = lua.lua_rawgeti(L, -1, i);
            const text = lua.toString(L, -1) orelse "";
            const owned = rt.gpa.dupe(u8, text) catch break;
            row.choices.append(rt.gpa, owned) catch {
                rt.gpa.free(owned);
                break;
            };
            lua.pop(L, 1);
        }
    }

    // Declaring the same key twice replaces it, as redefining a command does:
    // a plugin reloaded should not leave two rows behind.
    for (rt.settings.items) |*existing| {
        if (!existing.live or !std.mem.eql(u8, existing.key, key)) continue;
        freeSetting(rt.gpa, existing);
        existing.* = row;
        rt.revision +%= 1;
        return 0;
    }
    rt.settings.append(rt.gpa, row) catch {
        freeSetting(rt.gpa, &row);
        lua.raise(L, "galdr: out of memory");
    };
    rt.revision +%= 1;
    return 0;
}

fn freeSetting(gpa: Allocator, s: *Setting) void {
    gpa.free(s.key);
    gpa.free(s.about);
    gpa.free(s.unset);
    gpa.free(s.group);
    for (s.choices.items) |c| gpa.free(c);
    s.choices.deinit(gpa);
}

/// `fenrir.panel{ id =, title =, icon =, empty =, rows = fn, choose = fn }`.
///
/// The rail grows a latch for it beside the reader's own, and choosing a row
/// calls `choose` with that row's id. A plugin never touches a box: it says
/// what its rows *are* and Þviti lays them out, which is the same division
/// the annotations panel and the outline already work under.
fn apiPanel(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, @intFromEnum(lua.Type.table));

    _ = lua.lua_getfield(L, 1, "id");
    const name = lua.toString(L, -1) orelse lua.raise(L, "galdr: a panel needs an id");
    if (name.len == 0 or name.len > 64) lua.raise(L, "galdr: a panel's id is one to sixty-four bytes");

    _ = lua.lua_getfield(L, 1, "title");
    const title = lua.toString(L, -1) orelse name;
    _ = lua.lua_getfield(L, 1, "icon");
    const icon = lua.toString(L, -1) orelse "fenrir.panel";
    _ = lua.lua_getfield(L, 1, "empty");
    const empty = lua.toString(L, -1) orelse "nothing here";
    _ = lua.lua_getfield(L, 1, "group");
    const group = lua.toString(L, -1) orelse "";

    // Referenced last of the two, and both after every check: a reference
    // taken before a raise is a reference nothing will ever release.
    _ = lua.lua_getfield(L, 1, "choose");
    const has_choose = lua.typeOf(L, -1) == .function;
    if (!has_choose and lua.typeOf(L, -1) != .nil) lua.raise(L, "galdr: a panel's choose is a function");
    _ = lua.lua_getfield(L, 1, "rows");
    if (lua.typeOf(L, -1) != .function) lua.raise(L, "galdr: a panel needs a rows function");

    const rows_ref = lua.luaL_ref(L, lua.registry_index);
    const choose_ref = if (has_choose) lua.luaL_ref(L, lua.registry_index) else lua.no_ref;

    const rt = of(L);
    const owned_name = rt.gpa.dupe(u8, name) catch null;
    const owned_title = rt.gpa.dupe(u8, title) catch null;
    const owned_icon = rt.gpa.dupe(u8, icon) catch null;
    const owned_empty = rt.gpa.dupe(u8, empty) catch null;
    const owned_group = rt.gpa.dupe(u8, group) catch null;
    const id = rt.next_contribution;
    const added = owned_name != null and owned_title != null and owned_icon != null and
        owned_empty != null and owned_group != null and
        (if (rt.panels.append(rt.gpa, .{
            .id = id,
            .name = owned_name.?,
            .title = owned_title.?,
            .icon = owned_icon.?,
            .empty = owned_empty.?,
            .rows_ref = rows_ref,
            .choose_ref = choose_ref,
            .group = owned_group.?,
        })) true else |_| false);
    if (!added) {
        if (owned_name) |s| rt.gpa.free(s);
        if (owned_title) |s| rt.gpa.free(s);
        if (owned_icon) |s| rt.gpa.free(s);
        if (owned_empty) |s| rt.gpa.free(s);
        if (owned_group) |s| rt.gpa.free(s);
        if (choose_ref != lua.no_ref) lua.luaL_unref(L, lua.registry_index, choose_ref);
        return rt.outOfMemory(L, rows_ref);
    }
    rt.next_contribution += 1;
    rt.revision +%= 1;
    lua.lua_pushinteger(L, id);
    return 1;
}

/// `fenrir.refresh()`: the lists a plugin declared are out of date.
///
/// One call for all of them rather than one per panel, because a plugin that
/// changed something usually changed the thing two of its lists are drawn
/// from -- and rebuilding a list nobody has open costs nothing, since the
/// reader only asks the panel that is showing.
fn apiRefresh(L: ?*lua.State) callconv(.c) c_int {
    of(L).revision +%= 1;
    return 0;
}

fn apiUnrail(L: ?*lua.State) callconv(.c) c_int {
    const id = lua.luaL_checkinteger(L, 1);
    const rt = of(L);
    for (rt.rails.items) |*b| {
        if (b.id != id or !b.live) continue;
        b.live = false;
        if (b.ref != lua.no_ref) lua.luaL_unref(L, lua.registry_index, b.ref);
        b.ref = lua.no_ref;
        rt.revision +%= 1;
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
        \\local id = fenrir.on("PageChanged", function(e) seen[#seen + 1] = e.page end)
        \\fenrir.on("DocOpen", function(e) opened = e.title .. ":" .. e.pages .. ":" .. e.path end)
        \\fenrir.on("AnnotationAdd", function(e) made = e.event .. e.page end)
        \\fenrir.on("SelectionChanged", function(e) sel = e.from and e.from.line or "none" end)
        \\off_id = id
    ));
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 4 } });
    rt.emit(.{ .event = .DocOpen, .path = "/a.pdf", .data = .{ .document = .{
        .path = "/a.pdf",
        .title = "a.pdf",
        .pages = 9,
    } } });
    rt.emit(.{ .event = .AnnotationAdd, .data = .{ .highlight = .{
        .page = 2,
        .x0 = 0,
        .y0 = 0,
        .x1 = 1,
        .y1 = 1,
    } } });
    rt.emit(.{ .event = .SelectionChanged, .data = .{ .selection = null } });
    try testing.expect(rt.runString("check",
        \\assert(seen[1] == 4)
        \\assert(opened == "a.pdf:9:/a.pdf", tostring(opened))
        \\assert(made == "AnnotationAdd2", tostring(made))
        \\assert(sel == "none")
        \\fenrir.off(off_id)
    ));
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 5 } });
    try testing.expect(rt.runString("check2", "assert(#seen == 1, 'handler still ran')"));

    try testing.expect(!rt.runString("bad", "fenrir.on('nonsense', function() end)"));
    // A reserved event takes a handler and never fires it. That is not an
    // error: it is a plugin written for the version that will have it.
    try testing.expect(rt.runString("reserved", "fenrir.on('BeforeRedact', function() end)"));
}

test "a pattern decides which documents a handler hears about" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\papers, all = 0, 0
        \\fenrir.on("DocOpen", "*/papers/*.pdf", function() papers = papers + 1 end)
        \\fenrir.on("DocOpen", "*", function() all = all + 1 end)
    ));
    for ([_][]const u8{ "/home/x/papers/a.pdf", "/home/x/books/b.pdf", "C:\\Users\\x\\Papers\\C.PDF" }) |p| {
        rt.emit(.{ .event = .DocOpen, .path = p, .data = .{ .document = .{ .path = p, .title = p, .pages = 1 } } });
    }
    try testing.expect(rt.runString("check", "assert(papers == 2, papers) assert(all == 3)"));
}

test "globs match the way a file name needs them to" {
    try testing.expect(matches("*", ""));
    try testing.expect(matches("*", "/a/b.pdf"));
    try testing.expect(matches("*.pdf", "/a/b.pdf"));
    try testing.expect(matches("*.pdf", "b.pdf"));
    try testing.expect(!matches("*.pdf", "b.pdfx"));
    try testing.expect(matches("?.pdf", "b.pdf"));
    try testing.expect(!matches("?.pdf", "ab.pdf"));
    // A separator is a separator, and a name is a name, whichever machine
    // wrote it down.
    try testing.expect(matches("*/papers/*", "C:\\docs\\PAPERS\\x.pdf"));
    try testing.expect(matches("/a/b", "\\a\\b"));
    try testing.expect(!matches("/a/b", "/a/c"));
    // The pathological one: many stars over a string with no match at the
    // end, which a naive matcher takes exponential time over.
    try testing.expect(!matches("*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaac"));
}

test "a group goes away in one call" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\n, kept = 0, 0
        \\fenrir.on("PageChanged", "*", function() n = n + 1 end, "mine")
        \\fenrir.on("PageChanged", "*", function() n = n + 1 end, "mine")
        \\fenrir.on("PageChanged", "*", function() kept = kept + 1 end)
    ));
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 1 } });
    try testing.expect(rt.runString("again",
        \\assert(n == 2, n)
        \\assert(fenrir.clear("mine") == 2)
        \\assert(fenrir.clear("mine") == 0)
    ));
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 2 } });
    try testing.expect(rt.runString("check", "assert(n == 2, n) assert(kept == 2, kept)"));
}

test "a handler that yields is picked up again, with a fresh budget each time" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    // A budget too small for the whole loop in one go, so the only way the
    // handler finishes is by being resumed.
    const rt = try create(testing.allocator, fake.host(), .{ .step_limit = 20 });
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\total, rounds = 0, 0
        \\fenrir.on("PageChanged", function()
        \\  for _ = 1, 8 do
        \\    for i = 1, 20000 do total = total + i end
        \\    rounds = rounds + 1
        \\    coroutine.yield()
        \\  end
        \\  done = true
        \\end)
    ));
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 1 } });
    try testing.expectEqual(@as(usize, 1), rt.waiting());
    try testing.expect(rt.runString("check", "assert(rounds == 1) assert(done == nil)"));

    var frames: usize = 0;
    while (rt.waiting() != 0 and frames < 100) : (frames += 1) rt.pump();
    try testing.expectEqual(@as(usize, 0), rt.waiting());
    try testing.expect(rt.runString("check", "assert(done, 'the handler never finished') assert(rounds == 8)"));
    try testing.expectEqual(@as(usize, 0), rt.messages.items.len);

    // And one that never yields is still stopped at the limit, on its own
    // coroutine, without taking the reader with it.
    try testing.expect(rt.runString("more", "fenrir.on('Quit', function() while true do end end)"));
    rt.emit(.{ .event = .Quit });
    try testing.expectEqual(@as(usize, 0), rt.waiting());
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "too long") != null);
}

test "an error in a handler is one plugin's problem" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\after = 0
        \\fenrir.on("PageChanged", function() error("from a handler") end)
        \\fenrir.on("PageChanged", function() after = after + 1 end)
    ));
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 1 } });
    try testing.expectEqual(@as(usize, 1), rt.messages.items.len);
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "from a handler") != null);
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "PageChanged") != null);
    try testing.expect(rt.runString("check", "assert(after == 1, 'the next handler was skipped')"));
}

test "a handler that causes its own event does not recurse forever" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    // A host whose goTo emits `PageChanged` would loop; the depth limit ends
    // it.
    try testing.expect(rt.runString("init.lua",
        \\count = 0
        \\fenrir.on("PageChanged", function() count = count + 1 end)
    ));
    for (0..3) |_| rt.emit(.{ .event = .PageChanged, .data = .{ .page = 1 } });
    try testing.expect(rt.runString("check", "assert(count == 3)"));

    rt.emitting = max_event_depth;
    rt.emit(.{ .event = .PageChanged, .data = .{ .page = 1 } });
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

test "a manifest takes away what it did not ask for, and only from itself" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{ .files = &.{
        .{ "plugins/reader.lua",
        \\fenrir.manifest{ about = "reads", version = "1.2", capabilities = { "document.read" } }
        \\reader_has = { page = fenrir.page ~= nil, mark = fenrir.highlight ~= nil, say = fenrir.notify ~= nil }
        \\reader_page = fenrir.page()
        },
        .{ "plugins/writer.lua", "writer_has = { mark = fenrir.highlight ~= nil, say = fenrir.notify ~= nil }" },
    } };
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    rt.loadConfig();
    try testing.expect(rt.runString("check",
        \\assert(reader_has.page, "document.read was asked for and is missing")
        \\assert(not reader_has.mark, "document.write was not asked for and is there")
        \\assert(not reader_has.say, "ui was not asked for and is there")
        \\assert(reader_page == 3)
        \\assert(writer_has.mark and writer_has.say, "a plugin with no manifest lost something")
        \\assert(rawget(_G, "fenrir") == nil, "there is a global fenrir to reach around it")
    ));

    for (rt.plugins.items) |p| try testing.expect(p.ok);
    const reader = rt.plugins.items[0];
    try testing.expect(reader.manifest.declared);
    try testing.expect(reader.manifest.caps.has(.document_read));
    try testing.expect(!reader.manifest.caps.has(.ui));
    try testing.expectEqualStrings("reads", reader.manifest.about);
    try testing.expectEqualStrings("1.2", reader.manifest.version);

    try testing.expect(!rt.plugins.items[1].manifest.declared);
    try testing.expect(rt.plugins.items[1].manifest.caps.has(.redaction));
}

test "a folder's plugin.lua says the same thing, and a bad one stops the plugin" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{ .files = &.{
        .{ "plugins/good/plugin.lua", "return { about = \"a folder\", capabilities = { \"ui\" } }" },
        .{ "plugins/good/init.lua", "good_has = fenrir.notify ~= nil and fenrir.page == nil" },
        .{ "plugins/wrong/plugin.lua", "return { capabilities = { \"telepathy\" } }" },
        .{ "plugins/wrong/init.lua", "ran_anyway = true" },
    } };
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    rt.loadConfig();
    try testing.expect(rt.runString("check",
        \\assert(good_has, "a folder's manifest was not applied")
        \\assert(ran_anyway == nil, "a plugin ran with a manifest nobody could read")
    ));
    try testing.expect(rt.plugins.items[0].ok);
    try testing.expectEqualStrings("a folder", rt.plugins.items[0].manifest.about);
    try testing.expect(!rt.plugins.items[1].ok);
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "telepathy") != null);
}

test "a plugin puts buttons on the rails, and takes them away again" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\list = fenrir.rail{ icon = "fenrir.bookmark", label = "Reading list",
        \\                    action = function() fenrir.notify("opened") end, group = "mine" }
        \\fenrir.rail{ side = "left", icon = "fenrir.note", label = "Note", action = "vsplit", group = "mine" }
        \\gone = fenrir.rail{ label = "Temporary", action = "q" }
    ));

    const before = rt.revision;
    try testing.expect(rt.runString("drop", "fenrir.unrail(gone)"));
    try testing.expect(rt.revision != before);

    var live: usize = 0;
    var sides: [2]Side = undefined;
    for (rt.railList()) |b| {
        if (!b.live) continue;
        sides[live] = b.side;
        live += 1;
    }
    try testing.expectEqual(@as(usize, 2), live);
    try testing.expectEqual(Side.right, sides[0]);
    try testing.expectEqual(Side.left, sides[1]);
    try testing.expectEqualStrings("Reading list", rt.railList()[0].label);
    try testing.expectEqualStrings("fenrir.bookmark", rt.railList()[0].icon);

    // Both ways in: a function, and a command line the host is asked to run.
    rt.runRail(rt.railList()[0].id);
    try testing.expectEqualStrings("opened", fake.notes.items[fake.notes.items.len - 1]);
    rt.runRail(rt.railList()[1].id);
    try testing.expectEqualStrings("vsplit", fake.execs.items[0]);

    // A button that is gone does nothing rather than doing the wrong thing.
    rt.runRail(rt.railList()[2].id);
    try testing.expectEqual(@as(usize, 1), fake.execs.items.len);

    // And a reloading plugin drops its own in one call.
    try testing.expect(rt.runString("again", "assert(fenrir.clear('mine') == 2)"));
    for (rt.railList()) |b| try testing.expect(!b.live);

    try testing.expect(!rt.runString("bad", "fenrir.rail{ label = 'x' }"));
    try testing.expect(!rt.runString("bad", "fenrir.rail{ action = 'q' }"));
    try testing.expect(!rt.runString("bad", "fenrir.rail{ side = 'top', label = 'x', action = 'q' }"));
}

test "a plugin declares a setting, and its value is the store's" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\fenrir.setting{ key = "reading.list", about = "where the list is kept",
        \\                unset = "nowhere", group = "mine" }
        \\fenrir.setting{ key = "reading.sort", about = "how it is ordered",
        \\                choices = { "added", "title" }, group = "mine" }
    ));
    try testing.expectEqual(@as(usize, 2), rt.settingList().len);
    try testing.expectEqualStrings("reading.list", rt.settingList()[0].key);
    try testing.expectEqualStrings("nowhere", rt.settingList()[0].unset);
    try testing.expectEqual(@as(usize, 0), rt.settingList()[0].choices.items.len);
    try testing.expectEqualStrings("title", rt.settingList()[1].choices.items[1]);
    // Declaring one stores nothing: the value is the store's, before and
    // after, and `fenrir.store` is still how a plugin reads it.
    try testing.expect(fake.stored == null);

    // The same key twice replaces the row rather than adding a second.
    try testing.expect(rt.runString("again",
        \\fenrir.setting{ key = "reading.list", about = "somewhere else" }
    ));
    try testing.expectEqual(@as(usize, 2), rt.settingList().len);
    try testing.expectEqualStrings("somewhere else", rt.settingList()[0].about);
    // ...and it is no longer in the group, so a reload clears one, not two.
    try testing.expect(rt.runString("clear", "assert(fenrir.clear('mine') == 1)"));

    try testing.expect(!rt.runString("bad", "fenrir.setting{ about = 'no key' }"));
    try testing.expect(!rt.runString("bad", "fenrir.setting{ key = 'has spaces' }"));
}

test "a command carries its icon into the palette, and redefining replaces both" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\fenrir.command("Read", function() end, "open the reading list", "fenrir.bookmark")
        \\fenrir.command("Plain", function() end)
    ));
    try testing.expectEqualStrings("fenrir.bookmark", rt.commandNames()[0].icon);
    try testing.expectEqualStrings("open the reading list", rt.commandNames()[0].description);
    try testing.expectEqual(@as(usize, 0), rt.commandNames()[1].icon.len);

    try testing.expect(rt.runString("again",
        \\fenrir.command("Read", function() end, "close it again", "fenrir.close")
    ));
    try testing.expectEqual(@as(usize, 2), rt.commandNames().len);
    try testing.expectEqualStrings("close it again", rt.commandNames()[0].description);
    try testing.expectEqualStrings("fenrir.close", rt.commandNames()[0].icon);
}

test "a panel is a list a plugin builds, asked for when it is wanted" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\asked, chose = 0, nil
        \\titles = { "Chapter one", "Chapter two" }
        \\id = fenrir.panel{
        \\  id = "reading", title = "Reading list", icon = "fenrir.bookmark",
        \\  empty = "nothing saved yet", group = "mine",
        \\  rows = function()
        \\    asked = asked + 1
        \\    local out = {}
        \\    for i, t in ipairs(titles) do
        \\      out[i] = { label = t, detail = i .. " days ago", page = i * 4,
        \\                 color = "#ffcc00", depth = i - 1, id = 100 + i }
        \\    end
        \\    return out
        \\  end,
        \\  choose = function(row) chose = row end,
        \\}
    ));

    try testing.expectEqual(@as(usize, 1), rt.panelList().len);
    const panel = rt.panelList()[0];
    try testing.expectEqualStrings("reading", panel.name);
    try testing.expectEqualStrings("Reading list", panel.title);
    try testing.expectEqualStrings("nothing saved yet", panel.empty);

    const rows = rt.panelRows(panel.id);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Chapter one", rows[0].label);
    try testing.expectEqualStrings("1 days ago", rows[0].detail);
    try testing.expectEqualStrings("#ffcc00", rows[0].color);
    try testing.expectEqual(@as(u32, 8), rows[1].page);
    try testing.expectEqual(@as(u8, 1), rows[1].depth);
    try testing.expectEqual(@as(u64, 102), rows[1].id);

    // Asked again, the list is what the plugin says it is now.
    try testing.expect(rt.runString("more", "titles[3] = 'Chapter three'"));
    try testing.expectEqual(@as(usize, 3), rt.panelRows(panel.id).len);
    try testing.expect(rt.runString("check", "assert(asked == 2, asked)"));

    rt.choosePanelRow(panel.id, 102);
    try testing.expect(rt.runString("check", "assert(chose == 102, tostring(chose))"));

    // A panel that is gone gives no rows rather than the ones it used to.
    try testing.expect(rt.runString("clear", "assert(fenrir.clear('mine') == 1)"));
    try testing.expectEqual(@as(usize, 0), rt.panelRows(panel.id).len);

    try testing.expect(!rt.runString("bad", "fenrir.panel{ title = 'no id', rows = function() end }"));
    try testing.expect(!rt.runString("bad", "fenrir.panel{ id = 'x' }"));
    try testing.expect(!rt.runString("bad", "fenrir.panel{ id = 'x', rows = 3 }"));
}

test "a panel whose rows are wrong reports and gives none" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{};
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    try testing.expect(rt.runString("init.lua",
        \\a = fenrir.panel{ id = "a", rows = function() return 7 end }
        \\b = fenrir.panel{ id = "b", rows = function() error("broken") end }
    ));
    try testing.expectEqual(@as(usize, 0), rt.panelRows(rt.panelList()[0].id).len);
    try testing.expectEqual(@as(usize, 0), rt.panelRows(rt.panelList()[1].id).len);
    try testing.expectEqual(@as(usize, 2), rt.messages.items.len);
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[0], "list of rows") != null);
    try testing.expect(std.mem.indexOf(u8, rt.messages.items[1], "broken") != null);
}

test "a rail button is behind the ui capability" {
    if (!lua.available) return error.SkipZigTest;
    var fake: FakeHost = .{ .files = &.{
        .{ "plugins/quiet.lua",
        \\fenrir.manifest{ capabilities = { "document.read" } }
        \\has_rail = fenrir.rail ~= nil
        },
    } };
    defer fake.deinit();
    const rt = try start(&fake);
    defer rt.destroy();

    rt.loadConfig();
    try testing.expect(rt.runString("check", "assert(has_rail == false)"));
    try testing.expectEqual(@as(usize, 0), rt.railList().len);
}

test "every capability name survives the round trip" {
    inline for (@typeInfo(Capability).@"enum".fields) |f| {
        const c: Capability = @enumFromInt(f.value);
        try testing.expectEqual(c, Capability.parse(c.name()).?);
        var set: Caps = .{};
        set.add(c);
        try testing.expect(set.has(c));
        try testing.expect(Caps.all.has(c));
    }
    try testing.expect(Capability.parse("document") == null);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Caps{})));
}
