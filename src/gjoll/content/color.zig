//! Colour spaces (§8.6), resolved down to RGBA.
//!
//! Gelgja's `paint.zig` explains the trade this module implements: colour
//! arrives at the display list already converted, because running a tint
//! transform needs the document and nothing about running it needs the device.
//! The cost is that a print backend cannot recover the original ink, and the
//! benefit is that a `/Separation` fill is one `Color` by the time anything
//! has to draw it.
//!
//! Eight kinds, which is all of them:
//!
//! - `DeviceGray`, `DeviceRGB`, `DeviceCMYK` -- the three that need no
//!   document at all.
//! - `CalGray`, `CalRGB` -- treated as their device equivalents. The
//!   calibration data describes a monitor from 1998 and every reader ignores
//!   it.
//! - `ICCBased` -- an embedded profile, used for its `/N` and its
//!   `/Alternate`. Actually applying the profile needs a colour management
//!   engine, which is a project rather than a function.
//! - `Lab` -- converted through XYZ to sRGB, because nothing else can.
//! - `Indexed` -- a palette, whose entries are in some other space.
//! - `Separation`, `DeviceN` -- one or more inks, with a function that says
//!   what they look like in a space that can be displayed. This is the case
//!   that makes `function.zig` necessary.
//! - `Pattern` -- not a colour at all; the interpreter handles it, and this
//!   module only records that the space is one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("../Document.zig");
const function = @import("function.zig");
const object = @import("../object.zig");
const paint = @import("../../gelgja/paint.zig");

const Color = paint.Color;
const Dict = object.Dict;
const Function = function.Function;
const Object = object.Object;

pub const Error = Document.Error;

/// The most components any space has. `DeviceN` allows 32 colorants; nothing
/// real uses more than a dozen.
pub const max_components = 32;

/// How deep `/Indexed [/Separation ... [/ICCBased ...]]` may nest before we
/// decide the file is playing games.
const max_depth = 8;

pub const Kind = enum {
    gray,
    rgb,
    cmyk,
    lab,
    indexed,
    separation,
    pattern,

    pub fn opName(k: Kind) []const u8 {
        return @tagName(k);
    }
};

pub const ColorSpace = struct {
    kind: Kind,
    /// How many operands `sc`/`scn` expects.
    components: u8,

    /// `/Indexed`: the space the palette entries are in, and the palette.
    /// `/Pattern`: the underlying space for an uncoloured pattern, if any.
    base: ?*const ColorSpace = null,
    lookup: []const u8 = &.{},
    hival: u32 = 0,

    /// `/Separation` and `/DeviceN`: the tint transform and where it lands.
    tint: []const Function = &.{},
    alternate: ?*const ColorSpace = null,
    /// `/Separation /None` marks nothing at all (§8.6.6.4). Not the same as
    /// painting white, and files use it to suppress plates.
    marks_nothing: bool = false,

    /// `/Lab`: the white point and the a/b ranges.
    white: [3]f64 = .{ 0.9505, 1.0, 1.089 },
    range: [4]f64 = .{ -100, 100, -100, 100 },

    pub const device_gray: ColorSpace = .{ .kind = .gray, .components = 1 };
    pub const device_rgb: ColorSpace = .{ .kind = .rgb, .components = 3 };
    pub const device_cmyk: ColorSpace = .{ .kind = .cmyk, .components = 4 };

    /// The colour a space starts at when `cs` selects it (§8.6.8): black in
    /// every device space, the first palette entry for `/Indexed`, and full
    /// tint for `/Separation`.
    pub fn initial(cs: ColorSpace, out: *[max_components]f64) []const f64 {
        const n = @min(cs.components, max_components);
        switch (cs.kind) {
            .separation => @memset(out[0..n], 1),
            .lab => {
                out[0] = 0;
                out[1] = 0;
                out[2] = 0;
            },
            else => @memset(out[0..n], 0),
        }
        return out[0..n];
    }

    /// Converts components to RGBA. Never fails: a space whose transform is
    /// missing produces a defensible approximation rather than a hole in the
    /// page.
    pub fn toColor(cs: *const ColorSpace, comps: []const f64) Color {
        return cs.toColorDepth(comps, 0);
    }

    fn toColorDepth(cs: *const ColorSpace, comps: []const f64, depth: u8) Color {
        if (depth > max_depth) return .black;

        return switch (cs.kind) {
            .gray => .gray(@floatCast(clamp01(at(comps, 0)))),
            .rgb => .rgb(
                @floatCast(clamp01(at(comps, 0))),
                @floatCast(clamp01(at(comps, 1))),
                @floatCast(clamp01(at(comps, 2))),
            ),
            .cmyk => .fromCmyk(
                @floatCast(clamp01(at(comps, 0))),
                @floatCast(clamp01(at(comps, 1))),
                @floatCast(clamp01(at(comps, 2))),
                @floatCast(clamp01(at(comps, 3))),
            ),
            .lab => labToRgb(cs, at(comps, 0), at(comps, 1), at(comps, 2)),
            .indexed => cs.indexedToColor(at(comps, 0), depth),
            .separation => cs.separationToColor(comps, depth),
            // A pattern's colour comes from its content stream, not from
            // here. Grey is what a backend paints while it works that out.
            .pattern => .gray(0.5),
        };
    }

    fn indexedToColor(cs: *const ColorSpace, index: f64, depth: u8) Color {
        const base = cs.base orelse return .black;
        const n = @min(base.components, max_components);
        if (n == 0) return .black;

        const i: u32 = @intFromFloat(std.math.clamp(@round(index), 0, @as(f64, @floatFromInt(cs.hival))));
        const offset = @as(usize, i) * n;

        var comps: [max_components]f64 = undefined;
        for (0..n) |c| {
            const byte: f64 = if (offset + c < cs.lookup.len)
                @floatFromInt(cs.lookup[offset + c])
            else
                0;
            // Palette bytes are 0..255 across the component's own range,
            // which is 0..1 everywhere except Lab.
            const bounds = base.componentRange(@intCast(c));
            comps[c] = bounds[0] + byte * (bounds[1] - bounds[0]) / 255.0;
        }
        return base.toColorDepth(comps[0..n], depth + 1);
    }

    fn separationToColor(cs: *const ColorSpace, comps: []const f64, depth: u8) Color {
        if (cs.marks_nothing) return .transparent;

        if (cs.alternate) |alt| {
            if (cs.tint.len != 0) {
                var out: [max_components]f64 = @splat(0);
                const n = @min(alt.components, max_components);
                // Every component, not just the first: a `/DeviceN` arrives
                // here with all of its inks and the transform takes one
                // input per ink.
                const produced = function.evalCombined(cs.tint, comps, out[0..n]);
                if (produced.len != 0) return alt.toColorDepth(produced, depth + 1);
            }
        }

        // No usable transform. One ink at full tint is dark and at no tint is
        // white, which is true of every ink that exists, so the tint itself is
        // the best available guess at its own darkness.
        var darkest: f64 = 0;
        for (comps) |c| darkest = @max(darkest, clamp01(c));
        return .gray(@floatCast(1 - darkest));
    }

    /// The legal range of one component, which is 0..1 except in `Lab`.
    pub fn componentRange(cs: *const ColorSpace, i: u8) [2]f64 {
        if (cs.kind == .lab) {
            return switch (i) {
                0 => .{ 0, 100 },
                1 => .{ cs.range[0], cs.range[1] },
                2 => .{ cs.range[2], cs.range[3] },
                else => .{ 0, 1 },
            };
        }
        if (cs.kind == .indexed) return .{ 0, @floatFromInt(cs.hival) };
        return .{ 0, 1 };
    }

    /// True when `scn` may be given a name instead of numbers.
    pub fn isPattern(cs: *const ColorSpace) bool {
        return cs.kind == .pattern;
    }
};

fn at(comps: []const f64, i: usize) f64 {
    return if (i < comps.len) comps[i] else 0;
}

fn clamp01(v: f64) f64 {
    if (!std.math.isFinite(v)) return 0;
    return std.math.clamp(v, 0, 1);
}

/// CIE L*a*b* through XYZ to sRGB, with the sRGB transfer curve applied.
///
/// This is the only colour conversion here that is actually correct, which is
/// a little funny given that `Lab` is the rarest of the eight.
fn labToRgb(cs: *const ColorSpace, l_in: f64, a_in: f64, b_in: f64) Color {
    const l = std.math.clamp(l_in, 0, 100);
    const a = std.math.clamp(a_in, cs.range[0], cs.range[1]);
    const b = std.math.clamp(b_in, cs.range[2], cs.range[3]);

    const m = (l + 16) / 116;
    const x = cs.white[0] * labInverse(m + a / 500);
    const y = cs.white[1] * labInverse(m);
    const z = cs.white[2] * labInverse(m - b / 200);

    const r = 3.2406 * x - 1.5372 * y - 0.4986 * z;
    const g = -0.9689 * x + 1.8758 * y + 0.0415 * z;
    const bl = 0.0557 * x - 0.2040 * y + 1.0570 * z;

    return .rgb(
        @floatCast(clamp01(srgbGamma(r))),
        @floatCast(clamp01(srgbGamma(g))),
        @floatCast(clamp01(srgbGamma(bl))),
    );
}

fn labInverse(t: f64) f64 {
    // The linear segment near black; without it, dark colours quantise.
    return if (t > 6.0 / 29.0) t * t * t else 3 * (6.0 / 29.0) * (6.0 / 29.0) * (t - 4.0 / 29.0);
}

fn srgbGamma(v: f64) f64 {
    if (v <= 0.0031308) return 12.92 * v;
    return 1.055 * std.math.pow(f64, @max(v, 0), 1.0 / 2.4) - 0.055;
}

// -- loading ----------------------------------------------------------------

/// Resolves a colour-space object: a name, or an array whose first element is
/// a name. Names that are not device spaces are looked up in the page's
/// `/ColorSpace` resources, which is how `cs` selects anything interesting.
///
/// Null when the object is not a colour space at all. The caller substitutes
/// `DeviceGray`, per §8.6.8's rule that an unrecognised space leaves the
/// previous one in place -- but a fill still has to happen.
pub fn load(
    arena: Allocator,
    doc: *Document,
    obj: Object,
    resources: ?Dict,
    depth: u8,
) Error!?ColorSpace {
    if (depth > max_depth) return null;
    const resolved = try doc.resolve(obj);

    if (resolved.asName()) |name| {
        if (byName(name)) |cs| return cs;
        // Not a device space, so it must be a resource.
        const table = resources orelse return null;
        const entry = try doc.get(table, "ColorSpace") orelse return null;
        const dict = entry.asDict() orelse return null;
        const found = try doc.get(dict, name) orelse return null;
        return load(arena, doc, found, resources, depth + 1);
    }

    const list = resolved.asArray() orelse return null;
    if (list.len == 0) return null;

    const head = (try doc.resolve(list[0])).asName() orelse return null;

    // A one-element array is just the name in it, which producers write for
    // `[/DeviceRGB]` and for `[/Pattern]`.
    if (list.len == 1) {
        if (byName(head)) |cs| return cs;
        return load(arena, doc, list[0], resources, depth + 1);
    }

    if (eq(head, "ICCBased")) return try iccBased(arena, doc, list[1], resources, depth);
    if (eq(head, "Indexed") or eq(head, "I")) return try indexed(arena, doc, list, resources, depth);
    if (eq(head, "Separation")) return try separation(arena, doc, list, resources, depth, 1);
    if (eq(head, "DeviceN")) return try deviceN(arena, doc, list, resources, depth);
    if (eq(head, "CalRGB")) return .device_rgb;
    if (eq(head, "CalGray")) return .device_gray;
    if (eq(head, "CalCMYK")) return .device_cmyk;
    if (eq(head, "Lab")) return try lab(doc, list[1]);
    if (eq(head, "Pattern")) return try pattern(arena, doc, list[1], resources, depth);
    if (eq(head, "DeviceGray") or eq(head, "DeviceRGB") or eq(head, "DeviceCMYK")) {
        return byName(head);
    }

    return null;
}

/// The device spaces and the abbreviations inline images use (§8.9.7).
fn byName(name: []const u8) ?ColorSpace {
    if (eq(name, "DeviceGray") or eq(name, "G") or eq(name, "CalGray")) return .device_gray;
    if (eq(name, "DeviceRGB") or eq(name, "RGB") or eq(name, "CalRGB")) return .device_rgb;
    if (eq(name, "DeviceCMYK") or eq(name, "CMYK")) return .device_cmyk;
    if (eq(name, "Pattern")) return .{ .kind = .pattern, .components = 1 };
    return null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn iccBased(
    arena: Allocator,
    doc: *Document,
    obj: Object,
    resources: ?Dict,
    depth: u8,
) Error!?ColorSpace {
    const resolved = try doc.resolve(obj);
    const dict = resolved.asDict() orelse return .device_rgb;

    // `/Alternate` is what the producer says to use without a colour engine,
    // so prefer it over guessing from `/N`.
    if (try doc.get(dict, "Alternate")) |alt| {
        if (try load(arena, doc, alt, resources, depth + 1)) |cs| return cs;
    }

    const n = if (try doc.get(dict, "N")) |v| v.asInt() orelse 3 else 3;
    return switch (n) {
        1 => .device_gray,
        4 => .device_cmyk,
        // Three, and anything nonsensical: an ICC profile with no usable
        // component count is far more likely to be RGB than anything else.
        else => .device_rgb,
    };
}

fn indexed(
    arena: Allocator,
    doc: *Document,
    list: []const Object,
    resources: ?Dict,
    depth: u8,
) Error!?ColorSpace {
    if (list.len < 4) return null;

    const base_space = try load(arena, doc, list[1], resources, depth + 1) orelse ColorSpace.device_rgb;
    const base = try arena.create(ColorSpace);
    base.* = base_space;

    const hival_value = (try doc.resolve(list[2])).asInt() orelse 0;
    const hival: u32 = if (hival_value < 0) 0 else @intCast(@min(hival_value, 255));

    const table = try doc.resolve(list[3]);
    const lookup: []const u8 = switch (table) {
        .string => |s| s,
        .stream => |s| (try doc.streamData(s)).data,
        else => &.{},
    };

    return .{
        .kind = .indexed,
        .components = 1,
        .base = base,
        .lookup = lookup,
        .hival = hival,
    };
}

fn separation(
    arena: Allocator,
    doc: *Document,
    list: []const Object,
    resources: ?Dict,
    depth: u8,
    components: u8,
) Error!?ColorSpace {
    // [/Separation name alternate tint]
    if (list.len < 3) return .{ .kind = .separation, .components = components };

    // `/None` marks nothing -- but only for a real `/Separation`. A
    // `/DeviceN` reaches here with the first of its colorants, and one `/None`
    // ink among several does not suppress the others.
    const colorant = (try doc.resolve(list[1])).asName();
    const marks_nothing = components == 1 and
        if (colorant) |c| eq(c, "None") else false;

    const alt_space = try load(arena, doc, list[2], resources, depth + 1) orelse ColorSpace.device_gray;
    const alt = try arena.create(ColorSpace);
    alt.* = alt_space;

    const tint = if (list.len >= 4)
        try function.loadCombined(arena, doc, list[3], 0) orelse &[_]Function{}
    else
        &[_]Function{};

    return .{
        .kind = .separation,
        .components = components,
        .tint = tint,
        .alternate = alt,
        .marks_nothing = marks_nothing,
    };
}

fn deviceN(
    arena: Allocator,
    doc: *Document,
    list: []const Object,
    resources: ?Dict,
    depth: u8,
) Error!?ColorSpace {
    // [/DeviceN names alternate tint attributes?]
    const names = (try doc.resolve(list[1])).asArray() orelse return null;
    const count: u8 = @intCast(std.math.clamp(names.len, 1, max_components));

    // `/DeviceN` and `/Separation` differ only in how many inks they carry,
    // and everything downstream of the tint transform is identical.
    var shifted: [4]Object = .{ list[0], .null, .null, .null };
    shifted[1] = if (names.len != 0) names[0] else .null;
    if (list.len > 2) shifted[2] = list[2];
    if (list.len > 3) shifted[3] = list[3];

    return separation(arena, doc, shifted[0..@min(list.len, 4)], resources, depth, count);
}

fn lab(doc: *Document, obj: Object) Error!?ColorSpace {
    var cs: ColorSpace = .{ .kind = .lab, .components = 3 };
    const dict = (try doc.resolve(obj)).asDict() orelse return cs;

    if (try doc.get(dict, "WhitePoint")) |wp| {
        if (wp.asArray()) |a| {
            for (0..@min(3, a.len)) |i| {
                cs.white[i] = (try doc.resolve(a[i])).asNumber() orelse cs.white[i];
            }
        }
    }
    if (try doc.get(dict, "Range")) |r| {
        if (r.asArray()) |a| {
            for (0..@min(4, a.len)) |i| {
                cs.range[i] = (try doc.resolve(a[i])).asNumber() orelse cs.range[i];
            }
        }
    }
    return cs;
}

fn pattern(
    arena: Allocator,
    doc: *Document,
    obj: Object,
    resources: ?Dict,
    depth: u8,
) Error!?ColorSpace {
    // `[/Pattern base]` is an uncoloured pattern: `scn` takes the base
    // space's components *and* the pattern name, and the pattern's own
    // content stream has no colour of its own.
    const base_space = try load(arena, doc, obj, resources, depth + 1) orelse
        return ColorSpace{ .kind = .pattern, .components = 1 };
    const base = try arena.create(ColorSpace);
    base.* = base_space;
    return .{
        .kind = .pattern,
        .components = base_space.components,
        .base = base,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "device spaces convert without a document" {
    const grey = ColorSpace.device_gray.toColor(&.{0.25});
    try testing.expectApproxEqAbs(@as(f32, 0.25), grey.g, 1e-6);

    const rgb = ColorSpace.device_rgb.toColor(&.{ 1, 0.5, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), rgb.g, 1e-6);

    const black = ColorSpace.device_cmyk.toColor(&.{ 0, 0, 0, 1 });
    try testing.expectApproxEqAbs(@as(f32, 0), black.r, 1e-6);
}

test "out of range components clamp instead of wrapping" {
    const over = ColorSpace.device_rgb.toColor(&.{ 5, -2, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 1), over.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), over.g, 1e-6);
}

test "too few components read as zero rather than reading past the end" {
    const partial = ColorSpace.device_rgb.toColor(&.{0.5});
    try testing.expectApproxEqAbs(@as(f32, 0.5), partial.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), partial.b, 1e-6);
}

test "an indexed palette resolves through its base space" {
    const base: ColorSpace = .device_rgb;
    const cs: ColorSpace = .{
        .kind = .indexed,
        .components = 1,
        .base = &base,
        .lookup = &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255 },
        .hival = 2,
    };

    const red = cs.toColor(&.{0});
    try testing.expectApproxEqAbs(@as(f32, 1), red.r, 1e-6);
    const green = cs.toColor(&.{1});
    try testing.expectApproxEqAbs(@as(f32, 1), green.g, 1e-6);

    // An index past the palette clamps to the last entry rather than reading
    // whatever follows it in memory.
    const clamped = cs.toColor(&.{99});
    try testing.expectApproxEqAbs(@as(f32, 1), clamped.b, 1e-6);
}

test "a short palette reads missing entries as black" {
    const base: ColorSpace = .device_rgb;
    const cs: ColorSpace = .{
        .kind = .indexed,
        .components = 1,
        .base = &base,
        .lookup = &.{ 255, 255 }, // one entry short
        .hival = 1,
    };
    const truncated = cs.toColor(&.{1});
    try testing.expectApproxEqAbs(@as(f32, 0), truncated.r, 1e-6);
}

test "a separation runs its tint transform into the alternate space" {
    const alt: ColorSpace = .device_cmyk;
    // A blue ink: full tint is 100% cyan and 80% magenta.
    const tint = [_]Function{.{
        .kind = .exponential,
        .domain = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 4,
        .body = .{ .exponential = .{
            .c0 = &.{ 0, 0, 0, 0 },
            .c1 = &.{ 1, 0.8, 0, 0 },
            .n = 1,
        } },
    }};
    const cs: ColorSpace = .{
        .kind = .separation,
        .components = 1,
        .tint = &tint,
        .alternate = &alt,
    };

    const full = cs.toColor(&.{1});
    try testing.expectApproxEqAbs(@as(f32, 0), full.r, 1e-5);
    const none = cs.toColor(&.{0});
    try testing.expectApproxEqAbs(@as(f32, 1), none.r, 1e-5);
}

test "a DeviceN tint transform is given every colorant, not just the first" {
    // Two inks through one two-input transform. The tint used to be handed
    // `comps[0]` alone, and `Function.eval` fills the inputs it is not given
    // with their domain minima -- so no ink after the first could change the
    // colour, and a four-ink space printed as its first plate.
    //
    // The sampled table below returns its *second* input: samples are laid
    // out with the first input varying fastest, so this is 0, 0, 1, 1.
    const samples = [_]u8{ 0, 0, 255, 255 };
    const tint = [_]Function{.{
        .kind = .sampled,
        .domain = &.{ 0, 1, 0, 1 },
        .range = &.{ 0, 1 },
        .inputs = 2,
        .outputs = 1,
        .body = .{ .sampled = .{
            .samples = &samples,
            .size = &.{ 2, 2 },
            .bits = 8,
            .encode = &.{},
            .decode = &.{ 0, 1 },
        } },
    }};
    const alt: ColorSpace = .device_gray;
    const cs: ColorSpace = .{
        .kind = .separation,
        .components = 2,
        .tint = &tint,
        .alternate = &alt,
    };

    // Nothing of the first ink and all of the second: the transform says 1,
    // which is white in the alternate space.
    try testing.expectApproxEqAbs(@as(f32, 1), cs.toColor(&.{ 0, 1 }).r, 1e-5);
    // And the other way round is black -- the answer the bug gave for both.
    try testing.expectApproxEqAbs(@as(f32, 0), cs.toColor(&.{ 1, 0 }).r, 1e-5);
}

test "a separation with no transform darkens with its tint" {
    const cs: ColorSpace = .{ .kind = .separation, .components = 1 };
    try testing.expectApproxEqAbs(@as(f32, 1), cs.toColor(&.{0}).r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), cs.toColor(&.{1}).r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), cs.toColor(&.{0.75}).r, 1e-6);
}

test "the None colorant marks nothing at all" {
    const cs: ColorSpace = .{ .kind = .separation, .components = 1, .marks_nothing = true };
    try testing.expectApproxEqAbs(@as(f32, 0), cs.toColor(&.{1}).a, 1e-6);
}

test "Lab black and white land where they should" {
    const cs: ColorSpace = .{ .kind = .lab, .components = 3 };

    const white = cs.toColor(&.{ 100, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 1), white.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), white.b, 0.01);

    const black = cs.toColor(&.{ 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0), black.r, 0.01);

    // A strongly positive a* is red.
    const red = cs.toColor(&.{ 54, 81, 70 });
    try testing.expect(red.r > 0.8);
    try testing.expect(red.g < 0.4);
}

test "initial colour is black everywhere except a separation" {
    var buf: [max_components]f64 = undefined;
    try testing.expectEqual(@as(f64, 0), ColorSpace.device_rgb.initial(&buf)[0]);

    const spot: ColorSpace = .{ .kind = .separation, .components = 1 };
    // Full tint, per §8.6.8: a spot colour starts at 1, not 0, so `cs`
    // followed straight by a fill paints the ink rather than nothing.
    try testing.expectEqual(@as(f64, 1), spot.initial(&buf)[0]);
}

test "component ranges are unit except in Lab and Indexed" {
    const rgb: ColorSpace = .device_rgb;
    try testing.expectEqual(@as(f64, 1), rgb.componentRange(0)[1]);

    const l: ColorSpace = .{ .kind = .lab, .components = 3, .range = .{ -90, 90, -80, 80 } };
    try testing.expectEqual(@as(f64, 100), l.componentRange(0)[1]);
    try testing.expectEqual(@as(f64, -90), l.componentRange(1)[0]);

    const idx: ColorSpace = .{ .kind = .indexed, .components = 1, .hival = 15 };
    try testing.expectEqual(@as(f64, 15), idx.componentRange(0)[1]);
}
