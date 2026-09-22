//! `fenrir raster <file>` -- turn a page into a PNG.
//!
//! The first command in this project that produces a picture of a document.
//! Everything it needs already existed except the last link: Gjöll reads the
//! file, the interpreter turns a page into a display list, and
//! `gleipnir.replay` walks that list through the path pipeline onto a
//! framebuffer. This is the shell around those three calls.
//!
//! It renders on the CPU, deliberately. The GPU pipeline draws the same
//! geometry through the same two passes, but it needs a device, a window, and
//! a driver, and none of those belong between a person and a picture of page
//! four. What this produces is also the reference the GPU is checked against:
//! render both, subtract, and anything left is in the part the CPU cannot
//! model.
//!
//! The report at the end says what was *not* drawn -- text, images, gradients
//! -- rather than letting a page with a hole in it look finished. See
//! `gleipnir/replay.zig` for why each of them is missing and what it is
//! waiting for.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

const content = fenrir.content;
const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const replay = gleipnir.replay;
const glyphmod = @import("glyphs.zig");
const Images = @import("images.zig").Images;
const Glyphs = glyphmod.Fonts;

pub const usage =
    \\fenrir raster <file> [--page N | --all] [options]
    \\
    \\    Interprets a page and rasterises it to a PNG, on the CPU, with no
    \\    device or window involved.
    \\
    \\    --page N       Which page, numbered from 1. Defaults to 1.
    \\    --all          Every page, numbered into separate files.
    \\    -o, --out F    Where to write it. Defaults to page-N.png; with
    \\                   --all, the number is always appended.
    \\    --dpi N        Resolution. Defaults to 96, so a Letter page is
    \\                   816x1056. PDF units are 1/72 inch.
    \\    --scale N      Instead of --dpi: a direct multiplier on page units.
    \\    --samples N    Multisampling: 1, 2, 4 or 8. Defaults to 8.
    \\    --tolerance N  How far a flattened curve may stray, in pixels.
    \\                   Defaults to 0.1.
    \\    --text-boxes   Draw a rectangle where each glyph would be instead of
    \\                   the glyph: a layout aid.
    \\    --image-boxes  Outline each image's placement.
    \\    --no-rotate    Ignore /Rotate.
    \\    --no-type3     Do not run Type 3 glyph procedures.
    \\    --no-annots    Draw only the content stream, leaving out highlights,
    \\                   stamps, form fields and every other annotation.
    \\    --stats        Report and write nothing.
    \\    --time         Time each page and hash its framebuffer, on stderr.
    \\                   The hash proves the pixels did not move and the clock
    \\                   says whether a change was worth making, both out of
    \\                   one run over one set of pixels.
    \\    --path P       Which rasteriser fills an outline: stencil (the
    \\                   default), slug, or both -- which renders the page
    \\                   twice and reports how far the two disagree.
    \\
    \\    Text and images are drawn: Tyr reads TrueType, CFF and Type 1
    \\    outlines, and Gjoll decodes Flate and baseline JPEG images through
    \\    the document's colour space. JPEG 2000, CCITT and JBIG2 images,
    \\    shadings and tiling patterns are not, and are counted and reported
    \\    rather than passed over in silence.
;

/// Above this, a page is almost certainly a mistake -- a --dpi typo, or a
/// document whose media box is in the millions -- and allocating for it would
/// take the machine down rather than report anything.
const max_pixels: u64 = 64 << 20;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var file_path: ?[]const u8 = null;
    var dest: ?[]const u8 = null;
    var page_number: u32 = 1;
    var all = false;
    var stats_only = false;
    var timing = false;
    var dpi: f32 = 96;
    var scale: ?f32 = null;
    var samples: gleipnir.raster.Samples = .eight;
    var path_choice: PathChoice = .stencil;
    var options: content.Options = .{};
    var replay_options: replay.Options = .{};
    var ascii: ?[4]u32 = null;
    var list_fonts = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--page")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--page needs a page number", .{});
            page_number = std.fmt.parseInt(u32, argv[i], 10) catch
                return ctx.fail("not a page number: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--out needs a file name", .{});
            dest = argv[i];
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--dpi needs a number", .{});
            dpi = std.fmt.parseFloat(f32, argv[i]) catch
                return ctx.fail("not a resolution: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--scale")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--scale needs a number", .{});
            scale = std.fmt.parseFloat(f32, argv[i]) catch
                return ctx.fail("not a scale: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--samples")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--samples needs 1, 2, 4 or 8", .{});
            samples = switch (std.fmt.parseInt(u32, argv[i], 10) catch 0) {
                1 => .one,
                2 => .two,
                4 => .four,
                8 => .eight,
                else => return ctx.fail("--samples takes 1, 2, 4 or 8, not {s}", .{argv[i]}),
            };
        } else if (std.mem.eql(u8, arg, "--tolerance")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--tolerance needs a number", .{});
            replay_options.tolerance = std.fmt.parseFloat(f32, argv[i]) catch
                return ctx.fail("not a tolerance: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--text-boxes")) {
            replay_options.text_boxes = true;
        } else if (std.mem.eql(u8, arg, "--image-boxes")) {
            replay_options.image_boxes = true;
        } else if (std.mem.eql(u8, arg, "--no-rotate")) {
            options.rotate = false;
        } else if (std.mem.eql(u8, arg, "--no-type3")) {
            options.type3 = false;
        } else if (std.mem.eql(u8, arg, "--no-annots")) {
            options.annotations = false;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            stats_only = true;
        } else if (std.mem.eql(u8, arg, "--time")) {
            timing = true;
        } else if (std.mem.eql(u8, arg, "--fonts")) {
            list_fonts = true;
        } else if (std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--path needs stencil, slug or both", .{});
            path_choice = if (std.mem.eql(u8, argv[i], "stencil"))
                .stencil
            else if (std.mem.eql(u8, argv[i], "slug"))
                .slug
            else if (std.mem.eql(u8, argv[i], "both"))
                .both
            else
                return ctx.fail("--path wants stencil, slug or both, not {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--ascii")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--ascii needs x,y,w,h", .{});
            ascii = parseWindow(ctx, argv[i]) catch return ctx.fail("--ascii wants x,y,w,h", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (file_path == null) {
            file_path = arg;
        } else {
            return ctx.fail("raster takes one file", .{});
        }
    }

    const name = file_path orelse return ctx.fail("raster needs a file", .{});
    if (page_number == 0) return ctx.fail("pages are numbered from 1", .{});

    // 72 PDF units to the inch (§8.3.2.3), so this is the only place dpi turns
    // into a scale factor.
    const factor = scale orelse (dpi / 72.0);
    if (!(factor > 0) or !std.math.isFinite(factor)) {
        return ctx.fail("a scale has to be positive and finite", .{});
    }

    const bytes = ctx.readFile(name) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ name, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ name, err });
    defer doc.deinit();

    const pages = fenrir.pages.all(&doc) catch |err|
        return ctx.fail("cannot read the page tree: {t}", .{err});
    if (pages.len == 0) return ctx.fail("this document has no pages", .{});

    const job: Job = .{
        .factor = factor,
        .samples = samples,
        .path = path_choice,
        .options = options,
        .replay = replay_options,
        .stats_only = stats_only,
        .timing = timing,
        .ascii = ascii,
        .list_fonts = list_fonts,
    };

    var clocked: Timing = .{};
    const time: ?*Timing = if (timing) &clocked else null;

    // The fonts outlive the page, unlike everything else `one` allocates.
    // See `glyphs.Cache`: a document sets its text in the same few faces, and
    // parsing each font program again for every page is work that was never
    // needed. The heap under it spans the run for the same reason, and still
    // catches the bug the per-page one is there for -- that check is about
    // which allocator freed a thing, not about how long the thing lived.
    var font_heap: std.heap.DebugAllocator(.{}) = .init;
    defer _ = font_heap.deinit();
    var faces: glyphmod.Cache = .init(font_heap.allocator());
    defer faces.deinit();

    // One page's working memory, reused for every page. See the note in `one`
    // for why it is an arena that is reset rather than one that is freed.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();

    if (all) {
        var total: replay.Stats = .{};
        for (pages, 0..) |p, index| {
            const out = try numbered(ctx, dest, index + 1);
            defer ctx.gpa.free(out);
            const s = try one(ctx, &doc, p, out, job, time, &faces, &scratch);
            accumulate(&total, s);
        }
        ctx.note("{d} pages", .{pages.len});
        reportTime(ctx, time);
        report(ctx, total);
        return;
    }

    if (page_number > pages.len) {
        return ctx.fail("page {d}: this document has {d} pages", .{ page_number, pages.len });
    }
    const out = dest orelse try numbered(ctx, null, page_number);
    defer if (dest == null) ctx.gpa.free(out);

    const s = try one(ctx, &doc, pages[page_number - 1], out, job, time, &faces, &scratch);
    reportTime(ctx, time);
    report(ctx, s);
}

const Job = struct {
    factor: f32,
    samples: gleipnir.raster.Samples,
    options: content.Options,
    replay: replay.Options,
    stats_only: bool,
    timing: bool = false,
    ascii: ?[4]u32 = null,
    list_fonts: bool = false,
    path: PathChoice = .stencil,
};

/// Which rasteriser fills the page's outlines. `both` renders it twice and
/// says how far apart the two came out, which is how the analytic one is
/// checked against the one that is known to be right.
const PathChoice = enum { stencil, slug, both };

/// What `--time` measures, in nanoseconds, summed over the pages it saw.
///
/// Split three ways because the three move independently: interpreting is
/// Gjoll's decode and the content stream, the fonts line is every embedded
/// font program parsed again for this page, and rendering is Gleipnir. A
/// change that halves one of them and is invisible in the total is a change
/// aimed at the wrong third.
const Timing = struct {
    pages: u64 = 0,
    canvas: u64 = 0,
    interpret: u64 = 0,
    fonts: u64 = 0,
    render: u64 = 0,
    /// Every page's framebuffer hash, folded together in page order. Two runs
    /// that agree here rendered the same pixels; see `CLAUDE.md`.
    hash: u64 = 0,

    fn total(t: Timing) u64 {
        return t.interpret + t.canvas + t.fonts + t.render;
    }
};

/// Milliseconds, for printing. Nanoseconds are what is measured, because a
/// page can be under a millisecond and a truncated zero is worse than useless.
fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// A stopwatch over `Io`'s monotonic clock, since Zig 0.16 has no `std.time
/// .Timer` and `lyngvi.Clock` answers in seconds of `f32` -- too coarse for a
/// page that renders in two milliseconds.
///
/// `awake` rather than `real` for the same reason the frame clock uses it: a
/// wall clock corrected by NTP mid-run would report a negative page.
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

fn one(
    ctx: *Context,
    doc: *fenrir.Document,
    p: fenrir.Page,
    dest: []const u8,
    job: Job,
    time: ?*Timing,
    faces: *glyphmod.Cache,
    scratch: *std.heap.ArenaAllocator,
) !replay.Stats {
    // Started even when `--time` was not asked for: one `Timer.start` per
    // page is nothing beside interpreting it, and branching on the flag in
    // four places to save it would only make the code harder to read.
    var clock: Lap = .start(ctx.io);

    // The page arena, reused across pages and reset behind us. Everything
    // below is one page's working memory -- a display list, a canvas of
    // fourteen megabytes of `f32`, the rasteriser's scratch -- and `--all`
    // needs one page's worth at a time, not every page's. It used to come from
    // `ctx.gpa`, the CLI's arena, where `deinit` is a no-op: a 519-page scan
    // climbed to eight gigabytes resident before it finished.
    //
    // Retaining the capacity rather than freeing it is the whole point. A
    // fresh arena per page hands back cold pages and pays the fault on all
    // fourteen megabytes again every time, which measured two per cent slower
    // than never freeing at all. Reusing one arena keeps the memory warm and
    // bounds it at the largest page instead of the sum of them.
    //
    // First `defer` in the function, so it runs last -- after every `deinit`
    // below has had its turn at memory this arena owns.
    defer _ = scratch.reset(.retain_capacity);
    const gpa = scratch.allocator();

    var result = content.page(gpa, doc, p, job.options) catch |err|
        return ctx.fail("page {d}: {t}", .{ p.index + 1, err });
    defer result.deinit(gpa);

    const interpret_ns = clock.lap();

    const size = replay.canvasSize(result.list.page, job.factor);
    const pixels = @as(u64, size[0]) * size[1];
    if (pixels > max_pixels) {
        return ctx.fail(
            "page {d} would be {d}x{d}: too big. Lower --dpi.",
            .{ p.index + 1, size[0], size[1] },
        );
    }

    var canvas = gleipnir.raster.Canvas.init(gpa, size[0], size[1], .{ .samples = job.samples }) catch |err|
        return ctx.fail("cannot allocate a {d}x{d} canvas: {t}", .{ size[0], size[1], err });
    defer canvas.deinit(gpa);

    // Opaque white, because that is what paper is and what every other reader
    // shows. A transparent page would composite correctly and look, in most
    // viewers, like nothing at all.
    canvas.fb.clear(.white);

    // A lap of its own, and not part of the font one it used to hide inside.
    // A page at 96dpi is fourteen megabytes of `f32`, allocated and then
    // written once, and folding that into another column made the other
    // column look like the expensive one.
    const canvas_ns = clock.lap();

    // A checking heap, and not the page arena, for these two alone. The reader
    // runs them on a real heap, where freeing something the document's arena
    // owns is a crash; under an arena it is a silent no-op. Two of those have
    // shipped -- an embedded font program, then a `/CIDToGIDMap` -- and each
    // was found by a person opening a document. Here a corpus run finds them.
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer _ = heap.deinit();

    var glyphs: Glyphs = try .init(heap.allocator(), doc, result.list, ctx.io, faces);
    defer glyphs.deinit();

    var images: Images = .init(heap.allocator(), doc, p.resources);
    defer images.deinit();

    const fonts_ns = clock.lap();

    var options = job.replay;
    options.glyphs = glyphs.source();
    options.images = images.source();
    options.path_backend = if (job.path == .slug) .slug else .stencil;

    const stats = replay.render(
        gpa,
        &canvas,
        result.list,
        replay.pageTransform(result.list.page, job.factor),
        options,
    ) catch |err| return ctx.fail("page {d}: {t}", .{ p.index + 1, err });

    const render_ns = clock.lap();

    if (time) |t| {
        // The hash is over the float framebuffer rather than over a PNG, so
        // neither the encoder nor the eight-bit conversion is between the
        // rasteriser and the number that proves it did not change.
        const bytes = std.mem.sliceAsBytes(canvas.fb.pixels);
        const page_hash = std.hash.Wyhash.hash(0, bytes);

        t.pages += 1;
        t.interpret += interpret_ns;
        t.canvas += canvas_ns;
        t.fonts += fonts_ns;
        t.render += render_ns;
        // Order-dependent on purpose: two runs that render the same pages in
        // a different order are not the same run.
        t.hash = std.hash.Wyhash.hash(t.hash, std.mem.asBytes(&page_hash));

        ctx.note(
            "page {d}  {d:.2}ms  interpret {d:.2}  canvas {d:.2}  fonts {d:.2}  render {d:.2}  {x:0>16}",
            .{
                p.index + 1,
                ms(interpret_ns + canvas_ns + fonts_ns + render_ns),
                ms(interpret_ns),
                ms(canvas_ns),
                ms(fonts_ns),
                ms(render_ns),
                page_hash,
            },
        );
    }

    // The invariant from `raster.zig`, checked on real documents rather than
    // only on the shapes a test could think of. A page that leaves the stencil
    // dirty has drawn something wrong somewhere, and this is the cheapest
    // place to notice.
    if (!canvas.stencilIsClean()) {
        ctx.note("page {d}: the stencil buffer was not clean afterwards", .{p.index + 1});
    }

    ctx.out.print("page {d}  {d}x{d}  {d} fills  {d} strokes  {d} clips  {d} segments\n", .{
        p.index + 1,
        size[0],
        size[1],
        stats.fills,
        stats.strokes,
        stats.clips,
        stats.segments,
    }) catch {};

    const d = result.diagnostics;
    if (d.annotations_drawn != 0 or d.annotations_skipped != 0) {
        ctx.out.print("         {d} annotation{s} drawn, {d} skipped\n", .{
            d.annotations_drawn,
            if (d.annotations_drawn == 1) "" else "s",
            d.annotations_skipped,
        }) catch {};
    }

    images.report(ctx.out);

    if (job.list_fonts) glyphmod.describe(&glyphs, result.list, ctx.out) catch {};

    if (job.ascii) |w| dumpWindow(ctx, canvas.fb, w);

    if (!job.stats_only) {
        try writePng(ctx, dest, canvas.fb);
        ctx.out.print("wrote {s}\n", .{dest}) catch {};
    }

    if (job.path == .both) try second(ctx, doc, p.resources, result.list, &glyphs, canvas.fb, dest, job, size);
    return stats;
}

/// Renders the same page again through the analytic rasteriser and reports
/// how far the two disagree.
///
/// This is the only evidence the slug pipeline is correct that can be
/// collected without a device, and it is collected on real documents rather
/// than on shapes a test invented. Two independent rasterisers agreeing to
/// within a percent of a level, across a page of several thousand glyphs, is
/// a much stronger statement than either one passing its own unit tests.
fn second(
    ctx: *Context,
    doc: *fenrir.Document,
    resources: ?fenrir.Dict,
    list: gelgja.DisplayList,
    glyphs: *Glyphs,
    reference: gleipnir.Framebuffer,
    dest: []const u8,
    job: Job,
    size: [2]u32,
) !void {
    var canvas = gleipnir.raster.Canvas.init(ctx.gpa, size[0], size[1], .{ .samples = job.samples }) catch
        return;
    defer canvas.deinit(ctx.gpa);
    canvas.fb.clear(.white);

    // The same images as the reference pass, or every figure on the page is
    // a difference that has nothing to do with either rasteriser.
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer _ = heap.deinit();
    var images: Images = .init(heap.allocator(), doc, resources);
    defer images.deinit();

    var options = job.replay;
    options.glyphs = glyphs.source();
    options.images = images.source();
    options.path_backend = .slug;

    _ = replay.render(
        ctx.gpa,
        &canvas,
        list,
        replay.pageTransform(list.page, job.factor),
        options,
    ) catch |err| {
        ctx.note("the analytic pass failed: {t}", .{err});
        return;
    };

    compare(ctx, reference, canvas.fb);

    if (!job.stats_only) {
        const other = suffixed(ctx, dest, "-slug") catch return;
        defer ctx.gpa.free(other);
        try writePng(ctx, other, canvas.fb);
        ctx.out.print("wrote {s}\n", .{other}) catch {};

        // Where they disagree, amplified eight times, so a one-level
        // difference is visible and a shape in the wrong place is glaring.
        var diff = gleipnir.Framebuffer.init(ctx.gpa, size[0], size[1], .srgb) catch return;
        defer diff.deinit(ctx.gpa);
        for (0..@as(usize, size[0]) * size[1]) |i| {
            var d: f32 = 0;
            for (0..3) |c| d = @max(d, @abs(reference.pixels[i * 4 + c] - canvas.fb.pixels[i * 4 + c]));
            const v = 1 - @min(1, d * 8);
            diff.pixels[i * 4 ..][0..4].* = .{ v, v, v, 1 };
        }
        const name = suffixed(ctx, dest, "-diff") catch return;
        defer ctx.gpa.free(name);
        try writePng(ctx, name, diff);
        ctx.out.print("wrote {s}\n", .{name}) catch {};
    }
}

fn suffixed(ctx: *Context, name: []const u8, tail: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    return std.fmt.allocPrint(ctx.gpa, "{s}{s}{s}", .{ name[0..dot], tail, name[dot..] }) catch
        return ctx.fail("out of memory", .{});
}

/// Per-pixel difference between two renders of the same page.
///
/// Reported in levels out of 255, because that is the unit a difference has
/// to be judged in: a mean under a level is invisible, a maximum of a few
/// levels is an antialiased edge landing differently, and anything with a
/// large *count* of big differences is a shape in the wrong place.
fn compare(ctx: *Context, a: gleipnir.Framebuffer, b: gleipnir.Framebuffer) void {
    if (a.width != b.width or a.height != b.height) return;
    const n = @as(usize, a.width) * a.height;

    var total: f64 = 0;
    var worst: f32 = 0;
    var over_1: u64 = 0;
    var over_8: u64 = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var d: f32 = 0;
        for (0..3) |c| {
            d = @max(d, @abs(a.pixels[i * 4 + c] - b.pixels[i * 4 + c]));
        }
        const levels = d * 255.0;
        total += levels;
        worst = @max(worst, levels);
        if (levels > 1) over_1 += 1;
        if (levels > 8) over_8 += 1;
    }

    ctx.out.print(
        "         stencil vs slug: mean {d:.3}, worst {d:.1}, {d:.3}% over 1 level, {d:.3}% over 8\n",
        .{
            total / @as(f64, @floatFromInt(n)),
            worst,
            @as(f64, @floatFromInt(over_1)) * 100.0 / @as(f64, @floatFromInt(n)),
            @as(f64, @floatFromInt(over_8)) * 100.0 / @as(f64, @floatFromInt(n)),
        },
    ) catch {};
}

/// `page-4.png`, or `name-4.png` from a `--out name.png`.
fn numbered(ctx: *Context, dest: ?[]const u8, n: usize) ![]u8 {
    const base = dest orelse "page.png";
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return std.fmt.allocPrint(ctx.gpa, "{s}-{d}{s}", .{ base[0..dot], n, base[dot..] }) catch
        return ctx.fail("out of memory", .{});
}

fn writePng(ctx: *Context, dest: []const u8, fb: gleipnir.Framebuffer) !void {
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
        return ctx.fail("cannot create {s}: {t}", .{ dest, err });
    defer file.close(ctx.io);

    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buf);
    fb.writePng(ctx.gpa, &writer.interface) catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
    writer.interface.flush() catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
}

/// The one line a benchmark reads: the total, its three parts, and the hash
/// that says the pixels behind it are the same ones as last time.
fn reportTime(ctx: *Context, time: ?*Timing) void {
    const t = (time orelse return).*;
    if (t.pages == 0) return;
    ctx.note(
        "time {d:.2}ms over {d} page{s}  interpret {d:.2}  canvas {d:.2}  fonts {d:.2}  render {d:.2}  hash {x:0>16}",
        .{
            ms(t.total()),
            t.pages,
            if (t.pages == 1) "" else "s",
            ms(t.interpret),
            ms(t.canvas),
            ms(t.fonts),
            ms(t.render),
            t.hash,
        },
    );
}

fn accumulate(total: *replay.Stats, s: replay.Stats) void {
    total.fills += s.fills;
    total.strokes += s.strokes;
    total.clips += s.clips;
    total.unsupported_paint += s.unsupported_paint;
    total.text_runs += s.text_runs;
    total.glyphs += s.glyphs;
    total.images += s.images;
    total.shadings += s.shadings;
    total.layers += s.layers;
    total.segments += s.segments;
    total.clips_dropped += s.clips_dropped;
    total.paths_dropped += s.paths_dropped;
    total.glyphs_drawn += s.glyphs_drawn;
    total.glyphs_missing += s.glyphs_missing;
    total.glyphs_blank += s.glyphs_blank;
    total.glyphs_invisible += s.glyphs_invisible;
    total.text_not_drawn += s.text_not_drawn;
}

/// What is missing from the picture, on stderr so the image path on stdout
/// stays pipeable.
///
/// Only the non-zero lines, and nothing at all when the page came out whole --
/// a report that always prints something teaches people to stop reading it.
fn report(ctx: *Context, s: replay.Stats) void {
    if (s.text_not_drawn != 0) {
        ctx.note("{d} text runs ({d} glyphs) not drawn: no glyph source", .{ s.text_not_drawn, s.glyphs });
    } else if (s.glyphs_invisible == s.glyphs and s.glyphs != 0) {
        ctx.note("{d} glyphs are an invisible OCR layer over a scan; nothing to draw", .{s.glyphs});
    } else if (s.glyphs != 0) {
        ctx.note("{d} of {d} glyphs drawn, {d} blank, {d} invisible", .{
            s.glyphs_drawn, s.glyphs, s.glyphs_blank, s.glyphs_invisible,
        });
    }
    if (s.glyphs_missing != 0) {
        ctx.note("{d} glyphs had no outline: unembedded font, or a code the encoding did not resolve", .{s.glyphs_missing});
    }
    if (s.images_not_drawn != 0) {
        ctx.note("{d} of {d} images not drawn: see the codec note above", .{
            s.images_not_drawn,
            s.images,
        });
    }
    if (s.shadings != 0) ctx.note("{d} shadings not drawn", .{s.shadings});
    if (s.unsupported_paint != 0) {
        ctx.note("{d} paths with a gradient or pattern fill not drawn", .{s.unsupported_paint});
    }
    if (s.paths_dropped != 0) ctx.note("{d} paths over the point budget", .{s.paths_dropped});
    if (s.clips_dropped != 0) ctx.note("{d} clips over the depth budget", .{s.clips_dropped});
    if (s.complete()) ctx.note("every mark on the page was drawn", .{});
}

/// `x,y,w,h`, in device pixels.
fn parseWindow(ctx: *Context, s: []const u8) ![4]u32 {
    var out: [4]u32 = .{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, ',');
    for (&out) |*v| {
        const part = it.next() orelse return ctx.fail("--ascii wants four numbers", .{});
        v.* = std.fmt.parseInt(u32, part, 10) catch
            return ctx.fail("not a number: {s}", .{part});
    }
    return out;
}

/// A window of the framebuffer as text, one character per pixel.
///
/// A rasteriser bug is a statement about individual pixels, and a PNG viewer
/// is a poor instrument for reading one: a one-pixel seam is invisible at a
/// glance and unmistakable in a grid of characters. This is `fenrir trace` for
/// the other end of the pipeline.
///
/// Five levels of ink rather than two, because most rasteriser mistakes show
/// up as *partial* coverage where there should be full -- a seam along a
/// shared edge, a double-blended diagonal -- and a threshold would hide
/// exactly the class of bug worth looking for.
fn dumpWindow(ctx: *Context, fb: gleipnir.Framebuffer, w: [4]u32) void {
    const x0 = @min(w[0], fb.width);
    const y0 = @min(w[1], fb.height);
    const x1 = @min(x0 +| w[2], fb.width);
    const y1 = @min(y0 +| w[3], fb.height);

    ctx.out.print("# ascii {d},{d} {d}x{d}  . <2% - <20% + <60% o <98% # solid\n", .{
        x0, y0, x1 - x0, y1 - y0,
    }) catch {};

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const c = fb.at(x, y);
            // Ink against a white page: how far the pixel is from white, on
            // the luminance the eye weights most.
            const ink = 1.0 - (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) * c.a - (1.0 - c.a);
            const ch: u8 = if (ink > 0.98) '#' else if (ink > 0.6) 'o' else if (ink > 0.2) '+' else if (ink > 0.02) '-' else '.';
            ctx.out.writeByte(ch) catch {};
        }
        ctx.out.writeByte('\n') catch {};
    }
}
