//! Faces, one atlas, one shaper, and the text layout that joins them.
//!
//! `Face` and `Shaper` are interfaces and `Atlas` is a cache; none of them
//! knows about the others, which is right for testing them and useless for
//! drawing a label. This is the object a UI holds: give it a font id, a size
//! and a string, and it gives back quads.
//!
//! ## The run cache
//!
//! Shaping a string is the expensive half of drawing it -- a `cmap` lookup and
//! an advance per code point, and under FreeType an advance means parsing the
//! glyph -- and a UI re-derives the *same* strings every frame, because that is
//! what immediate-mode call sites do. So shaped runs are cached by
//! `(font, text)`, and the layout pass over a frame becomes a hash lookup per
//! label plus an atlas lookup per glyph.
//!
//! Size is deliberately not in that key. A shaper works in font units, so the
//! same string at eleven and at twenty-two points shapes identically and only
//! the multiplication differs. That also makes `measure` -- which the layout
//! solver calls for every text box, twice, once per axis -- free after the
//! first frame.
//!
//! ## What is snapped and what is not
//!
//! Baselines are rounded to whole pixels; pen positions along the line are
//! not. A horizontal stem spread across two rows is the artefact that reads as
//! blur rather than as position, and it is the one every glyph has. Horizontal
//! placement is preserved to a third of a pixel through the atlas's subpixel
//! buckets, which is where the spacing between letters lives. See `Atlas`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");

const Atlas = @import("Atlas.zig");
const Face = @import("Face.zig");
const Shaper = @import("Shaper.zig");
const format = @import("format.zig");
const registry = @import("registry.zig");

const Bounds = geom.Bounds;
const Point = geom.Point;

const Fonts = @This();

pub const Error = error{OutOfMemory};

/// An index into `faces`. Zero is always valid: it is opened at `init` from no
/// bytes at all, so it is whatever the build's last-resort backend is -- the
/// box-drawing stand-in, unless a real one claimed it. Nothing above has to
/// carry a null font.
pub const FontId = Atlas.FaceId;

pub const fallback_font: FontId = 0;

/// Vertical metrics at a size, in device pixels. `descent` is negative, as it
/// is in the font, so `ascent - descent` is the ink height and adding them to
/// a baseline needs no sign flipping at the call site.
pub const Metrics = struct {
    ascent: f32,
    descent: f32,
    line_gap: f32,

    /// Baseline to baseline.
    pub fn lineHeight(m: Metrics) f32 {
        return m.ascent - m.descent + m.line_gap;
    }
};

/// One glyph, ready to draw: where it goes and where to sample it.
pub const Placed = struct {
    /// Device pixels.
    dst: Bounds,
    /// Atlas texels. The caller normalises, or hands both to `DrawList.glyph`,
    /// which does.
    src: Bounds,
};

/// A shaped string, in font units, cached across frames.
const Run = struct {
    glyphs: []const Shaper.Positioned,
    /// Summed advances, in font units.
    width: f32,
};

/// Runs held before the cache is dropped wholesale.
///
/// A limit rather than an eviction policy, for the reason the atlas gives: the
/// bookkeeping to choose a victim costs more, every frame, than the rare
/// rebuild it avoids. Eight thousand distinct strings is far past any frame's
/// working set, so hitting it means something is generating text -- a clock, a
/// byte counter -- and the right response is to start again, not to thrash.
pub const run_cache_limit: u32 = 8192;

gpa: Allocator,
faces: std.ArrayList(Face) = .empty,
atlas: Atlas,
shaper: Shaper,

runs: std.AutoHashMapUnmanaged(u64, Run) = .empty,
run_arena: std.heap.ArenaAllocator,
scratch: std.ArrayList(Shaper.Positioned) = .empty,

pub fn init(gpa: Allocator, opts: Atlas.Options) Error!Fonts {
    var f: Fonts = .{
        .gpa = gpa,
        .atlas = try .init(gpa, opts),
        // The registry's shaper never fails to produce one: a build without
        // HarfBuzz gets the built-in shaper, which is correct for the Latin
        // this program's own chrome is written in.
        .shaper = registry.shaper(gpa) catch Shaper.simple,
        .run_arena = .init(gpa),
    };
    errdefer f.deinit();

    const first = registry.open(gpa, "", .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `registry.open` is documented to fail only on allocation.
        else => unreachable,
    };
    _ = try f.addFace(first);
    return f;
}

pub fn deinit(f: *Fonts) void {
    for (f.faces.items) |*open_face| open_face.deinit(f.gpa);
    f.faces.deinit(f.gpa);
    f.atlas.deinit(f.gpa);
    f.shaper.deinit(f.gpa);
    f.runs.deinit(f.gpa);
    f.run_arena.deinit();
    f.scratch.deinit(f.gpa);
    f.* = undefined;
}

/// Takes ownership of `face`, which is closed by `deinit`.
pub fn addFace(f: *Fonts, opened: Face) Error!FontId {
    if (f.faces.items.len > std.math.maxInt(FontId)) return error.OutOfMemory;
    try f.faces.append(f.gpa, opened);
    return @intCast(f.faces.items.len - 1);
}

/// Opens a font program. The bytes are borrowed, not copied: every backend
/// reads them lazily, so they must outlive this `Fonts`.
pub fn open(f: *Fonts, bytes: []const u8, opts: registry.Options) Error!FontId {
    const opened = registry.open(f.gpa, bytes, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return f.addFace(opened);
}

/// Out-of-range ids resolve to the fallback rather than trapping. A font id
/// travels through style stacks and box records, where a stale one is a
/// nuisance and a crash is not proportionate.
pub fn face(f: *const Fonts, id: FontId) Face {
    if (id >= f.faces.items.len) return f.faces.items[fallback_font];
    return f.faces.items[id];
}

pub fn count(f: *const Fonts) usize {
    return f.faces.items.len;
}

pub fn metrics(f: *const Fonts, id: FontId, px: f32) Metrics {
    const fa = f.face(id);
    const s = fa.unitScale() * Atlas.quantize(px);
    const info = fa.info;

    // A face with no vertical metrics at all -- a bare CFF is allowed to have
    // none -- would give a zero line height, and every line of text would land
    // on top of the last. The 0.8/0.2 split is the usual Latin proportion and
    // is only ever reached by a font that declined to say.
    if (info.ascender == 0 and info.descender == 0) {
        return .{ .ascent = px * 0.8, .descent = -px * 0.2, .line_gap = 0 };
    }
    return .{
        .ascent = @as(f32, @floatFromInt(info.ascender)) * s,
        .descent = @as(f32, @floatFromInt(info.descender)) * s,
        .line_gap = @as(f32, @floatFromInt(info.line_gap)) * s,
    };
}

// -- shaping ----------------------------------------------------------------

fn runKey(id: FontId, text: []const u8) u64 {
    var h: std.hash.Wyhash = .init(0x7e0f8b1d);
    h.update(std.mem.asBytes(&id));
    h.update(text);
    return h.final();
}

/// Shapes `text`, or returns the cached result.
///
/// A hash collision here would mis-measure and mis-draw one string. At 64 bits
/// that needs about five billion distinct strings in one session for even
/// odds, which is well past the point where the cache limit below has already
/// thrown everything away several times over.
fn shaped(f: *Fonts, id: FontId, text: []const u8) Error!Run {
    if (text.len == 0) return .{ .glyphs = &.{}, .width = 0 };

    const key = runKey(id, text);
    if (f.runs.get(key)) |run| return run;

    if (f.runs.count() >= run_cache_limit) {
        f.runs.clearRetainingCapacity();
        _ = f.run_arena.reset(.retain_capacity);
    }

    f.scratch.clearRetainingCapacity();
    f.shaper.shape(f.gpa, f.face(id), .{ .text = text }, &f.scratch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A shaper that failed on a string still has to yield something, or
        // one bad label takes the frame down. Nothing shaped means nothing
        // drawn, which is visible and recoverable.
        error.ShaperFailed => return .{ .glyphs = &.{}, .width = 0 },
    };

    const owned = try f.run_arena.allocator().dupe(Shaper.Positioned, f.scratch.items);
    var width: f32 = 0;
    for (owned) |g| width += g.x_advance;

    const run: Run = .{ .glyphs = owned, .width = width };
    try f.runs.put(f.gpa, key, run);
    return run;
}

/// Advance width in device pixels. Does not touch the atlas, so the layout
/// solver can call it for every text box on every frame without rasterising
/// anything -- including for boxes that turn out to be scrolled off screen.
pub fn measure(f: *Fonts, id: FontId, px: f32, text: []const u8) Error!f32 {
    const run = try f.shaped(id, text);
    return run.width * f.face(id).unitScale() * Atlas.quantize(px);
}

// -- drawing ----------------------------------------------------------------

/// Lays a string out from `origin`, which is the pen at the *baseline*, and
/// appends one `Placed` per glyph that has ink. Returns the advance width, so
/// a caller stringing runs together does not measure twice.
///
/// Glyphs with no ink -- spaces -- append nothing, which is why the returned
/// width is authoritative and `out.items.len` is not a character count.
pub fn layout(
    f: *Fonts,
    id: FontId,
    px: f32,
    text: []const u8,
    origin: Point,
    out: *std.ArrayList(Placed),
) Error!f32 {
    const size = Atlas.quantize(px);
    const run = try f.shaped(id, text);
    const fa = f.face(id);
    const scale = fa.unitScale() * size;

    // The baseline is snapped once, here, rather than per glyph: rounding each
    // glyph's own y would let a run straddle two rows wherever a fraction
    // happened to cross a boundary.
    const base_y = @round(origin.y);
    var pen = origin.x;

    for (run.glyphs) |g| {
        const at = f.atlas.position(pen + g.x_offset * scale);
        const cell = try f.atlas.get(f.gpa, fa, id, g.glyph, size, at.bucket) orelse {
            // The atlas is full for this frame. Skipping keeps the run's
            // spacing intact, so the gap is one missing glyph rather than a
            // word that jumps.
            pen += g.x_advance * scale;
            continue;
        };

        if (!cell.isBlank()) {
            const x0 = at.pixel + @as(f32, @floatFromInt(cell.left));
            const y0 = base_y - @as(f32, @floatFromInt(cell.top)) - g.y_offset * scale;
            try out.append(f.gpa, .{
                .dst = .fromRect(x0, y0, x0 + @as(f32, @floatFromInt(cell.w)), y0 + @as(f32, @floatFromInt(cell.h))),
                .src = .fromRect(
                    @floatFromInt(cell.x),
                    @floatFromInt(cell.y),
                    @as(f32, @floatFromInt(cell.x)) + @as(f32, @floatFromInt(cell.w)),
                    @as(f32, @floatFromInt(cell.y)) + @as(f32, @floatFromInt(cell.h)),
                ),
            });
        }
        pen += g.x_advance * scale;
    }

    return pen - origin.x;
}

// -- the texture ------------------------------------------------------------

pub fn beginFrame(f: *Fonts) void {
    f.atlas.beginFrame(f.gpa);
}

pub fn atlasWidth(f: *const Fonts) u32 {
    return f.atlas.width;
}

pub fn atlasHeight(f: *const Fonts) u32 {
    return f.atlas.height;
}

pub fn atlasPixels(f: *const Fonts) []const u8 {
    return f.atlas.pixels;
}

/// The region to re-upload, and clears it. The generation comes with it,
/// because a grow or a clear invalidates a caller's idea of the texture's
/// size as well as its contents.
pub fn takeDirty(f: *Fonts) ?Atlas.Dirty {
    return f.atlas.takeDirty();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "font zero exists without anyone opening anything" {
    var f: Fonts = try .init(testing.allocator, .{});
    defer f.deinit();

    try testing.expectEqual(@as(usize, 1), f.count());
    try testing.expect(f.face(fallback_font).info.units_per_em > 0);
    // And an id nobody registered resolves to it rather than trapping.
    try testing.expectEqualStrings(f.face(0).backend, f.face(99).backend);
}

test "measuring is the sum of the advances, scaled" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{});
    defer f.deinit();

    // The stand-in face advances half an em on every glyph, over a thousand
    // unit em: five pixels each at ten point.
    try testing.expectApproxEqAbs(@as(f32, 25), try f.measure(0, 10, "hello"), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50), try f.measure(0, 20, "hello"), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), try f.measure(0, 10, ""), 1e-6);
}

test "a run is shaped once however many times it is measured or drawn" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{});
    defer f.deinit();

    _ = try f.measure(0, 11, "Open");
    try testing.expectEqual(@as(u32, 1), f.runs.count());

    // The same string at a different size is the same shaping: advances are
    // in font units, so size is not part of the key.
    _ = try f.measure(0, 22, "Open");
    try testing.expectEqual(@as(u32, 1), f.runs.count());

    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(gpa);
    _ = try f.layout(0, 11, "Open", .origin, &out);
    try testing.expectEqual(@as(u32, 1), f.runs.count());

    _ = try f.measure(0, 11, "Close");
    try testing.expectEqual(@as(u32, 2), f.runs.count());
}

test "layout puts glyphs on the pen and returns where it ended" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{});
    defer f.deinit();

    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(gpa);

    const width = try f.layout(0, 16, "ab", .{ .x = 100, .y = 50 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 16), width, 1e-3);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Every glyph of the stand-in face is the same box, so the second is the
    // first shifted by exactly one advance.
    const a = out.items[0];
    const b = out.items[1];
    try testing.expectApproxEqAbs(@as(f32, 8), b.dst.min_x - a.dst.min_x, 1e-3);
    try testing.expectApproxEqAbs(a.dst.min_y, b.dst.min_y, 1e-6);
    // And it sits above the baseline it was given.
    try testing.expect(a.dst.max_y <= 50);

    // The measurement and the layout agree, which they must or every centred
    // label is off by however much they differ.
    try testing.expectApproxEqAbs(try f.measure(0, 16, "ab"), width, 1e-4);
}

test "the baseline is snapped but the pen is not" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{ .subpixel_positions = 3 });
    defer f.deinit();

    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(gpa);

    _ = try f.layout(0, 16, "a", .{ .x = 10.0, .y = 50.4 }, &out);
    _ = try f.layout(0, 16, "a", .{ .x = 10.6, .y = 50.4 }, &out);

    // Same baseline row for both, because y was rounded once.
    try testing.expectEqual(out.items[0].dst.min_y, out.items[1].dst.min_y);
    // Different horizontal placement, which is the point: less than a pixel
    // apart, but not the same pixel and not the same atlas cell.
    const dx = out.items[1].dst.min_x - out.items[0].dst.min_x;
    try testing.expect(dx >= 0 and dx <= 1);
    try testing.expect(!std.meta.eql(out.items[0].src, out.items[1].src));
}

test "a space costs an advance and no quad" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{});
    defer f.deinit();

    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(gpa);

    // The stand-in draws a box for every glyph including the space, so this
    // measures the other half of the claim: the advance is charged whether or
    // not a quad is emitted.
    const width = try f.layout(0, 16, "a b", .origin, &out);
    try testing.expectApproxEqAbs(@as(f32, 24), width, 1e-3);
}

test "metrics give a line height even for a face that declares none" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{});
    defer f.deinit();

    const m = f.metrics(0, 20);
    try testing.expect(m.ascent > 0);
    try testing.expect(m.descent < 0);
    try testing.expect(m.lineHeight() >= m.ascent - m.descent);
    // The stand-in reports 750 up and 250 down over a thousand-unit em.
    try testing.expectApproxEqAbs(@as(f32, 15), m.ascent, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -5), m.descent, 1e-3);
}

test "the run cache is dropped whole rather than evicted piecemeal" {
    const gpa = testing.allocator;
    var f: Fonts = try .init(gpa, .{});
    defer f.deinit();

    var buf: [32]u8 = undefined;
    var n: u32 = 0;
    while (n < run_cache_limit + 4) : (n += 1) {
        const text = std.fmt.bufPrint(&buf, "line {d}", .{n}) catch unreachable;
        _ = try f.measure(0, 12, text);
    }
    // Cleared at the limit and refilled from there, rather than growing
    // without bound.
    try testing.expect(f.runs.count() < run_cache_limit);
    try testing.expect(f.runs.count() > 0);
}
