//! The box tree, turned into rectangles.
//!
//! Þviti produces a tree and Gleipnir consumes an instance buffer; this walks
//! one into the other. It is deliberately the dumbest file in the layer: it
//! draws exactly what each box's style says, in build order, and makes no
//! decisions of its own beyond the two it cannot avoid.
//!
//! ## The two it cannot avoid
//!
//! **Interaction colour.** `hot_t` and `active_t` are only known at draw time
//! -- they are last frame's animation, advanced by `UI.end` after the tree was
//! built -- so a call site cannot bake them into a colour when it makes the
//! box. The rule is therefore here, and it is one line each: the background
//! moves `hot_lift` of the way towards the foreground when hovered and
//! `active_lift` of the way towards black when pressed. Both live in `Style`,
//! so the theme is still the caller's; only the interpolation is here.
//!
//! **Baseline placement.** Text is centred by its *line box*, not by its ink,
//! so that two labels with different letters in them sit on the same baseline.
//! Getting this wrong is invisible on one label and obvious in a list.
//!
//! ## Order
//!
//! Depth first, parents before children, siblings in the order they were
//! built. That is the same order the signals resolved hover in, which is what
//! makes "the box on top gets the mouse" and "the box on top is drawn last"
//! the same sentence. Nothing here sorts, and nothing here batches: the rect
//! pipeline puts the whole frame in one draw call whatever order it arrives
//! in, which is exactly why the clip is in the instance.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const DrawList = @import("../gleipnir/DrawList.zig");
const rect = @import("../gleipnir/rect.zig");
const Fonts = @import("../tyr/Fonts.zig");

const Box = @import("Box.zig");
const UI = @import("UI.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const Point = geom.Point;
const TextureId = rect.TextureId;

pub const Error = Allocator.Error;

/// Scratch that outlives a frame, so drawing a screen of text is not a
/// thousand allocations.
pub const Renderer = struct {
    gpa: Allocator,
    glyphs: std.ArrayList(Fonts.Placed) = .empty,

    /// Boxes and glyph quads emitted by the last `render`. Both are worth
    /// having in front of a person: a frame whose glyph count is ten times its
    /// box count is a frame drawing text nobody asked for.
    boxes_drawn: u32 = 0,
    glyphs_drawn: u32 = 0,

    pub fn init(gpa: Allocator) Renderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Renderer) void {
        r.glyphs.deinit(r.gpa);
        r.* = undefined;
    }

    /// Draws the whole tree into `d`.
    ///
    /// `atlas` is the texture id `d` gave back when the glyph atlas was
    /// registered; passing `rect.no_texture` draws every glyph as a solid
    /// block, which is what happens when the atlas has not been uploaded and
    /// is a great deal easier to diagnose than nothing at all.
    pub fn render(
        r: *Renderer,
        d: *DrawList,
        ui: *UI,
        fonts: *Fonts,
        atlas: TextureId,
    ) Error!void {
        r.boxes_drawn = 0;
        r.glyphs_drawn = 0;
        try r.node(d, ui.root, fonts, atlas);
    }

    fn node(r: *Renderer, d: *DrawList, b: *Box, fonts: *Fonts, atlas: TextureId) Error!void {
        // A box with nothing to draw still nests, still clips, and still has
        // children -- most of a tree is structure.
        if (b.size[0] > 0 and b.size[1] > 0) try r.paintOne(d, b, fonts, atlas);

        if (b.flags.clip) d.pushClipDevice(b.rect);
        defer if (b.flags.clip) d.popClip();

        var it = b.children();
        while (it.next()) |c| try r.node(d, c, fonts, atlas);
    }

    fn paintOne(r: *Renderer, d: *DrawList, b: *Box, fonts: *Fonts, atlas: TextureId) Error!void {
        const s = b.style;
        const fade = 1 - s.disabled_fade * b.disabled_t;

        if (b.flags.draw_shadow) {
            // Offset downwards by an eighth of the spread: there is no light
            // direction in the renderer, so the one convention the UI uses
            // lives here, in one place, rather than at every call site.
            const drop = s.shadow * 0.125;
            try d.shadow(
                .fromRect(b.rect.min_x, b.rect.min_y + drop, b.rect.max_x, b.rect.max_y + drop),
                s.radius,
                s.shadow,
                s.shadow_color.withAlpha(s.shadow_color.a * fade),
            );
        }

        if (b.flags.draw_background) {
            var bg = mix(s.bg, s.fg, s.hot_lift * b.hot_t);
            bg = mix(bg, .black, s.active_lift * b.active_t);
            try d.box(b.rect, .{
                .color = bg.withAlpha(bg.a * fade),
                .radius = s.radius,
            });
        }

        if (b.flags.draw_border) {
            try d.border(b.rect, s.radius, s.border, s.border_color.withAlpha(s.border_color.a * fade));
        }

        if (b.flags.draw_text and b.text.len > 0) {
            try r.paintText(d, b, fonts, atlas, fade);
        }

        // Boxes that emitted something, not boxes visited: most of a tree is
        // structure, and a count that included it would say nothing.
        if (b.flags.draw_background or b.flags.draw_border or
            b.flags.draw_shadow or b.flags.draw_text) r.boxes_drawn += 1;
    }

    fn paintText(
        r: *Renderer,
        d: *DrawList,
        b: *Box,
        fonts: *Fonts,
        atlas: TextureId,
        fade: f32,
    ) Error!void {
        const s = b.style;
        const m = fonts.metrics(s.font, s.font_size);

        // The padding the sizing pass already charged for, so that a label
        // aligned to the start sits at the inset it was measured with. Reading
        // it back off the size rather than storing it again is what keeps the
        // two from drifting.
        const pad: f32 = if (b.pref[0].kind == .text) b.pref[0].value else 0;
        const width = b.text_size[0];
        const free = b.rect.width() - width;

        const x = b.rect.min_x + switch (s.text_align) {
            .start => pad,
            .center => @max(free * 0.5, 0),
            .end => @max(free - pad, 0),
        };

        // Centred by the line box, not by the ink: `moon` and `Ipswich` must
        // share a baseline or a list ripples.
        const line = m.lineHeight();
        const y = b.rect.min_y + (b.rect.height() - line) * 0.5 + m.ascent;

        r.glyphs.clearRetainingCapacity();
        _ = fonts.layout(s.font, s.font_size, b.text, .{ .x = x, .y = y }, &r.glyphs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        const color = s.fg.withAlpha(s.fg.a * fade);
        for (r.glyphs.items) |g| {
            try d.glyph(g.dst, atlas, g.src, color);
        }
        r.glyphs_drawn += @intCast(r.glyphs.items.len);
    }
};

/// Linear interpolation in the colour space the styles are written in, which
/// is sRGB-encoded. Deliberately not in linear light: these are small nudges
/// between two nearby greys chosen by eye, and doing them "correctly" makes a
/// hover highlight visibly stronger than the designer picked.
fn mix(a: Color, b: Color, t: f32) Color {
    const k = std.math.clamp(t, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * k,
        .g = a.g + (b.g - a.g) * k,
        .b = a.b + (b.b - a.b) * k,
        .a = a.a + (b.a - a.a) * k,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const text_adapter = @import("text.zig");

const Harness = struct {
    fonts: Fonts,
    ui: UI,
    d: DrawList,
    r: Renderer,
    atlas: TextureId,

    fn init(gpa: Allocator) !*Harness {
        const h = try gpa.create(Harness);
        h.* = .{
            .fonts = try .init(gpa, .{}),
            .ui = undefined,
            .d = .init(gpa, .fromRect(0, 0, 400, 300)),
            .r = .init(gpa),
            .atlas = 0,
        };
        h.ui = .init(gpa, text_adapter.metricsOf(&h.fonts));
        h.atlas = try h.d.registerTexture(h.fonts.atlasWidth(), h.fonts.atlasHeight());
        return h;
    }

    fn deinit(h: *Harness, gpa: Allocator) void {
        h.r.deinit();
        h.d.deinit();
        h.ui.deinit();
        h.fonts.deinit();
        gpa.destroy(h);
    }

    fn draw(h: *Harness) !void {
        h.d.reset(.fromRect(0, 0, 400, 300));
        try h.r.render(&h.d, &h.ui, &h.fonts, h.atlas);
    }
};

test "a box with no draw flags emits nothing" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    h.ui.next(.{ .w = .px(100), .h = .px(40) });
    _ = try h.ui.box("invisible");
    h.ui.end();
    try h.draw();

    try testing.expectEqual(@as(u32, 0), h.d.count());
    try testing.expectEqual(@as(u32, 0), h.r.boxes_drawn);
}

test "background, border and shadow are three instances of one box" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    h.ui.next(.{
        .w = .px(100),
        .h = .px(40),
        .flags = .{ .draw_background = true, .draw_border = true, .draw_shadow = true },
    });
    _ = try h.ui.box("panel");
    h.ui.end();
    try h.draw();

    try testing.expectEqual(@as(u32, 3), h.d.count());
    // Shadow first, so the panel covers it rather than the other way round.
    try testing.expect(h.d.instances.items[0].softness > 0);
    try testing.expectEqual(@as(f32, 0), h.d.instances.items[1].softness);
    try testing.expect(h.d.instances.items[2].border > 0);
}

test "text becomes one instance per glyph with ink, against the atlas" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    h.ui.next(.{ .w = .text(4), .h = .px(24), .flags = .{ .draw_text = true } });
    _ = try h.ui.box("abc");
    h.ui.end();
    try h.draw();

    try testing.expectEqual(@as(u32, 3), h.r.glyphs_drawn);
    try testing.expectEqual(@as(u32, 3), h.d.count());
    for (h.d.instances.items) |i| {
        try testing.expect(i.flags.textured and i.flags.alpha_texture);
        try testing.expectEqual(h.atlas, i.texture);
    }
}

test "two labels with different letters share a baseline" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    {
        h.ui.pushStyle(.{ .pref = .{ .px(200), .px(30) } });
        defer h.ui.popStyle();
        h.ui.next(.{ .flags = .{ .draw_text = true } });
        _ = try h.ui.box("moon");
        h.ui.next(.{ .flags = .{ .draw_text = true } });
        _ = try h.ui.box("Ipswich");
    }
    h.ui.end();
    try h.draw();

    // Both rows are the same height and both baselines are centred in them,
    // so the first glyph of each must land on the same row.
    const first = h.d.instances.items[0];
    var second: ?@TypeOf(first) = null;
    for (h.d.instances.items) |i| {
        if (i.dst[1] != first.dst[1]) {
            second = i;
            break;
        }
    }
    const other = second.?;
    // The second label is a row lower by exactly the row height, not by some
    // fraction of it that would betray ink-based centring.
    try testing.expectApproxEqAbs(@as(f32, 30), other.dst[1] - first.dst[1], 0.51);
}

test "alignment moves the text inside the box, not the box" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    const build = struct {
        fn go(u: *UI, alignment: Box.Align) !void {
            u.next(.{
                .w = .px(200),
                .h = .px(30),
                .text_align = alignment,
                .flags = .{ .draw_text = true },
            });
            _ = try u.box("hi");
        }
    }.go;

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    try build(&h.ui, .start);
    h.ui.end();
    try h.draw();
    const at_start = h.d.instances.items[0].dst[0];

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    try build(&h.ui, .center);
    h.ui.end();
    try h.draw();
    const at_center = h.d.instances.items[0].dst[0];

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    try build(&h.ui, .end);
    h.ui.end();
    try h.draw();
    const at_end = h.d.instances.items[0].dst[0];

    try testing.expect(at_start < at_center);
    try testing.expect(at_center < at_end);
}

test "a clip box narrows what its children may cover" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    {
        h.ui.next(.{ .w = .px(100), .h = .px(50), .flags = .{ .clip = true, .overflow_y = true } });
        const view = try h.ui.open("view");
        defer h.ui.close(view);

        h.ui.next(.{ .w = .fill, .h = .px(200), .flags = .{ .draw_background = true } });
        _ = try h.ui.box("tall");
    }
    h.ui.end();
    try h.draw();

    const i = h.d.instances.items[0];
    // The rectangle is the full two hundred; the clip is what stops it.
    try testing.expectEqual(@as(f32, 200), i.dst[3] - i.dst[1]);
    try testing.expectEqual(@as(f32, 50), i.clip[3]);
}

test "hover and press move the background and nothing else" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    const build = struct {
        fn go(u: *UI) !*Box {
            u.next(.{
                .w = .px(100),
                .h = .px(40),
                .flags = .{ .clickable = true, .draw_background = true },
            });
            const b = try u.box("Open");
            _ = u.signal(b);
            return b;
        }
    }.go;

    // The mouse well away from it: the default input puts the pointer at the
    // origin, which is inside this box.
    try h.ui.begin(.fromRect(0, 0, 400, 300), .{ .mouse = .{ .x = 350, .y = 250 } });
    _ = try build(&h.ui);
    h.ui.end();
    try h.draw();
    const cold = h.d.instances.items[0].color[0];

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{ .mouse = .{ .x = 50, .y = 20 } });
    _ = try build(&h.ui);
    h.ui.end();
    try h.draw();
    const warm = h.d.instances.items[0].color[0];

    try testing.expect(cold != warm);
    // The geometry did not move: only the colour did.
    try testing.expectEqual([4]f32{ 0, 0, 100, 40 }, h.d.instances.items[0].dst);
}

test "a disabled box is drawn faded" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    // Two frames, because the fade is animated and starts at zero.
    var n: u32 = 0;
    while (n < 40) : (n += 1) {
        try h.ui.begin(.fromRect(0, 0, 400, 300), .{ .dt = 0.05 });
        h.ui.next(.{
            .w = .px(100),
            .h = .px(40),
            .flags = .{ .draw_background = true, .disabled = true },
        });
        _ = try h.ui.box("Open");
        h.ui.end();
    }
    try h.draw();

    const alpha = rect.unpack(h.d.instances.items[0].color[0]).a;
    try testing.expect(alpha > 0.4 and alpha < 0.7);
}

test "a whole frame of chrome is still one draw call" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    try h.ui.begin(.fromRect(0, 0, 400, 300), .{});
    {
        h.ui.next(.{ .w = .fill, .h = .fill, .axis = .y });
        const col = try h.ui.open("col");
        defer h.ui.close(col);

        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            h.ui.next(.{
                .w = .fill,
                .h = .px(24),
                .flags = .{ .draw_background = true, .draw_border = true },
            });
            _ = try h.ui.boxf("row {d}", .{i});
        }
    }
    h.ui.end();
    try h.draw();

    // Twenty rows of twenty-four in a three-hundred pixel viewport: the ones
    // past the bottom are dropped before they reach the buffer rather than
    // clipped on the GPU, so the two numbers together are the forty.
    try testing.expectEqual(@as(u32, 40), h.d.count() + h.d.culled);
    try testing.expect(h.d.culled > 0);
    // Nothing textured, so the fallback path would also take one call. The
    // number that matters is that it never depends on how many clips there
    // were, which a scissor-based renderer's would.
    try testing.expectEqual(@as(u32, 1), h.d.runCount());
}
