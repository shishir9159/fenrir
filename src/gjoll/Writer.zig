//! An incremental update (ISO 32000-2 §7.5.6): what a save appends to a
//! file, as bytes.
//!
//! Nothing already in the file is touched. New and changed objects go after
//! `%%EOF` with a cross-reference section of their own whose `/Prev` names
//! the one before, so a reader walking the chain newest-first sees the
//! change and every byte under it stays as it was -- which is also what
//! keeps a signature over an earlier revision valid. A rewrite would
//! renumber every object and break both.
//!
//! The library layer opens no files, so this returns the bytes and the CLI
//! appends them. They are laid out to start at the end of `doc.bytes`, and
//! every offset in them counts from there.
//!
//! ## What a save costs
//!
//! For a file at PDF 1.5 or later, one object stream and one
//! cross-reference stream: every dictionary that can be packed goes into the
//! one compressed stream, and the section is a few bytes an object rather
//! than twenty. An older file gets a classic table, because its readers may
//! not know the newer form, and its version is never raised to save bytes.
//!
//! Tokens are separated only where two would otherwise run together:
//! `<</Type/Annot/Rect[10 20.5 .25 4]>>`. A number fenrir makes is held to
//! a hundredth where it is made (`hundredths`), so it is written in few
//! digits; a number copied from the file is written back exactly.
//!
//! ## Using it
//!
//! `fresh` hands out a number, `put` gives a number an object, `putContent`
//! a stream, and `free` deletes one; a later call for a number replaces an
//! earlier one. What is put is built in `allocator()` or borrowed from the
//! document, and must last until `finish`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Document = @import("Document.zig");
const Lexer = @import("Lexer.zig");
const object = @import("object.zig");
const print = @import("print.zig");

const Dict = object.Dict;
const Object = object.Object;
const Ref = object.Ref;

const Writer = @This();

pub const Error = error{
    /// Its strings and streams are ciphertext, and what would be appended
    /// is not.
    Encrypted,
    /// Its cross-reference table was rebuilt by scanning, so there is no
    /// section for `/Prev` to name and no telling what other readers make
    /// of the file.
    Recovered,
    /// A stream as a value inside another object. Streams are always
    /// indirect; give it a number of its own.
    StreamInValue,
} || Io.Writer.Error || Document.Error;

gpa: Allocator,
doc: *Document,
arena_state: std.heap.ArenaAllocator,
pending: std.AutoArrayHashMapUnmanaged(u32, Pending) = .empty,
/// The file's `/Size`, past every number it uses.
size: u32,
/// The next number `fresh` hands out.
next: u32,

const Pending = union(enum) {
    object: Object,
    /// Bytes as they go in the file, with the `/Filter` in `dict` that
    /// reads them.
    stream: struct { dict: Dict, data: []const u8 },
    free,
};

pub fn init(gpa: Allocator, doc: *Document) Error!Writer {
    if (doc.isEncrypted()) return error.Encrypted;
    if (doc.recovered or doc.table.recovered) return error.Recovered;
    const declared = if (doc.trailer().get("Size")) |v| v.asInt() orelse 0 else 0;
    const size: u32 = @intCast(std.math.clamp(declared, 0, std.math.maxInt(u31)));
    const past = @max(size, doc.table.maxObjectNumber() +| 1);
    return .{ .gpa = gpa, .doc = doc, .arena_state = .init(gpa), .size = past, .next = past };
}

/// What a certification signature permits after it (§12.8.2.2, DocMDP):
/// 1 no change at all, 2 filling in forms and signing, 3 those and
/// annotations. Null for a file nobody certified, which permits anything.
///
/// Asked by whoever appends, not refused here: an update of 3 may hold
/// annotations and must not hold anything else, which is a question about
/// what is in it, and this file only writes what it is given.
pub fn certified(doc: *Document) Document.Error!?u8 {
    const root = try doc.catalog();
    const perms = (try doc.get(root, "Perms") orelse return null).asDict() orelse return null;
    const sig = (try doc.get(perms, "DocMDP") orelse return null).asDict() orelse return null;
    // The standard's default, for a certification that does not say.
    const unsaid: u8 = 2;
    const refs = (try doc.get(sig, "Reference") orelse return unsaid).asArray() orelse return unsaid;
    for (refs) |raw| {
        const r = (try doc.resolve(raw)).asDict() orelse continue;
        const method = try doc.get(r, "TransformMethod") orelse continue;
        if (!method.isName("DocMDP")) continue;
        const params = (try doc.get(r, "TransformParams") orelse return unsaid).asDict() orelse return unsaid;
        const p = (try doc.get(params, "P") orelse return unsaid).asInt() orelse return unsaid;
        return @intCast(std.math.clamp(p, 1, 3));
    }
    return unsaid;
}

pub fn deinit(w: *Writer) void {
    w.pending.deinit(w.gpa);
    w.arena_state.deinit();
    w.* = undefined;
}

/// Where to build what is put, so it lasts until `finish`.
pub fn allocator(w: *Writer) Allocator {
    return w.arena_state.allocator();
}

/// A number no object in the file or in this update has.
pub fn fresh(w: *Writer) u32 {
    defer w.next += 1;
    return w.next;
}

/// Whether anything has been put or freed. A save with nothing in it writes
/// nothing, and a document only read is never written.
pub fn isEmpty(w: Writer) bool {
    return w.pending.count() == 0;
}

/// `num` is `obj` from this update on. A stream object is written as it
/// stands, its data under the filters its dictionary names.
pub fn put(w: *Writer, num: u32, obj: Object) Error!void {
    const pending: Pending = switch (obj) {
        .stream => |s| .{ .stream = .{ .dict = s.dict, .data = s.raw } },
        else => .{ .object = obj },
    };
    try w.pending.put(w.gpa, num, pending);
}

/// A stream of `plain` bytes, compressed when that makes it smaller. Below
/// a hundred bytes or so it does not: zlib's header and checksum and the
/// `/Filter` naming it cost more than the compression saves.
pub fn putContent(w: *Writer, num: u32, dict: Dict, plain: []const u8) Error!void {
    const a = w.allocator();
    var d = try dict.clone(a);
    const packed_bytes = try deflate(a, plain);
    var data = plain;
    if (packed_bytes.len + "/Filter/FlateDecode".len < plain.len) {
        try d.put(a, "Filter", .{ .name = "FlateDecode" });
        data = packed_bytes;
    }
    try w.pending.put(w.gpa, num, .{ .stream = .{ .dict = d, .data = data } });
}

/// A coordinate fenrir made, held to a hundredth of a point, which is past
/// what any screen or printer resolves and writes as `20.5` rather than
/// `20.499999046325684`. Only for numbers fenrir makes: see `number`.
pub fn hundredths(v: f64) Object {
    const r = @round(v * 100) / 100;
    if (!std.math.isFinite(r)) return .{ .integer = 0 };
    if (r == @trunc(r) and @abs(r) < 1e15) return .{ .integer = @intFromFloat(r) };
    return .{ .real = r };
}

/// Deletes `num` from this update on: a free entry, at the next generation.
pub fn free(w: *Writer, num: u32) Error!void {
    try w.pending.put(w.gpa, num, .free);
}

pub const Options = struct {
    /// Mixed into the `/ID` this update writes, as §14.4 suggests: the
    /// caller's clock and the file's path. The library has neither.
    seed: []const u8 = "",
};

/// One row of the section: a number and where it is.
const Row = struct {
    num: u32,
    kind: enum(u8) { free = 0, in_file = 1, in_stream = 2 },
    /// The offset, the object stream's number, or for a free entry zero.
    where: u64,
    /// The generation, or the place in the object stream.
    gen: u32,

    fn before(_: void, a: Row, b: Row) bool {
        return a.num < b.num;
    }
};

/// The bytes to append to `doc.bytes`, owned by the caller. Empty when
/// nothing was put.
pub fn finish(w: *Writer, options: Options) Error![]u8 {
    if (w.isEmpty()) return w.gpa.alloc(u8, 0);
    const a = w.allocator();
    const base = w.doc.bytes.len;

    var file: Io.Writer.Allocating = .init(w.gpa);
    defer file.deinit();
    const out = &file.writer;
    // `%%EOF` and the first object header are never one line.
    if (base == 0 or !Lexer.isWhitespace(w.doc.bytes[base - 1])) try out.writeByte('\n');

    const streams = crossReferenceStreams(w.doc);
    var rows: std.ArrayList(Row) = .empty;
    var packed_nums: std.ArrayList(u32) = .empty;
    var packed_values: std.ArrayList(Object) = .empty;

    const nums = try a.dupe(u32, w.pending.keys());
    std.mem.sort(u32, nums, {}, std.sort.asc(u32));
    for (nums) |num| {
        const gen = generation(w.doc, num);
        switch (w.pending.get(num).?) {
            .free => try rows.append(a, .{ .num = num, .kind = .free, .where = 0, .gen = @min(gen + 1, 65535) }),
            .stream => |s| {
                try rows.append(a, .{ .num = num, .kind = .in_file, .where = base + file.written().len, .gen = gen });
                try writeStream(out, .{ .num = num, .gen = @intCast(gen) }, a, s.dict, s.data);
            },
            // An object stream holds generation 0 and nothing else
            // (§7.5.7): a changed object of a later generation keeps it,
            // and goes in the file on its own.
            .object => |obj| if (streams and gen == 0) {
                try packed_nums.append(a, num);
                try packed_values.append(a, obj);
            } else {
                try rows.append(a, .{ .num = num, .kind = .in_file, .where = base + file.written().len, .gen = gen });
                try out.print("{d} {d} obj\n", .{ num, gen });
                var emit: Emit = .{ .w = out };
                try emit.value(obj);
                try out.writeAll("\nendobj\n");
            },
        }
    }

    if (packed_nums.items.len != 0) {
        const container = w.fresh();
        var body: Io.Writer.Allocating = .init(a);
        var header: Io.Writer.Allocating = .init(a);
        for (packed_nums.items, packed_values.items, 0..) |num, obj, i| {
            if (i != 0) try body.writer.writeByte(' ');
            try header.writer.print("{s}{d} {d}", .{ if (i == 0) "" else " ", num, body.written().len });
            var emit: Emit = .{ .w = &body.writer };
            try emit.value(obj);
            try rows.append(a, .{ .num = num, .kind = .in_stream, .where = container, .gen = @intCast(i) });
        }
        try header.writer.writeByte('\n');
        const plain = try std.mem.concat(a, u8, &.{ header.written(), body.written() });

        var dict: Dict = .empty;
        try dict.put(a, "Type", .{ .name = "ObjStm" });
        try dict.put(a, "N", .{ .integer = @intCast(packed_nums.items.len) });
        try dict.put(a, "First", .{ .integer = @intCast(header.written().len) });
        try dict.put(a, "Filter", .{ .name = "FlateDecode" });
        try rows.append(a, .{ .num = container, .kind = .in_file, .where = base + file.written().len, .gen = 0 });
        try writeStream(out, .{ .num = container, .gen = 0 }, a, dict, try deflate(a, plain));
    }

    const id = try w.identify(a, options.seed);
    if (streams) {
        try w.sectionStream(out, &file, a, base, &rows, id);
    } else {
        try w.sectionTable(out, &file, a, base, &rows, id);
    }
    return file.toOwnedSlice();
}

/// The update's section as a cross-reference stream (§7.5.8), which lists
/// itself and carries the trailer's keys in its dictionary.
fn sectionStream(
    w: *Writer,
    out: *Io.Writer,
    file: *Io.Writer.Allocating,
    a: Allocator,
    base: usize,
    rows: *std.ArrayList(Row),
    id: [2][]const u8,
) Error!void {
    const self = w.fresh();
    const at = base + file.written().len;
    try rows.append(a, .{ .num = self, .kind = .in_file, .where = at, .gen = 0 });
    std.mem.sort(Row, rows.items, {}, Row.before);

    var widest: u64 = 0;
    var deepest: u64 = 0;
    for (rows.items) |r| {
        widest = @max(widest, r.where);
        deepest = @max(deepest, r.gen);
    }
    const widths = [3]u8{ 1, bytesFor(widest), bytesFor(deepest) };

    var data: std.ArrayList(u8) = .empty;
    for (rows.items) |r| {
        try data.append(a, @intFromEnum(r.kind));
        try appendBig(a, &data, r.where, widths[1]);
        try appendBig(a, &data, r.gen, widths[2]);
    }

    var dict = try w.trailerOf(a, rows.items, id);
    try dict.put(a, "Type", .{ .name = "XRef" });
    try dict.put(a, "Index", .{ .array = try runsOf(a, rows.items) });
    const w_array = try a.alloc(Object, 3);
    for (w_array, widths) |*slot, n| slot.* = .{ .integer = n };
    try dict.put(a, "W", .{ .array = w_array });
    try dict.put(a, "Filter", .{ .name = "FlateDecode" });
    try writeStream(out, .{ .num = self, .gen = 0 }, a, dict, try deflate(a, data.items));
    try out.print("startxref\n{d}\n%%EOF\n", .{at});
}

/// The update's section as a classic table (§7.5.4), for a file older than
/// the stream form.
fn sectionTable(
    w: *Writer,
    out: *Io.Writer,
    file: *Io.Writer.Allocating,
    a: Allocator,
    base: usize,
    rows: *std.ArrayList(Row),
    id: [2][]const u8,
) Error!void {
    std.mem.sort(Row, rows.items, {}, Row.before);
    const at = base + file.written().len;
    try out.writeAll("xref\n");
    const runs = try runsOf(a, rows.items);
    var r: usize = 0;
    var i: usize = 0;
    while (i < runs.len) : (i += 2) {
        const count: usize = @intCast(runs[i + 1].integer);
        try out.print("{d} {d}\n", .{ runs[i].integer, count });
        for (rows.items[r..][0..count]) |row| {
            // Twenty bytes an entry, the end of line two of them (§7.5.4).
            switch (row.kind) {
                .free => try out.print("0000000000 {d:0>5} f\r\n", .{row.gen}),
                else => try out.print("{d:0>10} {d:0>5} n\r\n", .{ row.where, row.gen }),
            }
        }
        r += count;
    }
    const dict = try w.trailerOf(a, rows.items, id);
    try out.writeAll("trailer\n");
    var emit: Emit = .{ .w = out };
    try emit.value(.{ .dict = dict });
    try out.print("\nstartxref\n{d}\n%%EOF\n", .{at});
}

/// The keys every section's trailer carries: `/Size` past every number,
/// `/Prev`, the catalog and information dictionary as the file names them,
/// and the `/ID`.
fn trailerOf(w: *Writer, a: Allocator, rows: []const Row, id: [2][]const u8) Error!Dict {
    var high: u32 = 0;
    for (rows) |r| high = @max(high, r.num);
    var dict: Dict = .empty;
    try dict.put(a, "Size", .{ .integer = @max(w.next, high +| 1) });
    if (w.doc.trailer().get("Root")) |root| try dict.put(a, "Root", root);
    if (w.doc.trailer().get("Info")) |info| try dict.put(a, "Info", info);
    try dict.put(a, "Prev", .{ .integer = @intCast(w.doc.table.start) });
    const pair = try a.alloc(Object, 2);
    // Digests are binary, so `Emit.string` writes them as hex.
    pair[0] = .{ .string = id[0] };
    pair[1] = .{ .string = id[1] };
    try dict.put(a, "ID", .{ .array = pair });
    return dict;
}

/// `/ID` (§14.4): the first half is the file's for good, kept when it has
/// one and made when it has none; the second is this revision's.
fn identify(w: *Writer, a: Allocator, seed: []const u8) Error![2][]const u8 {
    const Md5 = std.crypto.hash.Md5;
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, w.doc.bytes.len, .big);

    const first = if (w.doc.fileId()) |kept| kept else made: {
        var h: Md5 = .init(.{});
        h.update(seed);
        h.update(&length);
        h.update(w.doc.bytes[0..@min(w.doc.bytes.len, 1024)]);
        break :made try a.dupe(u8, &h.finalResult());
    };
    var h: Md5 = .init(.{});
    h.update(first);
    h.update(&length);
    h.update(seed);
    return .{ first, try a.dupe(u8, &h.finalResult()) };
}

/// The generation `num` has now: what a changed object keeps, and what a
/// free entry is one past.
fn generation(doc: *Document, num: u32) u32 {
    const entry = doc.table.get(num) orelse return 0;
    return switch (entry) {
        .in_file => |at| at.gen,
        .free, .in_stream => 0,
    };
}

/// Whether the file can be given the 1.5 forms: object streams and a
/// cross-reference stream. The later of the header and the catalog's
/// `/Version`, as §7.2.2 has it.
fn crossReferenceStreams(doc: *Document) bool {
    const header = versionOf(doc.headerVersion() orelse "1.0");
    const catalog = versionOf(doc.catalogVersion() orelse "1.0");
    return @max(header, catalog) >= 15;
}

/// `1.7` as 17 and `2.0` as 20; anything else as 10.
fn versionOf(text: []const u8) u32 {
    if (text.len < 3 or text[1] != '.') return 10;
    if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[2])) return 10;
    return @as(u32, text[0] - '0') * 10 + (text[2] - '0');
}

fn bytesFor(v: u64) u8 {
    var n: u8 = 1;
    while (n < 8 and v >> @intCast(n * 8) != 0) n += 1;
    return n;
}

fn appendBig(a: Allocator, data: *std.ArrayList(u8), v: u64, width: u8) Allocator.Error!void {
    var i: u8 = width;
    while (i > 0) {
        i -= 1;
        try data.append(a, @truncate(v >> @intCast(@as(u32, i) * 8)));
    }
}

/// The runs of consecutive numbers among sorted rows, as `/Index` pairs.
fn runsOf(a: Allocator, rows: []const Row) Allocator.Error![]const Object {
    var out: std.ArrayList(Object) = .empty;
    var i: usize = 0;
    while (i < rows.len) {
        var j = i + 1;
        while (j < rows.len and rows[j].num == rows[j - 1].num + 1) j += 1;
        try out.append(a, .{ .integer = rows[i].num });
        try out.append(a, .{ .integer = @intCast(j - i) });
        i = j;
    }
    return out.items;
}

fn writeStream(out: *Io.Writer, ref: Ref, a: Allocator, dict: Dict, data: []const u8) Error!void {
    var d = try dict.clone(a);
    try d.put(a, "Length", .{ .integer = @intCast(data.len) });
    _ = d.orderedRemove("DL");
    try out.print("{d} {d} obj\n", .{ ref.num, ref.gen });
    var emit: Emit = .{ .w = out };
    try emit.value(.{ .dict = d });
    try out.writeAll("\nstream\n");
    try out.writeAll(data);
    try out.writeAll("\nendstream\nendobj\n");
}

/// `data` through zlib, which is what `/FlateDecode` reads.
fn deflate(a: Allocator, data: []const u8) Error![]u8 {
    const flate = std.compress.flate;
    var out: Io.Writer.Allocating = try .initCapacity(a, @max(64, data.len / 2));
    const window = try a.alloc(u8, flate.max_window_len);
    // A quarter of a megabyte of tables: on the heap, not the stack.
    const c = try a.create(flate.Compress);
    c.* = try .init(&out.writer, window, .zlib, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.written();
}

/// Writes objects as PDF syntax, with a space between two tokens only where
/// they would otherwise read as one.
const Emit = struct {
    w: *Io.Writer,
    /// Whether the last byte written was a regular character, which another
    /// regular character after it would run into.
    regular: bool = false,

    fn token(e: *Emit, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (e.regular and Lexer.isRegular(bytes[0])) try e.w.writeByte(' ');
        try e.w.writeAll(bytes);
        e.regular = Lexer.isRegular(bytes[bytes.len - 1]);
    }

    fn value(e: *Emit, obj: Object) Error!void {
        var buf: [number_len]u8 = undefined;
        switch (obj) {
            .null => try e.token("null"),
            .boolean => |b| try e.token(if (b) "true" else "false"),
            .integer => |i| try e.token(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable),
            .real => |r| try e.token(number(&buf, r)),
            .string => |s| try e.string(s),
            .name => |n| {
                try print.writeName(e.w, n);
                e.regular = n.len != 0;
            },
            .array => |items| {
                try e.token("[");
                for (items) |item| try e.value(item);
                try e.token("]");
            },
            .dict => |d| {
                try e.token("<<");
                for (d.keys(), d.values()) |k, v| {
                    try e.value(.{ .name = k });
                    try e.value(v);
                }
                try e.token(">>");
            },
            .stream => return error.StreamInValue,
            .ref => |r| try e.token(std.fmt.bufPrint(&buf, "{d} {d} R", .{ r.num, r.gen }) catch unreachable),
        }
    }

    /// A literal string when it reads as text, escaping only `\`, the
    /// parentheses and CR, which a reader would otherwise take as a line
    /// end and turn into LF (§7.3.4.2). Hex for binary, as an `/ID` is.
    fn string(e: *Emit, s: []const u8) Io.Writer.Error!void {
        const text = for (s) |c| {
            if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') break false;
        } else true;
        if (!text) {
            try e.token("<");
            for (s) |c| try e.w.print("{x:0>2}", .{c});
            try e.w.writeByte('>');
            e.regular = false;
            return;
        }
        try e.token("(");
        for (s) |c| switch (c) {
            '\\', '(', ')' => {
                try e.w.writeByte('\\');
                try e.w.writeByte(c);
            },
            '\r' => try e.w.writeAll("\\r"),
            else => try e.w.writeByte(c),
        };
        try e.w.writeByte(')');
        e.regular = false;
    }
};

/// Room for any finite `f64` written out in full, which `{d}` does.
const number_len = 330;

/// `v` as the shortest decimal that reads back as the same `f64`, never in
/// exponent form, which PDF has not got, and with no zero before the point,
/// which §7.3.3 lets it leave out: `12`, `595.276`, `.5`, `-.25`.
///
/// **Exact, not rounded.** This once wrote every real to a hundredth, and a
/// page dictionary copied into a save had its `/MediaBox [0 0 595.276
/// 841.89]` come back as 595.28: the page moved, and its hash with it. A
/// number copied from the file must keep every digit it had. Fenrir's own
/// are rounded where they are made, by `hundredths` -- do not move the
/// rounding back here.
fn number(buf: *[number_len]u8, v: f64) []const u8 {
    if (!std.math.isFinite(v)) return "0";
    const text = std.fmt.bufPrint(buf, "{d}", .{v}) catch return "0";
    if (std.mem.startsWith(u8, text, "0.")) return text[1..];
    if (std.mem.startsWith(u8, text, "-0.")) {
        buf[1] = '-';
        return buf[1..text.len];
    }
    return text;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const pages = @import("pages.zig");

/// A file whose cross-reference table is right, so it opens without being
/// recovered: one object a string, numbered from 1, with `trailer_extra`
/// added to its trailer.
fn fixture(version: []const u8, objects: []const []const u8, trailer_extra: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("%PDF-{s}\n", .{version});
    var offsets: [16]usize = undefined;
    for (objects, 0..) |obj, i| {
        offsets[i] = out.written().len;
        try w.print("{d} 0 obj\n{s}\nendobj\n", .{ i + 1, obj });
    }
    const at = out.written().len;
    try w.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{objects.len + 1});
    for (objects, 0..) |_, i| try w.print("{d:0>10} 00000 n\r\n", .{offsets[i]});
    try w.print("trailer\n<< /Size {d} /Root 1 0 R {s} >>\nstartxref\n{d}\n%%EOF\n", .{ objects.len + 1, trailer_extra, at });
    return out.toOwnedSlice();
}

const page_tree = [_][]const u8{
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] >>",
};

/// Opens `old ++ update`, as the file is after a save.
fn reopen(old: []const u8, update: []const u8) !Document {
    return Document.open(testing.allocator, try std.mem.concat(testing.allocator, u8, &.{ old, update }));
}

/// Gives the page a highlight, the change a save makes most.
fn annotate(w: *Writer, doc: *Document) !u32 {
    const a = w.allocator();
    const page = (try pages.all(doc))[0];
    const num = w.fresh();
    var annot: Dict = .empty;
    try annot.put(a, "Subtype", .{ .name = "Highlight" });
    // Copied into the writer's arena: an array literal of numbers made at
    // run time is this function's stack, gone by `finish`. A debug build
    // read it back intact; ReleaseFast reused it and crashed.
    try annot.put(a, "Rect", .{ .array = try a.dupe(Object, &.{ hundredths(10), hundredths(20.499999), hundredths(0.25), .{ .integer = 4 } }) });
    try annot.put(a, "NM", .{ .string = "f1" });
    try w.put(num, .{ .dict = annot });

    var changed = try page.dict.clone(a);
    const list = try a.alloc(Object, 1);
    list[0] = .{ .ref = .{ .num = num, .gen = 0 } };
    try changed.put(a, "Annots", .{ .array = list });
    try w.put(page.ref.num, .{ .dict = changed });
    return num;
}

test "an update to a 1.7 file is one object stream and a cross-reference stream" {
    const old = try fixture("1.7", &page_tree, "/ID [<0a1b2c3d> <0a1b2c3d>]");
    var doc = try Document.open(testing.allocator, old);
    defer doc.deinit();

    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    const num = try annotate(&w, &doc);
    const update = try w.finish(.{ .seed = "test" });
    defer testing.allocator.free(update);

    try testing.expect(std.mem.indexOf(u8, update, "/Type/ObjStm") != null);
    try testing.expect(std.mem.indexOf(u8, update, "/Type/XRef") != null);
    try testing.expect(std.mem.indexOf(u8, update, "\nxref\n") == null);

    var after = try reopen(old, update);
    defer after.deinit();
    // Read through its own sections, not rebuilt by scanning.
    try testing.expect(!after.recovered);
    try testing.expectEqual(@as(i64, @intCast(doc.table.start)), after.trailer().get("Prev").?.asInt().?);
    try testing.expectEqualSlices(u8, "\x0a\x1b\x2c\x3d", after.fileId().?);

    const page = (try pages.all(&after))[0];
    const annots = try page.annotations(&after);
    try testing.expectEqual(@as(usize, 1), annots.len);
    try testing.expectEqual(num, annots[0].asRef().?.num);
    const annot = (try after.resolve(annots[0])).asDict().?;
    try testing.expect(annot.get("Subtype").?.isName("Highlight"));
    try testing.expectEqualStrings("f1", annot.get("NM").?.asString().?);
    try testing.expectEqual(@as(f64, 20.5), annot.get("Rect").?.asArray().?[1].asNumber().?);
}

test "a file older than 1.5 is given a classic table, and an /ID" {
    const old = try fixture("1.4", &page_tree, "");
    var doc = try Document.open(testing.allocator, old);
    defer doc.deinit();

    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    _ = try annotate(&w, &doc);
    const update = try w.finish(.{ .seed = "test" });
    defer testing.allocator.free(update);

    try testing.expect(std.mem.indexOf(u8, update, "ObjStm") == null);
    try testing.expect(std.mem.startsWith(u8, update[std.mem.indexOf(u8, update, "xref").?..], "xref\n3 2\n"));

    var after = try reopen(old, update);
    defer after.deinit();
    try testing.expect(!after.recovered);
    try testing.expectEqual(@as(usize, 16), after.fileId().?.len);
    try testing.expectEqual(@as(usize, 1), (try (try pages.all(&after))[0].annotations(&after)).len);
}

test "saves chain through /Prev, and a freed object reads as nothing" {
    const old = try fixture("1.7", &page_tree, "");
    var doc = try Document.open(testing.allocator, old);
    defer doc.deinit();

    var first = try Writer.init(testing.allocator, &doc);
    defer first.deinit();
    const num = try annotate(&first, &doc);
    const one = try first.finish(.{});
    defer testing.allocator.free(one);

    var middle = try reopen(old, one);
    defer middle.deinit();
    var second = try Writer.init(testing.allocator, &middle);
    defer second.deinit();
    try second.free(num);
    const two = try second.finish(.{});
    defer testing.allocator.free(two);

    const both = try std.mem.concat(testing.allocator, u8, &.{ old, one });
    defer testing.allocator.free(both);
    var last = try reopen(both, two);
    defer last.deinit();
    try testing.expect(!last.recovered);
    // The page changed in the first save is still found, through the
    // second save's `/Prev`, and the highlight it lists is gone.
    try testing.expectEqual(@as(usize, 1), (try (try pages.all(&last))[0].annotations(&last)).len);
    try testing.expect((try last.fetch(.{ .num = num, .gen = 0 })).isNull());
    // Its `/ID` is the first save's first half.
    try testing.expectEqualSlices(u8, middle.fileId().?, last.fileId().?);
}

test "nothing put is nothing written, and what cannot be appended to is refused" {
    const old = try fixture("1.7", &page_tree, "");
    var doc = try Document.open(testing.allocator, old);
    defer doc.deinit();
    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();
    try testing.expect(w.isEmpty());
    const none = try w.finish(.{});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    var locked = try Document.open(testing.allocator, try fixture("1.7", &page_tree, "/Encrypt << /Filter /Standard >>"));
    defer locked.deinit();
    try testing.expectError(error.Encrypted, Writer.init(testing.allocator, &locked));

    // `startxref 0`: the table is rebuilt by scanning.
    var broken = try Document.open(testing.allocator, try testing.allocator.dupe(u8,
        \\%PDF-1.7
        \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        \\2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        \\trailer << /Root 1 0 R >>
        \\startxref 0
        \\%%EOF
    ));
    defer broken.deinit();
    try testing.expectError(error.Recovered, Writer.init(testing.allocator, &broken));
}

test "content is compressed only when that makes it smaller" {
    const old = try fixture("1.7", &page_tree, "");
    var doc = try Document.open(testing.allocator, old);
    defer doc.deinit();
    var w = try Writer.init(testing.allocator, &doc);
    defer w.deinit();

    const long = comptime blk: {
        var s: []const u8 = "";
        for (0..40) |_| s = s ++ "1 0 0 rg 0 0 10 10 re f\n";
        break :blk s;
    };
    const big = w.fresh();
    const small = w.fresh();
    try w.putContent(big, .empty, long);
    try w.putContent(small, .empty, "0 0 1 1 re f");
    const update = try w.finish(.{});
    defer testing.allocator.free(update);

    var after = try reopen(old, update);
    defer after.deinit();
    const a = (try after.fetch(.{ .num = big, .gen = 0 })).asStream().?;
    const b = (try after.fetch(.{ .num = small, .gen = 0 })).asStream().?;
    try testing.expect(a.dict.get("Filter").?.isName("FlateDecode"));
    try testing.expect(a.raw.len < long.len);
    try testing.expectEqualStrings(long, (try after.streamData(a)).data);
    try testing.expect(b.dict.get("Filter") == null);
    try testing.expectEqualStrings("0 0 1 1 re f", (try after.streamData(b)).data);
}

test "copied numbers are written exactly, fenrir's to a hundredth, and tokens run together where they can" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var emit: Emit = .{ .w = &out.writer };
    var d: Dict = .empty;
    defer d.deinit(testing.allocator);
    try d.put(testing.allocator, "A B", .{ .array = &.{
        .{ .real = 12.0 },         .{ .real = 0.5 },                    hundredths(-3.049),
        .{ .real = -0.25 },        .{ .real = 595.276 },                hundredths(@as(f32, 132.9)),
        .{ .integer = 7 },         .{ .boolean = true },                .{ .string = "a(b)\\c\r" },
        .{ .string = "\x00\xff" }, .{ .ref = .{ .num = 4, .gen = 0 } }, .null,
    } });
    try d.put(testing.allocator, "N", .{ .name = "Highlight" });
    try emit.value(.{ .dict = d });
    try testing.expectEqualStrings(
        "<</A#20B[12 .5 -3.05 -.25 595.276 132.9 7 true(a\\(b\\)\\\\c\\r)<00ff>4 0 R null]/N/Highlight>>",
        out.written(),
    );
}
