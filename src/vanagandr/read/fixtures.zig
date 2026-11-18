//! What the reader's tests stand on: a session of blank pages with no
//! document behind them, and the few things a test hands one.
//!
//! Only tests reach this file, so none of it is in a binary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fenrir = @import("fenrir");

const Library = @import("../library.zig").Library;
const Session = @import("Session.zig");

const galdr = fenrir.galdr;
const gelgja = fenrir.gelgja;
const text = fenrir.hlidskjalf.text;

const caps = fenrir.build_options;

/// Hands a test session a library, or skips the test in a build with none.
///
/// A test cannot write `s.library = lib` directly: in a build with no
/// database the field has no payload type, by design -- see `Session.library`.
/// The assignment lives inside the comptime branch so it is analysed only
/// where it means something, which is what lets `-Dsqlite=false` compile its
/// test binary and skip rather than fail. `if (!caps.sqlite) return
/// error.SkipZigTest;` would not do: the line after it would still be
/// analysed.
pub fn giveLibrary(s: *Session, lib: Library) error{SkipZigTest}!void {
    if (caps.sqlite) {
        s.library = lib;
        return;
    }
    return error.SkipZigTest;
}

/// The same, for Galdr. `-Dlua=false` skips these tests rather than failing
/// to compile them.
pub fn givePlugins(s: *Session, rt: *galdr.Runtime) error{SkipZigTest}!void {
    if (caps.lua) {
        s.plugins = rt;
        return;
    }
    return error.SkipZigTest;
}

/// `n` identical Letter-sized pages, with nothing in them: the layout reads
/// only the boxes, so a page needs no document behind it to be laid out.
pub fn fakePages(buf: []fenrir.Page, n: usize) []fenrir.Page {
    const letter: fenrir.Page.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 600, .y1 = 800 };
    for (buf[0..n], 0..) |*p, i| p.* = .{
        .index = @intCast(i),
        .ref = .{ .num = 0, .gen = 0 },
        .dict = .empty,
        .resources = .empty,
        .media_box = letter,
        .crop_box = letter,
        .rotate = .none,
    };
    return buf[0..n];
}

/// A session with one buffer of `n` blank pages and one window on it. No
/// document: everything tested here reads `pages` and the caches.
pub fn sessionOf(gpa: Allocator, pages: []fenrir.Page, zoom: f32, w: f32, h: f32) !Session {
    var s: Session = .{
        .ctx = undefined,
        .gpa = gpa,
        .samples = .four,
        .palette_text = if (caps.panels) .init(gpa) else {},
    };
    errdefer s.deinit();
    try s.buffers.append(gpa, .{
        .path = try gpa.dupe(u8, "/docs/a.pdf"),
        .title = "a.pdf",
        .pages = pages,
    });
    s.next_doc_handle += 1;
    try s.doc_handles.append(gpa, s.next_doc_handle);
    try s.tabs.init(gpa, .{ .buffer = 0, .pages = pages, .zoom = zoom });
    s.tabs.arrange(.fromRect(0, 0, w, h));
    return s;
}

/// `Session.deinit` frees documents, and a test session has none.
pub fn closeSession(s: *Session) void {
    s.cmdline.deinit(s.gpa);
    s.stroking.deinit(s.gpa);
    s.note.deinit(s.gpa);
    s.comment_order.deinit(s.gpa);
    if (caps.panels) {
        s.palette_rows.deinit(s.gpa);
        s.palette_text.deinit();
        s.rail_left.deinit(s.gpa);
        s.rail_right.deinit(s.gpa);
        s.plugin_settings.deinit(s.gpa);
        s.rail_panels.deinit(s.gpa);
        s.rows.deinit(s.gpa);
    }
    s.doc_handles.deinit(s.gpa);
    s.search.deinit(s.gpa);
    s.recorded.deinit(s.gpa);
    s.tabs.deinit(s.gpa);
    if (caps.splits) {
        s.tab_names.deinit(s.gpa);
        s.tab_text.deinit(s.gpa);
        s.tab_ends.deinit(s.gpa);
    }
    for (s.disks.items) |*d| d.deinit(s.gpa, null);
    s.disks.deinit(s.gpa);
    for (s.buffers.items) |*b| {
        b.marks.deinit(s.gpa);
        for (&b.maps) |*m| m.map.deinit(s.gpa);
        s.gpa.free(b.path);
    }
    s.buffers.deinit(s.gpa);
}

/// `rows` lines of `cols` glyphs each, twenty points apart, as page `page`'s
/// text map in buffer 0. Words are two glyphs long.
/// `rows` lines of `cols` glyphs, as two words a line.
///
/// Two runs and not one, because that is the only shape a word gap can
/// reach this layer in: a `TJ` kern moves the text matrix and so ends the
/// run, which means the next word starts a few points right of where the
/// last one finished. Inside a run the glyphs are flush against each other,
/// and `w` has nothing to stop at.
pub fn putText(s: *Session, page: u32, rows: usize, cols: usize) !void {
    const gpa = s.gpa;
    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, rows * cols);
    defer gpa.free(glyphs);
    const cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, rows * 2);
    defer gpa.free(cmds);

    const word = @max(cols / 2, 1);
    const advance = 10 * @as(f32, @floatFromInt(word));
    for (0..rows) |row| {
        for (0..cols) |col| {
            const within: f32 = @floatFromInt(col % word);
            glyphs[row * cols + col] = .{ .code = 'a', .offset = .{ .x = 10 * within, .y = 0 } };
        }
        for (0..2) |w| {
            const first = row * cols + w * word;
            cmds[row * 2 + w] = .{ .text = .{
                .size = 10,
                .transform = .translation(
                    100 + @as(f32, @floatFromInt(w)) * (advance + 6),
                    700 - 20 * @as(f32, @floatFromInt(row)),
                ),
                .glyphs = .{ .start = @intCast(first), .count = @intCast(@min(word, cols - w * word)) },
                .advance = advance,
            } };
        }
    }
    s.buffer(0).putMap(gpa, page, try text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds }));
}
