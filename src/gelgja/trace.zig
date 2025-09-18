//! The trace backend: a display list as text.
//!
//! This is the first consumer of a display list and the cheapest one, and it
//! exists to answer a question that gets very expensive later: when a page
//! comes out wrong, is the interpreter wrong or is the rasteriser wrong? A
//! trace settles that in one diff, because it shows exactly what the
//! interpreter decided and nothing about how it was drawn.
//!
//! The format is designed to be diffed, not parsed. Coordinates are fixed at
//! two decimals so that trivial float noise does not show up as a change;
//! nesting is indented so that an unbalanced clip is visible at a glance; and
//! every line begins with its command name so that `grep -c` gives a usable
//! summary.

const std = @import("std");
const Writer = std.Io.Writer;

const DisplayList = @import("DisplayList.zig");
const geom = @import("geom.zig");
const paint = @import("paint.zig");

const Glyph = DisplayList.Glyph;
const Image = DisplayList.Image;
const Path = DisplayList.Path;
const Point = geom.Point;
const TextRun = DisplayList.TextRun;
const Verb = geom.Verb;

pub const Options = struct {
    /// Print every verb and point instead of a `12v/28p` summary.
    paths: bool = false,
    /// Print one line per glyph rather than a decoded string.
    glyphs: bool = false,
    /// Indent by clip and layer depth.
    indent: bool = true,
    /// Leading `#` lines with the page box and the command counts.
    header: bool = true,
};

pub fn write(w: *Writer, list: DisplayList, opts: Options) Writer.Error!void {
    if (opts.header) try writeHeader(w, list);

    var depth: u32 = 0;
    for (list.cmds) |cmd| {
        // Closers dedent before printing so they line up with their opener.
        switch (cmd) {
            .clip_pop, .layer_pop, .marked_end => depth -|= 1,
            else => {},
        }
        if (opts.indent) try w.splatByteAll(' ', depth * 2);

        switch (cmd) {
            .fill_path => |c| {
                try w.print("fill {s} ", .{c.rule.opName()});
                try writePaint(w, c.paint);
                try writePath(w, list, c.path, opts);
            },
            .stroke_path => |c| {
                try w.print("stroke w={d:.2} cap={s} join={s} limit={d:.1}", .{
                    c.stroke.width,
                    c.stroke.cap.opName(),
                    c.stroke.join.opName(),
                    c.stroke.miter_limit,
                });
                const pattern = list.dashOf(c.stroke);
                if (pattern.len != 0) {
                    try w.writeAll(" dash[");
                    for (pattern, 0..) |v, i| {
                        if (i != 0) try w.writeByte(' ');
                        try w.print("{d:.2}", .{v});
                    }
                    try w.print("]@{d:.2}", .{c.stroke.dash_phase});
                }
                // The matrix is only interesting when it changes the pen: a
                // uniform scale is the overwhelmingly common case and printing
                // it every time buries the ones that matter.
                if (!c.ctm.isAxisAligned() or c.stroke.width == 0) {
                    try w.print(" ctm{f}", .{c.ctm});
                }
                try w.writeByte(' ');
                try writePaint(w, c.paint);
                try writePath(w, list, c.path, opts);
            },
            .clip_push => |c| {
                try w.print("clip_push {s}", .{c.rule.opName()});
                try writePath(w, list, c.path, opts);
            },
            .clip_pop => try w.writeAll("clip_pop"),
            .text => |run| try writeText(w, list, run, opts),
            .image => |img| try writeImage(w, list, img),
            .shading => |sh| {
                try w.print("shading type={d} obj={d} {f}", .{ sh.kind, sh.object, sh.transform });
            },
            .layer_push => |l| {
                try w.print("layer_push alpha={d:.3} blend={s}", .{ l.alpha, @tagName(l.blend) });
                if (l.soft_mask != paint.no_object) try w.print(" smask={d}", .{l.soft_mask});
                if (l.isolated) try w.writeAll(" isolated");
                if (l.knockout) try w.writeAll(" knockout");
            },
            .layer_pop => try w.writeAll("layer_pop"),
            .marked_begin => |tag| try w.print("marked_begin /{s}", .{list.stringOf(tag)}),
            .marked_end => try w.writeAll("marked_end"),
        }
        try w.writeByte('\n');

        switch (cmd) {
            .clip_push, .layer_push, .marked_begin => depth += 1,
            else => {},
        }
    }

    if (list.unbalanced) {
        try w.writeAll("# WARNING: the content stream left clips or layers open\n");
    }
}

fn writeHeader(w: *Writer, list: DisplayList) Writer.Error!void {
    const s = list.stats();
    try w.print("# page {f}\n", .{list.page});
    try w.print(
        "# {d} cmds: {d} fill, {d} stroke, {d} clip, {d} text ({d} glyphs), {d} image, {d} shading, {d} layer\n",
        .{ list.cmds.len, s.fills, s.strokes, s.clips, s.text_runs, s.glyphs, s.images, s.shadings, s.layers },
    );
    try w.print("# content {f}\n", .{list.contentBounds()});
}

fn writePaint(w: *Writer, p: paint.Paint) Writer.Error!void {
    switch (p) {
        .solid => |c| try w.print("{f}", .{c}),
        .shading => |sh| try w.print("shading(type={d} obj={d})", .{ sh.kind, sh.object }),
        .tiling => |t| try w.print("tiling(obj={d})", .{t.object}),
    }
}

fn writePath(w: *Writer, list: DisplayList, path: Path, opts: Options) Writer.Error!void {
    const verbs = list.verbsOf(path);
    const points = list.pointsOf(path);

    if (path.isEmpty()) {
        try w.writeAll(" <empty path>");
        return;
    }

    try w.print(" {d}v/{d}p {f}", .{ verbs.len, points.len, list.pathBounds(path) });
    if (!opts.paths) return;

    var i: usize = 0;
    for (verbs) |verb| {
        try w.writeAll("\n    ");
        switch (verb) {
            .move => try w.print("move  {f}", .{points[i]}),
            .line => try w.print("line  {f}", .{points[i]}),
            .cubic => try w.print("cubic {f} {f} {f}", .{ points[i], points[i + 1], points[i + 2] }),
            .close => try w.writeAll("close"),
        }
        i += verb.pointCount();
    }
}

fn writeText(w: *Writer, list: DisplayList, run: TextRun, opts: Options) Writer.Error!void {
    const font = list.fontOf(run.font);
    const glyphs = list.glyphsOf(run);

    try w.print("text /{s}", .{list.stringOf(font.name)});
    const base = list.stringOf(font.base_font);
    if (base.len != 0) try w.print(" \"{s}\"", .{base});
    if (font.composite) try w.writeAll(" cid");

    try w.print(" {d:.2}pt mode={s} ", .{ run.size, @tagName(run.mode) });
    try writePaint(w, run.fill);
    try w.print(" {f} {d}g", .{ run.transform, glyphs.len });

    if (opts.glyphs) {
        for (glyphs, 0..) |g, i| {
            try w.print("\n    [{d}] code=0x{X:0>4}", .{ i, g.code });
            if (g.id != Glyph.unresolved_glyph) try w.print(" gid={d}", .{g.id});
            try w.print(" at {f}", .{g.offset});
        }
    } else {
        // A best-effort readable form. Codes are not Unicode until the font
        // layer resolves /ToUnicode, but for the simple fonts that dominate
        // most documents they are close enough to read a trace by.
        try w.writeAll(" \"");
        for (glyphs) |g| {
            if (g.code >= 0x20 and g.code < 0x7f) {
                if (g.code == '"' or g.code == '\\') try w.writeByte('\\');
                try w.writeByte(@intCast(g.code));
            } else {
                try w.writeByte('.');
            }
        }
        try w.writeByte('"');
    }
}

fn writeImage(w: *Writer, list: DisplayList, img: Image) Writer.Error!void {
    try w.print("image /{s} {d}x{d}", .{ list.stringOf(img.name), img.width, img.height });
    if (img.is_mask) {
        try w.writeAll(" mask ");
        try writePaint(w, img.fill);
    }
    if (img.interpolate) try w.writeAll(" interpolate");
    try w.print(" obj={d} {f}", .{ img.object, img.transform });
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Builder = @import("Builder.zig");

fn render(list: DisplayList, opts: Options) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, list, opts);
    return out.toOwnedSlice();
}

test "a filled rectangle traces to one line" {
    var b: Builder = .init(testing.allocator, .fromRect(0, 0, 612, 792));
    defer b.deinit();

    try b.rect(72, 700, 200, 24);
    try b.fill(.nonzero, .{ .solid = .rgb(0.2, 0.4, 0.9) });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "fill nonzero rgb(0.200 0.400 0.900) 5v/4p [72.00 700.00 272.00 724.00]\n",
        out,
    );
}

test "verbose paths print every segment" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.curveTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 });
    try b.closePath();
    try b.fill(.even_odd, .{ .solid = .black });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false, .paths = true });
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\fill evenodd rgb(0.000 0.000 0.000) 3v/4p [0.00 0.00 5.00 6.00]
        \\    move  0.00,0.00
        \\    cubic 1.00,2.00 3.00,4.00 5.00,6.00
        \\    close
        \\
    , out);
}

test "nesting is indented and closers line up" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 100, 100);
    try b.pushClip(.nonzero);
    try b.rect(10, 10, 10, 10);
    try b.fill(.nonzero, .{ .solid = .black });
    try b.popClip();

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\clip_push nonzero 5v/4p [0.00 0.00 100.00 100.00]
        \\  fill nonzero rgb(0.000 0.000 0.000) 5v/4p [10.00 10.00 20.00 20.00]
        \\clip_pop
        \\
    , out);
}

test "an unbalanced recording is called out" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 10, 10);
    try b.pushClip(.nonzero);

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "WARNING") != null);
}

test "strokes print dashes, and matrices only when they matter" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    const pattern = try b.dash(&.{ 3, 2 });
    try b.rect(0, 0, 10, 10);
    try b.stroke(
        .{ .width = 1.5, .cap = .round, .dash = pattern, .dash_phase = 1 },
        .{ .solid = .black },
        // Axis-aligned and non-zero width: the matrix adds nothing.
        Transform.scaling(2, 2),
    );

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "stroke w=1.50 cap=round join=miter limit=10.0 dash[3.00 2.00]@1.00 " ++
            "rgb(0.000 0.000 0.000) 5v/4p [0.00 0.00 10.00 10.00]\n",
        out,
    );
}

test "a skewed stroke prints its matrix, because the pen is an ellipse" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 10, .y = 0 });
    try b.stroke(.{ .width = 1 }, .{ .solid = .black }, .rotation(0.5));

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "ctm[") != null);
}

test "text prints a readable string by default" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    const font = try b.fontId(7, "F1", "Helvetica", false);
    try b.textRun(.{
        .font = font,
        .size = 12,
        .transform = .translation(72, 700),
    }, &.{
        .{ .code = 'H', .offset = .{ .x = 0, .y = 0 } },
        .{ .code = 'i', .offset = .{ .x = 7.2, .y = 0 } },
    });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "text /F1 \"Helvetica\" 12.00pt mode=fill rgb(0.000 0.000 0.000) " ++
            "[1.00 0.00 0.00 1.00 72.00 700.00] 2g \"Hi\"\n",
        out,
    );
}

test "verbose text prints one line per glyph" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    const font = try b.fontId(7, "F1", "", true);
    try b.textRun(.{ .font = font, .size = 10 }, &.{
        .{ .code = 0x0102, .id = 42, .offset = .{ .x = 0, .y = 0 } },
    });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false, .glyphs = true });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "cid") != null);
    try testing.expect(std.mem.indexOf(u8, out, "code=0x0102 gid=42") != null);
}

test "invisible text is recorded, since it is the OCR layer of every scan" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    const font = try b.fontId(1, "F1", "", false);
    try b.textRun(.{ .font = font, .size = 8, .mode = .invisible }, &.{
        .{ .code = 'a' },
    });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{ .header = false });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "mode=invisible") != null);
}

test "the header summarises the page" {
    var b: Builder = .init(testing.allocator, .fromRect(0, 0, 612, 792));
    defer b.deinit();

    try b.rect(0, 0, 10, 10);
    try b.fill(.nonzero, .{ .solid = .black });
    try b.drawImage(.{ .width = 8, .height = 8, .transform = .scaling(100, 100) });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const out = try render(list, .{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "# page [0.00 0.00 612.00 792.00]"));
    try testing.expect(std.mem.indexOf(u8, out, "1 fill") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 image") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# content [0.00 0.00 100.00 100.00]") != null);
}

const Transform = geom.Transform;
