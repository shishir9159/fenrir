//! The one adapter between the UI core and Týr.
//!
//! `UI` measures text through a vtable rather than through a `*Fonts`, and
//! this file is the only place the two names appear together. Twenty lines
//! buys the property that the layout solver -- the piece with all the
//! arithmetic in it -- can be tested against advances that are known exactly,
//! with no font file, no atlas, and no rasteriser anywhere in the test. That
//! is how most of the solver was written and it is why its tests assert
//! specific pixel counts rather than inequalities.
//!
//! It also means the dependency points the right way. Týr does not know a UI
//! exists; the UI does not know Týr exists; this file knows both, and it is
//! not on any hot path.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");
const Fonts = @import("../tyr/Fonts.zig");

const UI = @import("UI.zig");

const Point = geom.Point;

/// A `Metrics` backed by real fonts. `fonts` must outlive the `UI` it is
/// given to.
pub fn metricsOf(fonts: *Fonts) UI.Metrics {
    return .{ .ptr = fonts, .vtable = &vtable };
}

const vtable: UI.Metrics.VTable = .{
    .measure = measure,
    .lineHeight = lineHeight,
};

fn fontsOf(ptr: *anyopaque) *Fonts {
    return @ptrCast(@alignCast(ptr));
}

/// Width from the shaped advances; height from the line, not from the ink.
///
/// The height of a text box is the line height and not the height of the
/// letters in it, or a row containing `moon` would be shorter than the row
/// below it containing `Ipswich`, and a list would ripple.
fn measure(ptr: *anyopaque, text: []const u8, font: u16, px: f32) UI.Error!Point {
    const fonts = fontsOf(ptr);
    return .{
        .x = try fonts.measure(font, px, text),
        .y = fonts.metrics(font, px).lineHeight(),
    };
}

fn lineHeight(ptr: *anyopaque, font: u16, px: f32) f32 {
    return fontsOf(ptr).metrics(font, px).lineHeight();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the adapter reports what the font layer reports" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();

    const m = metricsOf(&fonts);
    // The stand-in face advances half an em, so five characters at twenty
    // pixels is fifty.
    const e = try m.measure("hello", 0, 20);
    try testing.expectApproxEqAbs(@as(f32, 50), e.x, 1e-3);
    try testing.expectApproxEqAbs(fonts.metrics(0, 20).lineHeight(), e.y, 1e-6);
    try testing.expectApproxEqAbs(e.y, m.lineHeight(0, 20), 1e-6);
}

test "a text box is as tall as its line, not as tall as its letters" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();

    const m = metricsOf(&fonts);
    // Two strings whose ink heights differ; their boxes must not.
    const short = try m.measure("moon", 0, 16);
    const tall = try m.measure("Ipswich", 0, 16);
    try testing.expectApproxEqAbs(short.y, tall.y, 1e-6);
    try testing.expect(tall.x > short.x);
}

test "a UI built on real fonts sizes a label to its text" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();

    var ui: UI = .init(gpa, metricsOf(&fonts));
    defer ui.deinit();

    try ui.begin(.fromRect(0, 0, 400, 300), .{});
    ui.next(.{ .w = .text(6), .h = .text(0), .font_size = 16, .flags = .{ .draw_text = true } });
    const label = try ui.box("Fenrir");
    ui.end();

    // Six glyphs at eight pixels each, plus six pixels of padding a side.
    try testing.expectApproxEqAbs(@as(f32, 6 * 8 + 12), label.size[0], 1e-3);
    try testing.expectApproxEqAbs(fonts.metrics(0, 16).lineHeight(), label.size[1], 1e-3);
}
