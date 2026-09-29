//! The interface the reader draws over the page.
//!
//! Until this file the reader drew no text in its own window at all: the mode
//! line was the operating system's *title bar*, which is a real place to put
//! one and is the only place available to a window that cannot write in
//! itself. `titleText` in `read.zig` said as much -- "the title is the only
//! text this window draws".
//!
//! So everything needed to write in the window arrives here together, because
//! none of it is useful in halves: Þviti to lay a tree out, Týr to turn the
//! strings into glyphs and pack them, and the upload that gets the atlas onto
//! the device. `fenrir view` has run exactly this stack since Lyngvi landed;
//! this is that wiring, in the command that opens a document.
//!
//! ## What is here and what is the reader's
//!
//! `Chrome` knows about fonts, an atlas, a box tree and a draw list. It does
//! not know what a buffer is, what a split is, or that documents exist: the
//! bar is handed a `Status`, which is a few strings and numbers, and
//! `read.zig` fills it in. That is the division `Host.zig` draws for Galdr,
//! and it is what lets the bar be built and measured in a test with no
//! window, no device and no PDF.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const gleipnir = fenrir.gleipnir;
const lyngvi = fenrir.lyngvi;
const thviti = fenrir.thviti;
const tyr = fenrir.tyr;

const sysfont = @import("sysfont.zig");

const Bounds = fenrir.gelgja.Bounds;
const DrawList = gleipnir.DrawList;
const Fonts = tyr.Fonts;
const Theme = thviti.Theme;
const UI = thviti.UI;
const w = thviti.widgets;

/// The bar along the bottom, in device pixels. Dense on purpose: it is a
/// mode line, not a dashboard.
pub const status_height: f32 = 26;
pub const status_text: f32 = 12;
/// The inset at either end of the bar, and between the things in it.
pub const gutter: f32 = 10;

/// Þviti, a face to draw it with, and the atlas the glyphs land in.
pub const Chrome = struct {
    gpa: Allocator,
    fonts: Fonts,
    ui: UI,
    painter: thviti.draw.Renderer,

    /// The face the interface is drawn in.
    ///
    /// `Fonts.init` puts Týr's fallback at zero and it stays there, so a
    /// machine with no usable face still lays the bar out correctly and draws
    /// every character as a box -- which says that measurement, packing and
    /// placement all work and only the outlines are missing. That is a far
    /// more useful failure than a blank bar.
    face: Fonts.FontId = Fonts.fallback_font,
    /// The font program, read off this machine. `Fonts.open` borrows the
    /// bytes rather than copying them, so they live exactly as long as this.
    program: ?[]u8 = null,

    /// The atlas, as the device and both draw lists number it. Zero until
    /// `attach`; zero means "no texture" to the instance format, so a frame
    /// drawn before attaching draws its glyphs as solid blocks rather than
    /// sampling something that is not there.
    atlas: u32 = 0,
    /// The atlas height as last uploaded. Týr grows it by doubling
    /// downwards, and a grow needs the device's image replaced.
    atlas_height: u32 = 0,

    theme: Theme = .dark,

    /// On the heap, and not by value, because `UI` reaches text through a
    /// vtable whose pointer is `&c.fonts`. A `Chrome` returned by value is
    /// copied to its caller and that pointer is left aiming at the frame it
    /// was built in -- which does not crash where it is made, it crashes
    /// three calls later inside Týr with an empty face table. The same
    /// reasoning puts `galdr.Runtime` and a buffer's `Document` on the heap.
    pub fn create(gpa: Allocator, io: ?std.Io) !*Chrome {
        const c = try gpa.create(Chrome);
        errdefer gpa.destroy(c);

        c.* = .{
            .gpa = gpa,
            .fonts = try .init(gpa, .{ .subpixel_positions = 3 }),
            .ui = undefined,
            .painter = .init(gpa),
        };
        errdefer {
            c.painter.deinit();
            c.fonts.deinit();
        }

        if (sysfont.forInterface(io, gpa)) |bytes| {
            c.program = bytes;
            // A face that will not open leaves the fallback in place, which
            // is the same outcome as finding no file at all.
            c.face = c.fonts.open(bytes, .{}) catch Fonts.fallback_font;
        }
        // Last, and at the address it will keep.
        c.ui = .init(gpa, thviti.text.metricsOf(&c.fonts));
        return c;
    }

    pub fn destroy(c: *Chrome) void {
        const gpa = c.gpa;
        c.painter.deinit();
        c.ui.deinit();
        // Before the bytes it borrows: a backend reads the program lazily,
        // and closing the face is what stops it.
        c.fonts.deinit();
        if (c.program) |p| gpa.free(p);
        gpa.destroy(c);
    }

    /// Whether the interface is drawn in a real typeface or in Týr's boxes.
    /// Worth reporting once rather than leaving someone to wonder.
    pub fn hasFace(c: Chrome) bool {
        return c.face != Fonts.fallback_font;
    }

    /// Creates the atlas on the device and registers it on both lists, in the
    /// one order that makes the three ids the same number.
    ///
    /// `under` records no glyphs and never samples this. It is registered
    /// anyway, because ids are handed out in creation order on both sides and
    /// `read.zig` asserts that a page's device id equals its list id --
    /// skipping this one here would put every page slot one ahead on the
    /// list for the rest of the session.
    pub fn attach(
        c: *Chrome,
        renderer: *lyngvi.Renderer,
        under: *DrawList,
        over: *DrawList,
    ) !void {
        const width = c.fonts.atlasWidth();
        const height = c.fonts.atlasHeight();

        const on_device = try renderer.createTexture(width, height, .coverage);
        const in_under = try under.registerTexture(width, height);
        const in_over = try over.registerTexture(width, height);
        std.debug.assert(on_device == in_under and on_device == in_over);

        c.atlas = on_device;
        c.atlas_height = height;
    }

    /// Starts a frame. `input` is the same frame's input the keymap read: the
    /// UI derives presses by comparing with last frame and consumes nothing,
    /// so both may have it.
    pub fn begin(c: *Chrome, viewport: Bounds, input: thviti.Input) !void {
        c.fonts.beginFrame();
        try c.ui.begin(viewport, input);
    }

    pub fn end(c: *Chrome) void {
        c.ui.end();
    }

    /// The mode line, for a reader that does not want to know how one is
    /// built.
    pub fn status(c: *Chrome, st: Status) !void {
        return statusBar(&c.ui, c.face, c.theme, st);
    }

    /// The solved tree, as instances on `over`, plus whatever rows Týr
    /// rasterised this frame, as an upload.
    ///
    /// A settled interface uploads nothing: the glyphs of a status bar are in
    /// the atlas after the first frame that drew them, and `takeDirty`
    /// answers null from then on.
    pub fn flush(
        c: *Chrome,
        over: *DrawList,
        under: *DrawList,
        renderer: *lyngvi.Renderer,
        uploads: *std.ArrayList(lyngvi.Renderer.Upload),
    ) !void {
        try c.painter.render(over, &c.ui, &c.fonts, c.atlas);
        if (c.atlas == 0) return;

        const width = c.fonts.atlasWidth();
        if (c.fonts.atlasHeight() != c.atlas_height) {
            // The atlas doubled. Every packed rectangle is still where it was
            // -- Týr grows downwards for this reason -- but the image is a
            // different size, so it goes up whole and both lists are told.
            c.atlas_height = c.fonts.atlasHeight();
            try renderer.resizeTexture(c.atlas, width, c.atlas_height);
            under.setTextureSize(c.atlas, width, c.atlas_height);
            over.setTextureSize(c.atlas, width, c.atlas_height);
            _ = c.fonts.takeDirty();
            try uploads.append(c.gpa, .{
                .texture = c.atlas,
                .x = 0,
                .y = 0,
                .w = width,
                .h = c.atlas_height,
                .pixels = c.fonts.atlasPixels(),
                .stride = width,
            });
        } else if (c.fonts.takeDirty()) |dirty| {
            try uploads.append(c.gpa, .{
                .texture = c.atlas,
                .x = dirty.x,
                .y = dirty.y,
                .w = dirty.w,
                .h = dirty.h,
                .pixels = c.fonts.atlasPixels(),
                .stride = width,
            });
        }
    }
};

/// What the bar says, as the reader knows it.
///
/// Strings and numbers and nothing else -- no view, no buffer, no document --
/// so that what the bar looks like for a given state is a question with an
/// answer, asked in a test.
pub const Status = struct {
    /// `-- VISUAL --`, or empty in normal mode.
    mode: []const u8 = "",
    /// The `:` line or the note being typed, drawn with a block after it.
    /// Null when nothing is being typed.
    typing: ?[]const u8 = null,
    /// What is written on the highlight in hand, in edit mode.
    note: []const u8 = "",
    /// What just happened, or why a key did nothing.
    message: []const u8 = "",

    title: []const u8 = "",
    /// Numbered from 1, as a person numbers them.
    page: u32 = 1,
    pages: u32 = 1,
    percent: f32 = 100,
    /// The zoom follows the window's width rather than being a number.
    fit_width: bool = false,
    /// Shown only when there is more than one.
    windows: u32 = 1,
};

/// The mode line, along the bottom of the window.
///
/// Two groups, and which is which is the whole layout. On the left, what you
/// are doing: the mode, what is being typed in it, and what the reader last
/// had to say. On the right, where you are: the zoom, the page, the document.
/// The left half changes with every key and the right half changes when you
/// move, and a person watching one is not watching the other.
///
/// The left group is the one that yields. It asks for the whole bar at a
/// strictness of zero and the right group asks for exactly its children at a
/// strictness of one, so a shortfall comes out of the left entirely -- and
/// because the left group clips, a message longer than the window is cut off
/// at the page number rather than pushing it out of the window. That is one
/// rule, in the sizes, instead of measuring a string and eliding it every
/// frame.
pub fn statusBar(ui: *UI, face: Fonts.FontId, t: Theme, st: Status) !void {
    ui.pushStyle(.{ .font = face, .font_size = status_text, .fg = t.text_dim });
    defer ui.popStyle();

    ui.next(.{
        .w = .fill,
        .h = .px(status_height),
        .axis = .x,
        .child_align = .center,
        .fixed_y = ui.viewport.height() - status_height,
        .bg = t.panel,
        .flags = .{ .floating_y = true, .draw_background = true, .clip = true },
    });
    const bar = try ui.open("status");
    defer ui.close(bar);

    {
        ui.next(.{
            .w = .fill,
            .h = .fill,
            .axis = .x,
            .child_align = .center,
            // Overflowing rather than squeezing: a message too long for the
            // room is cut, not condensed into unreadable text.
            .flags = .{ .clip = true, .overflow_x = true },
        });
        const left = try ui.open("left");
        defer ui.close(left);

        try w.spacer(ui, .px(gutter));

        if (st.mode.len != 0) {
            // The one thing in the bar drawn in the foreground: which mode
            // you are in is the question the bar exists to answer.
            ui.next(.{ .fg = t.text });
            _ = try w.labelf(ui, "{s}###mode", .{clamp(st.mode, 32)});
            try w.spacer(ui, .px(gutter));
        }

        if (st.typing) |line| {
            // A block rather than a caret: there is no blink here, and a thin
            // line that does not blink reads as part of the text.
            ui.next(.{ .fg = t.text });
            _ = try w.labelf(ui, "{s}_###typing", .{clamp(line, 400)});
            try w.spacer(ui, .px(gutter));
        }

        if (st.note.len != 0) {
            _ = try w.labelf(ui, "\"{s}\"###note", .{clamp(st.note, 400)});
            try w.spacer(ui, .px(gutter));
        }

        if (st.message.len != 0) {
            _ = try w.labelf(ui, "{s}###message", .{clamp(st.message, 400)});
        }
    }

    {
        ui.next(.{ .w = .children, .h = .fill, .axis = .x, .child_align = .center });
        const right = try ui.open("right");
        defer ui.close(right);

        if (st.windows > 1) {
            _ = try w.labelf(ui, "{d} windows###windows", .{st.windows});
            try w.spacer(ui, .px(gutter));
        }

        if (st.fit_width) {
            _ = try w.labelf(ui, "fit width###fit", .{});
            try w.spacer(ui, .px(gutter));
        }

        _ = try w.labelf(ui, "{d:.0}%###zoom", .{st.percent});
        try w.spacer(ui, .px(gutter));
        _ = try w.labelf(ui, "{d} / {d}###page", .{ st.page, st.pages });
        try w.spacer(ui, .px(gutter));

        ui.next(.{ .fg = t.text });
        _ = try w.labelf(ui, "{s}###title", .{clamp(st.title, 160)});
        try w.spacer(ui, .px(gutter));
    }
}

fn clamp(s: []const u8, limit: usize) []const u8 {
    return s[0..@min(s.len, limit)];
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const key = thviti.key;

/// The bar, solved, with no font layer and no device. `UI.fixed_metrics` has
/// a half-em advance, so every width below is arithmetic rather than a
/// typeface's opinion.
fn solve(ui: *UI, st: Status) !void {
    try ui.begin(.fromRect(0, 0, 900, 600), .{});
    try statusBar(ui, Fonts.fallback_font, .dark, st);
    ui.end();
}

fn group(ui: *UI, name: []const u8) *thviti.Box {
    return ui.find(key.make(key.make(ui.root.key, "status"), name)).?;
}

test "the bar sits along the bottom of the window, whatever is in it" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    try solve(&ui, .{ .title = "paper.pdf", .page = 7, .pages = 48 });

    const bar = ui.root.first.?;
    try testing.expectEqual(@as(f32, 600 - status_height), bar.rect.min_y);
    try testing.expectEqual(@as(f32, 600), bar.rect.max_y);
    try testing.expectEqual(@as(f32, 900), bar.rect.width());
}

test "what you are doing is at the near end and where you are at the far one" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    try solve(&ui, .{
        .mode = "-- VISUAL --",
        .title = "paper.pdf",
        .page = 7,
        .pages = 48,
        .percent = 138,
    });

    const left = group(&ui, "left");
    const mode = left.first.?.next.?;
    try testing.expectEqualStrings("-- VISUAL --", mode.text);
    try testing.expectEqual(@as(f32, gutter), mode.rect.min_x);

    // The title is the last thing before the closing gutter, and ends a
    // gutter short of the window's edge.
    const right = group(&ui, "right");
    const title = right.last.?.prev.?;
    try testing.expectEqualStrings("paper.pdf", title.text);
    try testing.expectApproxEqAbs(@as(f32, 900 - gutter), title.rect.max_x, 0.5);
}

test "a bar in normal mode with nothing to say says only where you are" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    try solve(&ui, .{ .title = "a.pdf", .page = 1, .pages = 1 });

    var labels: u32 = 0;
    var it = group(&ui, "left").children();
    while (it.next()) |child| {
        if (child.text.len != 0) labels += 1;
    }
    try testing.expectEqual(@as(u32, 0), labels);

    it = group(&ui, "right").children();
    while (it.next()) |child| {
        if (child.text.len != 0) labels += 1;
    }
    // Zoom, page, title. No window count and no fit, because there is one
    // window and the zoom is a number.
    try testing.expectEqual(@as(u32, 3), labels);
}

test "a label that counts keeps its identity when only the number moves" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    // After the first frame, not before: `ui.root` does not exist until
    // `begin` has made one, and a key seeded from it beforehand is a hash of
    // whatever was on the stack.
    try solve(&ui, .{ .title = "a.pdf", .page = 7, .pages = 48 });
    const id = key.make(key.make(key.make(ui.root.key, "status"), "right"), "page");
    const first = ui.find(id).?;

    try solve(&ui, .{ .title = "a.pdf", .page = 8, .pages = 48 });
    const second = ui.find(id).?;

    // The same box, so turning a page does not restart its animation.
    try testing.expectEqual(first, second);
    try testing.expectEqualStrings("8 / 48", second.text);
}

test "a message longer than the window cannot push the page number off it" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    const long = "x" ** 600;
    try solve(&ui, .{ .message = long, .title = "a.pdf", .page = 3, .pages = 9 });

    const left = group(&ui, "left");
    const right = group(&ui, "right");

    // The left group gave up every pixel the right group needed, and what it
    // could not fit is clipped inside it rather than drawn over the top.
    try testing.expect(left.rect.max_x <= right.rect.min_x + 0.5);
    try testing.expectApproxEqAbs(@as(f32, 900), right.rect.max_x, 0.5);
    try testing.expect(right.rect.width() > 0);
    try testing.expect(left.flags.clip);
}
