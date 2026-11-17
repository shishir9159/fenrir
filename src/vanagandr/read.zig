//! `fenrir read <file>...` -- the documents, in windows, scrollable.
//!
//! This is the command the rest of the project was for. Gjöll reads the file,
//! the interpreter turns each page into a display list, `gleipnir.replay`
//! rasterises or records it, Lyngvi opens a window and puts it on the screen,
//! and the loop below joins them.
//!
//! ## Buffers and windows
//!
//! The reader does not show *a document*. It holds a list of open documents
//! -- buffers -- and a tree of windows onto them, which is `hlidskjalf`. One
//! document can be in four windows at once; each has its own scroll, zoom and
//! cursor, and all four share the document's highlights, because the
//! highlights belong to the buffer. `<C-w>v` splits, `<C-w>c` closes,
//! `<C-w>hjkl` moves between them, as in Vim.
//!
//! Everything about *where* a window is looking lives in `hlidskjalf.View`
//! and is tested there without a device. What lives here is the part that
//! needs a document and a GPU: which pages to render, where to put the
//! pixels, and how to get out of the way of the rasterising thread.
//!
//! ## Where the page is drawn
//!
//! Two backends, chosen by `--path`:
//!
//!   **cpu** -- rasterised into an image and uploaded as a texture. Every
//!   feature the renderer has: all sixteen blend modes, antialiased clips,
//!   transparency groups. Costs a page of work per zoom change.
//!
//!   **gpu** -- the outlines go to the device and the fragment shader works
//!   out coverage from the curves. Resolution independent, so a zoom is a
//!   matrix and not a re-render, and a page is one draw call.
//!
//! ## Cost, and why there is a second thread
//!
//! A page costs one interpretation and one rasterisation: a couple of hundred
//! milliseconds for prose, a second for a page whose figure is a scatter plot
//! of several thousand separately clipped markers. Either number is far
//! longer than a frame, so rasterising on the frame thread would not make the
//! reader slow, it would make it *stop*. Rasterisation happens on a thread of
//! its own and the loop never blocks on it: it collects whatever finished,
//! uploads it, and draws. A page not ready yet is blank paper for a few
//! frames.
//!
//! One thread and not a pool, because it owns every `Document`. `Document.get`
//! fills an object cache, so it is not safe to call from two threads at once;
//! the worker is the only thread that touches one. The frame loop sees only
//! `pages`, which is resolved when the file is opened and never written
//! again, and the text maps and pixels the worker hands over.
//!
//! ## Memory
//!
//! The reader allocates from its own heap rather than from the CLI's arena.
//! Every other command is a short-lived process for which never freeing is
//! the right trade; a reader is not. A page's framebuffer is four floats per
//! pixel and its texture four bytes, so an arena would grow by tens of
//! megabytes per page scrolled past -- felt as a scroll that gets stickier
//! the longer you read.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const chrome_mod = @import("chrome.zig");
const config_mod = @import("config.zig");
const diff_mod = @import("diff.zig");
const glyphmod = @import("glyphs.zig");
const Images = @import("images.zig").Images;
const library = @import("library.zig");
const Library = library.Library;
const find_mod = @import("find.zig");
const palette_mod = @import("palette.zig");
const panels = @import("panels.zig");
const rails_mod = @import("rails.zig");
const settings_page = @import("settings.zig");
const watch = @import("watch.zig");

const compare = @import("read/compare.zig");
const cursor = @import("read/cursor.zig");
const ink = @import("read/ink.zig");
const interface = @import("read/interface.zig");
const marks = @import("read/marks.zig");
const plugins_mod = @import("read/plugins.zig");
const reload = @import("read/reload.zig");
const render = @import("read/render.zig");
const search_mod = @import("read/search.zig");
const windows = @import("read/windows.zig");

const content = fenrir.content;
const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const galdr = fenrir.galdr;
const hlidskjalf = fenrir.hlidskjalf;
const lyngvi = fenrir.lyngvi;
const thviti = fenrir.thviti;
const replay = gleipnir.replay;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const Point = gelgja.Point;
const DrawList = gleipnir.DrawList;
const Glyphs = glyphmod.Fonts;
const Scene = gleipnir.scene.Scene;

const Buffer = hlidskjalf.Buffer;
const Layout = hlidskjalf.Layout;
const Marks = hlidskjalf.Marks;
const Tabs = hlidskjalf.Tabs;
const View = hlidskjalf.View;
const commands = hlidskjalf.commands;
const keys = hlidskjalf.keys;
const search = hlidskjalf.search;
const text = hlidskjalf.text;
const Theme = thviti.Theme;

/// What this build contains. `-Dprofile` resolved it once in `build.zig`; the
/// help text, the options the parser accepts and the features the session has
/// are all read off the same answer, so none of the three can drift from the
/// others.
const caps = fenrir.build_options;

/// Which path rasteriser this binary has, from `-Dpath`.
const have_cpu = caps.path_cpu;
const have_gpu = caps.path_gpu;

/// Whether `--path` is a choice. With one rasteriser in the binary there is
/// nothing to choose, and the flag's answer is already the only answer.
const have_both = have_cpu and have_gpu;

/// What a feature this build left out is worth holding.
///
/// `noreturn` has no values, so `?noreturn` has exactly one -- null -- and
/// Zig folds `x orelse return` and `if (x) |y|` at comptime. That is what
/// turns "the reader checks whether it has a database" into "the reader has
/// no database and the code that used one is not in the binary". The field
/// types are the switch; the call sites below are written once and read
/// correctly either way.
const LibraryIfStored = if (caps.sqlite) Library else noreturn;
const ComparisonIfCompared = if (caps.compare) *diff_mod.Comparison else noreturn;
const RuntimeIfScripted = if (caps.lua) *galdr.Runtime else noreturn;
const BenchKind = if (caps.bench) Bench.Kind else noreturn;
const BenchDriver = if (caps.bench) Bench else noreturn;
const WrittenIfRead = if (caps.config) config_mod.Written else noreturn;

/// The help text, assembled from the parts this configuration has.
///
/// Composed rather than written out once because the alternative is a help
/// text that offers a flag the parser rejects. These are the same comptime
/// conditions the parser below reads, so the two cannot disagree -- and a
/// `light` binary's help is short because its surface is short, not because
/// something was hidden.
pub const usage = synopsis ++ view_flags ++
    (if (caps.bench) bench_flags else "") ++
    (if (caps.diagnostics) shot_flags else "") ++
    (if (caps.splits) split_flag else "") ++
    (if (have_both) path_flag else "") ++
    device_flags ++
    (if (caps.instruments) validate_flag else "") ++
    (if (caps.sqlite) db_flag else "") ++
    (if (caps.lua) plugin_flags else "") ++
    (if (caps.config) config_note else "") ++
    colon_commands ++
    (if (caps.splits) window_keys else "") ++
    normal_mode ++
    (if (caps.marks) mark_modes else "") ++
    closing;

const synopsis =
    \\fenrir <file>... [options]       -- `fenrir read <file>...` is the same
    \\
    \\    Opens the documents in a window and scrolls through them. More than
    \\    one file opens them as buffers; the first is shown and the rest are
    \\
++ (if (caps.splits)
    \\    reachable with <C-w>n.
    \\
    \\
else
    \\    reachable with :bn.
    \\
    \\
);

const view_flags =
    \\    --page N     Start at this page, numbered from 1. Without it, the
    \\                 place this document was last left at -- which is a page
    \\                 and how far down it, not just the page.
    \\    --zoom N     Device pixels per PDF point. 1.0 is 72 dpi. Without
    \\                 it the zoom this document was last read at, or the
    \\                 width of the window if it is new.
    \\    --dpi N      The same thing in the other unit.
    \\    --size WxH   The window's initial size.
    \\    --samples N  Multisampling for the page raster: 1, 2, 4 or 8.
    \\                 Defaults to 8.
    \\    --watch      Follow the file: when another program rewrites it, as
    \\                 a TeX build does, the new one takes its place at the
    \\                 first page that changed. Without it the file is held
    \\                 so that no other program can change it while it is
    \\                 open. The watch setting chooses; this is on for one
    \\                 session.
    \\
;

const bench_flags =
    \\    --frames N   Run N frames and exit, so the command can be scripted.
    \\    --time       How long startup took, stage by stage, and on exit
    \\                 what the frames cost: between frames, placing the
    \\                 paths, and on the device from its own timestamps.
    \\    --bench W    Drive the first window through a fixed workload and
    \\                 exit, with --time's report. scroll: the whole document
    \\                 a twentieth of a page a frame. zoom: 50% to the closest
    \\                 the reader goes and back, twice. flip: every page in
    \\                 turn. Each step waits for the pages it shows; that wait
    \\                 is reported apart.
    \\
;

const shot_flags =
    \\    --shot F     Write one composed frame to F as a PNG and exit. With
    \\                 --path cpu there is no window and no device: what the
    \\                 reader would look like, on a machine with no display
    \\                 and in a test. With --path gpu the frame is drawn by
    \\                 the device into a hidden window and read back, once
    \\                 every visible page is ready.
    \\    --device     With --shot and --path cpu: read the frame back from
    \\                 the device too, rather than modelling it.
    \\
;

const split_flag =
    \\    --split D    Start with the window split: v, h, or a repeat like
    \\                 vh. Mostly for scripting a screenshot of a layout.
    \\
;

const path_flag =
    \\    --path P     Which path rasteriser draws the page: cpu or gpu.
    \\                 Only what this build has; see -Dpath.
    \\
;

const device_flags =
    \\    --vsync      on (default), off, or adaptive.
    \\    --gpu NAME   Prefer a device whose name contains NAME.
    \\
;

const validate_flag =
    \\    --validate   Turn on the Khronos validation layers, if installed.
    \\
;

const db_flag =
    \\    --db FILE    Remember recent files, settings and highlights in FILE
    \\                 instead of the default. $FENRIR_DB does the same.
    \\
;

const plugin_flags =
    \\    --config DIR Read init.lua and plugins/ from DIR instead of the
    \\                 configuration directory. $FENRIR_CONFIG does the same.
    \\    --clean      Run no plugins and no init.lua.
    \\
;

const config_note =
    \\
    \\    fenrir.toml, in the directory fenrir starts in or else beside the
    \\    library, holds what would otherwise be typed every time: theme and
    \\    accent at the top, and under [read] the flags above by name, as in
    \\    zoom = 1.25 or vsync = "off", with a switch written as NAME = true.
    \\    A flag typed wins over one written there; nothing writes the file.
    \\
;

const colon_commands =
    \\
    \\commands, after : in normal mode:
    \\    :12                  page 12
    \\    :page +2, :page -1   pages forward and back
    \\    :zoom 150, :fit page a zoom, or the width, the height or a page
    \\    :set theme=light     the colours the interface is drawn in
    \\    :settings            all of them, as a page over the document
    \\    :reload, :e!         read the document again from its file
    \\
++ (if (caps.splits)
    \\    :sp, :vs, :close     split below, split beside, close the window
    \\    :only, :bn, :bp      close the others, next / previous document
    \\    :tabnew, :tabclose   a tabpage of this window, close this tabpage
    \\    :tabonly             close every other tabpage
    \\    :tabn, :tabp         next / previous tabpage; with N, that one
    \\
else
    \\    :bn, :bp             next / previous document
    \\
) ++
    \\    :q, :qa              close the window, close the reader
    \\
++ (if (caps.marks)
    \\    :undo, :redo         the history of the marks
    \\    :marks, :marks clear how many marks, or remove them all
    \\    :filter WORDS        only the marks that match, in the panel and to
    \\                         ]a: a colour, a style, ink, commented, or words
    \\                         in a comment; with no words, every mark again
    \\
else "") ++ (if (caps.lua)
    \\    :lua CODE            run Lua, with the fenrir table
    \\    :plugins, :messages  what loaded, and what went wrong
    \\    :plugin reload NAME  that plugin again, from nothing; also load,
    \\                         unload
    \\    :Name ARGS           a command a plugin registered
    \\
else "") ++
    \\    :echo TEXT           show TEXT
    \\
;

const window_keys =
    \\
    \\windows:
    \\    <C-w>v  <C-w>s       split beside / below
    \\    <C-w>c, <C-w>q       close this window
    \\    <C-w>o               close every other window
    \\    <C-w>h j k l         go to the window that way
    \\    <C-w>w, <C-w>W       the next / previous window
    \\    <C-w>=               make them all the same size
    \\    <C-w>n, <C-w>b       show the next / previous open document here
    \\
    \\tabpages -- each one its own arrangement of windows:
    \\    gt, gT               the next / previous tabpage
    \\    <C-w>T               move this window into a tabpage of its own
    \\    the bar at the top   appears as soon as there are two
    \\
;

const normal_mode =
    \\
    \\normal mode (reading):
    \\    drag the scrollbar   scroll; a press on the track moves a screen
    \\    wheel, ctrl+wheel    scroll, zoom
    \\    arrows, h j k l      move the cursor; the page follows it
    \\    w / b / e            the next word, the word before, the word's end
    \\    ^ / $                the start and end of the line
    \\    escape               put the cursor away
    \\    page up / page down  a screen at a time
    \\    home / end           the first and last page
    \\    space / p            the next and previous page
    \\    /                    search the document; escape ends it
    \\    n / N                the next and previous match, or the next and
    \\                         previous page when nothing is being searched for
    \\    drag over text       select it; a click puts the selection away
    \\
++ (if (caps.marks)
    \\    m                    highlight the selection, or the cursor's line,
    \\                         or remove the highlight under the cursor
    \\    click on a mark      remove it: a highlight, or a line of ink
    \\    M                    remove every mark in this document
    \\    ]a / [a              the next / previous mark, in reading order
    \\    ]c / [c              the next / previous comment, a thread at a time
    \\    u / ctrl+r           undo / redo a change to the marks
    \\
else "") ++
    \\    + / -                zoom in and out
    \\    0 / 1                fit the width / one hundred per cent
    \\    q                    close this window, then the reader
    \\    Q                    close the reader
    \\
++ (if (caps.marks)
    \\    v / V / i / d        visual, visual line, edit and draw mode
    \\
else
    \\    v / V                visual and visual line mode
    \\
) ++
    \\    :                    the command line
    \\
    \\visual mode (selecting), from v or V:
    \\    any motion           extend the selection
    \\    o                    go to the other end of the selection
    \\
++ (if (caps.marks)
    \\    m, enter             highlight it in the default colour
    \\    _ / - / ~            underline it, strike it through, squiggle it
    \\    c                    highlight it and write a comment on it
    \\
else "") ++
    \\    y                    put it away; there is no clipboard yet, and a
    \\                         selection is never stored
    \\
++ (if (caps.marks)
    \\    1 .. 8               highlight it in that colour: default, yellow,
    \\                         green, blue, pink, orange, purple, red
    \\    d, x                 remove the highlights it touches
    \\
else "") ++
    \\    v / V                leave, or switch between the two
    \\    escape               leave without doing anything
    \\
;

const mark_modes =
    \\
    \\edit mode (changing highlights), from i:
    \\    n / N, j / k, tab    the next and previous highlight
    \\    ]a [a                the same, among what :filter lets through
    \\    ]c [c                the next and previous comment, and take it in
    \\                         hand
    \\    1 .. 8               recolour it
    \\    m / _ / - / ~        make it a highlight, an underline, a
    \\                         strike-through or a squiggle
    \\    d, x, delete         delete it, and take the next
    \\    a, enter             change the comment in hand, or write one;
    \\                         enter keeps it, and keeps none when it is
    \\                         empty; escape throws it away
    \\    c                    write another comment on the same words
    \\    u / ctrl+r           undo / redo
    \\    escape, q            back to normal mode
    \\
    \\draw mode (freehand ink), from d:
    \\    drag on a page       draw; the line is kept when the button comes
    \\                         up, and stays on the page it was begun on
    \\    1 .. 8               the pen's colour, from the same eight
    \\    [ / ]                a thinner / thicker pen
    \\    wheel, page keys     scroll while drawing
    \\    u / ctrl+r           undo / redo the last line
    \\    d, q, escape         back to normal mode; a click there erases
    \\
;

const closing = (if (caps.marks)
    \\
    \\    The title bar shows the mode, the highlight in hand, its comment,
    \\    the comment or command as it is being typed, and messages from
    \\    plugins.
    \\
else
    \\
    \\    The title bar shows the mode, the page, the zoom and the command as
    \\    it is being typed.
    \\
) ++ (if (caps.lua)
    \\
    \\    Keys bound by plugins with fenrir.keymap come before these; see
    \\    `fenrir plugins` for what is bound.
    \\
else "") ++
    \\
    \\    The percentage in the title bar is relative to the page's true
    \\    physical size on this display: 100% means a 72-point inch is an
    \\    inch, display scaling included.
;

const gap = View.gap;
const min_zoom = View.min_zoom;
const max_zoom = View.max_zoom;

/// Frames a device shot waits for the visible pages before taking what it has.
const shot_patience: u32 = 3000;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    return runWith(ctx, args, null);
}

/// The reader, and with `comparison` the two documents of a `fenrir diff`
/// side by side: see `arrangeComparison`.
pub fn runWith(ctx: *Context, typed: []const []const u8, comparison: ?ComparisonIfCompared) !void {
    // fenrir.toml, before anything is parsed, because its `[read]` is parsed
    // with the typed flags. See `config.zig`.
    const written: ?WrittenIfRead = if (caps.config) try config_mod.load(ctx) else null;

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);

    var start_page: u32 = 1;
    var page_given = false;
    var db_path: ?[]const u8 = null;
    var zoom: ?f32 = null;
    var width: u32 = 1000;
    var height: u32 = 900;
    var frames: ?u32 = null;
    var vsync: lyngvi.Vsync = .on;
    var validate = false;
    var prefer: ?[]const u8 = null;
    var samples: gleipnir.raster.Samples = .eight;
    var shot: ?[]const u8 = null;
    var splits: []const u8 = &.{};
    var clean = false;
    var timing = false;
    var bench: ?BenchKind = null;
    var config_dir: ?[]const u8 = null;
    var watch_flag = false;
    var on_device = false;
    var backend: render.Backend = if (have_gpu and !have_cpu) .gpu else .cpu;

    // Every flag below is guarded by the capability it belongs to, and the
    // guards are comptime-known: a `light` build does not merely refuse
    // `--bench`, it has no `--bench` to refuse and nothing of the benchmark
    // driver in it. `unknown option` is then the truth rather than a policy.
    //
    // Twice: the flags fenrir.toml wrote down, then the typed ones, so a flag
    // typed now wins. Each pass is a list of its own, so a flag in the file
    // left without its value cannot take the first typed argument -- the
    // document -- as one. A refusal in the first pass says which file it
    // came from.
    var from_file: ?[]const u8 = null;
    errdefer if (from_file) |path| ctx.note("    (in {s})", .{path});
    const passes = [_][]const []const u8{ if (written) |w| w.flags else &.{}, typed };
    for (passes, 0..) |args, pass| {
        from_file = if (written) |w| (if (pass == 0) w.path else null) else null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (caps.instruments and std.mem.eql(u8, arg, "--validate")) {
                validate = true;
            } else if (std.mem.eql(u8, arg, "--page")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--page needs a number", .{});
                start_page = std.fmt.parseInt(u32, args[i], 10) catch
                    return ctx.fail("--page wants a number, not '{s}'", .{args[i]});
                if (start_page == 0) return ctx.fail("pages are numbered from 1", .{});
                page_given = true;
            } else if (std.mem.eql(u8, arg, "--zoom")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--zoom needs a number", .{});
                zoom = std.fmt.parseFloat(f32, args[i]) catch
                    return ctx.fail("--zoom wants a number, not '{s}'", .{args[i]});
            } else if (std.mem.eql(u8, arg, "--dpi")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--dpi needs a number", .{});
                const dpi = std.fmt.parseFloat(f32, args[i]) catch
                    return ctx.fail("--dpi wants a number, not '{s}'", .{args[i]});
                zoom = dpi / 72.0;
            } else if (std.mem.eql(u8, arg, "--samples")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--samples needs 1, 2, 4 or 8", .{});
                samples = switch (std.fmt.parseInt(u8, args[i], 10) catch 0) {
                    1 => .one,
                    2 => .two,
                    4 => .four,
                    8 => .eight,
                    else => return ctx.fail("--samples wants 1, 2, 4 or 8", .{}),
                };
            } else if (caps.bench and std.mem.eql(u8, arg, "--frames")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--frames needs a count", .{});
                frames = std.fmt.parseInt(u32, args[i], 10) catch
                    return ctx.fail("--frames wants a number, not '{s}'", .{args[i]});
            } else if (caps.bench and std.mem.eql(u8, arg, "--time")) {
                timing = true;
            } else if (caps.bench and std.mem.eql(u8, arg, "--bench")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--bench needs scroll, zoom or flip", .{});
                bench = std.meta.stringToEnum(Bench.Kind, args[i]) orelse
                    return ctx.fail("--bench wants scroll, zoom or flip, not '{s}'", .{args[i]});
                timing = true;
            } else if (caps.sqlite and std.mem.eql(u8, arg, "--db")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--db needs a file", .{});
                db_path = args[i];
            } else if (caps.splits and std.mem.eql(u8, arg, "--split")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--split needs v, h, or a run of them", .{});
                for (args[i]) |c| {
                    if (c != 'v' and c != 'h') return ctx.fail("--split wants v and h, not '{c}'", .{c});
                }
                splits = args[i];
            } else if (caps.lua and std.mem.eql(u8, arg, "--clean")) {
                clean = true;
            } else if (caps.lua and std.mem.eql(u8, arg, "--config")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--config needs a directory", .{});
                config_dir = args[i];
            } else if (caps.diagnostics and std.mem.eql(u8, arg, "--device")) {
                on_device = true;
            } else if (caps.diagnostics and std.mem.eql(u8, arg, "--shot")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--shot needs a file", .{});
                shot = args[i];
            } else if (have_both and std.mem.eql(u8, arg, "--path")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--path needs cpu or gpu", .{});
                if (std.mem.eql(u8, args[i], "cpu")) {
                    backend = .cpu;
                } else if (std.mem.eql(u8, args[i], "gpu")) {
                    backend = .gpu;
                } else {
                    return ctx.fail("--path wants cpu or gpu, not '{s}'", .{args[i]});
                }
            } else if (std.mem.eql(u8, arg, "--gpu")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--gpu needs a name", .{});
                prefer = args[i];
            } else if (std.mem.eql(u8, arg, "--vsync")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--vsync needs on, off or adaptive", .{});
                vsync = if (std.mem.eql(u8, args[i], "on"))
                    .on
                else if (std.mem.eql(u8, args[i], "off"))
                    .off
                else if (std.mem.eql(u8, args[i], "adaptive"))
                    .adaptive
                else
                    return ctx.fail("--vsync wants on, off or adaptive", .{});
            } else if (std.mem.eql(u8, arg, "--watch")) {
                watch_flag = true;
            } else if (std.mem.eql(u8, arg, "--size")) {
                i += 1;
                if (i >= args.len) return ctx.fail("--size needs WxH", .{});
                const x = std.mem.indexOfScalar(u8, args[i], 'x') orelse
                    return ctx.fail("--size wants WxH", .{});
                width = std.fmt.parseInt(u32, args[i][0..x], 10) catch
                    return ctx.fail("--size wants WxH", .{});
                height = std.fmt.parseInt(u32, args[i][x + 1 ..], 10) catch
                    return ctx.fail("--size wants WxH", .{});
                if (width == 0 or height == 0) return ctx.fail("--size must be positive", .{});
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return ctx.fail("unknown option {s}", .{arg});
            } else if (caps.config and pass == 0) {
                // The file names no documents. A word on its own in its list
                // is the value a switch was written with: `clean = "yes"` is
                // `--clean yes`, and so is `clean = false`.
                const name = std.mem.trimStart(u8, args[i - 1], "-");
                return ctx.fail("{s} is a switch: write {s} = true, or leave it out", .{ name, name });
            } else {
                try files.append(ctx.gpa, arg);
            }
        }
    }
    from_file = null;

    if (files.items.len == 0) return ctx.fail("read needs a file", .{});
    if (comparison != null and files.items.len != 2) return ctx.fail("a comparison is of two documents", .{});
    // `Rerun` reads both documents' bytes on a thread of its own, and a
    // reload frees them.
    if (comparison != null and watch_flag) return ctx.fail("a comparison does not watch its files", .{});
    if (zoom) |z| {
        if (!(z > 0) or !std.math.isFinite(z)) {
            return ctx.fail("a zoom has to be positive and finite", .{});
        }
    }

    if (shot == null and !lyngvi.has_window) {
        return ctx.fail(
            "no window backend for this platform yet: Lyngvi speaks Win32 and Wayland, and the X11 backend is a stub",
            .{},
        );
    }

    // The reader's own heap. See the note on memory at the top of the file:
    // the CLI's arena is right for a command that runs and exits and wrong
    // for one that runs until you close it. It also has to be safe to call
    // from the rasterising thread, which an arena is not.
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .debug) {
        if (heap.deinit() == .leak) ctx.note("the reader leaked memory", .{});
    };
    const gpa: Allocator = if (builtin.mode == .debug)
        heap.allocator()
    else
        std.heap.smp_allocator;

    var session: Session = .{
        .ctx = ctx,
        .gpa = gpa,
        .samples = samples,
        .backend = backend,
        .io = ctx.io,
        .palette_text = .init(gpa),
    };
    defer session.deinit();

    // `--time`'s stopwatch for startup. Every stage between here and the
    // first frame reports through it, so "the reader takes a moment to come
    // up" becomes a list of numbers rather than a guess about which stage.
    var stage: Stage = .{ .ctx = ctx, .on = timing, .clock = .start(ctx.io) };
    session.stage = &stage;

    // Mímir, if this build and this machine have one. A shot is a script
    // writing a file and not a person reading, so it neither reads the
    // remembered position nor records having been there.
    if (caps.sqlite) {
        session.library = library.openWith(ctx, gpa, db_path);
        if (session.library) |l| {
            if (l.accent() catch null) |c| {
                session.chosen_accent = c;
                session.highlight = c;
            }
        }
    }
    stage.mark("library");
    // A comparison opens at its first difference, wherever either document
    // was last read to, and does not move where they will reopen. A bench
    // ends at the last page and must not leave the reader there.
    session.remembers_place = shot == null and comparison == null and bench == null;
    if (caps.compare) session.diff = comparison;
    // fenrir.toml's settings over the library's, for this session and never
    // written into it: the library is what was last clicked, the file is
    // what somebody wrote down to have every time.
    if (written) |w| {
        if (w.accent) |c| {
            session.chosen_accent = c;
            session.highlight = c;
        }
    }
    const written_theme: ?Theme = if (written) |w| w.theme else null;
    // After the accent, because the theme carries it: `useTheme` puts the
    // chosen colour back on top of whichever theme was named.
    session.useTheme(written_theme orelse session.rememberedTheme());
    session.comment_style = marks.rememberedCommentStyle(&session);
    // Before the documents open: a document not watched is held from the
    // moment it is read.
    session.watching = comparison == null and (watch_flag or reload.rememberedWatch(&session));
    session.timing = timing;

    for (files.items) |file| {
        _ = session.openBuffer(file) catch |err| {
            return ctx.fail("cannot open {s}: {t}", .{ file, err });
        };
    }

    // The first window, looking at the first document.
    const first = &session.buffers.items[0];
    if (start_page > first.pages.len) {
        return ctx.fail("page {d}: {s} has {d} pages", .{ start_page, first.title, first.pages.len });
    }
    try session.tabs.init(gpa, .{
        .buffer = 0,
        .pages = first.pages,
        .zoom = std.math.clamp(zoom orelse 1.0, min_zoom, max_zoom),
        .fit_on_open = zoom == null,
    });

    const resumed = session.restore(session.layout().current(), 0, page_given, zoom == null);
    if (!page_given and resumed == null) session.layout().current().scrollToPage(start_page - 1);
    if (resumed) |p| {
        ctx.note("resuming at page {d} of {d}", .{ p.page + 1, first.pages.len });
    }

    // Galdr. Not for a shot, for the same reason a shot does not resume where
    // you were: a script asking for a picture must get the same picture
    // whatever is in your configuration directory.
    if (caps.lua) {
        if (shot == null and !clean) plugins_mod.startPlugins(&session, config_dir);
    }
    stage.mark("plugins");

    if (caps.diagnostics) {
        if (shot) |dest| {
            if (backend == .cpu and !on_device) {
                return session.shoot(dest, width, height, start_page - 1, splits);
            }
        }
    }

    try session.open(.{
        .width = width,
        .height = height,
        .frames = frames,
        .shot = shot,
        // Presenting to a hidden window with FIFO can wait for a vertical
        // blank that a window nobody can see is never given.
        .vsync = if (shot != null) .off else vsync,
        .start_page = start_page - 1,
        .page_given = page_given,
        .splits = splits,
        .device = .{ .validation = validate, .prefer = prefer },
        .time = timing,
        .bench = bench,
    });
}

const Settings = struct {
    width: u32,
    height: u32,
    frames: ?u32,
    /// Read one frame back from the device into this file, and exit.
    shot: ?[]const u8 = null,
    vsync: lyngvi.Vsync,
    start_page: u32,
    page_given: bool,
    splits: []const u8 = &.{},
    device: lyngvi.Device.Options,
    /// `--time`: what the frames cost, summarised on exit.
    time: bool = false,
    bench: ?BenchKind = null,
};

/// `--bench`: a workload that is the same on every run, so two builds, or the
/// two backends, can be set side by side on it.
///
/// A step moves the focused window, and the next waits until everything the
/// step brought into view has arrived. So the frames drawn with every page
/// present -- what scrolling and zooming cost, frame after frame -- and the
/// wait for a page -- what arriving costs -- are counted apart, and neither
/// hides in the other's average.
const Bench = struct {
    kind: Kind,
    step: u32 = 0,
    /// The scroll's stride, taken at the first step, so later zooms and page
    /// sizes do not change the run.
    stride: f32 = 0,
    /// Frames drawn while something visible was still missing.
    waited: u32 = 0,
    /// From a step to the last page it brought into view being there.
    arrival: lyngvi.Renderer.Samples = .{},
    pending: ?Lap = null,

    /// Steps each way between 50% and `max_zoom`, five percent a step. Taken
    /// at the first step, from the window's own 100%.
    zoom_steps: u32 = 0,

    const Kind = enum { scroll, zoom, flip };

    /// Up, down, up, down.
    const zoom_legs = 4;

    /// Moves the window for the next frame. False once the workload is done.
    fn advance(b: *Bench, v: *View) bool {
        defer b.step += 1;
        switch (b.kind) {
            .scroll => {
                if (b.step == 0) {
                    b.stride = v.pageSize(0)[1] / 20;
                    v.scroll = 0;
                } else {
                    if (v.scroll >= v.maxScroll()) return false;
                    v.scroll += b.stride;
                }
                v.clampScroll();
            },
            .zoom => {
                const half = 0.5 * v.hundredPercent();
                if (b.step == 0) b.zoom_steps = @intFromFloat(@ceil(@log(max_zoom / half) / @log(1.05)));
                const leg = b.step / b.zoom_steps;
                if (leg >= zoom_legs) return false;
                const k = b.step % b.zoom_steps;
                const up = if (leg % 2 == 0) k else b.zoom_steps - k;
                v.setZoom(half * std.math.pow(f32, 1.05, @floatFromInt(up)));
            },
            .flip => {
                if (b.step >= v.pages.len) return false;
                v.scrollToPage(b.step);
            },
        }
        return true;
    }
};

/// `--time`'s startup stopwatch.
///
/// The reader's start is a sequence of one-off costs -- the library, the
/// documents, a Vulkan device, a swapchain, two pipelines, and then the first
/// page actually rendered -- and until one of them is named with a number,
/// "startup feels slow" cannot be acted on. Every stage prints how long it
/// took and how long the run has been going, so both the individual cost and
/// the point the window appears are readable off one list.
///
/// Off unless `--time` was given, and then it is a handful of `note` calls on
/// a path that runs once.
const Stage = struct {
    ctx: *Context,
    on: bool,
    clock: Lap,
    total: u64 = 0,

    fn mark(s: *Stage, comptime what: []const u8) void {
        const ns = s.clock.lap();
        if (!s.on) return;
        s.total += ns;
        s.ctx.note("start  {s:<12} {d:>8.2}ms  ({d:.2} in)", .{
            what,
            @as(f64, @floatFromInt(ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(s.total)) / 1_000_000.0,
        });
    }
};

pub fn msOf(ns: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(ns)) / 1_000_000.0);
}

/// One line of `--time`'s exit summary.
fn reportSpread(ctx: *Context, comptime what: []const u8, samples: *lyngvi.Renderer.Samples) void {
    const sp = samples.spread();
    if (sp.n == 0) return;
    ctx.note("time   {s:<10} best {d:.3}ms  median {d:.3}  p95 {d:.3}  of {d}", .{
        what, sp.best, sp.median, sp.p95, sp.n,
    });
}

/// A stopwatch over `Io`'s monotonic clock. Zig 0.16 has no `std.time.Timer`,
/// and `lyngvi.Clock` answers in seconds of `f32`, which cannot resolve a
/// stage that takes two milliseconds.
pub const Lap = struct {
    io: Io,
    last: Io.Timestamp,

    pub fn start(io: Io) Lap {
        return .{ .io = io, .last = Io.Clock.awake.now(io) };
    }

    pub fn lap(l: *Lap) u64 {
        const now = Io.Clock.awake.now(l.io);
        const ns = l.last.durationTo(now).nanoseconds;
        l.last = now;
        return if (ns <= 0) 0 else @intCast(ns);
    }
};

/// The rendered pages, kept on the CPU so `--shot` can sample them without a
/// device. The window does not use this: there the pixels go to the GPU and
/// the buffer is freed the same frame.
const CpuTextures = struct {
    entries: [render.cache_slots]?render.Image = @splat(null),

    fn deinit(t: *CpuTextures, gpa: std.mem.Allocator) void {
        for (&t.entries) |*e| {
            if (e.*) |image| gpa.free(image.pixels);
            e.* = null;
        }
    }

    fn sampler(t: *CpuTextures) gleipnir.software.Sampler {
        return .{ .ptr = t, .sample = sample };
    }

    /// Nearest neighbour. The page is drawn at exactly the size it was
    /// rasterised, so every sample lands in the middle of its own texel and a
    /// bilinear filter would have nothing to interpolate.
    fn sample(ptr: *anyopaque, tex: u32, u: f32, v: f32) Color {
        const t: *CpuTextures = @ptrCast(@alignCast(ptr));
        if (tex == 0 or tex > t.entries.len) return .transparent;
        const image = t.entries[tex - 1] orelse return .transparent;

        const x = std.math.clamp(@as(i64, @intFromFloat(u * @as(f32, @floatFromInt(image.width)))), 0, image.width - 1);
        const y = std.math.clamp(@as(i64, @intFromFloat(v * @as(f32, @floatFromInt(image.height)))), 0, image.height - 1);
        const o = (@as(usize, @intCast(y)) * image.width + @as(usize, @intCast(x))) * 4;
        return .{
            .r = @as(f32, @floatFromInt(image.pixels[o + 0])) / 255.0,
            .g = @as(f32, @floatFromInt(image.pixels[o + 1])) / 255.0,
            .b = @as(f32, @floatFromInt(image.pixels[o + 2])) / 255.0,
            .a = @as(f32, @floatFromInt(image.pixels[o + 3])) / 255.0,
        };
    }
};

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

pub const Session = struct {
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
    /// rasterised for nobody.
    tabs: Tabs = .{},
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
    search: search.State = .{},

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
    tab_names: std.ArrayList([]const u8) = .empty,
    tab_text: std.ArrayList(u8) = .empty,
    tab_ends: std.ArrayList(u32) = .empty,
    tabs_for: u64 = 0,

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
    split_drag: ?Layout.Divider = null,

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
    stage: ?*Stage = null,

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
    /// few allocations for the life of the session.
    order: std.ArrayList(u32) = .empty,
    borders: std.ArrayList(Bounds) = .empty,
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
        s.order.deinit(s.gpa);
        s.borders.deinit(s.gpa);
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
        s.tab_names.deinit(s.gpa);
        s.tab_text.deinit(s.gpa);
        s.tab_ends.deinit(s.gpa);
        for (&s.diff_ticks) |*t| t.at.deinit(s.gpa);
    }

    // -- buffers -------------------------------------------------------------

    /// Opens a document and adds it to the list. The `Document` is on the
    /// heap because a buffer holds a pointer to it and the list moves when
    /// the next file is opened.
    fn openBuffer(s: *Session, file: []const u8) !u32 {
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
    pub fn layout(s: *Session) *Layout {
        return s.tabs.current();
    }

    pub fn view(s: *Session) *View {
        return s.layout().current();
    }

    // -- what the library remembers ------------------------------------------

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
    fn rememberedTheme(s: *Session) Theme {
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
    fn remember(s: *Session, v: *View) void {
        if (!s.remembers_place) return;
        const lib = s.library orelse return;
        const b = s.buffer(v.buffer);
        lib.visit(b.path, b.title, placeOf(v), library.now(s.ctx.io)) catch {};
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
    fn rememberAll(s: *Session) void {
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

    // -- the command line ---------------------------------------------------

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
            s.say("not a command: {s}", .{name[0..@min(name.len, 64)]});
            return false;
        };

        switch (entry.id) {
            .quit => {
                if (!windows.closeWindow(s)) s.quit = true;
            },
            .quit_all => s.quit = true,
            .split => windows.splitWindow(s, .horizontal),
            .vsplit => windows.splitWindow(s, .vertical),
            .close => _ = windows.closeWindow(s),
            .only => s.layout().only(s.gpa),
            .tabnew => windows.newTab(s),
            .tabclose => if (!windows.closeTab(s)) {
                s.say("this is the only tabpage; :q leaves the reader", .{});
                return false;
            },
            .tabonly => s.tabs.only(s.gpa),
            // `:tabnext` alone is the next one; with a number it is that one,
            // counted from 1 as a person counts the bar.
            .tabnext, .tabprevious => {
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
            .bnext => windows.showBuffer(s, 1),
            .bprevious => windows.showBuffer(s, -1),
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

    // -- input ---------------------------------------------------------------

    /// Returns true when the reader should close.
    ///
    /// The interface gets first refusal on the frame. While a menu is open it
    /// owns the pointer and the arrows, escape and enter, and the page must
    /// not also act on them -- escape would leave visual mode and the arrows
    /// would scroll the document out from under the menu. The chrome is built
    /// after this runs, so the question is asked of the menu's *state*, which
    /// the chrome keeps for exactly this reason, and not of a box tree that
    /// does not exist yet.
    fn handle(s: *Session, in: lyngvi.Input) bool {
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
            .quit => if (!windows.closeWindow(s)) return true,
            .quit_all => return true,

            .split => |dir| windows.splitWindow(s, dir),
            .close_window => _ = windows.closeWindow(s),
            .only_window => s.layout().only(s.gpa),
            .focus_side => |side| _ = s.layout().focusSide(side),
            .cycle_window => |back| s.layout().cycle(s.gpa, back),
            .equalise => s.layout().equalise(),

            .new_tab => windows.newTab(s),
            .close_tab => _ = windows.closeTab(s),
            .go_tab => |delta| windows.goTab(s, delta),
            .window_to_tab => windows.windowToTab(s),

            .diff_view => |delta| compare.turnComparison(s, delta),
            .nudge => |by| compare.nudge(s, by),

            .next_buffer => windows.showBuffer(s, 1),
            .previous_buffer => windows.showBuffer(s, -1),

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
    fn applyZoom(s: *Session, want: chrome_mod.ZoomWant) void {
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
        if (windows.dragSplit(s, in, down, pressed)) return;

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
            _ = s.layout().focusAt(in.mouse);
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

    // -- the frame -----------------------------------------------------------

    /// The backdrop a page sits on, the paper under one that has not arrived,
    /// the shadow it sits on, and the line between two windows.
    ///
    /// Four literals until the theme reached this far down. They were
    /// `gray(0.16)`, white, black at 0.45 and `gray(0.08)`, which are the
    /// dark theme's `ground`, `paper`, `shadow` and `divider` to within a
    /// hundredth -- the light theme needed all four to move together, and a
    /// backdrop that stayed near black under a light interface is exactly
    /// the sort of half-applied theme this file was meant not to have.
    const white: Color = .white;

    fn compose(s: *Session, list: *DrawList, over: *DrawList) !void {
        s.stamp += 1;
        s.recorded.stamp = s.stamp;

        s.order.clearRetainingCapacity();
        try s.layout().leaves(&s.order, s.gpa);

        for (s.order.items) |leaf| {
            const v = s.layout().viewAt(s.layout().nodes.items[leaf].pane.view().?);
            // Everything a window draws is confined to its own rectangle, or
            // a page scrolled past the bottom of one split would appear in
            // the next.
            list.pushClip(v.rect);
            over.pushClip(v.rect);
            defer list.popClip();
            defer over.popClip();
            try s.composeView(v, list, over);
        }

        // The lines between windows, then the focus ring, on top of
        // everything so neither is covered by a page.
        s.borders.clearRetainingCapacity();
        try s.layout().borders(&s.borders, s.gpa);
        for (s.borders.items) |b| try over.fill(b, s.theme.divider);

        if (s.layout().count() > 1) {
            const focused = s.layout().nodes.items[s.layout().focus].rect;
            try over.border(focused, .all(0), 2, .{
                .r = s.accent.r,
                .g = s.accent.g,
                .b = s.accent.b,
                .a = 0.9,
            });
        }
    }

    fn composeView(s: *Session, v: *View, list: *DrawList, over: *DrawList) !void {
        const b = s.buffer(v.buffer);
        const range = v.visiblePages();
        const overlay = compare.overlaid(s, v);

        var i = range.first;
        while (i < range.end) : (i += 1) {
            const rect = v.pageRect(i);

            // The shadow first, so the page sits on it rather than under it.
            try list.shadow(
                .fromRect(rect.min_x, rect.min_y + 3, rect.max_x, rect.max_y + 3),
                .{},
                8,
                s.theme.shadow,
            );

            if (s.backend == .gpu and !overlay) {
                // Blank paper. The path pipeline draws on it, in its own pass
                // between this list and `over`.
                s.recorded.touch(v.buffer, i);
                try list.fill(rect, s.theme.paper);
            } else if (render.slotFor(s, v.buffer, i, v.zoom, overlay)) |slot| {
                slot.used = s.stamp;
                try list.image(
                    rect,
                    slot.list,
                    .fromRect(0, 0, @floatFromInt(slot.width), @floatFromInt(slot.height)),
                    white,
                );
            } else {
                // Paper with nothing on it yet. Better than a hole, and it
                // tells you the page exists and is coming.
                try list.fill(rect, s.theme.paper);
            }
        }

        try compare.drawChanges(s, v, range, over);
        try marks.drawMarks(s, v, b, range, over);
        try ink.drawInk(s, v, b, range, over);
        try search_mod.drawSearchHits(s, v, range, over);

        v.marks_seen = b.marks.revision;
        try cursor.drawSelection(s, v, over);
        try cursor.drawCaret(s, v, over);
        try s.drawScrollbar(v, over);
    }

    /// A highlight's own shape: the glyph boxes, padded.
    ///
    /// The text map's boxes are tight around the type -- they are what a
    /// caret is placed against -- and a block drawn exactly on them clips the
    /// ascenders and reads as a stripe rather than as something laid over the
    /// words. A little air on each side, in device pixels so it does not grow
    /// with the zoom, is the difference.
    pub fn blockOf(box: Bounds, zoom: f32) Bounds {
        const pad = @max(1.0, zoom * 0.6);
        return .fromRect(box.min_x - pad, box.min_y - pad, box.max_x + pad, box.max_y + pad);
    }

    pub fn markRadius(zoom: f32) f32 {
        return @max(2.0, zoom * 1.5);
    }

    fn drawScrollbar(s: *Session, v: *View, list: *DrawList) !void {
        const bar = v.scrollbarAt() orelse return;
        const alpha: f32 = if (v.dragging != null) 0.75 else if (v.hot_thumb) 0.55 else 0.35;
        try list.rounded(
            .fromRect(bar.x0, bar.y, bar.x1, bar.y + bar.height),
            .all(3),
            .{ .r = s.accent.r, .g = s.accent.g, .b = s.accent.b, .a = alpha },
        );
        try compare.drawChangeTicks(s, v, bar, list);
    }

    /// The rectangle the windows get, which is the client area less whatever
    /// the interface has taken off it.
    ///
    /// The status bar and the rails are *reserved*, not drawn over: a bar
    /// that floated on top would cover the last line of the page, and a
    /// reader whose last line is hidden is worse than one with a shorter
    /// page. Every window's fit refits to this, because `Layout.arrange`
    /// calls `refit` on each rectangle it hands out -- which is also why a
    /// page fitted down the window fits above the bar rather than behind it.
    ///
    /// Reserving the rail rather than floating it is also what settles which
    /// of the two a click belonged to: a pointer over a rail is never also
    /// over a page, so there is nothing to arbitrate. The panels are the ones
    /// that overlay, and they are asked about separately.
    pub fn windowRect(s: *const Session, width: f32, height: f32) Bounds {
        if (s.chrome == null) return .fromRect(0, 0, width, @max(height, 1));
        const left = rails_mod.width;
        const top = windows.tabInset(s);
        return .fromRect(
            left,
            top,
            @max(width - rails_mod.width, left + 1),
            @max(height - chrome_mod.status_height, top + 1),
        );
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

    fn updateTitle(s: *Session, window: lyngvi.Window) void {
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

    // -- one frame, with no device -------------------------------------------

    /// Composes a frame and rasterises it with the CPU model of the rect
    /// pipeline, exactly as `fenrir ui` does.
    ///
    /// The point is not the picture. It is that the layout -- where a page
    /// lands, how big it is, where a split falls -- can be checked on a
    /// machine with no display, in a test, and in a diff, rather than only by
    /// looking at a window.
    fn shoot(s: *Session, dest: []const u8, width: u32, height: u32, start_page: u32, splits: []const u8) !void {
        const ctx = s.ctx;
        const gpa = s.gpa;

        // There is no device here, so there is no path pipeline either: a
        // shot is always the CPU rasteriser, whatever the window would use.
        s.backend = .cpu;

        s.tabs.arrange(.fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
        windows.applySplits(s, splits);

        var it = s.layout().iterator();
        while (it.next()) |v| {
            if (v.fit_on_open) v.fitTo(.width);
            if (v.scroll == 0) v.scrollToPage(start_page);
        }
        compare.arrangeComparison(s);

        var list: DrawList = .init(gpa, .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
        defer list.deinit();

        var images: CpuTextures = .{};
        defer images.deinit(gpa);

        // Every visible page, rendered up front: there is no next frame to
        // finish in, and no thread to finish it on.
        var slot: usize = 0;
        while (render.firstMissing(s)) |job| {
            if (slot >= render.cache_slots) break;

            const image = if (job.want == .overlay)
                compare.rasteriseOverlay(s, job) catch {
                    render.noteFailure(s, job);
                    continue;
                }
            else page: {
                const b = s.buffer(job.buffer);
                var result = content.page(gpa, b.doc, b.pages[job.page], render.page_options) catch break;
                defer result.deinit(gpa);

                if (text.build(gpa, result.list) catch null) |map| b.putMap(gpa, job.page, map);

                break :page render.rasterise(s, job, result.list, b) catch {
                    render.noteFailure(s, job);
                    continue;
                };
            };
            const id = try list.registerTexture(image.width, image.height);
            images.entries[id - 1] = image;
            s.slots[slot] = .{
                .buffer = job.buffer,
                .page = job.page,
                .zoom = job.zoom,
                .gpu = id,
                .list = id,
                .width = image.width,
                .height = image.height,
                .overlay = job.want == .overlay,
            };
            slot += 1;
        }

        // `--shot` models the rect pipeline only, so the two layers go into
        // one list: there is no path pass between them to separate.
        try s.compose(&list, &list);

        var fb = try gleipnir.Framebuffer.init(gpa, width, height, .linear);
        defer fb.deinit(gpa);
        fb.clear(s.theme.ground);
        gleipnir.software.render(fb, list.instances.items, images.sampler());

        var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
            return ctx.fail("cannot create {s}: {t}", .{ dest, err });
        defer file.close(ctx.io);

        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(ctx.io, &buf);
        fb.writePng(gpa, &writer.interface) catch |err|
            return ctx.fail("cannot write {s}: {t}", .{ dest, err });
        writer.interface.flush() catch |err|
            return ctx.fail("cannot write {s}: {t}", .{ dest, err });

        ctx.out.print("wrote {d}x{d} to {s}: {d} page{s} in {d} window{s} at {d:.0}%\n", .{
            width,
            height,
            dest,
            slot,
            if (slot == 1) "" else "s",
            s.layout().count(),
            if (s.layout().count() == 1) "" else "s",
            s.view().percent(),
        }) catch {};
    }

    // -- the window ----------------------------------------------------------

    fn open(s: *Session, settings: Settings) !void {
        const ctx = s.ctx;
        const gpa = s.gpa;

        var window = lyngvi.open(gpa, .{
            .title = "fenrir",
            .width = settings.width,
            .height = settings.height,
            // A shot is read back from the device, not looked at.
            .visible = settings.shot == null,
        }) catch |err| return ctx.fail("could not open a window: {s}", .{@errorName(err)});
        defer window.destroy();
        if (s.stage) |g| g.mark("window");

        // The interface, before the device: the face comes off the disk and
        // the first frame's glyphs are rasterised on the CPU, so none of it
        // waits on a Vulkan device that takes three quarters of a second to
        // create. A reader that cannot find a face still opens -- Týr's
        // fallback draws boxes -- so this is a note, not a failure.
        s.chrome = chrome_mod.Chrome.create(gpa, ctx.io) catch |err| blk: {
            ctx.note("no interface font ({s}); the status bar will draw as boxes", .{
                @errorName(err),
            });
            break :blk null;
        };
        if (s.chrome) |c| {
            if (!c.hasFace()) {
                ctx.note("no face for the interface on this machine; drawing Tyr's boxes", .{});
            }
        }

        const size = window.size();

        // Where every window starts, settled here rather than after the
        // device, because none of it needs one: the display's scale and the
        // window's size are known as soon as the window is, and the zoom
        // decides where every page begins.
        //
        // Now there is a display to be a percentage of, and a window to fit
        // to. Both have to happen before the first `scrollToPage`.
        const scale = window.scale();
        s.tabs.arrange(s.windowRect(@floatFromInt(size.width), @floatFromInt(size.height)));
        {
            const v = s.view();
            v.dpi_scale = scale;
            if (v.fit_on_open) v.fitTo(.width);
        }
        windows.applySplits(s, settings.splits);
        {
            // After the splits, because a split refits the zoom and a zoom
            // moves where every page starts: scrolling to `--page` first
            // would land above it by however much the refit moved things.
            var it = s.layout().iterator();
            while (it.next()) |v| {
                v.dpi_scale = scale;
                if (settings.page_given) v.scrollToPage(settings.start_page);
            }
        }
        compare.arrangeComparison(s);
        s.remember(s.view());
        // The window exists and every window is where it will start, so a
        // plugin reacting to `start` can split, scroll or zoom and see it.
        if (s.plugins) |rt| {
            rt.emit(.{ .event = .Start });
            plugins_mod.reportChanges(s);
        }

        var worker: render.Rasteriser = .{ .session = s, .io = ctx.io };
        worker.start() catch |err| {
            return ctx.fail("could not start the rasterising thread: {s}", .{@errorName(err)});
        };
        defer worker.stop();

        // Page one, asked for before the device exists.
        //
        // Rasterising it is CPU work and creating a Vulkan device and a
        // swapchain is the driver's; on this machine the second takes three
        // quarters of a second and the first a fifth of one, and doing them
        // one after the other meant the window appeared and then sat on blank
        // paper. Started here, the page is finished and waiting by the time
        // there is anything to upload it to. The worker fills one job and
        // blocks, so this costs one page of memory and no more.
        //
        // Only when the backend is already settled. A GPU session can still
        // fall back to the CPU if the path pipeline will not compile, and
        // `produce` reads `backend` on the worker thread -- starting before
        // that decision would be a race on it, and could rasterise the page
        // in the form the session turns out not to want.
        if (s.backend == .cpu) {
            if (render.nextJob(s)) |job| worker.post(job);
        }

        var device = lyngvi.Device.init(gpa, window, settings.device) catch |err| {
            return switch (err) {
                error.NoVulkanLoader => ctx.fail(
                    "no Vulkan loader on this system. Install the graphics driver; the SDK is not needed.",
                    .{},
                ),
                error.NoSuitableDevice => ctx.fail(
                    "a Vulkan loader is present but no device can present to a window.",
                    .{},
                ),
                else => ctx.fail("could not create a device: {s}", .{@errorName(err)}),
            };
        };
        defer device.deinit();
        if (s.stage) |g| g.mark("device");

        var swapchain = lyngvi.Swapchain.init(gpa, &device, .{
            .width = size.width,
            .height = size.height,
        }, settings.vsync) catch |err| {
            return ctx.fail("could not create a swapchain: {s}", .{@errorName(err)});
        };
        defer swapchain.deinit();
        if (s.stage) |g| g.mark("swapchain");
        if (settings.shot != null) {
            swapchain.readable = true;
            swapchain.recreate(.{ .width = size.width, .height = size.height }) catch |err| {
                return ctx.fail("could not create a swapchain: {s}", .{@errorName(err)});
            };
        }

        var renderer = lyngvi.Renderer.init(gpa, &device, &swapchain) catch |err| {
            return switch (err) {
                error.NoDescriptorIndexing => ctx.fail(
                    "{s} has no descriptor indexing, which the one-draw-call path requires.",
                    .{device.name()},
                ),
                else => ctx.fail("could not create the renderer: {s}", .{@errorName(err)}),
            };
        };
        defer renderer.deinit();
        if (s.stage) |g| g.mark("renderer");

        ctx.note("{s}, {d}x{d}, {s}, shaders from {s}", .{
            device.name(),
            swapchain.extent.width,
            swapchain.extent.height,
            @tagName(swapchain.present_mode),
            if (lyngvi.shaders.compiler.len == 0) "nowhere" else lyngvi.shaders.compiler,
        });
        if (renderer.shaders_missing) {
            ctx.note("no SPIR-V in this build, so the window clears and presents but draws nothing", .{});
            ctx.note("{s}", .{lyngvi.shaders.compile_hint});
            return;
        }

        // The analytic path pipeline, if this build has it and the reader is
        // using it. Created lazily: a `--path cpu` session should not pay for
        // storage buffers and a pipeline compile it will never bind.
        var paths_renderer: ?lyngvi.PathRenderer = if (have_gpu and s.backend == .gpu)
            lyngvi.PathRenderer.init(gpa, &device, &swapchain) catch |err| blk: {
                ctx.note("no GPU path pipeline ({s}); falling back to the CPU rasteriser", .{
                    @errorName(err),
                });
                s.backend = .cpu;
                break :blk null;
            }
        else
            null;
        defer if (paths_renderer) |*p| p.deinit();
        if (s.stage) |g| g.mark("paths");

        if (paths_renderer) |p| {
            if (p.shaders_missing) {
                ctx.note("no SPIR-V for the path pipeline; falling back to the CPU rasteriser", .{});
                s.backend = .cpu;
            }
        }
        ctx.note("paths: {s}", .{@tagName(s.backend)});

        var list: DrawList = .init(gpa, .fromRect(0, 0, 1, 1));
        defer list.deinit();
        // The layer above the document: scrollbars, highlights, the caret,
        // and anything else that must not be covered by the page it sits on.
        var over: DrawList = .init(gpa, .fromRect(0, 0, 1, 1));
        defer over.deinit();

        // The atlas takes texture one on the device and on both lists,
        // before any page slot does. See `Chrome.attach` for why all three.
        if (s.chrome) |c| {
            c.attach(&renderer, &list, &over) catch |err| {
                ctx.note("no atlas for the interface ({s}); its text will draw as blocks", .{
                    @errorName(err),
                });
            };
            c.theme = s.theme;
        }

        var uploads: std.ArrayList(lyngvi.Renderer.Upload) = .empty;
        defer uploads.deinit(gpa);

        var clock: lyngvi.Clock = .start(ctx.io);
        var drawn: u32 = 0;

        // `--time`: from one drawn frame to the next, and the placement, on
        // the CPU. The device's side is in `renderer.gpu_frame`.
        var interval: lyngvi.Renderer.Samples = .{};
        var placing: lyngvi.Renderer.Samples = .{};
        var lap: Lap = .start(ctx.io);
        // `?BenchDriver` and not `?Bench`: a build with no benchmark driver
        // holds an optional that cannot have a value, so the two blocks that
        // step the workload below fold away rather than testing a null every
        // frame.
        var bench: ?BenchDriver = null;
        if (caps.bench) {
            if (settings.bench) |kind| bench = .{ .kind = kind };
        }

        while (true) {
            window.pump();
            if (window.shouldClose()) break;
            if (settings.frames) |limit| {
                if (drawn >= limit) break;
            }

            const dt = clock.tick();
            const input = try window.events().take(dt);
            const client = window.size();

            if (window.events().resized or swapchain.extent.width != client.width or
                swapchain.extent.height != client.height)
            {
                try swapchain.recreate(.{ .width = client.width, .height = client.height });
                try renderer.refresh();
            }
            if (swapchain.isMinimised()) {
                window.wait(100);
                continue;
            }

            s.tabs.arrange(s.windowRect(
                @floatFromInt(swapchain.extent.width),
                @floatFromInt(swapchain.extent.height),
            ));
            if (s.handle(input)) break;
            reload.poll(s, dt);

            // Collect whatever the rasterising thread finished, and ask it
            // for the next page. Neither waits: the frame is drawn from what
            // is in the cache now, and a page still being worked on is blank
            // paper until it arrives.
            //
            // `pixels` stays alive until the frame is submitted, because
            // `Upload.pixels` is read during `frame`.
            var pixels: ?[]u8 = null;
            defer if (pixels) |p| gpa.free(p);
            pixels = render.collectPage(s, &worker, &renderer, &list, &uploads) catch |err| switch (err) {
                error.OutOfMemory => return ctx.fail("out of memory rendering a page", .{}),
                else => null,
            };
            // After what arrived is in and before the next job is chosen, so
            // the worker is asked for what the step just brought into view.
            if (bench) |*b| {
                if (render.firstMissing(s) != null) {
                    b.waited += 1;
                } else if (b.pending) |*l| {
                    // Arrived. Drawn for a frame before the next step, or a
                    // flip would move on from every page unseen.
                    b.arrival.push(msOf(l.lap()));
                    b.pending = null;
                } else {
                    if (!b.advance(s.view())) break;
                    if (render.firstMissing(s) != null) b.pending = .start(ctx.io);
                }
            }
            if (reload.jobToPost(s)) |job| worker.post(job);

            // One resumption each for the handlers that yielded, and no more:
            // a handler that gave the frame back gets it back on the next
            // one, which is the whole of what a coroutine is promised here.
            if (s.plugins) |rt| {
                rt.pump();
                marks.applyEffects(s);
            }

            const extent: Bounds = .fromRect(
                0,
                0,
                @floatFromInt(swapchain.extent.width),
                @floatFromInt(swapchain.extent.height),
            );
            list.reset(extent);
            over.reset(extent);
            try s.compose(&list, &over);
            s.updateTitle(window);

            // The interface, on top of the page and the marks on it. The
            // same frame's input the keymap already read: Þviti derives
            // presses by comparing with last frame and consumes nothing, so
            // both may have it.
            if (s.chrome) |c| {
                try c.begin(extent, input);
                // Before anything that starts below the bar: the rails and
                // the panel are floated against the top of the window and
                // have to be told how much of it is already spoken for.
                c.top = windows.tabInset(s);
                const want = try c.status(s.statusLine());
                if (try c.tabBar(windows.tabLabels(s), s.tabs.active)) |asked_tabs| windows.applyTabs(s, asked_tabs);
                const asked = try c.rightRail(interface.railLine(s));
                if (asked) |wanted| interface.applyRail(s, wanted);
                if (try c.leftRail(interface.modeRail(s))) |wanted| interface.applyRail(s, wanted);
                try interface.drawPanel(s, c);
                const asked_find = try find_mod.bar(
                    &c.ui,
                    c.face,
                    c.theme,
                    &c.icons,
                    &s.find,
                    search_mod.searchCount(s),
                    c.top,
                );
                // After the bar, the rails and the panel, so it is over all
                // of them: a popup is on top by being built last, and nothing
                // here sorts.
                //
                // Refilled first when a plugin changed what it declared
                // while the page was open. Nothing is read from the library
                // unless Galdr's revision moved, so an open page costs one
                // comparison a frame.
                if (s.settings.open and interface.pluginSettingsStale(s)) interface.readSettings(s);
                const changed = try settings_page.page(&c.ui, c.face, c.theme, &s.settings);
                const chosen = try palette_mod.palette(
                    &c.ui,
                    c.face,
                    c.theme,
                    &c.icons,
                    s.palette_rows.items,
                    &s.palette,
                );
                try c.tips();
                c.end();
                if (want) |wanted| s.applyZoom(wanted);
                if (changed) |c2| interface.changeSetting(s, c2);
                if (asked_find) |what| search_mod.applyFind(s, what);
                // After the frame is closed, because a command may open
                // another window, close this one, or leave the reader.
                if (chosen) |what| interface.runChosen(s, what);
                try c.flush(&over, &list, &renderer, &uploads);
            }

            // The path pass, between the two rect lists. Placing is a matrix
            // per instance and nothing else, so this runs every frame even
            // while scrolling at the refresh rate.
            var paths: ?lyngvi.Renderer.Paths = null;
            if (s.backend == .gpu) {
                if (paths_renderer) |*pr| {
                    // Only when something has actually moved. A reader
                    // sitting still then uploads nothing at all: the outlines
                    // are on the device and so is the placement.
                    const key = render.placementKey(s);
                    if (s.placed == null or s.placed.? != key) {
                        var place_lap: Lap = .start(ctx.io);
                        try render.placeVisible(s);
                        s.placed = key;
                        if (settings.time) placing.push(msOf(place_lap.lap()));
                    }
                    paths = .{
                        .renderer = pr,
                        .scene = &s.recorded.scene,
                        .frame = &s.recorded.frame,
                    };
                }
            }

            // A shot waits for every visible page, or gives up after a few
            // seconds' worth of frames and takes what there is.
            const shooting = settings.shot != null and
                (render.firstMissing(s) == null or drawn >= shot_patience);
            renderer.capture_next = shooting;

            switch (try renderer.frameWith(&list, uploads.items, s.theme.ground, paths, &over)) {
                .drawn => {
                    // The first frame and the first frame with the page on
                    // it are different moments, and the second is the one a
                    // reader calls "started". The window is up before the
                    // worker has finished page one, so the two are reported
                    // separately rather than as one number.
                    if (drawn == 0) {
                        if (s.stage) |g| g.mark("first frame");
                    }
                    if (s.pages_rendered != 0) {
                        if (s.stage) |g| {
                            g.mark("first page");
                            s.stage = null;
                        }
                    }
                    drawn += 1;
                    // The first interval is startup, which `Stage` reports,
                    // and under a bench a frame waiting for a page is the
                    // arrival's, which it reports.
                    const since = lap.lap();
                    const steady = if (bench) |b| b.pending == null else true;
                    if (settings.time and drawn > 1 and steady) interval.push(msOf(since));
                    if (shooting) {
                        if (renderer.captured) |c| try s.writeShot(settings.shot.?, c);
                        break;
                    }
                },
                .needs_recreate => {
                    try swapchain.recreate(.{ .width = client.width, .height = client.height });
                    try renderer.refresh();
                },
                .skipped => window.wait(100),
            }
            uploads.clearRetainingCapacity();
        }

        renderer.waitIdle();
        // Before the place is written, so a plugin that moves on `quit` is
        // remembered where it left the reader.
        if (s.plugins) |rt| {
            rt.emit(.{
                .event = .Quit,
                .doc = plugins_mod.handleOf(s, s.view().buffer),
                .path = s.buffer(s.view().buffer).path,
            });
            marks.applyEffects(s);
        }
        s.rememberAll();
        ctx.note("{d} frames drawn, {d} pages prepared, {d} MiB uploaded", .{
            renderer.frames_drawn,
            s.pages_rendered,
            renderer.bytes_uploaded / (1024 * 1024),
        });
        if (paths_renderer) |p| {
            ctx.note(
                "paths: {d} instances at most, {d} curves, {d} image texels, {d} draw calls over {d} frames, {d} MiB uploaded",
                .{
                    p.instance_high_water,
                    p.curve_high_water,
                    p.texel_high_water,
                    p.draw_calls,
                    renderer.frames_drawn,
                    p.bytes_uploaded / (1024 * 1024),
                },
            );
            const stats = s.recorded.scene.stats;
            if (stats.blended != 0 or stats.clips_too_deep != 0 or stats.images_dropped != 0) {
                ctx.note(
                    "         {d} with a blend mode drawn normal, {d} clips too deep, {d} images over the texel budget",
                    .{ stats.blended, stats.clips_too_deep, stats.images_dropped },
                );
            }
        }
        if (bench) |*b| {
            ctx.note("bench  {t}: {d} steps, {d} frames drawn waiting for a page", .{ b.kind, b.step, b.waited });
            reportSpread(ctx, "arrival", &b.arrival);
        }
        if (settings.time) {
            reportSpread(ctx, "frame", &interval);
            reportSpread(ctx, "place", &placing);
            if (paths_renderer) |*p| {
                if (p.memoryType()) |t| {
                    const kind = device.memory.memory_types[t];
                    ctx.note("time   paths in   {s}, of a {d} MiB heap", .{
                        lyngvi.choose.memoryKind(kind.property_flags),
                        device.memory.memory_heaps[kind.heap_index].size >> 20,
                    });
                } else {
                    ctx.note("time   paths in   more than one kind of memory", .{});
                }
            }
            if (renderer.query_pool == lyngvi.vk.null_handle) {
                ctx.note("time   this queue keeps no timestamps; no device times", .{});
            } else {
                reportSpread(ctx, "gpu frame", &renderer.gpu_frame);
                if (paths_renderer != null) reportSpread(ctx, "gpu paths", &renderer.gpu_paths);
            }
            const frames: f64 = @floatFromInt(@max(renderer.frames_drawn, 1));
            const paths_bytes = if (paths_renderer) |p| p.bytes_uploaded else 0;
            ctx.note("time   uploads    {d:.1} KiB a frame for rects and textures, {d:.1} for paths", .{
                @as(f64, @floatFromInt(renderer.bytes_uploaded)) / 1024.0 / frames,
                @as(f64, @floatFromInt(paths_bytes)) / 1024.0 / frames,
            });
        }
    }

    /// Writes a frame read back from the device.
    fn writeShot(s: *Session, dest: []const u8, c: lyngvi.Renderer.Capture) !void {
        const ctx = s.ctx;
        var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
            return ctx.fail("cannot create {s}: {t}", .{ dest, err });
        defer file.close(ctx.io);

        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(ctx.io, &buf);
        gleipnir.png.write(s.gpa, &writer.interface, c.pixels, c.width, c.height) catch |err|
            return ctx.fail("cannot write {s}: {t}", .{ dest, err });
        writer.interface.flush() catch |err|
            return ctx.fail("cannot write {s}: {t}", .{ dest, err });

        ctx.out.print("wrote {d}x{d} to {s}: read back from the device, paths on the {s}, at {d:.0}%\n", .{
            c.width,
            c.height,
            dest,
            @tagName(s.backend),
            s.view().percent(),
        }) catch {};
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("read/fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const giveLibrary = fixtures.giveLibrary;
const givePlugins = fixtures.givePlugins;
const putText = fixtures.putText;
const sessionOf = fixtures.sessionOf;

test {
    // The files the session is split into, named so that their tests run
    // whichever of them this build's session reaches. A file whose tests
    // need a capability gates them itself: see `compare.comparison_tests`.
    _ = compare;
    _ = cursor;
    _ = ink;
    _ = interface;
    _ = marks;
    _ = plugins_mod;
    _ = reload;
    _ = render;
    _ = search_mod;
    _ = windows;
}

test "each bench workload runs its course and then stops" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 8), 1, 1000, 800);
    defer closeSession(&s);

    // Every page once, ending on the last.
    var flip: Bench = .{ .kind = .flip };
    var steps: u32 = 0;
    while (flip.advance(s.view())) steps += 1;
    try testing.expectEqual(@as(u32, 8), steps);
    try testing.expectEqual(@as(u32, 7), s.view().currentPage());

    // From half size to the limit and back, twice, and nowhere outside that.
    var zoom: Bench = .{ .kind = .zoom };
    var lo: f32 = max_zoom;
    var hi: f32 = 0;
    steps = 0;
    while (zoom.advance(s.view())) : (steps += 1) {
        lo = @min(lo, s.view().zoom);
        hi = @max(hi, s.view().zoom);
    }
    try testing.expectEqual(Bench.zoom_legs * zoom.zoom_steps, steps);
    try testing.expectApproxEqRel(0.5 * s.view().hundredPercent(), lo, 1e-5);
    try testing.expectEqual(max_zoom, hi);

    // Top to bottom, twenty steps a page.
    s.view().setZoom(1);
    var scroll: Bench = .{ .kind = .scroll };
    steps = 0;
    while (scroll.advance(s.view())) steps += 1;
    try testing.expectEqual(s.view().maxScroll(), s.view().scroll);
    try testing.expect(steps > 7 * 20 and steps < 8 * 20);
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

    try testing.expect(s.exec("vsplit"));
    try testing.expectEqual(@as(u32, 2), s.layout().count());
    try testing.expect(s.exec("q"));
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    try testing.expect(!s.quit);
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

