//! The icon registry: namespaced ids, slots, and what draws each one.
//!
//! Icons are **declared, never embedded**. A toolbar asks for
//! `fenrir.bookmark`; a plugin asks for `notes.pin`; neither of them knows
//! whether the answer is path data compiled into the binary, a glyph of a
//! Nerd Font found on the machine, or the hollow box that means nobody has
//! said. That indirection is the whole file, and it is what makes an icon
//! theme a mapping table rather than a rebuild.
//!
//! ## The id is a number, and the name is only how you get one
//!
//! `plugin_id.icon_name`, interned to a `u32` the first time it is seen. The
//! namespace is not decoration: two plugins will eventually both want to be
//! called `pin`, and a registry that let the second one silently take the
//! first one's icon would be a bug nobody could see. Core icons are
//! `fenrir.bookmark`, `fenrir.search` and the rest of `tyr.icons.builtin`,
//! registered here at `init` so that the ids exist before anything asks.
//!
//! An id can be interned with no source at all. That is deliberate: a command
//! table naming `fenrir.redact` should compile, print and be searchable in a
//! build where nothing draws it yet, and get its picture the day something
//! registers one.
//!
//! ## Resolution, and why the last resort is visible
//!
//! Per slot: the user's theme, then the theme's default, then whoever
//! registered the icon, then `fenrir.unknown` -- which is a hollow box and
//! not nothing. Týr's `.notdef` makes the same argument: an icon that fails
//! to resolve and draws nothing is indistinguishable from a toolbar that is
//! correctly empty, and the difference is what somebody has to debug.
//!
//! ## A source is resolved once, at registration
//!
//! `Source` is what a caller says; `Resolved` is a font id and the bytes to
//! put in a box, worked out immediately and never again. Path data is handed
//! to the icon face's `Set` at that moment and becomes a glyph exactly like a
//! built-in one, so nothing downstream can tell a themed icon from a
//! compiled-in one -- and `resolve` on a frame path is two array indexes and
//! no work at all. That is the rule from `CLAUDE.md` about doing nothing per
//! frame that can be done on change, applied where the change is a
//! registration.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Fonts = @import("../tyr/Fonts.zig");
const face_icons = @import("../tyr/backend/icons.zig");

const Icons = @This();

/// An interned icon name. Small and copyable, because it travels through
/// command tables, menu rows and plugin declarations.
pub const Id = u32;

/// Always registered, always first, and what everything that fails resolves
/// to.
pub const unknown: Id = 0;

/// The namespace the icons in this binary are registered under.
pub const core = "fenrir";

pub const Error = error{
    /// Not `plugin_id.icon_name`.
    BadIconName,
    OutOfMemory,
};

/// Where an icon is drawn, which is the same thing as how big it is.
///
/// A size rather than a number at the call site, because the sizes have to
/// agree across a window -- a menu whose icons are a pixel bigger than the
/// tab bar's reads as a mistake even to someone who cannot say what is wrong
/// -- and because a per-slot source override has to have something to name.
pub const Slot = enum {
    toolbar_large,
    toolbar_small,
    sidebar,
    statusbar,
    menu,
    tab,

    pub fn px(s: Slot) f32 {
        return switch (s) {
            .toolbar_large => 24,
            .toolbar_small => 16,
            .sidebar => 20,
            .statusbar => 14,
            .menu => 16,
            .tab => 16,
        };
    }
};

const slot_count = @typeInfo(Slot).@"enum".fields.len;

/// What an icon is drawn from, as whoever registers it says so.
pub const Source = union(enum) {
    /// Path data on the icon face's grid. Rasterised at the slot's size and
    /// therefore exact at every one of them.
    path: []const u8,
    /// A glyph of a face that is already open -- a Nerd Font, a Material
    /// font -- named by the code point that reaches it, because a code point
    /// is what a theme author has and a glyph index is not.
    glyph: Glyph,
};

pub const Glyph = struct {
    font: Fonts.FontId,
    cp: u21,
};

/// What a call site draws: which face, which bytes, how big.
///
/// The bytes live in the registry's arena and stay valid for its lifetime, so
/// this can be held across a frame -- though there is no reason to, since
/// resolving again costs nothing.
pub const Drawn = struct {
    font: Fonts.FontId,
    text: []const u8,
    px: f32,
};

/// One source, already turned into something drawable.
const Resolved = struct {
    font: Fonts.FontId,
    text: []const u8,
};

/// A set of sources from one authority: a default for every slot, and
/// overrides for the slots that want something else.
const Layer = struct {
    any: ?Resolved = null,
    slots: [slot_count]?Resolved = @splat(null),

    fn at(l: Layer, s: Slot) ?Resolved {
        return l.slots[@intFromEnum(s)] orelse l.any;
    }

    fn put(l: *Layer, r: Resolved, slot: ?Slot) void {
        if (slot) |s| l.slots[@intFromEnum(s)] = r else l.any = r;
    }
};

const Entry = struct {
    name: []const u8,
    /// Whoever registered the icon.
    default: Layer = .{},
    /// The user's icon theme, which outranks it.
    theme: Layer = .{},
};

gpa: Allocator,
/// Names and encoded code points. An arena because every one of them lives
/// as long as the registry and none is ever freed alone.
arena: std.heap.ArenaAllocator,
entries: std.ArrayList(Entry) = .empty,
by_name: std.StringHashMapUnmanaged(Id) = .empty,

/// The face the built-in icons and every `.path` source are drawn by.
font: Fonts.FontId,
/// Its glyph table, which `.path` sources are added to. Borrowed: `Fonts`
/// owns the face and closes it, so a registry must not outlive the `Fonts`
/// it was built against -- the same rule `Chrome` follows for its metrics
/// vtable.
set: *face_icons.Set,

/// Opens an icon face on `fonts`, registers every built-in icon under
/// `fenrir.`, and returns a registry that can answer for all of them.
///
/// `fonts` is borrowed and must outlive the result.
pub fn init(gpa: Allocator, fonts: *Fonts) Error!Icons {
    const opened = face_icons.create(gpa) catch return error.OutOfMemory;
    const font = fonts.addFace(opened) catch |err| {
        var f = opened;
        f.deinit(gpa);
        return err;
    };

    var i: Icons = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .font = font,
        // Just created by `create`, so this cannot be anything else.
        .set = face_icons.setOf(fonts.face(font)).?,
    };
    errdefer i.deinit();

    var buf: [64]u8 = undefined;
    for (face_icons.builtin, 0..) |b, n| {
        const name = std.fmt.bufPrint(&buf, core ++ ".{s}", .{b.name}) catch
            return error.OutOfMemory;
        const id = try i.intern(name);
        i.entries.items[id].default.any = .{
            .font = font,
            .text = try i.encode(@intCast(n)),
        };
    }
    return i;
}

pub fn deinit(i: *Icons) void {
    i.entries.deinit(i.gpa);
    i.by_name.deinit(i.gpa);
    i.arena.deinit();
    i.* = undefined;
}

pub fn count(i: *const Icons) usize {
    return i.entries.items.len;
}

pub fn find(i: *const Icons, name: []const u8) ?Id {
    return i.by_name.get(name);
}

pub fn nameOf(i: *const Icons, id: Id) []const u8 {
    if (id >= i.entries.items.len) return i.entries.items[unknown].name;
    return i.entries.items[id].name;
}

/// Which layer a slot's icon is actually coming from. What `fenrir icons`
/// prints a column for: a theme that silently fails to take effect is
/// otherwise indistinguishable from one that had nothing to say.
pub const Origin = enum { theme, registered, none };

pub fn originOf(i: *const Icons, id: Id, slot: Slot) Origin {
    if (id >= i.entries.items.len) return .none;
    const e = i.entries.items[id];
    if (e.theme.at(slot) != null) return .theme;
    if (e.default.at(slot) != null) return .registered;
    return .none;
}

/// True when something has actually said how this icon is drawn.
pub fn isDrawn(i: *const Icons, id: Id, slot: Slot) bool {
    return i.originOf(id, slot) != .none;
}

/// The id for a name, made if this is the first time it has been seen.
///
/// An interned id with no source resolves to `unknown` and is not an error:
/// naming an icon and drawing one are separate acts, and they happen in that
/// order.
pub fn intern(i: *Icons, name: []const u8) Error!Id {
    if (!validName(name)) return error.BadIconName;
    if (i.by_name.get(name)) |id| return id;
    if (i.entries.items.len > std.math.maxInt(Id)) return error.OutOfMemory;

    const owned = try i.arena.allocator().dupe(u8, name);
    const id: Id = @intCast(i.entries.items.len);
    try i.entries.append(i.gpa, .{ .name = owned });
    errdefer _ = i.entries.pop();
    try i.by_name.put(i.gpa, owned, id);
    return id;
}

/// Interns `name` and says how to draw it. `slot` null is the default for
/// every slot; a slot names an override for that one alone.
pub fn register(i: *Icons, name: []const u8, src: Source, slot: ?Slot) Error!Id {
    const id = try i.intern(name);
    if (try i.resolveSource(name, src)) |r| i.entries.items[id].default.put(r, slot);
    return id;
}

/// What an icon theme says, which outranks what the icon was registered with.
/// Unknown ids are interned rather than refused: a theme is allowed to
/// mention an icon a plugin has not loaded yet.
pub fn override(i: *Icons, name: []const u8, src: Source, slot: ?Slot) Error!Id {
    const id = try i.intern(name);
    if (try i.resolveSource(name, src)) |r| i.entries.items[id].theme.put(r, slot);
    return id;
}

/// Forgets the theme layer, leaving every registration intact. What reloading
/// a theme does first, so that an icon the new theme does not mention goes
/// back to its default instead of keeping the old theme's.
///
/// The glyphs the old theme added to the face stay there, unreferenced. They
/// are a few hundred bytes apiece and the alternative is a face that can
/// renumber its glyphs, which would invalidate every atlas entry keyed on
/// one.
pub fn clearTheme(i: *Icons) void {
    for (i.entries.items) |*e| e.theme = .{};
}

/// Which face, which bytes, how big -- following the resolution order.
/// Never fails: the last resort is the hollow box.
pub fn resolve(i: *const Icons, id: Id, slot: Slot) Drawn {
    const px = slot.px();
    if (id < i.entries.items.len) {
        const e = i.entries.items[id];
        if (e.theme.at(slot) orelse e.default.at(slot)) |r| {
            return .{ .font = r.font, .text = r.text, .px = px };
        }
    }
    const box = i.entries.items[unknown].default.any.?;
    return .{ .font = box.font, .text = box.text, .px = px };
}

/// `resolve` by name, for a call site holding a string rather than an id --
/// a Lua table, a `:` command. Unknown names draw the box.
pub fn byName(i: *const Icons, name: []const u8, slot: Slot) Drawn {
    return i.resolve(i.find(name) orelse unknown, slot);
}

/// Null for a source that cannot be drawn at all, which leaves the layer as
/// it was and lets the icon fall through to whatever is behind it. Refusing
/// the whole registration instead would cost a theme every icon after its
/// first typo.
fn resolveSource(i: *Icons, name: []const u8, src: Source) Error!?Resolved {
    switch (src) {
        .path => |d| {
            // Named in the face by the id it is registered under, so that a
            // glyph dump and an icon listing can be read side by side.
            const g = i.set.add(name, d) catch return error.OutOfMemory;
            return .{ .font = i.font, .text = try i.encode(g) };
        },
        .glyph => |g| {
            const text = try i.encodePoint(g.cp) orelse return null;
            return .{ .font = g.font, .text = text };
        },
    }
}

fn encode(i: *Icons, g: u16) Error![]const u8 {
    // The private use area is a code point whatever the glyph index is.
    return (try i.encodePoint(face_icons.codepoint(g))).?;
}

fn encodePoint(i: *Icons, cp: u21) Error!?[]const u8 {
    var buf: [4]u8 = undefined;
    // A surrogate, or past the end of Unicode: there is no string that draws
    // it, so there is nothing to register.
    const n = std.unicode.utf8Encode(cp, &buf) catch return null;
    return try i.arena.allocator().dupe(u8, buf[0..n]);
}

/// `plugin_id.icon_name`: two non-empty parts, one dot, and nothing in either
/// that would have to be quoted in a Lua table key or a command line.
fn validName(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0 or dot + 1 == name.len) return false;
    if (std.mem.indexOfScalarPos(u8, name, dot + 1, '.') != null) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn scratch(fonts: *Fonts) !Icons {
    return Icons.init(testing.allocator, fonts);
}

test "every built-in icon is registered, and the box is first" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    try testing.expectEqual(face_icons.builtin.len, icons.count());
    try testing.expectEqualStrings("fenrir.unknown", icons.nameOf(unknown));
    try testing.expectEqual(@as(?Id, unknown), icons.find("fenrir.unknown"));

    const b = icons.find("fenrir.bookmark").?;
    try testing.expect(icons.isDrawn(b, .sidebar));
    // Drawn by the icon face, not by the text face it shares a `Fonts` with.
    try testing.expectEqual(icons.font, icons.resolve(b, .sidebar).font);
    try testing.expect(icons.font != Fonts.fallback_font);
}

test "a slot is a size, and the source does not change with it" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    const id = icons.find("fenrir.search").?;
    const big = icons.resolve(id, .toolbar_large);
    const small = icons.resolve(id, .statusbar);

    try testing.expectEqual(@as(f32, 24), big.px);
    try testing.expectEqual(@as(f32, 14), small.px);
    try testing.expectEqualStrings(big.text, small.text);
}

test "an id is interned once and keeps its number" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    const before = icons.count();
    const a = try icons.intern("notes.pin");
    const b = try icons.intern("notes.pin");
    try testing.expectEqual(a, b);
    try testing.expectEqual(before + 1, icons.count());

    // Interned and undrawn: the id exists, and drawing it gives the box.
    try testing.expect(!icons.isDrawn(a, .menu));
    try testing.expectEqualStrings(
        icons.resolve(unknown, .menu).text,
        icons.resolve(a, .menu).text,
    );
}

test "a name is a namespace and a name" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    for ([_][]const u8{ "pin", ".pin", "notes.", "notes.a.b", "Notes.pin", "notes pin", "" }) |bad| {
        try testing.expectError(error.BadIconName, icons.intern(bad));
    }
    _ = try icons.intern("notes2.pin_2");
}

test "path data becomes a glyph of the icon face" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    const id = try icons.register("notes.pin", .{ .path = "M4 4h16v16H4z" }, null);
    const d = icons.resolve(id, .sidebar);
    try testing.expectEqual(icons.font, d.font);

    // It reached the face under its own registered name, and draws.
    const face = fonts.face(icons.font);
    const g = face.glyphForName("notes.pin").?;
    try testing.expectEqual(face_icons.codepoint(g), try std.unicode.utf8Decode(d.text));

    var o = @import("../tyr/Outline.zig"){};
    defer o.deinit(gpa);
    try face.outline(gpa, g, &o);
    try testing.expectEqual(@as(u32, 1), o.contourCount());
}

test "a glyph source draws from the face it names" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    // Whatever a theme opened -- here the text face standing in for a Nerd
    // Font, which is all this registry ever knows about it.
    const nerd: Fonts.FontId = Fonts.fallback_font;
    const id = try icons.register("nerd.folder", .{ .glyph = .{ .font = nerd, .cp = 0xf07b } }, null);

    const d = icons.resolve(id, .menu);
    try testing.expectEqual(nerd, d.font);
    try testing.expectEqual(@as(u21, 0xf07b), try std.unicode.utf8Decode(d.text));
}

test "the theme outranks the registration, and a slot outranks both" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    const id = try icons.register("notes.pin", .{ .path = "M4 4h16v16H4z" }, null);
    const registered = icons.resolve(id, .menu).text;

    _ = try icons.override("notes.pin", .{ .glyph = .{ .font = 0, .cp = 0xf100 } }, null);
    const themed = icons.resolve(id, .menu).text;
    try testing.expect(!std.mem.eql(u8, registered, themed));

    // A per-slot override applies to its slot and leaves the others alone.
    _ = try icons.override("notes.pin", .{ .glyph = .{ .font = 0, .cp = 0xf101 } }, .tab);
    try testing.expectEqual(@as(u21, 0xf101), try std.unicode.utf8Decode(icons.resolve(id, .tab).text));
    try testing.expectEqual(@as(u21, 0xf100), try std.unicode.utf8Decode(icons.resolve(id, .menu).text));

    // And dropping the theme goes back to the registration rather than to the
    // box -- the failure a reload would otherwise have.
    icons.clearTheme();
    try testing.expectEqualStrings(registered, icons.resolve(id, .menu).text);
}

test "a theme may name an icon nothing has registered" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    const id = try icons.override("future.redact", .{ .path = "M4 4h16v4H4z" }, null);
    try testing.expect(icons.isDrawn(id, .toolbar_small));
    try testing.expectEqual(@as(?Id, id), icons.find("future.redact"));
}

test "an id nobody ever registered resolves to the box" {
    const gpa = testing.allocator;
    var fonts: Fonts = try .init(gpa, .{});
    defer fonts.deinit();
    var icons = try scratch(&fonts);
    defer icons.deinit();

    const box = icons.resolve(unknown, .tab);
    try testing.expectEqualStrings(box.text, icons.resolve(9999, .tab).text);
    try testing.expectEqualStrings(box.text, icons.byName("nothing.at.all", .tab).text);
    try testing.expectEqualStrings("fenrir.unknown", icons.nameOf(9999));
}
