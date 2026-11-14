//! The reader as Galdr sees it: the `Host` a plugin's `fenrir.*` calls land
//! on, the runtime started and asked after, and the events a plugin hears.
//!
//! A file of its own so that all of it is in one place, and so that a build
//! with no Lua -- whose `Session.plugins` is `?noreturn` -- can leave the
//! file out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const library = @import("../library.zig");
const Library = library.Library;
const read = @import("../read.zig");
const Session = read.Session;
const Job = read.Job;

const galdr = fenrir.galdr;
const hlidskjalf = fenrir.hlidskjalf;

const Buffer = hlidskjalf.Buffer;
const Marks = hlidskjalf.Marks;
const View = hlidskjalf.View;
const keys = hlidskjalf.keys;

/// Finds the configuration directory, starts Galdr, and runs `init.lua`
/// and the plugins. Nothing here can stop the reader opening: a build
/// without Lua, a machine without a home, or a broken plugin each leave a
/// reader that works and a message saying what did not.
pub fn startPlugins(s: *Session, dir: ?[]const u8) void {
    if (!galdr.available) return;
    s.config_dir = if (dir) |d|
        s.gpa.dupe(u8, d) catch return
    else
        galdr.configDir(s.gpa, library.environment(s.ctx)) catch return;

    const rt = galdr.Runtime.create(s.gpa, host(s), .{}) catch |err| {
        s.ctx.note("plugins are off: {t}", .{err});
        return;
    };
    s.plugins = rt;
    rt.loadConfig();

    var broken: usize = 0;
    for (rt.plugins.items) |p| {
        if (!p.ok) broken += 1;
    }
    if (broken != 0) {
        s.ctx.note("{d} of {d} plugins failed to load; :messages shows why", .{ broken, rt.plugins.items.len });
        for (rt.messages.items) |m| s.ctx.note("{s}", .{m});
    }

    for (s.buffers.items, 0..) |b, at| {
        const doc = handleOf(s, @intCast(at));
        rt.emit(.{ .event = .DocOpen, .doc = doc, .path = b.path, .data = .{ .document = .{
            .handle = doc,
            .path = b.path,
            .title = b.title,
            .pages = @intCast(b.pages.len),
        } } });
    }
}

/// `:plugins`, and `:plugin` with nothing after it.
///
/// A plugin keeps its place in Galdr's list once it is unloaded -- that
/// is how a reload keeps the store namespace its values are already
/// under -- so the count is of what is in service and not of how long
/// the list has grown.
pub fn sayPlugins(s: *Session, rt: *galdr.Runtime) void {
    var live: usize = 0;
    for (rt.plugins.items) |p| {
        if (p.loaded) live += 1;
    }
    if (rt.plugins.items.len == 0) {
        s.say("no init.lua and no plugins/ -- nothing to load", .{});
        return;
    }
    var w: std.Io.Writer = .fixed(&s.status_buf);
    w.print("{d} loaded:", .{live}) catch {};
    for (rt.plugins.items) |p| {
        const how = if (!p.loaded) " (unloaded)" else if (!p.ok) " (failed)" else "";
        w.print(" {s}{s}", .{ p.name, how }) catch break;
    }
    s.status = s.status_buf[0..w.end];
    s.dirty_title = true;
}

/// `:plugin load|unload|reload NAME`.
///
/// What the reader borrows from Galdr -- a rail's label, a setting's
/// choices, the palette's rows -- is rebuilt when `Runtime.revision`
/// moves and the dead storage is given back at the top of `pump`, so
/// there is nothing to do here but say what happened: the next frame
/// picks it up.
pub fn lifecycle(s: *Session, rt: *galdr.Runtime, args: []const u8) bool {
    const cut = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
    const verb = args[0..cut];
    const who = std.mem.trim(u8, args[cut..], " \t");

    const reloading = std.mem.eql(u8, verb, "reload");
    const loading = std.mem.eql(u8, verb, "load");
    if (!reloading and !loading and !std.mem.eql(u8, verb, "unload")) {
        s.say(":plugin takes load, unload or reload, and a name", .{});
        return false;
    }
    // Trimmed for the line and not for the lookup: a name too long to
    // print is still the name that was asked for.
    const short = who[0..@min(who.len, 64)];
    if (who.len == 0) {
        s.say(":plugin {s} takes the name of a plugin", .{verb});
        return false;
    }

    if (!reloading and !loading) {
        const n = rt.unload(who) orelse {
            s.say("no plugin is called {s}", .{short});
            return false;
        };
        if (n == 0) {
            s.say("{s} is already unloaded", .{short});
            return false;
        }
        s.say("unloaded {s}: {d} registrations gone", .{ short, n });
        return true;
    }

    // Two verbs for one call, so that asking for the wrong one is
    // answered rather than quietly done: `load` is for a plugin added
    // since the reader opened, `reload` for one already in service.
    if (rt.isLoaded(who) != reloading) {
        if (reloading) {
            s.say("{s} is not loaded: :plugin load {s}", .{ short, short });
        } else {
            s.say("{s} is loaded: :plugin reload {s} runs it again", .{ short, short });
        }
        return false;
    }

    switch (rt.load(who)) {
        .loaded => s.say("{s} {s}", .{ if (reloading) "reloaded" else "loaded", short }),
        // A reload that fails leaves the generation before it running,
        // which is the promise worth stating on the line: the person
        // edited a file, broke it, and still has the plugin they had.
        .failed => {
            if (reloading) {
                s.say("{s} did not reload; the last working one is still in service -- :messages", .{short});
            } else {
                s.say("{s} failed to load; :messages shows why", .{short});
            }
            if (rt.messages.items.len != 0) {
                s.ctx.note("{s}", .{rt.messages.items[rt.messages.items.len - 1]});
            }
            return false;
        },
        .missing => {
            s.say("no plugins/{s}.lua and no plugins/{s}/init.lua", .{ short, short });
            return false;
        },
    }
    return true;
}

/// Fires the events that are a difference rather than an act, when
/// either half of the difference has moved since it was last reported.
pub fn reportChanges(s: *Session) void {
    const rt = s.plugins orelse return;
    if (s.buffers.items.len == 0) return;
    const v = s.view();
    const doc = handleOf(s, v.buffer);
    const path = s.buffer(v.buffer).path;

    // Which document is in front is its own event, and it comes first.
    // Page and selection are differences *within* a document: moving
    // between two files that are open at the same page with the same
    // selection moves neither of them, so a panel that followed the
    // person by watching those two was left showing the file before.
    // Entering re-bases both rather than reporting them as changes,
    // which is the same reason: they did not change, the document did.
    const window = (@as(u32, s.tabs.active) << 16) | s.layout().currentIndex();
    if (doc != s.reported_doc or window != s.reported_window) {
        s.reported_doc = doc;
        s.reported_window = window;
        s.reported_page = v.currentPage();
        s.reported_selection = hostSelectionOf(s, v);
        rt.emit(.{ .event = .DocEnter, .doc = doc, .path = path });
    }

    const page = v.currentPage();
    if (page != s.reported_page) {
        s.reported_page = page;
        rt.emit(.{ .event = .PageChanged, .doc = doc, .path = path, .data = .{ .page = page + 1 } });
    }
    if (s.keymap.mode != s.reported_mode) {
        s.reported_mode = s.keymap.mode;
        rt.emit(.{ .event = .ModeChanged, .doc = doc, .path = path, .data = .{ .mode = @tagName(s.keymap.mode) } });
    }
    // The selection is read out of the view rather than kept beside it:
    // it moves with a key, with a drag and with a command, and a flag set
    // at each of those would be three places to forget one.
    const selection = hostSelectionOf(s, v);
    if (!std.meta.eql(selection, s.reported_selection)) {
        s.reported_selection = selection;
        rt.emit(.{ .event = .SelectionChanged, .doc = doc, .path = path, .data = .{ .selection = selection } });
    }
}

/// `PageRender`, once for the page that has just finished.
///
/// Here rather than where the page is *drawn*, which is the whole reason
/// the event is affordable: a page finishes once and is drawn sixty times
/// a second, and this is the frame thread, which is the only one that may
/// touch a Lua state -- the rasterising thread owns the `Document`.
pub fn announceRender(s: *Session, job: Job) void {
    const rt = s.plugins orelse return;
    rt.emit(.{
        .event = .PageRender,
        .doc = handleOf(s, job.buffer),
        .path = s.buffer(job.buffer).path,
        .data = .{ .page = job.page + 1 },
    });
}

pub fn announceEffect(s: *Session, at: u32, b: *Buffer, e: Marks.Effect) void {
    const rt = s.plugins orelse return;
    switch (e) {
        .comment_insert, .comment_delete, .comment_update => return announceComment(s, rt, at, b, e),
        else => {},
    }
    // Three events rather than one with an `action` field: a plugin that
    // only cares about a highlight being made should not have to be told
    // about every recolouring and then throw it away.
    const event: galdr.Runtime.Event, const mark: Marks.Mark = switch (e) {
        .insert => .{ .AnnotationAdd, (b.marks.byKey(e.insert) orelse return).* },
        .update => .{ .AnnotationChange, (b.marks.byKey(e.update) orelse return).* },
        .delete => |m| .{ .AnnotationRemove, m },
        .comment_insert, .comment_delete, .comment_update => unreachable,
    };
    var hex: [7]u8 = undefined;
    rt.emit(.{ .event = event, .doc = handleOf(s, at), .path = b.path, .data = .{ .mark = .{
        .id = mark.key,
        .page = mark.page + 1,
        .x0 = mark.box.min_x,
        .y0 = mark.box.min_y,
        .x1 = mark.box.max_x,
        .y1 = mark.box.max_y,
        .color = Session.hexOf(mark.color, &hex),
        .note = Session.firstComment(b, mark),
        .kind = kindName(mark.kind),
        .style = styleName(mark),
    } } });
}

/// The comment events, each with the comment as `fenrir.comments()`
/// would list it.
fn announceComment(s: *Session, rt: *galdr.Runtime, at: u32, b: *Buffer, e: Marks.Effect) void {
    const event: galdr.Runtime.Event, const c: Marks.Comment = switch (e) {
        .comment_insert => |key| .{ .CommentAdd, b.marks.comments.items[b.marks.commentIndex(key) orelse return] },
        .comment_update => |key| .{ .CommentChange, b.marks.comments.items[b.marks.commentIndex(key) orelse return] },
        .comment_delete => |c| .{ .CommentRemove, c },
        else => unreachable,
    };
    var names: [2][Library.name_len]u8 = undefined;
    rt.emit(.{ .event = event, .doc = handleOf(s, at), .path = b.path, .data = .{ .comment = hostComment(s, b, c, &names) } });
}

/// What a mark's kind is called on the other side of the plugin API.
fn kindName(k: Marks.Kind) []const u8 {
    return switch (k) {
        .block => "block",
        .ink => "ink",
    };
}

/// PDF's name for how a block is drawn, and nothing for ink, which has
/// no style to report.
fn styleName(m: Marks.Mark) []const u8 {
    return if (m.kind == .ink) "" else @tagName(m.style);
}

/// What a plugin calls the document in this buffer.
pub fn handleOf(s: *Session, index: u32) galdr.Host.Handle {
    if (index >= s.doc_handles.items.len) return galdr.Host.focused;
    return s.doc_handles.items[index];
}

/// Which buffer a handle names, or the focused window's for `focused`.
/// Null for a handle whose document is not open, which is what stops a
/// suspended handler writing on whatever is in front now.
fn bufferFor(s: *Session, doc: galdr.Host.Handle) ?u32 {
    if (s.buffers.items.len == 0) return null;
    if (doc == galdr.Host.focused) return s.view().buffer;
    for (s.doc_handles.items, 0..) |h, i| {
        if (h == doc) return @intCast(i);
    }
    return null;
}

/// A window showing that document: the focused one when it is showing
/// it, and otherwise the first that is.
///
/// Page, cursor and selection are a window's and a handle names a
/// document, so two windows on one file have to be resolved somehow.
/// The focused one first, because that is the one a person means.
fn viewFor(s: *Session, doc: galdr.Host.Handle) ?*View {
    const want = bufferFor(s, doc) orelse return null;
    const focused = s.view();
    if (focused.buffer == want) return focused;
    var it = s.layout().iterator();
    while (it.next()) |v| {
        if (v.buffer == want) return v;
    }
    return null;
}

// -- Galdr's view of the reader ----------------------------------------------

pub fn host(s: *Session) galdr.Host {
    return .{ .ptr = s, .vtable = &host_vtable };
}

fn hostSession(ptr: *anyopaque) *Session {
    return @ptrCast(@alignCast(ptr));
}

const host_vtable: galdr.Host.VTable = .{
    .notify = hostNotify,
    .exec = hostExec,
    .document = hostDocument,
    .page = hostPage,
    .goTo = hostGoTo,
    .zoom = hostZoom,
    .setZoom = hostSetZoom,
    .mode = hostMode,
    .cursor = hostCursor,
    .selection = hostSelection,
    .markCount = hostMarkCount,
    .markAt = hostMarkAt,
    .addMark = hostAddMark,
    .removeMark = hostRemoveMark,
    .commentCount = hostCommentCount,
    .commentAt = hostCommentAt,
    .addComment = hostAddComment,
    .removeComment = hostRemoveComment,
    .storeGet = hostStoreGet,
    .storeSet = hostStoreSet,
    .readFile = hostReadFile,
    .listDir = hostListDir,
};

fn hostNotify(ptr: *anyopaque, message: []const u8) void {
    hostSession(ptr).say("{s}", .{message[0..@min(message.len, 480)]});
}

/// A plugin's `:` line, which is not the console's.
///
/// `:lua` runs arbitrary Lua with everything granted, so a plugin that
/// asked for `ui` alone would have the whole table back through it --
/// `exec` is documented as running a command and a command is not an
/// interpreter. Refused here rather than in Galdr, because which of
/// this reader's commands is arbitrary code is this reader's answer.
fn hostExec(ptr: *anyopaque, line: []const u8) bool {
    return hostSession(ptr).execFrom(line, .plugin);
}

fn hostDocument(ptr: *anyopaque, doc: galdr.Host.Handle) ?galdr.Host.Document {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return null;
    const b = s.buffer(at);
    return .{
        .handle = handleOf(s, at),
        .path = b.path,
        .title = b.title,
        .pages = @intCast(b.pages.len),
    };
}

fn hostPage(ptr: *anyopaque, doc: galdr.Host.Handle) ?u32 {
    const v = viewFor(hostSession(ptr), doc) orelse return null;
    return v.currentPage() + 1;
}

fn hostGoTo(ptr: *anyopaque, page: u32, offset: f32) bool {
    const s = hostSession(ptr);
    const v = s.view();
    if (page < 1 or page > v.pages.len) return false;
    v.goTo(.{ .page = page - 1, .offset = offset, .zoom = v.zoom });
    return true;
}

fn hostZoom(ptr: *anyopaque) ?f32 {
    return hostSession(ptr).view().percent();
}

fn hostSetZoom(ptr: *anyopaque, percent: f32) void {
    const v = hostSession(ptr).view();
    v.setZoom(v.hundredPercent() * percent / 100);
}

fn hostMode(ptr: *anyopaque) []const u8 {
    return @tagName(hostSession(ptr).keymap.mode);
}

fn fromOne(p: View.Position) galdr.Host.Position {
    return .{ .page = p.page + 1, .line = p.line + 1, .column = p.column + 1 };
}

fn hostCursor(ptr: *anyopaque, doc: galdr.Host.Handle) ?galdr.Host.Position {
    const v = viewFor(hostSession(ptr), doc) orelse return null;
    if (!v.cursor.visible) return null;
    return fromOne(v.cursor.position());
}

fn hostSelection(ptr: *anyopaque, doc: galdr.Host.Handle) ?[2]galdr.Host.Position {
    const s = hostSession(ptr);
    return hostSelectionOf(s, viewFor(s, doc) orelse return null);
}

/// What a plugin sees selected in a window, in its numbering.
///
/// Either kind: a plugin asking what is selected means what the reader
/// can see selected, and does not care which hand made it. Named because
/// `SelectionChanged` compares two of these rather than watching the
/// three places a selection can move from.
fn hostSelectionOf(s: *Session, v: *View) ?[2]galdr.Host.Position {
    const sel = s.activeSelection(v) orelse return null;
    return .{ fromOne(sel[0]), fromOne(sel[1]) };
}

fn hostMarkCount(ptr: *anyopaque, doc: galdr.Host.Handle) usize {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return 0;
    return s.buffer(at).marks.count();
}

fn hostMarkAt(ptr: *anyopaque, doc: galdr.Host.Handle, index: usize) ?galdr.Host.Mark {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return null;
    const b = s.buffer(at);
    const marks = b.marks.items();
    if (index >= marks.len) return null;
    const m = marks[index];
    return .{
        .id = m.key,
        .page = m.page + 1,
        .x0 = m.box.min_x,
        .y0 = m.box.min_y,
        .x1 = m.box.max_x,
        .y1 = m.box.max_y,
        // Valid until the next call, which Galdr does not make until it
        // has copied this one into Lua.
        .color = Session.hexOf(m.color, &s.hex_buf),
        .note = Session.firstComment(b, m),
        .anchor = Session.spell(b, m.anchor, &s.name_bufs[0]),
        .kind = kindName(m.kind),
        .style = styleName(m),
    };
}

fn hostAddMark(ptr: *anyopaque, doc: galdr.Host.Handle, h: galdr.Host.Mark) ?u64 {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return null;
    const b = s.buffer(at);
    if (h.page < 1 or h.page > b.pages.len) return null;
    const color = if (h.color.len == 0) s.highlight else Library.parseColor(h.color) orelse s.highlight;

    b.marks.beginGroup();
    defer b.marks.beginGroup();
    const index = b.marks.add(s.gpa, .{
        .page = h.page - 1,
        .box = .fromRect(@min(h.x0, h.x1), @min(h.y0, h.y1), @max(h.x0, h.x1), @max(h.y0, h.y1)),
        .color = color,
        // Galdr has refused any name that is not one of these.
        .style = std.meta.stringToEnum(Marks.Style, h.style) orelse .highlight,
    }, false) catch return null;
    const made = b.marks.items()[index];
    // A note given with it is the first comment on it, in the same step.
    if (h.note.len != 0) _ = b.marks.addComment(s.gpa, .{ .anchor = made.anchor, .text = h.note }, false) catch {};
    return made.key;
}

/// Against the document the caller named, which is the half of this
/// that matters: `Marks.next_key` starts at 1 in every document, so an
/// id saved from A and removed against "whatever is focused now" takes
/// an unrelated mark out of an unrelated file.
fn hostRemoveMark(ptr: *anyopaque, doc: galdr.Host.Handle, id: u64) bool {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return false;
    const b = s.buffer(at);
    const index = b.marks.indexOf(id) orelse return false;
    b.marks.beginGroup();
    defer b.marks.beginGroup();
    return (b.marks.removeAt(s.gpa, index) catch null) != null;
}

/// `fenrir.comments()` asks for the count and then each row, so the
/// order is worked out on the first and kept until the marks change.
fn commentOrder(s: *Session, at: u32) []const usize {
    const b = s.buffer(at);
    const stamp: @TypeOf(s.comment_order_for) = .{ .buffer = at, .revision = b.marks.revision };
    if (!std.meta.eql(stamp, s.comment_order_for)) {
        b.marks.readOrder(s.gpa, &s.comment_order) catch s.comment_order.clearRetainingCapacity();
        s.comment_order_for = stamp;
    }
    return s.comment_order.items;
}

fn hostCommentCount(ptr: *anyopaque, doc: galdr.Host.Handle) usize {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return 0;
    return commentOrder(s, at).len;
}

fn hostCommentAt(ptr: *anyopaque, doc: galdr.Host.Handle, index: usize) ?galdr.Host.Comment {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return null;
    const order = commentOrder(s, at);
    if (index >= order.len) return null;
    return hostComment(s, s.buffer(at), s.buffer(at).marks.comments.items[order[index]], &s.name_bufs);
}

/// A comment as Galdr is handed it. The names are written into `names`,
/// which must outlive the call it is handed over in.
fn hostComment(s: *Session, b: *Buffer, c: Marks.Comment, names: *[2][Library.name_len]u8) galdr.Host.Comment {
    const line = b.marks.firstLine(s.gpa, c.anchor);
    return .{
        .id = c.key,
        .anchor = Session.spell(b, c.anchor, &names[0]),
        .name = Session.spell(b, c.name, &names[1]),
        .text = c.text,
        .page = if (line) |i| b.marks.items()[i].page + 1 else 0,
    };
}

fn hostAddComment(ptr: *anyopaque, doc: galdr.Host.Handle, c: galdr.Host.Comment) ?u64 {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return null;
    const b = s.buffer(at);
    // On a highlight's anchor, or an anchor by name; either way one
    // with a line left, since a comment on nothing is never shown.
    const anchor = if (c.on != 0)
        (b.marks.byKey(c.on) orelse return null).anchor
    else
        Library.nameNumber(c.anchor) orelse b.marks.foreign.get(c.anchor) orelse return null;
    if (anchor == 0 or b.marks.lineCount(anchor) == 0) return null;

    b.marks.beginGroup();
    defer b.marks.beginGroup();
    const index = b.marks.addComment(s.gpa, .{ .anchor = anchor, .text = c.text }, false) catch return null;
    return b.marks.comments.items[index].key;
}

fn hostRemoveComment(ptr: *anyopaque, doc: galdr.Host.Handle, id: u64) bool {
    const s = hostSession(ptr);
    const at = bufferFor(s, doc) orelse return false;
    const b = s.buffer(at);
    const index = b.marks.commentIndex(id) orelse return false;
    b.marks.beginGroup();
    defer b.marks.beginGroup();
    return (b.marks.removeComment(s.gpa, index) catch null) != null;
}

fn hostStoreGet(ptr: *anyopaque, gpa: Allocator, plugin: []const u8, key: []const u8) ?[]u8 {
    const s = hostSession(ptr);
    const lib = s.library orelse return null;
    var buf: [320]u8 = undefined;
    const full = library.pluginKey(&buf, plugin, key) orelse return null;
    const value = (lib.get(full) catch return null) orelse return null;
    // The library allocated with the reader's heap; hand back the
    // caller's allocation, as the interface promises.
    defer s.gpa.free(value);
    return gpa.dupe(u8, value) catch null;
}

fn hostStoreSet(ptr: *anyopaque, plugin: []const u8, key: []const u8, value: ?[]const u8) bool {
    const s = hostSession(ptr);
    const lib = s.library orelse return false;
    var buf: [320]u8 = undefined;
    const full = library.pluginKey(&buf, plugin, key) orelse return false;
    if (value) |val| {
        lib.set(full, val) catch return false;
    } else {
        lib.remove(full) catch return false;
    }
    return true;
}

fn configPath(s: *Session, buf: []u8, rel: []const u8) ?[]const u8 {
    const dir = s.config_dir orelse return null;
    if (!galdr.Host.isContained(rel)) return null;
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, rel }) catch null;
}

fn hostReadFile(ptr: *anyopaque, gpa: Allocator, rel: []const u8) ?[]u8 {
    const s = hostSession(ptr);
    var buf: [4096]u8 = undefined;
    const full = configPath(s, &buf, rel) orelse return null;
    const io = s.io orelse return null;
    // A plugin is source code, not a document: a megabyte is far past
    // any real one.
    return Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20)) catch null;
}

fn hostListDir(ptr: *anyopaque, gpa: Allocator, rel: []const u8) ?[][]u8 {
    const s = hostSession(ptr);
    var buf: [4096]u8 = undefined;
    const full = configPath(s, &buf, rel) orelse return null;
    const io = s.io orelse return null;

    var dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const name = switch (entry.kind) {
            .directory => std.fmt.allocPrint(gpa, "{s}/", .{entry.name}),
            .file, .sym_link => gpa.dupe(u8, entry.name),
            else => continue,
        } catch {
            galdr.Host.freeList(gpa, names.toOwnedSlice(gpa) catch return null);
            return null;
        };
        names.append(gpa, name) catch {
            gpa.free(name);
            galdr.Host.freeList(gpa, names.toOwnedSlice(gpa) catch return null);
            return null;
        };
    }
    // In order of name, so that plugins load in the same order on every
    // file system -- which directory order is not.
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.toOwnedSlice(gpa) catch null;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const givePlugins = fixtures.givePlugins;
const sessionOf = fixtures.sessionOf;

test "a plugin comments on the real reader's marks, and hears each comment come and go" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    const rt = try galdr.Runtime.create(gpa, host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    // Two lines of one selection, made the way `c` makes them.
    const anchor = s.markBoxes(0, &.{
        .{ .page = 1, .box = .fromRect(100, 700, 300, 712) },
        .{ .page = 1, .box = .fromRect(100, 686, 300, 698) },
    }, s.accent, .highlight);
    s.applyEffects();
    var name: [Library.name_len]u8 = undefined;
    var script: [1024]u8 = undefined;
    try testing.expect(rt.runString("init.lua", try std.fmt.bufPrint(&script,
        \\heard = {{}}
        \\local function hear(e) heard[#heard + 1] = e.event .. ":" .. e.text .. ":" .. e.anchor end
        \\fenrir.on("CommentAdd", hear)
        \\fenrir.on("CommentRemove", hear)
        \\fenrir.on("CommentChange", hear)
        \\local marks = fenrir.marks()
        \\assert(marks[1].anchor == "{s}" and marks[2].anchor == marks[1].anchor)
        \\first = fenrir.comment{{ anchor = marks[2].id, text = "on the second line" }}
        \\reply = fenrir.comment{{ anchor = "{s}", text = "a reply" }}
    , .{ Library.makeName(&name, anchor), Library.makeName(&name, anchor) })));
    s.applyEffects();

    // Both on the one anchor, the first named as the anchor is; and read
    // back in `]c`'s order, with the page the anchor begins on.
    const said = s.buffer(0).marks.said(anchor);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqual(anchor, said[0].name);
    try testing.expect(rt.runString("check",
        \\local all = fenrir.comments()
        \\assert(#all == 2, #all)
        \\assert(all[1].id == first and all[1].page == 2 and all[1].name == all[1].anchor)
        \\assert(all[2].text == "a reply" and all[2].name ~= all[2].anchor)
        \\assert(fenrir.marks()[1].note == "on the second line")
        \\assert(not pcall(fenrir.comment, { anchor = "f999", text = "on nothing" }))
        \\assert(fenrir.uncomment(reply))
    ));
    s.applyEffects();

    // An undo is the reader's, and the plugin hears it as it heard the rest.
    _ = s.apply(.undo);
    s.applyEffects();
    try testing.expect(rt.runString("check",
        \\assert(#heard == 4, #heard)
        \\assert(heard[1]:find("^CommentAdd:on the second line:"))
        \\assert(heard[3]:find("^CommentRemove:a reply:"))
        \\assert(heard[4]:find("^CommentAdd:a reply:"))
    ));
}

test "a plugin drives the real reader: bindings, commands, highlights, events" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [12]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 10), 1, 1000, 800);
    defer closeSession(&s);

    const rt = try galdr.Runtime.create(gpa, host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    try testing.expect(rt.runString("init.lua",
        \\events = {}
        \\local function note(e) events[#events + 1] = e.event .. ":" .. e.page end
        \\fenrir.on("AnnotationAdd", note)
        \\fenrir.on("AnnotationRemove", note)
        \\fenrir.on("PageChanged", function(e) last_page = e.page end)
        \\fenrir.on("DocEnter", function(e) entered = (entered or 0) + 1 end)
        \\fenrir.keymap("n", "g", function() fenrir.go(fenrir.document().pages) end)
        \\fenrir.command("Mark", function(args)
        \\  fenrir.mark{ page = tonumber(args), x0 = 72, y0 = 700, x1 = 300, y1 = 712, color = "blue", style = "squiggly", note = "from lua" }
        \\end)
    ));

    // The first report, as the reader makes it once the window is up: it
    // says which document is in front and sets the baseline that the
    // differences are measured against.
    reportChanges(&s);
    try testing.expect(s.exec("lua assert(entered == 1, tostring(entered))"));

    // The binding, through the keymap, as a key press would reach it.
    const out = keys.commandWith(&s.keymap, .{ .events = &.{.{ .text = "g" }} }, rt.lookup());
    try testing.expect(!s.apply(out.items()[0]));
    try testing.expectEqual(@as(u32, 9), s.view().currentPage());

    // A plugin command from the command line.
    try testing.expect(s.exec("Mark 3"));
    s.applyEffects();
    const marks = s.buffer(0).marks.items();
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqual(@as(u32, 2), marks[0].page);
    try testing.expectEqualStrings("from lua", Session.firstComment(s.buffer(0), marks[0]));
    try testing.expectEqual(Library.parseColor("blue").?, marks[0].color);
    try testing.expectEqual(Marks.Style.squiggly, marks[0].style);

    // Undo is the reader's, and the plugin hears about both.
    _ = s.apply(.undo);
    s.applyEffects();
    reportChanges(&s);
    try testing.expect(s.exec("lua assert(events[1] == 'AnnotationAdd:3' and events[2] == 'AnnotationRemove:3', table.concat(events, ',')) assert(last_page == 10)"));
    try testing.expectEqual(@as(usize, 0), rt.messages.items.len);

    // A broken binding reports and leaves the reader running.
    try testing.expect(rt.runString("more", "fenrir.keymap('n', 'x', function() error('boom') end)"));
    const bad = keys.commandWith(&s.keymap, .{ .events = &.{.{ .text = "x" }} }, rt.lookup());
    try testing.expect(!s.apply(bad.items()[0]));
    try testing.expect(std.mem.indexOf(u8, s.status, "boom") != null);
}

test "a plugin's exec runs a command and not the console's lua" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    const rt = try galdr.Runtime.create(gpa, host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    // `fenrir.exec` is a plugin's command line. `:lua` is arbitrary Lua at
    // the console's authority, so a plugin granted `ui` alone would have
    // the whole table back through it.
    try testing.expect(rt.runString("try", "ok = fenrir.exec('lua reached = true')"));
    try testing.expect(rt.runString("check",
        \\assert(ok == false, "a plugin reached :lua through fenrir.exec")
        \\assert(reached == nil, "the line ran anyway")
    ));
    try testing.expect(std.mem.indexOf(u8, s.status, "console") != null);

    // Every other command still goes through, and the console's own `:lua`
    // is untouched.
    try testing.expect(rt.runString("split", "fenrir.exec('vsplit')"));
    try testing.expect(s.exec("lua direct = true"));
    try testing.expect(rt.runString("check", "assert(direct == true)"));
}

test "the plugin lifecycle is asked for by name, and only from the console" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    const rt = try galdr.Runtime.create(gpa, host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    // Bare `:plugin` is `:plugins`, and this reader has no configuration
    // directory, so neither has anything to list.
    try testing.expect(s.exec("plugin"));
    try testing.expect(std.mem.indexOf(u8, s.status, "nothing to load") != null);

    try testing.expect(!s.exec("plugin frobnicate clock"));
    try testing.expect(std.mem.indexOf(u8, s.status, "load, unload or reload") != null);
    try testing.expect(!s.exec("plugin unload"));
    try testing.expect(std.mem.indexOf(u8, s.status, "name of a plugin") != null);
    try testing.expect(!s.exec("plugin unload clock"));
    try testing.expect(std.mem.indexOf(u8, s.status, "no plugin is called clock") != null);

    // `reload` is for a plugin in service and `load` for one that is not,
    // so asking for the wrong verb is answered rather than quietly done.
    try testing.expect(!s.exec("plugin reload clock"));
    try testing.expect(std.mem.indexOf(u8, s.status, "is not loaded") != null);
    try testing.expect(!s.exec("plugin load clock"));
    try testing.expect(std.mem.indexOf(u8, s.status, "plugins/clock.lua") != null);

    // And the verbs are the console's, for the reason `:lua` is: a plugin
    // that could reload itself would run its own chunk underneath its own
    // call, and one that could unload another would decide what else the
    // reader runs.
    try testing.expect(rt.runString("try", "ok = fenrir.exec('plugin unload clock')"));
    try testing.expect(rt.runString("check", "assert(ok == false)"));
    try testing.expect(std.mem.indexOf(u8, s.status, "console") != null);
    // Listing is not one of them.
    try testing.expect(rt.runString("list", "assert(fenrir.exec('plugin'))"));
}

test "moving between two documents at the same place still says so" {
    if (!galdr.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    // A second document, open at the same page with the same selection:
    // `PageChanged` and `SelectionChanged` are differences *within* a
    // document and neither of them moves, so before `DocEnter` a panel
    // following the focused file was left showing the first one.
    try s.buffers.append(gpa, .{
        .path = try gpa.dupe(u8, "/docs/b.pdf"),
        .title = "b.pdf",
        .pages = s.buffer(0).pages,
    });
    s.next_doc_handle += 1;
    try s.doc_handles.append(gpa, s.next_doc_handle);

    const rt = try galdr.Runtime.create(gpa, host(&s), .{});
    try givePlugins(&s, rt);
    defer {
        rt.destroy();
        s.plugins = null;
    }

    try testing.expect(rt.runString("init.lua",
        \\seen, pages = {}, 0
        \\fenrir.on("DocEnter", function(e) seen[#seen + 1] = e.path end)
        \\fenrir.on("PageChanged", function() pages = pages + 1 end)
    ));

    reportChanges(&s);
    s.showBuffer(1);
    reportChanges(&s);
    s.showBuffer(-1);
    reportChanges(&s);

    try testing.expect(rt.runString("check",
        \\assert(#seen == 3, #seen)
        \\assert(seen[2]:find("b.pdf", 1, true), seen[2])
        \\assert(seen[3]:find("a.pdf", 1, true), seen[3])
        \\assert(pages == 0, "entering a document reported a page that did not change")
    ));
    try testing.expectEqual(@as(usize, 0), rt.messages.items.len);
}
