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
const plugins_mod = @import("read/plugins.zig");

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

const Backend = enum { cpu, gpu };

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

/// How many rendered pages to keep. Two per window at a sensible zoom, plus
/// room to scroll back without re-rendering, and at four bytes a pixel it is
/// tens of megabytes rather than hundreds.
const cache_slots = 12;

const gap = View.gap;
const min_zoom = View.min_zoom;
const max_zoom = View.max_zoom;

/// A ceiling on one page's texture, matching `fenrir raster`. A page that
/// wants more than this at the requested zoom is rendered at whatever zoom
/// does fit rather than refused, because refusing means a blank window.
const max_page_pixels: u64 = 64 << 20;

/// Frames a device shot waits for the visible pages before taking what it has.
const shot_patience: u32 = 3000;

/// How wide a stroke is, in PDF points, when nothing says otherwise: a row
/// stored with no width, and the pen the reader starts with. About the weight
/// of a fineliner against ten-point type, which is what somebody underlining
/// a line of a paper is holding.
const default_pen_width: f32 = 1.6;

/// How the reader interprets a page: as `raster` does, less the annotations
/// it took as marks at open (`readAnnots`). It draws those itself, where they
/// can be recoloured and stepped through, and with their appearances in the
/// pixels too every one would be on screen twice.
const page_options: content.Options = .{ .taken = fenrir.annots.taken };

/// What `[` and `]` may take the pen to. A stroke under the thin end would
/// disappear at a fitted zoom and one over the thick end is a redaction.
const min_pen_width: f32 = 0.4;
const max_pen_width: f32 = 24;

/// How far apart two samples of the pointer have to be, in user-space points,
/// before the second is a place the pen went rather than the same place
/// reported again. Also `simplify`'s tolerance, because they are the same
/// question asked before and after the stroke.
const pen_tolerance: f32 = 0.4;

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
    var backend: Backend = if (have_gpu and !have_cpu) .gpu else .cpu;

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
    session.comment_style = session.rememberedCommentStyle();
    // Before the documents open: a document not watched is held from the
    // moment it is read.
    session.watching = comparison == null and (watch_flag or session.rememberedWatch());
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

fn msOf(ns: u64) f32 {
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
const Lap = struct {
    io: Io,
    last: Io.Timestamp,

    fn start(io: Io) Lap {
        return .{ .io = io, .last = Io.Clock.awake.now(io) };
    }

    fn lap(l: *Lap) u64 {
        const now = Io.Clock.awake.now(l.io);
        const ns = l.last.durationTo(now).nanoseconds;
        l.last = now;
        return if (ns <= 0) 0 else @intCast(ns);
    }
};

/// One rendered page, on the device and in the display list's numbering.
///
/// `gpu` and `list` are the same number by construction -- both registries
/// hand out ids in creation order and both are only added to here -- but the
/// two mean different things, so they are kept apart and asserted equal rather
/// than assumed to be one field.
const Slot = struct {
    buffer: u32 = 0,
    page: u32 = no_page,
    zoom: f32 = 0,
    gpu: u32 = 0,
    list: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// A monotonic frame stamp, for evicting the least recently drawn.
    used: u64 = 0,
    /// The page laid over its partner in a comparison, not the page alone.
    overlay: bool = false,
    /// Of a document since read again from its file: drawn until the new
    /// page arrives, so there is no blank flash, and never `cached`.
    stale: bool = false,

    const no_page = std.math.maxInt(u32);

    fn matches(s: Slot, buffer: u32, page: u32, zoom: f32, overlay: bool) bool {
        return s.buffer == buffer and s.page == page and s.zoom == zoom and s.overlay == overlay;
    }
};

/// The rendered pages, kept on the CPU so `--shot` can sample them without a
/// device. The window does not use this: there the pixels go to the GPU and
/// the buffer is freed the same frame.
const CpuTextures = struct {
    entries: [cache_slots]?Session.Image = @splat(null),

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

/// The pages recorded for the GPU pipeline.
///
/// One `Scene` holds the outlines of every cached page, so they go to the
/// device as one set of buffers; `ranges` says which instances belong to
/// which page. Recording is in *page space*, with no zoom and no scroll baked
/// in, which is what makes a scroll cost a matrix per instance rather than a
/// re-record -- and what lets two windows at different zooms share one
/// recording.
const Recorded = struct {
    scene: Scene = .{},
    /// This frame's placement: one instance per drawn path, rebuilt whenever
    /// any window moves.
    frame: gleipnir.scene.Frame = .{},
    pages: [cache_slots]Entry = @splat(.{}),
    stamp: u64 = 0,

    const Entry = struct {
        buffer: u32 = 0,
        page: u32 = Slot.no_page,
        used: u64 = 0,
        /// The page as it was recorded, kept so the shared store can be
        /// rebuilt when the cache changes. A `slug.Store` is append-only --
        /// evicting from the middle of it would renumber every header after
        /// the hole -- so the answer is to merge the survivors again.
        source: ?Scene = null,
        /// Where this page landed in `scene` after the last rebuild.
        range: Scene.Range = .{},
        /// As `Slot.stale`.
        stale: bool = false,
    };

    pub fn deinit(rc: *Recorded, gpa: Allocator) void {
        for (&rc.pages) |*e| {
            if (e.source) |*s| s.deinit(gpa);
        }
        rc.scene.deinit(gpa);
        rc.frame.deinit(gpa);
    }

    fn has(rc: *const Recorded, buffer: u32, page: u32) bool {
        for (rc.pages) |e| {
            if (e.buffer == buffer and e.page == page and e.source != null and !e.stale) return true;
        }
        return false;
    }

    /// Takes ownership of a recording and puts it in a slot, evicting the
    /// least recently drawn page if there is no free one.
    fn insert(rc: *Recorded, gpa: Allocator, buffer: u32, page: u32, source: Scene) Allocator.Error!void {
        var chosen: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        // A page read again takes the place of its old recording, which was
        // drawn until now: nothing draws blank paper over a page it has.
        for (&rc.pages, 0..) |*e, i| {
            if (e.source != null and e.buffer == buffer and e.page == page) {
                chosen = i;
                break;
            }
        } else for (&rc.pages, 0..) |*e, i| {
            if (e.source == null) {
                chosen = i;
                break;
            }
            if (e.used < oldest) {
                oldest = e.used;
                chosen = i;
            }
        }

        const slot = &rc.pages[chosen];
        const evicted = slot.source != null;
        if (slot.source) |*old| old.deinit(gpa);
        slot.* = .{ .buffer = buffer, .page = page, .used = rc.stamp, .source = source };

        if (evicted) {
            // The store is append-only, so a page leaving the middle of it
            // means renumbering everything after the hole. Merging the
            // survivors again is the cheaper answer, and it happens once per
            // page scrolled past rather than per frame.
            try rc.rebuild(gpa);
            return;
        }

        // Filling an empty slot, which is every page until the cache is full:
        // the pages already in the scene keep their ranges, and only the new
        // one is copied in.
        slot.range = try rc.scene.merge(gpa, slot.source.?);
    }

    fn rebuild(rc: *Recorded, gpa: Allocator) Allocator.Error!void {
        rc.scene.reset(.{ 1, 1 });
        for (&rc.pages) |*e| {
            if (e.source) |src| e.range = try rc.scene.merge(gpa, src);
        }
    }

    fn touch(rc: *Recorded, buffer: u32, page: u32) void {
        for (&rc.pages) |*e| {
            if (e.buffer == buffer and e.page == page) e.used = rc.stamp;
        }
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

/// One page of one document, at one zoom: everything that decides what a
/// rasterisation will produce, and so everything needed to say whether one is
/// still wanted.
pub const Job = struct {
    buffer: u32,
    page: u32,
    zoom: f32,
    want: Want = .page,
    /// For an overlay, how far the second document is moved against the
    /// first. In the job and not read off the session, because a nudge on
    /// the frame thread must not change a picture halfway through drawing
    /// it -- and a picture of the old offset is not wanted.
    shift: [2]f32 = .{ 0, 0 },

    /// What the worker is being asked for.
    ///
    /// A page and its text come out of one interpretation, so `.page` is
    /// both. `.text` is the same interpretation with the drawing thrown
    /// away, which is what a search wants from the six hundred pages nobody
    /// is looking at -- rasterising them would be a hundred times the work
    /// for pixels that go straight in the bin. `.overlay` is a page of the
    /// first document of a comparison laid over its partner in the second.
    /// `.reload` is the buffer's file read again, and no page; see `install`.
    pub const Want = enum { page, text, overlay, reload };

    pub fn eql(a: Job, b: Job) bool {
        return a.buffer == b.buffer and a.page == b.page and
            a.zoom == b.zoom and a.want == b.want and std.meta.eql(a.shift, b.shift);
    }
};

/// The rasterising thread.
///
/// One thread, not a pool, because it owns every `Document` -- see the note
/// at the top of the file. One job in flight and one waiting, with the
/// waiting one replaced rather than queued: if the loop has asked for three
/// pages while this thread rendered one, the third is the one on screen now
/// and the other two are behind the scroll.
const Rasteriser = struct {
    session: *Session,
    /// A copy of the process's `Io`, which is what the lock and the condition
    /// are implemented in terms of. Both sides only ever use the uncancelable
    /// operations: this thread is joined explicitly and has nothing to unwind.
    io: Io,
    thread: ?std.Thread = null,

    mutex: Io.Mutex = .init,
    change: Io.Condition = .init,

    want: ?Job = null,
    busy: ?Job = null,
    done: ?Finished = null,
    quit: bool = false,

    /// What one job produced.
    ///
    /// The text map comes with it because both come from one interpretation
    /// of the page, and interpreting it twice -- once for pixels and once for
    /// the cursor -- would double the cost of every page for a feature most
    /// frames do not use.
    const Finished = struct {
        job: Job,
        result: ?Result,
        map: ?text.Page = null,
        /// A `.reload`'s, and nothing else's.
        reload: ?watch.Outcome = null,

        const Result = union(Backend) {
            cpu: Session.Image,
            gpu: Scene,
        };
    };

    fn start(rz: *Rasteriser) !void {
        rz.thread = try std.Thread.spawn(.{}, work, .{rz});
    }

    /// Asks the worker to stop and waits for it. The worker may be halfway
    /// through a page; it finishes that page rather than being interrupted,
    /// because there is no safe point inside a rasterisation to stop at and
    /// a page is a bounded amount of work.
    fn stop(rz: *Rasteriser) void {
        const thread = rz.thread orelse return;
        {
            rz.mutex.lockUncancelable(rz.io);
            defer rz.mutex.unlock(rz.io);
            rz.quit = true;
            rz.change.broadcast(rz.io);
        }
        thread.join();
        rz.thread = null;

        if (rz.done) |*f| {
            rz.session.discard(f);
            rz.done = null;
        }
    }

    fn post(rz: *Rasteriser, job: Job) void {
        rz.mutex.lockUncancelable(rz.io);
        defer rz.mutex.unlock(rz.io);
        if (rz.want) |w| {
            if (w.eql(job)) return;
        }
        if (rz.busy) |b| {
            if (b.eql(job)) return;
        }
        rz.want = job;
        rz.change.signal(rz.io);
    }

    /// Takes the finished page, if there is one. Never waits: a frame that
    /// has nothing new to show still has to be drawn, because the scroll has
    /// moved.
    fn collect(rz: *Rasteriser) ?Finished {
        rz.mutex.lockUncancelable(rz.io);
        defer rz.mutex.unlock(rz.io);
        const f = rz.done orelse return null;
        rz.done = null;
        rz.change.signal(rz.io);
        return f;
    }

    fn work(rz: *Rasteriser) void {
        while (true) {
            rz.mutex.lockUncancelable(rz.io);
            while (!rz.quit and (rz.want == null or rz.done != null)) {
                rz.change.waitUncancelable(rz.io, &rz.mutex);
            }
            if (rz.quit) {
                rz.mutex.unlock(rz.io);
                return;
            }
            const job = rz.want.?;
            rz.want = null;
            rz.busy = job;
            rz.mutex.unlock(rz.io);

            var finished: Finished = .{ .job = job, .result = null };
            rz.session.produce(job, &finished) catch {};

            rz.mutex.lockUncancelable(rz.io);
            rz.busy = null;
            rz.done = finished;
            rz.change.signal(rz.io);
            rz.mutex.unlock(rz.io);
        }
    }
};

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

    backend: Backend = if (have_gpu and !have_cpu) .gpu else .cpu,
    placed: ?u64 = null,
    recorded: Recorded = .{},

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
    drag: ?Drag = null,

    /// The pen, and the stroke it is in the middle of.
    pen: Pen = .{},
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
    typing: ?Typing = null,
    /// The mark `]a` or `]c` last landed on, and the caret that left.
    last_jump: ?Jumped = null,

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

    slots: [cache_slots]Slot = @splat(.{}),
    stamp: u64 = 0,

    dirty_title: bool = true,
    shown: struct { buffer: u32 = 0, page: u32 = Slot.no_page, zoom: f32 = 0, windows: u32 = 0 } = .{},

    pages_rendered: u64 = 0,

    /// Pages that would not rasterise, so `firstMissing` stops asking for
    /// them every frame. Small and forgetful on purpose: a page that failed
    /// because memory was tight should get another chance eventually.
    failures: [16]Job = @splat(.{ .buffer = 0, .page = Slot.no_page, .zoom = 0 }),
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
    boxes: std.ArrayList(PageBox) = .empty,

    /// A selection made with the mouse: which buffer, and its two ends.
    ///
    /// It outlives the button. Letting go of a drag leaves the words selected,
    /// the way letting go in a browser does, and the next press anywhere puts
    /// the selection away. A selection is not a mark on the document: nothing
    /// of it is written to the database and nothing of it survives the
    /// session. `m` is what turns one into a highlight.
    const Drag = struct {
        buffer: u32,
        from: View.Position,
        to: View.Position,
        /// The button is still down, so the far end follows the pointer.
        held: bool = true,
    };

    /// The pen: what the next stroke will look like, and the one being drawn.
    ///
    /// The colour is a palette *index* rather than a `Color`, the way the
    /// highlight digits are, so that a reader who changes their accent finds
    /// the pen changed with it. Null is the reader's own ink colour.
    ///
    /// `page` and `buffer` are which document and which page the stroke in
    /// hand belongs to, and they are fixed when the button goes down: a drag
    /// that wanders onto the next page keeps drawing on the page it started
    /// on, because a stroke is a thing on one page and the alternative is a
    /// line that is cut in half by a gap nobody drew.
    const Pen = struct {
        colour: ?u8 = null,
        /// In PDF points, which is what a `Mark` stores and what keeps the
        /// pen the same weight against the type at every zoom.
        width: f32 = default_pen_width,
        buffer: u32 = 0,
        page: u32 = 0,
        /// True while the button is down and points are being collected.
        down: bool = false,
    };

    pub const Image = struct { pixels: []u8, width: u32, height: u32 };

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
                disk.notice = s.noticeOf(file);
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
        s.loadMarks(id);
        s.rememberFileId(path, doc);
        if (s.stage) |g| g.mark("document");
        s.readAnnots(id, null);
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

    /// Points the focused window at another open document. `<C-w>n`.
    pub fn showBuffer(s: *Session, delta: i32) void {
        if (s.buffers.items.len < 2) return;
        const v = s.view();
        const n: i32 = @intCast(s.buffers.items.len);
        const next: u32 = @intCast(@mod(@as(i32, @intCast(v.buffer)) + delta + n, n));
        if (next == v.buffer) return;

        // Where this window was in the old document is worth keeping: coming
        // back to it with `<C-w>b` should not have lost your place.
        s.rememberPlace(v);

        v.buffer = next;
        v.pages = s.buffer(next).pages;
        v.cursor = .{};
        v.scroll = 0;
        v.pan = 0;
        _ = s.restore(v, next, false, true);
        v.clampScroll();
        s.dirty_title = true;
    }

    // -- what the library remembers ------------------------------------------

    /// Draws everything after this in `t`, with whatever accent is in force.
    ///
    /// One place, so that a theme chosen at startup and one chosen with
    /// `:set` take exactly the same path -- the failure otherwise is the one
    /// where switching in the reader looks right and reopening does not.
    fn useTheme(s: *Session, t: Theme) void {
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

    /// What `comment_anchor` says, or a highlight when it says nothing this
    /// build knows.
    fn rememberedCommentStyle(s: *Session) Marks.Style {
        const lib = s.library orelse return .highlight;
        const said = (lib.get("comment_anchor") catch null) orelse return .highlight;
        defer s.gpa.free(said);
        return commentStyleNamed(said) orelse .highlight;
    }

    fn commentStyleNamed(name: []const u8) ?Marks.Style {
        if (std.mem.eql(u8, name, "highlight")) return .highlight;
        if (std.mem.eql(u8, name, "arrow")) return .arrow;
        return null;
    }

    /// Fills the settings page with what the library holds now.
    ///
    /// Called when the page opens and after every change, and nowhere near a
    /// frame: `Library.get` asks SQLite and allocates, and this reader does
    /// not allocate on a frame path. With no library every row is unset,
    /// which is the truth -- there is nowhere for a setting to have been
    /// written.
    fn readSettings(s: *Session) void {
        s.fillPluginSettings();
        var i: usize = 0;
        while (i < s.settings.count()) : (i += 1) {
            const lib = s.library orelse {
                s.settings.put(i, null);
                continue;
            };
            var buf: [256]u8 = undefined;
            const key = s.settingKey(&buf, i) orelse {
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
    fn settingKey(s: *Session, buf: []u8, index: usize) ?[]const u8 {
        const opt = s.settings.optionAt(index);
        if (!s.settings.isPlugin(index)) return opt.key;
        return library.pluginKey(buf, "", opt.key);
    }

    /// Whether what plugins declared has moved since the page was filled.
    ///
    /// Asked every frame the page is open, because a callback can declare,
    /// replace or clear a setting at any point and the page is holding
    /// Galdr's bytes until it is refilled.
    fn pluginSettingsStale(s: *const Session) bool {
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
    fn changeSetting(s: *Session, c: settings_page.Change) void {
        if (std.mem.eql(u8, c.key, "theme")) {
            const t = Theme.byName(c.value) orelse {
                s.say("no theme called {s}", .{c.value[0..@min(c.value.len, 48)]});
                return;
            };
            s.useTheme(t);
        } else if (std.mem.eql(u8, c.key, "comment_anchor")) {
            s.comment_style = if (c.value.len == 0) .highlight else commentStyleNamed(c.value) orelse {
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
        const where = s.settingKey(&buf, c.index) orelse return;
        if (c.value.len == 0) lib.remove(where) catch {} else lib.set(where, c.value) catch {};
        s.readSettings();
        s.say("{s} = {s}", .{ c.key, if (c.value.len == 0) "unset" else c.value });
    }

    /// Takes from the library where this document was left, and puts the view
    /// there. Returns the place if there was one.
    ///
    /// `--page` and `--zoom` win: an explicit argument is a person saying
    /// where to start, and remembering over the top of that is the kind of
    /// helpfulness that has to be fought.
    fn restore(s: *Session, v: *View, index: u32, page_given: bool, zoom_free: bool) ?View.Place {
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

    /// Reads this document's marks, and the comments on them, into its
    /// buffer. A row with no name becomes an anchor of its own.
    fn loadMarks(s: *Session, index: u32) void {
        const lib = s.library orelse return;
        const b = s.buffer(index);

        const list = lib.marks(b.path) catch return;
        defer lib.freeMarks(list, list.len);

        for (list) |h| {
            const color = Library.parseColor(h.color) orelse s.highlight;
            _ = b.marks.add(s.gpa, .{
                .id = h.id,
                .page = h.page,
                .box = .fromRect(h.x0, h.y0, h.x1, h.y1),
                .color = color,
                .style = std.meta.stringToEnum(Marks.Style, h.style) orelse .highlight,
                .anchor = (s.nameOf(b, h.anchor) catch return) orelse 0,
            }, true) catch return;
        }

        // The ink after the highlights, so a stroke drawn over a highlight is
        // on top of it -- which is the order they were made in and the order
        // an opaque pen over a wash has to be drawn in to look right.
        const ink = lib.strokes(b.path) catch return;
        defer lib.freeStrokes(ink, ink.len);

        for (ink) |k| {
            _ = b.marks.add(s.gpa, .{
                .id = k.id,
                .kind = .ink,
                .page = k.page,
                .points = k.points,
                .width = if (k.width > 0) k.width else default_pen_width,
                .color = Library.parseColor(k.color) orelse ink_colour,
                .anchor = (s.nameOf(b, k.anchor) catch return) orelse 0,
            }, true) catch return;
        }

        const said = lib.comments(b.path) catch return;
        defer lib.freeComments(said, said.len);

        for (said) |c| {
            const anchor = (s.nameOf(b, c.anchor) catch return) orelse continue;
            _ = b.marks.addComment(s.gpa, .{
                .id = c.id,
                .anchor = anchor,
                .name = (s.nameOf(b, c.nm) catch return) orelse 0,
                .text = c.text,
            }, true) catch return;
        }
    }

    /// The number a written name stands for in this buffer: one of fenrir's
    /// read as the number it spells, anybody else's held as it was written
    /// (`Marks.foreignName`). Null for no name.
    fn nameOf(s: *Session, b: *Buffer, nm: []const u8) Allocator.Error!?u64 {
        if (nm.len == 0) return null;
        if (Library.nameNumber(nm)) |n| {
            if (n < Marks.foreign_base) return n;
        }
        return try b.marks.foreignName(s.gpa, nm);
    }

    /// How a name is written down: the other half of `nameOf`.
    pub fn spell(b: *const Buffer, n: u64, buf: *[Library.name_len]u8) []const u8 {
        return b.marks.spelling(n) orelse Library.makeName(buf, n);
    }

    /// Takes the marks and comments already in the file: a highlight made
    /// in Acrobat or Zotero, its note and the replies to it.
    ///
    /// Every page, once, at open, on this thread: no page of the document
    /// has been asked of the rasterising thread yet, so it is still this
    /// thread's to read. The whole document rather than each page as it is
    /// wanted, because it costs little -- 3.5 ms for 1,486 annotations on
    /// 286 pages, 1.0 ms for a paper with 328, best of five, ReleaseFast --
    /// and a page at a time, the panel, `]c` and the next free name would
    /// each wait on pages nobody had scrolled to. `--time` prints it.
    ///
    /// **The library wins.** Its rows are what this reader changed since the
    /// file was written, so a name it already holds is not read again from
    /// the file: an anchor's lines, or a comment.
    ///
    /// A reload hands in what the worker read beside the file
    /// (`watch.Loaded.annots`), so that the frame thread does not walk the
    /// file again: on a 286-page book that walk was most of what installing
    /// a reload cost.
    fn readAnnots(s: *Session, index: u32, already: ?[]const []const fenrir.annots.Annot) void {
        const b = s.buffer(index);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // What the library put there, asked once rather than once per
        // annotation: `lineCount` walks every mark.
        var held: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (b.marks.items()) |m| held.put(a, m.anchor, {}) catch return;
        for (b.marks.comments.items) |c| held.put(a, c.name, {}) catch return;

        // What a reload takes away and reads again.
        const taken: ?*std.AutoHashMapUnmanaged(u64, void) = if (index < s.disks.items.len) &s.disks.items[index].taken else null;
        for (b.pages, 0..) |p, page| {
            const list = if (already) |read| (if (page < read.len) read[page] else &.{}) else fenrir.annots.read(a, b.doc, p) catch continue;
            if (list.len == 0) continue;
            s.takeAnnots(a, b, @intCast(page), list, &held, taken) catch return;
        }
    }

    fn takeAnnots(
        s: *Session,
        a: Allocator,
        b: *Buffer,
        page: u32,
        list: []const fenrir.annots.Annot,
        held: *const std.AutoHashMapUnmanaged(u64, void),
        taken: ?*std.AutoHashMapUnmanaged(u64, void),
    ) Allocator.Error!void {
        // The anchor each was taken as, so a reply finds its thread's.
        const anchors = try a.alloc(u64, list.len);
        for (list, anchors) |annot, *anchor| {
            if (annot.kind == .reply) continue;
            anchor.* = try s.nameOf(b, annot.name) orelse b.marks.newName();
            if (held.contains(anchor.*)) continue;
            if (taken) |t| try t.put(s.gpa, anchor.*, {});

            switch (annot.kind) {
                .ink => for (annot.paths) |path| {
                    _ = try b.marks.add(s.gpa, .{
                        .kind = .ink,
                        .page = page,
                        .points = path,
                        .width = if (annot.width > 0) annot.width else default_pen_width,
                        .color = annot.color orelse ink_colour,
                        .anchor = anchor.*,
                    }, true);
                },
                else => for (annot.lines) |box| {
                    _ = try b.marks.add(s.gpa, .{
                        .page = page,
                        .box = box,
                        .color = annot.color orelse s.highlight,
                        .style = styleOfAnnot(annot.kind),
                        .anchor = anchor.*,
                    }, true);
                },
            }
            // The markup's own note is the first comment, and has its name.
            if (annot.text.len != 0) {
                _ = try b.marks.addComment(s.gpa, .{ .anchor = anchor.*, .name = anchor.*, .text = annot.text }, true);
            }
        }

        for (list) |annot| {
            if (annot.kind != .reply or annot.text.len == 0) continue;
            const thread = annot.thread orelse continue;
            // A reply with no name of its own gets a new one rather than
            // the anchor's, which would make it the note on the markup.
            const name = try s.nameOf(b, annot.name) orelse b.marks.newName();
            if (held.contains(name)) continue;
            if (taken) |t| try t.put(s.gpa, name, {});
            _ = try b.marks.addComment(s.gpa, .{ .anchor = anchors[thread], .name = name, .text = annot.text }, true);
        }
    }

    fn styleOfAnnot(kind: fenrir.annots.Kind) Marks.Style {
        return switch (kind) {
            .highlight => .highlight,
            .underline => .underline,
            .strikeout => .strikeout,
            .squiggly => .squiggly,
            .arrow => .arrow,
            .ink, .reply => unreachable,
        };
    }

    /// Writes down that a document was opened, and where.
    fn remember(s: *Session, v: *View) void {
        if (!s.remembers_place) return;
        const lib = s.library orelse return;
        const b = s.buffer(v.buffer);
        lib.visit(b.path, b.title, placeOf(v), library.now(s.ctx.io)) catch {};
    }

    /// Writes down where a window was left, without counting another opening.
    fn rememberPlace(s: *Session, v: *View) void {
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

    // -- watching ------------------------------------------------------------

    /// What the `watch` setting says: on, or anything else, which is off.
    fn rememberedWatch(s: *Session) bool {
        const lib = s.library orelse return false;
        const said = (lib.get("watch") catch null) orelse return false;
        defer s.gpa.free(said);
        return std.mem.eql(u8, said, "on");
    }

    /// Follows the files, or holds them shut. Turned off, a file another
    /// program wrote while it was followed is read once more, so that what
    /// is held is what is shown.
    fn setWatching(s: *Session, on: bool) void {
        if (s.diff != null or s.watching == on) return;
        s.watching = on;
        const io = s.io orelse return;
        for (s.disks.items, s.buffers.items) |*d, b| {
            if (on) {
                if (d.hold) |*h| h.release(io);
                d.hold = null;
                d.notice = s.noticeOf(b.path);
                continue;
            }
            if (d.notice) |n| n.stop(s.gpa);
            d.notice = null;
            d.stirred = false;
            d.hold = watch.Hold.take(io, b.path) catch null;
            const stamp = watch.stat(io, b.path) orelse continue;
            if (!stamp.eql(d.held) and d.reload == .none) d.reload = .auto;
        }
    }

    /// What tells the reader that `path` changed, or null where nothing
    /// will, and it is looked at every `watch.interval_ns` instead.
    fn noticeOf(s: *Session, path: []const u8) ?*watch.Notice {
        return watch.Notice.start(s.gpa, path) catch |err| {
            // Expected where there are no notices, and not worth a line.
            if (err != error.Unsupported) s.ctx.note("{s} is looked at twice a second: no notices ({t})", .{ path, err });
            return null;
        };
    }

    /// Asks each followed file's notice what happened, and looks at the
    /// file -- a stat, never a read, and nothing allocated -- only when
    /// `watch.tick` says to. `dt` is the frame clock's, which the loop reads
    /// anyway.
    fn poll(s: *Session, dt: f32) void {
        if (!s.watching) return;
        const io = s.io orelse return;
        for (s.disks.items, s.buffers.items) |*d, b| {
            var said: ?watch.Notice.Said = null;
            if (d.notice) |n| {
                said = n.take(dt);
                if (said == .gone) {
                    n.stop(s.gpa);
                    d.notice = null;
                    said = null;
                    s.say("{s} is looked at twice a second: no more notices", .{b.title});
                }
            }
            // Taken while a reload is pending too, so that a write during
            // one is looked into after it.
            if (!watch.tick(d, dt, said) or d.reload != .none) continue;
            const stamp = watch.stat(io, b.path) orelse continue;
            if (watch.due(d, stamp)) d.reload = .auto;
        }
    }

    /// A file waiting to be read again, as a job.
    fn reloadJob(s: *Session) ?Job {
        for (s.disks.items, 0..) |d, i| {
            if (d.reload != .none) return .{ .buffer = @intCast(i), .page = 0, .zoom = 0, .want = .reload };
        }
        return null;
    }

    /// What the worker is asked for next.
    ///
    /// **While a reload is pending, nothing else.** A page asked of the old
    /// document after it would be drawn from a document `install` frees, and
    /// with nothing else posted the worker is parked when the reload comes
    /// back -- which is what lets `install` free it on this thread.
    fn jobToPost(s: *Session) ?Job {
        return s.reloadJob() orelse s.nextJob();
    }

    /// Puts what a reload read in place of what the buffer had: the
    /// document, its pages and outline, and everything that knew them.
    /// Only from `collectPage`, with the worker parked; see `jobToPost`.
    fn install(s: *Session, index: u32, outcome: watch.Outcome) void {
        var lap: ?Lap = if (s.io) |io| .start(io) else null;
        const d = &s.disks.items[index];
        const b = s.buffer(index);
        const forced = d.reload == .forced;
        d.reload = .none;

        var loaded = switch (outcome) {
            .refused => |r| {
                d.refused = r.stamp;
                if (forced) {
                    s.say("{s} would not open: {t}", .{ b.title, r.why });
                } else {
                    s.say("{s} is incomplete; showing gen {d}", .{ b.title, d.generation });
                }
                return;
            },
            .loaded => |l| l,
        };

        const before = b.pages.len;
        b.doc.deinit();
        s.gpa.destroy(b.doc);
        b.doc = loaded.doc;
        b.pages = loaded.pages;
        b.outline = loaded.outline;

        // What the pages were, kept until each window's caret has asked.
        const was = d.digests;
        const old = loaded.old_digests orelse was;
        defer {
            s.gpa.free(was);
            if (loaded.old_digests) |o| s.gpa.free(o);
        }
        d.digests = loaded.digests;
        d.held = loaded.stamp;
        d.seen = loaded.stamp;
        d.generation += 1;

        s.stalePages(index, @intCast(b.pages.len));
        b.dropMaps(s.gpa);
        if (loaded.map) |*m| {
            if (loaded.first) |page| b.putMap(s.gpa, page, m.*) else m.deinit(s.gpa);
        }
        // Keyed by the old document's object numbers.
        if (index < s.faces.items.len) {
            s.faces.items[index].deinit();
            s.faces.items[index] = .init(s.gpa);
        }

        var it = s.tabs.iterator();
        while (it.next()) |v| {
            if (v.buffer != index) continue;
            v.pages = b.pages;
            v.refit();
            s.keepCursor(v, old, d.digests);
            v.clampScroll();
        }
        if (s.drag) |drag| {
            const kept = watch.unchanged(old, d.digests, drag.from.page) and watch.unchanged(old, d.digests, drag.to.page);
            if (drag.buffer == index and !kept) s.drag = null;
        }
        if (loaded.first) |page| s.placeStale(index, page);
        s.rows_for = .{};

        // The file's own annotations, read again: those the library holds
        // stay, as they do at open.
        _ = b.marks.forget(s.gpa, &d.taken) catch 0;
        d.taken.clearRetainingCapacity();
        s.readAnnots(index, loaded.annots);
        if (loaded.annots_arena) |*a| a.deinit();

        if (loaded.first) |page| s.showChange(index, page, loaded.down);
        if (s.view().buffer == index and s.find.query().len != 0) s.requery();

        var count_buf: [32]u8 = undefined;
        const counted = if (b.pages.len == before) "" else std.fmt.bufPrint(&count_buf, ", {d} pages", .{b.pages.len}) catch "";
        if (loaded.first) |page| {
            s.say("gen {d}: page {d} changed{s}", .{ d.generation, page + 1, counted });
        } else {
            s.say("gen {d}: no page changed{s}", .{ d.generation, counted });
        }

        if (s.plugins) |rt| {
            const doc = plugins_mod.handleOf(s, index);
            rt.emit(.{ .event = .DocReload, .doc = doc, .path = b.path, .data = .{ .document = .{
                .handle = doc,
                .path = b.path,
                .title = b.title,
                .pages = @intCast(b.pages.len),
            } } });
        }
        if (s.timing) {
            const ns = loaded.ns;
            // `heard`: from the first notice to the look that found the file
            // still, so the rest of the line is what it cost after that.
            s.ctx.note("watch  gen {d}  heard {d:.0}ms  read {d:.1}  open {d:.1}  annots {d:.1}  digest {d:.1}  locate {d:.1}  install {d:.1}", .{
                d.generation,    d.heard * 1000,  msOf(ns.read),                      msOf(ns.open), msOf(ns.annots),
                msOf(ns.digest), msOf(ns.locate), if (lap) |*l| msOf(l.lap()) else 0,
            });
        }
        d.heard = 0;
    }

    /// Where a window's caret is after its document is read again.
    ///
    /// On a page that reads as it did, where it was: its line and column
    /// count the same text. On one that changed, it keeps its place on the
    /// page and is put on the nearest glyph when the page's text comes
    /// (`placeStale`). A page that is gone sends it to the top of the last.
    /// A selection with an end on a changed page goes, and visual mode with
    /// it.
    ///
    /// The author asked that a reload keep the caret; it first went to the
    /// top of its page on every one. Do not go back to resetting it.
    fn keepCursor(s: *Session, v: *View, old: []const u64, new: []const u64) void {
        const kept = watch.unchanged(old, new, v.cursor.page);
        const last: u32 = @intCast(v.pages.len - 1);
        if (v.cursor.page > last) {
            v.cursor.page = last;
            v.cursor.line = 0;
            v.cursor.column = 0;
            v.cursor.caret = .empty;
            v.cursor.stale = false;
        } else if (!kept) {
            v.cursor.stale = true;
        }
        const anchor = v.anchor orelse return;
        if (kept and watch.unchanged(old, new, anchor.page)) return;
        v.anchor = null;
        if (v == s.layout().current() and s.keymap.mode.isVisual()) s.keymap.mode = .normal;
    }

    /// The text of `page` has come: a caret a reload left stale on it is put
    /// on the glyph nearest where it was.
    fn placeStale(s: *Session, index: u32, page: u32) void {
        const map = s.buffer(index).textMap(page) orelse return;
        var it = s.tabs.iterator();
        while (it.next()) |v| {
            if (v.buffer == index and v.cursor.stale and v.cursor.page == page) v.cursorNear(map);
        }
    }

    /// Every cached picture of a buffer's pages is stale, and drawn until
    /// its page comes again; a page past the new end is dropped.
    fn stalePages(s: *Session, index: u32, pages: u32) void {
        for (&s.slots) |*slot| {
            if (slot.buffer != index or slot.page == Slot.no_page) continue;
            if (slot.page >= pages) {
                slot.page = Slot.no_page;
                slot.stale = false;
            } else slot.stale = true;
        }
        var dropped = false;
        for (&s.recorded.pages) |*e| {
            if (e.buffer != index or e.source == null) continue;
            if (e.page >= pages) {
                e.source.?.deinit(s.gpa);
                e.* = .{};
                dropped = true;
            } else e.stale = true;
        }
        if (dropped) s.recorded.rebuild(s.gpa) catch {};
        s.placed = null;
        // A page that would not draw before may now.
        for (&s.failures) |*f| {
            if (f.buffer == index) f.* = .{ .buffer = 0, .page = Slot.no_page, .zoom = 0 };
        }
    }

    /// Takes a window on the buffer to where a reload changed it: the focused
    /// one if it shows the buffer, else the first that does. A change already
    /// on screen moves nothing, and the other windows keep their place.
    fn showChange(s: *Session, index: u32, page: u32, down: f32) void {
        const v = if (s.view().buffer == index) s.view() else blk: {
            var it = s.layout().iterator();
            while (it.next()) |w| {
                if (w.buffer == index) break :blk w;
            }
            return;
        };
        if (page >= v.pages.len) return;
        const at = v.pageTop(page) + down * v.zoom;
        if (at >= v.scroll and at <= v.scroll + v.height()) return;
        // What led up to the change stays on screen above it, as for `]d`.
        v.goTo(.{ .page = page, .offset = down - v.height() * compare.lead_in / v.zoom, .zoom = v.zoom });
    }

    // -- work ----------------------------------------------------------------

    /// One job's worth of work, on the rasterising thread, in whichever form
    /// this backend wants it -- plus the page's text map, since both come out
    /// of one interpretation.
    fn produce(s: *Session, job: Job, out: *Rasteriser.Finished) !void {
        const gpa = s.gpa;
        const b = s.buffer(job.buffer);

        // The file again, read beside the document it replaces, which this
        // thread owns. `reload` was written before the job was posted, and
        // the post's lock orders the two.
        if (job.want == .reload) {
            const d = &s.disks.items[job.buffer];
            const old: watch.Old = .{ .doc = b.doc, .pages = b.pages, .digests = d.digests };
            out.reload = watch.load(gpa, s.ctx.io, b.path, old, d.reload == .forced, page_options);
            return;
        }

        // Two pages and no text map: the cursor's map is a `.page` job's,
        // asked for separately when the cursor wants it.
        if (job.want == .overlay) {
            out.result = .{ .cpu = try compare.rasteriseOverlay(s, job) };
            return;
        }

        var result = try content.page(gpa, b.doc, b.pages[job.page], page_options);
        defer result.deinit(gpa);

        // The text map first, and separately failable: a page whose pixels
        // will not come out should still be one the cursor can move through,
        // and vice versa.
        out.map = text.build(gpa, result.list) catch null;
        errdefer if (out.map) |*m| m.deinit(gpa);

        // A search wants the words and not the picture.
        if (job.want == .text) return;

        out.result = switch (s.backend) {
            .cpu => .{ .cpu = try s.rasterise(job, result.list, b) },
            // No zoom in it: the outline is recorded in page space and the
            // frame loop places it. That is the whole reason a zoom on the
            // GPU path is instant and on the CPU path is a re-render.
            .gpu => .{ .gpu = try s.recordPage(job, result.list, b) },
        };
    }

    /// Frees a finished job the frame loop is not going to use.
    fn discard(s: *Session, f: *Rasteriser.Finished) void {
        if (f.reload) |*o| switch (o.*) {
            .loaded => |*l| l.deinit(s.gpa),
            .refused => {},
        };
        f.reload = null;
        if (f.map) |*m| m.deinit(s.gpa);
        f.map = null;
        const result = &(f.result orelse return);
        switch (result.*) {
            .cpu => |image| s.gpa.free(image.pixels),
            .gpu => |*scene| scene.deinit(s.gpa),
        }
        f.result = null;
    }

    fn failed(s: *const Session, job: Job) bool {
        for (s.failures) |f| {
            if (f.eql(job)) return true;
        }
        return false;
    }

    fn noteFailure(s: *Session, job: Job) void {
        s.failures[s.failure_next] = job;
        s.failure_next = (s.failure_next + 1) % s.failures.len;
    }

    /// One page, rasterised. The same calls `fenrir raster` makes, which is
    /// why the two produce identical images.
    ///
    /// **Runs on the rasterising thread.** The zoom comes from the job rather
    /// than from the view, because a view belongs to the frame loop and can
    /// change underneath this at any moment.
    fn rasterise(s: *Session, job: Job, list: gelgja.DisplayList, b: *Buffer) !Image {
        var canvas = try s.drawCanvas(job.buffer, job.page, list, job.zoom, .{ 0, 0 }, b);
        defer canvas.deinit(s.gpa);
        return .{
            .pixels = try canvas.fb.toRgba8(s.gpa),
            .width = canvas.width(),
            .height = canvas.height(),
        };
    }

    /// The page on white paper at a zoom, or at half of it as often as the
    /// canvas has to be halved to fit `max_page_pixels`.
    pub fn drawCanvas(
        s: *Session,
        buffer_index: u32,
        page: u32,
        list: gelgja.DisplayList,
        want_zoom: f32,
        // Points across and down: the offset a comparison moves its second
        // document by, and nothing for a page drawn for itself.
        shift: [2]f32,
        b: *Buffer,
    ) !gleipnir.raster.Canvas {
        const gpa = s.gpa;

        var zoom = want_zoom;
        var size = replay.canvasSize(list.page, zoom);
        while (@as(u64, size[0]) * size[1] > max_page_pixels and zoom > min_zoom) {
            zoom *= 0.5;
            size = replay.canvasSize(list.page, zoom);
        }

        var canvas = try gleipnir.raster.Canvas.init(gpa, size[0], size[1], .{ .samples = s.samples });
        errdefer canvas.deinit(gpa);
        canvas.fb.clear(.white);

        var glyphs: Glyphs = try .init(gpa, b.doc, list, s.ctx.io, &s.faces.items[buffer_index]);
        defer glyphs.deinit();

        var images: Images = .init(gpa, b.doc, b.pages[page].resources);
        defer images.deinit();

        // Text through the analytic fill, and not the stencil the figures
        // use. The author compared a displayed equation here against Acrobat
        // and the eight-sample glyphs were a staircase beside it: nine grey
        // levels, which on an italic at a reading size is the whole edge.
        // Do not fold this back into one backend for tidiness; see
        // `replay.Options.analytic_glyphs`.
        _ = try replay.render(
            gpa,
            &canvas,
            list,
            replay.pageTransform(list.page, zoom).concat(.translation(shift[0] * zoom, shift[1] * zoom)),
            .{ .glyphs = glyphs.source(), .images = images.source(), .analytic_glyphs = true },
        );
        return canvas;
    }

    /// One page, recorded as outlines for the GPU pipeline, in *page space*:
    /// the page's own flip, with no zoom and no scroll in it. The curves that
    /// come out are good at every zoom, which is what the pipeline is for --
    /// and why two windows at two zooms share one recording.
    fn recordPage(s: *Session, job: Job, list: gelgja.DisplayList, b: *Buffer) !Scene {
        const gpa = s.gpa;

        var scene: Scene = .{};
        errdefer scene.deinit(gpa);
        const size = replay.canvasSize(list.page, 1.0);
        scene.reset(.{ @floatFromInt(size[0]), @floatFromInt(size[1]) });

        var glyphs: Glyphs = try .init(gpa, b.doc, list, s.ctx.io, &s.faces.items[job.buffer]);
        defer glyphs.deinit();

        var images: Images = .init(gpa, b.doc, b.pages[job.page].resources);
        defer images.deinit();

        _ = try replay.record(
            gpa,
            &scene,
            list,
            replay.pageTransform(list.page, 1.0),
            .{ .glyphs = glyphs.source(), .images = images.source() },
        );
        return scene;
    }

    // -- the cache -----------------------------------------------------------

    /// Whether a page is ready to draw for a given view.
    ///
    /// The two backends disagree about what "at this zoom" means, and that
    /// difference is the whole point of the GPU one: a rasterised page is
    /// pixels at one scale and a recorded one is curves at every scale, so a
    /// zoom throws away the CPU cache and leaves the GPU cache untouched --
    /// and two windows at two zooms need two CPU entries and one GPU entry.
    fn cached(s: *const Session, v: *const View, page: u32) bool {
        // An overlay is pixels on either backend: see `rasteriseOverlay`.
        if (compare.overlaid(s, v)) return s.cachedSlot(v.buffer, page, v.zoom, true) != null;
        return switch (s.backend) {
            .cpu => s.cachedSlot(v.buffer, page, v.zoom, false) != null,
            .gpu => s.recorded.has(v.buffer, page),
        };
    }

    fn cachedSlot(s: *const Session, buf: u32, page: u32, zoom: f32, overlay: bool) ?*const Slot {
        for (&s.slots) |*slot| {
            // A stale page is still drawn, by `slotFor`, and is not the page
            // that was asked for.
            if (slot.matches(buf, page, zoom, overlay) and !slot.stale) return slot;
        }
        return null;
    }

    fn slotFor(s: *Session, buf: u32, page: u32, zoom: f32, overlay: bool) ?*Slot {
        for (&s.slots) |*slot| {
            if (slot.matches(buf, page, zoom, overlay)) return slot;
        }
        return null;
    }

    /// The first page any window needs and has not got.
    ///
    /// Windows are asked in layout order and pages top-down within each, so a
    /// fresh split fills in the way a person reads rather than in page order.
    /// The focused window goes first, because that is the one being looked at.
    pub fn firstMissing(s: *Session) ?Job {
        if (s.missingIn(s.layout().current())) |job| return job;
        var it = s.layout().iterator();
        while (it.next()) |v| {
            if (s.missingIn(v)) |job| return job;
        }

        return null;
    }

    /// What to hand the rasterising thread next: everything on screen first,
    /// and then, if the cache has room to spare, the pages just past the edge
    /// of a window.
    ///
    /// Separate from `firstMissing` because the two questions differ. "Is
    /// anything missing?" decides whether `--shot` may take its picture, and
    /// a shot that waited for pages outside the frame would wait for pages it
    /// is never going to photograph.
    fn nextJob(s: *Session) ?Job {
        if (s.firstMissing()) |job| return job;
        if (!s.hasSpareSlot()) return null;

        // Only once nothing on screen is outstanding: a page just off the
        // edge must never be rendered ahead of one the reader is looking at,
        // or a split would sit on blank paper while the worker filled a page
        // nobody can see.
        if (s.aheadIn(s.layout().current())) |job| return job;
        var it = s.layout().iterator();
        while (it.next()) |v| {
            if (s.aheadIn(v)) |job| return job;
        }

        // Last of all, and deliberately: a search over six hundred pages is
        // six hundred interpretations, and a reader who scrolls while it
        // runs must not wait behind a page they cannot see. The scan gets
        // whatever is left over, one page at a time, and stops the instant
        // something on screen is missing.
        return s.searchJob();
    }

    /// The next page the search wants interpreted, if it wants one.
    fn searchJob(s: *Session) ?Job {
        const page = s.search.frontier() orelse return null;
        const v = s.layout().current();
        if (page >= v.pages.len) return null;
        return .{ .buffer = v.buffer, .page = page, .zoom = v.zoom, .want = .text };
    }

    /// Whether the cache has a slot the windows are not already using.
    ///
    /// Without this, four windows at a zoom that shows three pages each would
    /// want more slots for what is on screen than there are, and every
    /// read-ahead page would evict a page a window is looking at -- which the
    /// next frame would ask for again. The reader would render continuously
    /// and show nothing new. Read-ahead is a use for slack, so it only
    /// happens when there is slack.
    fn hasSpareSlot(s: *Session) bool {
        var held: usize = 0;
        switch (s.backend) {
            .cpu => for (&s.slots) |*slot| {
                if (slot.page != Slot.no_page and slot.used >= s.stamp) held += 1;
            },
            .gpu => for (&s.recorded.pages) |*e| {
                if (e.source != null and e.used >= s.recorded.stamp) held += 1;
            },
        }
        return held < cache_slots;
    }

    /// How many pages past each edge of the viewport to render before the
    /// reader asks for them.
    ///
    /// One each way, not more. A page is tens of megabytes and a hundred-odd
    /// milliseconds, the cache holds twelve of them across every window, and
    /// the worker renders one at a time -- so a deeper run-up would spend the
    /// cache on pages a reader who turns round never sees, and would put a
    /// real page behind a speculative one for a tenth of a second at a time.
    /// One is what a scroll needs: by the time the page below the fold comes
    /// into view it has been there for a while.
    const read_ahead = 1;

    /// The pages just outside a window, rendered before they are needed.
    ///
    /// Below first, then above, because reading goes downwards and a wheel
    /// that has been turning one way will keep turning that way.
    fn aheadIn(s: *Session, v: *View) ?Job {
        const range = v.visiblePages();

        var after = range.end;
        while (after < @min(range.end + read_ahead, v.pages.len)) : (after += 1) {
            const job: Job = .{ .buffer = v.buffer, .page = after, .zoom = v.zoom, .want = compare.pixelsFor(s, v), .shift = compare.shiftFor(s, v) };
            if (s.failed(job)) continue;
            if (!s.cached(v, after)) return job;
        }

        var back: u32 = 0;
        while (back < read_ahead and back < range.first) : (back += 1) {
            const page = range.first - 1 - back;
            const job: Job = .{ .buffer = v.buffer, .page = page, .zoom = v.zoom, .want = compare.pixelsFor(s, v), .shift = compare.shiftFor(s, v) };
            if (s.failed(job)) continue;
            if (!s.cached(v, page)) return job;
        }
        return null;
    }

    fn missingIn(s: *Session, v: *View) ?Job {
        const range = v.visiblePages();
        var i = range.first;
        while (i < range.end) : (i += 1) {
            const job: Job = .{ .buffer = v.buffer, .page = i, .zoom = v.zoom, .want = compare.pixelsFor(s, v), .shift = compare.shiftFor(s, v) };
            if (s.failed(job)) continue;
            if (!s.cached(v, i)) return job;
        }
        // The cursor needs a text map even for a page whose pixels are
        // already cached -- a window that has not moved since the map was
        // evicted would otherwise have a cursor that cannot cross a page.
        if (v.cursor.visible and !s.buffer(v.buffer).hasMap(v.cursor.page)) {
            const job: Job = .{ .buffer = v.buffer, .page = v.cursor.page, .zoom = v.zoom };
            if (!s.failed(job)) return job;
        }
        // A selection's text on every page it spans, so a selection extended
        // off the screen still draws -- a few pages each way, not a whole
        // chapter's worth of interpretation for one held key.
        if (v.selection()) |sel| {
            const last = @min(sel[1].page, sel[0].page + 8);
            var page = sel[0].page;
            while (page <= last and page < v.pages.len) : (page += 1) {
                if (s.buffer(v.buffer).hasMap(page)) continue;
                const job: Job = .{ .buffer = v.buffer, .page = page, .zoom = v.zoom };
                if (!s.failed(job)) return job;
            }
        }
        return null;
    }

    /// Takes whatever the rasterising thread finished and puts it away,
    /// returning the pixel buffer the caller must keep alive until the frame
    /// has been submitted -- `Upload.pixels` is read during `frame`.
    fn collectPage(
        s: *Session,
        worker: *Rasteriser,
        renderer: *lyngvi.Renderer,
        list: *DrawList,
        uploads: *std.ArrayList(lyngvi.Renderer.Upload),
    ) !?[]u8 {
        const gpa = s.gpa;
        var finished = worker.collect() orelse return null;

        if (finished.job.want == .reload) {
            // The worker is parked: nothing else was posted while this was
            // pending (`jobToPost`), so the document it replaces is this
            // thread's to free.
            const outcome = finished.reload orelse return null;
            s.install(finished.job.buffer, outcome);
            return null;
        }

        if (finished.job.want == .text) {
            // The scan's own page, and it is not cached: the buffer keeps
            // eight maps for the cursor to walk through, and a search that
            // put six hundred of them through that cache would evict the
            // eight that were doing something.
            //
            // A page that would not interpret still counts as scanned. The
            // alternative is a frontier that never advances and a search
            // that spins on one broken page forever.
            var map = finished.map orelse text.Page{};
            defer map.deinit(gpa);
            finished.map = null;
            s.search.take(gpa, finished.job.page, map) catch {};
            return null;
        }

        if (finished.map) |map| {
            s.buffer(finished.job.buffer).putMap(gpa, finished.job.page, map);
            finished.map = null;
            s.placeStale(finished.job.buffer, finished.job.page);
        }

        const result = finished.result orelse {
            // A page that will not interpret is a blank page, not a dead
            // reader. Remembering that it failed is what stops the loop
            // asking for it again on every frame for the rest of the session.
            s.noteFailure(finished.job);
            return null;
        };

        if (result == .gpu) {
            // The recording is in page space, so a zoom change does not make
            // it stale the way it makes a rasterised page stale.
            var source = result.gpu;
            errdefer source.deinit(gpa);
            try s.recorded.insert(gpa, finished.job.buffer, finished.job.page, source);
            s.pages_rendered += 1;
            plugins_mod.announceRender(s, finished.job);
            s.placed = null;
            return null;
        }

        const image = result.cpu;
        errdefer gpa.free(image.pixels);

        // The zoom may have changed while this was rendering, which makes the
        // image the right picture at the wrong size. Caching it would put a
        // stale page on screen that never refreshes.
        if (!s.wantedNow(finished.job)) {
            gpa.free(image.pixels);
            return null;
        }

        // A page read again goes where its old pixels are, which were drawn
        // until now: nothing draws blank paper over a page it has.
        const slot = if (s.slotFor(finished.job.buffer, finished.job.page, finished.job.zoom, finished.job.want == .overlay)) |old|
            try resize(renderer, list, old, image.width, image.height)
        else
            try s.claim(renderer, list, image.width, image.height);
        slot.stale = false;
        slot.buffer = finished.job.buffer;
        slot.page = finished.job.page;
        slot.zoom = finished.job.zoom;
        slot.overlay = finished.job.want == .overlay;
        slot.width = image.width;
        slot.height = image.height;
        slot.used = s.stamp;

        try uploads.append(gpa, .{
            .texture = slot.gpu,
            .x = 0,
            .y = 0,
            .w = image.width,
            .h = image.height,
            .pixels = image.pixels,
            .stride = image.width * 4,
        });
        s.pages_rendered += 1;
        plugins_mod.announceRender(s, finished.job);
        return image.pixels;
    }

    /// Whether any window still wants this exact job. With one window that is
    /// "did the zoom change"; with four it is a question that has to be asked
    /// of all of them, because the window that asked may have closed while
    /// another one still wants the page.
    pub fn wantedNow(s: *Session, job: Job) bool {
        // An overlay drawn before the last nudge shows the old offset.
        if (job.want == .overlay and !std.meta.eql(job.shift, s.diff_offset)) return false;
        var it = s.layout().iterator();
        while (it.next()) |v| {
            if (v.buffer == job.buffer and v.zoom == job.zoom) return true;
        }
        return false;
    }

    /// A slot to render into: an unused one, then the stalest, with its
    /// texture resized if the page is a different size from the last thing
    /// that lived there.
    fn claim(
        s: *Session,
        renderer: *lyngvi.Renderer,
        list: *DrawList,
        width: u32,
        height: u32,
    ) !*Slot {
        var chosen: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&s.slots, 0..) |*slot, i| {
            if (slot.gpu == 0) {
                // Never used: create the pair of registrations now. They are
                // handed out in creation order by both sides, which is what
                // makes the two ids equal -- checked, not trusted.
                const gpu = try renderer.createTexture(width, height, .color);
                const in_list = try list.registerTexture(width, height);
                std.debug.assert(gpu == in_list);
                slot.gpu = gpu;
                slot.list = in_list;
                slot.width = width;
                slot.height = height;
                return slot;
            }
            if (slot.used < oldest) {
                oldest = slot.used;
                chosen = i;
            }
        }

        return resize(renderer, list, &s.slots[chosen], width, height);
    }

    fn resize(renderer: *lyngvi.Renderer, list: *DrawList, slot: *Slot, width: u32, height: u32) !*Slot {
        if (slot.width != width or slot.height != height) {
            // A device-wide wait. Only on a zoom change, a document whose
            // pages differ in size, or a page read again, none of which is
            // per frame.
            try renderer.resizeTexture(slot.gpu, width, height);
            list.setTextureSize(slot.list, width, height);
        }
        return slot;
    }

    // -- the cursor ----------------------------------------------------------

    /// Moves the focused window's cursor, fetching the neighbouring page's
    /// text map when the cursor runs off the end of this one.
    ///
    /// A move that needs a map which is not built yet does nothing this
    /// frame: `missingIn` will ask for it, and the next press works. That is
    /// the same bargain as a page that is still blank paper.
    fn moveCursor(s: *Session, step: View.Step) void {
        const v = s.view();
        const b = s.buffer(v.buffer);
        if (v.cursor.page >= v.pages.len) v.cursor.page = v.currentPage();

        // A cursor being shown for the first time appears on the page in
        // front of you, not on whichever page it was left on.
        if (!v.cursor.visible) v.cursor.page = v.currentPage();

        const map = b.textMap(v.cursor.page) orelse {
            v.cursor.visible = true;
            return;
        };
        if (v.cursor.stale) v.cursorNear(map);

        switch (v.moveCursor(step, map)) {
            .moved, .blocked => {},
            .page_above => {
                if (v.cursor.page == 0) return;
                const above = v.cursor.page - 1;
                const other = b.textMap(above) orelse return;
                v.enterPage(above, other, step);
            },
            .page_below => {
                if (v.cursor.page + 1 >= v.pages.len) return;
                const below = v.cursor.page + 1;
                const other = b.textMap(below) orelse return;
                v.enterPage(below, other, step);
            },
        }
        v.scrollToCursor();
    }

    /// Makes sure the focused window has a caret to work from: the one it
    /// has, or one at the top of the page in front of the reader. Returns
    /// false when that page's text is not ready yet.
    fn ensureCursor(s: *Session) bool {
        const v = s.view();
        const b = s.buffer(v.buffer);
        if (!v.cursor.visible or v.cursor.page >= v.pages.len) {
            const page = v.currentPage();
            const map = b.textMap(page) orelse {
                v.cursor.page = page;
                v.cursor.visible = true;
                return false;
            };
            v.cursorToPage(page, map, false);
            return true;
        }
        const map = b.textMap(v.cursor.page) orelse return false;
        if (v.cursor.stale) v.cursorNear(map);
        return true;
    }

    /// The text position under a window point, or null if it is not over
    /// text whose map is ready.
    fn positionAt(s: *Session, v: *View, p: Point) ?View.Position {
        const page = v.pageAt(p) orelse return null;
        const at = v.userSpaceAt(page, p) orelse return null;
        const map = s.buffer(v.buffer).textMap(page) orelse return null;
        if (map.isEmpty()) return null;
        const line = map.lineAt(at.x, at.y);
        return .{ .page = page, .line = line, .column = map.columnAt(line, at.x) };
    }

    // -- highlights ----------------------------------------------------------

    /// One box on one page: what a selection and a highlight are made of.
    const PageBox = struct { page: u32, box: Bounds };

    /// The colour a digit names. `1` is the default highlight colour, which is
    /// the accent when the reader has chosen one, so the key a person reaches
    /// for first gives the colour they set; the rest are the named colours
    /// `fenrir config accent` accepts, in rainbow order.
    /// The colours a digit picks, from `2` onwards. `1` is whatever the
    /// reader highlights with by default, which is a setting and not a name.
    const palette_names = [_][]const u8{
        "yellow", "green", "blue", "pink", "orange", "purple", "red",
    };

    fn paletteColor(s: *const Session, index: ?u8) Color {
        const i = index orelse return s.highlight;
        if (i == 0 or i > palette_names.len) return s.highlight;
        return Library.parseColor(palette_names[i - 1]).?;
    }

    /// The annotations panel's filter, read out of its field. Parsed where it
    /// is asked for -- on a key, or when the rows are rebuilt -- and never
    /// held, so it cannot outlive the text its words point into.
    fn markFilter(s: *Session) Marks.Filter {
        var swatches: [palette_names.len + 1]Marks.Swatch = undefined;
        swatches[0] = .{ .name = "default", .color = s.highlight };
        for (palette_names, swatches[1..]) |name, *sw| sw.* = .{ .name = name, .color = Library.parseColor(name).? };
        return .parse(s.panel.filterText(), &swatches);
    }

    /// Said wherever a filter has left nothing to walk.
    const unmatched = "nothing matches the filter -- :filter with nothing after it clears it";

    fn paletteName(index: u8) []const u8 {
        if (index == 0 or index > palette_names.len) return "the usual colour";
        return palette_names[index - 1];
    }

    /// The glyphs between two text positions, as one box per line per page.
    ///
    /// Inclusive of both ends, as a Vim selection is: `v` on a letter selects
    /// that letter. `lines` widens every line to its whole length, which is
    /// `V`. Pages whose text is not ready are skipped rather than waited for;
    /// `missingIn` asks for them, and the selection fills in a frame later.
    fn selectionBoxes(
        s: *Session,
        buffer_index: u32,
        from: View.Position,
        to: View.Position,
        lines: bool,
        out: *std.ArrayList(PageBox),
    ) !void {
        out.clearRetainingCapacity();
        const b = s.buffer(buffer_index);
        const ends = View.Position.ordered(from, to);

        var page = ends[0].page;
        while (page <= ends[1].page and page < b.pages.len) : (page += 1) {
            const map = b.textMap(page) orelse continue;
            if (map.isEmpty()) continue;
            const last_line: u32 = @intCast(map.lines.len - 1);

            const first = if (page == ends[0].page) @min(ends[0].line, last_line) else 0;
            const last = if (page == ends[1].page) @min(ends[1].line, last_line) else last_line;

            var line = first;
            while (line <= last) : (line += 1) {
                const glyphs = map.lines[line].glyphs(map);
                const starts_here = !lines and page == ends[0].page and line == ends[0].line;
                const ends_here = !lines and page == ends[1].page and line == ends[1].line;
                const lo: usize = if (starts_here) @min(ends[0].column, glyphs.len) else 0;
                const hi: usize = if (ends_here) @min(ends[1].column + 1, glyphs.len) else glyphs.len;
                if (lo >= hi) continue;

                var box: Bounds = .empty;
                for (glyphs[lo..hi]) |g| box = box.unionWith(g.box);
                if (!box.isEmpty()) try out.append(s.gpa, .{ .page = page, .box = box });
            }
        }
    }

    /// Highlights a run of boxes as one undo step.
    ///
    /// A box laid mostly over an existing highlight replaces it rather than
    /// stacking on it, so selecting highlighted words and pressing `3`
    /// recolours them instead of darkening them.
    fn highlightBoxes(s: *Session, buffer_index: u32, boxes: []const PageBox, color: Color) void {
        _ = s.markBoxes(buffer_index, boxes, color, .highlight);
    }

    /// Marks each box, replacing what mostly covered the same words: marking
    /// a line again in another colour or style is changing its mark.
    ///
    /// Every box is a line of one new anchor, returned. A replaced mark that
    /// was the last line of its anchor hands its comments to the new one
    /// first, so marking commented words again keeps what was said about
    /// them.
    pub fn markBoxes(s: *Session, buffer_index: u32, boxes: []const PageBox, color: Color, style: Marks.Style) u64 {
        const b = s.buffer(buffer_index);
        b.marks.beginGroup();
        defer b.marks.beginGroup();
        const anchor = b.marks.newName();

        for (boxes) |pb| {
            var i = b.marks.count();
            while (i > 0) {
                i -= 1;
                const mark = b.marks.items()[i];
                if (mark.page != pb.page) continue;
                const shared = mark.box.intersect(pb.box);
                if (shared.isEmpty()) continue;
                if (area(shared) < area(mark.box) * 0.5) continue;
                if (b.marks.lineCount(mark.anchor) == 1) b.marks.moveComments(s.gpa, mark.anchor, anchor) catch return anchor;
                _ = b.marks.removeAt(s.gpa, i) catch return anchor;
            }
            _ = b.marks.add(s.gpa, .{
                .page = pb.page,
                .box = pb.box,
                .color = color,
                .style = style,
                .anchor = anchor,
            }, false) catch return anchor;
        }
        return anchor;
    }

    fn area(box: Bounds) f32 {
        if (box.isEmpty()) return 0;
        return box.width() * box.height();
    }

    /// `m` in normal mode: highlight the cursor's line, or remove the
    /// highlight the cursor is inside.
    fn toggleMark(s: *Session) void {
        const v = s.view();
        const b = s.buffer(v.buffer);

        // A selection dragged with the mouse leaves normal mode holding
        // words, not a line, and `m` means those words -- otherwise the only
        // way to highlight a mouse selection would be to make it again with
        // the keyboard.
        if (s.drag != null) return s.highlightSelection(null, .highlight);

        if (!v.cursor.visible or v.cursor.caret.isEmpty()) return;

        const at: Point = .{
            .x = v.cursor.caret.min_x,
            .y = (v.cursor.caret.min_y + v.cursor.caret.max_y) * 0.5,
        };
        if (b.marks.at(v.cursor.page, at)) |index| {
            b.marks.beginGroup();
            _ = b.marks.removeAt(s.gpa, index) catch {};
            return;
        }

        const map = b.textMap(v.cursor.page) orelse return;
        if (map.isEmpty()) return;
        const line = map.lines[@min(v.cursor.line, map.lines.len - 1)];
        s.highlightBoxes(v.buffer, &.{.{ .page = v.cursor.page, .box = line.box }}, s.highlight);
    }

    fn clearMarks(s: *Session) void {
        const b = s.buffer(s.view().buffer);
        b.marks.clear(s.gpa) catch {};
        s.status = if (b.marks.canUndo()) "marks cleared -- u to bring them back" else "";
    }

    // -- the pen ---------------------------------------------------------------

    /// The colour the next stroke comes out in.
    ///
    /// Not `highlight`, which is a wash meant to be seen through: ink is
    /// opaque and goes *on* the page, so the default is a dark grey-blue that
    /// reads as a pen against white paper and is still visible against a
    /// figure. A digit replaces it with a palette colour, and those are the
    /// same eight the highlighter uses -- one palette, two tools, which is
    /// what makes the swatch under the pointer mean what it says.
    fn penColor(s: *const Session) Color {
        if (s.pen.colour) |i| return s.paletteColor(i);
        return ink_colour;
    }

    const ink_colour: Color = .{ .r = 0.13, .g = 0.19, .b = 0.35, .a = 1 };

    /// The pen goes down on `page` at `at`, in that page's user space.
    fn penDown(s: *Session, v: *View, page: u32, at: Point) void {
        s.stroking.clearRetainingCapacity();
        s.pen.buffer = v.buffer;
        s.pen.page = page;
        s.pen.down = true;
        s.stroking.append(s.gpa, at) catch {};
    }

    /// One more sample of where the pen is, if it has moved far enough to be
    /// a different place. `at` is in the page the stroke began on, which is
    /// why it may be off that page: a drag that runs past the edge keeps
    /// drawing, and the stroke is clipped to the page when it is shown.
    fn penMove(s: *Session, at: Point) void {
        if (!s.pen.down) return;
        const last = s.stroking.getLastOrNull() orelse return;
        const dx = at.x - last.x;
        const dy = at.y - last.y;
        if (dx * dx + dy * dy < pen_tolerance * pen_tolerance) return;
        if (s.stroking.items.len >= Library.max_points) return;
        s.stroking.append(s.gpa, at) catch {};
    }

    /// The pen comes up: what was drawn becomes a mark, or nothing does.
    ///
    /// A stroke of one point is a click and not a drawing, and is dropped --
    /// which also means a press in draw mode that was meant to be a press
    /// leaves nothing behind. Everything else goes through `Marks.add` like
    /// any other mark, so it is in the same undo history and the same list.
    fn penUp(s: *Session) void {
        if (!s.pen.down) return;
        s.pen.down = false;
        const points = Marks.simplify(s.stroking.items, pen_tolerance);
        if (points.len < 2) {
            s.stroking.clearRetainingCapacity();
            return;
        }
        if (s.pen.buffer >= s.buffers.items.len) return;
        const b = s.buffer(s.pen.buffer);
        b.marks.beginGroup();
        _ = b.marks.add(s.gpa, .{
            .kind = .ink,
            .page = s.pen.page,
            .points = points,
            .width = s.pen.width,
            .color = s.penColor(),
        }, false) catch {};
        s.stroking.clearRetainingCapacity();
        s.applyEffects();
        s.dirty_title = true;
    }

    /// The stroke in hand is abandoned: escape, or leaving draw mode with the
    /// button still down.
    fn penCancel(s: *Session) void {
        s.pen.down = false;
        s.stroking.clearRetainingCapacity();
    }

    fn setPenWidth(s: *Session, factor: f32) void {
        s.pen.width = std.math.clamp(s.pen.width * factor, min_pen_width, max_pen_width);
        s.say("pen {d:.1}pt", .{s.pen.width});
    }

    fn setPenColour(s: *Session, index: u8) void {
        if (index >= keys.palette_size) return;
        s.pen.colour = index;
        s.say("pen {s}", .{paletteName(index)});
    }

    /// What is selected right now, from the keyboard or from the mouse.
    ///
    /// Visual mode wins when both are somehow live, because the reader asked
    /// for that one last. The mouse's counts only in the window it was made
    /// in: a selection in a split is that split's, as visual mode's is.
    pub fn activeSelection(s: *Session, v: *View) ?[2]View.Position {
        if (v.selection()) |sel| return sel;
        const d = s.drag orelse return null;
        if (d.buffer != v.buffer or v != s.layout().current()) return null;
        return View.Position.ordered(d.from, d.to);
    }

    /// Nothing is selected any more, whichever of the two made it.
    fn clearSelection(s: *Session) void {
        s.view().endSelection();
        s.drag = null;
    }

    /// Visual mode's `m`, enter or a digit -- and `m` over a selection the
    /// mouse made, which is the only way a drag becomes a highlight: letting
    /// go of one does not, and `y` does not.
    fn highlightSelection(s: *Session, colour: ?u8, style: Marks.Style) void {
        const v = s.view();
        const sel = s.activeSelection(v) orelse return;
        defer s.clearSelection();

        var boxes: std.ArrayList(PageBox) = .empty;
        defer boxes.deinit(s.gpa);
        s.selectionBoxes(v.buffer, sel[0], sel[1], s.lineSelection(), &boxes) catch return;
        _ = s.markBoxes(v.buffer, boxes.items, s.paletteColor(colour), style);
    }

    /// Visual mode's `d`: every highlight the selection touches goes.
    fn unhighlightSelection(s: *Session) void {
        const v = s.view();
        const sel = s.activeSelection(v) orelse return;
        defer s.clearSelection();
        const b = s.buffer(v.buffer);

        var boxes: std.ArrayList(PageBox) = .empty;
        defer boxes.deinit(s.gpa);
        s.selectionBoxes(v.buffer, sel[0], sel[1], s.lineSelection(), &boxes) catch return;

        b.marks.beginGroup();
        defer b.marks.beginGroup();
        var removed: u32 = 0;
        var i = b.marks.count();
        while (i > 0) {
            i -= 1;
            const mark = b.marks.items()[i];
            for (boxes.items) |pb| {
                if (pb.page != mark.page or mark.box.intersect(pb.box).isEmpty()) continue;
                _ = b.marks.removeAt(s.gpa, i) catch return;
                removed += 1;
                break;
            }
        }
        if (removed == 0) s.status = "no highlights in the selection";
    }

    fn lineSelection(s: *const Session) bool {
        return s.keymap.mode == .visual_line or (s.keymap.mode == .normal and s.last_visual_line);
    }

    // -- edit mode -----------------------------------------------------------

    /// `i`: take hold of the highlight at or after the cursor, among those
    /// the filter lets through -- the first of what `n` will walk.
    fn enterEdit(s: *Session) void {
        const v = s.view();
        const b = s.buffer(v.buffer);
        if (b.marks.count() == 0) {
            s.keymap.mode = .normal;
            s.status = "no highlights to edit -- select text with v and press m";
            return;
        }

        const filter = s.markFilter();
        const key = if (v.cursor.visible and !v.cursor.caret.isEmpty())
            b.marks.atOrAfter(v.cursor.page, .{
                .x = v.cursor.caret.min_x,
                .y = (v.cursor.caret.min_y + v.cursor.caret.max_y) * 0.5,
            }, &filter)
        else blk: {
            const page = v.currentPage();
            break :blk b.marks.atOrAfter(page, .{ .x = 0, .y = v.pageBox(page).max_y }, &filter);
        };
        if (key == null) {
            s.keymap.mode = .normal;
            s.status = unmatched;
            return;
        }
        s.focusMark(key);
    }

    /// Puts a highlight in hand: scrolls to it, and brings the cursor along so
    /// that leaving edit mode leaves you where you were working.
    fn focusMark(s: *Session, key: ?u64) void {
        s.focus_mark = key;
        s.focus_comment = null;
        const k = key orelse return;
        const v = s.view();
        const b = s.buffer(v.buffer);
        const mark = b.marks.byKey(k) orelse return;
        const said = b.marks.said(mark.anchor);
        if (said.len != 0) s.focus_comment = said[0].key;
        if (mark.page >= v.pages.len) return;

        v.scrollToBox(mark.page, mark.box);
        if (b.textMap(mark.page)) |map| {
            if (!map.isEmpty()) {
                const line = map.lineAt(mark.box.min_x, (mark.box.min_y + mark.box.max_y) * 0.5);
                v.cursorTo(.{
                    .page = mark.page,
                    .line = line,
                    .column = map.columnAt(line, mark.box.min_x),
                }, map);
            }
        }
    }

    fn focusedMarkIndex(s: *Session) ?usize {
        const key = s.focus_mark orelse return null;
        return s.buffer(s.view().buffer).marks.indexOf(key);
    }

    /// The comment in hand, by its index in `comments`: the one `]c` took,
    /// while it is still on the anchor in hand, and otherwise the first on
    /// that anchor. Null when the anchor has none.
    fn focusedComment(s: *Session) ?usize {
        const i = s.focusedMarkIndex() orelse return null;
        const b = s.buffer(s.view().buffer);
        const anchor = b.marks.items()[i].anchor;
        if (s.focus_comment) |k| {
            if (b.marks.commentIndex(k)) |c| {
                if (b.marks.comments.items[c].anchor == anchor) return c;
            }
        }
        const range = b.marks.saidRange(anchor);
        return if (range[0] == range[1]) null else range[0];
    }

    const Jumped = struct {
        buffer: u32,
        key: u64,
        caret: Bounds,
        /// The comment `]c` landed on, so the next `]c` reads on from it
        /// rather than from the start of its thread.
        comment: ?u64 = null,
    };

    const Typing = union(enum) {
        /// The comment with this key, changed.
        comment: u64,
        /// A new comment on the anchor with this number.
        new: u64,
    };

    /// `]a`, `[a`, `]c`, `[c`. In edit mode from the highlight in hand, which
    /// the jump then replaces. Otherwise from where the reader is: the mark
    /// jumped to last while the caret has stayed where that left it, else the
    /// caret, else the top of the page in front of the window.
    ///
    /// The first of those is not a nicety. A stroke of ink has no text for the
    /// caret to land on, so a jump from the caret alone would find the same
    /// stroke again, every time.
    fn jumpMark(s: *Session, j: keys.Command.Jump) void {
        const v = s.view();
        const b = s.buffer(v.buffer);
        const from: Marks.Mark = from: {
            if (s.keymap.mode == .edit) {
                if (s.focus_mark) |k| if (b.marks.byKey(k)) |m| break :from m.*;
            }
            if (s.last_jump) |last| {
                if (last.buffer == v.buffer and std.meta.eql(last.caret, v.cursor.caret)) {
                    if (b.marks.byKey(last.key)) |m| break :from m.*;
                }
            }
            if (v.cursor.visible and !v.cursor.caret.isEmpty()) {
                const c = v.cursor.caret;
                const y = (c.min_y + c.max_y) * 0.5;
                break :from .{ .page = v.cursor.page, .box = .fromRect(c.min_x, y, c.min_x, y) };
            }
            const page = v.currentPage();
            const top = v.pageBox(page).max_y;
            break :from .{ .page = page, .box = .fromRect(0, top, 0, top) };
        };

        // What the panel shows, whether or not it is open: a filter is set to
        // be walked, and the status line says when one is in force.
        var filter = s.markFilter();
        const filtered = !filter.isEmpty();
        if (j.comments) return s.jumpComment(from, j.forwards, &filter, filtered);
        const to = b.marks.jump(from, j.forwards, &filter) orelse {
            s.status = if (filtered)
                unmatched
            else if (j.comments)
                "no comments in this document -- a in edit mode writes one"
            else
                "no marks in this document";
            return;
        };

        // Normal mode has no highlight in hand, and landing on one must not
        // give it one: `focus_mark` is what edit mode outlines and deletes.
        const held = s.focus_mark;
        s.focusMark(to.key);
        if (s.keymap.mode != .edit) s.focus_mark = held;
        s.last_jump = .{ .buffer = v.buffer, .key = to.key, .caret = v.cursor.caret };

        const round: []const u8 = if (!to.wrapped) "" else if (j.forwards) ", from the top" else ", from the end";
        const of: []const u8 = if (filtered) " that match" else "";
        s.say("mark {d}/{d}{s}{s}", .{ to.place, to.of, of, round });
    }

    /// `]c` and `[c`: each comment in turn, a thread read through before the
    /// next anchor's, from the comment the reader stands on. In edit mode
    /// the comment is taken in hand, so `a` changes the one that was read.
    fn jumpComment(s: *Session, from: Marks.Mark, forwards: bool, filter: *const Marks.Filter, filtered: bool) void {
        const v = s.view();
        const b = s.buffer(v.buffer);
        const after: ?u64 = if (s.keymap.mode == .edit)
            s.focus_comment
        else if (s.last_jump) |last|
            (if (last.buffer == v.buffer and last.key == from.key) last.comment else null)
        else
            null;
        const to = b.marks.jumpComment(s.gpa, from, after, forwards, filter) orelse {
            s.status = if (filtered)
                unmatched
            else
                "no comments in this document -- c on a selection writes one";
            return;
        };

        const held = s.focus_mark;
        const held_comment = s.focus_comment;
        s.focusMark(to.mark);
        if (s.keymap.mode == .edit) {
            s.focus_comment = to.key;
        } else {
            s.focus_mark = held;
            s.focus_comment = held_comment;
        }
        s.last_jump = .{ .buffer = v.buffer, .key = to.mark, .caret = v.cursor.caret, .comment = to.key };

        const round: []const u8 = if (!to.wrapped) "" else if (forwards) ", from the top" else ", from the end";
        const of: []const u8 = if (filtered) " that match" else "";
        const c = b.marks.comments.items[b.marks.commentIndex(to.key).?];
        s.say("comment {d}/{d}{s}{s}: {s}", .{ to.place, to.of, of, round, c.text });
    }

    /// The first thing written on a mark's anchor, or nothing: what a line
    /// of the status bar or of the panel has room for.
    pub fn firstComment(b: *Buffer, mark: Marks.Mark) []const u8 {
        const said = b.marks.said(mark.anchor);
        return if (said.len == 0) "" else said[0].text;
    }

    fn recolourMark(s: *Session, colour: u8) void {
        const i = s.focusedMarkIndex() orelse return;
        const b = s.buffer(s.view().buffer);
        b.marks.beginGroup();
        b.marks.recolour(s.gpa, i, s.paletteColor(colour)) catch {};
    }

    fn restyleMark(s: *Session, style: Marks.Style) void {
        const i = s.focusedMarkIndex() orelse return;
        const b = s.buffer(s.view().buffer);
        if (b.marks.items()[i].kind == .ink) {
            s.status = "ink is drawn as it went -- only marked words have a style";
            return;
        }
        b.marks.beginGroup();
        b.marks.restyle(s.gpa, i, style) catch {};
    }

    /// `d` in edit mode: delete the highlight in hand and take hold of the
    /// next one, so that deleting several in a row is `ddd`.
    ///
    /// The next of what `n` walks, so `ddd` under a filter deletes only what
    /// the panel shows, and stops when the filter has nothing left rather
    /// than going on into marks the panel hides.
    fn deleteMark(s: *Session) void {
        const i = s.focusedMarkIndex() orelse return;
        const b = s.buffer(s.view().buffer);
        const filter = s.markFilter();
        const next = if (b.marks.jump(b.marks.items()[i], true, &filter)) |to| to.key else null;

        b.marks.beginGroup();
        _ = b.marks.removeAt(s.gpa, i) catch return;

        if (next == null or next == s.focus_mark) {
            s.focus_mark = null;
            s.keymap.mode = .normal;
            s.status = if (b.marks.count() == 0)
                "that was the last highlight"
            else
                "that was the last that matches -- :filter with nothing after it clears it";
            return;
        }
        s.focusMark(next);
    }

    /// `a`: note mode opens on the comment in hand, to change it, or on
    /// nothing when the anchor has none, to write its first.
    fn beginNote(s: *Session) void {
        const b = s.buffer(s.view().buffer);
        const i = s.focusedMarkIndex() orelse {
            s.keymap.mode = if (b.marks.count() == 0) .normal else .edit;
            return;
        };
        s.note.clearRetainingCapacity();
        if (s.focusedComment()) |c| {
            const comment = b.marks.comments.items[c];
            s.typing = .{ .comment = comment.key };
            s.note.appendSlice(s.gpa, comment.text) catch {};
        } else {
            s.typing = .{ .new = b.marks.items()[i].anchor };
        }
    }

    /// `c` in edit mode: note mode opens empty, for another comment on the
    /// anchor in hand.
    fn beginComment(s: *Session) void {
        const b = s.buffer(s.view().buffer);
        const i = s.focusedMarkIndex() orelse {
            s.keymap.mode = if (b.marks.count() == 0) .normal else .edit;
            return;
        };
        s.note.clearRetainingCapacity();
        s.typing = .{ .new = b.marks.items()[i].anchor };
    }

    /// `c` in visual mode: the selection is highlighted as one anchor, taken
    /// in hand, and note mode opens for the first comment on it. Escape
    /// keeps the highlight, which `u` takes back like any other.
    fn commentSelection(s: *Session) void {
        const v = s.view();
        const sel = s.activeSelection(v) orelse return s.noAnchor();
        defer s.clearSelection();
        var boxes: std.ArrayList(PageBox) = .empty;
        defer boxes.deinit(s.gpa);
        s.selectionBoxes(v.buffer, sel[0], sel[1], s.lineSelection(), &boxes) catch return s.noAnchor();
        if (boxes.items.len == 0) return s.noAnchor();

        const b = s.buffer(v.buffer);
        const anchor = s.markBoxes(v.buffer, boxes.items, s.highlight, s.comment_style);
        var first: ?Marks.Mark = null;
        for (b.marks.items()) |m| {
            if (m.anchor != anchor) continue;
            if (first == null or Marks.readsBefore(m, first.?)) first = m;
        }
        s.focusMark(first.?.key);
        s.note.clearRetainingCapacity();
        s.typing = .{ .new = anchor };
    }

    /// A comment begun where no words are selected, or none are known yet.
    fn noAnchor(s: *Session) void {
        s.keymap.mode = .normal;
        s.typing = null;
        s.status = "nothing to comment on -- select some words first";
    }

    fn noteChar(s: *Session, c: u21) void {
        if (s.note.items.len >= max_note) return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch return;
        s.note.appendSlice(s.gpa, buf[0..n]) catch {};
    }

    /// Removes the last *character*, not the last byte: a note is UTF-8, and
    /// cutting an accented letter in half leaves a note the library would
    /// store as invalid text.
    fn noteBackspace(s: *Session) void {
        var n = s.note.items.len;
        if (n == 0) return;
        n -= 1;
        while (n > 0 and s.note.items[n] & 0xc0 == 0x80) n -= 1;
        s.note.shrinkRetainingCapacity(n);
    }

    /// Keeps what was typed: the comment it was begun on changed, or none at
    /// all when everything was rubbed out; or a new comment, taken in hand,
    /// unless nothing was typed.
    fn commitNote(s: *Session) void {
        defer s.note.clearRetainingCapacity();
        const typing = s.typing orelse return;
        s.typing = null;
        const b = s.buffer(s.view().buffer);
        b.marks.beginGroup();
        switch (typing) {
            .comment => |key| {
                const at = b.marks.commentIndex(key) orelse return;
                if (s.note.items.len == 0) {
                    _ = b.marks.removeComment(s.gpa, at) catch {};
                } else {
                    b.marks.setText(s.gpa, at, s.note.items) catch {};
                }
            },
            .new => |anchor| {
                if (s.note.items.len == 0) return;
                // The anchor may have gone while this was typed, to an undo
                // from a plugin's key; a comment on nothing would be lost.
                if (b.marks.lineCount(anchor) == 0) return;
                const at = b.marks.addComment(s.gpa, .{ .anchor = anchor, .text = s.note.items }, false) catch return;
                s.focus_comment = b.marks.comments.items[at].key;
            },
        }
    }

    /// A comment is a line of text on a highlight, not an essay. Bounded so
    /// that a key held down does not fill the title bar, and the database,
    /// with a megabyte of one letter.
    const max_note = 1024;

    fn undoMarks(s: *Session, forwards: bool) void {
        const b = s.buffer(s.view().buffer);
        const done = (if (forwards) b.marks.redo(s.gpa) else b.marks.undo(s.gpa)) catch false;
        if (!done) {
            s.status = if (forwards) "already at newest change" else "already at oldest change";
            return;
        }
        // The highlight in hand may be the thing that was undone.
        if (s.focus_mark) |k| {
            if (b.marks.indexOf(k) == null) {
                s.focus_mark = null;
                if (s.keymap.mode == .edit) s.enterEdit();
            }
        }
    }

    // -- the library ---------------------------------------------------------

    /// Writes whatever the highlights' history says has changed. Once a frame,
    /// after the commands, so that a burst of edits is written as it settles
    /// rather than one statement per keystroke inside the handler.
    pub fn applyEffects(s: *Session) void {
        for (s.buffers.items, 0..) |*b, at| {
            if (b.marks.takeEffects().len == 0) continue;

            // Taken out of the buffer before anything is told about them: a
            // plugin handler for `highlight` may make another change, and
            // that change belongs to the next pass rather than to this list.
            const effects = s.gpa.dupe(Marks.Effect, b.marks.takeEffects()) catch continue;
            defer s.gpa.free(effects);
            b.marks.clearEffects();

            for (effects) |e| {
                s.writeEffect(b, e);
                plugins_mod.announceEffect(s, @intCast(at), b, e);
            }
        }
    }

    /// One queued change, written.
    ///
    /// The kind is read off the mark rather than carried on the effect: an
    /// `Effect` says *what happened* to a mark, and which table that is is a
    /// fact about the mark. A delete carries the whole mark for this reason,
    /// so a row can still be found after the mark has left the list.
    fn writeEffect(s: *Session, b: *Buffer, e: Marks.Effect) void {
        const lib = s.library orelse return;
        switch (e) {
            .insert => |key| {
                const mark = b.marks.byKey(key) orelse return;
                var hex: [7]u8 = undefined;
                var name: [Library.name_len]u8 = undefined;
                const anchor = spell(b, mark.anchor, &name);
                const id = switch (mark.kind) {
                    .block => lib.addMark(b.path, .{
                        .page = mark.page,
                        .x0 = mark.box.min_x,
                        .y0 = mark.box.min_y,
                        .x1 = mark.box.max_x,
                        .y1 = mark.box.max_y,
                        .color = @constCast(hexOf(mark.color, &hex)),
                        .style = @constCast(@tagName(mark.style)),
                        .anchor = @constCast(anchor),
                    }, s.now()) catch return,
                    .ink => lib.addStroke(b.path, .{
                        .page = mark.page,
                        .color = @constCast(hexOf(mark.color, &hex)),
                        .width = mark.width,
                        .points = @constCast(mark.points),
                        .anchor = @constCast(anchor),
                    }, s.now()) catch return,
                };
                b.marks.setId(key, id);
            },
            .delete => |mark| if (mark.saved()) switch (mark.kind) {
                .block => lib.removeMark(mark.id) catch {},
                .ink => lib.removeStroke(mark.id) catch {},
            },
            .update => |key| {
                const mark = b.marks.byKey(key) orelse return;
                if (!mark.saved()) return;
                var hex: [7]u8 = undefined;
                switch (mark.kind) {
                    .block => lib.updateMark(mark.id, hexOf(mark.color, &hex), @tagName(mark.style)) catch {},
                    .ink => lib.updateStroke(mark.id, hexOf(mark.color, &hex)) catch {},
                }
            },
            .comment_insert => |key| {
                const c = b.marks.comments.items[b.marks.commentIndex(key) orelse return];
                var anchor: [Library.name_len]u8 = undefined;
                var own: [Library.name_len]u8 = undefined;
                const id = lib.addComment(b.path, .{
                    .anchor = @constCast(spell(b, c.anchor, &anchor)),
                    .nm = @constCast(spell(b, c.name, &own)),
                    .text = @constCast(c.text),
                }, s.now()) catch return;
                b.marks.setCommentId(key, id);
            },
            .comment_delete => |c| if (c.saved()) lib.removeComment(c.id) catch {},
            .comment_update => |key| {
                const c = b.marks.comments.items[b.marks.commentIndex(key) orelse return];
                if (c.saved()) lib.updateComment(c.id, c.text, s.now()) catch {};
            },
        }
    }

    pub fn hexOf(c: Color, buf: *[7]u8) []const u8 {
        const byte = struct {
            fn of(v: f32) u8 {
                return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
            }
        }.of;
        return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ byte(c.r), byte(c.g), byte(c.b) }) catch unreachable;
    }

    fn now(s: *const Session) i64 {
        const io = s.io orelse return 0;
        return library.now(io);
    }

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
                if (!s.closeWindow()) s.quit = true;
            },
            .quit_all => s.quit = true,
            .split => s.splitWindow(.horizontal),
            .vsplit => s.splitWindow(.vertical),
            .close => _ = s.closeWindow(),
            .only => s.layout().only(s.gpa),
            .tabnew => s.newTab(),
            .tabclose => if (!s.closeTab()) {
                s.say("this is the only tabpage; :q leaves the reader", .{});
                return false;
            },
            .tabonly => s.tabs.only(s.gpa),
            // `:tabnext` alone is the next one; with a number it is that one,
            // counted from 1 as a person counts the bar.
            .tabnext, .tabprevious => {
                const back = entry.id == .tabprevious;
                if (args.len == 0) {
                    s.goTab(if (back) -1 else 1);
                } else if (std.fmt.parseInt(u32, args, 10)) |n| {
                    if (n == 0 or n > s.tabs.count()) {
                        s.say("there is no tabpage {d}", .{n});
                        return false;
                    }
                    s.showTab(n - 1);
                } else |_| {
                    s.say(":{s} takes a tabpage number, or nothing", .{name});
                    return false;
                }
            },
            .bnext => s.showBuffer(1),
            .bprevious => s.showBuffer(-1),
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
                if (s.settings.open) s.readSettings();
            },
            .palette => s.showPalette(),
            .undo => s.undoMarks(false),
            .redo => s.undoMarks(true),
            .marks => {
                if (std.mem.eql(u8, args, "clear")) {
                    s.clearMarks();
                } else {
                    // Counted apart, because "7 marks" does not say whether
                    // somebody highlighted seven sentences or drew seven
                    // lines, and those are the question being asked.
                    var ink: usize = 0;
                    for (s.buffer(v.buffer).marks.items()) |m| {
                        if (m.kind == .ink) ink += 1;
                    }
                    const all = s.buffer(v.buffer).marks.count();
                    s.say("{d} highlights and {d} lines of ink in this document", .{ all - ink, ink });
                }
            },
            .mnext => s.jumpMark(.{ .forwards = true }),
            .mprevious => s.jumpMark(.{ .forwards = false }),
            .cnext => s.jumpMark(.{ .forwards = true, .comments = true }),
            .cprevious => s.jumpMark(.{ .forwards = false, .comments = true }),
            .filter => {
                s.panel.setFilter(args);
                if (s.chrome) |c| c.rails.show(.annotations);
                const filter = s.markFilter();
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

    // -- the palette ----------------------------------------------------------

    /// Opens it, having refilled the rows.
    ///
    /// The built-in half comes from the registry and the plugins' half from
    /// the runtime, and once they are in one array nothing downstream can
    /// tell which is which -- which is the point, since a person looking for
    /// a command does not know either.
    fn showPalette(s: *Session) void {
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

    // -- search ---------------------------------------------------------------

    /// `/`: the bar appears, empty, with the keyboard.
    fn beginSearch(s: *Session) void {
        s.find.show();
        s.search.start(s.gpa, "", s.view().currentPage(), s.pageCount()) catch {};
    }

    /// Escape, or the close button: the bar goes and the highlights go with
    /// it, which is the whole of what a reader means by ending a search.
    fn endSearch(s: *Session) void {
        s.find.hide();
        s.search.start(s.gpa, "", 0, 0) catch {};
    }

    /// The query changed. The scan restarts from the page in front of the
    /// reader, because a query one letter longer is a different search and
    /// the hits for the old one are answers to a question nobody asked.
    fn requery(s: *Session) void {
        s.search.start(s.gpa, s.find.query(), s.view().currentPage(), s.pageCount()) catch {};
    }

    /// `n`, `N`, and the two chevrons.
    fn stepSearch(s: *Session, back: bool) void {
        const hit = s.search.step(back) orelse return;
        const v = s.view();
        // Not `scrollToPage`: the match may be the last line of a page that
        // is already half on screen, and scrolling to the top of it would
        // move the window away from the thing it was asked to show.
        // `scrollToBox` is the rule the caret and a chosen highlight use,
        // which is to move as little as will do.
        v.scrollToBox(hit.page, hit.box);
    }

    fn pageCount(s: *Session) u32 {
        return @intCast(s.buffer(s.view().buffer).pages.len);
    }

    /// What the bar was asked to do, carried out.
    fn applyFind(s: *Session, what: find_mod.Action) void {
        switch (what) {
            .typed => s.requery(),
            .step => |back| s.stepSearch(back),
            // Enter is `n` without moving the hands, and on the first press
            // that means landing on the first hit rather than stepping past
            // it -- which `search.step` already knows.
            .submitted => s.stepSearch(false),
            .close => s.endSearch(),
        }
    }

    /// What the bar writes beside the field.
    fn searchCount(s: *Session) find_mod.Count {
        var found: u32 = 0;
        var at: ?u32 = null;
        for (s.search.hits.items, 0..) |h, i| {
            if (!h.starts) continue;
            found += 1;
            if (s.search.landed and i == s.search.current) at = found;
        }
        return .{
            .at = at,
            .found = found,
            .scanned = s.search.scanned,
            .pages = s.search.pages,
        };
    }

    /// A row chosen, or a line typed into the palette that matched nothing.
    ///
    /// A command that needs an argument cannot be *run* from a list -- there
    /// is nothing to run it with -- so it goes onto the `:` line with a space
    /// after it and the caret where the argument goes. That is the one thing
    /// the palette hands to the older way in rather than doing itself, and it
    /// is the honest handover: the two are the same commands.
    fn runChosen(s: *Session, chosen: palette_mod.Chosen) void {
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
            if (name[0] == 'c' and commentStyleNamed(value) == null) {
                s.say("comment_anchor is highlight or arrow, not {s}", .{value[0..@min(value.len, 48)]});
                return false;
            }
            if (name[0] == 'w' and !std.mem.eql(u8, value, "on") and !std.mem.eql(u8, value, "off")) {
                s.say("watch is on or off, not {s}", .{value[0..@min(value.len, 48)]});
                return false;
            }
            for (settings_page.builtin, 0..) |opt, i| {
                if (std.mem.eql(u8, opt.key, name)) s.changeSetting(.{ .key = opt.key, .value = value, .index = i });
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

    fn goToPage(s: *Session, page: u32) bool {
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
        s.applyEffects();
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
    fn interfaceHasInput(s: *const Session) bool {
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
            .quit => if (!s.closeWindow()) return true,
            .quit_all => return true,

            .split => |dir| s.splitWindow(dir),
            .close_window => _ = s.closeWindow(),
            .only_window => s.layout().only(s.gpa),
            .focus_side => |side| _ = s.layout().focusSide(side),
            .cycle_window => |back| s.layout().cycle(s.gpa, back),
            .equalise => s.layout().equalise(),

            .new_tab => s.newTab(),
            .close_tab => _ = s.closeTab(),
            .go_tab => |delta| s.goTab(delta),
            .window_to_tab => s.windowToTab(),

            .diff_view => |delta| compare.turnComparison(s, delta),
            .nudge => |by| compare.nudge(s, by),

            .next_buffer => s.showBuffer(1),
            .previous_buffer => s.showBuffer(-1),

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

            .move_cursor => |step| s.moveCursor(step),
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
                    s.endSearch();
                } else if (v.cursor.visible) {
                    v.cursor.visible = false;
                } else return true;
            },

            .enter_visual, .enter_visual_line => {
                s.last_visual_line = cmd == .enter_visual_line;
                _ = s.ensureCursor();
                if (v.anchor == null) v.beginSelection();
            },
            .enter_edit => s.enterEdit(),
            .enter_draw => {
                // Whatever was selected is not selected any more: the next
                // drag is a stroke, so a selection left on screen would be a
                // thing the mouse could no longer change.
                s.clearSelection();
                s.say("pen {d:.1}pt -- drag to draw, d or escape to stop", .{s.pen.width});
            },
            .enter_note => s.beginNote(),
            .add_comment => s.beginComment(),
            .leave_mode => {
                s.clearSelection();
                s.penCancel();
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
            .highlight_selection => |colour| s.highlightSelection(colour, .highlight),
            .style_selection => |style| s.highlightSelection(null, style),
            .yank_selection => {
                // The selection goes and nothing is written: a selection is
                // the interface's, never a mark, whichever key ends it.
                s.clearSelection();
                s.status = "nothing copied -- there is no clipboard yet; m highlights";
            },
            .unhighlight_selection => s.unhighlightSelection(),
            .comment_selection => s.commentSelection(),

            .toggle_highlight => s.toggleMark(),
            .clear_highlights => s.clearMarks(),

            // Edit mode's `n` and `N` are `]a` and `[a`: they walk what the
            // filter lets through. The author asked for this -- don't give
            // them a walk of their own over every mark again, or the panel
            // shows one set and `n` steps through another.
            .next_mark => s.jumpMark(.{ .forwards = true }),
            .previous_mark => s.jumpMark(.{ .forwards = false }),
            .jump_mark => |j| s.jumpMark(j),
            .jump_change => |forwards| compare.jumpChange(s, forwards),
            .recolour_mark => |colour| s.recolourMark(colour),
            .restyle_mark => |style| s.restyleMark(style),
            .delete_mark => s.deleteMark(),

            .pen_colour => |colour| s.setPenColour(colour),
            .pen_width => |factor| s.setPenWidth(factor),

            .note_char => |c| s.noteChar(c),
            .note_backspace => s.noteBackspace(),
            .note_commit => s.commitNote(),

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
            .show_commands => s.showPalette(),

            .enter_search => s.beginSearch(),
            .search_step => |back| {
                // `n` is the next page until a search is live. See the note
                // on `keys.Command.search_step`.
                if (s.search.isEmpty()) {
                    v.scrollToPage(if (back)
                        v.currentPage() -| 1
                    else
                        @min(v.currentPage() + 1, v.pages.len - 1));
                } else s.stepSearch(back);
            },
            .plugin_key => |id| if (s.plugins) |rt| rt.runKeymap(id),

            .undo => s.undoMarks(false),
            .redo => s.undoMarks(true),
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
    fn pointer(s: *Session, in: lyngvi.Input) void {
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
        if (s.dragSplit(in, down, pressed)) return;

        // Then the pen, which claims the whole gesture the way a divider
        // does -- a stroke that stopped because the pointer crossed a mark or
        // ran off the page would be a line with a hole in it.
        if (s.keymap.mode == .draw or s.pen.down) {
            s.drawPointer(in, down, pressed);
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
                if (s.positionAt(v, in.mouse)) |p| {
                    d.to = p;
                    s.carryCursor(v, p);
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
                s.focusMark(key);
            } else {
                // A press on a highlight takes it away, the eraser on the end
                // of the highlighter. `u` puts it back.
                b.marks.beginGroup();
                _ = b.marks.removeAt(s.gpa, index) catch {};
                s.applyEffects();
            }
            s.dirty_title = true;
            return;
        }

        const p = s.positionAt(v, in.mouse) orelse return;
        s.drag = .{ .buffer = v.buffer, .from = p, .to = p };
        s.carryCursor(v, p);
    }

    /// The pointer in draw mode: down is the pen down, moving is the stroke,
    /// up is a mark.
    ///
    /// The scrollbars are not consulted, unlike everywhere else, and that is
    /// deliberate: in draw mode the pointer is a pen over the whole window,
    /// and a stroke that began by grabbing a thumb somebody could not see
    /// under their hand would be worse than a thumb that has to be reached
    /// with the wheel. Scrolling is the wheel and the keys, both of which
    /// still work while the pen is down.
    fn drawPointer(s: *Session, in: lyngvi.Input, down: bool, pressed: bool) void {
        if (!down) return s.penUp();

        const v = s.view();
        if (pressed) {
            _ = s.layout().focusAt(in.mouse);
            const focused = s.view();
            const page = focused.pageAt(in.mouse) orelse return;
            const at = focused.userSpaceAt(page, in.mouse) orelse return;
            s.penDown(focused, page, at);
            return;
        }
        if (!s.pen.down or v.buffer != s.pen.buffer) return;
        // In the space of the page the stroke started on, whether or not the
        // pointer is still over it -- `userSpaceAt` answers null off the
        // page, and a stroke that stopped at the margin would be a line with
        // its end cut off.
        s.penMove(v.pageSpaceAt(s.pen.page, in.mouse));
    }

    /// How far either side of the line a press still counts as taking hold
    /// of it. The line is two pixels; nobody can hit two pixels.
    const divider_slack: f32 = 4;

    /// The line between two windows, taken hold of and moved. True when the
    /// gesture belongs to a divider, and nothing below should see it.
    ///
    /// The divider is remembered for the whole drag rather than looked up
    /// each frame, because the pointer runs ahead of the line the moment it
    /// reaches a window's minimum -- and a lookup would then find nothing and
    /// drop the gesture just as someone leans into it.
    fn dragSplit(s: *Session, in: lyngvi.Input, down: bool, pressed: bool) bool {
        if (down and pressed and s.split_drag == null) {
            s.split_drag = s.layout().dividerAt(in.mouse, divider_slack);
        }
        const d = s.split_drag orelse return false;

        if (down) {
            s.layout().moveDivider(d, if (d.dir == .vertical) in.mouse.x else in.mouse.y);
        } else {
            s.split_drag = null;
        }

        // Everything below the early return is skipped, and that includes the
        // button bookkeeping `dragScrollbar` does. Without this the release
        // that ends a drag still looks like a press on the frame after it,
        // and the next press anywhere is swallowed.
        s.view().was_down = down;
        return true;
    }

    /// Moves the caret to where the pointer is, which is what a click in text
    /// means everywhere else and is how the keyboard picks up a selection the
    /// mouse began: `v` after a drag extends from the end of it, and `w` or
    /// `j` after a click carries on from where the reader was looking.
    ///
    /// Not scrolled to, unlike a cursor move from the keyboard -- the pointer
    /// is already somewhere the reader can see, and a page that jumped under
    /// a drag would be unusable.
    fn carryCursor(s: *Session, v: *View, at: View.Position) void {
        const map = s.buffer(v.buffer).textMap(at.page) orelse return;
        if (map.isEmpty()) return;
        v.cursorTo(at, map);
    }

    pub fn splitWindow(s: *Session, dir: Layout.Direction) void {
        // A split copies the window, and a copied selection would be two
        // windows each claiming to be selecting.
        s.clearSelection();
        if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;

        const made = s.layout().split(s.gpa, dir) catch null;
        if (made == null) {
            s.status = "no room to split";
            return;
        }
        s.placed = null;
    }

    /// Closes the focused window. False when it was the last one anywhere,
    /// which the caller turns into a quit.
    ///
    /// The last window of a tabpage closes the tabpage, as `:q` does in Vim:
    /// a tabpage with no windows in it is not a thing, so the only question
    /// is whether there is another tabpage to fall back to.
    fn closeWindow(s: *Session) bool {
        if (s.layout().count() < 2) return s.closeTab();
        s.rememberPlace(s.view());
        _ = s.layout().close(s.gpa);
        s.placed = null;
        return true;
    }

    // -- tabpages ------------------------------------------------------------

    /// A tabpage of one window, looking at whatever this one is. `:tabnew`.
    ///
    /// Looking at the same document, and not at nothing: a reader opens a tab
    /// to keep an arrangement, not to be handed an empty one. `<C-w>n` in the
    /// new tab is what moves it to another buffer, exactly as it would in a
    /// split.
    fn newTab(s: *Session) void {
        const copy = s.leavingTab();
        _ = s.tabs.open(s.gpa, copy) catch {
            s.say("no memory for another tabpage", .{});
            return;
        };
        s.enteredTab();
    }

    /// Closes the tabpage on screen. False when it is the only one, which
    /// `closeWindow` turns into a quit and `:tabclose` reports.
    fn closeTab(s: *Session) bool {
        if (s.tabs.count() < 2) return false;

        // Every window in it, not only the focused one: the whole
        // arrangement is going, and each was somewhere in a document.
        var it = s.layout().iterator();
        while (it.next()) |v| s.rememberPlace(v);

        s.clearSelection();
        if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;
        _ = s.tabs.close(s.gpa);
        s.enteredTab();
        return true;
    }

    /// `gt` and `gT`.
    fn goTab(s: *Session, delta: i32) void {
        if (s.tabs.count() < 2) return;
        _ = s.leavingTab();
        s.tabs.go(delta);
        s.enteredTab();
    }

    /// A tabpage by number, from zero. What `:tabnext 2` and a click on the
    /// bar both go through.
    fn showTab(s: *Session, index: u32) void {
        if (index >= s.tabs.count() or index == s.tabs.active) return;
        _ = s.leavingTab();
        s.tabs.show(index);
        s.enteredTab();
    }

    /// The focused window, moved into a tabpage of its own. `<C-w>T`.
    fn windowToTab(s: *Session) void {
        if (s.layout().count() < 2) {
            s.say("this window is the whole tabpage already", .{});
            return;
        }
        _ = s.leavingTab();
        _ = s.tabs.moveToNewTab(s.gpa) catch {
            s.say("no memory for another tabpage", .{});
            return;
        };
        s.enteredTab();
    }

    /// Everything that has to happen before this tabpage stops being the one
    /// on screen, and a copy of the window that was focused in it.
    ///
    /// A selection belongs to the window it was dragged in, and a window on
    /// another tabpage is one nobody can see the selection in -- so it goes,
    /// the way a split's does and for the same reason.
    fn leavingTab(s: *Session) View {
        const copy = s.view().*;
        s.clearSelection();
        if (s.keymap.mode.isVisual()) s.keymap.mode = .normal;
        s.rememberPlace(s.view());
        return copy;
    }

    /// And after: the pages on the device belong to whichever windows are
    /// showing, and which those are has just changed.
    fn enteredTab(s: *Session) void {
        s.placed = null;
        s.dirty_title = true;
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
            } else if (s.slotFor(v.buffer, i, v.zoom, overlay)) |slot| {
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
        try s.drawMarks(v, b, range, over);
        try s.drawInk(v, b, range, over);
        try s.drawSearchHits(v, range, over);

        v.marks_seen = b.marks.revision;
        try s.drawSelection(v, over);
        try s.drawCaret(v, over);
        try s.drawScrollbar(v, over);
    }

    /// The marks over words on the pages a window can see.
    ///
    /// Drawn over the page rather than under it, with alpha, because a PDF's
    /// paper is opaque: a highlight beneath it would not be visible at all.
    /// That means dark text shows through a light wash, which is what a
    /// highlighter does to paper. An underline, a strike-through and a
    /// squiggle are solid, being lines and not washes.
    ///
    /// The one in hand in edit mode is stronger and outlined, and the first
    /// line of an anchor with a comment carries a small tab at its top-right
    /// corner -- the comment's text is in the title bar while the highlight
    /// is in hand, since the title bar is the only text this window draws.
    ///
    /// The whole range at once, rather than a call per page: a buffer's marks
    /// are one list in no particular page order, so a call per page would
    /// walk all of them once for each page on screen, and a well-marked
    /// document with four windows open would walk it a dozen times a frame.
    fn drawMarks(
        s: *Session,
        v: *View,
        b: *Buffer,
        range: View.Visible,
        over: *DrawList,
    ) !void {
        const editing = s.keymap.mode == .edit or s.keymap.mode == .note;
        const in_focus = v == s.layout().current();
        for (b.marks.items(), 0..) |mark, i| {
            if (mark.kind != .block) continue;
            if (mark.page < range.first or mark.page >= range.end) continue;
            const page = mark.page;
            const box = v.windowBox(page, mark.box);
            const held = editing and in_focus and s.focus_mark == mark.key;
            const c = mark.color;
            switch (mark.style) {
                .highlight => try over.rounded(
                    blockOf(box, v.zoom),
                    .all(markRadius(v.zoom)),
                    .{ .r = c.r, .g = c.g, .b = c.b, .a = if (held) 0.55 else 0.35 },
                ),
                .underline, .strikeout => try over.fill(ruleOf(box, mark.style), c),
                .squiggly => try squiggle(over, box, c),
                // From the first line only: the arrow says where the words
                // begin, and the outline in edit mode says where they run.
                .arrow => if (b.marks.heads(s.gpa, i)) try arrow(over, box, lineStart(v, b, mark, box), c),
            }
            if (held) {
                const pad = 2.0;
                try over.border(
                    .fromRect(box.min_x - pad, box.min_y - pad, box.max_x + pad, box.max_y + pad),
                    .all(2),
                    2,
                    .{ .r = c.r * 0.6, .g = c.g * 0.6, .b = c.b * 0.6, .a = 1 },
                );
            }
            // On the anchor's first line only: six lines of one comment
            // carry one tab.
            if (b.marks.leads(s.gpa, i)) {
                const tab = @max(4.0, 3.0 * v.zoom);
                try over.fill(
                    .fromRect(box.max_x - tab, box.min_y - tab * 0.5, box.max_x + tab * 0.5, box.min_y + tab),
                    .{ .r = c.r * 0.7, .g = c.g * 0.7, .b = c.b * 0.7, .a = 1 },
                );
            }
        }
    }

    /// The ink on the pages a window can see, and the stroke being drawn.
    ///
    /// ## Why this is a row of discs
    ///
    /// `gleipnir/stroke.zig` already turns a pen dragged along a path into an
    /// outline -- caps, joins, miters -- and this does not call it, which
    /// needs saying. What that file produces is a *path*, and the only path
    /// pipeline in this reader draws the page: it runs on the worker thread,
    /// behind a `Scene` recorded once per page per zoom, and ink has to
    /// appear under the pointer this frame. The overlay these marks share
    /// with the highlights is the instance pipeline, and an instance is an
    /// axis-aligned rounded box by design -- see the note at the top of
    /// `DrawList.zig` about why it has no rotation.
    ///
    /// So the stroke is drawn the way `stroke.zig` itself says it thinks
    /// about strokes: **stamping, not offsetting.** A rounded box whose
    /// radius is half its side is a disc, a row of overlapping discs along a
    /// segment is that segment stroked with round caps, and a disc at each
    /// joint is the round join. It is the same algorithm reaching the screen
    /// through the pipeline that is available, and it has the same property
    /// that made it the choice there: no case analysis. A stroke that doubles
    /// back, a corner tighter than the pen, a segment of no length -- none of
    /// them is a special case, because overlapping opaque discs are their own
    /// union.
    ///
    /// The cost is instances, proportional to the visible length of stroke
    /// rather than to the number of points, which is why the spacing is tied
    /// to the radius and why pages out of view are skipped before any of it.
    fn drawInk(
        s: *Session,
        v: *View,
        b: *Buffer,
        range: View.Visible,
        over: *DrawList,
    ) !void {
        for (b.marks.items()) |mark| {
            if (mark.kind != .ink) continue;
            if (mark.page < range.first or mark.page >= range.end) continue;
            try s.strokePoints(v, mark.page, mark.points, mark.width, mark.color, over);
        }

        // The stroke in hand, in this window only. It is not a mark yet --
        // it becomes one when the button comes up -- so it is drawn from the
        // session's buffer and not from the list.
        if (!s.pen.down or v.buffer != s.pen.buffer) return;
        if (s.pen.page < range.first or s.pen.page >= range.end) return;
        if (v != s.layout().current()) return;
        try s.strokePoints(v, s.pen.page, s.stroking.items, s.pen.width, s.penColor(), over);
    }

    /// One polyline in user space, stamped into the overlay. See `drawInk`.
    fn strokePoints(
        s: *Session,
        v: *View,
        page: u32,
        points: []const Point,
        width: f32,
        color: Color,
        over: *DrawList,
    ) !void {
        _ = s;
        if (points.len == 0) return;

        // Never thinner than a pixel: a hairline at a fitted zoom is what
        // makes ink look like it failed to load rather than like a fine pen.
        const radius = @max(0.5, width * v.zoom * 0.5);
        // Half a radius between stamps. The union of discs that far apart is
        // scalloped by about two per cent of the radius, which is under a
        // pixel at every width this reader allows, and it is the spacing at
        // which two overlapping antialiased edges still leave the inside of
        // the stroke fully covered.
        const step = @max(0.5, radius * 0.5);

        var previous = v.windowPointOf(page, points[0]);
        try disc(over, previous, radius, color);
        for (points[1..]) |p| {
            const at = v.windowPointOf(page, p);
            const dx = at.x - previous.x;
            const dy = at.y - previous.y;
            const length = @sqrt(dx * dx + dy * dy);
            // The segment's own stamps, then the joint. `n` is how many fit;
            // the endpoint is the next iteration's `previous` and is stamped
            // there, so it is not stamped twice here.
            const n: u32 = @intFromFloat(@min(@floor(length / step), max_stamps));
            var i: u32 = 1;
            while (i <= n) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n + 1));
                try disc(over, .{ .x = previous.x + dx * t, .y = previous.y + dy * t }, radius, color);
            }
            try disc(over, at, radius, color);
            previous = at;
        }
    }

    /// A ceiling on the stamps one segment may cost.
    ///
    /// A segment is one frame of pointer movement, so it is short unless the
    /// window was behind -- a frame after a breakpoint, or a drag that ran
    /// across the screen while the reader was busy. The line is still drawn
    /// in that case; it is drawn with a gap in it rather than with ten
    /// thousand instances, which is the better of the two failures and is the
    /// same argument `keys.max_commands` makes.
    const max_stamps: f32 = 512;

    fn disc(over: *DrawList, at: Point, radius: f32, color: Color) !void {
        try over.rounded(
            .fromRect(at.x - radius, at.y - radius, at.x + radius, at.y + radius),
            .all(radius),
            color,
        );
    }

    /// The search's matches on the pages a window can see.
    ///
    /// Over the page rather than under it, like a highlight and for the same
    /// reason: a PDF's paper is opaque.
    ///
    /// Not in the accent, which is the trap. The accent is white by default,
    /// and white at a wash's alpha over white paper leaves the paper exactly
    /// as white as it was -- every match would be invisible on the only kind
    /// of page most documents have. So these are fixed colours, the way the
    /// selection's grey and the caret's blue are fixed and for the argument
    /// written beside them: the page underneath is the document's colour and
    /// the interface has no business tinting it. Matches get the selection's
    /// grey, because a match is the same kind of thing -- the interface
    /// pointing at the page, not a mark on it -- and the one being stood on
    /// gets the caret's blue, which is already this reader's word for where
    /// you are.
    ///
    /// Drawn in every window and not only the focused one: two windows on
    /// one document are looking at one search.
    fn drawSearchHits(s: *Session, v: *View, range: View.Visible, over: *DrawList) !void {
        const hits = s.search.hits.items;
        if (hits.len == 0) return;

        // Which hits are the match being stood on: the current one, plus its
        // continuation onto the next line if it has one. Both halves of a
        // match across a line break are one thing and are drawn as one.
        var last = s.search.current;
        if (s.search.at() != null) {
            while (last + 1 < hits.len and !hits[last + 1].starts) last += 1;
        }
        const standing = s.search.at() != null;

        const radius = markRadius(v.zoom);
        for (hits, 0..) |hit, i| {
            if (hit.page < range.first or hit.page >= range.end) continue;
            const on = standing and i >= s.search.current and i <= last;
            const block = blockOf(v.windowBox(hit.page, hit.box), v.zoom);
            try over.rounded(block, .all(radius), if (on) current_block else match_block);
            try over.border(block, .all(radius), 1, if (on) current_edge else match_edge);
        }
    }

    /// A match, and the one the reader is standing on. See `drawSearchHits`
    /// for why neither is the accent.
    const match_block: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.22 };
    const match_edge: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.5 };
    const current_block: Color = .{ .r = 0.1, .g = 0.45, .b = 0.95, .a = 0.28 };
    const current_edge: Color = .{ .r = 0.1, .g = 0.45, .b = 0.95, .a = 0.95 };

    /// A highlight's own shape: the glyph boxes, padded.
    ///
    /// The text map's boxes are tight around the type -- they are what a
    /// caret is placed against -- and a block drawn exactly on them clips the
    /// ascenders and reads as a stripe rather than as something laid over the
    /// words. A little air on each side, in device pixels so it does not grow
    /// with the zoom, is the difference.
    fn blockOf(box: Bounds, zoom: f32) Bounds {
        const pad = @max(1.0, zoom * 0.6);
        return .fromRect(box.min_x - pad, box.min_y - pad, box.max_x + pad, box.max_y + pad);
    }

    fn markRadius(zoom: f32) f32 {
        return @max(2.0, zoom * 1.5);
    }

    /// How heavy an underline, a strike-through or a squiggle is: a twelfth
    /// of the line it marks, so it keeps its weight against the type at
    /// every zoom, and never under a pixel.
    fn ruleWeight(box: Bounds) f32 {
        return @max(1.0, box.height() / 12);
    }

    /// An underline at the foot of the box, or a strike-through across its
    /// middle. One rect, as a highlight is one.
    fn ruleOf(box: Bounds, style: Marks.Style) Bounds {
        const t = ruleWeight(box);
        const top = if (style == .underline) box.max_y - t else (box.min_y + box.max_y - t) * 0.5;
        return .fromRect(box.min_x, top, box.max_x, top + t);
    }

    /// Where the line a mark is on begins, in window x, so that an arrow
    /// stops short of the line's first word and not of the mark's: a
    /// selection begun mid-line would otherwise have its arrow drawn over
    /// the words before it. The mark's own edge when the text is not known.
    fn lineStart(v: *View, b: *Buffer, mark: Marks.Mark, box: Bounds) f32 {
        const map = b.textMap(mark.page) orelse return box.min_x;
        if (map.isEmpty()) return box.min_x;
        const line = map.lines[map.lineAt(mark.box.min_x, (mark.box.min_y + mark.box.max_y) * 0.5)].box;
        const start = v.windowBox(mark.page, .fromRect(line.min_x, line.min_y, line.min_x + 1, line.max_y));
        return @min(start.min_x, box.min_x);
    }

    /// An arrow in the margin, pointing at the line `box` is on from left of
    /// `start`, where its words begin: a shaft and a head, in the mark's
    /// colour darkened to read on paper.
    ///
    /// The overlay draws axis-aligned boxes and nothing else, so the head is
    /// a stack of slices about a pixel wide, each shorter than the last: a
    /// triangle at any size worth drawing, for about a line's height in
    /// instances, and only on an anchor's first line.
    fn arrow(over: *DrawList, box: Bounds, start: f32, color: Color) !void {
        const h = @max(box.height(), 4);
        const tip = start - h * 0.25;
        const head = h * 0.5;
        const half = h * 0.3;
        const mid = (box.min_y + box.max_y) * 0.5;
        const t = @max(1.0, h * 0.1);
        const ink: Color = .{ .r = color.r * 0.75, .g = color.g * 0.75, .b = color.b * 0.75, .a = 1 };
        try over.fill(.fromRect(tip - head - h * 1.2, mid - t * 0.5, tip - head + 0.5, mid + t * 0.5), ink);

        const slices: f32 = std.math.clamp(@ceil(head), 2, 24);
        const step = head / slices;
        var j: f32 = 0;
        while (j < slices) : (j += 1) {
            const y = half * (1 - (j + 0.5) / slices);
            const x = tip - head + j * step;
            try over.fill(.fromRect(x, mid - y, x + step + 0.25, mid + y), ink);
        }
    }

    /// A squiggle along the foot of the box: half rings, the top of one and
    /// the bottom of the next, each clipped to its half. Two halves meet with
    /// the same upright tangent, so the chain is a smooth wave.
    ///
    /// Not ink's stamping, which it began as: a disc every half pixel was
    /// 562 instances a line at 120%, fifty thousand for a page of squiggles,
    /// rebuilt every frame. This is one a half wave, a fifth of that.
    fn squiggle(over: *DrawList, box: Bounds, color: Color) !void {
        const t = ruleWeight(box);
        // To the middle of the stroke, and to its outside edge.
        const r = 1.25 * t;
        const outer = r + t * 0.5;
        const y = box.max_y - outer;
        over.pushClip(box);
        defer over.popClip();

        var x = box.min_x + r;
        var up = true;
        while (x - r < box.max_x) : ({
            x += 2 * r;
            up = !up;
        }) {
            over.pushClip(.fromRect(x - outer, if (up) y - outer else y, x + outer, if (up) y else y + outer));
            defer over.popClip();
            try over.border(.fromRect(x - outer, y - outer, x + outer, y + outer), .all(outer), t, color);
        }
    }

    /// What is selected, drawn the way the highlight `m` would make of it, so
    /// that committing one changes nothing a reader can see. From the
    /// keyboard in visual mode, or from the mouse.
    ///
    /// Grey, and a shade darker than the highlight that follows it, because a
    /// selection is not a mark on the document: it is the interface saying
    /// which words it is holding. Drawn over the text at an alpha that
    /// darkens the paper rather than lifting the type -- see `highlight`.
    fn drawSelection(s: *Session, v: *View, over: *DrawList) !void {
        const sel = s.activeSelection(v) orelse return;
        // Whole lines only when visual line mode made it; a mouse drag is
        // always the glyphs it went over.
        const lines = v.selection() != null and s.lineSelection();

        s.boxes.clearRetainingCapacity();
        s.selectionBoxes(v.buffer, sel[0], sel[1], lines, &s.boxes) catch return;
        const radius = markRadius(v.zoom);
        for (s.boxes.items) |pb| {
            if (pb.page >= v.pages.len) continue;
            const block = blockOf(v.windowBox(pb.page, pb.box), v.zoom);
            try over.rounded(block, .all(radius), selection_block);
            // A hairline the same grey at full strength, so the ends of the
            // selection are legible against a figure or a dark background as
            // well as against paper.
            try over.border(block, .all(radius), 1, selection_edge);
        }
    }

    /// The selection block, and the line around it. Grey rather than the
    /// system blue every other reader uses: the page underneath is the
    /// document's colour, and the interface has no business tinting it.
    const selection_block: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.30 };
    const selection_edge: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.55 };

    /// The caret: a thin bar at the leading edge of the glyph it is on.
    fn drawCaret(s: *Session, v: *View, over: *DrawList) !void {
        if (!v.cursor.visible or v.cursor.caret.isEmpty()) return;
        if (v.cursor.page >= v.pages.len) return;

        const box = v.windowBox(v.cursor.page, v.cursor.caret);
        // A hairline at this zoom, never thinner than a pixel, so it is
        // visible on a page scaled down to a thumbnail.
        const w = @max(1.5, v.zoom);
        const focused = v == s.layout().current();
        try over.fill(
            .fromRect(box.min_x - w * 0.5, box.min_y, box.min_x + w * 0.5, box.max_y),
            if (focused) .{ .r = 0.1, .g = 0.45, .b = 0.95, .a = 1 } else .gray(0.55),
        );
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

    /// Everything the GPU placement depends on, hashed: if this has not
    /// changed, the instances on the device are still right.
    ///
    /// Compared rather than invalidated by hand: a `dirty` flag has to be set
    /// in every place that moves a view, and the one place it is forgotten is
    /// a window that stops following its own scroll.
    fn placementKey(s: *Session) u64 {
        var h: u64 = 1469598103934665603;
        const mix = struct {
            fn go(acc: *u64, value: anytype) void {
                const bits: u64 = switch (@TypeOf(value)) {
                    f32 => @as(u32, @bitCast(value)),
                    else => @intCast(value),
                };
                acc.* = (acc.* ^ bits) *% 1099511628211;
            }
        }.go;

        for (s.recorded.pages) |e| {
            mix(&h, e.page);
            mix(&h, e.buffer);
        }
        var it = s.layout().iterator();
        while (it.next()) |v| {
            mix(&h, v.buffer);
            mix(&h, @intFromBool(compare.overlaid(s, v)));
            mix(&h, v.scroll);
            mix(&h, v.pan);
            mix(&h, v.zoom);
            mix(&h, v.rect.min_x);
            mix(&h, v.rect.min_y);
            mix(&h, v.rect.max_x);
            mix(&h, v.rect.max_y);
        }
        return h;
    }

    /// Builds this frame's instance list: every visible page of every window,
    /// placed.
    ///
    /// Cheap on purpose. It touches no curve and no band -- only one matrix
    /// concatenation and one scissor per instance -- so scrolling costs a few
    /// hundred kilobytes of writes rather than a re-render.
    fn placeVisible(s: *Session) !void {
        s.recorded.frame.reset();

        var it = s.layout().iterator();
        while (it.next()) |v| {
            // An overlaid window shows a picture, not the recorded outlines.
            if (compare.overlaid(s, v)) continue;
            const box: [4]f32 = .{ v.rect.min_x, v.rect.min_y, v.rect.max_x, v.rect.max_y };
            const range = v.visiblePages();
            var i = range.first;
            while (i < range.end) : (i += 1) {
                for (s.recorded.pages) |entry| {
                    if (entry.buffer != v.buffer or entry.page != i) continue;
                    try s.recorded.frame.place(
                        s.gpa,
                        s.recorded.scene,
                        entry.range,
                        v.placement(i),
                        box,
                    );
                    break;
                }
            }
        }
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
    fn windowRect(s: *const Session, width: f32, height: f32) Bounds {
        if (s.chrome == null) return .fromRect(0, 0, width, @max(height, 1));
        const left = rails_mod.width;
        const top = s.tabInset();
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
    fn statusLine(s: *Session) chrome_mod.Status {
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
        if ((mode == .edit or mode == .note) and s.focusedMarkIndex() != null) {
            const held = b.marks.items()[s.focusedMarkIndex().?];
            // Among what the filter lets through, which is what `n` walks;
            // among them all when the one in hand is not one of those -- a
            // click takes hold of any mark, and a recolour can take one out.
            var filter = s.markFilter();
            if (!filter.matches(held, b.marks.said(held.anchor))) filter = .{};
            const at = b.marks.placeOf(held, &filter);
            var wr: std.Io.Writer = .fixed(&s.mode_buf);
            wr.print("{s} {d}/{d}", .{ mode.label(), at.place, at.of }) catch {};
            st.mode = s.mode_buf[0..wr.end];
            if (mode == .edit) {
                if (s.focusedComment()) |c| st.note = b.marks.comments.items[c].text;
            }
        }

        return st;
    }

    /// How much of the window the tab bar takes off the top.
    ///
    /// Zero for a single tabpage, which is every session until somebody opens
    /// a second one: a bar showing one tab says what the title bar says and
    /// costs a row of the page to say it. Asked here rather than of the
    /// chrome because `windowRect` needs the answer before the chrome for
    /// this frame has been built.
    fn tabInset(s: *const Session) f32 {
        return if (s.tabs.count() > 1) chrome_mod.tab_height else 0;
    }

    /// What is written on each tab: the document its focused window is
    /// looking at, and how many windows are in it when there is more than
    /// one.
    ///
    /// The count is on the tab because it is the one thing that distinguishes
    /// two tabs on the same document, which is the normal way a second tab
    /// begins -- `:tabnew` opens on what you were reading.
    fn tabLabels(s: *Session) []const []const u8 {
        const stamp = s.tabsKey();
        if (stamp == s.tabs_for) return s.tab_names.items;
        s.tabs_for = stamp;

        s.tab_text.clearRetainingCapacity();
        s.tab_ends.clearRetainingCapacity();
        s.tab_names.clearRetainingCapacity();

        var i: u32 = 0;
        while (i < s.tabs.count()) : (i += 1) {
            const l = s.tabs.at(i);
            const title = s.buffer(l.current().buffer).title;
            // Through a buffer rather than a writer over the list: the name
            // is a basename and a number, and a fixed print cannot fail on
            // anything but a pathological title -- which then keeps its own
            // name and loses only the count.
            var buf: [192]u8 = undefined;
            const name = if (l.count() > 1)
                std.fmt.bufPrint(&buf, "{s} ({d})", .{ title[0..@min(title.len, 160)], l.count() }) catch title
            else
                title;
            s.tab_text.appendSlice(s.gpa, name) catch break;
            s.tab_ends.append(s.gpa, @intCast(s.tab_text.items.len)) catch break;
        }

        // The slices last, once the bytes have stopped moving.
        var from: u32 = 0;
        for (s.tab_ends.items) |to| {
            s.tab_names.append(s.gpa, s.tab_text.items[from..to]) catch break;
            from = to;
        }
        return s.tab_names.items;
    }

    /// Everything the bar would draw differently, hashed. Compared rather
    /// than invalidated by hand, for the reason `placementKey` is: a flag set
    /// in every place that opens, closes or retitles a tab is a flag that
    /// will be forgotten in one of them.
    fn tabsKey(s: *Session) u64 {
        var h: u64 = 1469598103934665603;
        const mix = struct {
            fn go(acc: *u64, value: u64) void {
                acc.* = (acc.* ^ value) *% 1099511628211;
            }
        }.go;

        mix(&h, s.tabs.count());
        mix(&h, s.tabs.active);
        var i: u32 = 0;
        while (i < s.tabs.count()) : (i += 1) {
            const l = s.tabs.at(i);
            mix(&h, l.current().buffer);
            mix(&h, l.count());
        }
        return h;
    }

    /// What the tab bar was asked for, carried out.
    ///
    /// A tab closed by its cross is shown first and closed after, so that
    /// closing one is the same act as clicking it and typing `:tabclose` --
    /// one path through the session, and the windows in it get their places
    /// written down on the way out either way.
    fn applyTabs(s: *Session, r: thviti.widgets.tabs.Result) void {
        if (r.activated) |i| s.showTab(i);
        if (r.closed) |i| {
            s.showTab(i);
            _ = s.closeTab();
        }
        if (r.added) s.newTab();
    }

    /// What the right rail shows: where you are, and how far it goes.
    fn railLine(s: *Session) rails_mod.Right {
        const v = s.view();
        s.fillRailButtons();
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
    fn fillRailButtons(s: *Session) void {
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
    fn modeRail(s: *Session) rails_mod.Left {
        if (s.swatches[0].name.len == 0 or !std.meta.eql(s.swatches[0].color, s.highlight)) {
            for (&s.swatches, 0..) |*sw, i| {
                sw.* = .{
                    .name = paletteName(@intCast(i)),
                    .color = s.paletteColor(@intCast(i)),
                };
            }
        }
        s.fillRailButtons();
        return .{ .mode = s.keymap.mode, .palette = &s.swatches, .extra = s.rail_left.items };
    }

    /// What a rail asked for, carried out.
    fn applyRail(s: *Session, want: rails_mod.Want) void {
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
                s.applyEffects();
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
                s.applyEffects();
            },
        }
        s.dirty_title = true;
    }

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
                const filter = s.markFilter();
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
    fn drawPanel(s: *Session, c: *chrome_mod.Chrome) !void {
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
        const declared = s.declaredPanel(which);
        const rows = s.panelRows(which);
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
            .bookmarks => s.goToBookmark(chosen.id),
            // The same gesture `n` makes: the highlight goes in hand and the
            // view scrolls to it, so clicking a row and pressing `d` deletes
            // the one that was clicked.
            .annotations => s.focusMark(chosen.id),
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
                s.applyEffects();
            },
        }
        s.dirty_title = true;
    }

    /// The plugin panel `which` names, or null for one of the reader's own.
    fn declaredPanel(s: *Session, which: rails_mod.Panel) ?galdr.Runtime.Panel {
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

    fn updateTitle(s: *Session, window: lyngvi.Window) void {
        const v = s.view();
        const page = v.currentPage();
        const windows = s.layout().count();
        if (!s.dirty_title and page == s.shown.page and v.zoom == s.shown.zoom and
            v.buffer == s.shown.buffer and windows == s.shown.windows) return;

        s.dirty_title = false;
        s.shown = .{ .buffer = v.buffer, .page = page, .zoom = v.zoom, .windows = windows };

        var buf: [1024]u8 = undefined;
        window.setTitle(s.titleText(&buf, page, windows));
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
    fn titleText(s: *Session, buf: []u8, page: u32, windows: u32) []const u8 {
        const v = s.view();
        const base = s.buffer(v.buffer).title;
        var w: std.Io.Writer = .fixed(buf);

        w.print("{s} -- page {d} of {d} -- {d:.0}%", .{
            base[0..@min(base.len, 160)], page + 1, v.pages.len, v.percent(),
        }) catch return buf[0..w.end];
        if (windows > 1) w.print(" -- {d} windows", .{windows}) catch return buf[0..w.end];
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
        s.applySplits(splits);

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
        while (s.firstMissing()) |job| {
            if (slot >= cache_slots) break;

            const image = if (job.want == .overlay)
                compare.rasteriseOverlay(s, job) catch {
                    s.noteFailure(job);
                    continue;
                }
            else page: {
                const b = s.buffer(job.buffer);
                var result = content.page(gpa, b.doc, b.pages[job.page], page_options) catch break;
                defer result.deinit(gpa);

                if (text.build(gpa, result.list) catch null) |map| b.putMap(gpa, job.page, map);

                break :page s.rasterise(job, result.list, b) catch {
                    s.noteFailure(job);
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

    /// `--split vh`: the splits a scripted shot asked for.
    fn applySplits(s: *Session, spec: []const u8) void {
        for (spec) |c| {
            s.splitWindow(if (c == 'v') .vertical else .horizontal);
        }
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
        s.applySplits(settings.splits);
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

        var worker: Rasteriser = .{ .session = s, .io = ctx.io };
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
            if (s.nextJob()) |job| worker.post(job);
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
            s.poll(dt);

            // Collect whatever the rasterising thread finished, and ask it
            // for the next page. Neither waits: the frame is drawn from what
            // is in the cache now, and a page still being worked on is blank
            // paper until it arrives.
            //
            // `pixels` stays alive until the frame is submitted, because
            // `Upload.pixels` is read during `frame`.
            var pixels: ?[]u8 = null;
            defer if (pixels) |p| gpa.free(p);
            pixels = s.collectPage(&worker, &renderer, &list, &uploads) catch |err| switch (err) {
                error.OutOfMemory => return ctx.fail("out of memory rendering a page", .{}),
                else => null,
            };
            // After what arrived is in and before the next job is chosen, so
            // the worker is asked for what the step just brought into view.
            if (bench) |*b| {
                if (s.firstMissing() != null) {
                    b.waited += 1;
                } else if (b.pending) |*l| {
                    // Arrived. Drawn for a frame before the next step, or a
                    // flip would move on from every page unseen.
                    b.arrival.push(msOf(l.lap()));
                    b.pending = null;
                } else {
                    if (!b.advance(s.view())) break;
                    if (s.firstMissing() != null) b.pending = .start(ctx.io);
                }
            }
            if (s.jobToPost()) |job| worker.post(job);

            // One resumption each for the handlers that yielded, and no more:
            // a handler that gave the frame back gets it back on the next
            // one, which is the whole of what a coroutine is promised here.
            if (s.plugins) |rt| {
                rt.pump();
                s.applyEffects();
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
                c.top = s.tabInset();
                const want = try c.status(s.statusLine());
                if (try c.tabBar(s.tabLabels(), s.tabs.active)) |asked_tabs| s.applyTabs(asked_tabs);
                const asked = try c.rightRail(s.railLine());
                if (asked) |wanted| s.applyRail(wanted);
                if (try c.leftRail(s.modeRail())) |wanted| s.applyRail(wanted);
                try s.drawPanel(c);
                const asked_find = try find_mod.bar(
                    &c.ui,
                    c.face,
                    c.theme,
                    &c.icons,
                    &s.find,
                    s.searchCount(),
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
                if (s.settings.open and s.pluginSettingsStale()) s.readSettings();
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
                if (changed) |c2| s.changeSetting(c2);
                if (asked_find) |what| s.applyFind(what);
                // After the frame is closed, because a command may open
                // another window, close this one, or leave the reader.
                if (chosen) |what| s.runChosen(what);
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
                    const key = s.placementKey();
                    if (s.placed == null or s.placed.? != key) {
                        var place_lap: Lap = .start(ctx.io);
                        try s.placeVisible();
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
                (s.firstMissing() == null or drawn >= shot_patience);
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
            s.applyEffects();
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
    _ = plugins_mod;
}

test "a split is two windows on one document, scrolling apart" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    s.splitWindow(.vertical);
    try testing.expectEqual(@as(u32, 2), s.layout().count());

    // Both are looking at the same buffer...
    var it = s.layout().iterator();
    while (it.next()) |v| try testing.expectEqual(@as(u32, 0), v.buffer);

    // ...and scrolling one does not move the other, which is the whole point
    // of the scroll living in the view.
    s.view().scroll = 500;
    var others: u32 = 0;
    var walk = s.layout().iterator();
    while (walk.next()) |v| {
        if (v != s.layout().current() and v.scroll != 500) others += 1;
    }
    try testing.expectEqual(@as(u32, 1), others);
}

test "a highlight made in one window is in the other" {
    // The requirement in one test: two views, one underlying document, and a
    // change made through one visible through the other with nothing copied.
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    s.splitWindow(.vertical);
    const before = s.buffer(0).marks.revision;

    s.highlightBoxes(0, &.{.{ .page = 1, .box = .fromRect(100, 700, 300, 712) }}, s.accent);

    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
    try testing.expect(s.buffer(0).marks.revision != before);

    var it = s.layout().iterator();
    while (it.next()) |v| {
        try testing.expect(v.marks_seen != s.buffer(v.buffer).marks.revision);
    }
}

test "every window's visible pages are asked for, focused window first" {
    const gpa = testing.allocator;
    var buf: [64]fenrir.Page = undefined;
    // Half scale, so two pages fit at once.
    var s = try sessionOf(gpa, fakePages(&buf, 40), 0.5, 1000, 800);
    defer closeSession(&s);

    s.view().scrollToPage(20);
    s.splitWindow(.vertical);
    s.view().scrollToPage(4);

    // The focused window is the one that just scrolled to page 4.
    try testing.expectEqual(@as(u32, 4), s.firstMissing().?.page);

    // With that cached, the rest of the focused window, then the other one.
    s.slots[0] = .{ .buffer = 0, .page = 4, .zoom = s.view().zoom, .gpu = 1, .list = 1 };
    const next = s.firstMissing().?;
    try testing.expect(next.page == 5 or next.page == 20);
}

test "two windows at different zooms need two rasters and one recording" {
    // The difference between the backends, as a test: the CPU cache is keyed
    // by zoom because its contents are pixels, and the GPU cache is not
    // because its contents are curves.
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    s.splitWindow(.vertical);
    s.view().setZoom(2);

    const a = s.layout().viewAt(0);
    const b = s.layout().viewAt(1);
    try testing.expect(a.zoom != b.zoom);

    s.backend = .cpu;
    s.slots[0] = .{ .buffer = 0, .page = 0, .zoom = a.zoom, .gpu = 1, .list = 1 };
    try testing.expect(s.cached(a, 0));
    try testing.expect(!s.cached(b, 0));

    s.backend = .gpu;
    s.recorded.pages[0] = .{ .buffer = 0, .page = 0, .source = .{} };
    try testing.expect(s.cached(a, 0));
    try testing.expect(s.cached(b, 0));
    s.recorded.pages[0].source = null;
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

/// A square `side` across as straight quadratics, the shape a scene stores.
fn squareCurves(side: f32) [4]gleipnir.slug.Curve {
    const p = [_][2]f32{ .{ 0, 0 }, .{ side, 0 }, .{ side, side }, .{ 0, side } };
    var out: [4]gleipnir.slug.Curve = undefined;
    for (p, 0..) |a, i| {
        const b = p[(i + 1) % 4];
        out[i] = .{
            .x0 = a[0],
            .y0 = a[1],
            .x1 = (a[0] + b[0]) * 0.5,
            .y1 = (a[1] + b[1]) * 0.5,
            .x2 = b[0],
            .y2 = b[1],
        };
    }
    return out;
}

fn curvesOf(store: gleipnir.slug.Store, header: u32) []const gleipnir.slug.Curve {
    const h = store.headers.items[header];
    return store.curves.items[h.curve_first..][0..h.curve_count];
}

test "evicting a recorded page leaves every other page's range naming its own curves" {
    // An eviction merges the survivors again, which moves every page after
    // the hole. A range kept from before that would draw another page's
    // outlines at this page's positions, which looks like a rendering bug
    // anywhere but here.
    const gpa = testing.allocator;
    const no_clip = gleipnir.slugpipe.no_clip;
    var rc: Recorded = .{};
    defer rc.deinit(gpa);

    for (0..cache_slots + 1) |i| {
        // A different size per page, and a clip, so each page's curves and
        // nodes are its own.
        var page: Scene = .{};
        page.reset(.{ 100, 100 });
        const own = squareCurves(@floatFromInt(10 + i));
        const unit = squareCurves(1);
        try page.pushClip(gpa, &own, .nonzero, .identity);
        try page.draw(gpa, &unit, .nonzero, .identity, .black, 1, .normal);
        page.popClip();
        try page.draw(gpa, &own, .even_odd, .identity, .black, 1, .normal);

        // Page 0 is drawn again just before the cache overflows, so page 1
        // is the one that has waited longest.
        if (i == cache_slots) {
            rc.stamp = 100;
            rc.touch(0, 0);
        }
        rc.stamp = i;
        try rc.insert(gpa, 0, @intCast(i), page);
    }

    try testing.expect(rc.has(0, 0));
    try testing.expect(!rc.has(0, 1));
    try testing.expect(rc.has(0, cache_slots));

    var instances: u32 = 0;
    for (rc.pages) |e| {
        const src = e.source orelse continue;
        instances += e.range.instance_count;
        try testing.expectEqual(src.instanceCount(), e.range.instance_count);
        try testing.expectEqual(@as(u32, @intCast(src.clips.items.len)), e.range.clip_count);

        for (src.instances.items, 0..) |want, k| {
            const got = rc.scene.instances.items[e.range.first_instance + k];
            try testing.expectEqualSlices(
                gleipnir.slug.Curve,
                curvesOf(src.store, want.header),
                curvesOf(rc.scene.store, got.header),
            );
            if (want.clip_node == no_clip) {
                try testing.expectEqual(no_clip, got.clip_node);
                continue;
            }
            try testing.expectEqual(want.clip_node + e.range.first_clip, got.clip_node);
            try testing.expectEqualSlices(
                gleipnir.slug.Curve,
                curvesOf(src.store, src.clips.items[want.clip_node].header),
                curvesOf(rc.scene.store, rc.scene.clips.items[got.clip_node].header),
            );
        }
    }
    // Nothing left behind from the page that went.
    try testing.expectEqual(rc.scene.instanceCount(), instances);
}

test "a page rendered for a window that has closed is not cached" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(s.wantedNow(.{ .buffer = 0, .page = 0, .zoom = 1 }));
    // Nobody is looking at this document at this zoom any more.
    try testing.expect(!s.wantedNow(.{ .buffer = 0, .page = 0, .zoom = 3.5 }));
    try testing.expect(!s.wantedNow(.{ .buffer = 9, .page = 0, .zoom = 1 }));
}

test "closing the last window is a quit, and closing others is not" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(!s.closeWindow());
    s.splitWindow(.vertical);
    try testing.expect(s.closeWindow());
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    try testing.expect(!s.closeWindow());
}

test "a selection runs in reading order, inclusive, and across pages" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);
    try putText(&s, 1, 3, 4);

    var boxes: std.ArrayList(Session.PageBox) = .empty;
    defer boxes.deinit(gpa);

    // From the middle of the first line to the middle of the last: three
    // boxes, the middle one whole and the ends partial.
    try s.selectionBoxes(0, .{ .page = 0, .line = 0, .column = 2 }, .{ .page = 0, .line = 2, .column = 1 }, false, &boxes);
    try testing.expectEqual(@as(usize, 3), boxes.items.len);
    try testing.expect(boxes.items[1].box.width() > boxes.items[0].box.width());
    try testing.expect(boxes.items[1].box.width() > boxes.items[2].box.width());

    // Backwards is the same selection.
    var backwards: std.ArrayList(Session.PageBox) = .empty;
    defer backwards.deinit(gpa);
    try s.selectionBoxes(0, .{ .page = 0, .line = 2, .column = 1 }, .{ .page = 0, .line = 0, .column = 2 }, false, &backwards);
    try testing.expectEqual(boxes.items.len, backwards.items.len);
    try testing.expectApproxEqAbs(boxes.items[0].box.min_x, backwards.items[0].box.min_x, 0.01);

    // One glyph is a selection of one glyph: `v` then `m` highlights the
    // letter under the cursor, as it does in Vim.
    try s.selectionBoxes(0, .{ .page = 0, .line = 1, .column = 1 }, .{ .page = 0, .line = 1, .column = 1 }, false, &boxes);
    try testing.expectEqual(@as(usize, 1), boxes.items.len);

    // Line-wise, and over a page break: the last line of page 0 and the
    // first of page 1, both whole.
    try s.selectionBoxes(0, .{ .page = 0, .line = 2, .column = 3 }, .{ .page = 1, .line = 0, .column = 0 }, true, &boxes);
    try testing.expectEqual(@as(usize, 2), boxes.items.len);
    try testing.expectEqual(@as(u32, 0), boxes.items[0].page);
    try testing.expectEqual(@as(u32, 1), boxes.items[1].page);
    try testing.expectApproxEqAbs(boxes.items[0].box.width(), boxes.items[1].box.width(), 0.01);
}

test "visual mode: select with motions, highlight in a colour, undo it" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    // `v`, `j`, `w`, `3`: what the keymap turns those keys into.
    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    try testing.expect(s.view().anchor != null);
    _ = s.apply(.{ .move_cursor = .down });
    _ = s.apply(.{ .move_cursor = .word_next });
    s.keymap.mode = .normal;
    _ = s.apply(.{ .highlight_selection = 2 });

    const marks = &s.buffer(0).marks;
    // Two lines selected, so two marks, in the third palette colour.
    try testing.expectEqual(@as(usize, 2), marks.count());
    try testing.expectEqual(Library.parseColor("green").?, marks.items()[0].color);
    try testing.expect(s.view().anchor == null);

    // And one `u` takes both back.
    _ = s.apply(.undo);
    try testing.expectEqual(@as(usize, 0), marks.count());
    _ = s.apply(.redo);
    try testing.expectEqual(@as(usize, 2), marks.count());
}

/// A page carrying what Acrobat leaves and what a save by fenrir would: a
/// highlight of two lines with a note and a reply, under names that are not
/// fenrir's, and a stroke named `f7`.
const annotated_pdf =
    \\%PDF-1.7
    \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    \\2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    \\3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800]
    \\  /Annots [30 0 R 31 0 R 32 0 R 33 0 R] >> endobj
    \\30 0 obj << /Subtype /Highlight /Rect [87 521 273 570] /NM (305e35fa) /C [1 0.75 0]
    \\  /Contents (why) /QuadPoints [134 569 272 569 134 557 272 557 87 557 272 557 87 545 272 545] >> endobj
    \\31 0 obj << /Subtype /Text /Rect [0 0 20 20] /IRT 30 0 R /NM (ccbe0138) /Contents (because) >> endobj
    \\32 0 obj << /Subtype /Ink /Rect [0 0 99 99] /NM (f7) /InkList [[10 10 40 40]] >> endobj
    \\33 0 obj << /Subtype /Link /Rect [0 0 99 99] >> endobj
    \\trailer << /Root 1 0 R /Size 40 >>
    \\startxref 0
    \\%%EOF
    \\
;

test "the file's annotations are marks and comments, and the library's names win" {
    const gpa = testing.allocator;
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};
    var s = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&s);
    const b = s.buffer(0);
    b.doc = &doc;

    // The library already holds the stroke, as a journal row newer than
    // the file: it is not read a second time.
    _ = try b.marks.add(gpa, .{ .kind = .ink, .points = &.{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } }, .anchor = 7 }, true);
    s.readAnnots(0, null);

    const marks = &b.marks;
    try testing.expectEqual(@as(usize, 3), marks.count());
    const line = marks.items()[1];
    try testing.expectEqual(Marks.Style.highlight, line.style);
    try testing.expectApproxEqAbs(@as(f32, 545), marks.items()[2].box.min_y, 1e-3);
    try testing.expectEqual(line.anchor, marks.items()[2].anchor);

    // The note is the first comment and has the highlight's name; the reply
    // keeps its own. Both are spelled back as they were written.
    const said = marks.said(line.anchor);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqualStrings("why", said[0].text);
    try testing.expectEqualStrings("because", said[1].text);
    var name: [Library.name_len]u8 = undefined;
    try testing.expectEqualStrings("305e35fa", Session.spell(b, said[0].name, &name));
    try testing.expectEqualStrings("ccbe0138", Session.spell(b, said[1].name, &name));

    // None of it is a change, and fenrir's next name is past the stroke's.
    try testing.expect(!marks.dirty);
    try testing.expect(marks.newName() > 7);
}

test "a comment on another program's highlight is stored under that program's name" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    var doc = try fenrir.open(gpa, try gpa.dupe(u8, annotated_pdf));
    defer doc.deinit();
    var buf: [1]fenrir.Page = .{(try fenrir.pages.all(&doc))[0]};
    var s = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    const b = s.buffer(0);
    b.doc = &doc;
    s.readAnnots(0, null);

    const anchor = b.marks.items()[0].anchor;
    _ = try b.marks.addComment(gpa, .{ .anchor = anchor, .text = "and so" }, false);
    s.applyEffects();

    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 1), said.len);
    try testing.expectEqualStrings("305e35fa", said[0].anchor);
    // Its own name is fenrir's: the anchor's went to the note in the file.
    try testing.expect(Library.nameNumber(said[0].nm) != null);

    // Read back on the next open, it lands on the same highlight.
    var again = try sessionOf(gpa, &buf, 1, 1000, 800);
    defer closeSession(&again);
    try giveLibrary(&again, lib);
    again.buffer(0).doc = &doc;
    again.loadMarks(0);
    again.readAnnots(0, null);
    const lines = again.buffer(0).marks.items();
    try testing.expectEqual(@as(usize, 3), again.buffer(0).marks.said(lines[0].anchor).len);
}

test "c on a selection makes one anchor and its first comment, and c in edit mode another" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    try putText(&s, 0, 3, 4);

    // `v`, `j`, `c`, then the comment, as the keymap sends them.
    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .down });
    s.keymap.mode = .note;
    _ = s.apply(.comment_selection);
    for ("why") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    s.applyEffects();

    // Two lines, one anchor, and the comment on it named as the anchor is.
    const marks = &s.buffer(0).marks;
    try testing.expectEqual(@as(usize, 2), marks.count());
    const anchor = marks.items()[0].anchor;
    try testing.expectEqual(anchor, marks.items()[1].anchor);
    try testing.expectEqual(anchor, marks.said(anchor)[0].name);
    try testing.expect(s.view().anchor == null);
    try testing.expectEqualStrings("why", s.statusLine().note);

    // `c` in edit mode is a reply on the same anchor, taken in hand.
    _ = s.apply(.add_comment);
    try testing.expectEqualStrings("", s.note.items);
    s.keymap.mode = .note;
    for ("because") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    try testing.expectEqual(@as(usize, 2), marks.said(anchor).len);
    try testing.expectEqualStrings("because", s.statusLine().note);

    // `a` changes the one in hand, which is the reply, not the first.
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    try testing.expectEqualStrings("because", s.note.items);
    _ = s.apply(.{ .note_char = '!' });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    s.applyEffects();
    try testing.expectEqualStrings("why", marks.said(anchor)[0].text);
    try testing.expectEqualStrings("because!", marks.said(anchor)[1].text);

    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqualStrings(said[0].anchor, said[1].anchor);
    try testing.expect(!std.mem.eql(u8, said[0].nm, said[1].nm));
    try testing.expectEqualStrings("because!", said[1].text);

    // With nothing selected there is nothing to comment on, and no mark.
    s.keymap.mode = .note;
    _ = s.apply(.comment_selection);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expectEqual(@as(usize, 2), marks.count());
}

test "]c reads each comment of a thread, and in edit mode takes it in hand" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    try commentOn(marks, gpa, 0, "is this right?");
    try commentOn(marks, gpa, 0, "no");
    try commentOn(marks, gpa, 1, "see here");

    // Normal mode reads them in order without taking any in hand.
    const next: keys.Command = .{ .jump_mark = .{ .forwards = true, .comments = true } };
    _ = s.apply(next);
    try testing.expect(std.mem.endsWith(u8, s.status, "is this right?"));
    _ = s.apply(next);
    try testing.expect(std.mem.startsWith(u8, s.status, "comment 2/3"));
    try testing.expect(std.mem.endsWith(u8, s.status, "no"));
    _ = s.apply(next);
    try testing.expect(std.mem.endsWith(u8, s.status, "see here"));
    try testing.expect(s.focus_mark == null);

    // Edit mode takes up the first mark with its first comment in hand;
    // `]c` moves on to the reply and takes that, so `a` opens it.
    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqualStrings("is this right?", s.statusLine().note);
    _ = s.apply(next);
    try testing.expectEqual(marks.items()[0].key, s.focus_mark.?);
    try testing.expectEqualStrings("no", s.statusLine().note);
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    try testing.expectEqualStrings("no", s.note.items);
}

test "a selection's lines are one anchor, and marking them again keeps its comment" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    const lines = [_]Session.PageBox{
        .{ .page = 0, .box = .fromRect(100, 700, 300, 712) },
        .{ .page = 0, .box = .fromRect(100, 686, 300, 698) },
        .{ .page = 0, .box = .fromRect(100, 672, 200, 684) },
    };
    const anchor = s.markBoxes(0, &lines, s.accent, .highlight);
    const marks = &s.buffer(0).marks;
    for (marks.items()) |m| try testing.expectEqual(anchor, m.anchor);
    try commentOn(marks, gpa, 0, "one claim");

    // The comment on the first line, and the other two under it.
    const rows = s.panelRows(.annotations);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("one claim", rows[0].label);
    try testing.expectEqual(@as(u8, 0), rows[0].depth);
    try testing.expectEqual(@as(u8, 1), rows[2].depth);

    // Underlined over the same words: new marks, a new anchor, and the
    // comment moved onto it rather than lost with the old marks.
    const again = s.markBoxes(0, &lines, s.accent, .underline);
    try testing.expect(again != anchor);
    try testing.expectEqual(@as(usize, 3), marks.count());
    try testing.expectEqual(@as(usize, 0), marks.said(anchor).len);
    try testing.expectEqualStrings("one claim", marks.said(again)[0].text);

    // One `u` is one step back to the old marks with their comment.
    _ = s.apply(.undo);
    try testing.expectEqualStrings("one claim", marks.said(anchor)[0].text);
    for (marks.items()) |m| try testing.expectEqual(anchor, m.anchor);
}

test "highlighting over a highlight replaces it rather than stacking" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    const line: Session.PageBox = .{ .page = 0, .box = .fromRect(100, 695, 160, 710) };
    s.highlightBoxes(0, &.{line}, Library.parseColor("yellow").?);
    s.highlightBoxes(0, &.{line}, Library.parseColor("blue").?);
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
    try testing.expectEqual(Library.parseColor("blue").?, s.buffer(0).marks.items()[0].color);
}

test "visual d removes the highlights the selection touches" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    // A highlight on each of the three lines.
    const map = s.buffer(0).textMap(0).?;
    for (map.lines) |l| s.highlightBoxes(0, &.{.{ .page = 0, .box = l.box }}, s.accent);
    try testing.expectEqual(@as(usize, 3), s.buffer(0).marks.count());

    // Select from the second line to the third, and delete.
    s.view().cursorTo(.{ .page = 0, .line = 1, .column = 0 }, map);
    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .down });
    s.keymap.mode = .normal;
    _ = s.apply(.unhighlight_selection);

    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
}

test "a selection underlined, then squiggled in edit mode, keeps its style in the library" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    try putText(&s, 0, 3, 4);

    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .word_next });
    s.keymap.mode = .normal;
    _ = s.apply(.{ .style_selection = .underline });
    s.applyEffects();
    const marks = &s.buffer(0).marks;
    try testing.expectEqual(Marks.Style.underline, marks.items()[0].style);

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    _ = s.apply(.{ .restyle_mark = .squiggly });
    s.applyEffects();

    // Read back as the next session would.
    marks.deinit(gpa);
    s.loadMarks(0);
    try testing.expectEqual(Marks.Style.squiggly, marks.items()[0].style);
}

test "an underline is one rect at the foot of the line, and a squiggle stays inside it" {
    const gpa = testing.allocator;
    const box: Bounds = .fromRect(100, 200, 400, 224);
    const under = Session.ruleOf(box, .underline);
    try testing.expectEqual(box.max_y, under.max_y);
    try testing.expectApproxEqAbs(@as(f32, 2), under.height(), 1e-4);
    const through = Session.ruleOf(box, .strikeout);
    try testing.expectApproxEqAbs((box.min_y + box.max_y) * 0.5, (through.min_y + through.max_y) * 0.5, 1e-4);

    var d: DrawList = .init(gpa, .fromRect(0, 0, 1000, 1000));
    defer d.deinit();
    try Session.squiggle(&d, box, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    var ink: Bounds = .empty;
    for (d.instances.items) |i| ink = ink.add(.{ .x = i.dst[0], .y = i.dst[1] }).add(.{ .x = i.dst[2], .y = i.dst[3] });
    try testing.expect(ink.max_y <= box.max_y + 1e-3 and ink.min_y >= box.min_y);
    // A half ring every five pixels of a line 24 tall: what it costs a frame.
    try testing.expectEqual(@as(usize, 60), d.instances.items.len);
}

test "edit mode walks highlights in reading order, recolours, comments and deletes, and the library follows" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);

    // Made bottom first, so reading order and creation order differ.
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 600, 200, 612) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.applyEffects();
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 2), rows.len);
    }

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    const marks = &s.buffer(0).marks;
    // No cursor out, so the first in reading order: the higher one.
    try testing.expectApproxEqAbs(@as(f32, 700), marks.items()[s.focusedMarkIndex().?].box.min_y, 0.01);

    _ = s.apply(.next_mark);
    try testing.expectApproxEqAbs(@as(f32, 600), marks.items()[s.focusedMarkIndex().?].box.min_y, 0.01);

    _ = s.apply(.{ .recolour_mark = 4 });
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    for ("check") |c| _ = s.apply(.{ .note_char = c });
    _ = s.apply(.note_backspace);
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    s.applyEffects();

    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        var found = false;
        for (rows) |r| {
            if (r.y0 != 600) continue;
            found = true;
            try testing.expectEqualStrings("#ef476f", r.color);
            // Written on its anchor, named as the anchor is.
            const said = try lib.comments("/docs/a.pdf");
            defer lib.freeComments(said, said.len);
            try testing.expectEqual(@as(usize, 1), said.len);
            try testing.expectEqualStrings("chec", said[0].text);
            try testing.expectEqualStrings(r.anchor, said[0].anchor);
            try testing.expectEqualStrings(r.anchor, said[0].nm);
        }
        try testing.expect(found);
    }

    // Delete it: focus moves on to the other one, and the row goes, and
    // the comment with it, since it was the anchor's only line.
    _ = s.apply(.delete_mark);
    s.applyEffects();
    try testing.expectEqual(@as(usize, 1), marks.count());
    try testing.expect(s.focus_mark != null);
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 1), rows.len);
        const said = try lib.comments("/docs/a.pdf");
        defer lib.freeComments(said, said.len);
        try testing.expectEqual(@as(usize, 0), said.len);
    }

    // Undo the deletion: a row again, with its colour and its comment.
    _ = s.apply(.undo);
    s.applyEffects();
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqual(@as(usize, 2), rows.len);
        const said = try lib.comments("/docs/a.pdf");
        defer lib.freeComments(said, said.len);
        try testing.expectEqual(@as(usize, 1), said.len);
        try testing.expectEqualStrings("chec", said[0].text);
    }

    // Rubbing the comment out keeps none, rather than an empty one.
    _ = s.apply(.next_mark);
    try testing.expectApproxEqAbs(@as(f32, 600), marks.items()[s.focusedMarkIndex().?].box.min_y, 0.01);
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    for ("chec") |_| _ = s.apply(.note_backspace);
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    s.applyEffects();
    const said = try lib.comments("/docs/a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 0), said.len);
}

/// A comment on the anchor of the mark at `index`, as `a` in edit mode
/// would write it.
fn commentOn(marks: *Marks, gpa: Allocator, index: usize, text_: []const u8) !void {
    _ = try marks.addComment(gpa, .{ .anchor = marks.items()[index].anchor, .text = text_ }, false);
}

test "edit mode on a document with no highlights says so and stays in normal" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expect(s.status.len != 0);
}

test "]a and ]c walk the marks from where the reader is, and come round again" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    // Nothing to go to says so, rather than doing nothing.
    _ = s.apply(.{ .jump_mark = .{ .forwards = true } });
    try testing.expect(s.status.len != 0);
    try testing.expect(s.last_jump == null);

    // These pages have no text, so the caret never moves: the case a stroke
    // of ink is, and the one a jump from the caret alone would get stuck on.
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 300, 200, 312) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 1, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    var top: u64 = 0;
    var mid: u64 = 0;
    var p1: u64 = 0;
    for (marks.items()) |m| {
        if (m.page == 1) p1 = m.key else if (m.box.min_y > 600) top = m.key else mid = m.key;
    }
    try commentOn(marks, gpa, marks.indexOf(mid).?, "why?");

    // From the top of the page in front of the window, in reading order.
    const next: keys.Command = .{ .jump_mark = .{ .forwards = true } };
    _ = s.apply(next);
    try testing.expectEqual(top, s.last_jump.?.key);
    _ = s.apply(next);
    try testing.expectEqual(mid, s.last_jump.?.key);
    _ = s.apply(next);
    try testing.expectEqual(p1, s.last_jump.?.key);
    // Past the last it comes round, and the status line says it did.
    _ = s.apply(next);
    try testing.expectEqual(top, s.last_jump.?.key);
    try testing.expect(std.mem.indexOf(u8, s.status, "from the top") != null);
    // Normal mode lands on a mark without taking hold of it.
    try testing.expect(s.focus_mark == null);

    // A comment passes over the marks with none, and reads the comment out.
    _ = s.apply(.{ .jump_mark = .{ .forwards = true, .comments = true } });
    try testing.expectEqual(mid, s.last_jump.?.key);
    try testing.expect(std.mem.endsWith(u8, s.status, "why?"));
    _ = s.apply(.{ .jump_mark = .{ .forwards = false, .comments = true } });
    try testing.expectEqual(mid, s.last_jump.?.key);

    // In edit mode the jump moves the highlight in hand, and the : line
    // reaches the same place the keys do.
    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    const held = s.focus_mark.?;
    try testing.expect(s.exec("mprevious"));
    try testing.expect(s.focus_mark.? != held);
    try testing.expectEqual(s.last_jump.?.key, s.focus_mark.?);
}

test "]a walks what :filter lets the panel show, and the rows are those" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 600, 200, 612) }}, Library.parseColor("green").?);
    s.highlightBoxes(0, &.{.{ .page = 1, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    try commentOn(marks, gpa, 0, "#question one");
    try commentOn(marks, gpa, 2, "a #question too");

    try testing.expect(s.exec("filter #question"));
    try testing.expectEqualStrings("2 of 3 marks match", s.status);
    try testing.expectEqual(@as(usize, 2), s.panelRows(.annotations).len);

    // Over the green one, which the panel does not show.
    _ = s.apply(.{ .jump_mark = .{ .forwards = true } });
    try testing.expectEqual(marks.items()[0].key, s.last_jump.?.key);
    _ = s.apply(.{ .jump_mark = .{ .forwards = true } });
    try testing.expectEqual(marks.items()[2].key, s.last_jump.?.key);
    try testing.expect(std.mem.indexOf(u8, s.status, "that match") != null);

    // A colour by its swatch's name; then nothing, which is everything.
    try testing.expect(s.exec("filter green"));
    try testing.expectEqual(@as(usize, 1), s.panelRows(.annotations).len);
    try testing.expect(s.exec("filter"));
    try testing.expectEqual(@as(usize, 3), s.panelRows(.annotations).len);
}

// The author asked for edit mode to walk the filter as `]a` does. `n` and `N`
// stepping every mark while the panel shows a few is what this pins.
test "edit mode's i, n, N and d walk what the filter lets through" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    // A question, a plain one, and another question, down the page.
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 600, 200, 612) }}, s.accent);
    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 500, 200, 512) }}, s.accent);
    const marks = &s.buffer(0).marks;
    try commentOn(marks, gpa, 0, "#question one");
    try commentOn(marks, gpa, 2, "#question two");
    const one = marks.items()[0].key;
    const plain = marks.items()[1].key;
    const two = marks.items()[2].key;
    try testing.expect(s.exec("filter #question"));

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqual(one, s.focus_mark.?);
    try testing.expectEqualStrings("-- EDIT -- 1/2", s.statusLine().mode);

    // Over the plain one, both ways.
    _ = s.apply(.next_mark);
    try testing.expectEqual(two, s.focus_mark.?);
    try testing.expectEqualStrings("-- EDIT -- 2/2", s.statusLine().mode);
    _ = s.apply(.previous_mark);
    try testing.expectEqual(one, s.focus_mark.?);

    // A click can still take hold of the plain one, which is then counted
    // among them all.
    s.focus_mark = plain;
    try testing.expectEqualStrings("-- EDIT -- 2/3", s.statusLine().mode);

    // `d` goes on to the next question, and after the last stops, leaving
    // the plain one where it was.
    s.focus_mark = one;
    _ = s.apply(.delete_mark);
    try testing.expectEqual(two, s.focus_mark.?);
    _ = s.apply(.delete_mark);
    try testing.expect(s.focus_mark == null);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expectEqual(@as(usize, 1), marks.count());
    try testing.expectEqual(plain, marks.items()[0].key);

    // And `i` with nothing to match does not take hold of what is left.
    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
    try testing.expect(std.mem.startsWith(u8, s.status, "nothing matches"));
}

test "backspace in a note removes a character, not a byte" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    s.noteChar('a');
    s.noteChar(0xe9); // two bytes in UTF-8
    s.noteBackspace();
    try testing.expectEqualStrings("a", s.note.items);
}

test "the status line carries the mode and what the mode has to show" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expectEqualStrings("", s.statusLine().mode);

    s.keymap.mode = .visual;
    try testing.expectEqualStrings("-- VISUAL --", s.statusLine().mode);

    s.highlightBoxes(0, &.{.{ .page = 0, .box = .fromRect(100, 700, 200, 712) }}, s.accent);
    s.keymap.mode = .note;
    s.focus_mark = s.buffer(0).marks.items()[0].key;
    for ("hello") |c| s.noteChar(c);

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

test "the cursor's line can be highlighted and cleared again" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{
        .code = 'a',
        .offset = .{ .x = 10 * @as(f32, @floatFromInt(i)), .y = 0 },
    };
    var cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700),
        .glyphs = .{ .start = 0, .count = 3 },
    } };
    const map = try text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    s.buffer(0).putMap(gpa, 0, map);

    s.view().cursorToPage(0, s.buffer(0).textMap(0).?, false);
    s.toggleMark();
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());

    // Again on the same line: the cursor is inside the mark it just made, so
    // this takes it away rather than stacking a second one on top.
    s.toggleMark();
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "showing another document in a window keeps the place in the first" {
    const gpa = testing.allocator;
    var buf: [20]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    try s.buffers.append(gpa, .{
        .path = try gpa.dupe(u8, "/docs/b.pdf"),
        .title = "b.pdf",
        .pages = fakePages(buf[10..], 6),
    });

    s.view().scrollToPage(5);
    const was = s.view().scroll;

    s.showBuffer(1);
    try testing.expectEqual(@as(u32, 1), s.view().buffer);
    try testing.expectEqual(@as(usize, 6), s.view().pages.len);
    try testing.expectApproxEqAbs(@as(f32, 0), s.view().scroll, 0.001);

    // And back, which without a library does not restore the place -- so the
    // test asserts what it can: the pages are the first document's again.
    s.showBuffer(-1);
    try testing.expectEqual(@as(u32, 0), s.view().buffer);
    try testing.expectEqual(@as(usize, 10), s.view().pages.len);
    try testing.expect(was > 0);
}

test "a tabpage keeps its own windows, and gt goes between them" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    s.view().scroll = 300;
    _ = s.apply(.{ .split = .vertical });
    _ = s.apply(.new_tab);

    try testing.expectEqual(@as(u32, 2), s.tabs.count());
    // The new tabpage is one window on the same document, where that window
    // was: a tab is an arrangement, not a second file.
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    try testing.expectEqual(@as(u32, 0), s.view().buffer);
    try testing.expectApproxEqAbs(@as(f32, 300), s.view().scroll, 0.001);

    s.view().scroll = 0;
    _ = s.apply(.{ .go_tab = 1 });
    try testing.expectEqual(@as(u32, 2), s.layout().count());
    try testing.expectApproxEqAbs(@as(f32, 300), s.view().scroll, 0.001);
}

test "the last window of a tabpage closes the tabpage, not the reader" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.new_tab);
    try testing.expectEqual(@as(u32, 2), s.tabs.count());

    // `q` in a tab of one window: the tab goes and the reader stays.
    try testing.expect(!s.apply(.quit));
    try testing.expectEqual(@as(u32, 1), s.tabs.count());

    // And on the last window of the last tabpage it is a quit again.
    try testing.expect(s.apply(.quit));
}

test "a window moved to its own tabpage is one window in each" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    // Nothing to move: one window is a tabpage already, and the reader says
    // so rather than making an identical tab beside it.
    _ = s.apply(.window_to_tab);
    try testing.expectEqual(@as(u32, 1), s.tabs.count());

    _ = s.apply(.{ .split = .horizontal });
    _ = s.apply(.window_to_tab);
    try testing.expectEqual(@as(u32, 2), s.tabs.count());
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    _ = s.apply(.{ .go_tab = -1 });
    try testing.expectEqual(@as(u32, 1), s.layout().count());
    // The window left behind took the whole rectangle back.
    try testing.expectApproxEqAbs(@as(f32, 800), s.view().rect.height(), 0.001);
}

test "the tab commands on the : line reach the same places the keys do" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    try testing.expect(s.exec("tabnew"));
    try testing.expect(s.exec("tabnew"));
    try testing.expectEqual(@as(u32, 3), s.tabs.count());

    try testing.expect(s.exec("tabnext 1"));
    try testing.expectEqual(@as(u32, 0), s.tabs.active);
    try testing.expect(!s.exec("tabnext 9"));
    try testing.expectEqual(@as(u32, 0), s.tabs.active);
    try testing.expect(s.exec("tabprevious"));
    try testing.expectEqual(@as(u32, 2), s.tabs.active);

    try testing.expect(s.exec("tabonly"));
    try testing.expectEqual(@as(u32, 1), s.tabs.count());
    // And the only tabpage will not close: leaving is `:q`'s job.
    try testing.expect(!s.exec("tabclose"));
}

test "a tab is named for its document, and says how many windows are in it" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.new_tab);
    _ = s.apply(.{ .split = .vertical });
    _ = s.apply(.{ .split = .horizontal });

    const names = s.tabLabels();
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a.pdf", names[0]);
    try testing.expectEqualStrings("a.pdf (3)", names[1]);

    // Nothing the bar would draw has changed, so nothing is rebuilt: the
    // slices are the same bytes, not equal copies of them.
    const again = s.tabLabels();
    try testing.expectEqual(names.ptr, again.ptr);
    try testing.expectEqual(names[1].ptr, again[1].ptr);

    // A window closed is a different bar, and the name follows it.
    _ = s.apply(.close_window);
    try testing.expectEqualStrings("a.pdf (2)", s.tabLabels()[1]);
}

test "the bar takes a row off the pages, and only once there are two tabs" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    // One tabpage: a bar showing one tab would say what the title bar says,
    // so there is no bar and the page keeps the row.
    try testing.expectEqual(@as(f32, 0), s.tabInset());
    _ = s.apply(.new_tab);
    try testing.expectEqual(chrome_mod.tab_height, s.tabInset());
    _ = s.apply(.close_tab);
    try testing.expectEqual(@as(f32, 0), s.tabInset());

    // And with no interface at all -- a test, and `--shot --path cpu` --
    // the windows get the whole thing however many tabpages there are.
    _ = s.apply(.new_tab);
    try testing.expectEqual(@as(f32, 0), s.windowRect(1000, 800).min_y);
}

test "a job only equals a job for the same page of the same document at the same zoom" {
    const a: Job = .{ .buffer = 0, .page = 3, .zoom = 1.5 };
    try testing.expect(a.eql(.{ .buffer = 0, .page = 3, .zoom = 1.5 }));
    try testing.expect(!a.eql(.{ .buffer = 1, .page = 3, .zoom = 1.5 }));
    try testing.expect(!a.eql(.{ .buffer = 0, .page = 4, .zoom = 1.5 }));
    try testing.expect(!a.eql(.{ .buffer = 0, .page = 3, .zoom = 1.25 }));
}

test "a page that will not rasterise is asked for once, not every frame" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 0.5, 1000, 800);
    defer closeSession(&s);

    try testing.expectEqual(@as(u32, 0), s.firstMissing().?.page);
    s.noteFailure(.{ .buffer = 0, .page = 0, .zoom = s.view().zoom });
    try testing.expectEqual(@as(u32, 1), s.firstMissing().?.page);

    // The failure is remembered per zoom, because a page that ran out of
    // memory at one scale may well fit at another.
    s.view().zoom = 0.25;
    try testing.expectEqual(@as(u32, 0), s.firstMissing().?.page);
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

test "highlights come back out of the library the next time it is opened" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;

    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    s.ctx = undefined;

    // Written through the session, so the row and the in-memory mark are
    // made by the same call a keypress would make.
    _ = try lib.addMark(s.buffer(0).path, .{
        .page = 2,
        .x0 = 100,
        .y0 = 700,
        .x1 = 300,
        .y1 = 712,
        .color = @constCast("#ff0000"),
    }, 1);

    var reopened = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&reopened);
    reopened.library = lib;
    reopened.loadMarks(0);

    try testing.expectEqual(@as(usize, 1), reopened.buffer(0).marks.count());
    const mark = reopened.buffer(0).marks.items()[0];
    try testing.expectEqual(@as(u32, 2), mark.page);
    try testing.expectApproxEqAbs(@as(f32, 1), mark.color.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), mark.color.g, 0.01);
    // Loading is not an edit, so closing again writes nothing back.
    try testing.expect(!reopened.buffer(0).marks.dirty);
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

test "a press in text moves the caret there and a drag carries it along" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    const v = s.view();
    try testing.expect(!v.cursor.visible);

    // The window point of the second glyph of the second line.
    const map = s.buffer(0).textMap(0).?;
    const target = map.lines[1].glyphs(map)[1];
    const at = v.windowPoint(0, .{ .x = target.middle(), .y = target.base }) orelse
        return error.SkipZigTest;

    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    try testing.expect(v.cursor.visible);
    try testing.expectEqual(@as(u32, 1), v.cursor.line);
    try testing.expectEqual(@as(u32, 1), v.cursor.column);
    try testing.expect(s.drag != null);

    // The drag carries the caret with it rather than leaving it where the
    // press was: releasing and pressing `v` has to extend from the end.
    const later = map.lines[2].glyphs(map)[3];
    const to = v.windowPoint(0, .{ .x = later.middle(), .y = later.base }) orelse
        return error.SkipZigTest;
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(u32, 2), v.cursor.line);
    try testing.expectEqual(@as(u32, 3), v.cursor.column);
}

test "letting go of a drag leaves a selection, not a highlight" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    const v = s.view();
    const map = s.buffer(0).textMap(0).?;
    const first = map.lines[1].glyphs(map)[0];
    const last = map.lines[2].glyphs(map)[2];
    const at = v.windowPoint(0, .{ .x = first.middle(), .y = first.base }) orelse
        return error.SkipZigTest;
    const to = v.windowPoint(0, .{ .x = last.middle(), .y = last.base }) orelse
        return error.SkipZigTest;

    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{} });

    // The words stay selected and nothing was written to the document: a
    // selection belongs to the interface, a highlight to the reader.
    try testing.expect(s.drag != null);
    try testing.expect(!s.drag.?.held);
    try testing.expect(s.activeSelection(v) != null);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());

    // A press puts the selection away, the way a click in a browser does,
    // and a press that goes nowhere is a click and selects nothing.
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    try testing.expect(std.meta.eql(s.drag.?.from, s.drag.?.to));
    s.pointer(.{ .mouse = at, .buttons = .{} });
    try testing.expect(s.drag == null);

    // `y` puts it away and writes nothing either. It used to highlight, and
    // the author had that taken out along with the highlight on letting go.
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{} });
    _ = s.apply(.yank_selection);
    try testing.expect(s.drag == null);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());

    // `m` is what makes a highlight of it, and puts the selection away.
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{} });
    _ = s.apply(.toggle_highlight);
    try testing.expect(s.drag == null);
    try testing.expect(s.buffer(0).marks.count() > 0);
}

test "dragging the line between two windows resizes both of them" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    s.splitWindow(.vertical);
    const left = s.layout().viewAt(0);
    const line = left.rect.max_x;

    // A press on the line, then a drag well to the left of it.
    s.pointer(.{ .mouse = .{ .x = line + 1, .y = 400 }, .buttons = .{ .left = true } });
    try testing.expect(s.split_drag != null);
    s.pointer(.{ .mouse = .{ .x = 300, .y = 400 }, .buttons = .{ .left = true } });
    try testing.expectApproxEqAbs(@as(f32, 300), left.rect.max_x, 1e-3);

    // Letting go ends it, and the gesture never became a text selection.
    s.pointer(.{ .mouse = .{ .x = 300, .y = 400 } });
    try testing.expect(s.split_drag == null);
    try testing.expect(s.drag == null);

    // A press away from the line is not a drag on it, and the next press
    // after a divider drag still registers.
    s.pointer(.{ .mouse = .{ .x = 150, .y = 400 }, .buttons = .{ .left = true } });
    try testing.expect(s.split_drag == null);
    try testing.expectApproxEqAbs(@as(f32, 300), left.rect.max_x, 1e-3);
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

    s.changeSetting(.{ .key = "theme", .value = "light" });
    try testing.expectEqualStrings("light", s.theme.name);

    // A colour is parsed where it is typed, so a row nobody could read is
    // refused rather than found wrong on the next start.
    s.changeSetting(.{ .key = "accent", .value = "not a colour" });
    try testing.expect(s.chosen_accent == null);

    s.changeSetting(.{ .key = "accent", .value = "orange" });
    try testing.expect(s.chosen_accent != null);
    try testing.expectEqual(s.chosen_accent.?, s.accent);
    try testing.expectEqual(s.chosen_accent.?, s.highlight);
}

test "comment_anchor = arrow makes c point at the words, kept and read back" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);
    try putText(&s, 0, 3, 4);

    // Refused by name, so a misspelling is not a highlight by default.
    try testing.expect(!s.exec("set comment_anchor=arow"));
    try testing.expect(s.exec("set comment_anchor=arrow"));
    try testing.expectEqual(Marks.Style.arrow, s.comment_style);

    s.keymap.mode = .visual;
    _ = s.apply(.enter_visual);
    _ = s.apply(.{ .move_cursor = .down });
    s.keymap.mode = .note;
    _ = s.apply(.comment_selection);
    for ("see") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    s.applyEffects();
    for (s.buffer(0).marks.items()) |m| try testing.expectEqual(Marks.Style.arrow, m.style);
    {
        const rows = try lib.marks("/docs/a.pdf");
        defer lib.freeMarks(rows, rows.len);
        try testing.expectEqualStrings("arrow", rows[0].style);
    }

    // The next reader opens with it.
    var again = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&again);
    try giveLibrary(&again, lib);
    try testing.expectEqual(Marks.Style.arrow, again.rememberedCommentStyle());
}

test "an arrow sits in the margin, its tip short of the words" {
    const gpa = testing.allocator;
    const line: Bounds = .fromRect(100, 200, 400, 220);
    var d: DrawList = .init(gpa, .fromRect(0, 0, 1000, 1000));
    defer d.deinit();
    // A mark begun mid-line, on a line whose words begin at 60.
    try Session.arrow(&d, line, 60, .{ .r = 1, .g = 0.9, .b = 0.2, .a = 1 });

    var ink: Bounds = .empty;
    for (d.instances.items) |i| ink = ink.add(.{ .x = i.dst[0], .y = i.dst[1] }).add(.{ .x = i.dst[2], .y = i.dst[3] });
    // Nothing on the text, the line's earlier words included, and nothing
    // taller than the line it points at.
    try testing.expect(ink.max_x <= 60);
    try testing.expect(ink.min_y >= line.min_y and ink.max_y <= line.max_y);
    // A shaft and ten slices of head, for a line twenty tall.
    try testing.expectEqual(@as(usize, 11), d.instances.items.len);
}

test "with no library every setting is unset, and saying so is not a crash" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    s.readSettings();
    for (settings_page.builtin, 0..) |_, i| {
        try testing.expectEqual(@as(usize, 0), s.settings.valueOf(i).len);
    }
    // The theme still changes; there is simply nowhere to keep it.
    s.changeSetting(.{ .key = "theme", .value = "light" });
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

    s.fillRailButtons();
    try testing.expectEqual(@as(usize, 1), s.rail_panels.items.len);
    const id = s.rail_panels.items[0].id;
    try testing.expectEqualStrings("Reading list", s.rail_panels.items[0].label);
    try testing.expectEqualStrings("fenrir.bookmark", s.rail_panels.items[0].icon);

    const which: rails_mod.Panel = .{ .plugin = id };
    const rows = s.panelRows(which);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Chapter two", rows[1].label);
    try testing.expectEqualStrings("kept", rows[1].detail);
    try testing.expectEqual(@as(u32, 6), rows[1].page);
    try testing.expectEqualStrings("Reading list", s.declaredPanel(which).?.title);
    try testing.expect(s.declaredPanel(.annotations) == null);

    // Cached until the plugin says otherwise, and rebuilt when it does.
    try testing.expect(rt.runString("more", "titles[3] = 'Chapter three'"));
    try testing.expectEqual(@as(usize, 2), s.panelRows(which).len);
    try testing.expect(rt.runString("refresh", "fenrir.refresh()"));
    try testing.expectEqual(@as(usize, 3), s.panelRows(which).len);
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
    s.readSettings();
    try testing.expectEqual(settings_page.builtin.len + 1, s.settings.count());
    const at = settings_page.builtin.len;
    try testing.expectEqualStrings("reading.list", s.settings.optionAt(at).key);
    try testing.expect(s.settings.isPlugin(at));
    // Which is where `fenrir.store` already keeps it: one key, not two.
    var key_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("galdr.reading.list", s.settingKey(&key_buf, at).?);
    try testing.expectEqualStrings("theme", s.settingKey(&key_buf, 0).?);

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

    s.showPalette();
    s.runChosen(.{ .row = .{ .name = "split" } });
    try testing.expectEqual(@as(usize, 2), s.layout().count());

    // And a line nothing matched goes down the same path a typed one does.
    s.runChosen(.{ .line = "page 3" });
    try testing.expectEqual(@as(u32, 2), s.view().currentPage());
}

test "a command that needs an argument lands on the : line, not in the void" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    s.showPalette();
    const entry = commands.get(.page);
    try testing.expect(entry.needs_argument);
    s.runChosen(.{ .row = .{ .name = entry.name, .needs_argument = true } });

    try testing.expectEqual(keys.Mode.command, s.keymap.mode);
    try testing.expectEqualStrings("page ", s.cmdline.items);
}

/// One page of `words`, one run a word, at the top of the page. The same
/// shape `search.zig`'s own fixture uses, because a word gap only reaches
/// the text map as a gap between runs.
fn putWords(s: *Session, page: u32, words: []const []const u8) !void {
    const gpa = s.gpa;
    var glyphs: std.ArrayList(gelgja.DisplayList.Glyph) = .empty;
    defer glyphs.deinit(gpa);
    var cmds: std.ArrayList(gelgja.DisplayList.DrawCmd) = .empty;
    defer cmds.deinit(gpa);

    var x: f32 = 100;
    for (words) |word| {
        const start: u32 = @intCast(glyphs.items.len);
        for (word, 0..) |c, i| try glyphs.append(gpa, .{
            .code = c,
            .offset = .{ .x = 5 * @as(f32, @floatFromInt(i)), .y = 0 },
        });
        const advance = 5 * @as(f32, @floatFromInt(word.len));
        try cmds.append(gpa, .{ .text = .{
            .size = 10,
            .transform = .translation(x, 700),
            .glyphs = .{ .start = start, .count = @intCast(word.len) },
            .advance = advance,
        } });
        x += advance + 4;
    }
    s.buffer(0).putMap(gpa, page, try text.build(gpa, .{
        .glyphs = glyphs.items,
        .cmds = cmds.items,
    }));
}

/// Runs the scan to completion the way the frame loop would: the frontier
/// asks for a page, the worker builds its map, the search takes it.
fn scanAll(s: *Session, on: []const []const []const u8) !void {
    while (s.searchJob()) |job| {
        try putWords(s, job.page, on[job.page]);
        const map = s.buffer(job.buffer).textMap(job.page).?;
        try s.search.take(s.gpa, job.page, map);
    }
}

test "slash opens a search that is empty until something is typed" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.enter_search);
    try testing.expect(s.find.open);
    try testing.expect(s.find.typing);
    // An empty query asks for no pages at all: a scan of the whole document
    // for nothing is the worst thing `/` could do on its own.
    try testing.expect(s.searchJob() == null);
}

test "the scan walks every page from the one in front of the reader" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 1000, 800);
    defer closeSession(&s);

    s.view().scrollToPage(2);
    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("fox");
    s.applyFind(.typed);

    // Page 2 first, because that is the one being read.
    try testing.expectEqual(@as(u32, 2), s.searchJob().?.page);
    try scanAll(&s, &.{
        &.{ "the", "fox" },
        &.{"nothing"},
        &.{"nothing"},
        &.{ "a", "fox", "here" },
    });

    try testing.expect(s.search.done());
    try testing.expectEqual(@as(u32, 2), s.searchCount().found);
    // Page 3 comes before page 0, because a reader on page 2 meets it first.
    try testing.expectEqual(@as(u32, 3), s.search.hits.items[0].page);
    try testing.expectEqual(@as(u32, 0), s.search.hits.items[1].page);
}

test "n steps the matches while a search is live and turns the page when it is not" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 1000, 800);
    defer closeSession(&s);

    // No search: `n` is the next page, as it has always been.
    try testing.expectEqual(@as(u32, 0), s.view().currentPage());
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 1), s.view().currentPage());

    s.view().scrollToPage(0);
    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("fox");
    s.applyFind(.typed);
    try scanAll(&s, &.{
        &.{"nothing"},
        &.{ "a", "fox" },
        &.{"nothing"},
        &.{ "another", "fox" },
    });

    // Now it steps the matches, and the first `n` lands on the first rather
    // than stepping past it.
    //
    // The check is that the match is *on screen*, not that the window has
    // moved to the top of its page: `scrollToBox` moves as little as will
    // do, so a match near the top of the next page is brought into view
    // with the page before it still mostly showing -- which is the right
    // thing and makes `currentPage` the wrong question.
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 1), s.search.at().?.page);
    try testing.expectEqual(@as(u32, 1), s.searchCount().at.?);
    try testing.expect(onScreen(s.view(), 1));

    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 3), s.search.at().?.page);
    try testing.expectEqual(@as(u32, 2), s.searchCount().at.?);
    try testing.expect(onScreen(s.view(), 3));

    // And back round, which is what wrapping means.
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 1), s.search.at().?.page);
    try testing.expect(onScreen(s.view(), 1));
}

fn onScreen(v: *View, page: u32) bool {
    const range = v.visiblePages();
    return page >= range.first and page < range.end;
}

test "escape ends the search, takes the highlights with it, and gives n back" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("fox");
    s.applyFind(.typed);
    try scanAll(&s, &.{
        &.{ "a", "fox" },
        &.{"nothing"},
        &.{"nothing"},
        &.{"nothing"},
    });
    try testing.expectEqual(@as(u32, 1), s.searchCount().found);

    // The field no longer has the keyboard -- enter gave it back -- so this
    // is the escape the keymap sends, not the field's own.
    s.find.typing = false;
    _ = s.apply(.hide_cursor);
    try testing.expect(!s.find.open);
    try testing.expectEqual(@as(usize, 0), s.search.hits.items.len);

    // And `n` is the next page again.
    const was = s.view().currentPage();
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(was + 1, s.view().currentPage());
}

test "a query that matches nothing says so rather than saying nothing" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("aardvark");
    s.applyFind(.typed);
    try scanAll(&s, &.{ &.{"nothing"}, &.{"nothing"} });

    const count = s.searchCount();
    try testing.expectEqual(@as(u32, 0), count.found);
    try testing.expect(!count.scanning());
    try testing.expect(count.at == null);
    // Stepping a search with nothing in it moves nothing.
    const was = s.view().scroll;
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(was, s.view().scroll);
}

test "a drag in draw mode is a stroke, and it is a mark like any other" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    const b = s.buffer(0);

    // Down on the page, across it, and up.
    const from = v.windowPoint(0, .{ .x = 100, .y = 700 }).?;
    s.pointer(.{ .mouse = from, .buttons = .{ .left = true } });
    try testing.expect(s.pen.down);
    try testing.expectEqual(@as(usize, 0), b.marks.count());

    var x: f32 = 110;
    while (x <= 300) : (x += 10) {
        const at = v.windowPoint(0, .{ .x = x, .y = 700 }).?;
        s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    }
    // Nothing is written until the pen comes up: a stroke half drawn is not
    // a mark, it is a gesture.
    try testing.expectEqual(@as(usize, 0), b.marks.count());
    try testing.expect(s.stroking.items.len > 2);

    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 300, .y = 700 }).?, .buttons = .{} });
    try testing.expect(!s.pen.down);
    try testing.expectEqual(@as(usize, 1), b.marks.count());

    const mark = b.marks.items()[0];
    try testing.expectEqual(Marks.Kind.ink, mark.kind);
    // A straight drag is two points once it has been simplified, whatever it
    // was sampled as.
    try testing.expectEqual(@as(usize, 2), mark.points.len);
    try testing.expectApproxEqAbs(@as(f32, 100), mark.points[0].x, 1);
    try testing.expectApproxEqAbs(@as(f32, 300), mark.points[1].x, 1);
    try testing.expectApproxEqAbs(s.pen.width, mark.width, 0.001);

    // And it undoes with `u`, through the one history, like a highlight.
    try testing.expect(b.marks.canUndo());
    s.undoMarks(false);
    try testing.expectEqual(@as(usize, 0), b.marks.count());
}

test "a comment typed on a stroke is written to the library and comes back" {
    // A stroke is focusable, so `note` mode accepts a comment on one -- and
    // the ink arm of the writer was once `updateStroke(id, colour)`, with no
    // column behind it, so what was typed lived for the session and was gone
    // at the next open. A stroke is an anchor like any mark, and its comment
    // is a row like any other; do not let ink fall out of that again.
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;

    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try giveLibrary(&s, lib);

    // Drawn with the pen, so the mark and its row are made by the calls a
    // drag makes.
    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 100, .y = 700 }).?, .buttons = .{ .left = true } });
    var x: f32 = 110;
    while (x <= 300) : (x += 10) {
        s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = x, .y = 700 }).?, .buttons = .{ .left = true } });
    }
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 300, .y = 700 }).?, .buttons = .{} });
    s.applyEffects();
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());

    s.keymap.mode = .edit;
    _ = s.apply(.enter_edit);
    try testing.expect(s.focusedMarkIndex() != null);
    s.keymap.mode = .note;
    _ = s.apply(.enter_note);
    for ("the margin") |c| _ = s.apply(.{ .note_char = c });
    s.keymap.mode = .edit;
    _ = s.apply(.note_commit);
    s.applyEffects();

    {
        const rows = try lib.strokes(s.buffer(0).path);
        defer lib.freeStrokes(rows, rows.len);
        try testing.expectEqual(@as(usize, 1), rows.len);
        const said = try lib.comments(s.buffer(0).path);
        defer lib.freeComments(said, said.len);
        try testing.expectEqual(@as(usize, 1), said.len);
        try testing.expectEqualStrings(rows[0].anchor, said[0].anchor);
        try testing.expectEqualStrings("the margin", said[0].text);
    }

    // And the next open has it.
    var reopened = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&reopened);
    reopened.library = lib;
    reopened.loadMarks(0);

    const marks = reopened.buffer(0).marks.items();
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqual(Marks.Kind.ink, marks[0].kind);
    try testing.expectEqualStrings("the margin", Session.firstComment(reopened.buffer(0), marks[0]));
}

test "a press in draw mode that goes nowhere leaves nothing behind" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const at = s.view().windowPoint(0, .{ .x = 100, .y = 700 }).?;
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = at, .buttons = .{} });
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "a stroke keeps to the page it began on, however far the drag goes" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    const on_page = v.windowPoint(0, .{ .x = 100, .y = 40 }).?;
    s.pointer(.{ .mouse = on_page, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(u32, 0), s.pen.page);

    // Down past the bottom of page one, into the gap and towards page two.
    // The stroke is still page one's, with points below its edge.
    const below: Point = .{ .x = on_page.x, .y = v.pageRect(0).max_y + 30 };
    s.pointer(.{ .mouse = below, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = below, .buttons = .{} });

    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());
    const mark = s.buffer(0).marks.items()[0];
    try testing.expectEqual(@as(u32, 0), mark.page);
    try testing.expect(mark.points[mark.points.len - 1].y < 0);
}

test "leaving draw mode with the pen down throws the stroke away" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    const v = s.view();
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 100, .y = 700 }).?, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = v.windowPoint(0, .{ .x = 300, .y = 700 }).?, .buttons = .{ .left = true } });

    _ = s.apply(keys.enter(&s.keymap, .normal));
    try testing.expect(!s.pen.down);
    try testing.expectEqual(@as(usize, 0), s.stroking.items.len);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "the pen takes the palette colours and a width that compounds" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(keys.enter(&s.keymap, .draw));
    // The digit picks the same swatch it would pick in any other mode.
    _ = s.apply(keys.paletteCommand(.draw, 2).?);
    try testing.expectEqual(s.paletteColor(2), s.penColor());

    const started = s.pen.width;
    _ = s.apply(.{ .pen_width = 1.4 });
    try testing.expect(s.pen.width > started);
    _ = s.apply(.{ .pen_width = 1.0 / 1.4 });
    try testing.expectApproxEqAbs(started, s.pen.width, 0.0001);

    // And it is clamped: a pen thinner than a hair or wider than a page is
    // not a pen.
    for (0..40) |_| _ = s.apply(.{ .pen_width = 1.4 });
    try testing.expectApproxEqAbs(max_pen_width, s.pen.width, 0.001);
    for (0..80) |_| _ = s.apply(.{ .pen_width = 1.0 / 1.4 });
    try testing.expectApproxEqAbs(min_pen_width, s.pen.width, 0.001);
}

test "a click erases a stroke it is on, and not one it is merely inside" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    // Two sides of a box, drawn with the pen.
    const drawn = [_]Point{
        .{ .x = 100, .y = 400 },
        .{ .x = 300, .y = 400 },
        .{ .x = 300, .y = 600 },
    };
    _ = try s.buffer(0).marks.add(gpa, .{
        .kind = .ink,
        .page = 0,
        .points = &drawn,
        .width = 2,
    }, false);

    const v = s.view();
    // In normal mode a press on a mark takes it away -- the eraser on the end
    // of the highlighter, which ink gets for nothing by being a mark. A press
    // in the middle of the box is not on the line and takes nothing.
    const inside = v.windowPoint(0, .{ .x = 200, .y = 500 }).?;
    s.pointer(.{ .mouse = inside, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = inside, .buttons = .{} });
    try testing.expectEqual(@as(usize, 1), s.buffer(0).marks.count());

    const on_line = v.windowPoint(0, .{ .x = 200, .y = 400 }).?;
    s.pointer(.{ .mouse = on_line, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());
}

test "ink is drawn over the page, and only on the pages a window can see" {
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    const drawn = [_]Point{ .{ .x = 100, .y = 700 }, .{ .x = 300, .y = 700 } };
    const b = s.buffer(0);
    _ = try b.marks.add(gpa, .{ .kind = .ink, .page = 0, .points = &drawn, .width = 2 }, true);
    // The same stroke far down the document, which should cost nothing.
    _ = try b.marks.add(gpa, .{ .kind = .ink, .page = 8, .points = &drawn, .width = 2 }, true);

    var over: DrawList = .init(gpa, .fromRect(0, 0, 1000, 800));
    defer over.deinit();
    const v = s.view();
    try s.drawInk(v, b, v.visiblePages(), &over);
    try testing.expect(over.count() > 0);

    // With nothing in range, nothing is drawn at all: an off-screen stroke
    // costs one compare, not a walk of its points.
    over.reset(.fromRect(0, 0, 1000, 800));
    try s.drawInk(v, b, .{ .first = 0, .end = 0 }, &over);
    try testing.expectEqual(@as(u32, 0), over.count());
}

// -- watching -----------------------------------------------------------------

/// A document of `n` Letter-sized pages with nothing on them, on the heap
/// as a buffer holds one.
fn blankDocument(gpa: Allocator, n: usize) !*fenrir.Document {
    var src: Io.Writer.Allocating = .init(gpa);
    errdefer src.deinit();
    try src.writer.writeAll("%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [");
    for (0..n) |i| try src.writer.print("{d} 0 R ", .{i + 3});
    try src.writer.print("] /Count {d} >> endobj\n", .{n});
    for (0..n) |i| try src.writer.print("{d} 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] >> endobj\n", .{i + 3});
    try src.writer.writeAll("trailer << /Root 1 0 R >>\nstartxref 0\n%%EOF\n");

    const doc = try gpa.create(fenrir.Document);
    errdefer gpa.destroy(doc);
    doc.* = try fenrir.open(gpa, try src.toOwnedSlice());
    return doc;
}

/// A session on a real document of `n` pages, with its disk beside it: what
/// a reload is installed into. There is no worker; `install` is handed what
/// `watch.load` would have made.
fn watchedSession(gpa: Allocator, n: usize) !Session {
    const doc = try blankDocument(gpa, n);
    errdefer {
        doc.deinit();
        gpa.destroy(doc);
    }
    var s = try sessionOf(gpa, @constCast(try fenrir.pages.all(doc)), 1, 600, 900);
    s.buffers.items[0].doc = doc;
    try s.disks.append(gpa, .{});
    return s;
}

fn closeWatched(s: *Session) void {
    const doc = s.buffers.items[0].doc;
    doc.deinit();
    s.gpa.destroy(doc);
    closeSession(s);
}

/// What `watch.load` hands back for a file of `n` blank pages that changed
/// at `first`, `down` points below its top.
fn reloadOf(gpa: Allocator, n: usize, first: ?u32, down: f32) !watch.Outcome {
    const doc = try blankDocument(gpa, n);
    const digests = try gpa.alloc(u64, n);
    @memset(digests, 0);
    return .{ .loaded = .{
        .doc = doc,
        .pages = try fenrir.pages.all(doc),
        .outline = &.{},
        .digests = digests,
        .stamp = .{ .size = 1, .mtime = 1 },
        .first = first,
        .down = down,
    } };
}

test "a reload leaves its buffer's pages stale, drawn until they come again" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    s.slots[0] = .{ .buffer = 0, .page = 0, .zoom = 1, .gpu = 1 };
    s.slots[1] = .{ .buffer = 0, .page = 2, .zoom = 1, .gpu = 2 };
    // Another document's page, which a reload of this one leaves alone.
    s.slots[2] = .{ .buffer = 1, .page = 0, .zoom = 1, .gpu = 3 };

    s.install(0, try reloadOf(gpa, 2, null, 0));
    try testing.expect(s.slots[0].stale);
    // Past the new end.
    try testing.expectEqual(Slot.no_page, s.slots[1].page);
    try testing.expect(!s.slots[2].stale);

    // Still drawn, and asked for again.
    const v = s.view();
    try testing.expect(s.slotFor(0, 0, 1, false) != null);
    try testing.expect(!s.cached(v, 0));
    try testing.expectEqual(@as(usize, 2), v.pages.len);
    try testing.expectEqual(@as(u32, 2), s.disks.items[0].generation);
    try testing.expect(s.disks.items[0].held.eql(.{ .size = 1, .mtime = 1 }));
    try testing.expectEqualStrings("gen 2: no page changed, 2 pages", s.status);
}

test "a reload goes to the change, unless the change is already on screen" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    const v = s.view();
    v.scroll = 0;

    // A hundred points down the third page, which is below the window: it
    // lands a quarter of the way down, as `]d` puts a change.
    s.install(0, try reloadOf(gpa, 3, 2, 100));
    const at = v.pageTop(2) + 100 * v.zoom;
    try testing.expectApproxEqAbs(v.height() * compare.lead_in, at - v.scroll, 1);
    try testing.expectEqualStrings("gen 2: page 3 changed", s.status);

    // On screen now, so a second change there moves nothing.
    const kept = v.scroll;
    s.install(0, try reloadOf(gpa, 3, 2, 150));
    try testing.expectEqual(kept, v.scroll);
    // Nor does a reload that changed nothing.
    s.install(0, try reloadOf(gpa, 3, null, 0));
    try testing.expectEqual(kept, v.scroll);
}

/// What `watch.load` hands back when the pages' digests are `digests`, for
/// a held document whose own are set to compare them with.
fn reloadDigests(gpa: Allocator, digests: []const u64, first: ?u32) !watch.Outcome {
    const outcome = try reloadOf(gpa, digests.len, first, 0);
    @memcpy(outcome.loaded.digests, digests);
    return outcome;
}

test "a reload keeps the caret where the page did not change, and finds it where it did" {
    // The author asked for this: a reload first sent every caret to the top
    // of its page, wherever the change was.
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    const v = s.view();

    // On the third line of the first page, which will not change.
    s.disks.items[0].digests = try gpa.dupe(u64, &.{ 1, 2, 3 });
    try putText(&s, 0, 4, 6);
    v.cursorTo(.{ .page = 0, .line = 2, .column = 3 }, s.buffer(0).textMap(0).?);
    const caret = v.cursor.caret;
    s.install(0, try reloadDigests(gpa, &.{ 1, 9, 3 }, 1));
    try testing.expectEqual(View.Position{ .page = 0, .line = 2, .column = 3 }, v.cursor.position());
    try testing.expect(!v.cursor.stale);
    try testing.expectEqual(caret, v.cursor.caret);

    // On the second page, which will: kept by its place until the page's
    // text comes, then put on the glyph there.
    try putText(&s, 1, 4, 6);
    v.cursorTo(.{ .page = 1, .line = 3, .column = 1 }, s.buffer(0).textMap(1).?);
    s.install(0, try reloadDigests(gpa, &.{ 1, 8, 3 }, 1));
    try testing.expect(v.cursor.stale);
    try testing.expectEqual(@as(u32, 1), v.cursor.page);
    try putText(&s, 1, 4, 6);
    s.placeStale(0, 1);
    try testing.expect(!v.cursor.stale);
    try testing.expectEqual(View.Position{ .page = 1, .line = 3, .column = 1 }, v.cursor.position());

    // A page taken off the end takes the caret to the top of the last.
    s.install(0, try reloadDigests(gpa, &.{ 1, 8 }, 1));
    try testing.expectEqual(View.Position{ .page = 1, .line = 3, .column = 1 }, v.cursor.position());
    v.cursor.page = 2;
    s.install(0, try reloadDigests(gpa, &.{1}, 0));
    try testing.expectEqual(View.Position{ .page = 0, .line = 0, .column = 0 }, v.cursor.position());
}

test "a selection is kept through a reload only where neither end's page changed" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    const v = s.view();
    s.disks.items[0].digests = try gpa.dupe(u64, &.{ 1, 2, 3 });
    try putText(&s, 0, 4, 6);

    s.keymap.mode = .visual;
    v.cursorTo(.{ .page = 0, .line = 0, .column = 0 }, s.buffer(0).textMap(0).?);
    v.beginSelection();
    v.cursorTo(.{ .page = 0, .line = 1, .column = 4 }, s.buffer(0).textMap(0).?);

    s.install(0, try reloadDigests(gpa, &.{ 1, 7, 3 }, 1));
    try testing.expect(v.selection() != null);
    try testing.expectEqual(keys.Mode.visual, s.keymap.mode);

    s.install(0, try reloadDigests(gpa, &.{ 6, 7, 3 }, 0));
    try testing.expect(v.selection() == null);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
}

test "a file caught halfway is not shown, and is not tried again" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 2);
    defer closeWatched(&s);
    s.disks.items[0].reload = .auto;
    s.install(0, .{ .refused = .{ .stamp = .{ .size = 7 }, .why = error.Incomplete } });
    try testing.expectEqualStrings("a.pdf is incomplete; showing gen 1", s.status);
    try testing.expect(s.disks.items[0].refused.eql(.{ .size = 7 }));
    try testing.expectEqual(watch.Disk.Reload.none, s.disks.items[0].reload);
    try testing.expectEqual(@as(usize, 2), s.view().pages.len);
}

test "while a reload is pending, nothing else is asked of the worker" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 600, 900);
    defer closeSession(&s);
    try s.disks.append(gpa, .{});

    // Pages are missing, and would be asked for.
    try testing.expectEqual(Job.Want.page, s.jobToPost().?.want);
    s.disks.items[0].reload = .auto;
    try testing.expectEqual(Job.Want.reload, s.jobToPost().?.want);
}

test ":reload reads the document again, and :set watch follows the file or holds it" {
    const gpa = testing.allocator;
    var buf: [2]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 600, 900);
    defer closeSession(&s);
    try s.disks.append(gpa, .{});

    try testing.expect(s.exec("e!"));
    try testing.expectEqual(watch.Disk.Reload.forced, s.disks.items[0].reload);

    // Off unless asked for.
    try testing.expect(!s.watching);
    try testing.expect(s.exec("set watch=on"));
    try testing.expect(s.watching);
    try testing.expect(!s.exec("set watch=maybe"));
    try testing.expect(s.watching);
    try testing.expect(s.exec("set watch=off"));
    try testing.expect(!s.watching);
}
