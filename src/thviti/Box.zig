//! One node of the box tree: what was asked for, what was solved, and what
//! survived from last frame.
//!
//! A box is created by a call site, sized by the solver, drawn, and then left
//! alone until the same call site asks for it again next frame. The three
//! groups of fields below are exactly that story, and keeping them visually
//! separate is worth more than packing the struct: mixing "the caller said
//! this" with "the solver worked this out" is how a layout bug becomes
//! untraceable.
//!
//! ## Semantic sizing
//!
//! A box does not have a width. It has an *opinion* about its width -- so many
//! pixels, or as wide as its text, or a share of its parent, or as wide as its
//! children need -- and a *strictness*, which says how much of that opinion it
//! is willing to give up when the opinions do not fit. Layout is the process
//! of turning opinions into numbers, and it is a separate pass over a tree
//! that already exists, which is why an immediate-mode call site here does not
//! lag a frame behind the layout the way Dear ImGui's does.
//!
//! The four kinds are not interchangeable and the strictness is not a
//! priority number bolted on afterwards. `pixels` with strictness 1 is a
//! scrollbar: it is sixteen pixels wide and it does not negotiate.
//! `text` with strictness 1 is a label: shrinking it below its text would
//! elide characters, which is worse than overflowing. `percent_of_parent`
//! with strictness 0 is a pane in a split: it wants half and will take
//! whatever it gets. `children_sum` is a container, which has no opinion of
//! its own and simply reports what it contains.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const sdf = @import("../gleipnir/sdf.zig");
const Fonts = @import("../tyr/Fonts.zig");

const key_mod = @import("key.zig");
const Theme = @import("Theme.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const Key = key_mod.Key;
const Radius = sdf.Radius;

const Box = @This();

/// Which way a container stacks its children, and which of the two solver
/// runs is being talked about. The same enum for both, because they are the
/// same axis and giving them separate names invites mixing them up.
pub const Axis = enum(u1) {
    x,
    y,

    pub fn other(a: Axis) Axis {
        return if (a == .x) .y else .x;
    }

    pub fn index(a: Axis) usize {
        return @intFromEnum(a);
    }
};

pub const SizeKind = enum {
    /// No opinion: zero, unless something else fills it in.
    none,
    /// Exactly this many pixels.
    pixels,
    /// As wide, or as tall, as the box's text plus `value` of padding on each
    /// side.
    text,
    /// `value` as a fraction of the nearest ancestor that already has a size.
    percent_of_parent,
    /// The sum of the children along the layout axis, or the largest of them
    /// across it.
    children_sum,
};

pub const Size = struct {
    kind: SizeKind = .none,
    value: f32 = 0,
    /// How much of `value` this box refuses to give up when the children of
    /// a parent do not fit: 1 keeps every pixel, 0 surrenders all of it.
    ///
    /// Not a priority: two boxes at strictness 0.5 do not take turns, they
    /// each give up half of what they wanted. The solver distributes a
    /// shortfall in proportion to what each box is *willing* to lose, which
    /// is the only rule that produces the same answer whatever order the
    /// children were built in.
    strictness: f32 = 0,

    pub const none: Size = .{};

    /// A fixed size that does not negotiate. The right default for pixels:
    /// a sixteen-pixel scrollbar that shrinks to eleven is a bug.
    pub fn px(v: f32) Size {
        return .{ .kind = .pixels, .value = v, .strictness = 1 };
    }

    pub fn pxLoose(v: f32, strictness: f32) Size {
        return .{ .kind = .pixels, .value = v, .strictness = strictness };
    }

    /// As big as the text, plus `pad` on each side.
    pub fn text(pad: f32) Size {
        return .{ .kind = .text, .value = pad, .strictness = 1 };
    }

    /// A share of the nearest sized ancestor. Loose by default, because a
    /// percentage is a wish and the thing it is a percentage of may itself
    /// have been cut down.
    pub fn percent(v: f32) Size {
        return .{ .kind = .percent_of_parent, .value = v, .strictness = 0 };
    }

    pub fn percentStrict(v: f32) Size {
        return .{ .kind = .percent_of_parent, .value = v, .strictness = 1 };
    }

    /// Everything the parent has left.
    pub const fill: Size = .{ .kind = .percent_of_parent, .value = 1, .strictness = 0 };

    /// Exactly as big as the contents.
    pub const children: Size = .{ .kind = .children_sum, .value = 0, .strictness = 1 };
};

pub const Align = enum { start, center, end };

pub const Flags = packed struct(u32) {
    /// Takes mouse buttons. Without it a box is scenery and the mouse falls
    /// through to whatever is behind.
    clickable: bool = false,
    /// Takes the wheel, and owns a `view_off` that survives the frame.
    scrollable: bool = false,
    /// Can hold the keyboard focus, and is reachable by tab.
    focusable: bool = false,

    draw_background: bool = false,
    draw_border: bool = false,
    draw_text: bool = false,
    draw_shadow: bool = false,

    /// Children are clipped to this box, and so is hit testing inside it.
    clip: bool = false,

    /// Position on this axis comes from `fixed`, not from the parent's stack.
    floating_x: bool = false,
    floating_y: bool = false,

    /// Children may exceed this box on this axis without being squeezed.
    /// What makes a scroll view a scroll view.
    overflow_x: bool = false,
    overflow_y: bool = false,

    /// Animate towards the hover and press states rather than snapping.
    hot_animation: bool = false,
    active_animation: bool = false,

    /// Drawn dimmed and takes no input.
    disabled: bool = false,

    _reserved: u17 = 0,

    pub const none: Flags = .{};

    pub fn floating(f: Flags, axis: Axis) bool {
        return if (axis == .x) f.floating_x else f.floating_y;
    }

    pub fn overflows(f: Flags, axis: Axis) bool {
        return if (axis == .x) f.overflow_x else f.overflow_y;
    }

    /// Bitwise union, for merging a scope's flags with a call site's.
    pub fn merge(a: Flags, b: Flags) Flags {
        const A: u32 = @bitCast(a);
        const B: u32 = @bitCast(b);
        return @bitCast(A | B);
    }

    pub fn any(f: Flags) bool {
        return @as(u32, @bitCast(f)) != 0;
    }
};

/// Everything a box inherits from the scope it is built in.
///
/// One struct rather than the dozen separate stacks RAD Debugger keeps,
/// because C macros make per-field stacks ergonomic and Zig does not: here,
/// `ui.pushStyle(.{ .fg = dim })` merges one field onto the top of the stack
/// and leaves the rest alone, which is the same thing with one stack.
pub const Style = struct {
    bg: Color = Theme.dark.panel,
    fg: Color = Theme.dark.text,
    border_color: Color = Theme.dark.border,
    shadow_color: Color = Theme.dark.shadow,

    radius: Radius = .none,
    /// Ring thickness for `draw_border`, inside the edge.
    border: f32 = 1,
    /// Shadow spread for `draw_shadow`.
    shadow: f32 = 12,

    /// How far the background moves towards `fg` when hovered, and towards
    /// black when pressed.
    ///
    /// Two numbers rather than two more colours, because the whole point of
    /// the effect is that it is the same gesture on every control -- and
    /// because the renderer has to apply it at draw time, where `hot_t` is
    /// known, so leaving it to the call site would mean reading last frame's
    /// animation before building this frame's box.
    hot_lift: f32 = 0.07,
    active_lift: f32 = 0.12,
    /// Opacity a disabled box falls to.
    disabled_fade: f32 = 0.45,

    font: Fonts.FontId = 0,
    font_size: f32 = 14,
    text_align: Align = .start,
    /// Where children sit on the axis they are *not* stacked along.
    child_align: Align = .start,

    /// Which way this box stacks its children.
    axis: Axis = .y,

    /// Inherited, unlike flags: a scope that says "everything in here is a
    /// hundred pixels wide" is a normal thing to want, and a scope that says
    /// "everything in here is clickable" is not.
    pref: [2]Size = .{ .none, .none },
};

/// A one-shot override for the next box only, cleared as soon as it is used.
///
/// Split from `Style` because their lifetimes differ and conflating them is
/// the classic immediate-mode UI bug: a colour set for one button that leaks
/// into the next forty. Anything here applies once; anything pushed onto the
/// style stack applies until it is popped.
pub const Next = struct {
    w: ?Size = null,
    h: ?Size = null,
    /// Merged into the box's flags rather than replacing them.
    flags: Flags = .{},
    /// Position within the parent, used only on axes flagged floating.
    fixed_x: ?f32 = null,
    fixed_y: ?f32 = null,

    bg: ?Color = null,
    fg: ?Color = null,
    border_color: ?Color = null,
    shadow_color: ?Color = null,
    radius: ?Radius = null,
    border: ?f32 = null,
    shadow: ?f32 = null,
    hot_lift: ?f32 = null,
    active_lift: ?f32 = null,
    disabled_fade: ?f32 = null,
    font: ?Fonts.FontId = null,
    font_size: ?f32 = null,
    text_align: ?Align = null,
    child_align: ?Align = null,
    axis: ?Axis = null,

    pub const nothing: Next = .{};

    pub fn isEmpty(n: Next) bool {
        return std.meta.eql(n, nothing);
    }
};

/// A partial `Style`, for `pushStyle`. Every field is the optional of the
/// `Style` field with the same name, which the test at the bottom of this file
/// enforces -- the two drift apart silently otherwise, and the symptom is a
/// style field that simply cannot be pushed.
pub const StylePatch = struct {
    bg: ?Color = null,
    fg: ?Color = null,
    border_color: ?Color = null,
    shadow_color: ?Color = null,
    radius: ?Radius = null,
    border: ?f32 = null,
    shadow: ?f32 = null,
    hot_lift: ?f32 = null,
    active_lift: ?f32 = null,
    disabled_fade: ?f32 = null,
    font: ?Fonts.FontId = null,
    font_size: ?f32 = null,
    text_align: ?Align = null,
    child_align: ?Align = null,
    axis: ?Axis = null,
    pref: ?[2]Size = null,

    /// Convenience for the overwhelmingly common pair.
    pub fn size(w: Size, h: Size) StylePatch {
        return .{ .pref = .{ w, h } };
    }
};

pub fn applyPatch(s: Style, p: StylePatch) Style {
    var out = s;
    inline for (@typeInfo(StylePatch).@"struct".field_names) |name| {
        if (@field(p, name)) |v| @field(out, name) = v;
    }
    return out;
}

// -- the node ---------------------------------------------------------------

key: Key = .nil,

// Tree links, rebuilt from scratch every frame. A box that persists across
// frames does not persist its position in the tree, because the call sites
// decide that anew each time and any cached answer would be the stale one.
parent: ?*Box = null,
first: ?*Box = null,
last: ?*Box = null,
next: ?*Box = null,
prev: ?*Box = null,
child_count: u32 = 0,

// -- what the call site asked for, this frame -------------------------------

flags: Flags = .{},
style: Style = .{},
pref: [2]Size = .{ .none, .none },
fixed: [2]f32 = .{ 0, 0 },

/// The visible text, borrowed from the frame arena.
text: []const u8 = "",
/// Measured once at creation, because the solver needs it in pass one and it
/// cannot change between then and there.
text_size: [2]f32 = .{ 0, 0 },

/// The clip in force where this box was built, from the enclosing `clip`
/// boxes' *previous* rectangles. Used for hit testing, which is answered
/// against last frame's geometry anyway.
clip_rect: Bounds = .infinite,

// -- what the solver worked out ---------------------------------------------

size: [2]f32 = .{ 0, 0 },
/// Position within the parent, before scrolling.
rel_pos: [2]f32 = .{ 0, 0 },
/// Absolute top-left, filled in by the positioning pass. Kept apart from
/// `rect` because `rect` still holds last frame's answer while this frame is
/// being built, and hit testing reads it.
pos: [2]f32 = .{ 0, 0 },
/// Absolute, in device pixels. Survives the frame: it is what the *next*
/// frame's `signal` hit-tests against, which is the one place the immediate
/// call site pays for not having a retained tree, and it costs one frame only
/// on the frame a box first appears.
rect: Bounds = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 },

// -- what survived from last frame ------------------------------------------

/// Scroll offset, subtracted from children's positions.
view_off: [2]f32 = .{ 0, 0 },
/// Where the offset is heading, for smooth scrolling. The renderer reads
/// `view_off`; input writes `view_off_target`.
view_off_target: [2]f32 = .{ 0, 0 },

/// Hover and press, as continuous values in 0..1 rather than booleans. This
/// is the entire reason boxes persist: a button that lights up over four
/// frames cannot be expressed by a call site that only knows about now.
hot_t: f32 = 0,
active_t: f32 = 0,
disabled_t: f32 = 0,

first_frame: u64 = 0,
last_frame: u64 = 0,

/// True on the frame a box is created, so a caller can skip an animation that
/// would otherwise play on appearance.
pub fn isNew(b: Box) bool {
    return b.first_frame == b.last_frame;
}

pub fn prefOn(b: Box, axis: Axis) Size {
    return b.pref[axis.index()];
}

pub fn sizeOn(b: Box, axis: Axis) f32 {
    return b.size[axis.index()];
}

/// The rectangle children are laid inside, which is the box itself minus
/// nothing -- padding is expressed with `Size.text`'s pad or with spacers, so
/// that there is one place a number turns into a gap.
pub fn contentRect(b: Box) Bounds {
    return b.rect;
}

/// Children in build order.
pub const Children = struct {
    cur: ?*Box,

    pub fn next(it: *Children) ?*Box {
        const c = it.cur orelse return null;
        it.cur = c.next;
        return c;
    }
};

pub fn children(b: *const Box) Children {
    return .{ .cur = b.first };
}

/// Resets everything the frame owns, keeping everything the box owns.
///
/// The split between the two halves is the whole design, so it is worth being
/// able to read it in one function: tree links, flags, style and the solver's
/// output are rebuilt; scroll offsets, animation and the previous rectangle
/// are not.
pub fn beginFrame(b: *Box, frame: u64) void {
    b.parent = null;
    b.first = null;
    b.last = null;
    b.next = null;
    b.prev = null;
    b.child_count = 0;
    b.flags = .{};
    b.text = "";
    b.text_size = .{ 0, 0 };
    b.pref = .{ .none, .none };
    b.fixed = .{ 0, 0 };
    b.size = .{ 0, 0 };
    b.rel_pos = .{ 0, 0 };
    b.pos = .{ 0, 0 };
    b.last_frame = frame;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the patch covers every style field, with the same types" {
    // The guarantee the hand-written `StylePatch` needs and cannot state:
    // a `Style` field with no counterpart here is a field nobody can push,
    // which fails silently at every call site rather than loudly at one.
    const style = @typeInfo(Style).@"struct";
    const patch = @typeInfo(StylePatch).@"struct";
    try testing.expectEqual(style.field_names.len, patch.field_names.len);

    inline for (style.field_names, style.field_types) |name, Field| {
        const pushed = @typeInfo(@FieldType(StylePatch, name)).optional.child;
        try testing.expectEqual(Field, pushed);
    }
}

test "a patch changes what it names and nothing else" {
    const base: Style = .{};
    const out = applyPatch(base, .{ .font_size = 22 });

    try testing.expectEqual(@as(f32, 22), out.font_size);
    try testing.expectEqual(base.bg, out.bg);
    try testing.expectEqual(base.axis, out.axis);
    // And an empty patch is the identity, which is what makes pushing a scope
    // that changes nothing free rather than destructive.
    try testing.expectEqual(base, applyPatch(base, .{}));
}

test "sizes carry the strictness their kind implies" {
    // Pixels and text default strict, percentages loose. Getting these
    // backwards makes every scrollbar collapse or every pane refuse to fit.
    try testing.expectEqual(@as(f32, 1), Size.px(16).strictness);
    try testing.expectEqual(@as(f32, 1), Size.text(4).strictness);
    try testing.expectEqual(@as(f32, 0), Size.percent(0.5).strictness);
    try testing.expectEqual(@as(f32, 0), Size.fill.strictness);
    try testing.expectEqual(SizeKind.children_sum, Size.children.kind);
}

test "flags merge rather than replace" {
    const scope: Flags = .{ .draw_background = true };
    const site: Flags = .{ .clickable = true };
    const both = scope.merge(site);

    try testing.expect(both.draw_background and both.clickable);
    try testing.expect(!both.draw_border);
    try testing.expect(!Flags.none.any());
    try testing.expect(both.any());
}

test "an axis knows the other one" {
    try testing.expectEqual(Axis.y, Axis.x.other());
    try testing.expectEqual(@as(usize, 0), Axis.x.index());
    try testing.expectEqual(@as(usize, 1), Axis.y.index());

    const f: Flags = .{ .floating_x = true, .overflow_y = true };
    try testing.expect(f.floating(.x) and !f.floating(.y));
    try testing.expect(f.overflows(.y) and !f.overflows(.x));
}

test "a new frame keeps state and drops structure" {
    var b: Box = .{ .key = @enumFromInt(7) };
    b.view_off = .{ 0, 120 };
    b.hot_t = 0.75;
    b.rect = .fromRect(10, 10, 50, 50);
    b.child_count = 3;
    b.size = .{ 40, 40 };
    b.first_frame = 1;

    b.beginFrame(9);

    // Dropped: the tree and the solve are the frame's.
    try testing.expectEqual(@as(u32, 0), b.child_count);
    try testing.expectEqual([2]f32{ 0, 0 }, b.size);
    // Kept: the scroll, the animation, and last frame's rectangle -- which is
    // what this frame's hit testing runs against.
    try testing.expectEqual([2]f32{ 0, 120 }, b.view_off);
    try testing.expectEqual(@as(f32, 0.75), b.hot_t);
    try testing.expectEqual(Bounds.fromRect(10, 10, 50, 50), b.rect);
    try testing.expect(!b.isNew());
}

test "a default style is the dark theme, to the last thousandth" {
    // The defaults used to be four literals here. They are the theme's now,
    // and this is the test that says moving them changed nothing: every
    // screenshot taken before Theme.zig existed still matches.
    const s: Style = .{};
    try testing.expectEqual(Color{ .r = 0.16, .g = 0.17, .b = 0.20 }, s.bg);
    try testing.expectEqual(Color{ .r = 0.88, .g = 0.89, .b = 0.92 }, s.fg);
    try testing.expectEqual(Color{ .r = 0.30, .g = 0.32, .b = 0.38 }, s.border_color);
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0.45 }, s.shadow_color);
}
