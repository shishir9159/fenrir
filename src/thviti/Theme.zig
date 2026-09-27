//! The colours, named by what they are for rather than by what they are.
//!
//! Until now every colour in the interface was a literal at the call site --
//! `vanagandr/ui.zig` says `.{ .r = 0.15, .g = 0.16, .b = 0.19 }` in four
//! places and means "a sidebar" in all four. That is fine for one screen and
//! impossible for two themes, because there is no way to ask what a sidebar
//! is without already knowing.
//!
//! So a theme is a table from a *role* to a colour, and nothing in the
//! interface names a colour any other way. The roles are the questions a
//! widget actually asks -- "what is behind everything", "what is a bar",
//! "what is text nobody is meant to read first" -- and there are eleven of
//! them, which is few enough that someone writing a theme can hold the whole
//! thing in their head.
//!
//! ## Why this file knows nothing about boxes
//!
//! It imports `paint.Color` and nothing else. `Box.Style`'s defaults are read
//! *from here*, which is what makes the dark theme the one you get for
//! nothing; an import in the other direction as well would make the
//! dependency a loop for no gain, since turning a theme into a style is three
//! assignments and belongs where the style stack is.
//!
//! ## Interaction is not in here
//!
//! There is no "hover colour" and no "pressed colour". `Style.hot_lift` moves
//! a background towards the *foreground* and `active_lift` moves it towards
//! black, which means one rule gives the right answer in both themes: on a
//! dark theme hover lightens, and on a light theme the foreground is dark so
//! the same arithmetic darkens. A pair of explicit colours per role would
//! have to be got right twice and would drift.

const std = @import("std");

const paint = @import("../gelgja/paint.zig");

const Color = paint.Color;
const Theme = @This();

/// What a colour is for. Every colour the interface draws comes through one
/// of these, so adding a role is a deliberate act and not a side effect of
/// wanting a slightly different grey.
pub const Role = enum {
    ground,
    panel,
    panel_hi,
    border,
    divider,
    text,
    text_dim,
    accent,
    selection,
    paper,
    shadow,
};

/// What to call it in a setting, and what `fenrir config theme` takes.
name: []const u8,

/// Behind everything: the area a page floats in, and the backdrop of a
/// window with no document in it.
ground: Color,
/// A bar, a rail, a sidebar -- a surface that sits on the ground and holds
/// controls.
panel: Color,
/// A surface on a panel: a button, a text field, the inside of a popup. One
/// step further from the ground, so that three levels are told apart without
/// a border between each pair.
panel_hi: Color,
/// A hairline around a control. Not the same as `divider`: a border is meant
/// to be found when looked for, a divider is meant to be seen.
border: Color,
/// The line between two split windows, and between a rail and the page.
divider: Color,

text: Color,
/// A label, a count, a keybinding -- text that is there to be read second.
text_dim: Color,

/// Focus, selection, the active tab, and the marks the reader makes of its
/// own. This is the *default*; `fenrir config accent` overrides it, and
/// `withAccent` is how.
accent: Color,
/// The background of a selected row. Derived from the accent rather than
/// chosen, so that overriding the accent moves this with it.
selection: Color,

/// A page, when there is no page yet. The real one comes from the document.
paper: Color,
shadow: Color,

/// The theme the interface has had all along, written down.
///
/// `panel`, `text`, `border` and `shadow` are exactly `Box.Style`'s former
/// literal defaults, so nothing drawn before this file existed moves by a
/// thousandth. The test at the bottom of `Box.zig` is what keeps that true.
pub const dark: Theme = .{
    .name = "dark",
    .ground = .{ .r = 0.09, .g = 0.10, .b = 0.12 },
    .panel = .{ .r = 0.16, .g = 0.17, .b = 0.20 },
    .panel_hi = .{ .r = 0.22, .g = 0.23, .b = 0.27 },
    .border = .{ .r = 0.30, .g = 0.32, .b = 0.38 },
    .divider = .{ .r = 0.08, .g = 0.08, .b = 0.08 },
    .text = .{ .r = 0.88, .g = 0.89, .b = 0.92 },
    .text_dim = .{ .r = 0.62, .g = 0.64, .b = 0.70 },
    .accent = .{ .r = 0.26, .g = 0.52, .b = 0.88 },
    .selection = .{ .r = 0.20, .g = 0.36, .b = 0.62 },
    .paper = .{ .r = 0.97, .g = 0.97, .b = 0.96 },
    .shadow = .{ .r = 0, .g = 0, .b = 0, .a = 0.45 },
};

/// The same roles, read the other way up.
///
/// `ground` is a mid grey and not white on purpose: paper is white, and a
/// white page on a white backdrop has no edge. The accent is a darker blue
/// than the dark theme's, because a colour chosen to carry against near-black
/// carries nothing against near-white.
pub const light: Theme = .{
    .name = "light",
    .ground = .{ .r = 0.84, .g = 0.85, .b = 0.87 },
    .panel = .{ .r = 0.94, .g = 0.94, .b = 0.95 },
    .panel_hi = .{ .r = 1.00, .g = 1.00, .b = 1.00 },
    .border = .{ .r = 0.76, .g = 0.77, .b = 0.80 },
    .divider = .{ .r = 0.68, .g = 0.69, .b = 0.72 },
    .text = .{ .r = 0.12, .g = 0.13, .b = 0.16 },
    .text_dim = .{ .r = 0.42, .g = 0.44, .b = 0.48 },
    .accent = .{ .r = 0.13, .g = 0.36, .b = 0.72 },
    .selection = .{ .r = 0.78, .g = 0.85, .b = 0.96 },
    .paper = .{ .r = 1.00, .g = 1.00, .b = 1.00 },
    .shadow = .{ .r = 0, .g = 0, .b = 0, .a = 0.28 },
};

pub const all = [_]Theme{ dark, light };

/// The theme a setting names, or null. Matched exactly: these are one word in
/// a configuration file, not user-facing prose.
pub fn byName(want: []const u8) ?Theme {
    for (all) |t| {
        if (std.mem.eql(u8, t.name, want)) return t;
    }
    return null;
}

pub fn color(t: Theme, role: Role) Color {
    return switch (role) {
        .ground => t.ground,
        .panel => t.panel,
        .panel_hi => t.panel_hi,
        .border => t.border,
        .divider => t.divider,
        .text => t.text,
        .text_dim => t.text_dim,
        .accent => t.accent,
        .selection => t.selection,
        .paper => t.paper,
        .shadow => t.shadow,
    };
}

/// The same theme with the accent a person configured.
///
/// `selection` moves with it, because a row drawn in the accent at full
/// strength is a slab of colour with the text lost inside it. Mixing the
/// accent part of the way towards the panel keeps the row legible and still
/// unmistakably that colour -- and doing it here means a theme author picks
/// one colour rather than two that have to agree.
pub fn withAccent(t: Theme, c: Color) Theme {
    var out = t;
    out.accent = c;
    out.selection = mix(t.panel, c, 0.55);
    return out;
}

/// Perceived brightness, for the one question that is not a role: whether a
/// theme is a dark one. Rec. 601 weights, on the sRGB-encoded values these
/// colours are written in -- the same approximation `draw.zig` argues for
/// where it interpolates.
pub fn luminance(c: Color) f32 {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
}

pub fn isDark(t: Theme) bool {
    return luminance(t.ground) < 0.5;
}

fn mix(a: Color, b: Color, k: f32) Color {
    const s = std.math.clamp(k, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * s,
        .g = a.g + (b.g - a.g) * s,
        .b = a.b + (b.b - a.b) * s,
        .a = a.a + (b.a - a.a) * s,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "every role has a colour in every theme" {
    for (all) |t| {
        for (std.enums.values(Role)) |role| {
            const c = t.color(role);
            try testing.expect(std.math.isFinite(c.r));
            try testing.expect(c.a > 0);
        }
    }
}

test "themes are found by the name a setting would hold" {
    try testing.expectEqualStrings("dark", byName("dark").?.name);
    try testing.expectEqualStrings("light", byName("light").?.name);
    try testing.expect(byName("solarised") == null);
}

test "the dark theme is dark and the light one is not" {
    try testing.expect(dark.isDark());
    try testing.expect(!light.isDark());
}

test "an accent taken from a setting carries its selection with it" {
    const red: Color = .{ .r = 0.9, .g = 0.1, .b = 0.1 };
    const t = dark.withAccent(red);

    try testing.expectEqual(red, t.accent);
    // Between the panel and the accent and equal to neither: a row that is
    // tinted, not painted.
    try testing.expect(t.selection.r > dark.panel.r);
    try testing.expect(t.selection.r < red.r);
}

test "text has contrast against the surface it sits on" {
    // Not a designer's preference, a legibility floor. If these ever cross,
    // a theme has been written that cannot be read, and this is the only
    // place that would notice.
    for (all) |t| {
        const on_panel = @abs(luminance(t.text) - luminance(t.panel));
        const dim_on_panel = @abs(luminance(t.text_dim) - luminance(t.panel));
        try testing.expect(on_panel > 0.4);
        try testing.expect(dim_on_panel > 0.2);
    }
}
