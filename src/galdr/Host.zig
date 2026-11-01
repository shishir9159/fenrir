//! What a plugin can reach: the reader, as an interface.
//!
//! Galdr runs scripts and knows nothing about windows, documents, files or
//! databases. Everything a script can *do* goes through this vtable, which
//! the reader implements, and so everything a script can do is listed here in
//! one place. That is the sandbox, stated positively: a plugin can read and
//! write exactly the things below, and a function that is not below does not
//! exist from Lua.
//!
//! It is also what makes the runtime testable. A test hands in a host made of
//! a few fields and checks what the script asked it to do, with no window and
//! no document.
//!
//! Files are here rather than in Galdr for the same reason: the library layer
//! does not open files, the CLI does, and a plugin can only read what the
//! host agrees to read -- which for the reader is its configuration
//! directory and nothing else.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Host = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// A document, as a script sees it. Pages are numbered from 1 here and
/// everywhere else in the Lua API, as a person numbers them.
pub const Document = struct {
    path: []const u8,
    title: []const u8,
    pages: u32,
};

/// A place in the text, numbered from 1.
pub const Position = struct {
    page: u32,
    line: u32,
    column: u32,
};

pub const Highlight = struct {
    /// The session's key for it: stable for the life of the reader, and what
    /// `fenrir.unhighlight` takes.
    id: u64 = 0,
    page: u32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// `#rrggbb`, or empty for the accent colour.
    color: []const u8 = "",
    note: []const u8 = "",
    /// `"block"` for a highlight over words, `"ink"` for a freehand stroke.
    ///
    /// The box of a stroke is the box it covers, which is a true answer to
    /// "where is it" and a misleading one to "what is it" -- a plugin
    /// counting what a reader marked should be able to tell a line drawn
    /// round a figure from a highlight over its caption. A word rather than
    /// a flag because this crosses into Lua, where a table field reading
    /// `kind = "ink"` needs no documentation to understand.
    kind: []const u8 = "block",
};

pub const VTable = struct {
    /// Shows a message where the reader shows messages.
    notify: *const fn (ptr: *anyopaque, message: []const u8) void,
    /// Runs a `:` command line, **at a plugin's authority and never the
    /// console's**. A host whose commands include one that runs arbitrary
    /// code -- `:lua` -- refuses that one here, or a plugin granted `ui`
    /// alone has the whole table back through it. False when there is no
    /// such command or it failed; the host has already said why.
    exec: *const fn (ptr: *anyopaque, line: []const u8) bool,

    document: *const fn (ptr: *anyopaque) ?Document,
    page: *const fn (ptr: *anyopaque) ?u32,
    /// Scrolls the focused window to a page, and `offset` points down it.
    goTo: *const fn (ptr: *anyopaque, page: u32, offset: f32) bool,
    /// The zoom as the title bar shows it: a percentage of true size.
    zoom: *const fn (ptr: *anyopaque) ?f32,
    setZoom: *const fn (ptr: *anyopaque, percent: f32) void,
    mode: *const fn (ptr: *anyopaque) []const u8,
    cursor: *const fn (ptr: *anyopaque) ?Position,
    selection: *const fn (ptr: *anyopaque) ?[2]Position,

    highlightCount: *const fn (ptr: *anyopaque) usize,
    highlightAt: *const fn (ptr: *anyopaque, index: usize) ?Highlight,
    addHighlight: *const fn (ptr: *anyopaque, h: Highlight) ?u64,
    removeHighlight: *const fn (ptr: *anyopaque, id: u64) bool,

    /// A plugin's persistent value, or null. The caller owns the result and
    /// frees it with `gpa`.
    ///
    /// `plugin` is the host's own name for the caller and never a string the
    /// caller chose: the namespace is the host's answer to "whose key is
    /// this", so two plugins that both keep `enabled` keep two values.
    storeGet: *const fn (ptr: *anyopaque, gpa: Allocator, plugin: []const u8, key: []const u8) ?[]u8,
    /// Sets, or with null removes. False when there is nowhere to store it.
    storeSet: *const fn (ptr: *anyopaque, plugin: []const u8, key: []const u8, value: ?[]const u8) bool,

    /// A file under the configuration directory, by a path relative to it.
    /// Null when it does not exist or is outside the directory. Caller frees.
    readFile: *const fn (ptr: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8,
    /// The entries of a directory under the configuration directory, sorted.
    /// Directories carry a trailing `/`. Caller frees each and the list.
    listDir: *const fn (ptr: *anyopaque, gpa: Allocator, path: []const u8) ?[][]u8,
};

pub fn notify(h: Host, message: []const u8) void {
    h.vtable.notify(h.ptr, message);
}

pub fn exec(h: Host, line: []const u8) bool {
    return h.vtable.exec(h.ptr, line);
}

pub fn document(h: Host) ?Document {
    return h.vtable.document(h.ptr);
}

pub fn page(h: Host) ?u32 {
    return h.vtable.page(h.ptr);
}

pub fn goTo(h: Host, p: u32, offset: f32) bool {
    return h.vtable.goTo(h.ptr, p, offset);
}

pub fn zoom(h: Host) ?f32 {
    return h.vtable.zoom(h.ptr);
}

pub fn setZoom(h: Host, percent: f32) void {
    h.vtable.setZoom(h.ptr, percent);
}

pub fn mode(h: Host) []const u8 {
    return h.vtable.mode(h.ptr);
}

pub fn cursor(h: Host) ?Position {
    return h.vtable.cursor(h.ptr);
}

pub fn selection(h: Host) ?[2]Position {
    return h.vtable.selection(h.ptr);
}

pub fn highlightCount(h: Host) usize {
    return h.vtable.highlightCount(h.ptr);
}

pub fn highlightAt(h: Host, index: usize) ?Highlight {
    return h.vtable.highlightAt(h.ptr, index);
}

pub fn addHighlight(h: Host, hl: Highlight) ?u64 {
    return h.vtable.addHighlight(h.ptr, hl);
}

pub fn removeHighlight(h: Host, id: u64) bool {
    return h.vtable.removeHighlight(h.ptr, id);
}

pub fn storeGet(h: Host, gpa: Allocator, plugin: []const u8, key: []const u8) ?[]u8 {
    return h.vtable.storeGet(h.ptr, gpa, plugin, key);
}

pub fn storeSet(h: Host, plugin: []const u8, key: []const u8, value: ?[]const u8) bool {
    return h.vtable.storeSet(h.ptr, plugin, key, value);
}

pub fn readFile(h: Host, gpa: Allocator, path: []const u8) ?[]u8 {
    return h.vtable.readFile(h.ptr, gpa, path);
}

pub fn listDir(h: Host, gpa: Allocator, path: []const u8) ?[][]u8 {
    return h.vtable.listDir(h.ptr, gpa, path);
}

pub fn freeList(gpa: Allocator, list: [][]u8) void {
    for (list) |item| gpa.free(item);
    gpa.free(list);
}

/// Whether a path a script asked for stays inside the directory it is
/// relative to. Rejects absolute paths, drive letters, and any `..`
/// component, which is the whole of what "under the configuration directory"
/// means. Hosts call this before touching the filesystem.
pub fn isContained(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "a script's paths cannot leave the configuration directory" {
    try testing.expect(isContained("init.lua"));
    try testing.expect(isContained("lua/foo/bar.lua"));
    try testing.expect(isContained("plugins\\thing.lua"));

    try testing.expect(!isContained(""));
    try testing.expect(!isContained("/etc/passwd"));
    try testing.expect(!isContained("\\Windows\\win.ini"));
    try testing.expect(!isContained("C:\\Users"));
    try testing.expect(!isContained("../secrets.txt"));
    try testing.expect(!isContained("lua/../../escape.lua"));
    try testing.expect(!isContained("lua\\..\\..\\escape.lua"));
}
