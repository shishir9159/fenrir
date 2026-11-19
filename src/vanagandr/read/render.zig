//! Pages, from a job to something that can be drawn: the rasterising
//! thread and what it is asked for, the cache of what it made on either
//! backend, and the GPU's placement of what is cached.
//!
//! With the frame loop this is the reader's hot path, and it is one file for
//! that reason: every frame asks it what is missing, collects what the worker
//! finished, and places what is on screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const glyphmod = @import("../glyphs.zig");
const Images = @import("../images.zig").Images;
const watch = @import("../watch.zig");
const Session = @import("Session.zig");
const compare = @import("compare.zig");
const plugins_mod = @import("plugins.zig");
const reload = @import("reload.zig");
const search_mod = @import("search.zig");

const content = fenrir.content;
const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const hlidskjalf = fenrir.hlidskjalf;
const lyngvi = fenrir.lyngvi;
const replay = gleipnir.replay;

const DrawList = gleipnir.DrawList;
const Glyphs = glyphmod.Fonts;
const Scene = gleipnir.scene.Scene;

const Buffer = hlidskjalf.Buffer;
const View = hlidskjalf.View;
const text = hlidskjalf.text;

const caps = fenrir.build_options;
const min_zoom = View.min_zoom;

pub const Backend = enum { cpu, gpu };

/// How many rendered pages to keep. Two per window at a sensible zoom, plus
/// room to scroll back without re-rendering, and at four bytes a pixel it is
/// tens of megabytes rather than hundreds.
pub const cache_slots = 12;

/// A ceiling on one page's texture, matching `fenrir raster`. A page that
/// wants more than this at the requested zoom is rendered at whatever zoom
/// does fit rather than refused, because refusing means a blank window.
pub const max_page_pixels: u64 = 64 << 20;

/// How the reader interprets a page: as `raster` does, less the annotations
/// it took as marks at open (`readAnnots`). It draws those itself, where they
/// can be recoloured and stepped through, and with their appearances in the
/// pixels too every one would be on screen twice.
///
/// A build with no marks takes none, and leaves every annotation in the
/// page: a highlight made in Acrobat is still on the page, drawn as `raster`
/// draws it, rather than taken out and drawn by nothing.
pub const page_options: content.Options = .{ .taken = if (caps.marks) fenrir.annots.taken else null };

/// One rendered page, on the device and in the display list's numbering.
///
/// `gpu` and `list` are the same number by construction -- both registries
/// hand out ids in creation order and both are only added to here -- but the
/// two mean different things, so they are kept apart and asserted equal rather
/// than assumed to be one field.
pub const Slot = struct {
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

    pub const no_page = std.math.maxInt(u32);

    fn matches(s: Slot, buffer: u32, page: u32, zoom: f32, overlay: bool) bool {
        return s.buffer == buffer and s.page == page and s.zoom == zoom and s.overlay == overlay;
    }
};

pub const Image = struct { pixels: []u8, width: u32, height: u32 };

/// The pages recorded for the GPU pipeline.
///
/// One `Scene` holds the outlines of every cached page, so they go to the
/// device as one set of buffers; `ranges` says which instances belong to
/// which page. Recording is in *page space*, with no zoom and no scroll baked
/// in, which is what makes a scroll cost a matrix per instance rather than a
/// re-record -- and what lets two windows at different zooms share one
/// recording.
pub const Recorded = struct {
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

    pub fn rebuild(rc: *Recorded, gpa: Allocator) Allocator.Error!void {
        rc.scene.reset(.{ 1, 1 });
        for (&rc.pages) |*e| {
            if (e.source) |src| e.range = try rc.scene.merge(gpa, src);
        }
    }

    pub fn touch(rc: *Recorded, buffer: u32, page: u32) void {
        for (&rc.pages) |*e| {
            if (e.buffer == buffer and e.page == page) e.used = rc.stamp;
        }
    }
};

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
/// at the top of `read.zig`. One job in flight and one waiting, with the
/// waiting one replaced rather than queued: if the loop has asked for three
/// pages while this thread rendered one, the third is the one on screen now
/// and the other two are behind the scroll.
pub const Rasteriser = struct {
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
            cpu: Image,
            gpu: Scene,
        };
    };

    pub fn start(rz: *Rasteriser) !void {
        rz.thread = try std.Thread.spawn(.{}, work, .{rz});
    }

    /// Asks the worker to stop and waits for it. The worker may be halfway
    /// through a page; it finishes that page rather than being interrupted,
    /// because there is no safe point inside a rasterisation to stop at and
    /// a page is a bounded amount of work.
    pub fn stop(rz: *Rasteriser) void {
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
            discard(rz.session, f);
            rz.done = null;
        }
    }

    pub fn post(rz: *Rasteriser, job: Job) void {
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
            produce(rz.session, job, &finished) catch {};

            rz.mutex.lockUncancelable(rz.io);
            rz.busy = null;
            rz.done = finished;
            rz.change.signal(rz.io);
            rz.mutex.unlock(rz.io);
        }
    }
};

// -- work --------------------------------------------------------------------

/// One job's worth of work, on the rasterising thread, in whichever form
/// this backend wants it -- plus the page's text map, since both come out
/// of one interpretation.
pub fn produce(s: *Session, job: Job, out: *Rasteriser.Finished) !void {
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
        .cpu => .{ .cpu = try rasterise(s, job, result.list, b) },
        // No zoom in it: the outline is recorded in page space and the
        // frame loop places it. That is the whole reason a zoom on the
        // GPU path is instant and on the CPU path is a re-render.
        .gpu => .{ .gpu = try recordPage(s, job, result.list, b) },
    };
}

/// Frees a finished job the frame loop is not going to use.
pub fn discard(s: *Session, f: *Rasteriser.Finished) void {
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

pub fn noteFailure(s: *Session, job: Job) void {
    s.failures[s.failure_next] = job;
    s.failure_next = (s.failure_next + 1) % s.failures.len;
}

/// One page, rasterised. The same calls `fenrir raster` makes, which is
/// why the two produce identical images.
///
/// **Runs on the rasterising thread.** The zoom comes from the job rather
/// than from the view, because a view belongs to the frame loop and can
/// change underneath this at any moment.
pub fn rasterise(s: *Session, job: Job, list: gelgja.DisplayList, b: *Buffer) !Image {
    var canvas = try drawCanvas(s, job.buffer, job.page, list, job.zoom, .{ 0, 0 }, b);
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

// -- the cache ---------------------------------------------------------------

/// Whether a page is ready to draw for a given view.
///
/// The two backends disagree about what "at this zoom" means, and that
/// difference is the whole point of the GPU one: a rasterised page is
/// pixels at one scale and a recorded one is curves at every scale, so a
/// zoom throws away the CPU cache and leaves the GPU cache untouched --
/// and two windows at two zooms need two CPU entries and one GPU entry.
pub fn cached(s: *const Session, v: *const View, page: u32) bool {
    // An overlay is pixels on either backend: see `rasteriseOverlay`.
    if (compare.overlaid(s, v)) return cachedSlot(s, v.buffer, page, v.zoom, true) != null;
    return switch (s.backend) {
        .cpu => cachedSlot(s, v.buffer, page, v.zoom, false) != null,
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

pub fn slotFor(s: *Session, buf: u32, page: u32, zoom: f32, overlay: bool) ?*Slot {
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
    if (missingIn(s, s.layout().current())) |job| return job;
    var it = s.layout().iterator();
    while (it.next()) |v| {
        if (missingIn(s, v)) |job| return job;
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
pub fn nextJob(s: *Session) ?Job {
    if (firstMissing(s)) |job| return job;
    if (!hasSpareSlot(s)) return null;

    // Only once nothing on screen is outstanding: a page just off the
    // edge must never be rendered ahead of one the reader is looking at,
    // or a split would sit on blank paper while the worker filled a page
    // nobody can see.
    if (aheadIn(s, s.layout().current())) |job| return job;
    var it = s.layout().iterator();
    while (it.next()) |v| {
        if (aheadIn(s, v)) |job| return job;
    }

    // Last of all, and deliberately: a search over six hundred pages is
    // six hundred interpretations, and a reader who scrolls while it
    // runs must not wait behind a page they cannot see. The scan gets
    // whatever is left over, one page at a time, and stops the instant
    // something on screen is missing.
    return if (caps.search) search_mod.searchJob(s) else null;
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
        if (failed(s, job)) continue;
        if (!cached(s, v, after)) return job;
    }

    var back: u32 = 0;
    while (back < read_ahead and back < range.first) : (back += 1) {
        const page = range.first - 1 - back;
        const job: Job = .{ .buffer = v.buffer, .page = page, .zoom = v.zoom, .want = compare.pixelsFor(s, v), .shift = compare.shiftFor(s, v) };
        if (failed(s, job)) continue;
        if (!cached(s, v, page)) return job;
    }
    return null;
}

fn missingIn(s: *Session, v: *View) ?Job {
    const range = v.visiblePages();
    var i = range.first;
    while (i < range.end) : (i += 1) {
        const job: Job = .{ .buffer = v.buffer, .page = i, .zoom = v.zoom, .want = compare.pixelsFor(s, v), .shift = compare.shiftFor(s, v) };
        if (failed(s, job)) continue;
        if (!cached(s, v, i)) return job;
    }
    // The cursor needs a text map even for a page whose pixels are
    // already cached -- a window that has not moved since the map was
    // evicted would otherwise have a cursor that cannot cross a page.
    if (v.cursor.visible and !s.buffer(v.buffer).hasMap(v.cursor.page)) {
        const job: Job = .{ .buffer = v.buffer, .page = v.cursor.page, .zoom = v.zoom };
        if (!failed(s, job)) return job;
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
            if (!failed(s, job)) return job;
        }
    }
    return null;
}

/// Takes whatever the rasterising thread finished and puts it away,
/// returning the pixel buffer the caller must keep alive until the frame
/// has been submitted -- `Upload.pixels` is read during `frame`.
pub fn collectPage(
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
        reload.install(s, finished.job.buffer, outcome);
        return null;
    }

    if (caps.search and finished.job.want == .text) {
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
        reload.placeStale(s, finished.job.buffer, finished.job.page);
    }

    const result = finished.result orelse {
        // A page that will not interpret is a blank page, not a dead
        // reader. Remembering that it failed is what stops the loop
        // asking for it again on every frame for the rest of the session.
        noteFailure(s, finished.job);
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
    if (!wantedNow(s, finished.job)) {
        gpa.free(image.pixels);
        return null;
    }

    // A page read again goes where its old pixels are, which were drawn
    // until now: nothing draws blank paper over a page it has.
    const slot = if (slotFor(s, finished.job.buffer, finished.job.page, finished.job.zoom, finished.job.want == .overlay)) |old|
        try resize(renderer, list, old, image.width, image.height)
    else
        try claim(s, renderer, list, image.width, image.height);
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

// -- the paths on the device -------------------------------------------------

/// Everything the GPU placement depends on, hashed: if this has not
/// changed, the instances on the device are still right.
///
/// Compared rather than invalidated by hand: a `dirty` flag has to be set
/// in every place that moves a view, and the one place it is forgotten is
/// a window that stops following its own scroll.
pub fn placementKey(s: *Session) u64 {
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
pub fn placeVisible(s: *Session) !void {
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

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const windows = @import("windows.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const sessionOf = fixtures.sessionOf;

test "every window's visible pages are asked for, focused window first" {
    if (!caps.splits) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [64]fenrir.Page = undefined;
    // Half scale, so two pages fit at once.
    var s = try sessionOf(gpa, fakePages(&buf, 40), 0.5, 1000, 800);
    defer closeSession(&s);

    s.view().scrollToPage(20);
    windows.splitWindow(&s, .vertical);
    s.view().scrollToPage(4);

    // The focused window is the one that just scrolled to page 4.
    try testing.expectEqual(@as(u32, 4), firstMissing(&s).?.page);

    // With that cached, the rest of the focused window, then the other one.
    s.slots[0] = .{ .buffer = 0, .page = 4, .zoom = s.view().zoom, .gpu = 1, .list = 1 };
    const next = firstMissing(&s).?;
    try testing.expect(next.page == 5 or next.page == 20);
}

test "two windows at different zooms need two rasters and one recording" {
    // The difference between the backends, as a test: the CPU cache is keyed
    // by zoom because its contents are pixels, and the GPU cache is not
    // because its contents are curves.
    if (!caps.splits) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 6), 1, 1000, 800);
    defer closeSession(&s);

    windows.splitWindow(&s, .vertical);
    s.view().setZoom(2);

    const a = s.layout().viewAt(0);
    const b = s.layout().viewAt(1);
    try testing.expect(a.zoom != b.zoom);

    s.backend = .cpu;
    s.slots[0] = .{ .buffer = 0, .page = 0, .zoom = a.zoom, .gpu = 1, .list = 1 };
    try testing.expect(cached(&s, a, 0));
    try testing.expect(!cached(&s, b, 0));

    s.backend = .gpu;
    s.recorded.pages[0] = .{ .buffer = 0, .page = 0, .source = .{} };
    try testing.expect(cached(&s, a, 0));
    try testing.expect(cached(&s, b, 0));
    s.recorded.pages[0].source = null;
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

    try testing.expect(wantedNow(&s, .{ .buffer = 0, .page = 0, .zoom = 1 }));
    // Nobody is looking at this document at this zoom any more.
    try testing.expect(!wantedNow(&s, .{ .buffer = 0, .page = 0, .zoom = 3.5 }));
    try testing.expect(!wantedNow(&s, .{ .buffer = 9, .page = 0, .zoom = 1 }));
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

    try testing.expectEqual(@as(u32, 0), firstMissing(&s).?.page);
    noteFailure(&s, .{ .buffer = 0, .page = 0, .zoom = s.view().zoom });
    try testing.expectEqual(@as(u32, 1), firstMissing(&s).?.page);

    // The failure is remembered per zoom, because a page that ran out of
    // memory at one scale may well fit at another.
    s.view().zoom = 0.25;
    try testing.expectEqual(@as(u32, 0), firstMissing(&s).?.page);
}
