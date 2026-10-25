//! `fenrir diff a.pdf b.pdf` -- which pages of two documents differ.
//!
//! After [diff-pdf](https://github.com/vslavik/diff-pdf): the same options,
//! the same defaults its users reach for, and the same exit codes, so a
//! script written against one runs against the other.
//!
//! ## Cheap first, pixels last
//!
//! 1. Pages are paired by number. A page with no partner is added or removed
//!    and is never drawn.
//! 2. Both pages of a pair are interpreted, and their display lists hashed.
//!    Equal hashes are identical pages, and nothing is rasterised. Two
//!    exports of one source usually stop here, and a document compared with
//!    itself always does.
//! 3. Otherwise both are rasterised at `--dpi` and compared sixteen pixels at
//!    a time, over the union of the two pages.
//! 4. The differing pixels' 16x16 tiles are gathered into rectangles: the
//!    regions a view washes and steps through, and what `--report` counts.
//!
//! `--output-diff` writes diff-pdf's picture of each pair as a PNG rather
//! than a PDF, because fenrir writes no PDF yet.
//!
//! The hash is only worth having if it never calls a changed page identical,
//! so it digests what every object *holds* rather than its number -- a file
//! revised in place keeps the number and replaces the figure. See
//! `DisplayList.hash` and `digest.zig`.
//!
//! ## Threads
//!
//! `--jobs` works as it does in `raster`: each thread opens its own view of
//! both files, takes the next pair when it is free, and the results are
//! printed in page order once every pair is in.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const Digests = @import("digest.zig").Digests;
const glyphmod = @import("glyphs.zig");
const Images = @import("images.zig").Images;
const Lap = @import("raster.zig").Lap;
const read = @import("read.zig");

const content = fenrir.content;
const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const replay = gleipnir.replay;
const Canvas = gleipnir.raster.Canvas;
const Framebuffer = gleipnir.Framebuffer;

pub const usage =
    \\fenrir diff <a.pdf> <b.pdf> [options]
    \\
    \\    Compares two documents page by page, as diff-pdf does, and opens them
    \\    side by side at the first difference. Pages whose display lists hash
    \\    the same are identical without being drawn; the rest are rasterised
    \\    and compared pixel by pixel.
    \\
    \\    --report                     Print the pages that differ, and exit
    \\                                 without opening a window.
    \\    --per-page-pixel-tolerance N A page differs only when more than N
    \\                                 of its pixels do. Defaults to 10.
    \\    --channel-tolerance N        A pixel differs when a channel moves by
    \\                                 more than N of 255. Defaults to 0.
    \\    --skip-identical             List only the pages that differ. The
    \\                                 default.
    \\    --all-pages                  List every page.
    \\    --dpi N                      The resolution pages are compared at.
    \\                                 Defaults to 150; diff-pdf uses 300.
    \\    --jobs N                     Compare N pairs of pages at once. 0 is
    \\                                 one per core. Defaults to 1.
    \\    --output-diff DIR            A PNG of each pair listed, in DIR: ink
    \\                                 only in the first document red, only
    \\                                 in the second blue, in both dark.
    \\                                 Named a3-b3.png, or a7.png and b7.png
    \\                                 for a page one of them has alone.
    \\    --mark-differences           A bar in each picture's left margin
    \\                                 beside the rows that changed.
    \\    --grayscale                  Unchanged ink in grey, so only the
    \\                                 differences are in colour.
    \\    --offset X,Y                 Move the second document X points right
    \\                                 and Y down before comparing, for a
    \\                                 revision whose margins moved. Pages
    \\                                 whose display lists hash the same stay
    \\                                 the same.
    \\    --time                       Where the time went, on stderr.
    \\
    \\    The view takes the reader's --size, --frames, --shot, --path, --vsync,
    \\    --samples, --db, --config, --clean, --gpu, --validate and --device.
    \\
    \\    Exits 0 when the documents are the same, 1 when they differ, 2 for
    \\    bad arguments and 3 when a file would not open.
    \\
    \\in the view -- the first document on the left, the second on the right:
    \\    both windows scroll and zoom together, page against the page it was
    \\    compared with; the changes are washed red on the left and green on
    \\    the right, and ticked on the scrollbar
    \\    ]d / [d              the next / previous change
    \\    gd / gD              side by side, then laid over each other (red
    \\                         only in the first, blue only in the second),
    \\                         then the first alone, then the second alone;
    \\                         gD goes back, so gd gD gd blinks between the
    \\                         two at one place
    \\    :diff side|overlay|first|second   one of those by name
    \\    <C-arrows>           move the second document a point against the
    \\                         first, and compare again; the overlay moves at
    \\                         once and the washes when the comparison is back
    \\    :diff offset X Y     move it exactly; :diff offset puts it back
;

/// diff-pdf's exit codes.
pub const exit_same = 0;
pub const exit_differ = 1;
pub const exit_usage = 2;
pub const exit_unreadable = 3;

pub const Options = struct {
    /// A page differs only when more than this many pixels do.
    pixel_tolerance: u64 = 10,
    /// A pixel differs when a channel moves by more than this many levels.
    channel_tolerance: u8 = 0,
    /// Only pages that differ are listed.
    skip_identical: bool = true,
    /// Device pixels per inch, for the pages that have to be drawn.
    dpi: f32 = 150,
    jobs: u32 = 1,
    /// Where to write a picture of each pair listed, or nowhere.
    output_dir: ?[]const u8 = null,
    /// A bar in each picture's left margin beside the rows that changed.
    mark_differences: bool = false,
    /// Unchanged ink drawn grey, so only the differences carry colour.
    grayscale: bool = false,
    /// How far the second document is moved before it is compared, in
    /// points across and down: diff-pdf's offset, for a revision whose
    /// margins moved. The view nudges it with `<C-arrows>`. Pages whose
    /// display lists hash the same are still the same page, moved or not.
    offset: [2]f32 = .{ 0, 0 },
};

/// Which page of each document is compared with which. Zero-based, and null
/// on the side a page is missing from.
pub const Pair = struct {
    a: ?u32,
    b: ?u32,
};

/// What comparing one pair found.
pub const Result = struct {
    kind: Kind = .failed,
    /// Pixels that differ. Zero unless the pages were drawn.
    pixels: u64 = 0,
    /// Why a pair could not be compared, when it could not.
    err: ?anyerror = null,
    /// Where the pages differ, in reading order, when they do. Allocated
    /// with `smp_allocator`, because a worker thread made them; see
    /// `freeResults`.
    regions: []const Region = &.{},
    /// Why its picture was not written, when one was asked for and was not.
    unwritten: ?anyerror = null,

    pub const Kind = enum {
        /// The display lists hash the same: nothing was drawn.
        same_list,
        /// Drawn and compared, and within the pixel tolerance.
        same_pixels,
        differ,
        /// A page only the first document has.
        only_a,
        only_b,
        /// A page that would not interpret or draw. Counted as differing,
        /// since nothing can vouch that it does not.
        failed,
    };

    pub fn differs(r: Result) bool {
        return switch (r.kind) {
            .same_list, .same_pixels => false,
            .differ, .only_a, .only_b, .failed => true,
        };
    }
};

pub fn freeResults(gpa: std.mem.Allocator, results: []Result) void {
    for (results) |r| std.heap.smp_allocator.free(r.regions);
    gpa.free(results);
}

/// A finished comparison as the view reads it: each pair, what it found, and
/// which pair each page of each document is in.
///
/// The documents are sides 0 and 1, which are also their buffer numbers in
/// the reader.
pub const Comparison = struct {
    /// Everything below that this made, and `results` once they are its own.
    /// Thread-safe, because a comparison run again is made on a thread of
    /// its own and handed over; see `replace`.
    gpa: std.mem.Allocator,
    pairs: []const Pair,
    results: []Result,
    /// Whether `results` are this comparison's to free: false for results
    /// it was lent, true for ones handed to `replace`.
    owns_results: bool = false,
    /// What it was compared with. `factor` is its dpi as pixels per point,
    /// which is what the regions are measured in.
    options: Options,
    factor: f32,
    /// Each page's pair, by side.
    pair_of: [2][]u32,
    /// Every change in order: each region of each differing pair, and a
    /// page one document has alone as a change of its own. What `]d` walks.
    changes: []Change,

    pub const Change = struct {
        pair: u32,
        /// Null for a whole page: added, removed, or not compared.
        region: ?u32,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        pairs: []const Pair,
        results: []Result,
        counts: [2]usize,
        options: Options,
    ) !Comparison {
        var pair_of: [2][]u32 = undefined;
        pair_of[0] = try gpa.alloc(u32, counts[0]);
        errdefer gpa.free(pair_of[0]);
        pair_of[1] = try gpa.alloc(u32, counts[1]);
        errdefer gpa.free(pair_of[1]);
        for (pairs, 0..) |p, i| {
            if (p.a) |a| pair_of[0][a] = @intCast(i);
            if (p.b) |b| pair_of[1][b] = @intCast(i);
        }
        return .{
            .gpa = gpa,
            .pairs = pairs,
            .results = results,
            .options = options,
            .factor = options.dpi / 72.0,
            .pair_of = pair_of,
            .changes = try listChanges(gpa, results),
        };
    }

    pub fn deinit(c: *Comparison) void {
        if (c.owns_results) freeResults(c.gpa, c.results);
        c.gpa.free(c.pair_of[0]);
        c.gpa.free(c.pair_of[1]);
        c.gpa.free(c.changes);
    }

    /// Takes the results of comparing the same pairs again -- after a nudge
    /// -- in place of these. They must have been made with `gpa`.
    pub fn replace(c: *Comparison, results: []Result) !void {
        const changes = try listChanges(c.gpa, results);
        if (c.owns_results) freeResults(c.gpa, c.results);
        c.gpa.free(c.changes);
        c.results = results;
        c.owns_results = true;
        c.changes = changes;
    }

    fn listChanges(gpa: std.mem.Allocator, results: []const Result) ![]Change {
        var changes: std.ArrayList(Change) = .empty;
        errdefer changes.deinit(gpa);
        for (results, 0..) |r, i| {
            if (!r.differs()) continue;
            if (r.regions.len == 0) try changes.append(gpa, .{ .pair = @intCast(i), .region = null });
            for (0..r.regions.len) |k| try changes.append(gpa, .{ .pair = @intCast(i), .region = @intCast(k) });
        }
        return changes.toOwnedSlice(gpa);
    }

    /// What was found for the pair a page is in.
    pub fn resultOn(c: Comparison, side: u1, page: u32) Result {
        if (page >= c.pair_of[side].len) return .{};
        return c.results[c.pair_of[side][page]];
    }

    /// The page of the other document at the same place as `page` of this
    /// one: its partner, or for a page one document has alone, the partner
    /// of the nearest page before it that has one -- so scrolling through
    /// three inserted pages holds the other side still rather than jumping.
    pub fn partner(c: Comparison, side: u1, page: u32) u32 {
        if (page >= c.pair_of[side].len) return 0;
        var i = c.pair_of[side][page];
        while (true) : (i -= 1) {
            const p = c.pairs[i];
            if (if (side == 0) p.b else p.a) |other| return other;
            if (i == 0) break;
        }
        // Nothing before it has a partner: the other side's first page.
        return 0;
    }

    /// A change's page on one side, and how far down it the change starts,
    /// in points. A change on a page this side does not have is placed at
    /// the partner that side scrolls to.
    pub fn changeAt(c: Comparison, side: u1, change: Change) struct { page: u32, down: f32 } {
        const p = c.pairs[change.pair];
        const page = (if (side == 0) p.a else p.b) orelse c.partner(side ^ 1, (if (side == 0) p.b else p.a).?);
        const down = if (change.region) |r|
            // The top edge on a page of no height, turned round: the offset
            // applied the same way the box has it applied.
            -c.regionIn(side, c.results[change.pair].regions[r], 0).max_y
        else
            0;
        return .{ .page = page, .down = down };
    }

    /// A region as a box in one side's page, in that page's user space. The
    /// second document was moved by the offset before it was compared, so
    /// its box is moved back by as much.
    pub fn regionIn(c: Comparison, side: u1, region: Region, page_height: f32) gelgja.Bounds {
        const box = region.inPage(c.factor, page_height);
        if (side == 0) return box;
        const dx = c.options.offset[0];
        const dy = c.options.offset[1];
        return .fromRect(box.min_x - dx, box.min_y + dy, box.max_x - dx, box.max_y + dy);
    }
};

/// Pages by number, as diff-pdf pairs them: the first with the first, and
/// whatever one document has past the other's end on its own.
pub fn pairByNumber(gpa: std.mem.Allocator, a_pages: usize, b_pages: usize) ![]Pair {
    const pairs = try gpa.alloc(Pair, @max(a_pages, b_pages));
    for (pairs, 0..) |*p, i| p.* = .{
        .a = if (i < a_pages) @intCast(i) else null,
        .b = if (i < b_pages) @intCast(i) else null,
    };
    return pairs;
}

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var files: [2][]const u8 = undefined;
    var given: usize = 0;
    var options: Options = .{};
    var timing = false;
    var report_only = false;
    // What the view is opened with: the two files, then these.
    var reader_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--report")) {
            report_only = true;
        } else if (std.mem.eql(u8, arg, "--per-page-pixel-tolerance")) {
            i += 1;
            if (i == argv.len) return bad(ctx, "{s} needs a number", .{arg});
            options.pixel_tolerance = std.fmt.parseInt(u64, argv[i], 10) catch
                return bad(ctx, "not a pixel count: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--channel-tolerance")) {
            i += 1;
            if (i == argv.len) return bad(ctx, "{s} needs a number", .{arg});
            options.channel_tolerance = std.fmt.parseInt(u8, argv[i], 10) catch
                return bad(ctx, "--channel-tolerance is 0 to 255, not {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--skip-identical")) {
            options.skip_identical = true;
        } else if (std.mem.eql(u8, arg, "--all-pages")) {
            options.skip_identical = false;
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            i += 1;
            if (i == argv.len) return bad(ctx, "--dpi needs a number", .{});
            options.dpi = std.fmt.parseFloat(f32, argv[i]) catch
                return bad(ctx, "not a resolution: {s}", .{argv[i]});
            if (!(options.dpi > 0) or !std.math.isFinite(options.dpi)) {
                return bad(ctx, "a resolution has to be positive", .{});
            }
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i == argv.len) return bad(ctx, "--jobs needs a number of threads", .{});
            options.jobs = std.fmt.parseInt(u32, argv[i], 10) catch
                return bad(ctx, "not a thread count: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--output-diff")) {
            i += 1;
            if (i == argv.len) return bad(ctx, "--output-diff needs a directory", .{});
            options.output_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--offset")) {
            i += 1;
            if (i == argv.len) return bad(ctx, "--offset needs X,Y", .{});
            const comma = std.mem.indexOfScalar(u8, argv[i], ',') orelse
                return bad(ctx, "--offset wants X,Y in points", .{});
            options.offset = .{
                std.fmt.parseFloat(f32, argv[i][0..comma]) catch return bad(ctx, "--offset wants X,Y in points", .{}),
                std.fmt.parseFloat(f32, argv[i][comma + 1 ..]) catch return bad(ctx, "--offset wants X,Y in points", .{}),
            };
        } else if (std.mem.eql(u8, arg, "--mark-differences")) {
            options.mark_differences = true;
        } else if (std.mem.eql(u8, arg, "--grayscale")) {
            options.grayscale = true;
        } else if (std.mem.eql(u8, arg, "--time")) {
            timing = true;
        } else if (readerOption(arg)) |takes_value| {
            try reader_args.append(ctx.gpa, arg);
            if (takes_value) {
                i += 1;
                if (i == argv.len) return bad(ctx, "{s} needs a value", .{arg});
                try reader_args.append(ctx.gpa, argv[i]);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return bad(ctx, "unknown option {s}", .{arg});
        } else {
            if (given == 2) return bad(ctx, "diff takes two files", .{});
            files[given] = arg;
            given += 1;
        }
    }
    if (given != 2) return bad(ctx, "diff needs two files", .{});
    if (options.jobs == 0) options.jobs = cpuCount();
    if (options.output_dir) |dir| {
        Io.Dir.cwd().createDirPath(ctx.io, dir) catch |err|
            return bad(ctx, "cannot make {s}: {t}", .{ dir, err });
    }

    var wall: Lap = .start(ctx.io);

    // Read once, here, and shared: every thread opens its own `Document`
    // over the same bytes, as `raster --jobs` does.
    var bytes: [2][]const u8 = undefined;
    var counts: [2]usize = undefined;
    for (files, 0..) |file, side| {
        bytes[side] = ctx.readFile(file) catch |err|
            return unreadable(ctx, "cannot read {s}: {t}", .{ file, err });
        var doc = fenrir.openBorrowed(ctx.gpa, bytes[side]) catch |err|
            return unreadable(ctx, "cannot open {s}: {t}", .{ file, err });
        defer doc.deinit();
        const pages = fenrir.pages.all(&doc) catch |err|
            return unreadable(ctx, "cannot read the pages of {s}: {t}", .{ file, err });
        counts[side] = pages.len;
    }

    const pairs = try pairByNumber(ctx.gpa, counts[0], counts[1]);
    var clocked: Timing = .{};
    // Not the command's arena: a view that nudges one document against the
    // other compares again on a thread of its own, and swaps these out.
    const heap = std.heap.smp_allocator;
    const results = try compare(heap, ctx.io, bytes, pairs, options, &clocked);

    const names: [2][]const u8 = .{ std.fs.path.basename(files[0]), std.fs.path.basename(files[1]) };
    var differing: usize = 0;
    for (results) |r| {
        if (r.differs()) differing += 1;
    }
    if (timing) clocked.print(ctx, wall.lap());
    const verdict: u8 = if (differing == 0) exit_same else exit_differ;

    if (report_only) {
        defer freeResults(heap, results);
        try report(ctx.out, pairs, results, names, @max(counts[0], counts[1]), options);
        ctx.exit = verdict;
        return;
    }

    ctx.note("{d} of {d} pages differ", .{ differing, pairs.len });
    var comparison: Comparison = Comparison.init(heap, pairs, results, counts, options) catch |err| {
        freeResults(heap, results);
        return err;
    };
    comparison.owns_results = true;
    defer comparison.deinit();
    try reader_args.insertSlice(ctx.gpa, 0, &files);
    try read.runWith(ctx, reader_args.items, &comparison);
    ctx.exit = verdict;
}

/// The reader's options `fenrir diff` passes on to the view, and whether each
/// takes a value. `--dpi` and `--time` are not among them: here they mean the
/// comparison's.
fn readerOption(arg: []const u8) ?bool {
    const with_value = [_][]const u8{ "--size", "--frames", "--shot", "--path", "--vsync", "--db", "--config", "--gpu", "--samples" };
    const alone = [_][]const u8{ "--clean", "--validate", "--device" };
    for (with_value) |o| if (std.mem.eql(u8, arg, o)) return true;
    for (alone) |o| if (std.mem.eql(u8, arg, o)) return false;
    return null;
}

/// A bad argument: diff-pdf's 2, not the usual 1.
fn bad(ctx: *Context, comptime fmt: []const u8, args: anytype) error{CommandFailed} {
    ctx.exit = exit_usage;
    return ctx.fail(fmt, args);
}

fn unreadable(ctx: *Context, comptime fmt: []const u8, args: anytype) error{CommandFailed} {
    ctx.exit = exit_unreadable;
    return ctx.fail(fmt, args);
}

pub fn cpuCount() u32 {
    const n = std.Thread.getCpuCount() catch return 1;
    return @intCast(@max(1, @min(n, 256)));
}

// -- the report ----------------------------------------------------------------

/// One line per pair worth listing, and a count.
///
/// ```
/// page  3 ≠  3    1,204 px in 3 regions
/// page  7 +       only in v2.pdf
/// 2 of 12 pages differ
/// ```
///
/// The numbers are right-aligned to the widest page number either document
/// has, so a column of them can be read down.
pub fn report(
    w: *Io.Writer,
    pairs: []const Pair,
    results: []const Result,
    names: [2][]const u8,
    most_pages: usize,
    options: Options,
) !void {
    const width = digits(most_pages);
    var differing: usize = 0;
    for (pairs, results) |p, r| {
        if (r.differs()) differing += 1;
        if (!r.differs() and options.skip_identical) continue;

        // A page on one side only is numbered in the first column, so every
        // row starts with a number; the sign says whose it is.
        try w.writeAll("page ");
        try number(w, p.a orelse p.b, width);
        try w.writeAll(switch (r.kind) {
            .same_list, .same_pixels => " = ",
            .differ, .failed => " ≠ ",
            .only_a => " - ",
            .only_b => " + ",
        });
        try number(w, if (p.a != null) p.b else null, width);
        try w.writeAll("    ");

        switch (r.kind) {
            .same_list => try w.writeAll("same display list"),
            .same_pixels => {
                var buf: [32]u8 = undefined;
                try w.print("{s} px", .{grouped(r.pixels, &buf)});
            },
            .differ => {
                var buf: [32]u8 = undefined;
                const n = r.regions.len;
                try w.print("{s} px in {d} region{s}", .{ grouped(r.pixels, &buf), n, if (n == 1) "" else "s" });
            },
            .only_a => try w.print("only in {s}", .{names[0]}),
            .only_b => try w.print("only in {s}", .{names[1]}),
            .failed => try w.print("could not be compared: {t}", .{r.err orelse error.Unexpected}),
        }
        if (r.unwritten) |err| try w.print("; its picture was not written: {t}", .{err});
        try w.writeByte('\n');
    }
    try w.print("{d} of {d} pages differ\n", .{ differing, pairs.len });
}

/// A page number from one, or blanks where a pair has no page on that side.
fn number(w: *Io.Writer, page: ?u32, width: usize) !void {
    var buf: [16]u8 = undefined;
    const text = if (page) |p| std.fmt.bufPrint(&buf, "{d}", .{p + 1}) catch "?" else "";
    try w.splatByteAll(' ', width -| text.len);
    try w.writeAll(text);
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// `1204` as `1,204`: a count of pixels runs to seven digits, and seven
/// digits in a row have to be counted to be read.
fn grouped(n: u64, buf: *[32]u8) []const u8 {
    var plain: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&plain, "{d}", .{n}) catch unreachable;
    var out: usize = 0;
    for (s, 0..) |c, i| {
        if (i != 0 and (s.len - i) % 3 == 0) {
            buf[out] = ',';
            out += 1;
        }
        buf[out] = c;
        out += 1;
    }
    return buf[0..out];
}

// -- comparing ---------------------------------------------------------------

/// Compares every pair, on `options.jobs` threads, and returns a result per
/// pair in the same order.
pub fn compare(
    gpa: std.mem.Allocator,
    io: Io,
    bytes: [2][]const u8,
    pairs: []const Pair,
    options: Options,
    time: *Timing,
) ![]Result {
    const results = try gpa.alloc(Result, pairs.len);
    @memset(results, .{});

    var fleet: Fleet = .{
        .io = io,
        .bytes = bytes,
        .pairs = pairs,
        .results = results,
        .options = options,
    };

    const threads = @min(options.jobs, @max(1, pairs.len));
    var pool: [256]std.Thread = undefined;
    const timings = try gpa.alloc(Timing, threads);
    defer gpa.free(timings);
    @memset(timings, .{});

    var started: usize = 0;
    if (threads > 1) {
        while (started < threads) : (started += 1) {
            pool[started] = std.Thread.spawn(.{}, work, .{ &fleet, &timings[started] }) catch break;
        }
    }
    // One thread asked for, or none would start: the pairs are this one's.
    if (started == 0) work(&fleet, &timings[0]);
    for (pool[0..started]) |t| t.join();

    for (timings) |t| time.add(t);
    return results;
}

/// What every thread shares: the files, the pairs, and the next one to take.
const Fleet = struct {
    io: Io,
    bytes: [2][]const u8,
    pairs: []const Pair,
    results: []Result,
    options: Options,
    next: std.atomic.Value(usize) = .init(0),
};

/// One thread: its own view of each document, and pairs until there are none.
fn work(f: *Fleet, time: *Timing) void {
    var w: Worker = undefined;
    w.init(f.io, f.bytes) catch |err| {
        // Every pair this thread would have taken is still taken by it, and
        // said to have failed, rather than silently never compared.
        while (true) {
            const index = f.next.fetchAdd(1, .monotonic);
            if (index >= f.pairs.len) return;
            f.results[index] = .{ .kind = .failed, .err = err };
        }
    };
    defer w.deinit();

    while (true) {
        const index = f.next.fetchAdd(1, .monotonic);
        if (index >= f.pairs.len) break;
        f.results[index] = w.comparePair(f.pairs[index], f.options);
    }
    time.* = w.time;
}

/// Above this, a page is a mistake -- a `--dpi` typo, or a media box in the
/// millions -- and allocating for it would take the machine down. `raster`'s
/// limit.
const max_pixels: u64 = 64 << 20;

/// One thread's documents and working memory.
///
/// Built in place and never moved: each side's digests point at its document.
const Worker = struct {
    /// Glyph bindings, decoded images and the digest memo: freed precisely,
    /// and safe on any thread.
    heap: std.mem.Allocator,
    io: Io,
    sides: [2]Side,
    /// One pair's display lists and canvases, reset after each pair and
    /// reused, as `raster` reuses its page arena. Two canvases at 150 dpi are
    /// over a hundred megabytes, and faulting them in afresh for every pair
    /// would be most of the cost of comparing it.
    scratch: std.heap.ArenaAllocator,
    time: Timing = .{},

    fn init(w: *Worker, io: Io, bytes: [2][]const u8) !void {
        w.heap = std.heap.smp_allocator;
        w.io = io;
        w.time = .{};
        w.scratch = .init(std.heap.page_allocator);
        errdefer w.scratch.deinit();
        try w.sides[0].open(w.heap, bytes[0]);
        errdefer w.sides[0].close();
        try w.sides[1].open(w.heap, bytes[1]);
    }

    fn deinit(w: *Worker) void {
        w.sides[1].close();
        w.sides[0].close();
        w.scratch.deinit();
    }

    fn comparePair(w: *Worker, pair: Pair, options: Options) Result {
        // First, so it runs last: the lists and canvases below are all in it.
        defer _ = w.scratch.reset(.retain_capacity);
        const gpa = w.scratch.allocator();
        var clock: Lap = .start(w.io);

        const pages = [2]?u32{ pair.a, pair.b };
        var lists: [2]?gelgja.DisplayList = .{ null, null };
        for (pages, &lists, &w.sides) |page, *list, *side| {
            list.* = side.interpret(gpa, page orelse continue) catch |err| return .{ .err = err };
        }
        w.time.interpret += clock.lap();

        var result: Result = if (pair.a == null)
            .{ .kind = .only_b }
        else if (pair.b == null)
            .{ .kind = .only_a }
        else sure: {
            const hash_a = lists[0].?.hash(w.sides[0].digests.objects());
            const hash_b = lists[1].?.hash(w.sides[1].digests.objects());
            w.time.hash += clock.lap();
            w.time.pairs += 1;
            if (hash_a) |x| if (hash_b) |y| if (x == y) break :sure .{ .kind = .same_list };
            break :sure .{ .kind = .differ };
        };

        // Drawn to be counted, or to be written: a page only one document
        // has is drawn only for its picture, and an identical one only when
        // every page's picture was asked for.
        const measure = result.kind == .differ;
        const picture = options.output_dir != null and
            (result.differs() or !options.skip_identical);
        if (!measure and !picture) return result;

        const factor = options.dpi / 72.0;
        var fbs: [2]?Framebuffer = .{ null, null };
        for (pages, lists, &w.sides, &fbs, 0..) |page, list, *side, *fb, index| {
            // Identical pages are one page drawn once.
            if (fbs[0] != null and result.kind == .same_list) break;
            // The second document moved by the offset, and the first never.
            const shift = if (index == 1) options.offset else [2]f32{ 0, 0 };
            const canvas = w.draw(gpa, side, page orelse continue, list.?, factor, shift) catch |err|
                return .{ .err = err };
            fb.* = canvas.fb;
        }
        w.time.render += clock.lap();
        w.time.drawn += 1;

        // A missing page is blank paper, so that everything on the one that
        // is there shows as added or removed.
        const a = fbs[0] orelse (blank(gpa, fbs[1].?) catch |err| return .{ .err = err });
        const b = fbs[1] orelse if (result.kind == .same_list)
            a
        else
            (blank(gpa, a) catch |err| return .{ .err = err });

        var tiles = Tiles.init(gpa, @max(a.width, b.width), @max(a.height, b.height)) catch |err|
            return .{ .err = err };
        const pixels = countDifferences(a, b, options.channel_tolerance, &tiles);
        if (measure) {
            result.pixels = pixels;
            if (pixels > options.pixel_tolerance) {
                result.regions = regionsOf(w.heap, gpa, tiles) catch |err| return .{ .err = err };
            } else {
                result.kind = .same_pixels;
            }
        }
        w.time.compare += clock.lap();

        if (options.output_dir) |dir| {
            if (result.differs() or !options.skip_identical) {
                w.writePicture(gpa, dir, pair, a, b, tiles, options) catch |err| {
                    result.unwritten = err;
                };
            }
        }
        return result;
    }

    /// diff-pdf's picture of a pair, as a PNG in `dir`: `a3-b3.png` for a
    /// pair, `a7.png` or `b7.png` for a page one document has alone.
    fn writePicture(
        w: *Worker,
        gpa: std.mem.Allocator,
        dir: []const u8,
        pair: Pair,
        a: Framebuffer,
        b: Framebuffer,
        tiles: Tiles,
        options: Options,
    ) !void {
        // From the pair's arena, like everything else the pair made.
        const out = try Framebuffer.init(gpa, @max(a.width, b.width), @max(a.height, b.height), .srgb);
        overlay(out, a, b, options.channel_tolerance, options.grayscale);
        if (options.mark_differences) markRows(out, tiles, @max(3, @as(u32, @intFromFloat(options.dpi / 25))));

        var name: [64]u8 = undefined;
        var path: [4096]u8 = undefined;
        const file_name = pictureName(&name, pair);
        const full = try std.fmt.bufPrint(&path, "{s}{c}{s}", .{ dir, std.fs.path.sep, file_name });

        var file = try Io.Dir.cwd().createFile(w.io, full, .{});
        defer file.close(w.io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(w.io, &buf);
        try out.writePng(gpa, &writer.interface);
        try writer.interface.flush();
    }

    /// One page on a white canvas, drawn as `raster` draws it.
    fn draw(
        w: *Worker,
        gpa: std.mem.Allocator,
        side: *Side,
        index: u32,
        list: gelgja.DisplayList,
        factor: f32,
        // Points across and down, before the page is drawn.
        shift: [2]f32,
    ) !Canvas {
        const size = replay.canvasSize(list.page, factor);
        if (@as(u64, size[0]) * size[1] > max_pixels) return error.PageTooBig;

        var canvas = try Canvas.init(gpa, size[0], size[1], .{ .samples = .eight });
        errdefer canvas.deinit(gpa);
        canvas.fb.clear(.white);

        var glyphs: glyphmod.Fonts = try .init(w.heap, &side.doc, list, w.io, &side.faces);
        defer glyphs.deinit();
        var images: Images = .init(w.heap, &side.doc, side.pages[index].resources);
        defer images.deinit();

        const place = replay.pageTransform(list.page, factor).concat(.translation(shift[0] * factor, shift[1] * factor));
        _ = try replay.render(gpa, &canvas, list, place, .{
            .glyphs = glyphs.source(),
            .images = images.source(),
        });
        return canvas;
    }
};

/// One document, as one thread reads it.
///
/// Opened in place and never moved: `digests` points at `doc`.
const Side = struct {
    heap: std.mem.Allocator,
    doc: fenrir.Document,
    pages: []const fenrir.Page,
    faces: glyphmod.Cache,
    digests: Digests,

    fn open(s: *Side, heap: std.mem.Allocator, bytes: []const u8) !void {
        s.heap = heap;
        s.doc = try fenrir.openBorrowed(heap, bytes);
        errdefer s.doc.deinit();
        s.pages = try fenrir.pages.all(&s.doc);
        s.faces = .init(heap);
        s.digests = .init(heap, &s.doc);
    }

    fn close(s: *Side) void {
        s.digests.deinit();
        s.faces.deinit();
        s.doc.deinit();
    }

    fn interpret(s: *Side, gpa: std.mem.Allocator, index: u32) !gelgja.DisplayList {
        const result = try content.page(gpa, &s.doc, s.pages[index], .{});
        return result.list;
    }
};

// -- pixels ------------------------------------------------------------------

/// Pixels compared at once: sixteen, four channels each.
const chunk = 16;
const Lanes = @Vector(chunk * 4, f32);

/// How many pixels of two pages differ, over the union of the two.
///
/// A pixel differs when any channel moves by more than `tolerance` levels of
/// 255, measured as the eight-bit value a PNG of the page would hold. The
/// page is opaque paper, so its premultiplied channels are its straight ones
/// and nothing has to be divided out first. A pixel on one page and off the
/// other differs; one on neither -- in the corner two pages of different
/// shapes leave -- does not.
///
/// Sixteen pixels a step, and most steps are one comparison: runs of
/// untouched paper and unchanged type are bit-for-bit equal, and only a chunk
/// that is not pays for the rounding.
///
/// Every differing pixel's tile is marked in `tiles`, which must cover the
/// union.
pub fn countDifferences(a: Framebuffer, b: Framebuffer, tolerance: u8, tiles: *Tiles) u64 {
    const width = @max(a.width, b.width);
    const common_w = @min(a.width, b.width);
    const common_h = @min(a.height, b.height);
    const wider = if (a.width > b.width) a else b;
    const tol: f32 = @floatFromInt(tolerance);

    var count: u64 = 0;
    var y: u32 = 0;
    while (y < common_h) : (y += 1) {
        const row_a = a.pixels[@as(usize, y) * a.width * 4 ..][0 .. @as(usize, common_w) * 4];
        const row_b = b.pixels[@as(usize, y) * b.width * 4 ..][0 .. @as(usize, common_w) * 4];

        var x: u32 = 0;
        while (x + chunk <= common_w) : (x += chunk) {
            const mask = chunkMask(row_a[x * 4 ..][0 .. chunk * 4], row_b[x * 4 ..][0 .. chunk * 4], tol);
            if (mask == 0) continue;
            count += @popCount(mask);
            tiles.mark(x / tile, y / tile);
        }
        while (x < common_w) : (x += 1) {
            if (!pixelDiffers(row_a[x * 4 ..][0..4], row_b[x * 4 ..][0..4], tol)) continue;
            count += 1;
            tiles.mark(x / tile, y / tile);
        }
        // Past the narrower page's right edge.
        count += width - common_w;
        tiles.markSpan(common_w, wider.width, y);
    }
    // Below the shorter page: only the taller one is there.
    const taller = if (a.height > b.height) a else b;
    count += @as(u64, taller.width) * (taller.height - common_h);
    if (taller.height > common_h) {
        var row = common_h / tile;
        while (row <= (taller.height - 1) / tile) : (row += 1) tiles.markSpan(0, taller.width, row * tile);
    }
    return count;
}

/// The side of a tile, and the width of a chunk: one chunk of a row is one
/// tile's row, so marking the tile costs nothing past the chunk's own mask.
const tile = chunk;

/// Which tiles of the union of two pages hold a differing pixel.
pub const Tiles = struct {
    cols: u32,
    rows: u32,
    marked: []bool,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Tiles {
        const cols = (width + tile - 1) / tile;
        const rows = (height + tile - 1) / tile;
        const marked = try gpa.alloc(bool, @as(usize, cols) * rows);
        @memset(marked, false);
        return .{ .cols = cols, .rows = rows, .marked = marked };
    }

    pub fn at(t: Tiles, col: u32, row: u32) bool {
        return t.marked[@as(usize, row) * t.cols + col];
    }

    fn mark(t: *Tiles, col: u32, row: u32) void {
        t.marked[@as(usize, row) * t.cols + col] = true;
    }

    /// The tiles under pixels `x0..x1` of row `y`.
    fn markSpan(t: *Tiles, x0: u32, x1: u32, y: u32) void {
        if (x0 >= x1) return;
        var col = x0 / tile;
        while (col <= (x1 - 1) / tile) : (col += 1) t.mark(col, y / tile);
    }
};

/// A changed area, in pixels of the union of the two pages, from the top
/// left.
pub const Region = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    /// The same area in a page's user space -- points, y upwards -- which is
    /// what a mark is stored in and what `View.windowBox` takes. Each
    /// document's page has its own height, so each gets its own answer.
    pub fn inPage(r: Region, factor: f32, page_height: f32) gelgja.Bounds {
        const f = @as(f32, 1) / factor;
        return .fromRect(
            @as(f32, @floatFromInt(r.x0)) * f,
            page_height - @as(f32, @floatFromInt(r.y1)) * f,
            @as(f32, @floatFromInt(r.x1)) * f,
            page_height - @as(f32, @floatFromInt(r.y0)) * f,
        );
    }

    fn overlaps(r: Region, o: Region) bool {
        return r.x0 < o.x1 and o.x0 < r.x1 and r.y0 < o.y1 and o.y0 < r.y1;
    }

    fn merge(r: Region, o: Region) Region {
        return .{ .x0 = @min(r.x0, o.x0), .y0 = @min(r.y0, o.y0), .x1 = @max(r.x1, o.x1), .y1 = @max(r.y1, o.y1) };
    }

    fn readsBefore(_: void, r: Region, o: Region) bool {
        return if (r.y0 != o.y0) r.y0 < o.y0 else r.x0 < o.x0;
    }
};

/// The marked tiles gathered into rectangles, in reading order.
///
/// Tiles one empty tile apart are one region. A tile is 16 pixels, under
/// eight points at 150 dpi: more than a word space and less than a line's
/// pitch, so a reworded sentence that wraps is one region and two edits a
/// paragraph apart are two. Boxes that then overlap are merged, so no part
/// of the page is washed twice.
pub fn regionsOf(gpa: std.mem.Allocator, scratch: std.mem.Allocator, tiles: Tiles) ![]Region {
    var found: std.ArrayList(Region) = .empty;
    defer found.deinit(scratch);
    const seen = try scratch.alloc(bool, tiles.marked.len);
    defer scratch.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList([2]u32) = .empty;
    defer stack.deinit(scratch);

    for (0..tiles.rows) |row| for (0..tiles.cols) |col| {
        const start = row * tiles.cols + col;
        if (!tiles.marked[start] or seen[start]) continue;
        seen[start] = true;

        var box: [4]u32 = .{ @intCast(col), @intCast(row), @intCast(col), @intCast(row) };
        try stack.append(scratch, .{ @intCast(col), @intCast(row) });
        while (stack.pop()) |at| {
            box = .{ @min(box[0], at[0]), @min(box[1], at[1]), @max(box[2], at[0]), @max(box[3], at[1]) };
            const r0 = at[1] -| 2;
            const r1 = @min(tiles.rows - 1, at[1] + 2);
            const c0 = at[0] -| 2;
            const c1 = @min(tiles.cols - 1, at[0] + 2);
            var r = r0;
            while (r <= r1) : (r += 1) {
                var c = c0;
                while (c <= c1) : (c += 1) {
                    const i = @as(usize, r) * tiles.cols + c;
                    if (!tiles.marked[i] or seen[i]) continue;
                    seen[i] = true;
                    try stack.append(scratch, .{ c, r });
                }
            }
        }
        try found.append(scratch, .{
            .x0 = box[0] * tile,
            .y0 = box[1] * tile,
            .x1 = (box[2] + 1) * tile,
            .y1 = (box[3] + 1) * tile,
        });
    };

    // Merge until nothing overlaps: a box that grew can reach one already
    // passed over, so a pass that merged anything is followed by another.
    // Components are few, and each merge removes one.
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < found.items.len) : (i += 1) {
            var j = i + 1;
            while (j < found.items.len) {
                if (found.items[i].overlaps(found.items[j])) {
                    found.items[i] = found.items[i].merge(found.swapRemove(j));
                    changed = true;
                } else j += 1;
            }
        }
    }

    std.mem.sort(Region, found.items, {}, Region.readsBefore);
    return gpa.dupe(Region, found.items);
}

/// White paper the size of `like`.
pub fn blank(gpa: std.mem.Allocator, like: Framebuffer) !Framebuffer {
    var fb = try Framebuffer.init(gpa, like.width, like.height, .srgb);
    fb.clear(.white);
    return fb;
}

/// diff-pdf's overlay of two pages: ink only in `a` red, only in `b` blue,
/// and ink both share dark.
///
/// Each document's luminance goes into the channels the other one's colour
/// is not: red is `b`'s paper showing where `a` has ink, blue the other way
/// round, and green is dark wherever either is. Shared ink is dark in all
/// three. With `grayscale`, a pixel within the tolerance is drawn as a grey
/// of `a` instead, so the colour is only where something changed.
pub fn overlay(out: Framebuffer, a: Framebuffer, b: Framebuffer, tolerance: u8, grayscale: bool) void {
    const tol: f32 = @floatFromInt(tolerance);
    for (0..out.height) |yy| for (0..out.width) |xx| {
        const x: u32 = @intCast(xx);
        const y: u32 = @intCast(yy);
        const in_a = x < a.width and y < a.height;
        const in_b = x < b.width and y < b.height;
        const la = if (in_a) luminance(a, x, y) else 1;
        const lb = if (in_b) luminance(b, x, y) else 1;

        const same = in_a and in_b and !pixelDiffers(texel(a, x, y), texel(b, x, y), tol);
        const rgb: [3]f32 = if (grayscale and same)
            @splat(0.5 + 0.5 * la)
        else
            .{ lb, @min(la, lb), la };

        const o = (@as(usize, y) * out.width + x) * 4;
        out.pixels[o..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 1 };
    };
}

/// A change bar down the left margin beside every row of tiles with a
/// difference in it, so a page of small changes shows where to look.
fn markRows(out: Framebuffer, tiles: Tiles, bar: u32) void {
    for (0..tiles.rows) |row| {
        const changed = for (0..tiles.cols) |col| {
            if (tiles.at(@intCast(col), @intCast(row))) break true;
        } else false;
        if (!changed) continue;
        const y0 = row * tile;
        const y1 = @min(out.height, y0 + tile);
        for (y0..y1) |y| for (0..@min(bar, out.width)) |x| {
            out.pixels[(y * out.width + x) * 4 ..][0..4].* = .{ 0.85, 0.1, 0.1, 1 };
        };
    }
}

fn texel(fb: Framebuffer, x: u32, y: u32) *const [4]f32 {
    return fb.pixels[(@as(usize, y) * fb.width + x) * 4 ..][0..4];
}

fn luminance(fb: Framebuffer, x: u32, y: u32) f32 {
    const p = texel(fb, x, y);
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
}

fn pictureName(buf: []u8, pair: Pair) []const u8 {
    return if (pair.a != null and pair.b != null)
        std.fmt.bufPrint(buf, "a{d}-b{d}.png", .{ pair.a.? + 1, pair.b.? + 1 }) catch unreachable
    else if (pair.a) |a|
        std.fmt.bufPrint(buf, "a{d}.png", .{a + 1}) catch unreachable
    else
        std.fmt.bufPrint(buf, "b{d}.png", .{pair.b.? + 1}) catch unreachable;
}

/// One bit per differing pixel, at bit `4 * i` for the `i`th, which is where
/// the four channel bits of each pixel fold down to.
fn chunkMask(a: *const [chunk * 4]f32, b: *const [chunk * 4]f32, tol: f32) u64 {
    const va: Lanes = a.*;
    const vb: Lanes = b.*;
    if (@reduce(.And, va == vb)) return 0;

    const over = @abs(levels(va) - levels(vb)) > @as(Lanes, @splat(tol));
    const bits: u64 = @bitCast(over);
    return (bits | bits >> 1 | bits >> 2 | bits >> 3) & 0x1111_1111_1111_1111;
}

fn levels(v: Lanes) Lanes {
    const clamped = @min(@max(v, @as(Lanes, @splat(0))), @as(Lanes, @splat(1)));
    return @round(clamped * @as(Lanes, @splat(255)));
}

fn pixelDiffers(a: *const [4]f32, b: *const [4]f32, tol: f32) bool {
    for (a, b) |x, y| {
        const lx = @round(std.math.clamp(x, 0, 1) * 255);
        const ly = @round(std.math.clamp(y, 0, 1) * 255);
        if (@abs(lx - ly) > tol) return true;
    }
    return false;
}

// -- time ----------------------------------------------------------------------

/// What `--time` measures, summed over every thread, in nanoseconds.
///
/// Split so the budget can be read off it: the comparison has to be a
/// rounding error beside rendering the two pages it compares, and hashing
/// beside interpreting them.
pub const Timing = struct {
    pairs: u64 = 0,
    drawn: u64 = 0,
    interpret: u64 = 0,
    hash: u64 = 0,
    render: u64 = 0,
    compare: u64 = 0,

    fn add(t: *Timing, o: Timing) void {
        t.pairs += o.pairs;
        t.drawn += o.drawn;
        t.interpret += o.interpret;
        t.hash += o.hash;
        t.render += o.render;
        t.compare += o.compare;
    }

    fn print(t: Timing, ctx: *Context, wall: u64) void {
        ctx.note(
            "time: {d} pairs, {d} drawn  interpret {d:.2}ms  hash {d:.2}  render {d:.2}  compare {d:.2}  wall {d:.2}",
            .{ t.pairs, t.drawn, ms(t.interpret), ms(t.hash), ms(t.render), ms(t.compare), ms(wall) },
        );
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn paper(w: u32, h: u32) !Framebuffer {
    var fb = try Framebuffer.init(testing.allocator, w, h, .srgb);
    fb.clear(.white);
    return fb;
}

fn ink(fb: Framebuffer, x: u32, y: u32, level: f32) void {
    const o = (@as(usize, y) * fb.width + x) * 4;
    fb.pixels[o..][0..3].* = .{ level, level, level };
}

/// The count alone, for the tests that want nothing else.
fn counted(a: Framebuffer, b: Framebuffer, tolerance: u8) !u64 {
    var tiles = try Tiles.init(testing.allocator, @max(a.width, b.width), @max(a.height, b.height));
    defer testing.allocator.free(tiles.marked);
    return countDifferences(a, b, tolerance, &tiles);
}

/// The regions two pages differ in.
fn regionsBetween(a: Framebuffer, b: Framebuffer) ![]Region {
    var tiles = try Tiles.init(testing.allocator, @max(a.width, b.width), @max(a.height, b.height));
    defer testing.allocator.free(tiles.marked);
    _ = countDifferences(a, b, 0, &tiles);
    return regionsOf(testing.allocator, testing.allocator, tiles);
}

test "pages are paired by number, and the longer document's tail stands alone" {
    const pairs = try pairByNumber(testing.allocator, 3, 5);
    defer testing.allocator.free(pairs);
    try testing.expectEqual(@as(usize, 5), pairs.len);
    try testing.expectEqual(Pair{ .a = 2, .b = 2 }, pairs[2]);
    try testing.expectEqual(Pair{ .a = null, .b = 4 }, pairs[4]);
}

test "identical pages have no differing pixels, however wide" {
    // 37 is two whole chunks and a tail, so both loops run.
    var a = try paper(37, 5);
    defer a.deinit(testing.allocator);
    var b = try paper(37, 5);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), try counted(a, b, 0));
}

test "a pixel differs in the vector loop and in the tail alike" {
    var a = try paper(37, 5);
    defer a.deinit(testing.allocator);
    var b = try paper(37, 5);
    defer b.deinit(testing.allocator);
    ink(b, 3, 1, 0); // in the first chunk
    ink(b, 20, 2, 0); // in the second
    ink(b, 35, 4, 0); // in the tail
    try testing.expectEqual(@as(u64, 3), try counted(a, b, 0));
    // Symmetric: which page is first does not matter.
    try testing.expectEqual(@as(u64, 3), try counted(b, a, 0));
}

test "the channel tolerance is in levels of 255, and a float wobble is no level at all" {
    var a = try paper(16, 1);
    defer a.deinit(testing.allocator);
    var b = try paper(16, 1);
    defer b.deinit(testing.allocator);

    // Not bit-equal, but the same eight-bit value: a PNG of either page is
    // the same file, so the pages are the same.
    ink(b, 0, 0, 1.0 - 1e-6);
    try testing.expectEqual(@as(u64, 0), try counted(a, b, 0));

    // Four levels down.
    ink(b, 5, 0, (255.0 - 4.0) / 255.0);
    try testing.expectEqual(@as(u64, 1), try counted(a, b, 0));
    try testing.expectEqual(@as(u64, 1), try counted(a, b, 3));
    try testing.expectEqual(@as(u64, 0), try counted(a, b, 4));
}

test "pages of different sizes differ where only one of them is" {
    var a = try paper(20, 10);
    defer a.deinit(testing.allocator);
    var b = try paper(24, 8);
    defer b.deinit(testing.allocator);
    // Eight rows are 4 pixels wider in b; two rows are in a only, 20 wide;
    // the corner below b and right of a is on neither and does not count.
    try testing.expectEqual(@as(u64, 8 * 4 + 2 * 20), try counted(a, b, 0));
}

test "changes a line apart are one region, and changes far apart are two, in reading order" {
    var a = try paper(200, 200);
    defer a.deinit(testing.allocator);
    var b = try paper(200, 200);
    defer b.deinit(testing.allocator);
    // Two edits a tile and a half apart: one sentence that wrapped.
    ink(b, 20, 20, 0);
    ink(b, 22, 44, 0);
    // One far below and to the right of them, and one above it.
    ink(b, 180, 180, 0);
    ink(b, 150, 100, 0);

    const regions = try regionsBetween(a, b);
    defer testing.allocator.free(regions);
    try testing.expectEqual(@as(usize, 3), regions.len);
    try testing.expectEqual(Region{ .x0 = 16, .y0 = 16, .x1 = 32, .y1 = 48 }, regions[0]);
    try testing.expectEqual(@as(u32, 144), regions[1].x0);
    try testing.expectEqual(@as(u32, 176), regions[2].y0);
}

test "a region is a box in each page's own user space" {
    const r: Region = .{ .x0 = 150, .y0 = 300, .x1 = 300, .y1 = 450 };
    // 150 dpi: a pixel is 72/150 of a point, and y turns upwards from the
    // page's own height.
    const box = r.inPage(150.0 / 72.0, 792);
    try testing.expectApproxEqAbs(@as(f32, 72), box.min_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 792 - 216), box.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 792 - 144), box.max_y, 1e-3);
}

test "a page longer than its partner has its tail marked to the last tile" {
    var a = try paper(20, 14);
    defer a.deinit(testing.allocator);
    var b = try paper(20, 33);
    defer b.deinit(testing.allocator);
    var tiles = try Tiles.init(testing.allocator, 20, 33);
    defer testing.allocator.free(tiles.marked);
    _ = countDifferences(a, b, 0, &tiles);
    // Rows 14..32 are b's alone, and reach into the third row of tiles by
    // one pixel. Stepping a tile at a time from row 14 lands on 14 and 30,
    // and misses it.
    try testing.expect(tiles.at(0, 0) and tiles.at(1, 1));
    try testing.expect(tiles.at(0, 2) and tiles.at(1, 2));
}

test "the overlay: a's ink red, b's blue, both dark, and grey where nothing changed" {
    var a = try paper(3, 1);
    defer a.deinit(testing.allocator);
    var b = try paper(3, 1);
    defer b.deinit(testing.allocator);
    ink(a, 0, 0, 0); // only in a
    ink(b, 1, 0, 0); // only in b
    ink(a, 2, 0, 0); // in both
    ink(b, 2, 0, 0);

    var out = try Framebuffer.init(testing.allocator, 3, 1, .srgb);
    defer out.deinit(testing.allocator);
    overlay(out, a, b, 0, false);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1 }, out.pixels[0..4]);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 1 }, out.pixels[4..8]);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1 }, out.pixels[8..12]);

    // The shared ink is unchanged, so in grey; the changes keep colour.
    overlay(out, a, b, 0, true);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1 }, out.pixels[0..4]);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 1 }, out.pixels[8..12]);
}

test "a page one document has alone sits beside the page before it, and is a change" {
    // Two pages inserted into the second document after its second page.
    const pairs = [_]Pair{
        .{ .a = 0, .b = 0 },
        .{ .a = 1, .b = 1 },
        .{ .a = null, .b = 2 },
        .{ .a = null, .b = 3 },
        .{ .a = 2, .b = 4 },
    };
    var results = [_]Result{
        .{ .kind = .same_list },
        .{ .kind = .differ, .regions = &.{
            .{ .x0 = 0, .y0 = 100, .x1 = 16, .y1 = 116 },
            .{ .x0 = 0, .y0 = 400, .x1 = 16, .y1 = 416 },
        } },
        .{ .kind = .only_b },
        .{ .kind = .only_b },
        .{ .kind = .same_pixels },
    };
    var c: Comparison = try .init(testing.allocator, &pairs, &results, .{ 3, 5 }, .{ .dpi = 144 });
    defer c.deinit();

    try testing.expectEqual(@as(u32, 1), c.partner(1, 2));
    try testing.expectEqual(@as(u32, 1), c.partner(1, 3));
    try testing.expectEqual(@as(u32, 2), c.partner(1, 4));
    try testing.expectEqual(@as(u32, 4), c.partner(0, 2));

    // Two regions and two whole pages, in order.
    try testing.expectEqual(@as(usize, 4), c.changes.len);
    const second = c.changeAt(0, c.changes[1]);
    try testing.expectEqual(@as(u32, 1), second.page);
    try testing.expectEqual(@as(f32, 200), second.down);
    // An inserted page, seen from the document without it.
    try testing.expectEqual(@as(u32, 1), c.changeAt(0, c.changes[3]).page);
    try testing.expectEqual(@as(u32, 3), c.changeAt(1, c.changes[3]).page);
}

test "the second document's regions are moved back by the offset it was compared at" {
    const pairs = [_]Pair{.{ .a = 0, .b = 0 }};
    var results = [_]Result{.{ .kind = .differ, .regions = &.{.{ .x0 = 72, .y0 = 144, .x1 = 144, .y1 = 216 }} }};
    // One pixel a point, and the second document moved 10pt right, 4pt down.
    var c: Comparison = try .init(testing.allocator, &pairs, &results, .{ 1, 1 }, .{ .dpi = 72, .offset = .{ 10, 4 } });
    defer c.deinit();

    const a = c.regionIn(0, results[0].regions[0], 792);
    const b = c.regionIn(1, results[0].regions[0], 792);
    try testing.expectEqual(@as(f32, 72), a.min_x);
    try testing.expectEqual(@as(f32, 62), b.min_x);
    // Down the page is up in user space: moved down 4 is found 4 higher.
    try testing.expectEqual(a.max_y + 4, b.max_y);
    try testing.expectEqual(@as(f32, 144), c.changeAt(0, c.changes[0]).down);
    try testing.expectEqual(@as(f32, 140), c.changeAt(1, c.changes[0]).down);
}

/// A one-page file with a blue rectangle at `x`, and no cross-reference
/// table: the document rebuilds one by scanning.
pub fn rectanglePdf(buf: []u8, x: u32) []const u8 {
    var ops: [64]u8 = undefined;
    const stream = std.fmt.bufPrint(&ops, "0 0 1 rg {d} 400 200 100 re f", .{x}) catch unreachable;
    return std.fmt.bufPrint(buf,
        \\%PDF-1.4
        \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        \\2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        \\3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >> endobj
        \\4 0 obj << /Length {d} >> stream
        \\{s}
        \\endstream endobj
        \\trailer << /Root 1 0 R >>
        \\%%EOF
        \\
    , .{ stream.len, stream }) catch unreachable;
}

test "moving the second document by the offset lines two pages up again" {
    var one: [512]u8 = undefined;
    var two: [512]u8 = undefined;
    // 36pt apart, which at 36 dpi is eighteen whole pixels: moved back by
    // exactly that, every edge falls where the other page's does.
    const bytes: [2][]const u8 = .{ rectanglePdf(&one, 72), rectanglePdf(&two, 108) };
    const pairs = [_]Pair{.{ .a = 0, .b = 0 }};
    var time: Timing = .{};

    const apart = try compare(testing.allocator, testing.io, bytes, &pairs, .{ .dpi = 36 }, &time);
    defer freeResults(testing.allocator, apart);
    try testing.expectEqual(Result.Kind.differ, apart[0].kind);

    const lined = try compare(testing.allocator, testing.io, bytes, &pairs, .{ .dpi = 36, .offset = .{ -36, 0 } }, &time);
    defer freeResults(testing.allocator, lined);
    try testing.expectEqual(Result.Kind.same_pixels, lined[0].kind);
    try testing.expectEqual(@as(u64, 0), lined[0].pixels);
}

test "a comparison made again replaces the results and the changes walked" {
    const gpa = testing.allocator;
    const pairs = [_]Pair{ .{ .a = 0, .b = 0 }, .{ .a = 1, .b = 1 } };
    var first = [_]Result{ .{ .kind = .differ }, .{ .kind = .same_list } };
    var c: Comparison = try .init(gpa, &pairs, &first, .{ 2, 2 }, .{});
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.changes.len);

    // As a thread would hand them over: owned, regions and all.
    const again = try gpa.alloc(Result, 2);
    again[0] = .{ .kind = .same_pixels };
    again[1] = .{ .kind = .differ, .regions = try std.heap.smp_allocator.dupe(Region, &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 16 },
        .{ .x0 = 0, .y0 = 64, .x1 = 16, .y1 = 80 },
    }) };
    try c.replace(again);
    try testing.expectEqual(@as(usize, 2), c.changes.len);
    try testing.expectEqual(@as(u32, 1), c.changes[0].pair);
    try testing.expect(c.owns_results);
}

test "the report lists what differs and counts it" {
    const pairs = [_]Pair{
        .{ .a = 0, .b = 0 },
        .{ .a = 1, .b = 1 },
        .{ .a = 2, .b = 2 },
        .{ .a = null, .b = 3 },
    };
    const results = [_]Result{
        .{ .kind = .same_list },
        .{ .kind = .differ, .pixels = 1204, .regions = &.{ .{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 16 }, .{ .x0 = 0, .y0 = 64, .x1 = 16, .y1 = 80 } } },
        .{ .kind = .same_pixels, .pixels = 3 },
        .{ .kind = .only_b },
    };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report(&out.writer, &pairs, &results, .{ "v1.pdf", "v2.pdf" }, 12, .{});
    try testing.expectEqualStrings(
        \\page  2 ≠  2    1,204 px in 2 regions
        \\page  4 +       only in v2.pdf
        \\2 of 4 pages differ
        \\
    , out.written());

    out.clearRetainingCapacity();
    try report(&out.writer, pairs[0..1], results[0..1], .{ "v1.pdf", "v2.pdf" }, 1, .{ .skip_identical = false });
    try testing.expectEqualStrings("page 1 = 1    same display list\n0 of 1 pages differ\n", out.written());
}

test "counts are grouped by thousands" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", grouped(0, &buf));
    try testing.expectEqualStrings("999", grouped(999, &buf));
    try testing.expectEqualStrings("1,204", grouped(1204, &buf));
    try testing.expectEqualStrings("12,345,678", grouped(12_345_678, &buf));
}
