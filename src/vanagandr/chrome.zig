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

const rails = @import("rails.zig");
const sysfont = @import("sysfont.zig");

const Bounds = fenrir.gelgja.Bounds;
const DrawList = gleipnir.DrawList;
const Fonts = tyr.Fonts;
const Icons = thviti.Icons;
const Theme = thviti.Theme;
const UI = thviti.UI;
const w = thviti.widgets;

/// The bar along the bottom, in device pixels. Dense on purpose: it is a
/// mode line, not a dashboard.
pub const status_height: f32 = 26;
pub const status_text: f32 = 12;

/// The tab bar along the top, when there is one. The same height as the
/// status bar, and the widget's own number rather than a second one beside
/// it.
pub const tab_height: f32 = w.tabs.height;
/// The inset at either end of the bar, and between the things in it.
pub const gutter: f32 = 10;

/// Þviti, a face to draw it with, and the atlas the glyphs land in.
pub const Chrome = struct {
    gpa: Allocator,
    fonts: Fonts,
    /// The icon registry, which borrows `&fonts` and so cannot outlive it --
    /// the same rule the metrics vtable follows, and the other reason a
    /// `Chrome` is never returned by value.
    icons: Icons,
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

    /// The zoom control's own state. On the chrome and not in the box tree,
    /// for the reason a checkbox's bool is the caller's: the reader has to
    /// be able to ask whether a menu is open before it reads a key.
    zoom: Zoom = .{},

    /// The rails', for the same reason: a rail with a page number half typed
    /// into it is holding the digits, and that is asked before the keymap
    /// sees them.
    rails: rails.Rails = .{},

    /// The one tooltip a window can have. Drawn by `tips`, at the end of the
    /// frame, because a popup is on top only by being built last.
    tip: w.Tips = .{},

    /// How much of the window the chrome has taken off the top: the tab bar,
    /// when there is one. Set by the reader each frame, and read by the rails
    /// and the panel, which begin below it.
    ///
    /// Here rather than a parameter on each of them because all three are
    /// reached through this struct and it is one number about the window,
    /// not three about three widgets. It is the reader's to set because only
    /// the reader knows how many tabpages there are -- and it has to be known
    /// before any of this is built, since `windowRect` takes the same inset
    /// off the pages.
    top: f32 = 0,

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
            .icons = undefined,
            .ui = undefined,
            .painter = .init(gpa),
        };
        errdefer {
            c.painter.deinit();
            c.fonts.deinit();
        }
        // After `fonts` is at the address it will keep: the registry holds
        // the icon face's glyph table, which `Fonts` owns.
        c.icons = try .init(gpa, &c.fonts);
        errdefer c.icons.deinit();

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
        c.icons.deinit();
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
    /// built. Returns what the zoom control was asked for, if anything.
    pub fn status(c: *Chrome, st: Status) !?ZoomWant {
        return statusBar(&c.ui, c.face, c.theme, st, &c.zoom);
    }

    /// The rails, for a reader that does not want to know how one is built.
    /// Each returns what it was asked for, if anything.
    pub fn rightRail(c: *Chrome, st: rails.Right) !?rails.Want {
        return rails.rightRail(&c.ui, c.face, c.theme, &c.icons, st, &c.rails, &c.tip, c.top);
    }

    pub fn leftRail(c: *Chrome, st: rails.Left) !?rails.Want {
        return rails.leftRail(&c.ui, c.face, c.theme, &c.icons, st, &c.tip, c.top);
    }

    /// The tab bar along the top, and what was clicked on it.
    ///
    /// Nothing at all for a single tabpage: a bar showing one tab is a row of
    /// chrome that says what the title bar already says, and the reader looks
    /// exactly as it did before tabpages existed until somebody opens one.
    /// `top` is set from the same count, so the pages get the row back too.
    pub fn tabBar(c: *Chrome, labels: []const []const u8, active: u32) !?w.tabs.Result {
        if (labels.len < 2) return null;

        c.ui.pushStyle(.{
            .font = c.face,
            .font_size = status_text,
            .fg = c.theme.text,
            .bg = c.theme.panel,
            .border_color = c.theme.divider,
        });
        defer c.ui.popStyle();

        c.ui.next(.{
            .w = .px(c.ui.viewport.width()),
            .fixed_x = 0,
            .fixed_y = 0,
            .flags = .{ .floating_x = true, .floating_y = true },
        });
        return try w.tabBar(&c.ui, "tabs", labels, active, .{
            .h = tab_height,
            .accent = c.theme.accent,
            .add = true,
        });
    }

    /// The tooltip, if the pointer has been resting on something long enough.
    /// Last of everything: a popup is on top by being built last.
    pub fn tips(c: *Chrome) !void {
        return w.tool.tooltips(&c.ui, &c.tip);
    }

    /// Whether the interface is holding the keyboard and the pointer this
    /// frame, which it is while a menu is open or a rail is being typed in.
    pub fn grabbing(c: *const Chrome) bool {
        return c.zoom.menu.open or c.rails.grabbing();
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
    /// What the zoom is tied to -- "fit width", "fit page" -- or empty when
    /// it is a number nobody is moving. A string rather than `View.Fit`
    /// because `Status` is strings and numbers, and the bar has no business
    /// knowing what a view is.
    fit: []const u8 = "",
    /// Shown only when there is more than one.
    windows: u32 = 1,
};

/// What the zoom control was asked for.
///
/// A request, not an action: the bar has no view to act on and no idea what
/// one is, so it names what it was asked for and the reader carries it out.
/// The fit is the *word* `:fit` takes rather than a `View.Fit`, which keeps
/// this file's promise that a `Status` is strings and numbers -- and costs
/// nothing, since `View.Fit.byName` is the parser either way.
pub const ZoomWant = union(enum) {
    fit: []const u8,
    /// A percentage of the page's true physical size, as the bar shows it.
    percent: f32,
};

/// The zoom control's state, which is one menu.
pub const Zoom = struct {
    menu: w.Menu = .{},
};

/// What the menu offers, in the order it offers it. The rule above the line
/// is the fits, below it the sizes somebody might name.
const zoom_menu = struct {
    const Row = struct { []const u8, []const u8, ZoomWant };
    const fits = [_]Row{
        .{ "Fit width", "0", .{ .fit = "width" } },
        .{ "Fit height", "", .{ .fit = "height" } },
        .{ "Fit page", "", .{ .fit = "page" } },
        .{ "Actual size", "1", .{ .fit = "actual" } },
    };
    const sizes = [_]Row{
        .{ "50%", "", .{ .percent = 50 } },
        .{ "75%", "", .{ .percent = 75 } },
        .{ "100%", "", .{ .percent = 100 } },
        .{ "150%", "", .{ .percent = 150 } },
        .{ "200%", "", .{ .percent = 200 } },
        .{ "400%", "", .{ .percent = 400 } },
    };

    /// Known before the menu is built, so it can be placed *above* the bar
    /// rather than hanging off the bottom of the window for one frame while
    /// `popup.clampInto` works out how tall it turned out to be.
    const height: f32 = w.menu.padding * 2 +
        @as(f32, fits.len + sizes.len) * w.menu.item_height +
        w.menu.separator_height;
    const width: f32 = 180;
};

/// The zoom, as a control rather than a reading.
///
/// Built inside the bar; the menu it opens is built *after* the bar closes,
/// because a popup is on top by being built last and nothing here sorts.
fn zoomControl(ui: *UI, t: Theme, st: Status, z: *Zoom) !void {
    ui.next(.{
        .w = .children,
        .h = .fill,
        .axis = .x,
        .child_align = .center,
        .bg = t.panel,
        .flags = .{
            .clickable = true,
            .draw_background = true,
            .hot_animation = true,
            .active_animation = true,
        },
    });
    // Keyed and not labelled: it draws nothing of its own, and a container
    // carrying its key as text would be a label nobody wrote.
    const b = try ui.open("###zoom");
    const sig = ui.signal(b);
    {
        defer ui.close(b);
        try w.spacer(ui, .px(gutter * 0.6));
        if (st.fit.len != 0) {
            _ = try w.labelf(ui, "{s}###fit", .{clamp(st.fit, 32)});
            try w.spacer(ui, .px(gutter * 0.6));
        }
        ui.next(.{ .fg = t.text });
        _ = try w.labelf(ui, "{d:.0}%###percent", .{st.percent});
        try w.spacer(ui, .px(gutter * 0.6));
    }

    // Above the bar and aligned with the control's left edge. `b.rect` is
    // last frame's, which is the frame the person was looking at when they
    // clicked -- the same rectangle the signal is about.
    if (sig.clicked) z.menu.toggle(.{
        .x = b.rect.min_x,
        .y = ui.viewport.height() - status_height - zoom_menu.height,
    });
}

/// The menu, and what it was asked for. Built after everything else.
fn zoomMenu(ui: *UI, z: *Zoom) !?ZoomWant {
    const p = try w.menu.begin(ui, "zoom menu", &z.menu, .{ .w = .px(zoom_menu.width) }) orelse
        return null;
    defer w.menu.end(ui, &z.menu, p);

    var want: ?ZoomWant = null;
    for (zoom_menu.fits) |row| {
        if (try w.menu.item(ui, &z.menu, row[0], .{ .binding = row[1] })) want = row[2];
    }
    try w.menu.separator(ui);
    for (zoom_menu.sizes) |row| {
        if (try w.menu.item(ui, &z.menu, row[0], .{ .binding = row[1] })) want = row[2];
    }
    return want;
}

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
pub fn statusBar(ui: *UI, face: Fonts.FontId, t: Theme, st: Status, z: *Zoom) !?ZoomWant {
    ui.pushStyle(.{ .font = face, .font_size = status_text, .fg = t.text_dim });
    defer ui.popStyle();

    try modeLine(ui, t, st, z);
    return zoomMenu(ui, z);
}

fn modeLine(ui: *UI, t: Theme, st: Status, z: *Zoom) !void {
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

        try zoomControl(ui, t, st, z);
        try w.spacer(ui, .px(gutter * 0.4));

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
    var z: Zoom = .{};
    _ = try solveWith(ui, st, &z, .{});
}

/// The same, with the zoom control's state and this frame's input in hand:
/// what a test about the menu needs and what the rest does not.
fn solveWith(ui: *UI, st: Status, z: *Zoom, in: thviti.Input) !?ZoomWant {
    try ui.begin(.fromRect(0, 0, 900, 600), in);
    const want = try statusBar(ui, Fonts.fallback_font, .dark, st, z);
    ui.end();
    return want;
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
    // The page and the title. No window count, because there is one window;
    // the zoom is inside its own control and is counted below.
    try testing.expectEqual(@as(u32, 2), labels);

    // And inside the control, the percentage alone -- no fit, because the
    // zoom is a number nobody is holding to a shape.
    const zoom = ui.find(key.make(group(&ui, "right").key, "zoom")).?;
    var inner: u32 = 0;
    var kids = zoom.children();
    while (kids.next()) |child| {
        if (child.text.len != 0) inner += 1;
    }
    try testing.expectEqual(@as(u32, 1), inner);
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

    const long: [600]u8 = @splat('x');
    try solve(&ui, .{ .message = &long, .title = "a.pdf", .page = 3, .pages = 9 });

    const left = group(&ui, "left");
    const right = group(&ui, "right");

    // The left group gave up every pixel the right group needed, and what it
    // could not fit is clipped inside it rather than drawn over the top.
    try testing.expect(left.rect.max_x <= right.rect.min_x + 0.5);
    try testing.expectApproxEqAbs(@as(f32, 900), right.rect.max_x, 0.5);
    try testing.expect(right.rect.width() > 0);
    try testing.expect(left.flags.clip);
}

test "the zoom reads as a control and opens its menu above the bar" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var z: Zoom = .{};

    const st: Status = .{ .title = "a.pdf", .page = 1, .pages = 9, .percent = 138 };
    _ = try solveWith(&ui, st, &z, .{});

    const zoom = ui.find(key.make(group(&ui, "right").key, "zoom")).?;
    try testing.expect(zoom.flags.clickable);

    // Onto it, then press: a press only reaches a box the pointer was
    // already over, here as in a real mouse.
    const at: fenrir.gelgja.Point = .{
        .x = (zoom.rect.min_x + zoom.rect.max_x) * 0.5,
        .y = (zoom.rect.min_y + zoom.rect.max_y) * 0.5,
    };
    _ = try solveWith(&ui, st, &z, .{ .mouse = at });
    _ = try solveWith(&ui, st, &z, .{ .mouse = at, .buttons = .{ .left = true } });
    _ = try solveWith(&ui, st, &z, .{ .mouse = at });
    try testing.expect(z.menu.open);

    // Above the bar and not behind it, which is what knowing the height in
    // advance buys: the menu is placed rather than pushed.
    const menu = ui.find(key.make(ui.root.key, "zoom menu")).?;
    try testing.expectApproxEqAbs(600 - status_height, menu.rect.max_y, 0.5);

    // Sideways it starts at the control and is pushed back inside the window
    // -- which here it is, because the zoom sits near the right-hand end.
    try testing.expect(menu.rect.min_x <= zoom.rect.min_x + 0.5);
    try testing.expectApproxEqAbs(@as(f32, 900), menu.rect.max_x, 0.5);
}

test "a menu row names a fit in the words the command line takes" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var z: Zoom = .{};

    const st: Status = .{ .title = "a.pdf", .page = 1, .pages = 9, .percent = 100 };
    _ = try solveWith(&ui, st, &z, .{});
    z.menu.show(.{ .x = 40, .y = 600 - status_height - zoom_menu.height });
    _ = try solveWith(&ui, st, &z, .{});

    // The third fit, chosen with the keyboard: down three times and enter.
    // `Menu.fired` is what the arrows leave behind, and `item` reports it as
    // the row is built -- the same return a click comes back through.
    z.menu.highlight = 2;
    z.menu.fired = 2;
    const want = (try solveWith(&ui, st, &z, .{})).?;
    try testing.expectEqualStrings("page", want.fit);
    // And it closed itself on the way out.
    try testing.expect(!z.menu.open);
}

test "a percentage row asks for the number it is written with" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();
    var z: Zoom = .{};

    const st: Status = .{ .title = "a.pdf", .page = 1, .pages = 9, .percent = 100 };
    _ = try solveWith(&ui, st, &z, .{});
    z.menu.show(.{ .x = 40, .y = 0 });
    _ = try solveWith(&ui, st, &z, .{});

    const first_size: i32 = @intCast(zoom_menu.fits.len);
    z.menu.highlight = first_size;
    z.menu.fired = first_size;
    const want = (try solveWith(&ui, st, &z, .{})).?;
    try testing.expectApproxEqAbs(@as(f32, 50), want.percent, 0.001);
}

test "a fit shows its name beside the percentage, and a free zoom shows none" {
    var ui: UI = .init(testing.allocator, UI.fixed_metrics);
    defer ui.deinit();

    try solve(&ui, .{ .title = "a.pdf", .page = 1, .pages = 9, .fit = "fit page" });
    const zoom_key = key.make(group(&ui, "right").key, "zoom");
    try testing.expectEqualStrings("fit page", ui.find(key.make(zoom_key, "fit")).?.text);

    // A second UI rather than a second frame on this one: a box survives a
    // few frames after it stops being built, so asking this one whether the
    // label is gone would be asking whether `prune` has caught up yet.
    var plain: UI = .init(testing.allocator, UI.fixed_metrics);
    defer plain.deinit();
    try solve(&plain, .{ .title = "a.pdf", .page = 1, .pages = 9 });
    const plain_zoom = key.make(group(&plain, "right").key, "zoom");
    try testing.expect(plain.find(key.make(plain_zoom, "fit")) == null);
    try testing.expectEqualStrings("100%", plain.find(key.make(plain_zoom, "percent")).?.text);
}
