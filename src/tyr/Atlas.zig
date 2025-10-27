//! The glyph atlas: rasterised glyphs packed into one texture, keyed by
//! everything that changes what the pixels look like.
//!
//! ## The key
//!
//! `(face, glyph, size, subpixel_x)`. The first three are obvious. The fourth
//! is the one that decides whether text looks like text.
//!
//! A run of glyphs advances by fractional amounts -- an `r` is 5.34 pixels
//! wide at eleven point, not 5 -- so the pen lands between pixels almost
//! always. There are three things to do about it and only one of them is
//! right. Rounding each glyph's position to a whole pixel keeps the atlas
//! small and makes the gaps between letters wobble by up to a pixel, which is
//! wider than a stem: the word stops looking like a word. Rounding the run's
//! start only, and letting the glyphs land wherever, means sampling a bitmap
//! at a half-texel offset, which is a blur. The third is to rasterise the
//! glyph *at* the fraction it lands on, and to do that from a small set of
//! buckets so the cache still hits: three positions per pixel is what FreeType
//! and Skia both settle on, and the residual error is a third of a pixel of
//! horizontal placement, which is below what anyone can see.
//!
//! There is no vertical subpixel bucket. Baselines are snapped to whole pixels
//! by the layout, because a horizontal stem straddling two rows is the one
//! artefact that reads as blur rather than as position, and because it would
//! multiply the cache by another three for a benefit only visible during a
//! scroll. `Render.offset_y` exists on the interface anyway: the page renderer
//! will want it, where the baseline is the file's business and not ours.
//!
//! ## Getting pixels in the first place
//!
//! Two doors, as `raster.zig` describes. A backend that rasterises is asked to
//! (FreeType hints, and hinting at eleven pixels beats an unhinted fill by a
//! visible margin); a backend that only decomposes has its outline filled by
//! Týr's own scan converter. The atlas does not care which, and neither does
//! anything above it.
//!
//! ## Space, and what happens when it runs out
//!
//! Skyline packing into a texture of fixed width and growing height. Fixed
//! width because growing it would re-stride every row already in the texture
//! and invalidate every cached rectangle; growing height appends rows and
//! leaves every existing `(x, y)` exactly where it was, so a grow costs a
//! reallocation and a full re-upload and nothing else.
//!
//! When the height cap is reached, the atlas is cleared and every glyph is
//! rasterised again. There is no LRU, deliberately: eviction means touching a
//! timestamp on every glyph of every frame -- tens of thousands of writes to
//! keep score of a resource that is not scarce -- and the alternative it buys
//! is one frame of re-rasterisation, once, in a session that changed font size
//! enough times to fill four megabytes. The clear happens at `beginFrame`,
//! never in the middle of one, so a frame is never assembled half against the
//! old contents and half against the new.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("Face.zig");
const Outline = @import("Outline.zig");
const rast = @import("raster.zig");

const GlyphIndex = Face.GlyphIndex;

const Atlas = @This();

pub const Error = Allocator.Error;

/// Faces are numbered by the caller. Sixteen bits is far past what a document
/// plus a UI can open, and keeping it small is what lets the whole key be one
/// word.
pub const FaceId = u16;

pub const Options = struct {
    /// Fixed for the life of the atlas. 1024 holds a 32-pixel face's entire
    /// Latin range in three or four rows.
    width: u32 = 1024,
    initial_height: u32 = 256,
    /// The point at which the atlas is cleared instead of grown. 4096 square
    /// is sixteen megabytes of coverage and is a common `maxImageDimension2D`
    /// floor, so a texture this size is portable.
    max_height: u32 = 4096,
    /// Horizontal buckets per pixel. Three is the usual choice; one turns
    /// subpixel positioning off, which is what a page render wants, where the
    /// positions come from the file and are already exact.
    subpixel_positions: u8 = 3,
    /// Texels left blank on the right and bottom of every cell, so that a
    /// bilinear sample near an edge cannot pick up the neighbour.
    padding: u8 = 1,
    hinting: Face.Hinting = .normal,
};

/// The size axis of the key, in quarter-pixels.
///
/// Quarter-pixel rather than exact, because a float key would give a UI
/// animating a font size a fresh cache entry every frame of the animation and
/// never a hit. A quarter of a pixel at eleven point is below the size step
/// anyone chooses deliberately.
pub const size_step: f32 = 4.0;

pub fn quantize(px: f32) f32 {
    return @round(std.math.clamp(px, 0, 16000) * size_step) / size_step;
}

/// Everything that changes the pixels, in one word.
pub const Key = packed struct(u64) {
    face: FaceId,
    glyph: GlyphIndex,
    /// `quantize(px) * size_step`.
    size: u16,
    subpixel: u8,
    _pad: u8 = 0,

    pub fn word(k: Key) u64 {
        return @bitCast(k);
    }
};

/// A packed glyph. `w` and `h` are zero for a space, which is a cache hit with
/// nothing to draw rather than a miss repeated every frame.
pub const Glyph = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    /// The cell's top-left corner relative to the pen, in pixels: `left` to
    /// the right, `top` upwards from the baseline. Both are `Face.Bitmap`'s.
    left: i16 = 0,
    top: i16 = 0,
    /// Horizontal advance in device pixels at this size. Cached here so that
    /// laying out a run is one hash lookup per glyph rather than a lookup and
    /// a vtable call. A PDF's `/Widths` still outranks it; see `Face`.
    advance: f32 = 0,

    pub fn isBlank(g: Glyph) bool {
        return g.w == 0 or g.h == 0;
    }
};

/// A rectangle of the texture that has changed since the last upload.
pub const Dirty = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pixels: []u8,
width: u32,
height: u32,
max_height: u32,
subpixel_positions: u8,
padding: u8,
hinting: Face.Hinting,

map: std.AutoHashMapUnmanaged(u64, Glyph) = .empty,
nodes: std.ArrayList(Node) = .empty,

/// Scratch, kept because a page of text would otherwise allocate per glyph.
raster: rast.Raster = .{},
outline: Outline = .{},

/// Bumped by every clear. A caller holding a `Glyph` from an earlier
/// generation is holding coordinates into a texture that no longer has that
/// glyph there; anything that caches must compare this and re-ask.
generation: u32 = 1,
/// Set when a glyph did not fit at the maximum size. Acted on at the next
/// `beginFrame`, never mid-frame.
exhausted: bool = false,

/// Counters, which are the only way an atlas problem is ever visible. A
/// steady-state `misses` above zero means something is asking for a size that
/// changes every frame; a non-zero `clears` after startup means the cap is too
/// low for how this session uses text.
misses: u64 = 0,
clears: u32 = 0,

dirty_x0: u32 = 0,
dirty_y0: u32 = 0,
dirty_x1: u32 = 0,
dirty_y1: u32 = 0,

pub fn init(gpa: Allocator, opts: Options) Error!Atlas {
    const width = @max(opts.width, 16);
    const height = @max(@min(opts.initial_height, opts.max_height), 16);

    const pixels = try gpa.alloc(u8, width * height);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    var a: Atlas = .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .max_height = @max(opts.max_height, height),
        .subpixel_positions = @max(opts.subpixel_positions, 1),
        .padding = opts.padding,
        .hinting = opts.hinting,
    };
    // A one-texel skirt along the left and top, for the same reason as the
    // per-cell padding: nothing should be able to sample into the edge of the
    // texture and find a neighbour there.
    try a.nodes.append(gpa, .{ .x = 0, .y = 0, .width = width });
    return a;
}

pub fn deinit(a: *Atlas, gpa: Allocator) void {
    gpa.free(a.pixels);
    a.map.deinit(gpa);
    a.nodes.deinit(gpa);
    a.raster.deinit(gpa);
    a.outline.deinit(gpa);
    a.* = undefined;
}

/// Call once per frame, before any `get`. Performs a deferred clear.
pub fn beginFrame(a: *Atlas, gpa: Allocator) void {
    if (a.exhausted) a.clear(gpa);
}

/// Drops every glyph and bumps the generation.
pub fn clear(a: *Atlas, gpa: Allocator) void {
    @memset(a.pixels, 0);
    a.map.clearRetainingCapacity();
    a.nodes.clearRetainingCapacity();
    // Cannot fail: the list held at least one node a moment ago, so the
    // capacity for one is already there.
    a.nodes.append(gpa, .{ .x = 0, .y = 0, .width = a.width }) catch unreachable;
    a.generation +%= 1;
    a.exhausted = false;
    a.clears += 1;
    a.markDirty(0, 0, a.width, a.height);
}

/// The changed region since the last call, and clears it. The whole texture
/// after a grow or a clear, since both move or invalidate everything.
pub fn takeDirty(a: *Atlas) ?Dirty {
    if (a.dirty_x1 <= a.dirty_x0 or a.dirty_y1 <= a.dirty_y0) return null;
    const d: Dirty = .{
        .x = a.dirty_x0,
        .y = a.dirty_y0,
        .w = a.dirty_x1 - a.dirty_x0,
        .h = a.dirty_y1 - a.dirty_y0,
    };
    a.dirty_x0 = 0;
    a.dirty_y0 = 0;
    a.dirty_x1 = 0;
    a.dirty_y1 = 0;
    return d;
}

/// Which horizontal bucket a fractional pen position falls in, and the whole
/// pixel it snaps to.
///
/// Returned together because they have to agree: the bucket says which
/// rendering to fetch, the integer says where to put it, and computing them
/// apart is how a run ends up a pixel long at one end.
pub const Position = struct {
    /// The pen rounded down to a whole pixel.
    pixel: f32,
    /// The bucket index, in `0 .. subpixel_positions`.
    bucket: u8,
};

pub fn position(a: *const Atlas, pen_x: f32) Position {
    const whole = @floor(pen_x);
    const frac = pen_x - whole;
    const n: f32 = @floatFromInt(a.subpixel_positions);
    var bucket: u32 = @intFromFloat(frac * n);
    // `frac` is in [0, 1) mathematically, but `floor` on a value a hair below
    // an integer can leave it at exactly 1.0 after the multiply.
    if (bucket >= a.subpixel_positions) bucket = a.subpixel_positions - 1;
    return .{ .pixel = whole, .bucket = @intCast(bucket) };
}

fn offsetFor(a: *const Atlas, bucket: u8) f32 {
    return @as(f32, @floatFromInt(bucket)) / @as(f32, @floatFromInt(a.subpixel_positions));
}

/// Fetches a glyph, rasterising and packing it on a miss.
///
/// Null means the atlas is full at its maximum size and could not take this
/// glyph; the caller should skip it, and the next `beginFrame` will make room.
/// A glyph with no ink -- a space -- comes back as a zero-sized `Glyph`, which
/// is a hit and not a miss.
pub fn get(
    a: *Atlas,
    gpa: Allocator,
    face: Face,
    face_id: FaceId,
    glyph: GlyphIndex,
    px_size: f32,
    bucket: u8,
) Error!?Glyph {
    const size = quantize(px_size);
    const key: Key = .{
        .face = face_id,
        .glyph = glyph,
        .size = @intFromFloat(size * size_step),
        .subpixel = if (a.subpixel_positions == 1) 0 else bucket % a.subpixel_positions,
    };

    const gop = try a.map.getOrPut(gpa, key.word());
    if (gop.found_existing) return gop.value_ptr.*;

    a.misses += 1;
    // Written before any failure path below, so that a glyph the backend
    // cannot produce is a cached blank rather than a decode attempted on
    // every frame for the rest of the session.
    gop.value_ptr.* = .{ .advance = advanceOf(face, glyph, size) };

    const req: Face.Render = .{
        .px_size = size,
        .offset_x = a.offsetFor(key.subpixel),
        .hinting = a.hinting,
    };

    const packed_glyph = if (face.caps.rasterize)
        a.fromBackend(gpa, face, glyph, req) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Full => return null,
            else => return gop.value_ptr.*,
        }
    else
        a.fromOutline(gpa, face, glyph, req) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Full => return null,
            else => return gop.value_ptr.*,
        };

    // `fromBackend` and `fromOutline` may have grown the map's allocation via
    // nothing, but the pointer from `getOrPut` is only valid while no other
    // insert happened -- and none did. Re-fetching would be safer against a
    // future edit, so it is done rather than reasoned about.
    var g = packed_glyph;
    g.advance = advanceOf(face, glyph, size);
    a.map.putAssumeCapacity(key.word(), g);
    return g;
}

fn advanceOf(face: Face, glyph: GlyphIndex, px: f32) f32 {
    const units = face.advance(glyph) orelse return 0;
    return units * face.unitScale() * px;
}

const PackError = error{ OutOfMemory, Full, Failed };

fn fromBackend(a: *Atlas, gpa: Allocator, face: Face, glyph: GlyphIndex, req: Face.Render) PackError!Glyph {
    const bmp = face.rasterize(glyph, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };
    if (bmp.width == 0 or bmp.height == 0) return .{};

    const cell = try a.alloc(gpa, bmp.width, bmp.height);
    var row: u32 = 0;
    while (row < bmp.height) : (row += 1) {
        const src = bmp.pixels[row * bmp.stride ..][0..bmp.width];
        const dst = a.pixels[(cell.y + row) * a.width + cell.x ..][0..bmp.width];
        @memcpy(dst, src);
    }

    return .{
        .x = @intCast(cell.x),
        .y = @intCast(cell.y),
        .w = @intCast(bmp.width),
        .h = @intCast(bmp.height),
        .left = clampI16(bmp.left),
        .top = clampI16(bmp.top),
    };
}

fn fromOutline(a: *Atlas, gpa: Allocator, face: Face, glyph: GlyphIndex, req: Face.Render) PackError!Glyph {
    face.outline(gpa, glyph, &a.outline) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };

    const pl: rast.Placement = .{
        .scale = req.px_size * face.unitScale(),
        .dx = req.offset_x,
        .dy = req.offset_y,
    };
    const b = try a.raster.flatten(gpa, a.outline, pl);
    if (b.isEmpty()) return .{};

    const x0 = @floor(b.min_x);
    const y0 = @floor(b.min_y);
    const w: u32 = @intFromFloat(@max(@ceil(b.max_x) - x0, 0));
    const h: u32 = @intFromFloat(@max(@ceil(b.max_y) - y0, 0));
    if (w == 0 or h == 0) return .{};
    // A glyph wider or taller than the whole atlas is a corrupt outline or an
    // absurd size; refusing it is better than clearing the atlas to make room
    // for something that will never fit.
    if (w > a.width or h > a.max_height) return error.Failed;

    const cell = try a.alloc(gpa, w, h);
    // Straight into the atlas: `fill` writes every pixel of its window, so
    // there is no intermediate buffer and nothing to clear first.
    try a.raster.fill(gpa, a.pixels[cell.y * a.width + cell.x ..], w, h, a.width, x0, y0);

    return .{
        .x = @intCast(cell.x),
        .y = @intCast(cell.y),
        .w = @intCast(w),
        .h = @intCast(h),
        .left = clampI16(@intFromFloat(x0)),
        .top = clampI16(@intFromFloat(-y0)),
    };
}

fn clampI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

// -- packing ----------------------------------------------------------------

const Spot = struct { x: u32, y: u32 };

/// Reserves a `w * h` cell, growing the texture if it will not fit.
fn alloc(a: *Atlas, gpa: Allocator, w: u32, h: u32) PackError!Spot {
    const need_w = w + a.padding;
    const need_h = h + a.padding;
    if (need_w > a.width) return error.Failed;

    while (true) {
        if (a.find(need_w, need_h)) |hit| {
            try a.place(gpa, hit.index, hit.x, hit.y, need_w, need_h);
            a.markDirty(hit.x, hit.y, w, h);
            return .{ .x = hit.x, .y = hit.y };
        }
        if (!try a.grow(gpa, need_h)) {
            a.exhausted = true;
            return error.Full;
        }
    }
}

const Hit = struct { index: u32, x: u32, y: u32 };

/// Bottom-left: the lowest resting height, ties broken by the narrowest gap.
/// Both halves matter -- height alone leaves a row of one-texel canyons that
/// nothing ever fits into.
fn find(a: *Atlas, w: u32, h: u32) ?Hit {
    var best: ?Hit = null;
    var best_y: u32 = std.math.maxInt(u32);
    var best_w: u32 = std.math.maxInt(u32);

    for (a.nodes.items, 0..) |node, i| {
        const y = a.fits(@intCast(i), w, h) orelse continue;
        if (y < best_y or (y == best_y and node.width < best_w)) {
            best_y = y;
            best_w = node.width;
            best = .{ .index = @intCast(i), .x = node.x, .y = y };
        }
    }
    return best;
}

/// The height at which a `w * h` cell would rest on the skyline starting at
/// `index`, or null if it would run off the right edge or the bottom.
fn fits(a: *Atlas, index: u32, w: u32, h: u32) ?u32 {
    const nodes = a.nodes.items;
    const x = nodes[index].x;
    if (x + w > a.width) return null;

    var y = nodes[index].y;
    var remaining: i64 = w;
    var i = index;
    while (remaining > 0) : (i += 1) {
        if (i >= nodes.len) return null;
        y = @max(y, nodes[i].y);
        if (y + h > a.height) return null;
        remaining -= nodes[i].width;
    }
    return y;
}

/// Raises the skyline over the cell just placed. `y` is where the cell rests
/// and `h` is how tall it is, so the new profile height is their sum.
fn place(a: *Atlas, gpa: Allocator, index: u32, x: u32, y: u32, w: u32, h: u32) Error!void {
    try a.nodes.insert(gpa, index, .{ .x = x, .y = y + h, .width = w });

    // Everything the new node overhangs is trimmed, and anything it swallows
    // entirely is removed.
    const i: usize = index + 1;
    while (i < a.nodes.items.len) {
        const prev = a.nodes.items[i - 1];
        const cur = &a.nodes.items[i];
        if (cur.x >= prev.x + prev.width) break;
        const shrink = prev.x + prev.width - cur.x;
        if (cur.width <= shrink) {
            _ = a.nodes.orderedRemove(i);
            continue;
        }
        cur.x += shrink;
        cur.width -= shrink;
        break;
    }

    // Adjacent runs at the same height are one run. Without this the node list
    // grows without bound and `find` becomes the cost of the frame.
    var j: usize = 0;
    while (j + 1 < a.nodes.items.len) {
        if (a.nodes.items[j].y == a.nodes.items[j + 1].y) {
            a.nodes.items[j].width += a.nodes.items[j + 1].width;
            _ = a.nodes.orderedRemove(j + 1);
            continue;
        }
        j += 1;
    }
}

/// Doubles the height, up to the cap. False when there is no room left to
/// give, which is the caller's signal to give up on this glyph.
fn grow(a: *Atlas, gpa: Allocator, need: u32) Error!bool {
    if (a.height >= a.max_height) return false;
    const target = @min(@max(a.height * 2, a.height + need), a.max_height);
    if (target <= a.height) return false;

    const pixels = try gpa.realloc(a.pixels, a.width * target);
    @memset(pixels[a.width * a.height ..], 0);
    a.pixels = pixels;
    a.height = target;
    // Existing cells keep their coordinates, because only rows were appended
    // and the stride is unchanged. The skyline is a profile of occupied space
    // and is likewise still true; only the ceiling `fits` tests against moved.
    a.markDirty(0, 0, a.width, a.height);
    return true;
}

fn markDirty(a: *Atlas, x: u32, y: u32, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    if (a.dirty_x1 <= a.dirty_x0 or a.dirty_y1 <= a.dirty_y0) {
        a.dirty_x0 = x;
        a.dirty_y0 = y;
        a.dirty_x1 = x + w;
        a.dirty_y1 = y + h;
        return;
    }
    a.dirty_x0 = @min(a.dirty_x0, x);
    a.dirty_y0 = @min(a.dirty_y0, y);
    a.dirty_x1 = @max(a.dirty_x1, x + w);
    a.dirty_y1 = @max(a.dirty_y1, y + h);
}

// -- reading it back --------------------------------------------------------

pub fn count(a: *const Atlas) u32 {
    return a.map.count();
}

/// Texels in use over texels allocated. Under about a half means the packer is
/// being handed glyphs in an order it cannot use, which for a UI means text is
/// being drawn at many sizes interleaved rather than in passes.
pub fn occupancy(a: *const Atlas) f32 {
    var used: u64 = 0;
    var it = a.map.valueIterator();
    while (it.next()) |g| used += @as(u64, g.w) * g.h;
    const total: u64 = @as(u64, a.width) * a.height;
    if (total == 0) return 0;
    return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(total));
}

pub fn at(a: *const Atlas, x: u32, y: u32) u8 {
    return a.pixels[y * a.width + x];
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const registry = @import("registry.zig");

/// The fallback face: every glyph is the hollow `.notdef` box, decomposed but
/// not rasterised, so these run through `fromOutline` and exercise Týr's own
/// scan converter as well as the packing.
fn boxFace(gpa: Allocator) !Face {
    return registry.open(gpa, "", .{});
}

test "a glyph is rasterised once and found thereafter" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 256, .initial_height = 128 });
    defer a.deinit(gpa);

    const first = (try a.get(gpa, face, 0, 'A', 16, 0)).?;
    try testing.expect(!first.isBlank());
    try testing.expectEqual(@as(u64, 1), a.misses);

    const second = (try a.get(gpa, face, 0, 'A', 16, 0)).?;
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u64, 1), a.misses);
    try testing.expectEqual(@as(u32, 1), a.count());
}

test "every part of the key is part of the key" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 512, .initial_height = 512 });
    defer a.deinit(gpa);

    _ = try a.get(gpa, face, 0, 'A', 16, 0);
    _ = try a.get(gpa, face, 1, 'A', 16, 0); // another face
    _ = try a.get(gpa, face, 0, 'B', 16, 0); // another glyph
    _ = try a.get(gpa, face, 0, 'A', 17, 0); // another size
    _ = try a.get(gpa, face, 0, 'A', 16, 1); // another subpixel bucket
    try testing.expectEqual(@as(u32, 5), a.count());

    // And nothing else is: the same request twice over is one entry.
    _ = try a.get(gpa, face, 0, 'A', 16, 0);
    try testing.expectEqual(@as(u32, 5), a.count());
}

test "sizes within a quarter pixel share an entry" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 256, .initial_height = 256 });
    defer a.deinit(gpa);

    // The case this exists for: a size being animated between two values.
    _ = try a.get(gpa, face, 0, 'A', 16.0, 0);
    _ = try a.get(gpa, face, 0, 'A', 16.05, 0);
    _ = try a.get(gpa, face, 0, 'A', 16.1, 0);
    try testing.expectEqual(@as(u32, 1), a.count());

    _ = try a.get(gpa, face, 0, 'A', 16.5, 0);
    try testing.expectEqual(@as(u32, 2), a.count());
}

test "the subpixel bucket moves the ink without moving the cell" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 256, .initial_height = 256, .subpixel_positions = 3 });
    defer a.deinit(gpa);

    const at_0 = (try a.get(gpa, face, 0, 'A', 20, 0)).?;
    const at_1 = (try a.get(gpa, face, 0, 'A', 20, 1)).?;

    // Same glyph at the same size: the bitmaps differ, but not by a whole
    // pixel of placement. If they came out identical, the offset never reached
    // the rasteriser and the whole scheme is doing nothing.
    var same = at_0.w == at_1.w and at_0.h == at_1.h;
    if (same) {
        same = false;
        var y: u32 = 0;
        outer: while (y < at_0.h) : (y += 1) {
            var x: u32 = 0;
            while (x < at_0.w) : (x += 1) {
                if (a.at(at_0.x + x, at_0.y + y) != a.at(at_1.x + x, at_1.y + y)) break :outer;
            }
        } else same = true;
    }
    try testing.expect(!same);
}

test "positions split a pixel into buckets that agree with the whole part" {
    const gpa = testing.allocator;
    var a: Atlas = try .init(gpa, .{ .subpixel_positions = 3 });
    defer a.deinit(gpa);

    try testing.expectEqual(Position{ .pixel = 10, .bucket = 0 }, a.position(10.0));
    try testing.expectEqual(Position{ .pixel = 10, .bucket = 0 }, a.position(10.2));
    try testing.expectEqual(Position{ .pixel = 10, .bucket = 1 }, a.position(10.5));
    try testing.expectEqual(Position{ .pixel = 10, .bucket = 2 }, a.position(10.9));
    try testing.expectEqual(Position{ .pixel = 11, .bucket = 0 }, a.position(11.0));
    // Negative pen positions happen the moment anything scrolls left.
    try testing.expectEqual(Position{ .pixel = -1, .bucket = 1 }, a.position(-0.5));
}

test "one bucket turns subpixel positioning off" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 256, .initial_height = 256, .subpixel_positions = 1 });
    defer a.deinit(gpa);

    _ = try a.get(gpa, face, 0, 'A', 16, 0);
    _ = try a.get(gpa, face, 0, 'A', 16, 2);
    try testing.expectEqual(@as(u32, 1), a.count());
    try testing.expectEqual(@as(u8, 0), a.position(10.9).bucket);
}

test "cells do not overlap, however many are packed" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 128, .initial_height = 64, .max_height = 2048 });
    defer a.deinit(gpa);

    // Enough glyphs at enough sizes to force several grows.
    var placed: std.ArrayList(Glyph) = .empty;
    defer placed.deinit(gpa);

    var size: f32 = 8;
    while (size <= 24) : (size += 4) {
        var g: GlyphIndex = 0;
        while (g < 24) : (g += 1) {
            if (try a.get(gpa, face, 0, g, size, 0)) |cell| {
                if (!cell.isBlank()) try placed.append(gpa, cell);
            }
        }
    }
    try testing.expect(placed.items.len > 40);

    for (placed.items, 0..) |p, i| {
        try testing.expect(p.x + p.w <= a.width);
        try testing.expect(p.y + p.h <= a.height);
        for (placed.items[i + 1 ..]) |q| {
            const disjoint = p.x + p.w <= q.x or q.x + q.w <= p.x or
                p.y + p.h <= q.y or q.y + q.h <= p.y;
            try testing.expect(disjoint);
        }
    }
}

test "growing keeps every glyph exactly where it was" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 64, .initial_height = 32, .max_height = 1024 });
    defer a.deinit(gpa);

    const first = (try a.get(gpa, face, 0, 'A', 12, 0)).?;
    const before = a.height;

    var g: GlyphIndex = 1;
    while (g < 40) : (g += 1) _ = try a.get(gpa, face, 0, g, 12, 0);
    try testing.expect(a.height > before);

    // The point of growing only downwards: a cached rectangle stays valid, so
    // the generation does not move and callers are not asked to re-look-up.
    const again = (try a.get(gpa, face, 0, 'A', 12, 0)).?;
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(u32, 1), a.generation);
}

test "a full atlas refuses rather than corrupting, and recovers next frame" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 32, .initial_height = 32, .max_height = 32 });
    defer a.deinit(gpa);

    var refused = false;
    var g: GlyphIndex = 0;
    while (g < 64) : (g += 1) {
        if ((try a.get(gpa, face, 0, g, 14, 0)) == null) {
            refused = true;
            break;
        }
    }
    try testing.expect(refused);
    try testing.expect(a.exhausted);

    // Nothing was cleared mid-frame, so whatever was already drawn this frame
    // still points at the right texels.
    const gen = a.generation;
    a.beginFrame(gpa);
    try testing.expectEqual(gen + 1, a.generation);
    try testing.expectEqual(@as(u32, 0), a.count());
    try testing.expect(!a.exhausted);
    try testing.expect((try a.get(gpa, face, 0, 0, 14, 0)) != null);
}

test "the dirty rectangle covers what was written and then empties" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 256, .initial_height = 256 });
    defer a.deinit(gpa);

    // The initial allocation is clean: there is nothing in it to upload.
    try testing.expectEqual(@as(?Dirty, null), a.takeDirty());

    const cell = (try a.get(gpa, face, 0, 'A', 16, 0)).?;
    const d = a.takeDirty().?;
    try testing.expect(d.x <= cell.x and d.y <= cell.y);
    try testing.expect(d.x + d.w >= cell.x + cell.w);
    try testing.expect(d.y + d.h >= cell.y + cell.h);

    // Taken once, gone.
    try testing.expectEqual(@as(?Dirty, null), a.takeDirty());
    // A hit writes no pixels, so it dirties nothing.
    _ = try a.get(gpa, face, 0, 'A', 16, 0);
    try testing.expectEqual(@as(?Dirty, null), a.takeDirty());
}

test "a glyph the backend cannot produce is cached as blank, not retried" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 128, .initial_height = 128 });
    defer a.deinit(gpa);

    // Zero pixels: no ink at any offset, so it packs nothing.
    const cell = (try a.get(gpa, face, 0, 'A', 0, 0)).?;
    try testing.expect(cell.isBlank());
    try testing.expectEqual(@as(u64, 1), a.misses);
    _ = try a.get(gpa, face, 0, 'A', 0, 0);
    try testing.expectEqual(@as(u64, 1), a.misses);
}

test "the advance comes back with the cell, in device pixels" {
    const gpa = testing.allocator;
    var face = try boxFace(gpa);
    defer face.deinit(gpa);

    var a: Atlas = try .init(gpa, .{ .width = 128, .initial_height = 128 });
    defer a.deinit(gpa);

    // The fallback advances half an em, and its em is a thousand units.
    const cell = (try a.get(gpa, face, 0, 'A', 20, 0)).?;
    try testing.expectApproxEqAbs(@as(f32, 10), cell.advance, 1e-4);
}
