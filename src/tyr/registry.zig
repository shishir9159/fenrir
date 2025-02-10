//! The one place in Týr that knows which backends exist.
//!
//! The split this file exists to draw: *which* backends are in the binary is a
//! build-time fact, because you cannot dispatch to a library you did not link;
//! *which one opens a given font* is a runtime decision, made from the font's
//! own bytes and a string the user can pass on the command line. Everything
//! above this file sees only the runtime half.
//!
//! So there is exactly one `comptime` conditional in the font layer, and it is
//! the `compiled` block below. No call site anywhere else branches on which
//! backend was built. Adding a fourth backend is a new file and two lines
//! here, and touches nothing that consumes a `Face`.
//!
//! The alternative designs and why they lost:
//!
//! *Comptime dispatch* -- a `Face` that is a concrete type chosen by build
//! flag -- costs nothing at runtime and makes the interesting test impossible.
//! Rendering the same page through FreeType and through the native parser and
//! diffing the two requires both in one process at one call site. That test is
//! the main reason to have more than one backend at all, so a design that
//! forbids it is not cheaper, it is broken.
//!
//! *`std.DynLib` at startup* -- no build flags, one binary, FreeType used if
//! the system has it -- is genuinely attractive and stays possible later,
//! since it only changes the body of `open` on one backend. It is not the
//! default because it means hand-writing the symbol table with no compiler
//! checking the C ABI, and because it cannot work for stb_truetype, which is a
//! header rather than a library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("build_options");

const Face = @import("Face.zig");
const fallback = @import("backend/fallback.zig");
const format = @import("format.zig");
const Shaper = @import("Shaper.zig");

const Backend = Face.Backend;
const log = std.log.scoped(.tyr);

/// Every backend in this binary, in preference order. The fallback is last so
/// that it is reached only after everything else has declined.
pub const compiled: []const *const Backend = blk: {
    var list: []const *const Backend = &.{};
    if (options.tyr_freetype) {
        list = list ++ [_]*const Backend{&@import("backend/freetype.zig").backend};
    }
    if (options.tyr_stb_truetype) {
        list = list ++ [_]*const Backend{&@import("backend/stb.zig").backend};
    }
    list = list ++ [_]*const Backend{&fallback.backend};
    break :blk list;
};

/// True when the only thing in the binary is the box-drawing stand-in, so a
/// caller can say so once rather than letting a user wonder why every page of
/// text is rectangles.
pub const glyphs_are_real = compiled.len > 1;

pub const Options = struct {
    /// A backend name to try first, from `--font-backend=` or the build's
    /// default. Unknown names are reported and ignored rather than fatal: a
    /// stale script should not stop a document opening.
    prefer: ?[]const u8 = if (options.tyr_default.len == 0) null else options.tyr_default,
    /// What the font descriptor claimed, when the bytes are unidentifiable.
    declared: format.Format = .unknown,
    /// Face index inside a `ttcf` collection.
    index: u32 = 0,
};

pub fn find(name: []const u8) ?*const Backend {
    return findIn(compiled, name);
}

fn findIn(list: []const *const Backend, name: []const u8) ?*const Backend {
    for (list) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Opens a font program with the best available backend.
///
/// The order is: the preferred backend if it was named and can handle this
/// format, then the rest in registration order, then the fallback. A backend
/// that accepts the format but fails on the bytes does not end the search --
/// subsetted fonts are damaged often enough that a second opinion is worth
/// having, and the fallback at the end means this cannot return an error for
/// any reason except running out of memory.
pub fn open(gpa: Allocator, bytes: []const u8, opts: Options) Face.Error!Face {
    return openWith(gpa, compiled, bytes, opts);
}

/// `open` against an explicit backend list.
///
/// It exists because `compiled` has one entry in any build without C
/// dependencies, which is every build this can be tested in: the ordering, the
/// capability filter and the fall-through are the parts most likely to be
/// wrong and would otherwise never run against a list with two things in it.
/// Tests below pass synthetic backends through here.
pub fn openWith(
    gpa: Allocator,
    list: []const *const Backend,
    bytes: []const u8,
    opts: Options,
) Face.Error!Face {
    const fmt = format.resolve(bytes, opts.declared);

    if (opts.prefer) |name| {
        if (findIn(list, name)) |b| {
            if (b.canOpen(fmt)) {
                if (tryOpen(gpa, b, bytes, opts.index, fmt)) |face| return face else |_| {}
            } else {
                log.debug("backend '{s}' cannot open {s}", .{ name, fmt.label() });
            }
        } else {
            // Debug, not warn: this is library code, and a typo in
            // `--font-backend` is the CLI's to report -- it can check the name
            // against `find` once at startup instead of once per font.
            log.debug("unknown font backend '{s}'; using the default order", .{name});
        }
    }

    for (list) |b| {
        if (opts.prefer != null and std.mem.eql(u8, b.name, opts.prefer.?)) continue;
        if (!b.canOpen(fmt)) continue;
        if (tryOpen(gpa, b, bytes, opts.index, fmt)) |face| return face else |_| {}
    }

    // Unreachable in practice: the fallback claims every format and never
    // fails. Kept as a real branch rather than an assertion because a future
    // backend list could be edited into one where it is not last.
    return fallback.backend.open(gpa, bytes, opts.index);
}

fn tryOpen(
    gpa: Allocator,
    b: *const Backend,
    bytes: []const u8,
    index: u32,
    fmt: format.Format,
) Face.Error!Face {
    return b.open(gpa, bytes, index) catch |err| {
        // OOM is not a reason to consult a different backend.
        if (err == error.OutOfMemory) return err;
        log.debug("backend '{s}' declined {s}: {t}", .{ b.name, fmt.label(), err });
        return err;
    };
}

/// One line per compiled-in backend, for `fenrir fonts` and for the header of
/// a rendering trace -- a diff between two runs should say which backend
/// produced each side.
pub fn describe(w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (compiled) |b| {
        try w.print("{s:<10}", .{b.name});
        const c = b.caps;
        inline for (.{
            .{ c.truetype, "truetype" },
            .{ c.cff, "cff" },
            .{ c.type1, "type1" },
            .{ c.glyph_names, "names" },
            .{ c.cmap, "cmap" },
            .{ c.hinting, "hinting" },
        }) |pair| {
            if (pair[0]) try w.print(" {s}", .{pair[1]});
        }
        try w.writeByte('\n');
    }
}

/// The shaper for text Fenrir composes itself. Never used for page content:
/// see the note at the top of `Shaper.zig`.
///
/// Always succeeds -- a build without HarfBuzz gets the built-in shaper, which
/// is correct for the Latin the UI is written in. Callers may `deinit` the
/// result unconditionally; the built-in one has a no-op destructor.
pub fn shaper(gpa: Allocator) Shaper.Error!Shaper {
    if (options.tyr_harfbuzz) return @import("backend/harfbuzz.zig").create(gpa);
    return Shaper.simple;
}

pub const shaping_is_complex = options.tyr_harfbuzz;

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "the fallback is always present and always last" {
    try testing.expect(compiled.len >= 1);
    try testing.expectEqualStrings("fallback", compiled[compiled.len - 1].name);
    try testing.expect(find("fallback") != null);
    try testing.expect(find("nonesuch") == null);
}

test "opening always yields a face, whatever the bytes are" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "", "not a font at all", &.{ 0, 1, 0, 0 }, &.{ 1, 0, 4, 2 } }) |bytes| {
        var face = try open(gpa, bytes, .{});
        defer face.deinit(gpa);
        try testing.expect(face.info.units_per_em > 0);
    }
}

test "an unknown preferred backend is ignored, not fatal" {
    const gpa = testing.allocator;
    var face = try open(gpa, &.{ 0, 1, 0, 0 }, .{ .prefer = "harfbuzz" });
    defer face.deinit(gpa);
    // Named a shaper where a glyph source belongs, which is the mistake this
    // guards against; the document still opens.
    try testing.expect(face.backend.len > 0);
}

test "a named backend is honoured when it can take the format" {
    const gpa = testing.allocator;
    var face = try open(gpa, &.{ 1, 0, 4, 2 }, .{ .prefer = "fallback" });
    defer face.deinit(gpa);
    try testing.expectEqualStrings("fallback", face.backend);
    try testing.expectEqual(format.Format.cff, face.info.format);
}

// Synthetic backends, so the selection logic is exercised against a list with
// more than one thing in it. They borrow the fallback's state and destructor
// and only restamp the name, which is all these tests read.
fn Fake(comptime tag: []const u8, comptime fails: bool) type {
    return struct {
        fn open(gpa: Allocator, bytes: []const u8, index: u32) Face.Error!Face {
            if (fails) return error.CorruptFont;
            var f = try fallback.backend.open(gpa, bytes, index);
            f.backend = tag;
            return f;
        }
    };
}

const tt_only: Backend = .{
    .name = "tt",
    .caps = .{ .truetype = true },
    .open = Fake("tt", false).open,
};
const cff_only: Backend = .{
    .name = "cff",
    .caps = .{ .cff = true },
    .open = Fake("cff", false).open,
};
const broken: Backend = .{
    .name = "broken",
    .caps = .{ .truetype = true, .cff = true },
    .open = Fake("broken", true).open,
};

const truetype_bytes = [_]u8{ 0, 1, 0, 0 };
const cff_bytes = [_]u8{ 1, 0, 4, 2 };

fn openedBy(list: []const *const Backend, bytes: []const u8, opts: Options) ![]const u8 {
    var face = try openWith(testing.allocator, list, bytes, opts);
    defer face.deinit(testing.allocator);
    return face.backend;
}

test "the format picks the backend, not the order" {
    const list = &[_]*const Backend{ &tt_only, &cff_only, &fallback.backend };
    // This is the case that matters in practice: most subsetted PDF fonts are
    // bare CFF, and a TrueType-only backend must not be handed one.
    try testing.expectEqualStrings("tt", try openedBy(list, &truetype_bytes, .{}));
    try testing.expectEqualStrings("cff", try openedBy(list, &cff_bytes, .{}));
}

test "a backend that accepts the format but fails does not end the search" {
    const list = &[_]*const Backend{ &broken, &tt_only, &fallback.backend };
    try testing.expectEqualStrings("tt", try openedBy(list, &truetype_bytes, .{}));
}

test "a preference is overridden by capability, never the other way round" {
    const list = &[_]*const Backend{ &tt_only, &cff_only, &fallback.backend };
    // Asking for the CFF backend on a TrueType font is a request that cannot
    // be honoured; the font opens anyway.
    try testing.expectEqualStrings("tt", try openedBy(list, &truetype_bytes, .{ .prefer = "cff" }));
    // And when it can be honoured, it jumps the queue.
    try testing.expectEqualStrings("cff", try openedBy(list, &cff_bytes, .{ .prefer = "cff" }));
}

test "a preferred backend is not retried after it fails" {
    const list = &[_]*const Backend{ &broken, &tt_only, &fallback.backend };
    try testing.expectEqualStrings("tt", try openedBy(list, &truetype_bytes, .{ .prefer = "broken" }));
}

test "the last resort holds when every backend declines" {
    // A list with no fallback in it at all: the tail of `openWith` is what
    // keeps this from returning an error.
    const list = &[_]*const Backend{&broken};
    try testing.expectEqualStrings("fallback", try openedBy(list, &truetype_bytes, .{}));
}

test "describe lists the compiled-in backends" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try describe(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "fallback") != null);
    try testing.expectEqual(compiled.len, std.mem.count(u8, out, "\n"));
}
