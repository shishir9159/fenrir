//! Renders objects back into something close to PDF syntax.
//!
//! The output is meant to be read by a person and diffed against
//! `qpdf --qdf --object-streams=disable`, which is the fastest way to check a
//! parser against a known-good one. It is deliberately not a serialiser: it
//! elides long arrays, prints binary strings as hex, and can follow indirect
//! references, none of which a writer may do.

const std = @import("std");
const Writer = std.Io.Writer;

const Document = @import("Document.zig");
const object = @import("object.zig");
const Dict = object.Dict;
const Object = object.Object;

pub const Error = Writer.Error || Document.Error;

pub const Options = struct {
    /// Nesting beyond this prints as `...`.
    max_depth: u8 = 6,
    /// Arrays longer than this are truncated with a count.
    max_items: usize = 32,
    /// Strings longer than this are truncated.
    max_string: usize = 96,
    /// Replace `12 0 R` with the object it names, up to `max_depth`.
    follow_refs: bool = false,
    /// Spaces per level.
    indent: u8 = 2,
};

pub fn write(w: *Writer, doc: *Document, obj: Object, opts: Options) Error!void {
    try writeAt(w, doc, obj, opts, 0);
    try w.writeByte('\n');
}

fn writeAt(w: *Writer, doc: *Document, obj: Object, opts: Options, depth: u8) Error!void {
    if (depth > opts.max_depth) {
        try w.writeAll("...");
        return;
    }

    switch (obj) {
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |v| try w.print("{d}", .{v}),
        .real => |v| try w.print("{d}", .{v}),
        .name => |n| try writeName(w, n),
        .string => |s| try writeString(w, s, opts),
        .array => |a| try writeArray(w, doc, a, opts, depth),
        .dict => |d| try writeDict(w, doc, d, opts, depth),
        .stream => |s| {
            try writeDict(w, doc, s.dict, opts, depth);
            try w.print("\nstream  % {d} bytes, encoded\n", .{s.raw.len});
        },
        .ref => |r| {
            if (!opts.follow_refs) {
                try w.print("{f}", .{r});
                return;
            }
            // Annotate so the reader can still see what was followed.
            try w.print("{f} -> ", .{r});
            const target = doc.fetch(r) catch Object.null_object;
            try writeAt(w, doc, target, opts, depth + 1);
        },
    }
}

/// Names round-trip through `#xx` for anything outside the regular character
/// set, matching the escaping rule in §7.3.5.
fn writeName(w: *Writer, name: []const u8) Error!void {
    try w.writeByte('/');
    for (name) |c| {
        if (c < 0x21 or c > 0x7e or c == '#' or isDelimiterByte(c)) {
            try w.print("#{X:0>2}", .{c});
        } else {
            try w.writeByte(c);
        }
    }
}

fn isDelimiterByte(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

/// Text-ish strings print as literals; anything with control or high bytes
/// prints as hex, because a terminal cannot show the difference otherwise.
fn writeString(w: *Writer, s: []const u8, opts: Options) Error!void {
    const shown = s[0..@min(s.len, opts.max_string)];
    const printable = for (shown) |c| {
        if (c < 0x20 or c > 0x7e) break false;
    } else true;

    if (printable) {
        try w.writeByte('(');
        for (shown) |c| {
            if (c == '(' or c == ')' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeByte(')');
    } else {
        try w.writeByte('<');
        for (shown) |c| try w.print("{X:0>2}", .{c});
        try w.writeByte('>');
    }
    if (shown.len < s.len) try w.print("  % +{d} bytes", .{s.len - shown.len});
}

fn writeArray(w: *Writer, doc: *Document, items: []const Object, opts: Options, depth: u8) Error!void {
    const shown = items[0..@min(items.len, opts.max_items)];

    // Arrays of scalars are far more readable on one line, and most arrays in
    // a PDF are rectangles, widths, or kids.
    if (inlineable(shown, opts)) {
        try w.writeByte('[');
        for (shown, 0..) |item, i| {
            if (i != 0) try w.writeByte(' ');
            try writeAt(w, doc, item, opts, depth + 1);
        }
        if (shown.len < items.len) try w.print(" ... +{d}", .{items.len - shown.len});
        try w.writeByte(']');
        return;
    }

    try w.writeAll("[\n");
    for (shown) |item| {
        try indent(w, opts, depth + 1);
        try writeAt(w, doc, item, opts, depth + 1);
        try w.writeByte('\n');
    }
    if (shown.len < items.len) {
        try indent(w, opts, depth + 1);
        try w.print("... +{d} more\n", .{items.len - shown.len});
    }
    try indent(w, opts, depth);
    try w.writeByte(']');
}

fn writeDict(w: *Writer, doc: *Document, dict: Dict, opts: Options, depth: u8) Error!void {
    if (dict.count() == 0) {
        try w.writeAll("<< >>");
        return;
    }

    try w.writeAll("<<\n");
    for (dict.keys(), dict.values()) |key, value| {
        try indent(w, opts, depth + 1);
        try writeName(w, key);
        try w.writeByte(' ');
        try writeAt(w, doc, value, opts, depth + 1);
        try w.writeByte('\n');
    }
    try indent(w, opts, depth);
    try w.writeAll(">>");
}

/// An array fits on one line when nothing in it will itself span lines. A
/// reference only expands when `follow_refs` is on.
fn inlineable(items: []const Object, opts: Options) bool {
    for (items) |item| switch (item) {
        .array, .dict, .stream => return false,
        .ref => if (opts.follow_refs) return false,
        else => {},
    };
    return true;
}

fn indent(w: *Writer, opts: Options, depth: u8) Error!void {
    try w.splatByteAll(' ', @as(usize, opts.indent) * depth);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Renders into a growable buffer, which is all the tests need.
fn render(gpa: std.mem.Allocator, doc: *Document, obj: Object, opts: Options) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(&out.writer, doc, obj, opts);
    return out.toOwnedSlice();
}

const tiny_pdf =
    "%PDF-1.4\n" ++
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Page /MediaBox [0 0 612 792] >>\nendobj\n" ++
    "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

test "dictionaries and inline arrays" {
    var doc = try Document.open(testing.allocator, try testing.allocator.dupe(u8, tiny_pdf));
    defer doc.deinit();

    const page = try doc.fetch(.{ .num = 3, .gen = 0 });
    const out = try render(testing.allocator, &doc, page, .{});
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\<<
        \\  /Type /Page
        \\  /MediaBox [0 0 612 792]
        \\>>
        \\
    , out);
}

test "names with unusual bytes are escaped" {
    var doc = try Document.open(testing.allocator, try testing.allocator.dupe(u8, tiny_pdf));
    defer doc.deinit();

    const out = try render(testing.allocator, &doc, .{ .name = "Lime Green" }, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/Lime#20Green\n", out);
}

test "binary strings print as hex" {
    var doc = try Document.open(testing.allocator, try testing.allocator.dupe(u8, tiny_pdf));
    defer doc.deinit();

    const out = try render(testing.allocator, &doc, .{ .string = "\x00\x01\xff" }, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<0001FF>\n", out);
}

test "references can be followed" {
    var doc = try Document.open(testing.allocator, try testing.allocator.dupe(u8, tiny_pdf));
    defer doc.deinit();

    const cat = try doc.fetch(.{ .num = 1, .gen = 0 });
    const out = try render(testing.allocator, &doc, cat, .{ .follow_refs = true });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "2 0 R -> <<") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/Count 1") != null);
}
