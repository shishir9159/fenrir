//! `fenrir read <file>...` -- the documents, in windows, scrollable.
//!
//! This is the command the rest of the project was for. Gjöll reads the file,
//! the interpreter turns each page into a display list, `gleipnir.replay`
//! rasterises or records it, Lyngvi opens a window and puts it on the screen,
//! and the loop in `read/frame.zig` joins them.
//!
//! ## Buffers and windows
//!
//! The reader does not show *a document*. It holds a list of open documents
//! -- buffers -- and a tree of windows onto them, which is `hlidskjalf`. One
//! document can be in four windows at once; each has its own scroll, zoom and
//! cursor, and all four share the document's highlights, because the
//! highlights belong to the buffer. `<C-w>v` splits, `<C-w>c` closes,
//! `<C-w>hjkl` moves between them, as in Vim. A build with no splits has one
//! window on one document, `hlidskjalf.OneWindow`, and refuses a second file
//! rather than opening it into a buffer nothing could show.
//!
//! Everything about *where* a window is looking lives in `hlidskjalf.View`
//! and is tested there without a device. What lives in `read/` is the part
//! that needs a document and a GPU: which pages to render, where to put the
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
//!
//! ## Where the code is
//!
//! This file is the command: its help and its flags. `read/Session.zig` is
//! the reader's state and what a key, a click or a `:` line does to it;
//! `read/render.zig` and `read/frame.zig` are the pages and the frame loop,
//! the path every frame takes. Every other file in `read/` is one feature
//! the session calls into, split along the lines a build profile can leave
//! out.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const config_mod = @import("config.zig");
const library = @import("library.zig");

const Session = @import("read/Session.zig");
const frame = @import("read/frame.zig");
const marks = @import("read/marks.zig");
const plugins_mod = @import("read/plugins.zig");
const reload = @import("read/reload.zig");
const render = @import("read/render.zig");

const gleipnir = fenrir.gleipnir;
const lyngvi = fenrir.lyngvi;

const View = fenrir.hlidskjalf.View;
const Theme = fenrir.thviti.Theme;

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

/// What fenrir.toml wrote down, or `noreturn` in a build that reads no such
/// file: an optional that can only be null, for the reason given on
/// `Session.LibraryIfStored`.
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

const synopsis = if (caps.splits)
    \\fenrir <file>... [options]       -- `fenrir read <file>...` is the same
    \\
    \\    Opens the documents in a window and scrolls through them. More than
    \\    one file opens them as buffers; the first is shown and the rest are
    \\    reachable with <C-w>n.
    \\
    \\
else
    \\fenrir <file> [options]          -- `fenrir read <file>` is the same
    \\
    \\    Opens the document in a window and scrolls through it. One document:
    \\    this build has one window, and no buffers to hold a second file in.
    \\
    \\
;

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
    \\
++ (if (caps.panels)
    \\    :settings            all of them, as a page over the document
    \\
else "") ++
    \\    :reload, :e!         read the document again from its file
    \\
++ (if (caps.splits)
    \\    :sp, :vs, :close     split below, split beside, close the window
    \\    :only, :bn, :bp      close the others, next / previous document
    \\    :tabnew, :tabclose   a tabpage of this window, close this tabpage
    \\    :tabonly             close every other tabpage
    \\    :tabn, :tabp         next / previous tabpage; with N, that one
    \\
else "") ++
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
    \\
++ (if (caps.search)
    \\    /                    search the document; escape ends it
    \\    n / N                the next and previous match, or the next and
    \\                         previous page when nothing is being searched for
    \\
else
    \\    n / N                the next and previous page
    \\
) ++
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

const min_zoom = View.min_zoom;
const max_zoom = View.max_zoom;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    return runWith(ctx, args, null);
}

/// The reader, and with `comparison` the two documents of a `fenrir diff`
/// side by side: see `arrangeComparison`.
pub fn runWith(ctx: *Context, typed: []const []const u8, comparison: ?Session.ComparisonIfCompared) !void {
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
    var bench: ?frame.BenchKind = null;
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
                bench = std.meta.stringToEnum(frame.Bench.Kind, args[i]) orelse
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
    // Said, rather than the second opened into a buffer that nothing in this
    // build can show.
    if (!caps.splits and files.items.len > 1) {
        return ctx.fail("this build reads one document at a time, and {s} is a second", .{files.items[1]});
    }
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
        .palette_text = if (caps.panels) .init(gpa) else {},
    };
    defer session.deinit();

    // `--time`'s stopwatch for startup. Every stage between here and the
    // first frame reports through it, so "the reader takes a moment to come
    // up" becomes a list of numbers rather than a guess about which stage.
    var stage: frame.Stage = .{ .ctx = ctx, .on = timing, .clock = .start(ctx.io) };
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
                return frame.shoot(&session, dest, width, height, start_page - 1, splits);
            }
        }
    }

    try frame.open(&session, .{
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

