//! The PDF object model (ISO 32000-2 §7.3).
//!
//! Objects are plain values, cheap to copy, and never own their memory: every
//! slice either points into the mapped file bytes or into the owning
//! `Document`'s arena. Nothing here allocates, and nothing here needs freeing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A name object with the leading `/` and any `#xx` escapes already removed.
/// Distinct from `String` only by which union tag holds it.
pub const Name = []const u8;

/// A string object with escapes resolved. PDF strings are byte strings, not
/// text: the encoding depends on where the string was found.
pub const String = []const u8;

pub const Array = []const Object;

/// Insertion-ordered so that `fenrir dump` reproduces source order, which
/// makes diffing our output against `qpdf --qdf` practical.
pub const Dict = std.StringArrayHashMapUnmanaged(Object);

/// A reference to an indirect object: `12 0 R`.
pub const Ref = struct {
    num: u32,
    gen: u16,

    pub fn format(r: Ref, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} {d} R", .{ r.num, r.gen });
    }
};

/// A stream is a dictionary plus raw, still-encoded bytes. Decoding happens on
/// demand in `Document.streamData`, because it needs the document to resolve
/// indirect `/Filter` and `/DecodeParms` values.
pub const Stream = struct {
    dict: Dict,
    /// Bytes between `stream` and `endstream`, before any filter is applied.
    raw: []const u8,
};

const min_i64_f: f64 = @floatFromInt(std.math.minInt(i64));
const max_i64_f: f64 = @floatFromInt(std.math.maxInt(i64));

pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    string: String,
    name: Name,
    array: Array,
    dict: Dict,
    /// Arena-allocated: `Stream` is too large to store inline in the union.
    stream: *const Stream,
    ref: Ref,

    pub const null_object: Object = .null;

    /// The dictionary of a dict object *or* of a stream object. Most spec
    /// lookups ("the page's /Resources") do not care which one they got.
    pub fn asDict(o: Object) ?Dict {
        return switch (o) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }

    pub fn asArray(o: Object) ?Array {
        return switch (o) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asName(o: Object) ?Name {
        return switch (o) {
            .name => |n| n,
            else => null,
        };
    }

    pub fn asString(o: Object) ?String {
        return switch (o) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asStream(o: Object) ?*const Stream {
        return switch (o) {
            .stream => |s| s,
            else => null,
        };
    }

    pub fn asRef(o: Object) ?Ref {
        return switch (o) {
            .ref => |r| r,
            else => null,
        };
    }

    /// Integers and reals are interchangeable in most of the spec ("numbers"),
    /// so callers that want a count or an offset accept both.
    pub fn asInt(o: Object) ?i64 {
        return switch (o) {
            .integer => |i| i,
            .real => |r| blk: {
                // `@intFromFloat` traps on non-integral or out-of-range input,
                // and PDF files are full of both.
                if (!std.math.isFinite(r) or r != @trunc(r)) break :blk null;
                if (r < min_i64_f or r > max_i64_f) break :blk null;
                break :blk @as(i64, @intFromFloat(r));
            },
            else => null,
        };
    }

    pub fn asNumber(o: Object) ?f64 {
        return switch (o) {
            .integer => |i| @floatFromInt(i),
            .real => |r| r,
            else => null,
        };
    }

    pub fn asBool(o: Object) ?bool {
        return switch (o) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn isNull(o: Object) bool {
        return o == .null;
    }

    /// True if this is the name `/want`. Reads better than the `asName` dance
    /// at call sites that just want to test `/Type`.
    pub fn isName(o: Object, want: []const u8) bool {
        return switch (o) {
            .name => |n| std.mem.eql(u8, n, want),
            else => false,
        };
    }

    /// Direct lookup: no indirect references are followed, so a `12 0 R` value
    /// comes back as `.ref`. Use `Document.get` when you want resolution.
    pub fn find(o: Object, key: []const u8) ?Object {
        const d = o.asDict() orelse return null;
        return d.get(key);
    }

    /// Short human-readable tag, used by `fenrir objects`.
    pub fn typeName(o: Object) []const u8 {
        return switch (o) {
            .null => "null",
            .boolean => "boolean",
            .integer => "integer",
            .real => "real",
            .string => "string",
            .name => "name",
            .array => "array",
            .dict => "dict",
            .stream => "stream",
            .ref => "ref",
        };
    }
};

/// Builds a `Dict` in arena memory. Only the writer path and object-stream
/// assembly need this; parsing builds dictionaries directly.
pub fn dictPut(dict: *Dict, arena: Allocator, key: []const u8, value: Object) Allocator.Error!void {
    try dict.put(arena, key, value);
}

test "accessors do not lie about their tag" {
    const int: Object = .{ .integer = 42 };
    try std.testing.expectEqual(@as(?i64, 42), int.asInt());
    try std.testing.expectEqual(@as(?f64, 42.0), int.asNumber());
    try std.testing.expectEqual(@as(?Name, null), int.asName());

    const name: Object = .{ .name = "Page" };
    try std.testing.expect(name.isName("Page"));
    try std.testing.expect(!name.isName("Pages"));
}

test "reals that are exactly integral convert" {
    const whole: Object = .{ .real = 7.0 };
    try std.testing.expectEqual(@as(?i64, 7), whole.asInt());

    const fractional: Object = .{ .real = 7.5 };
    try std.testing.expectEqual(@as(?i64, null), fractional.asInt());
}
