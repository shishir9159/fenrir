//! The reader's state, and what it does with a key, a click or a `:` line.
//!
//! Every feature the reader has keeps its fields here and its code in a file
//! of its own beside this one, reached from the dispatch below -- `handle`,
//! `apply`, `execFrom` and `pointer` -- with one direct call each, and no
//! table of function pointers between them. Besides that dispatch, what is
//! here is what every build has: the documents, the windows onto them, the
//! command line, and where the reader was left.

const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("../Context.zig");
const chrome_mod = @import("../chrome.zig");
const diff_mod = @import("../diff.zig");
const find_mod = @import("../find.zig");
const glyphmod = @import("../glyphs.zig");
const library_mod = @import("../library.zig");
const Library = library_mod.Library;
const palette_mod = @import("../palette.zig");
const panels = @import("../panels.zig");
const rails_mod = @import("../rails.zig");
const settings_page = @import("../settings.zig");
const watch = @import("../watch.zig");

const compare = @import("compare.zig");
const cursor = @import("cursor.zig");
const frame = @import("frame.zig");
const ink = @import("ink.zig");
const interface = @import("interface.zig");
const marks = @import("marks.zig");
const plugins_mod = @import("plugins.zig");
const reload = @import("reload.zig");
const render = @import("render.zig");
const search_mod = @import("search.zig");
const windows = @import("windows.zig");

const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const galdr = fenrir.galdr;
const hlidskjalf = fenrir.hlidskjalf;
const lyngvi = fenrir.lyngvi;
const thviti = fenrir.thviti;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const Point = gelgja.Point;

const Buffer = hlidskjalf.Buffer;
const Layout = hlidskjalf.Layout;
const Marks = hlidskjalf.Marks;
const OneWindow = hlidskjalf.OneWindow;
const Tabs = hlidskjalf.Tabs;
const View = hlidskjalf.View;
const commands = hlidskjalf.commands;
const keys = hlidskjalf.keys;
const Theme = thviti.Theme;

const caps = fenrir.build_options;
const have_cpu = caps.path_cpu;
const have_gpu = caps.path_gpu;

const min_zoom = View.min_zoom;
const max_zoom = View.max_zoom;

/// What a feature this build left out is worth holding.
///
/// `noreturn` has no values, so `?noreturn` has exactly one -- null -- and
/// Zig folds `x orelse return` and `if (x) |y|` at comptime. That is what
/// turns "the reader checks whether it has a database" into "the reader has
/// no database and the code that used one is not in the binary". The field
/// types are the switch; the call sites below are written once and read
/// correctly either way.
const LibraryIfStored = if (caps.sqlite) Library else noreturn;
pub const ComparisonIfCompared = if (caps.compare) *diff_mod.Comparison else noreturn;
const RuntimeIfScripted = if (caps.lua) *galdr.Runtime else noreturn;

/// A field of a feature this build may leave out: its own type when the
/// feature is in, and `void` when it is not.
///
/// `void` rather than a value nothing reads, for the reason `library` is
/// `?noreturn`: a field that is there is a field a line can still touch,
/// and that line is then in the binary. Gone, every line that touches it
/// fails to compile unless a comptime-false gate above it means it is never
/// analysed -- so the gates in `handle`, `apply`, `execFrom`, `pointer` and
/// the frame loop are not a convention that can be forgotten. A build that
/// forgets one does not build.
fn If(comptime on: bool, comptime T: type) type {
    return if (on) T else void;
}

/// The windows: tabpages of split trees, or in a build with no splits the
/// one window there is. `layout()` is the arrangement on screen, a `Layout`
/// or that same one window, and both answer `current`, `count`, `iterator`
/// and `arrange` alike -- which is nearly all the reader asks of either.
const Windows = if (caps.splits) Tabs else OneWindow;
const Arrangement = if (caps.splits) Layout else OneWindow;

ctx: *Context,
/// The reader's heap, not the CLI's arena, and safe to call from the
/// rasterising thread.
gpa: Allocator,
samples: gleipnir.raster.Samples,

/// The open documents, and the tree of windows onto them.
buffers: std.ArrayList(Buffer) = .empty,
/// One font cache per open buffer, same index. Every page of a document
/// draws in the same few faces, and parsing each font program again for
/// every page was a tenth of the time a page took to appear.
///
/// Here rather than on `Buffer` because a buffer is Hliðskjálf's and the
/// binding of a PDF font to a Týr face is Vánagandr's, and the
/// dependencies run one way. Touched only from `produce`, which is to say
/// only on the rasterising thread, for the same reason `Document` is.
faces: std.ArrayList(glyphmod.Cache) = .empty,
/// One a buffer, beside `faces` and under the same rule: the file each
/// document was read from, and whether it is held shut. See `watch.zig`.
disks: std.ArrayList(watch.Disk) = .empty,
/// Whether files are followed when another program rewrites them, or
/// held so that none can: `--watch`, else the `watch` setting, off
/// unless asked for. Never in a comparison, whose `Rerun` reads the
/// buffers' bytes on a thread of its own while a reload would free them.
watching: bool = false,
/// `--time`, which prints a line for every reload.
timing: bool = false,
/// The tabpages, and the tree of windows in each. The one on screen is
/// `layout()`, which is what almost everything here means by "the
/// windows": a tab nobody is looking at is drawn by nothing and
/// rasterised for nobody. In a build with no splits, the one window, under
/// the same name so that it is started and arranged the same way.
tabs: Windows = .{},
keymap: keys.State = .{},

/// The interface drawn over the page: Þviti, a face off this machine, and
/// the glyph atlas. Null until there is a window to draw it in, which is
/// every test and every `--shot --path cpu`.
chrome: ?*chrome_mod.Chrome = null,

backend: render.Backend = if (have_gpu and !have_cpu) .gpu else .cpu,
placed: ?u64 = null,
recorded: render.Recorded = .{},

/// The colours everything the reader draws is taken from, the chrome's
/// and the page's backdrop alike. Remembered between sessions; see
/// `mimir`.
///
/// On the session and not only on the `Chrome`, because the backdrop, the
/// lines between windows and the paper under a page that has not arrived
/// yet are all drawn whether or not there is an interface -- `--shot`
/// draws them with no `Chrome` at all.
theme: Theme = .dark,

/// The settings page, and the values it is showing. Filled when it opens
/// and after every change, never per frame: see `settings.zig`.
settings: settings_page.State = .{},

/// The command palette, and the rows it is filtering.
///
/// The rows are rebuilt when the palette opens and not once a frame: the
/// built-in half is a table in the binary and the plugin half changes
/// when a plugin registers something, which is while Lua runs and never
/// during a frame. `palette.zig` re-ranks on the same rule.
palette: palette_mod.State = .{},
palette_rows: std.ArrayList(palette_mod.Row) = .empty,
/// The bytes a plugin's rows point into, copied out of Galdr.
///
/// The built-in half of the palette is a table in the binary and needs
/// no copy; a plugin's half is Galdr's, and Galdr may replace a command
/// while the palette is open -- `rt.pump()` runs a yielded callback
/// immediately before the chrome is built, so this is one frame and not
/// a race. The rows own what they draw and the arena is reset the next
/// time the palette opens.
palette_text: std.heap.ArenaAllocator,

/// The search bar, and what it has found.
///
/// Two states and not one, because they answer to different things: the
/// bar is a widget that is open or shut, and the search is a query, a
/// frontier and a list of hits that the worker thread fills in. `/`
/// starts both and escape ends both; nothing else touches the pair.
find: find_mod.State = .{},
search: hlidskjalf.search.State = .{},

/// The panel docked to the right rail, and the rows in it.
///
/// The rows are rebuilt when what is behind them changes and not once a
/// frame: `rows_for` is which buffer they were built from and what that
/// buffer's marks were at the time, and a highlight added or removed is
/// what makes them stale. The labels are the marks' own note bytes,
/// which live on the buffer, so nothing here owns a string.
panel: panels.State = .{},
rows: std.ArrayList(panels.Row) = .empty,

/// The plugins' rail buttons, sorted by side. Filled from Galdr when its
/// revision changes and never per frame: see `fillRailButtons`.
rail_left: std.ArrayList(rails_mod.Extra) = .empty,
rail_right: std.ArrayList(rails_mod.Extra) = .empty,
rail_panels: std.ArrayList(rails_mod.PanelToggle) = .empty,
rails_for: u32 = std.math.maxInt(u32),

/// The plugins' settings as the page wants them. Same rule: filled when
/// Galdr's revision changes, and never on a frame path.
plugin_settings: std.ArrayList(settings_page.Option) = .empty,
settings_for: u32 = std.math.maxInt(u32),
rows_for: struct {
    which: rails_mod.Panel = .none,
    buffer: u32 = 0,
    revision: u64 = 0,
    contributions: u32 = 0,
    compared: usize = 0,
    filtered: u32 = 0,
} = .{},

/// What is written on the tabs, and the bytes those names point into.
///
/// Rebuilt when the bar would read differently and not once a frame: a
/// tab is named for the document its focused window is looking at, and
/// that changes when somebody makes it change. `tab_ends` is where each
/// name stops in `tab_text`, kept because appending to the text moves it
/// and a slice taken before the last name was written would be aimed at
/// freed bytes.
tab_names: If(caps.splits, std.ArrayList([]const u8)) = if (caps.splits) .empty else {},
tab_text: If(caps.splits, std.ArrayList(u8)) = if (caps.splits) .empty else {},
tab_ends: If(caps.splits, std.ArrayList(u32)) = if (caps.splits) .empty else {},
tabs_for: If(caps.splits, u64) = if (caps.splits) 0 else {},

/// The left rail's colours, filled when the highlight colour changes.
swatches: [keys.palette_size]rails_mod.Swatch = @splat(.{ .name = "", .color = .gray(0) }),

/// The accent a person configured, or null for the theme's own.
///
/// Kept apart from the theme so that `useTheme` can put it back on top of
/// whichever theme is chosen next: a reader who picked orange and then
/// switched to the light theme wants orange, not the light theme's blue.
chosen_accent: ?Color = null,

/// The colour the interface draws its own chrome in: the scrollbar thumb
/// and the focused window's border. The theme's accent, or the one that
/// was configured.
accent: Color = Theme.dark.accent,

/// The colour a highlight made without naming one is drawn in.
///
/// Not the accent, which is white by default. A highlight is composited
/// *over* the text it covers, so white at a highlight's alpha leaves the
/// paper exactly as white as it was and lifts the black type to a flat
/// grey: the reader sees the words fade rather than a block appear. A
/// mid-grey does the opposite -- it darkens the paper to about four
/// fifths and leaves the type near black -- which is the block a
/// highlighter actually makes. Setting `accent` replaces this too, so a
/// reader who chose a colour still gets it.
highlight: Color = .gray(0.42),

/// Mímir, if this build has a database.
///
/// `?noreturn` when it has not, which is the whole mechanism: an optional
/// that can only ever be null, so every `s.library orelse return` below
/// is a comptime `return` and not a branch taken on a null at run time.
/// The schema, the statements and the colour parsing behind them are then
/// unreferenced, and the exclusion is real rather than nominal. Do not
/// "simplify" this to `?Library` with a runtime null: that is the version
/// that compiles Mímir into a binary which can never use it.
library: ?LibraryIfStored = null,
/// False for `--shot`: settings still apply, the reading position does
/// not, and nothing is written back.
remembers_place: bool = true,

/// Set when the loop should end, by `q` on the last window or by `Q`.
quit: bool = false,

/// The selection made with the mouse, or null when there is none.
drag: ?cursor.Drag = null,

/// The pen, and the stroke it is in the middle of.
pen: ink.Pen = .{},
/// Where the pen has been since the button went down, in the user space
/// of `pen.page`. Held on the session and cleared rather than freed: a
/// reader drawing on a page makes a stroke a second and the buffer it
/// needs is the same buffer every time.
stroking: std.ArrayList(Point) = .empty,

/// The line between two windows, while it is being dragged.
split_drag: If(caps.splits, ?Layout.Divider) = if (caps.splits) null else {},

/// The highlight in hand in edit mode, by its session key.
focus_mark: ?u64 = null,
/// The comment in hand with it: the first on its anchor when the mark is
/// taken up, the one `]c` landed on after that. Asked through
/// `focusedComment`, which mends it when an undo has taken it away.
focus_comment: ?u64 = null,
/// What `c` leaves on the words it comments on: a highlight, or an arrow
/// for a reader who wants no colour on the text. The `comment_anchor`
/// setting, read when the reader starts and when it is changed.
comment_style: Marks.Style = .highlight,
/// What note mode will write on enter. Set as it begins, because the
/// keys that begin it mean different things: `a` the comment in hand,
/// `c` a new one.
typing: ?marks.Typing = null,
/// The mark `]a` or `]c` last landed on, and the caret that left.
last_jump: ?marks.Jumped = null,

/// `fenrir diff`'s comparison, when this reader is showing one. Buffer 0
/// is the first document and buffer 1 the second; see
/// `arrangeComparison`. Borrowed from the command, which outlives this.
///
/// `?noreturn` in a build with no comparison, for the reason given on
/// `library`: every `s.diff orelse return` becomes a comptime return and
/// the twenty-odd methods behind them leave the binary.
diff: ?ComparisonIfCompared = null,
/// Where each document's window was when the two were last held
/// together, to tell which one has moved. See `lockComparison`.
diff_seen: [2]compare.Seen = @splat(.{}),
/// The change `]d` last landed on, and where that left its window.
diff_at: ?struct { change: u32, side: u1, scroll: f32 } = null,
/// How the comparison is on screen. `gd` turns it.
diff_showing: compare.Showing = .side_by_side,
/// How far the second document is moved against the first, as last
/// nudged. The comparison's own offset is the one its regions were
/// found with, and catches up when `rerun` comes back.
diff_offset: [2]f32 = .{ 0, 0 },
rerun: compare.Rerun = .{},
/// Each document's scrollbar ticks, as fractions of its height, and the
/// zoom they were worked out at.
diff_ticks: [2]struct { zoom: f32 = 0, at: std.ArrayList(f32) = .empty } = @splat(.{}),
/// The note being typed in note mode. Written to the highlight on enter.
note: std.ArrayList(u8) = .empty,
/// Whether the last visual mode entered was `V`. Read after the key that
/// ends visual mode has already set the mode back to normal.
last_visual_line: bool = false,
/// A sentence for the title bar about what just happened -- "no
/// highlights to edit", "already at oldest change". Cleared by the next
/// key. The title bar is the only text this window draws.
status: []const u8 = "",
/// The process's `Io`, for timestamps. Null in tests.
io: ?Io = null,
/// `--time`'s startup stopwatch, borrowed from `run`. Null everywhere
/// else, which is every test and every session that did not ask for it.
stage: ?*frame.Stage = null,

/// Galdr, when this build has Lua and plugins were not turned off.
/// `?noreturn` when it has no plugin host at all; see `library`.
plugins: ?RuntimeIfScripted = null,
/// Where `init.lua` and `plugins/` are read from. Owned.
config_dir: ?[]u8 = null,
/// The `:` line being typed.
cmdline: std.ArrayList(u8) = .empty,
/// Where `status` points when the message is not a literal: a plugin's
/// `fenrir.notify`, or a command's answer.
status_buf: [512]u8 = undefined,
/// The mode and the count beside it, for the frame being built.
mode_buf: [96]u8 = undefined,
/// A highlight's colour as text, for the one `markAt` being answered.
hex_buf: [7]u8 = undefined,
/// Names as text, for the one highlight or comment being answered: an
/// anchor's, and a comment's own.
name_bufs: [2][Library.name_len]u8 = undefined,
/// The comments of one buffer in the order `]c` reads them, by index,
/// for `fenrir.comments()`; kept until the marks change, so a plugin
/// listing them asks for one sort and not one a row.
comment_order: std.ArrayList(usize) = .empty,
comment_order_for: struct { buffer: u32 = 0, revision: u64 = 0 } = .{},
/// What events were last reported with, so that the ones that are a
/// difference fire on a change and not on every frame.
///
/// `reported_doc` is which document the reports are *about*: page and
/// selection are differences within one document, so a move to another
/// is `DocEnter` and a new baseline rather than a page that appears to
/// have changed. `reported_window` is the same question for a window,
/// because two windows on one document are at two scrolls and the
/// baseline is the focused one's.
reported_doc: galdr.Host.Handle = galdr.Host.focused,
reported_window: u32 = std.math.maxInt(u32),
reported_page: u32 = std.math.maxInt(u32),
reported_mode: keys.Mode = .normal,
reported_selection: ?[2]galdr.Host.Position = null,

/// What each open document is called from Lua, in `buffers`' order.
///
/// Beside the list rather than on `Buffer`: a handle is what the plugin
/// API needs and a buffer is Hlidskjalf's, which knows nothing about
/// plugins. Handed out once each and never reused, so a handle a
/// handler kept over a yield names its own document or names nothing.
doc_handles: std.ArrayList(galdr.Host.Handle) = .empty,
next_doc_handle: galdr.Host.Handle = 0,

slots: [render.cache_slots]render.Slot = @splat(.{}),
stamp: u64 = 0,

dirty_title: bool = true,
shown: struct { buffer: u32 = 0, page: u32 = render.Slot.no_page, zoom: f32 = 0, windows: u32 = 0 } = .{},

pages_rendered: u64 = 0,

/// Pages that would not rasterise, so `firstMissing` stops asking for
/// them every frame. Small and forgetful on purpose: a page that failed
/// because memory was tight should get another chance eventually.
failures: [16]render.Job = @splat(.{ .buffer = 0, .page = render.Slot.no_page, .zoom = 0 }),
failure_next: usize = 0,

/// Scratch for `compose`, held rather than made fresh each time.
///
/// These three are rebuilt from nothing every frame -- the windows in
/// draw order, the lines between them, and the boxes a selection covers
/// -- and a reader scrolling at the refresh rate would otherwise ask the
/// allocator for them sixty times a second forever. Kept here they are a
/// few allocations for the life of the session. One window has no order to
/// be drawn in and no line between it and another.
order: If(caps.splits, std.ArrayList(u32)) = if (caps.splits) .empty else {},
borders: If(caps.splits, std.ArrayList(Bounds)) = if (caps.splits) .empty else {},
boxes: std.ArrayList(cursor.PageBox) = .empty,

pub fn deinit(s: *Session) void {
    s.rerun.finish();
    if (s.chrome) |c| c.destroy();
    // Before the buffers: a plugin's last handlers may still read them.
    if (s.plugins) |p| p.destroy();
    if (s.config_dir) |d| s.gpa.free(d);
    s.cmdline.deinit(s.gpa);
    s.search.deinit(s.gpa);
    s.note.deinit(s.gpa);
    s.comment_order.deinit(s.gpa);
    s.recorded.deinit(s.gpa);
    s.tabs.deinit(s.gpa);
    for (s.faces.items) |*c| c.deinit();
    s.faces.deinit(s.gpa);
    for (s.disks.items) |*d| d.deinit(s.gpa, s.io);
    s.disks.deinit(s.gpa);
    for (s.buffers.items) |*b| {
        b.doc.deinit();
        s.gpa.destroy(b.doc);
        b.deinit(s.gpa);
    }
    s.buffers.deinit(s.gpa);
    if (caps.splits) {
        s.order.deinit(s.gpa);
        s.borders.deinit(s.gpa);
        s.tab_names.deinit(s.gpa);
        s.tab_text.deinit(s.gpa);
        s.tab_ends.deinit(s.gpa);
    }
    s.boxes.deinit(s.gpa);
    s.stroking.deinit(s.gpa);
    s.rows.deinit(s.gpa);
    s.palette_rows.deinit(s.gpa);
    s.palette_text.deinit();
    s.doc_handles.deinit(s.gpa);
    s.rail_left.deinit(s.gpa);
    s.rail_right.deinit(s.gpa);
    s.plugin_settings.deinit(s.gpa);
    s.rail_panels.deinit(s.gpa);
    for (&s.diff_ticks) |*t| t.at.deinit(s.gpa);
}

// -- buffers -----------------------------------------------------------------

/// Opens a document and adds it to the list. The `Document` is on the
/// heap because a buffer holds a pointer to it and the list moves when
/// the next file is opened.
pub fn openBuffer(s: *Session, file: []const u8) !u32 {
    const gpa = s.gpa;

    // Held before it is read, so that nothing changes between the bytes
    // read and the file held; and its stamp taken before it is read, so
    // that a write during the read is noticed. Watched, it is never held
    // open at all, see `watch.load`, and is listened to from before the
    // stamp, so that no write falls between the two.
    var disk: watch.Disk = .{};
    errdefer disk.deinit(gpa, s.io);
    if (s.io) |io| {
        if (s.watching) {
            disk.notice = reload.noticeOf(s, file);
        } else {
            disk.hold = watch.Hold.take(io, file) catch |err| blk: {
                s.ctx.note("{s} is not held ({t}): another program may change it", .{ file, err });
                break :blk null;
            };
        }
        disk.held = watch.stat(io, file) orelse .{};
        disk.seen = disk.held;
    }

    // With `gpa` and not `ctx.gpa`: `Document` owns these bytes and frees
    // them with the allocator it was opened with.
    const bytes = try s.ctx.readFileWith(gpa, file);

    const doc = try gpa.create(fenrir.Document);
    errdefer gpa.destroy(doc);
    doc.* = try fenrir.open(gpa, bytes);
    errdefer doc.deinit();

    const pages = try fenrir.pages.all(doc);
    if (pages.len == 0) return error.NoPages;

    const path = absolutePath(s.ctx, gpa, file) orelse return error.OutOfMemory;
    errdefer gpa.free(path);

    // Appended together and in this order, because `faces` is indexed by
    // buffer id and a buffer with no cache beside it would be looked up
    // out of bounds on its first page.
    try s.faces.append(gpa, .init(gpa));
    errdefer _ = s.faces.pop();
    try s.disks.append(gpa, disk);
    errdefer _ = s.disks.pop();

    try s.buffers.append(gpa, .{
        .path = path,
        .title = std.fs.path.basename(path),
        .doc = doc,
        .pages = pages,
        // A table of contents that will not parse is no table of
        // contents, and never a document that will not open.
        .outline = fenrir.outline.all(doc, pages) catch &.{},
    });

    s.next_doc_handle += 1;
    try s.doc_handles.append(gpa, s.next_doc_handle);

    const id: u32 = @intCast(s.buffers.items.len - 1);
    marks.loadMarks(s, id);
    s.rememberFileId(path, doc);
    if (s.stage) |g| g.mark("document");
    marks.readAnnots(s, id, null);
    if (s.stage) |g| g.mark("annotations");
    return id;
}

/// The path a document is remembered under: absolute, so the same file opened
/// from two different directories is one entry in the library rather than
/// two. Falls back to what was typed, which still remembers something.
fn absolutePath(ctx: *Context, gpa: Allocator, file: []const u8) ?[]u8 {
    if (Io.Dir.cwd().realPathFileAlloc(ctx.io, file, gpa)) |real| {
        // Copied, and the original freed as the `[:0]u8` it is. Returning it
        // as a plain slice would hand back a length one byte short of the
        // allocation, and freeing *that* is an invalid free -- which is
        // exactly how this line failed the first time it ran.
        defer gpa.free(real);
        return gpa.dupe(u8, real) catch null;
    } else |_| {}
    return gpa.dupe(u8, file) catch null;
}

/// Writes the document's `/ID` down beside its path, which is how a link
/// into it finds it again after it has been moved or sent.
///
/// Here, before any job for this buffer exists to race with: the
/// rasterising thread owns the `Document`, and `fileId` reads only the
/// trailer parsed on open.
fn rememberFileId(s: *Session, path: []const u8, doc: *const fenrir.Document) void {
    const lib = s.library orelse return;
    var hex: [Library.id_hex_len]u8 = undefined;
    lib.setFileId(path, Library.hexId(&hex, doc.fileId() orelse "")) catch {};
}

pub fn buffer(s: *Session, index: u32) *Buffer {
    return &s.buffers.items[index];
}

/// The tabpage on screen. Every window command means this one.
pub fn layout(s: *Session) *Arrangement {
    return if (caps.splits) s.tabs.current() else &s.tabs;
}

pub fn view(s: *Session) *View {
    return s.layout().current();
}

// -- what the library remembers ----------------------------------------------

/// Draws everything after this in `t`, with whatever accent is in force.
///
/// One place, so that a theme chosen at startup and one chosen with
/// `:set` take exactly the same path -- the failure otherwise is the one
/// where switching in the reader looks right and reopening does not.
pub fn useTheme(s: *Session, t: Theme) void {
    s.theme = if (s.chosen_accent) |c| t.withAccent(c) else t;
    s.accent = s.theme.accent;
    if (s.chrome) |c| c.theme = s.theme;
}

/// The theme the library remembers, or the one already in force. A name
/// nobody recognises is left alone rather than reported: `fenrir config`
/// refuses one at the moment it is typed, so a bad name in the database
/// was put there by hand and the reader still has to open.
pub fn rememberedTheme(s: *Session) Theme {
    const lib = s.library orelse return s.theme;
    const name = (lib.theme() catch null) orelse return s.theme;
    defer s.gpa.free(name);
    return Theme.byName(name) orelse s.theme;
}

/// Takes from the library where this document was left, and puts the view
/// there. Returns the place if there was one.
///
/// `--page` and `--zoom` win: an explicit argument is a person saying
/// where to start, and remembering over the top of that is the kind of
/// helpfulness that has to be fought.
pub fn restore(s: *Session, v: *View, index: u32, page_given: bool, zoom_free: bool) ?View.Place {
    if (!s.remembers_place) return null;
    const lib = s.library orelse return null;
    const b = s.buffer(index);

    const seen = (lib.lastSeen(b.path) catch null) orelse return null;
    defer lib.freeRecent(seen);

    if (zoom_free and seen.zoom > 0) {
        v.zoom = std.math.clamp(seen.zoom, min_zoom, max_zoom);
        v.fit_on_open = false;
    }
    if (page_given or seen.page >= b.pages.len) return null;
    if (seen.page == 0 and seen.offset <= 0) return null;

    const place: View.Place = .{ .page = seen.page, .offset = seen.offset, .zoom = v.zoom };
    v.goTo(place);
    return place;
}

/// Writes down that a document was opened, and where.
pub fn remember(s: *Session, v: *View) void {
    if (!s.remembers_place) return;
    const lib = s.library orelse return;
    const b = s.buffer(v.buffer);
    lib.visit(b.path, b.title, placeOf(v), library_mod.now(s.ctx.io)) catch {};
}

/// Writes down where a window was left, without counting another opening.
pub fn rememberPlace(s: *Session, v: *View) void {
    if (!s.remembers_place) return;
    const lib = s.library orelse return;
    const b = s.buffer(v.buffer);
    lib.leaveAt(b.path, placeOf(v)) catch {};
}

fn placeOf(v: *View) Library.Place {
    const p = v.place();
    return .{ .page = p.page, .offset = p.offset, .zoom = p.zoom };
}

/// On the way out: every open window's place, oldest window first, so the
/// focused one is written last and wins for a document open twice.
pub fn rememberAll(s: *Session) void {
    if (!s.remembers_place) return;
    // Every tabpage, not only the one on screen: a window on a tab
    // nobody has looked at since morning was still left somewhere.
    var it = s.tabs.iterator();
    while (it.next()) |v| {
        if (v == s.layout().current()) continue;
        s.rememberPlace(v);
    }
    s.rememberPlace(s.layout().current());
}

/// A comment is a line of text on a highlight, not an essay. Bounded so
/// that a key held down does not fill the title bar, and the database,
/// with a megabyte of one letter.
pub const max_note = 1024;

// -- the command line --------------------------------------------------------

/// Puts a message of any lifetime on the message line.
pub fn say(s: *Session, comptime fmt: []const u8, args: anytype) void {
    s.status = std.fmt.bufPrint(&s.status_buf, fmt, args) catch blk: {
        // Too long for the line: as much as fits.
        const n = @min(s.status_buf.len, fmt.len);
        @memcpy(s.status_buf[0..n], fmt[0..n]);
        break :blk s.status_buf[0..n];
    };
    s.dirty_title = true;
}

/// Runs a `:` command line. The built-in commands first, then the ones
/// plugins registered, so that a plugin cannot make `:q` mean something
/// else by accident.
///
/// The name is looked up in `hlidskjalf.commands`, which is the one place
/// a built-in is written down: `fenrir commands` prints that table and
/// the palette lists it, so a command that exists here and nowhere else
/// is not possible.
///
/// Who asked for a `:` line to run. A plugin's authority is not the
/// console's, and the reader is where the difference is known.
const Origin = enum { console, plugin };

/// Returns false when the line did nothing, having said why.
pub fn exec(s: *Session, raw: []const u8) bool {
    return s.execFrom(raw, .console);
}

pub fn execFrom(s: *Session, raw: []const u8, from: Origin) bool {
    const line = std.mem.trim(u8, raw, " \t");
    if (line.len == 0) return true;

    // `:12` is page 12, as it is line 12 in Vim.
    if (std.fmt.parseInt(u32, line, 10)) |page| {
        return s.goToPage(page);
    } else |_| {}

    const space = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const name = line[0..space];
    const args = std.mem.trim(u8, line[space..], " \t");
    const v = s.view();

    const entry = commands.find(name) orelse {
        if (s.plugins) |rt| {
            if (rt.runCommand(name, args)) |ran| return ran;
        }
        return s.absent(name);
    };

    switch (entry.id) {
        .quit => {
            if (!caps.splits or !windows.closeWindow(s)) s.quit = true;
        },
        .quit_all => s.quit = true,
        .split => if (caps.splits) windows.splitWindow(s, .horizontal) else return s.absent(name),
        .vsplit => if (caps.splits) windows.splitWindow(s, .vertical) else return s.absent(name),
        .close => if (caps.splits) {
            _ = windows.closeWindow(s);
        } else return s.absent(name),
        .only => if (caps.splits) s.layout().only(s.gpa) else return s.absent(name),
        .tabnew => if (caps.splits) windows.newTab(s) else return s.absent(name),
        .tabclose => {
            if (!caps.splits) return s.absent(name);
            if (!windows.closeTab(s)) {
                s.say("this is the only tabpage; :q leaves the reader", .{});
                return false;
            }
        },
        .tabonly => if (caps.splits) s.tabs.only(s.gpa) else return s.absent(name),
        // `:tabnext` alone is the next one; with a number it is that one,
        // counted from 1 as a person counts the bar.
        .tabnext, .tabprevious => {
            if (!caps.splits) return s.absent(name);
            const back = entry.id == .tabprevious;
            if (args.len == 0) {
                windows.goTab(s, if (back) -1 else 1);
            } else if (std.fmt.parseInt(u32, args, 10)) |n| {
                if (n == 0 or n > s.tabs.count()) {
                    s.say("there is no tabpage {d}", .{n});
                    return false;
                }
                windows.showTab(s, n - 1);
            } else |_| {
                s.say(":{s} takes a tabpage number, or nothing", .{name});
                return false;
            }
        },
        .bnext => if (caps.splits) windows.showBuffer(s, 1) else return s.absent(name),
        .bprevious => if (caps.splits) windows.showBuffer(s, -1) else return s.absent(name),
        .reload => {
            if (s.diff != null) {
                s.say("a comparison does not reload", .{});
                return false;
            }
            if (v.buffer >= s.disks.items.len) return false;
            s.disks.items[v.buffer].reload = .forced;
        },
        .page => {
            // `:page 12`, `:page +2`, `:page -1`.
            const relative = args.len > 0 and (args[0] == '+' or args[0] == '-');
            const n = std.fmt.parseInt(i64, args, 10) catch {
                s.say(":page takes a number, or +N / -N", .{});
                return false;
            };
            const current: i64 = v.currentPage() + 1;
            const target = if (relative) current + n else n;
            return s.goToPage(@intCast(std.math.clamp(target, 1, @as(i64, @intCast(v.pages.len)))));
        },
        .zoom => {
            const percent = std.fmt.parseFloat(f32, std.mem.trimEnd(u8, args, "%")) catch {
                s.say(":zoom takes a percentage, like :zoom 150", .{});
                return false;
            };
            if (!(percent > 0) or !std.math.isFinite(percent)) return false;
            v.setZoom(v.hundredPercent() * percent / 100);
        },
        .fit => {
            // Bare `:fit` is the width, which is what it has always
            // meant and what it means in every other reader.
            const want: View.Fit = if (args.len == 0) .width else View.Fit.byName(args) orelse {
                s.say(":fit takes width, height, page or actual", .{});
                return false;
            };
            v.fitTo(want);
        },
        .set => return s.setOption(args),
        .settings => {
            s.settings.toggle();
            if (s.settings.open) interface.readSettings(s);
        },
        .palette => interface.showPalette(s),
        .undo => marks.undoMarks(s, false),
        .redo => marks.undoMarks(s, true),
        .marks => {
            if (std.mem.eql(u8, args, "clear")) {
                marks.clearMarks(s);
            } else {
                // Counted apart, because "7 marks" does not say whether
                // somebody highlighted seven sentences or drew seven
                // lines, and those are the question being asked.
                var strokes: usize = 0;
                for (s.buffer(v.buffer).marks.items()) |m| {
                    if (m.kind == .ink) strokes += 1;
                }
                const all = s.buffer(v.buffer).marks.count();
                s.say("{d} highlights and {d} lines of ink in this document", .{ all - strokes, strokes });
            }
        },
        .mnext => marks.jumpMark(s, .{ .forwards = true }),
        .mprevious => marks.jumpMark(s, .{ .forwards = false }),
        .cnext => marks.jumpMark(s, .{ .forwards = true, .comments = true }),
        .cprevious => marks.jumpMark(s, .{ .forwards = false, .comments = true }),
        .filter => {
            s.panel.setFilter(args);
            if (s.chrome) |c| c.rails.show(.annotations);
            const filter = marks.markFilter(s);
            if (filter.isEmpty()) {
                s.status = "no filter: every mark is shown, and ]a walks them all";
            } else {
                const b = s.buffer(v.buffer);
                var n: usize = 0;
                for (b.marks.items()) |m| n += @intFromBool(filter.matches(m, b.marks.said(m.anchor)));
                s.say("{d} of {d} marks match", .{ n, b.marks.count() });
            }
        },
        .dnext => compare.jumpChange(s, true),
        .dprevious => compare.jumpChange(s, false),
        .diff => {
            if (args.len == 0) {
                if (s.diff == null) {
                    s.status = "nothing is being compared -- fenrir diff A B";
                } else s.say("{s}", .{s.diff_showing.label()});
                return false;
            }
            if (std.mem.startsWith(u8, args, "offset")) {
                // `:diff offset X Y` in points, or nothing to put it back.
                var it = std.mem.tokenizeScalar(u8, args["offset".len..], ' ');
                const x = it.next() orelse {
                    compare.setOffset(s, .{ 0, 0 });
                    return false;
                };
                const y = it.next() orelse "0";
                const dx = std.fmt.parseFloat(f32, x) catch null;
                const dy = std.fmt.parseFloat(f32, y) catch null;
                if (dx == null or dy == null) {
                    s.status = ":diff offset takes two numbers of points, across and down";
                    return false;
                }
                compare.setOffset(s, .{ dx.?, dy.? });
                return false;
            }
            const want = compare.Showing.byName(args) orelse {
                s.say(":diff takes side, overlay, first, second or offset X Y", .{});
                return false;
            };
            compare.showComparison(s, want);
        },
        .lua => {
            // Not from a plugin. `:lua` is arbitrary Lua at the
            // console's authority, so a plugin that asked for `ui`
            // alone would have the whole table back through
            // `fenrir.exec` -- which is why `exec` carries who asked.
            if (from == .plugin) {
                s.say(":lua is the console's and not a plugin's", .{});
                return false;
            }
            const rt = s.plugins orelse {
                s.say("plugins are off in this reader", .{});
                return false;
            };
            return rt.runString(":lua", args);
        },
        .messages => {
            const rt = s.plugins orelse {
                s.say("plugins are off in this reader", .{});
                return false;
            };
            if (rt.messages.items.len == 0) {
                s.say("no messages", .{});
            } else {
                // The title bar holds one line; stderr has them all.
                for (rt.messages.items) |m| s.ctx.note("{s}", .{m});
                const last = rt.messages.items[rt.messages.items.len - 1];
                s.say("{d} messages, the last: {s}", .{
                    rt.messages.items.len,
                    std.mem.sliceTo(last, '\n')[0..@min(std.mem.sliceTo(last, '\n').len, 300)],
                });
            }
        },
        .plugins => {
            const rt = s.plugins orelse {
                s.say("plugins are off in this reader", .{});
                return false;
            };
            plugins_mod.sayPlugins(s, rt);
        },
        .plugin => {
            const rt = s.plugins orelse {
                s.say("plugins are off in this reader", .{});
                return false;
            };
            if (args.len == 0) {
                plugins_mod.sayPlugins(s, rt);
                return true;
            }
            // The lifecycle verbs are the console's, for the reason
            // `:lua` is: a plugin that could reload itself would be
            // running its own chunk underneath its own call, and one
            // that could unload another would be deciding what else the
            // reader runs.
            if (from == .plugin) {
                s.say(":plugin load, unload and reload are the console's", .{});
                return false;
            }
            return plugins_mod.lifecycle(s, rt, args);
        },
        .echo => s.say("{s}", .{args[0..@min(args.len, 400)]}),
    }
    return true;
}

/// What a `:` line naming nothing gets, and so does one naming a command
/// this build left out: `:sp` in a reader with one window is not refused,
/// there being nothing to refuse. It is simply not there.
fn absent(s: *Session, name: []const u8) bool {
    s.say("not a command: {s}", .{name[0..@min(name.len, 64)]});
    return false;
}

/// `:set theme=light`, and `:set theme` to be told what it is.
///
/// Vim's spelling, and Vim's division: a setting is a name and a value,
/// not a command per setting. There is one of them today and the shape is
/// here for the next; `fenrir config` is the same table from outside the
/// reader, and both go through `Theme.byName` so a name that works in one
/// works in the other.
///
/// What is set is written down. A theme chosen in the reader and lost on
/// the way out would be a theme nobody chooses twice.
fn setOption(s: *Session, args: []const u8) bool {
    if (args.len == 0) {
        s.say("theme = {s}", .{s.theme.name});
        return true;
    }

    const eq = std.mem.indexOfScalar(u8, args, '=') orelse {
        if (std.mem.eql(u8, args, "comment_anchor")) {
            s.say("comment_anchor = {s}", .{@tagName(s.comment_style)});
            return true;
        }
        if (std.mem.eql(u8, args, "watch")) {
            s.say("watch = {s}", .{if (s.watching) "on" else "off"});
            return true;
        }
        if (!std.mem.eql(u8, args, "theme")) {
            s.say("no setting called {s}", .{args[0..@min(args.len, 48)]});
            return false;
        }
        s.say("theme = {s}", .{s.theme.name});
        return true;
    };

    const name = std.mem.trim(u8, args[0..eq], " \t");
    const value = std.mem.trim(u8, args[eq + 1 ..], " \t");
    // Through the settings page's door, which checks it, applies it and
    // writes it down, so `:set` and a click cannot disagree.
    if (std.mem.eql(u8, name, "comment_anchor") or std.mem.eql(u8, name, "watch")) {
        if (name[0] == 'c' and marks.commentStyleNamed(value) == null) {
            s.say("comment_anchor is highlight or arrow, not {s}", .{value[0..@min(value.len, 48)]});
            return false;
        }
        if (name[0] == 'w' and !std.mem.eql(u8, value, "on") and !std.mem.eql(u8, value, "off")) {
            s.say("watch is on or off, not {s}", .{value[0..@min(value.len, 48)]});
            return false;
        }
        for (settings_page.builtin, 0..) |opt, i| {
            if (std.mem.eql(u8, opt.key, name)) interface.changeSetting(s, .{ .key = opt.key, .value = value, .index = i });
        }
        return true;
    }
    if (!std.mem.eql(u8, name, "theme")) {
        s.say("no setting called {s}", .{name[0..@min(name.len, 48)]});
        return false;
    }

    const t = Theme.byName(value) orelse {
        s.say("no theme called {s}: there is dark and light", .{value[0..@min(value.len, 48)]});
        return false;
    };
    s.useTheme(t);
    if (s.library) |l| l.setTheme(t.name) catch {};
    s.say("theme = {s}", .{t.name});
    return true;
}

pub fn goToPage(s: *Session, page: u32) bool {
    const v = s.view();
    if (page < 1 or page > v.pages.len) {
        s.say("page {d}: this document has {d} pages", .{ page, v.pages.len });
        return false;
    }
    v.scrollToPage(page - 1);
    return true;
}

// -- input -------------------------------------------------------------------

/// Returns true when the reader should close.
///
/// The interface gets first refusal on the frame. While a menu is open it
/// owns the pointer and the arrows, escape and enter, and the page must
/// not also act on them -- escape would leave visual mode and the arrows
/// would scroll the document out from under the menu. The chrome is built
/// after this runs, so the question is asked of the menu's *state*, which
/// the chrome keeps for exactly this reason, and not of a box tree that
/// does not exist yet.
pub fn handle(s: *Session, in: lyngvi.Input) bool {
    compare.collectRerun(s);
    if (s.interfaceHasInput()) {
        var it = s.layout().iterator();
        while (it.next()) |v| v.clampScroll();
        return s.quit;
    }
    s.pointer(in);

    const bindings = if (s.plugins) |rt| rt.lookup() else null;
    const result = keys.commandWith(&s.keymap, in, bindings);
    if (result.items().len != 0) {
        s.status = "";
        s.dirty_title = true;
    }
    for (result.items()) |cmd| {
        if (s.apply(cmd)) return true;
    }
    marks.applyEffects(s);
    compare.lockComparison(s);

    var it = s.layout().iterator();
    while (it.next()) |v| v.clampScroll();
    plugins_mod.reportChanges(s);
    return s.quit;
}

/// Whether the interface is holding this frame's keyboard and pointer.
///
/// True while a menu or the settings page is open. Both are built after
/// `handle` runs, so the question is asked of their *state* rather than
/// of a box tree that does not exist yet -- which is why that state is
/// the caller's in both files rather than living in the tree.
pub fn interfaceHasInput(s: *const Session) bool {
    if (s.settings.open or s.palette.open) return true;
    // The search bar is the one of these that gives the keyboard *back*:
    // enter drops focus so `n` and `N` step the matches while the count
    // stays on screen. So the question is whether the field has it, not
    // whether the bar is open -- and the answer is last frame's, for the
    // same reason the rest of this function's answers are.
    if (s.find.typing or s.panel.typing) return true;
    const c = s.chrome orelse return false;
    return c.grabbing();
}

/// One command. Returns true when the reader should close.
///
/// Separate from `handle` so that tests can drive the reader with the
/// commands a keystroke would produce, without inventing keystrokes.
pub fn apply(s: *Session, cmd: keys.Command) bool {
    const v = s.view();
    switch (cmd) {
        .none => {},
        .quit => if (!caps.splits or !windows.closeWindow(s)) return true,
        .quit_all => return true,

        // The window keys do nothing in a build with one window, as
        // `<C-w>j` does nothing in Vim with no window below.
        .split => |dir| if (caps.splits) windows.splitWindow(s, dir),
        .close_window => if (caps.splits) {
            _ = windows.closeWindow(s);
        },
        .only_window => if (caps.splits) s.layout().only(s.gpa),
        .focus_side => |side| if (caps.splits) {
            _ = s.layout().focusSide(side);
        },
        .cycle_window => |back| if (caps.splits) s.layout().cycle(s.gpa, back),
        .equalise => if (caps.splits) s.layout().equalise(),

        .new_tab => if (caps.splits) windows.newTab(s),
        .close_tab => if (caps.splits) {
            _ = windows.closeTab(s);
        },
        .go_tab => |delta| if (caps.splits) windows.goTab(s, delta),
        .window_to_tab => if (caps.splits) windows.windowToTab(s),

        .diff_view => |delta| compare.turnComparison(s, delta),
        .nudge => |by| compare.nudge(s, by),

        .next_buffer => if (caps.splits) windows.showBuffer(s, 1),
        .previous_buffer => if (caps.splits) windows.showBuffer(s, -1),

        // Straight through. The wheel already arrives in document pixels:
        // the platform layer multiplied the notch by the system's line
        // count and the display scale, and multiplying again here by a
        // "line" of sixty was what made one notch jump most of a page.
        .scroll_pixels => |n| v.scroll += n,
        .scroll_screens => |n| v.scroll += n * v.height() * 0.9,
        .to_start => v.scroll = 0,
        .to_end => v.scroll = v.maxScroll(),
        .next_page => v.scrollToPage(@min(v.currentPage() + 1, v.pages.len - 1)),
        .previous_page => v.scrollToPage(v.currentPage() -| 1),

        .zoom_by => |f| v.setZoom(v.zoom * f),
        .zoom_to => |f| v.setZoom(v.hundredPercent() * f),
        .fit => |want| v.fitTo(want),

        .move_cursor => |step| cursor.moveCursor(s, step),
        .hide_cursor => {
            // Escape puts the selection away, then the caret, and closes
            // last -- each step is something the reader can see undone,
            // so leaving is never the same key as leaving cursor mode.
            if (s.drag != null) {
                s.drag = null;
            } else if (s.find.open) {
                // The search bar hands the keyboard back on enter, so
                // this is the escape that ends a search somebody has
                // stopped typing into. Before the caret, because the
                // highlights are the louder thing on the page.
                search_mod.endSearch(s);
            } else if (v.cursor.visible) {
                v.cursor.visible = false;
            } else return true;
        },

        .enter_visual, .enter_visual_line => {
            s.last_visual_line = cmd == .enter_visual_line;
            _ = cursor.ensureCursor(s);
            if (v.anchor == null) v.beginSelection();
        },
        .enter_edit => marks.enterEdit(s),
        .enter_draw => {
            // Whatever was selected is not selected any more: the next
            // drag is a stroke, so a selection left on screen would be a
            // thing the mouse could no longer change.
            cursor.clearSelection(s);
            s.say("pen {d:.1}pt -- drag to draw, d or escape to stop", .{s.pen.width});
        },
        .enter_note => marks.beginNote(s),
        .add_comment => marks.beginComment(s),
        .leave_mode => {
            cursor.clearSelection(s);
            ink.penCancel(s);
            s.note.clearRetainingCapacity();
            s.cmdline.clearRetainingCapacity();
            s.typing = null;
            if (s.keymap.mode == .normal) {
                s.focus_mark = null;
                s.focus_comment = null;
            }
        },

        .swap_selection_ends => {
            const other = v.swapSelectionEnds() orelse return false;
            if (s.buffer(v.buffer).textMap(other.page)) |map| v.cursorTo(other, map);
            v.scrollToCursor();
        },
        .highlight_selection => |colour| marks.highlightSelection(s, colour, .highlight),
        .style_selection => |style| marks.highlightSelection(s, null, style),
        .yank_selection => {
            // The selection goes and nothing is written: a selection is
            // the interface's, never a mark, whichever key ends it.
            cursor.clearSelection(s);
            s.status = "nothing copied -- there is no clipboard yet; m highlights";
        },
        .unhighlight_selection => marks.unhighlightSelection(s),
        .comment_selection => marks.commentSelection(s),

        .toggle_highlight => marks.toggleMark(s),
        .clear_highlights => marks.clearMarks(s),

        // Edit mode's `n` and `N` are `]a` and `[a`: they walk what the
        // filter lets through. The author asked for this -- don't give
        // them a walk of their own over every mark again, or the panel
        // shows one set and `n` steps through another.
        .next_mark => marks.jumpMark(s, .{ .forwards = true }),
        .previous_mark => marks.jumpMark(s, .{ .forwards = false }),
        .jump_mark => |j| marks.jumpMark(s, j),
        .jump_change => |forwards| compare.jumpChange(s, forwards),
        .recolour_mark => |colour| marks.recolourMark(s, colour),
        .restyle_mark => |style| marks.restyleMark(s, style),
        .delete_mark => marks.deleteMark(s),

        .pen_colour => |colour| ink.setPenColour(s, colour),
        .pen_width => |factor| ink.setPenWidth(s, factor),

        .note_char => |c| marks.noteChar(s, c),
        .note_backspace => marks.noteBackspace(s),
        .note_commit => marks.commitNote(s),

        .enter_command => s.cmdline.clearRetainingCapacity(),
        .command_char => |c| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch return false;
            if (s.cmdline.items.len + n <= max_note) s.cmdline.appendSlice(s.gpa, buf[0..n]) catch {};
        },
        .command_backspace => {
            var n = s.cmdline.items.len;
            if (n == 0) {
                // Backspace on an empty line leaves it, as in Vim.
                s.keymap.mode = .normal;
                return false;
            }
            n -= 1;
            while (n > 0 and s.cmdline.items[n] & 0xc0 == 0x80) n -= 1;
            s.cmdline.shrinkRetainingCapacity(n);
        },
        .command_run => {
            // Copied out first: the command may be `:lua` code that opens
            // another command line, which would clear this one under it.
            var copy: [max_note]u8 = undefined;
            const len = s.cmdline.items.len;
            @memcpy(copy[0..len], s.cmdline.items);
            s.cmdline.clearRetainingCapacity();
            _ = s.exec(copy[0..len]);
            return s.quit;
        },
        .show_commands => interface.showPalette(s),

        .enter_search => search_mod.beginSearch(s),
        .search_step => |back| {
            // `n` is the next page until a search is live. See the note
            // on `keys.Command.search_step`.
            if (s.search.isEmpty()) {
                v.scrollToPage(if (back)
                    v.currentPage() -| 1
                else
                    @min(v.currentPage() + 1, v.pages.len - 1));
            } else search_mod.stepSearch(s, back);
        },
        .plugin_key => |id| if (s.plugins) |rt| rt.runKeymap(id),

        .undo => marks.undoMarks(s, false),
        .redo => marks.undoMarks(s, true),
    }
    return false;
}

/// What the status bar's zoom control asked for, carried out.
///
/// The bar names a fit with the same word `:fit` takes, so the two ways
/// in parse it in one place and a menu row cannot drift from the command
/// that does the same thing.
pub fn applyZoom(s: *Session, want: chrome_mod.ZoomWant) void {
    const v = s.view();
    switch (want) {
        .fit => |name| v.fitTo(View.Fit.byName(name) orelse return),
        .percent => |p| v.setZoom(v.hundredPercent() * p / 100),
    }
    s.dirty_title = true;
}

/// The pointer: which window it is in, the scrollbar, and the page.
///
/// Dragging over text selects it, and the selection stays put when the
/// button is let go until the next press anywhere puts it away -- text
/// selection the way a browser does it. `m` is what turns one into a
/// highlight. In edit mode a press on a highlight takes hold of it
/// instead.
pub fn pointer(s: *Session, in: lyngvi.Input) void {
    const down = in.buttons.left;
    const pressed = down and !s.view().was_down;

    // The one place the interface and the page share pixels. A rail is
    // reserved space and can never be both; a panel floats over the
    // document, so the press that lands in it has to be kept off the text
    // underneath -- and `rect` is last frame's, which is the rectangle
    // that was there when the button went down.
    if (s.panel.holds(in.mouse) or s.find.holds(in.mouse.x, in.mouse.y)) {
        s.view().was_down = down;
        return;
    }

    // Before anything else: a gesture that began on the line between two
    // windows belongs to that line until it is let go.
    if (caps.splits and windows.dragSplit(s, in, down, pressed)) return;

    // Then the pen, which claims the whole gesture the way a divider
    // does -- a stroke that stopped because the pointer crossed a mark or
    // ran off the page would be a line with a hole in it.
    if (s.keymap.mode == .draw or s.pen.down) {
        ink.drawPointer(s, in, down, pressed);
        s.view().was_down = down;
        return;
    }

    // A press begins a new gesture, so whatever was selected stops being
    // selected -- and it happens here, before anything below can read
    // `s.drag` and take the last gesture's selection for this one's.
    if (pressed) {
        s.drag = null;
        if (caps.splits) _ = s.layout().focusAt(in.mouse);
    }

    // Every window's scrollbar is live, not only the focused one's: a
    // thumb you can see and cannot drag is worse than no thumb.
    var handled = false;
    var it = s.layout().iterator();
    while (it.next()) |v| {
        const inside = v.rect.contains(in.mouse) or v.dragging != null;
        if (v.dragScrollbar(if (inside) in.mouse else .{ .x = -1e9, .y = -1e9 }, down and inside)) {
            handled = true;
        }
    }
    if (handled) {
        s.drag = null;
        return;
    }

    const v = s.view();
    if (!down) {
        // Letting go keeps the words selected. A drag that never left the
        // glyph it started on is a click, and a click selects nothing.
        //
        // And nothing is written. This used to make the drag a highlight
        // in the database, and the author asked for it gone: a selection
        // belongs to the interface. Do not "save the user a keypress" by
        // highlighting here -- `m` is the keypress.
        if (s.drag) |*d| {
            if (std.meta.eql(d.from, d.to)) s.drag = null else d.held = false;
        }
        return;
    }

    if (s.drag) |*d| {
        if (d.buffer == v.buffer) {
            if (cursor.positionAt(s, v, in.mouse)) |p| {
                d.to = p;
                cursor.carryCursor(s, v, p);
            }
        }
        return;
    }
    if (!pressed) return;

    const page = v.pageAt(in.mouse) orelse return;
    const user = v.userSpaceAt(page, in.mouse) orelse return;
    const b = s.buffer(v.buffer);

    if (b.marks.at(page, user)) |index| {
        const key = b.marks.items()[index].key;
        if (s.keymap.mode == .edit) {
            marks.focusMark(s, key);
        } else {
            // A press on a highlight takes it away, the eraser on the end
            // of the highlighter. `u` puts it back.
            b.marks.beginGroup();
            _ = b.marks.removeAt(s.gpa, index) catch {};
            marks.applyEffects(s);
        }
        s.dirty_title = true;
        return;
    }

    const p = cursor.positionAt(s, v, in.mouse) orelse return;
    s.drag = .{ .buffer = v.buffer, .from = p, .to = p };
    cursor.carryCursor(s, v, p);
}

/// What the mode line says, gathered from wherever the reader keeps it.
///
/// Every slice handed out either lives on the session or is a literal, so
/// the bar holds nothing it has to be given back: the note and the `:`
/// line are the session's own buffers, and the one thing that has to be
/// formatted -- which highlight is in hand, of how many -- goes into
/// `mode_buf` and is built afresh each frame rather than cached, because
/// it is under a hundred bytes and caching it would mean invalidating it.
pub fn statusLine(s: *Session) chrome_mod.Status {
    const v = s.view();
    const b = s.buffer(v.buffer);
    const mode = s.keymap.mode;

    var st: chrome_mod.Status = .{
        .mode = mode.label(),
        .message = s.status,
        .title = b.title,
        .page = v.currentPage() + 1,
        .pages = @intCast(v.pages.len),
        .percent = v.percent(),
        .fit = v.fit.label(),
        .windows = s.layout().count(),
    };

    switch (mode) {
        .note => st.typing = s.note.items,
        // The colon belongs to the line being typed and not beside it:
        // `:zoom 150` is one thing a person is writing, and a gap in the
        // middle of it would read as two.
        .command => {
            st.mode = "";
            var wr: std.Io.Writer = .fixed(&s.mode_buf);
            wr.print(":{s}", .{s.cmdline.items[0..@min(s.cmdline.items.len, 80)]}) catch {};
            st.typing = s.mode_buf[0..wr.end];
        },
        else => {},
    }

    // Edit and note mode say which highlight is in hand, in the order `n`
    // walks them, and edit mode shows what is written on it -- note mode
    // does not, because what is being typed is about to replace it.
    if ((mode == .edit or mode == .note) and marks.focusedMarkIndex(s) != null) {
        const held = b.marks.items()[marks.focusedMarkIndex(s).?];
        // Among what the filter lets through, which is what `n` walks;
        // among them all when the one in hand is not one of those -- a
        // click takes hold of any mark, and a recolour can take one out.
        var filter = marks.markFilter(s);
        if (!filter.matches(held, b.marks.said(held.anchor))) filter = .{};
        const at = b.marks.placeOf(held, &filter);
        var wr: std.Io.Writer = .fixed(&s.mode_buf);
        wr.print("{s} {d}/{d}", .{ mode.label(), at.place, at.of }) catch {};
        st.mode = s.mode_buf[0..wr.end];
        if (mode == .edit) {
            if (marks.focusedComment(s)) |c| st.note = b.marks.comments.items[c].text;
        }
    }

    return st;
}

pub fn updateTitle(s: *Session, window: lyngvi.Window) void {
    const v = s.view();
    const page = v.currentPage();
    const count = s.layout().count();
    if (!s.dirty_title and page == s.shown.page and v.zoom == s.shown.zoom and
        v.buffer == s.shown.buffer and count == s.shown.windows) return;

    s.dirty_title = false;
    s.shown = .{ .buffer = v.buffer, .page = page, .zoom = v.zoom, .windows = count };

    var buf: [1024]u8 = undefined;
    window.setTitle(s.titleText(&buf, page, count));
}

/// What the operating system's title bar says: the document, and where
/// you are in it.
///
/// It used to say a great deal more, because it was the only text this
/// window drew: the mode, the note being typed, which highlight was in
/// hand, the reason a key did nothing. All of that is in the status bar
/// now, where a person reading the page is already looking. What is left
/// here is what a title is actually for -- telling one window from
/// another in a task switcher, where the page you are on is useful and
/// the mode you are in is not.
fn titleText(s: *Session, buf: []u8, page: u32, count: u32) []const u8 {
    const v = s.view();
    const base = s.buffer(v.buffer).title;
    var w: std.Io.Writer = .fixed(buf);

    w.print("{s} -- page {d} of {d} -- {d:.0}%", .{
        base[0..@min(base.len, 160)], page + 1, v.pages.len, v.percent(),
    }) catch return buf[0..w.end];
    if (count > 1) w.print(" -- {d} windows", .{count}) catch return buf[0..w.end];
    return buf[0..w.end];
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const giveLibrary = fixtures.giveLibrary;
const sessionOf = fixtures.sessionOf;

test {
    // The files the session is split into, named so that their tests run
    // whichever of them this build's session reaches. A file whose tests
    // need a capability gates them itself: see `compare.comparison_tests`.
    _ = compare;
    _ = cursor;
    _ = frame;
    _ = ink;
    _ = interface;
    _ = marks;
    _ = plugins_mod;
    _ = reload;
    _ = render;
    _ = search_mod;
    if (caps.splits) _ = windows;
}

test "the status line carries the mode and what the mode has to show" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expectEqualStrings("", s.statusLine().mode);

    s.keymap.mode = .visual;
    try testing.expectEqualStrings("-- VISUAL --", s.statusLine().mode);

    marks.highlightBoxes(&s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.keymap.mode = .note;
    s.focus_mark = s.buffer(0).marks.items()[0].key;
    for ("hello") |c| marks.noteChar(&s, c);

    const noting = s.statusLine();
    try testing.expectEqualStrings("-- NOTE -- 1/1", noting.mode);
    try testing.expectEqualStrings("hello", noting.typing.?);

    // A `:` line belongs to the colon, not beside it.
    s.keymap.mode = .command;
    for ("zoom 150") |c| s.cmdline.append(gpa, c) catch unreachable;
    const typing = s.statusLine();
    try testing.expectEqualStrings("", typing.mode);
    try testing.expectEqualStrings(":zoom 150", typing.typing.?);
}

test "the title bar keeps the document and drops the mode line" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    s.keymap.mode = .visual;
    var title: [1024]u8 = undefined;
    const text_of = s.titleText(&title, 0, 1);
    try testing.expect(std.mem.indexOf(u8, text_of, "page 1 of 2") != null);
    try testing.expect(std.mem.indexOf(u8, text_of, "VISUAL") == null);
}

test "the place written down is where the reader was, to the point" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;

    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);

    // 150 pixels below the top of page 5, which at zoom 1 is 150 points.
    s.view().scroll = s.view().pageTop(5) + 150;

    // What the reader writes on the way out. Through `placeOf`, which is the
    // conversion being tested; `remember` itself only adds a clock.
    try lib.visit(s.buffer(0).path, "a.pdf", Session.placeOf(s.view()), 1);

    // Reopened at twice the zoom, the same *point* of the same page is at
    // the top -- which is the whole reason the offset is in points and not
    // in the pixels it was scrolled by.
    var other = try sessionOf(gpa, fakePages(&buf, 10), 2, 1000, 800);
    defer closeSession(&other);
    other.library = lib;

    const place = other.restore(other.view(), 0, false, false).?;
    try testing.expectEqual(@as(u32, 5), place.page);
    try testing.expectApproxEqAbs(@as(f32, 150), place.offset, 1.0);
    try testing.expectEqual(@as(u32, 5), other.view().currentPage());
    // 150 points at zoom 2 is 300 pixels below the top of the page.
    try testing.expectApproxEqAbs(
        other.view().pageTop(5) + 300,
        other.view().scroll,
        1.0,
    );
}

test "command lines: page numbers, relative pages, zoom, and unknown names" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(s.exec("7"));
    try testing.expectEqual(@as(u32, 6), s.view().currentPage());
    try testing.expect(s.exec("page +2"));
    try testing.expectEqual(@as(u32, 8), s.view().currentPage());
    try testing.expect(s.exec("page -1"));
    try testing.expectEqual(@as(u32, 7), s.view().currentPage());

    try testing.expect(!s.exec("99"));
    try testing.expect(std.mem.indexOf(u8, s.status, "10 pages") != null);

    try testing.expect(s.exec("zoom 200%"));
    try testing.expectApproxEqAbs(@as(f32, 200), s.view().percent(), 0.5);

    if (caps.splits) {
        try testing.expect(s.exec("vsplit"));
        try testing.expectEqual(@as(u32, 2), s.layout().count());
        try testing.expect(s.exec("q"));
        try testing.expectEqual(@as(u32, 1), s.layout().count());
        try testing.expect(!s.quit);
    } else {
        // Not refused: absent, in the words a name nobody registered gets.
        try testing.expect(!s.exec("vsplit"));
        try testing.expect(std.mem.indexOf(u8, s.status, "not a command") != null);
    }
    try testing.expect(s.exec("q"));
    try testing.expect(s.quit);

    try testing.expect(!s.exec("frobnicate now"));
    try testing.expect(std.mem.indexOf(u8, s.status, "frobnicate") != null);
}

test "a theme reaches the page's backdrop and not only the chrome" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    // Two of the three literals were already the dark theme's, to the
    // hundredth. The backdrop was not: it was `gray(0.16)`, which is the
    // *panel*, so the bar was the same grey as the ground it sat on. It is
    // `ground` now and a step darker, which is what the design language asks
    // for and what makes a bar read as a surface.
    try testing.expectApproxEqAbs(@as(f32, 0.08), s.theme.divider.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.45), s.theme.shadow.a, 0.01);
    try testing.expect(s.theme.ground.r < s.theme.panel.r);

    try testing.expect(s.exec("set theme=light"));
    try testing.expect(!s.theme.isDark());
    // The ground moves with it: a light interface over a near-black backdrop
    // is the half-applied theme this is here to catch.
    try testing.expect(s.theme.ground.r > 0.5);
    try testing.expect(s.theme.paper.r > 0.9);
}

test "the accent follows the theme, and a chosen one follows the reader" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    s.useTheme(.dark);
    try testing.expectEqual(Theme.dark.accent, s.accent);

    // Somebody picked orange. It survives the change of theme, because a
    // person choosing a colour has not also chosen to lose it.
    const orange: Color = .{ .r = 0.96, .g = 0.6, .b = 0.15 };
    s.chosen_accent = orange;
    s.useTheme(.light);
    try testing.expectEqual(orange, s.accent);
    try testing.expectEqual(orange, s.theme.accent);
}

test "an unknown setting or theme is refused, and changes nothing" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(!s.exec("set theme=solarised"));
    try testing.expectEqualStrings("dark", s.theme.name);
    try testing.expect(!s.exec("set wrap=on"));
    try testing.expectEqualStrings("dark", s.theme.name);

    // Asking rather than setting, both spellings.
    try testing.expect(s.exec("set theme"));
    try testing.expect(s.exec("set"));
}
