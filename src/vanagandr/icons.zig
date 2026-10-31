//! `fenrir icons` -- the registry, printed, and a sheet of what it draws.
//!
//! Every registry in this program gets a command that prints it, so that a
//! wrong table is a diff rather than something to find by clicking. This is
//! that command for icons, and it has a second job the others do not: an
//! icon can be *registered* and still be wrong, because the path data that
//! draws it is a string. So the listing asks for every icon's outline and
//! says which ones the parser refused, and `--out` renders the whole set to
//! a PNG, which is the only way to see that a bookmark came out upside down.
//!
//! The sheet goes through the same stack as `fenrir ui`: a box tree, the
//! glyph atlas, the draw list, and the CPU rasteriser. That is deliberate --
//! a sheet drawn some shortcut way would prove the paths parse and nothing
//! about whether they reach the screen.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const library = @import("library.zig");
const ui_png = @import("ui.zig");

const galdr = fenrir.galdr;
const gleipnir = fenrir.gleipnir;
const thviti = fenrir.thviti;
const tyr = fenrir.tyr;

const Bounds = fenrir.gelgja.Bounds;
const DrawList = gleipnir.DrawList;
const Fonts = tyr.Fonts;
const Icons = thviti.Icons;
const UI = thviti.UI;
const w = thviti.widgets;

pub const usage =
    \\fenrir icons [--theme NAME] [--out FILE] [--slot NAME] [--size WxH]
    \\
    \\    Lists every registered icon: its id, its name, which layer the
    \\    source came from, and the glyph it resolves to. An icon whose path
    \\    data does not parse is marked, and makes the command exit non-zero.
    \\
    \\    --theme NAME apply an icon theme first, from <config>/icons/NAME.lua
    \\                 or from a path if NAME is one. This is how a theme is
    \\                 checked: every icon it replaces is listed as themed,
    \\                 and its path data is parsed like any other.
    \\    --out FILE   also draw every icon into a PNG sheet, at the sizes of
    \\                 every slot, with its name beside it.
    \\    --slot NAME  report one slot instead of the sidebar: toolbar_large,
    \\                 toolbar_small, sidebar, statusbar, menu or tab.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    var dest: ?[]const u8 = null;
    var theme_arg: ?[]const u8 = null;
    var slot: Icons.Slot = .sidebar;
    var width: u32 = 760;
    var height: u32 = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--theme needs a name", .{});
            theme_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--out needs a file name", .{});
            dest = args[i];
        } else if (std.mem.eql(u8, arg, "--slot")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--slot needs a name", .{});
            slot = std.meta.stringToEnum(Icons.Slot, args[i]) orelse
                return ctx.fail("no slot called '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--size needs WxH", .{});
            const x = std.mem.indexOfScalar(u8, args[i], 'x') orelse
                return ctx.fail("--size wants WxH", .{});
            width = std.fmt.parseInt(u32, args[i][0..x], 10) catch
                return ctx.fail("--size wants WxH", .{});
            height = std.fmt.parseInt(u32, args[i][x + 1 ..], 10) catch
                return ctx.fail("--size wants WxH", .{});
        } else {
            return ctx.fail("unknown option {s}", .{arg});
        }
    }

    var fonts: Fonts = try .init(ctx.gpa, .{ .subpixel_positions = 3 });
    defer fonts.deinit();

    var icons: Icons = try .init(ctx.gpa, &fonts);
    defer icons.deinit();

    if (theme_arg) |name| try applyTheme(ctx, &icons, &fonts, name);

    const broken = try list(ctx, &icons, &fonts, slot);
    if (dest) |path| try sheet(ctx, &icons, &fonts, path, width, height);

    if (broken != 0) return ctx.fail("{d} icon{s} could not be drawn", .{
        broken,
        if (broken == 1) "" else "s",
    });
}

/// Reads a theme and overrides everything it names.
///
/// The file is read here and not in Galdr, and the font is opened here and
/// not in Þviti, which is the same rule twice: the library layer does not
/// touch the filesystem, and the CLI is what has an `Io` to touch it with.
fn applyTheme(ctx: *Context, icons: *Icons, fonts: *Fonts, name: []const u8) !void {
    if (!galdr.available) return ctx.fail("this build has no Lua, so it can read no themes", .{});

    const path = try themePath(ctx, name);
    const source = ctx.readFile(path) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ path, err });

    var diag: galdr.icons.Diagnostic = .{};
    var theme = galdr.icons.read(ctx.gpa, path, source, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoLua => unreachable,
        error.BadTheme => return ctx.fail("{s}", .{diag.message()}),
    };
    defer theme.deinit();

    // The theme's font, if it named one. Opened against the command's arena,
    // which outlives the `Fonts` -- every backend reads the bytes lazily and
    // a face that outlives them reads freed memory.
    var font: ?Fonts.FontId = null;
    if (theme.font) |rel| {
        const font_path = try std.fs.path.join(ctx.gpa, &.{ std.fs.path.dirname(path) orelse ".", rel });
        if (ctx.readFile(font_path)) |bytes| {
            font = try fonts.open(bytes, .{});
        } else |err| {
            ctx.note("icons: cannot read the theme font {s}: {t}", .{ font_path, err });
        }
    }

    var applied: usize = 0;
    var ignored: usize = 0;
    for (theme.entries) |e| {
        const slot: ?Icons.Slot = if (e.slot) |s|
            std.meta.stringToEnum(Icons.Slot, s) orelse {
                ctx.note("icons: {s} names no slot called '{s}'", .{ e.name, s });
                ignored += 1;
                continue;
            }
        else
            null;

        const src: Icons.Source = switch (e.source) {
            .path => |d| .{ .path = d },
            .glyph => |cp| .{ .glyph = .{ .font = font orelse {
                ctx.note("icons: {s} wants a glyph, and the theme opened no font", .{e.name});
                ignored += 1;
                continue;
            }, .cp = cp } },
        };

        _ = icons.override(e.name, src, slot) catch |err| switch (err) {
            error.BadIconName => {
                ctx.note("icons: '{s}' is not a plugin_id.icon_name", .{e.name});
                ignored += 1;
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        applied += 1;
    }

    ctx.note("theme {s}: {d} applied, {d} ignored", .{ path, applied, ignored });
}

/// A bare word is a theme in the configuration directory; anything that
/// looks like a path is one.
fn themePath(ctx: *Context, name: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, name, ".lua") or
        std.mem.indexOfAny(u8, name, "/\\") != null) return name;

    const dir = galdr.configDir(ctx.gpa, library.environment(ctx)) catch
        return ctx.fail("no configuration directory: name the theme file by path", .{});
    return std.fs.path.join(ctx.gpa, &.{ dir, "icons", try std.fmt.allocPrint(ctx.gpa, "{s}.lua", .{name}) });
}

/// Prints the table, and returns how many icons are unusable.
fn list(ctx: *Context, icons: *Icons, fonts: *Fonts, slot: Icons.Slot) !usize {
    const out = ctx.out;
    try out.print("{d} icons, at the {t} slot ({d:.0}px)\n\n", .{
        icons.count(),
        slot,
        slot.px(),
    });
    try out.print("{s: <4} {s: <22} {s: <11} {s: <9} {s}\n", .{
        "id", "name", "source", "glyph", "check",
    });

    var broken: usize = 0;
    var id: Icons.Id = 0;
    while (id < icons.count()) : (id += 1) {
        const origin = icons.originOf(id, slot);
        const drawn = icons.resolve(id, slot);
        const cp = std.unicode.utf8Decode(drawn.text) catch 0;

        // The face is asked for the outline rather than trusted, because a
        // registered icon whose path data is nonsense resolves perfectly and
        // then draws the box. That is exactly the failure this column is for.
        var note: []const u8 = "ok";
        if (origin == .none) {
            note = "unset";
        } else if (try check(ctx.gpa, fonts, drawn)) |why| {
            note = why;
            broken += 1;
        }

        try out.print("{d: <4} {s: <22} {t: <11} U+{X:0>4}   {s}\n", .{
            id,
            icons.nameOf(id),
            origin,
            cp,
            note,
        });
    }
    return broken;
}

/// Null when the icon draws, a reason when it does not.
fn check(gpa: std.mem.Allocator, fonts: *Fonts, drawn: Icons.Drawn) !?[]const u8 {
    const face = fonts.face(drawn.font);
    const cp = std.unicode.utf8Decode(drawn.text) catch return "bad code point";
    const g = face.glyphForCodepoint(cp) orelse return "no such glyph";

    // Path data is parsed here rather than through `Face.outline`, which
    // substitutes the box on a bad path instead of complaining -- right for
    // a frame, useless for a check.
    if (tyr.icons.setOf(face)) |set| {
        const icon = set.icon(g) orelse return "no such glyph";
        var o: tyr.Outline = .{};
        defer o.deinit(gpa);
        tyr.svgpath.parse(gpa, &o, icon.d, .{
            .transform = tyr.svgpath.viewBox(tyr.icons.grid, @floatFromInt(tyr.icons.units_per_em)),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadPathData => return "bad path data",
        };
        if (o.isEmpty()) return "draws nothing";
        return null;
    }

    // A glyph of somebody else's face: all that can be said is whether it
    // has ink, and a blank one is a theme pointing at the wrong code point.
    var o: tyr.Outline = .{};
    defer o.deinit(gpa);
    face.outline(gpa, g, &o) catch return "cannot decode";
    if (o.isEmpty()) return "draws nothing";
    return null;
}

/// Every icon at every slot size, with its name, through the whole stack.
fn sheet(
    ctx: *Context,
    icons: *Icons,
    fonts: *Fonts,
    dest: []const u8,
    width: u32,
    height_arg: u32,
) !void {
    const rows: f32 = @floatFromInt(icons.count());
    const height: u32 = if (height_arg != 0)
        height_arg
    else
        @intFromFloat(row_height * rows + 2 * margin);

    var ui: UI = .init(ctx.gpa, thviti.text.metricsOf(fonts));
    defer ui.deinit();

    var d: DrawList = .init(ctx.gpa, .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
    defer d.deinit();

    var renderer: thviti.draw.Renderer = .init(ctx.gpa);
    defer renderer.deinit();

    const viewport: Bounds = .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height));

    // Twice, for the reason `fenrir ui` runs forty times: the first frame
    // has no geometry behind it. Nothing here hovers or animates, so two is
    // enough.
    var n: u32 = 0;
    while (n < 2) : (n += 1) {
        fonts.beginFrame();
        try ui.begin(viewport, .{});
        try grid(&ui, icons);
        ui.end();
    }

    const atlas = try d.registerTexture(fonts.atlasWidth(), fonts.atlasHeight());
    d.reset(viewport);
    try renderer.render(&d, &ui, fonts, atlas);

    var fb = try gleipnir.Framebuffer.init(ctx.gpa, width, height, .linear);
    defer fb.deinit(ctx.gpa);
    fb.clear(.gray(0.07));

    var source: ui_png.AtlasSampler = .{ .fonts = fonts };
    gleipnir.software.render(fb, d.instances.items, source.sampler());
    try ui_png.writePng(ctx, dest, fb);

    ctx.note("atlas {d}x{d}, {d} glyphs, {d} rasterised", .{
        fonts.atlasWidth(),
        fonts.atlasHeight(),
        fonts.atlas.count(),
        fonts.atlas.misses,
    });
    ctx.note("wrote {d}x{d} to {s}", .{ width, height, dest });
}

const margin: f32 = 12;
const row_height: f32 = 34;
const name_width: f32 = 220;

fn grid(ui: *UI, icons: *Icons) !void {
    ui.pushStyle(.{ .bg = .{ .r = 0.11, .g = 0.12, .b = 0.15 } });
    defer ui.popStyle();

    ui.next(.{ .w = .fill, .h = .fill, .axis = .y, .flags = .{ .draw_background = true } });
    const page = try ui.open("sheet");
    defer ui.close(page);

    try w.spacer(ui, .px(margin));

    var id: Icons.Id = 0;
    while (id < icons.count()) : (id += 1) {
        var key: [16]u8 = undefined;
        ui.next(.{ .w = .fill, .h = .px(row_height), .axis = .x, .child_align = .center });
        const row = try ui.open(std.fmt.bufPrint(&key, "row{d}", .{id}) catch "row");
        defer ui.close(row);

        try w.spacer(ui, .px(margin));
        ui.next(.{ .w = .px(name_width), .h = .text(0), .flags = .{ .draw_text = true } });
        _ = try ui.boxText("name", icons.nameOf(id));

        // One button per slot, left to right, so that the sizes can be
        // compared against each other as well as looked at.
        const slots = @typeInfo(Icons.Slot).@"enum";
        inline for (slots.field_names, slots.field_values) |name, value| {
            const slot: Icons.Slot = @enumFromInt(value);
            _ = try w.iconButton(ui, name, icons.resolve(id, slot), .{ .size = 30 });
            try w.spacer(ui, .px(6));
        }
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the check is what tells a registered icon from a drawable one" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons: Icons = try .init(gpa, &fonts);
    defer icons.deinit();

    // Every icon compiled into the binary draws. This is the assertion the
    // command exists to make, run without the command.
    var id: Icons.Id = 0;
    while (id < icons.count()) : (id += 1) {
        try testing.expectEqual(
            @as(?[]const u8, null),
            try check(gpa, &fonts, icons.resolve(id, .sidebar)),
        );
    }

    // A theme's typo resolves perfectly and then draws the box, which is
    // exactly what the listing has to catch.
    const bad = try icons.override("theme.oops", .{ .path = "M0 0 Lwhat" }, null);
    try testing.expectEqualStrings(
        "bad path data",
        (try check(gpa, &fonts, icons.resolve(bad, .sidebar))).?,
    );

    // And so does one that parses but has no ink in it.
    const blank = try icons.override("theme.blank", .{ .path = "  " }, null);
    try testing.expectEqualStrings(
        "draws nothing",
        (try check(gpa, &fonts, icons.resolve(blank, .sidebar))).?,
    );
}
