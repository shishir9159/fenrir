//! Cross-reference loading (ISO 32000-2 §7.5.4 and §7.5.8).
//!
//! A PDF is read back to front: `startxref` at the end of the file gives the
//! byte offset of the newest cross-reference section, whose trailer may point
//! at an older one via `/Prev`, and so on. Later sections shadow earlier ones,
//! so walking newest-first and keeping the first entry seen for each object
//! number gives the current state of the document.
//!
//! Two encodings exist and both must be supported: the original ASCII `xref`
//! table, and the compressed cross-reference *stream* introduced in PDF 1.5,
//! which is how essentially every modern file is written.
//!
//! Finally, offsets in real files are often wrong -- truncated downloads,
//! bytes prepended by a broken transfer, hand-edited files. `reconstruct`
//! rebuilds the table by scanning the whole file for `N G obj`, and the
//! document layer falls back to it whenever the normal path fails to produce a
//! usable catalog.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const filter = @import("filter.zig");
const object = @import("object.zig");
const Dict = object.Dict;
const Object = object.Object;
const Ref = object.Ref;

pub const Error = error{
    /// No `startxref` in the last kilobyte of the file.
    MissingStartxref,
    /// The section at that offset was neither a table nor an xref stream.
    InvalidXrefSection,
    /// An xref stream lacked `/W`, or its widths did not add up.
    InvalidXrefStream,
    /// Scanning found no indirect objects at all.
    NotAPdf,
} || Parser.Error || filter.Error || Allocator.Error;

/// Where an object lives.
pub const Entry = union(enum) {
    /// Deleted, or never allocated.
    free,
    /// At a byte offset in the file.
    in_file: struct { offset: u64, gen: u16 },
    /// Inside an object stream, at `index` within container object `container`.
    in_stream: struct { container: u32, index: u32 },
};

pub const Table = struct {
    /// Sparse: object numbers in real files are not contiguous.
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    /// The merged trailer. Keys from newer sections win.
    trailer: Dict = .empty,
    /// True when the table came from `reconstruct` rather than from the file's
    /// own cross-reference data.
    recovered: bool = false,

    pub fn get(t: Table, num: u32) ?Entry {
        return t.entries.get(num);
    }

    /// Highest object number present, for reporting.
    pub fn maxObjectNumber(t: Table) u32 {
        var max: u32 = 0;
        var it = t.entries.keyIterator();
        while (it.next()) |k| max = @max(max, k.*);
        return max;
    }

    pub fn count(t: Table) usize {
        return t.entries.count();
    }
};

/// Loads the cross-reference chain. All allocation happens in `arena`, whose
/// lifetime must cover the returned table.
pub fn load(arena: Allocator, src: []const u8) Error!Table {
    var table: Table = .{};

    const start = try findStartxref(src);

    // Section offsets already visited, so a `/Prev` cycle terminates.
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;

    var next_offset: ?u64 = start;
    while (next_offset) |offset| {
        if (offset >= src.len) break;
        if ((try seen.getOrPut(arena, offset)).found_existing) break;

        const trailer = readSection(arena, src, offset, &table) catch break;
        try mergeTrailer(arena, &table.trailer, trailer);

        // A hybrid-reference file keeps a second, stream-encoded table for
        // readers that understand it. Its entries take priority over the
        // plain table we just read, but not over anything newer.
        if (trailer.get("XRefStm")) |x| {
            if (x.asInt()) |stm| {
                if (stm >= 0 and @as(u64, @intCast(stm)) < src.len) {
                    if (readSection(arena, src, @intCast(stm), &table)) |hybrid| {
                        try mergeTrailer(arena, &table.trailer, hybrid);
                    } else |_| {}
                }
            }
        }

        next_offset = if (trailer.get("Prev")) |p| blk: {
            const v = p.asInt() orelse break :blk null;
            break :blk if (v >= 0) @as(u64, @intCast(v)) else null;
        } else null;
    }

    if (table.entries.count() == 0) return error.InvalidXrefSection;
    return table;
}

/// Rebuilds a table by scanning for `N G obj`. Later definitions win, matching
/// the incremental-update rule that the last version of an object is current.
pub fn reconstruct(arena: Allocator, src: []const u8) Error!Table {
    var table: Table = .{ .recovered = true };

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "obj")) |at| {
        i = at + 3;
        // `obj` must be a whole token, and must be preceded by `N G `.
        if (at + 3 < src.len and Lexer.isRegular(src[at + 3])) continue;
        const header = scanBackwardsForObjHeader(src, at) orelse continue;
        try table.entries.put(arena, header.ref.num, .{
            .in_file = .{ .offset = header.offset, .gen = header.ref.gen },
        });
    }

    if (table.entries.count() == 0) return error.NotAPdf;

    // Prefer a real trailer if one survived; otherwise look for the catalog.
    if (findLastTrailer(arena, src)) |t| {
        table.trailer = t;
    } else {
        try recoverTrailerFromCatalog(arena, src, &table);
    }

    // Object streams hold objects that no `N G obj` header describes, so their
    // contents must be indexed too.
    try indexObjectStreams(arena, src, &table);
    return table;
}

// -- locating the first section ---------------------------------------------

/// `startxref` lives near the end, after `%%EOF`. Search a generous tail so
/// that files with trailing junk still load.
fn findStartxref(src: []const u8) Error!u64 {
    const tail_len = @min(src.len, 2048);
    const tail = src[src.len - tail_len ..];
    const at = std.mem.lastIndexOf(u8, tail, "startxref") orelse return error.MissingStartxref;

    var i = at + "startxref".len;
    while (i < tail.len and Lexer.isWhitespace(tail[i])) i += 1;
    const digits_start = i;
    while (i < tail.len and std.ascii.isDigit(tail[i])) i += 1;
    if (i == digits_start) return error.MissingStartxref;

    return std.fmt.parseInt(u64, tail[digits_start..i], 10) catch error.MissingStartxref;
}

// -- one section ------------------------------------------------------------

/// Reads either encoding at `offset`, adding entries that are not already
/// present, and returns that section's trailer dictionary.
fn readSection(arena: Allocator, src: []const u8, offset: u64, table: *Table) Error!Dict {
    if (offset >= src.len) return error.InvalidXrefSection;
    const at: usize = @intCast(offset);

    if (sectionAt(arena, src, at, table)) |trailer| return trailer else |err| {
        // Cross-reference offsets drift in files that have been repaired,
        // re-saved, or had bytes prepended -- a `/Prev` a few hundred bytes
        // short of its section is common. Losing the rest of the chain over
        // that costs far more than looking nearby costs.
        const near = findSectionNear(src, at) orelse return err;
        if (near == at) return err;
        return sectionAt(arena, src, near, table);
    }
}

fn sectionAt(arena: Allocator, src: []const u8, at: usize, table: *Table) Error!Dict {
    var lexer: Lexer = .initAt(src, at);
    lexer.skipSpace();

    if (std.mem.startsWith(u8, src[lexer.pos..], "xref")) {
        return readTable(arena, src, lexer.pos + "xref".len, table);
    }
    return readStream(arena, src, at, table);
}

/// How far from a stated offset to look for a section that is not there.
const section_search_window = 8192;

/// Finds the section header nearest to `offset`: either a standalone `xref`
/// keyword, or the `N G obj` header of a cross-reference stream.
fn findSectionNear(src: []const u8, offset: usize) ?usize {
    const start = offset -| section_search_window;
    const end = @min(src.len, offset +| section_search_window);
    if (start >= end) return null;
    const window = src[start..end];

    var best: ?usize = null;

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, window, i, "xref")) |found| {
        i = found + "xref".len;
        // Must be a whole token, which is what rejects `startxref`.
        if (found > 0 and Lexer.isRegular(window[found - 1])) continue;
        if (i < window.len and Lexer.isRegular(window[i])) continue;
        best = nearer(best, start + found, offset);
    }
    if (best) |b| return b;

    i = 0;
    while (std.mem.indexOfPos(u8, window, i, "obj")) |found| {
        i = found + "obj".len;
        if (i < window.len and Lexer.isRegular(window[i])) continue;
        const header = scanBackwardsForObjHeader(window, found) orelse continue;
        best = nearer(best, start + @as(usize, @intCast(header.offset)), offset);
    }
    return best;
}

fn nearer(current: ?usize, candidate: usize, target: usize) usize {
    const c = current orelse return candidate;
    return if (distance(candidate, target) < distance(c, target)) candidate else c;
}

fn distance(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

/// The classic table:
///
///     xref
///     0 3
///     0000000000 65535 f
///     0000000017 00000 n
///     ...
///     trailer
///     << ... >>
fn readTable(arena: Allocator, src: []const u8, start: usize, table: *Table) Error!Dict {
    var parser: Parser = .initAt(src, start, arena);

    // Subsection headers are `first count` pairs, repeated until the `trailer`
    // keyword. Peek at the raw bytes rather than lexing, because `parseObject`
    // rejects bare keywords by design.
    while (!nextWordIs(src, parser.pos(), "trailer")) {
        const sub_start = (parser.parseObject() catch break).asInt() orelse break;
        const sub_count = (parser.parseObject() catch break).asInt() orelse break;
        if (sub_start < 0 or sub_count < 0) break;

        try readSubsection(arena, &parser, @intCast(sub_start), @intCast(sub_count), table);
    }

    if (!nextWordIs(src, parser.pos(), "trailer")) return .empty;
    var lexer: Lexer = .initAt(src, parser.pos());
    lexer.skipSpace();

    var trailer_parser: Parser = .initAt(src, lexer.pos + "trailer".len, arena);
    const trailer = try trailer_parser.parseObject();
    return trailer.asDict() orelse .empty;
}

/// True if the next token in `src` at or after `from` is exactly `word`.
fn nextWordIs(src: []const u8, from: usize, word: []const u8) bool {
    var lexer: Lexer = .initAt(src, from);
    lexer.skipSpace();
    const rest = src[lexer.pos..];
    if (!std.mem.startsWith(u8, rest, word)) return false;
    return rest.len == word.len or !Lexer.isRegular(rest[word.len]);
}

fn readSubsection(
    arena: Allocator,
    parser: *Parser,
    first_num: u32,
    entry_count: u32,
    table: *Table,
) Error!void {
    for (0..entry_count) |i| {
        const save = parser.pos();
        const offset_obj = parser.parseObject() catch {
            parser.seek(save);
            return;
        };
        const gen_obj = parser.parseObject() catch {
            parser.seek(save);
            return;
        };

        // The type is a bare `n` or `f` keyword, which `parseObject` will not
        // return, so read it straight from the token stream.
        var lexer: Lexer = .initAt(parser.lexer.src, parser.pos());
        lexer.skipSpace();
        const kind = if (lexer.pos < lexer.src.len) lexer.src[lexer.pos] else 'f';
        parser.seek(lexer.pos + 1);

        const num: u32 = @intCast(first_num + @as(u64, i));
        const offset = offset_obj.asInt() orelse continue;
        const gen = gen_obj.asInt() orelse 0;

        // Entries from newer sections were inserted first and must not be
        // overwritten by the older ones we are walking into.
        const slot = try table.entries.getOrPut(arena, num);
        if (slot.found_existing) continue;

        slot.value_ptr.* = if (kind == 'n' and offset > 0)
            .{ .in_file = .{
                .offset = @intCast(offset),
                .gen = if (gen >= 0 and gen <= std.math.maxInt(u16)) @intCast(gen) else 0,
            } }
        else
            .free;
    }
}

/// The PDF 1.5 cross-reference stream: a normal indirect object whose data is
/// a packed binary table. `/W` gives the byte width of each of the three
/// fields, and a width of zero means "use the default" (type 1, everything
/// else 0).
fn readStream(arena: Allocator, src: []const u8, offset: usize, table: *Table) Error!Dict {
    var parser: Parser = .initAt(src, offset, arena);
    const indirect = try parser.parseIndirect();
    const stream = indirect.object.asStream() orelse return error.InvalidXrefSection;
    const dict = stream.dict;

    // An xref stream is never encrypted and its /Length is always direct, so
    // it can be decoded without a document.
    const chain = try filterChain(arena, dict);
    const decoded = try filter.decode(arena, stream.raw, chain);

    const widths = (dict.get("W") orelse return error.InvalidXrefStream).asArray() orelse
        return error.InvalidXrefStream;
    if (widths.len < 3) return error.InvalidXrefStream;

    var w: [3]usize = undefined;
    for (w[0..], widths[0..3]) |*slot, obj| {
        const v = obj.asInt() orelse return error.InvalidXrefStream;
        if (v < 0 or v > 8) return error.InvalidXrefStream;
        slot.* = @intCast(v);
    }
    const row_len = w[0] + w[1] + w[2];
    if (row_len == 0) return error.InvalidXrefStream;

    // `/Index` lists [first count] pairs; it defaults to the whole range.
    const size = (dict.get("Size") orelse Object{ .integer = 0 }).asInt() orelse 0;
    var default_index = [_]Object{ .{ .integer = 0 }, .{ .integer = size } };
    const index: []const Object = if (dict.get("Index")) |idx|
        idx.asArray() orelse &default_index
    else
        &default_index;

    var row: usize = 0;
    var pair: usize = 0;
    while (pair + 1 < index.len) : (pair += 2) {
        const first = index[pair].asInt() orelse continue;
        const n = index[pair + 1].asInt() orelse continue;
        if (first < 0 or n < 0) continue;

        for (0..@intCast(n)) |i| {
            const at = row * row_len;
            if (at + row_len > decoded.data.len) break;
            row += 1;

            const fields = decoded.data[at..][0..row_len];
            const kind = if (w[0] == 0) 1 else readBig(fields[0..w[0]]);
            const f2 = readBig(fields[w[0]..][0..w[1]]);
            const f3 = readBig(fields[w[0] + w[1] ..][0..w[2]]);

            const num: u32 = @intCast(@as(u64, @intCast(first)) + i);
            const slot = try table.entries.getOrPut(arena, num);
            if (slot.found_existing) continue;

            slot.value_ptr.* = switch (kind) {
                1 => .{ .in_file = .{
                    .offset = f2,
                    .gen = @truncate(f3),
                } },
                2 => .{ .in_stream = .{
                    .container = @truncate(f2),
                    .index = @truncate(f3),
                } },
                // Type 0 is a free entry; anything else is undefined and the
                // spec says to treat it as a reference to the null object.
                else => .free,
            };
        }
    }

    return dict;
}

fn readBig(bytes: []const u8) u64 {
    var v: u64 = 0;
    for (bytes) |b| v = v << 8 | b;
    return v;
}

/// Builds a filter chain from a stream dictionary whose values are all direct.
/// `Document` has a richer version that resolves references; this one exists
/// so cross-reference streams can be decoded before any document exists.
pub fn filterChain(arena: Allocator, dict: Dict) Error![]const filter.Spec {
    const filters = dict.get("Filter") orelse return &.{};
    const parms = dict.get("DecodeParms") orelse dict.get("DP") orelse Object.null_object;

    var specs: std.ArrayList(filter.Spec) = .empty;
    switch (filters) {
        .name => |n| try specs.append(arena, buildSpec(n, parms)),
        .array => |arr| for (arr, 0..) |f, i| {
            const name = f.asName() orelse continue;
            const p = switch (parms) {
                .array => |pa| if (i < pa.len) pa[i] else Object.null_object,
                else => if (i == 0) parms else Object.null_object,
            };
            try specs.append(arena, buildSpec(name, p));
        },
        else => {},
    }
    return specs.items;
}

pub fn buildSpec(name: []const u8, parms: Object) filter.Spec {
    var spec: filter.Spec = .{ .kind = .fromName(name) };
    const d = parms.asDict() orelse return spec;

    if (d.get("Predictor")) |p| {
        if (p.asInt()) |v| spec.predictor.kind = .fromInt(v);
    }
    if (d.get("Colors")) |p| {
        if (p.asInt()) |v| if (v > 0 and v <= 32) {
            spec.predictor.colors = @intCast(v);
        };
    }
    if (d.get("BitsPerComponent")) |p| {
        if (p.asInt()) |v| if (v > 0 and v <= 32) {
            spec.predictor.bits = @intCast(v);
        };
    }
    if (d.get("Columns")) |p| {
        if (p.asInt()) |v| if (v > 0 and v <= 1 << 24) {
            spec.predictor.columns = @intCast(v);
        };
    }
    if (d.get("EarlyChange")) |p| {
        if (p.asInt()) |v| spec.early_change = v != 0;
    }
    return spec;
}

fn mergeTrailer(arena: Allocator, into: *Dict, from: Dict) Allocator.Error!void {
    for (from.keys(), from.values()) |key, value| {
        // Newer sections were merged first and keep priority.
        if (into.contains(key)) continue;
        try into.put(arena, key, value);
    }
}

// -- reconstruction ---------------------------------------------------------

const ObjHeader = struct { ref: Ref, offset: u64 };

/// Given the index of an `obj` keyword, walks backwards over `G` and `N` to
/// recover the header and the offset it starts at.
fn scanBackwardsForObjHeader(src: []const u8, obj_at: usize) ?ObjHeader {
    var i = obj_at;

    i = skipSpaceBackwards(src, i) orelse return null;
    const gen_end = i;
    i = skipDigitsBackwards(src, i) orelse return null;
    const gen_start = i;
    if (gen_start == gen_end) return null;

    i = skipSpaceBackwards(src, i) orelse return null;
    const num_end = i;
    i = skipDigitsBackwards(src, i) orelse return null;
    const num_start = i;
    if (num_start == num_end) return null;

    // The number must start a token, not continue one.
    if (num_start > 0 and Lexer.isRegular(src[num_start - 1])) return null;

    const num = std.fmt.parseInt(u32, src[num_start..num_end], 10) catch return null;
    const gen = std.fmt.parseInt(u16, src[gen_start..gen_end], 10) catch return null;
    return .{ .ref = .{ .num = num, .gen = gen }, .offset = num_start };
}

fn skipSpaceBackwards(src: []const u8, from: usize) ?usize {
    var i = from;
    while (i > 0 and Lexer.isWhitespace(src[i - 1])) i -= 1;
    return if (i == from) null else i; // at least one separator required
}

fn skipDigitsBackwards(src: []const u8, from: usize) ?usize {
    var i = from;
    while (i > 0 and std.ascii.isDigit(src[i - 1])) i -= 1;
    return i;
}

fn findLastTrailer(arena: Allocator, src: []const u8) ?Dict {
    var best: ?Dict = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "trailer")) |at| {
        i = at + "trailer".len;
        var parser: Parser = .initAt(src, i, arena);
        const obj = parser.parseObject() catch continue;
        const dict = obj.asDict() orelse continue;
        if (dict.contains("Root")) best = dict;
    }
    return best;
}

/// No usable trailer survived. Find an object whose `/Type` is `/Catalog` and
/// synthesise a trailer pointing at it.
fn recoverTrailerFromCatalog(arena: Allocator, src: []const u8, table: *Table) Error!void {
    var it = table.entries.iterator();
    while (it.next()) |kv| {
        const entry = switch (kv.value_ptr.*) {
            .in_file => |f| f,
            else => continue,
        };
        var parser: Parser = .initAt(src, @intCast(entry.offset), arena);
        const indirect = parser.parseIndirect() catch continue;
        const dict = indirect.object.asDict() orelse continue;

        if (dict.get("Type")) |t| if (t.isName("Catalog")) {
            var trailer: Dict = .empty;
            try trailer.put(arena, "Root", .{ .ref = indirect.ref });
            table.trailer = trailer;
            return;
        };
    }
}

/// After a reconstruction, walk every recovered object looking for
/// `/Type /ObjStm` and register the objects it contains.
fn indexObjectStreams(arena: Allocator, src: []const u8, table: *Table) Error!void {
    // Snapshot the container numbers first: inserting while iterating a hash
    // map is not allowed.
    var containers: std.ArrayList(u32) = .empty;
    var it = table.entries.iterator();
    while (it.next()) |kv| {
        const entry = switch (kv.value_ptr.*) {
            .in_file => |f| f,
            else => continue,
        };
        var parser: Parser = .initAt(src, @intCast(entry.offset), arena);
        const indirect = parser.parseIndirect() catch continue;
        const stream = indirect.object.asStream() orelse continue;
        if (stream.dict.get("Type")) |t| if (t.isName("ObjStm")) {
            try containers.append(arena, kv.key_ptr.*);
        };
    }

    for (containers.items) |container| {
        const entry = switch (table.entries.get(container).?) {
            .in_file => |f| f,
            else => continue,
        };
        var parser: Parser = .initAt(src, @intCast(entry.offset), arena);
        const indirect = parser.parseIndirect() catch continue;
        const stream = indirect.object.asStream() orelse continue;

        const chain = try filterChain(arena, stream.dict);
        const decoded = filter.decode(arena, stream.raw, chain) catch continue;
        const n = if (stream.dict.get("N")) |v| v.asInt() orelse 0 else 0;

        var header: Parser = .init(decoded.data, arena);
        for (0..@intCast(n)) |i| {
            const num_obj = header.parseObject() catch break;
            _ = header.parseObject() catch break; // relative offset
            const num = num_obj.asInt() orelse break;
            if (num < 0 or num > std.math.maxInt(u32)) continue;

            const slot = try table.entries.getOrPut(arena, @intCast(num));
            // A later top-level definition of the same object wins over the
            // copy inside an object stream.
            if (slot.found_existing) continue;
            slot.value_ptr.* = .{ .in_stream = .{
                .container = container,
                .index = @intCast(i),
            } };
        }
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// A minimal but genuinely valid PDF with a classic cross-reference table.
/// The object offsets and the `startxref` value are computed at comptime, so
/// the fixture cannot drift out of sync with itself the way a hand-counted one
/// does.
const classic_pdf = build: {
    const obj1 = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n";
    const obj2 = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n";
    const obj3 = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n";

    const header = "%PDF-1.4\n";
    const off1 = header.len;
    const off2 = off1 + obj1.len;
    const off3 = off2 + obj2.len;
    const xref_at = off3 + obj3.len;

    break :build header ++ obj1 ++ obj2 ++ obj3 ++
        "xref\n0 4\n0000000000 65535 f \n" ++
        std.fmt.comptimePrint("{d:0>10} 00000 n \n", .{off1}) ++
        std.fmt.comptimePrint("{d:0>10} 00000 n \n", .{off2}) ++
        std.fmt.comptimePrint("{d:0>10} 00000 n \n", .{off3}) ++
        "trailer\n<< /Size 4 /Root 1 0 R >>\n" ++
        std.fmt.comptimePrint("startxref\n{d}\n", .{xref_at}) ++
        "%%EOF\n";
};

/// Byte offset of object 1, recomputed the same way the fixture builds it.
const classic_obj1_offset = "%PDF-1.4\n".len;

test "classic table" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try load(arena, classic_pdf);
    try testing.expectEqual(@as(usize, 4), table.count());
    try testing.expectEqual(Entry.free, table.get(0).?);
    try testing.expectEqual(@as(u64, classic_obj1_offset), table.get(1).?.in_file.offset);
    try testing.expectEqual(Ref{ .num = 1, .gen = 0 }, table.trailer.get("Root").?.ref);
    try testing.expect(!table.recovered);
}

test "reconstruction finds objects when the table is wrong" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try reconstruct(arena, classic_pdf);
    try testing.expect(table.recovered);
    try testing.expectEqual(@as(usize, 3), table.count());
    try testing.expectEqual(Ref{ .num = 1, .gen = 0 }, table.trailer.get("Root").?.ref);

    // The recovered offsets must actually point at their headers.
    const at = table.get(2).?.in_file.offset;
    try testing.expect(std.mem.startsWith(u8, classic_pdf[@intCast(at)..], "2 0 obj"));
}

test "reconstruction recovers a catalog without a trailer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const truncated = classic_pdf[0 .. std.mem.indexOf(u8, classic_pdf, "xref").?];
    const table = try reconstruct(arena, truncated);
    try testing.expectEqual(Ref{ .num = 1, .gen = 0 }, table.trailer.get("Root").?.ref);
}

test "a missing startxref is reported" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.MissingStartxref,
        load(arena_state.allocator(), "%PDF-1.4\nnothing here\n"),
    );
}
