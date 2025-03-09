//! `fenrir fonts` -- what Týr can do in this build.
//!
//! Small, but it answers the question that is otherwise guesswork: whether a
//! binary can render glyphs at all, or only the box-drawing stand-in. A page
//! of rectangles is a legible symptom; having to read `build.zig` to find out
//! why is not.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

pub const usage =
    \\fenrir fonts
    \\
    \\    Lists the glyph backends compiled into this binary, in the order
    \\    they are tried, with the capabilities each advertises. Pass one of
    \\    these names to --font-backend to try it first.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len != 0) return ctx.fail("fonts takes no arguments", .{});

    const w = ctx.out;
    try w.writeAll("glyph backends, in the order they are tried:\n\n");
    try fenrir.tyr.registry.describe(w);

    try w.print("\nshaper        {s}\n", .{
        if (fenrir.tyr.registry.shaping_is_complex)
            "harfbuzz -- full OpenType shaping for UI text"
        else
            "simple -- one glyph per code point, no ligatures or reordering",
    });

    if (!fenrir.tyr.glyphs_are_real) {
        try w.writeAll(
            \\
            \\No real glyph source is compiled in, so every glyph will draw as a
            \\.notdef box. Rebuild with -Dfreetype or -Dstb-truetype.
            \\
        );
    }
}
