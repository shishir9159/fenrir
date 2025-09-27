//! A loaded PDF: the cross-reference table, an object cache, and the lookups
//! that need both.
//!
//! `Document` owns the file bytes and one arena. Every `Object` handed out
//! borrows from one or the other, so nothing returned from here needs freeing
//! and objects stay cheap to copy. The arena is freed wholesale in `deinit`.
//!
//! Two facilities live here rather than lower down because they are the only
//! ones that need the whole graph: resolving indirect references (including
//! objects packed inside object streams), and decoding a stream, whose
//! `/Filter` and `/DecodeParms` may themselves be references.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const filter = @import("filter.zig");
const object = @import("object.zig");
const xref = @import("xref.zig");

const Dict = object.Dict;
const Object = object.Object;
const Ref = object.Ref;
const Stream = object.Stream;

const Document = @This();

pub const Error = error{
    /// The file does not begin with `%PDF-` and no objects could be found.
    NotAPdf,
    /// No `/Root`, or it does not point at a dictionary.
    MissingCatalog,
    /// An object referred to itself, directly or through a chain.
    CircularReference,
} || xref.Error || Parser.Error || filter.Error || Allocator.Error;

gpa: Allocator,
/// Backs every object, dictionary, and decoded object stream.
arena_state: std.heap.ArenaAllocator,
/// The whole file. Owned; freed in `deinit`.
bytes: []const u8,
table: xref.Table,
/// Parsed objects, keyed by object number. Generations are not part of the
/// key: a file only ever has one live generation of a given object.
cache: std.AutoHashMapUnmanaged(u32, Object) = .empty,
/// Decoded object streams, keyed by their container object number.
streams: std.AutoHashMapUnmanaged(u32, ObjectStream) = .empty,
/// Object numbers currently being parsed, to break reference cycles.
in_progress: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// True when the cross-reference table had to be rebuilt by scanning.
recovered: bool,

/// An `/Type /ObjStm` container: many small objects concatenated and
/// compressed together (§7.5.7). Its header is a list of
/// `object-number relative-offset` pairs.
const ObjectStream = struct {
    data: []const u8,
    /// Absolute offsets into `data`, in the order the header lists them.
    offsets: []const u32,
    numbers: []const u32,
};

/// Takes ownership of `bytes`, which must outlive nothing else -- it is freed
/// by `deinit`. Falls back to rebuilding the cross-reference table by scanning
/// whenever the file's own table does not yield a usable catalog.
pub fn open(gpa: Allocator, bytes: []const u8) Error!Document {
    var doc: Document = .{
        .gpa = gpa,
        .arena_state = .init(gpa),
        .bytes = bytes,
        .table = .{},
        .recovered = false,
    };
    errdefer doc.deinit();

    const arena = doc.arena_state.allocator();

    // Try the file's own cross-reference chain, then verify it actually leads
    // somewhere. A table that parses but points at nothing is worse than none.
    if (xref.load(arena, bytes)) |table| {
        doc.table = table;
        if (doc.tableLeadsToPages()) return doc;
    } else |_| {}

    doc.clearDerived();
    doc.table = try xref.reconstruct(arena, bytes);
    doc.recovered = true;
    return doc;
}

/// Whether a cross-reference table is good enough to keep.
///
/// "Is there a catalog?" is too weak a test. A partial table -- one whose
/// `/Prev` chain broke halfway -- routinely still contains the catalog while
/// missing the page tree it points at, and that failure is silent: the
/// document opens and then has no pages. Requiring the page tree to resolve
/// catches it, and costs two lookups.
fn tableLeadsToPages(doc: *Document) bool {
    const cat = doc.catalog() catch return false;
    const pages = (doc.get(cat, "Pages") catch return false) orelse return false;
    const tree = pages.asDict() orelse return false;
    return tree.contains("Kids") or tree.contains("Count");
}

/// Drops everything derived from a cross-reference table, so a second attempt
/// starts clean. The arena keeps the memory; that is fine for one retry.
fn clearDerived(doc: *Document) void {
    doc.cache.clearRetainingCapacity();
    doc.streams.clearRetainingCapacity();
    doc.in_progress.clearRetainingCapacity();
}

/// The document's arena. Anything allocated from it lives until `deinit`, so
/// modules layered above `Document` -- the page tree, later the content-stream
/// interpreter -- can hand out borrowed slices with the same ownership rule
/// the rest of the library uses: nothing returned needs freeing.
pub fn arenaAllocator(doc: *Document) Allocator {
    return doc.arena_state.allocator();
}

pub fn deinit(doc: *Document) void {
    doc.cache.deinit(doc.gpa);
    doc.streams.deinit(doc.gpa);
    doc.in_progress.deinit(doc.gpa);
    doc.arena_state.deinit();
    doc.gpa.free(doc.bytes);
    doc.* = undefined;
}

// -- file-level facts -------------------------------------------------------

/// The version from the `%PDF-x.y` header. `/Version` in the catalog can
/// override it in PDF 1.4 and later; `catalogVersion` reports that separately.
pub fn headerVersion(doc: *const Document) ?[]const u8 {
    // The header is normally at offset 0 but is allowed to be preceded by
    // junk, and often is.
    const window = doc.bytes[0..@min(doc.bytes.len, 1024)];
    const at = std.mem.indexOf(u8, window, "%PDF-") orelse return null;
    const rest = doc.bytes[at + "%PDF-".len ..];
    var end: usize = 0;
    while (end < rest.len and end < 8 and (std.ascii.isDigit(rest[end]) or rest[end] == '.')) end += 1;
    return if (end == 0) null else rest[0..end];
}

pub fn catalogVersion(doc: *Document) ?[]const u8 {
    const cat = doc.catalog() catch return null;
    const v = (doc.get(cat, "Version") catch return null) orelse return null;
    return v.asName();
}

pub fn trailer(doc: *const Document) Dict {
    return doc.table.trailer;
}

/// Encrypted documents parse structurally, but their strings and stream data
/// are ciphertext. Decryption is not implemented yet, so callers should say so
/// rather than presenting garbage.
pub fn isEncrypted(doc: *const Document) bool {
    return doc.table.trailer.contains("Encrypt");
}

pub fn objectCount(doc: *const Document) usize {
    return doc.table.count();
}

pub fn catalog(doc: *Document) Error!Dict {
    const root = doc.table.trailer.get("Root") orelse return error.MissingCatalog;
    const resolved = try doc.resolve(root);
    return resolved.asDict() orelse error.MissingCatalog;
}

// -- resolution -------------------------------------------------------------

/// Follows an indirect reference, chasing chains of them. Anything else is
/// returned unchanged.
pub fn resolve(doc: *Document, obj: Object) Error!Object {
    var current = obj;
    var hops: u8 = 0;
    while (current.asRef()) |ref| {
        if (hops == 32) return error.CircularReference;
        hops += 1;
        current = try doc.fetch(ref);
    }
    return current;
}

/// Looks up `key` in `dict` and resolves the result. Returns null for both a
/// missing key and an explicit null value, which the spec treats alike.
pub fn get(doc: *Document, dict: Dict, key: []const u8) Error!?Object {
    const raw = dict.get(key) orelse return null;
    const resolved = try doc.resolve(raw);
    return if (resolved.isNull()) null else resolved;
}

/// Loads one object by reference. Missing objects are the null object, not an
/// error: §7.3.10 says a reference to a nonexistent object is legal.
pub fn fetch(doc: *Document, ref: Ref) Error!Object {
    if (doc.cache.get(ref.num)) |cached| return cached;

    const entry = doc.table.get(ref.num) orelse return .null;

    // A cycle would otherwise recurse forever: an object stream whose /Length
    // lives inside the very stream being loaded, for instance.
    if ((try doc.in_progress.getOrPut(doc.gpa, ref.num)).found_existing) {
        return error.CircularReference;
    }
    defer _ = doc.in_progress.remove(ref.num);

    const loaded: Object = switch (entry) {
        .free => .null,
        .in_file => |at| try doc.parseAt(at.offset, ref.num),
        .in_stream => |at| try doc.fetchFromObjectStream(at.container, at.index, ref.num),
    };

    try doc.cache.put(doc.gpa, ref.num, loaded);
    return loaded;
}

/// Parses the indirect object at `offset`, checking that it is the one we
/// asked for. A mismatch means the table is stale, which is common enough
/// that it is worth one nearby rescan before giving up.
fn parseAt(doc: *Document, offset: u64, want: u32) Error!Object {
    if (offset >= doc.bytes.len) return .null;
    const at: usize = @intCast(offset);
    const arena = doc.arena_state.allocator();

    var parser: Parser = .initAt(doc.bytes, at, arena);
    if (parser.parseIndirect()) |indirect| {
        if (indirect.ref.num == want) return indirect.object;
    } else |_| {}

    // Some producers point at the whitespace before the header, or a few bytes
    // into it. Search a small window for the right `N 0 obj`.
    return doc.rescanFor(want, at);
}

/// Looks for `want 0 obj` near `hint`, then anywhere in the file. Only used
/// when the cross-reference table has already proven unreliable.
fn rescanFor(doc: *Document, want: u32, hint: usize) Error!Object {
    const arena = doc.arena_state.allocator();

    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{d} 0 obj", .{want}) catch return .null;

    const window_start = @min(doc.bytes.len, hint -| 64);
    const window_end = @min(doc.bytes.len, window_start + 4096);
    const ranges = [_][]const u8{ doc.bytes[window_start..window_end], doc.bytes };
    const bases = [_]usize{ window_start, 0 };

    for (ranges, bases) |range, base| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, range, i, needle)) |at| {
            i = at + needle.len;
            // Must start a token, or `12 0 obj` would match `112 0 obj`.
            if (at > 0 and std.ascii.isDigit(range[at - 1])) continue;

            var parser: Parser = .initAt(doc.bytes, base + at, arena);
            const indirect = parser.parseIndirect() catch continue;
            if (indirect.ref.num == want) return indirect.object;
        }
    }
    return .null;
}

// -- object streams ---------------------------------------------------------

fn fetchFromObjectStream(doc: *Document, container: u32, index: u32, want: u32) Error!Object {
    const stream = try doc.loadObjectStream(container);
    if (index >= stream.offsets.len) return .null;

    const arena = doc.arena_state.allocator();

    // Trust `index`, but check the object number the header claims. If the
    // table and the header disagree, the header is the one holding the data.
    const at = if (stream.numbers[index] == want)
        stream.offsets[index]
    else find: {
        for (stream.numbers, stream.offsets) |num, off| {
            if (num == want) break :find off;
        }
        break :find stream.offsets[index];
    };
    if (at >= stream.data.len) return .null;

    var parser: Parser = .initAt(stream.data, at, arena);
    return parser.parseObject() catch .null;
}

fn loadObjectStream(doc: *Document, container: u32) Error!ObjectStream {
    if (doc.streams.get(container)) |cached| return cached;

    const arena = doc.arena_state.allocator();
    const obj = try doc.fetch(.{ .num = container, .gen = 0 });
    const stream = obj.asStream() orelse return error.InvalidXrefStream;

    const decoded = try doc.streamData(stream);
    const n_raw = try doc.intField(stream.dict, "N", 0);
    const first_raw = try doc.intField(stream.dict, "First", 0);
    if (n_raw < 0 or first_raw < 0) return error.InvalidXrefStream;

    // Every header pair costs at least four bytes, so a count larger than that
    // allows is a corrupt or hostile file, not a big document.
    const n: usize = @min(@as(u64, @intCast(n_raw)), decoded.data.len / 4 + 1);
    const first: usize = @intCast(first_raw);

    var numbers: std.ArrayList(u32) = try .initCapacity(arena, n);
    var offsets: std.ArrayList(u32) = try .initCapacity(arena, n);

    var header: Parser = .init(decoded.data, arena);
    for (0..n) |_| {
        const num = (header.parseObject() catch break).asInt() orelse break;
        const rel = (header.parseObject() catch break).asInt() orelse break;
        if (num < 0 or num > std.math.maxInt(u32) or rel < 0) break;

        const absolute = first + @as(usize, @intCast(rel));
        if (absolute > decoded.data.len) break;

        numbers.appendAssumeCapacity(@intCast(num));
        offsets.appendAssumeCapacity(@intCast(absolute));
    }

    const result: ObjectStream = .{
        .data = decoded.data,
        .numbers = numbers.items,
        .offsets = offsets.items,
    };
    try doc.streams.put(doc.gpa, container, result);
    return result;
}

fn intField(doc: *Document, dict: Dict, key: []const u8, default: i64) Error!i64 {
    const v = try doc.get(dict, key) orelse return default;
    return v.asInt() orelse default;
}

// -- stream data ------------------------------------------------------------

/// Decodes a stream's bytes. The result is arena-allocated and lives as long
/// as the document, so callers must not free it.
///
/// `result.stopped_at` is set when the chain ended at an image codec; the data
/// is then that codec's encoded bytes, which is what an extractor wants.
pub fn streamData(doc: *Document, stream: *const Stream) Error!filter.Result {
    const arena = doc.arena_state.allocator();
    const chain = try doc.filterChain(stream.dict);

    return filter.decode(arena, stream.raw, chain) catch |err| switch (err) {
        // A stream that will not decode is still worth showing raw: it is
        // often encrypted, or truncated with a usable prefix.
        error.CorruptFlateStream => .{ .data = try arena.dupe(u8, stream.raw) },
        else => err,
    };
}

/// Builds a filter chain, resolving indirect `/Filter` and `/DecodeParms`.
/// The parallel function in `xref` handles the direct-only case, which is all
/// a cross-reference stream is allowed to use.
pub fn filterChain(doc: *Document, dict: Dict) Error![]const filter.Spec {
    const arena = doc.arena_state.allocator();

    const filters = try doc.get(dict, "Filter") orelse return &.{};
    const parms = try doc.get(dict, "DecodeParms") orelse
        try doc.get(dict, "DP") orelse Object.null_object;

    var specs: std.ArrayList(filter.Spec) = .empty;
    switch (filters) {
        .name => |n| try specs.append(arena, xref.buildSpec(n, try doc.resolve(parms))),
        .array => |arr| for (arr, 0..) |f, i| {
            const name = (try doc.resolve(f)).asName() orelse continue;
            const raw_parm = switch (parms) {
                .array => |pa| if (i < pa.len) pa[i] else Object.null_object,
                else => if (i == 0) parms else Object.null_object,
            };
            try specs.append(arena, xref.buildSpec(name, try doc.resolve(raw_parm)));
        },
        else => {},
    }
    return specs.items;
}

// -- iteration --------------------------------------------------------------

/// Walks every object number in the cross-reference table, in ascending order,
/// which the hash map itself does not provide.
pub const ObjectIterator = struct {
    doc: *Document,
    numbers: []const u32,
    index: usize = 0,

    pub const Item = struct {
        num: u32,
        entry: xref.Entry,
        object: Object,
    };

    /// Yields free entries too, so that callers reporting on the table see the
    /// same set of numbers the table holds. Callers that only want real
    /// objects skip `.free` themselves.
    pub fn next(it: *ObjectIterator) Error!?Item {
        while (it.index < it.numbers.len) {
            const num = it.numbers[it.index];
            it.index += 1;
            const entry = it.doc.table.get(num) orelse continue;
            return .{
                .num = num,
                .entry = entry,
                .object = if (entry == .free)
                    .null
                else
                    it.doc.fetch(.{ .num = num, .gen = 0 }) catch .null,
            };
        }
        return null;
    }
};

/// The returned iterator borrows arena memory and is valid until `deinit`.
pub fn objects(doc: *Document) Error!ObjectIterator {
    const arena = doc.arena_state.allocator();
    var numbers: std.ArrayList(u32) = try .initCapacity(arena, doc.table.count());

    var it = doc.table.entries.keyIterator();
    while (it.next()) |k| numbers.appendAssumeCapacity(k.*);
    std.mem.sort(u32, numbers.items, {}, std.sort.asc(u32));

    return .{ .doc = doc, .numbers = numbers.items };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Builds a document from a static string, copying it because `deinit` frees
/// the bytes it was given.
fn openStatic(src: []const u8) !Document {
    return Document.open(testing.allocator, try testing.allocator.dupe(u8, src));
}

const minimal_pdf =
    "%PDF-1.4\n" ++
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n" ++
    "4 0 obj\n<< /Length 20 >>\nstream\nBT /F1 12 Tf (hi) Tj\nendstream\nendobj\n" ++
    "trailer\n<< /Size 5 /Root 1 0 R >>\n" ++
    "startxref\n0\n" ++
    "%%EOF\n";

test "opens a file whose xref offset is wrong by falling back to scanning" {
    var doc = try openStatic(minimal_pdf);
    defer doc.deinit();

    try testing.expect(doc.recovered);
    try testing.expectEqualStrings("1.4", doc.headerVersion().?);
    try testing.expect(!doc.isEncrypted());

    const cat = try doc.catalog();
    try testing.expect(cat.get("Type").?.isName("Catalog"));
}

test "resolves references through the catalog" {
    var doc = try openStatic(minimal_pdf);
    defer doc.deinit();

    const cat = try doc.catalog();
    const pages = (try doc.get(cat, "Pages")).?;
    try testing.expectEqual(@as(i64, 1), pages.find("Count").?.integer);

    const kids = (try doc.get(pages.asDict().?, "Kids")).?.array;
    const page = try doc.resolve(kids[0]);
    try testing.expect(page.find("Type").?.isName("Page"));
}

test "reads stream data" {
    var doc = try openStatic(minimal_pdf);
    defer doc.deinit();

    const obj = try doc.fetch(.{ .num = 4, .gen = 0 });
    const data = try doc.streamData(obj.asStream().?);
    try testing.expectEqualStrings("BT /F1 12 Tf (hi) Tj", data.data);
}

test "a reference to a nonexistent object is null, not an error" {
    var doc = try openStatic(minimal_pdf);
    defer doc.deinit();

    const missing = try doc.fetch(.{ .num = 9999, .gen = 0 });
    try testing.expect(missing.isNull());
}

test "iterates objects in ascending order" {
    var doc = try openStatic(minimal_pdf);
    defer doc.deinit();

    var it = try doc.objects();
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(testing.allocator);
    while (try it.next()) |item| try seen.append(testing.allocator, item.num);

    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, seen.items);
}
