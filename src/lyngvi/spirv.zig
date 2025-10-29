//! Just enough of the SPIR-V binary format to check a module before it is
//! handed to a driver.
//!
//! This is not a validator and does not try to be one -- `spirv-val` exists,
//! it is thorough, and it belongs in a build step rather than in a renderer.
//! What this catches is the small set of mistakes that a *build* can make and
//! a driver reports as either nothing at all or an abort inside its own
//! compiler:
//!
//! * A file that is not SPIR-V. An empty `.spv` from a shader compiler that
//!   failed and still exited zero, a text file, a truncated download.
//! * A module byte-swapped by having been produced on a big-endian host.
//! * The vertex module passed to the fragment stage, or the wrong entry point
//!   name. Both produce a pipeline that creates successfully and draws
//!   nothing, which is the single most expensive class of bug in a renderer
//!   because there is no error to search for.
//! * A module that needs `runtimeDescriptorArray` on a device that has not
//!   enabled it. The capability is declared in the module itself, so this can
//!   be checked against what the device advertises *before* creating the
//!   pipeline, and the fallback path chosen deliberately instead of by
//!   crashing.
//!
//! The format is trivial to walk: a five-word header, then a stream of
//! instructions, each of whose first word is `(word_count << 16) | opcode`.
//! Nothing here decodes an instruction it does not care about; it reads the
//! length and skips.

const std = @import("std");

pub const magic: u32 = 0x0723_0203;
pub const header_words = 5;

pub const Error = error{
    NotSpirV,
    /// The right words in the wrong byte order. Swapping them is possible and
    /// deliberately not done: it would mean copying every module at startup to
    /// support a host nobody is running this on.
    WrongEndian,
    Truncated,
    /// An instruction claiming a length of zero, which would make the walk
    /// loop forever.
    MalformedInstruction,
};

pub const ExecutionModel = enum(u32) {
    vertex = 0,
    tessellation_control = 1,
    tessellation_evaluation = 2,
    geometry = 3,
    fragment = 4,
    gl_compute = 5,
    kernel = 6,
    _,
};

pub const Capability = enum(u32) {
    matrix = 0,
    shader = 1,
    geometry = 2,
    tessellation = 3,
    float64 = 10,
    int64 = 11,
    image_query = 50,
    derivative_control = 51,
    storage_image_extended_formats = 49,
    shader_non_uniform = 5301,
    runtime_descriptor_array = 5302,
    uniform_buffer_array_non_uniform_indexing = 5306,
    sampled_image_array_non_uniform_indexing = 5307,
    storage_buffer_array_non_uniform_indexing = 5308,
    storage_image_array_non_uniform_indexing = 5309,
    _,
};

const op_capability: u16 = 17;
const op_entry_point: u16 = 15;
const op_function: u16 = 54;

/// A parsed module. Borrows the words; nothing is copied.
pub const Module = struct {
    words: []const u32,

    pub fn version(m: Module) u32 {
        return m.words[1];
    }

    /// Which tool produced it, in the top half. 8 is glslang, 13 is shaderc
    /// (`glslc`), 6 is Khronos' own assembler. Printed in `fenrir view
    /// --probe` because "the module was built by a compiler nobody remembers
    /// installing" is a real explanation for a real bug.
    pub fn generator(m: Module) u32 {
        return m.words[2] >> 16;
    }

    pub fn versionMajor(m: Module) u32 {
        return (m.version() >> 16) & 0xff;
    }

    pub fn versionMinor(m: Module) u32 {
        return (m.version() >> 8) & 0xff;
    }

    /// The `<id>` bound: every identifier in the module is below it, so it is
    /// a fair proxy for size when comparing two builds of the same shader.
    pub fn bound(m: Module) u32 {
        return m.words[3];
    }

    /// The 4-byte-aligned pointer `vkCreateShaderModule` wants, and the byte
    /// count it wants alongside it.
    pub fn code(m: Module) []const u32 {
        return m.words;
    }

    pub fn byteSize(m: Module) usize {
        return m.words.len * @sizeOf(u32);
    }

    pub const Instructions = struct {
        words: []const u32,
        at: usize,

        pub const Instruction = struct {
            opcode: u16,
            /// The instruction's operands: everything after the length word.
            operands: []const u32,
        };

        pub fn next(it: *Instructions) Error!?Instruction {
            if (it.at >= it.words.len) return null;
            const head = it.words[it.at];
            const count = head >> 16;
            if (count == 0) return error.MalformedInstruction;
            if (it.at + count > it.words.len) return error.Truncated;
            const ins: Instruction = .{
                .opcode = @truncate(head & 0xffff),
                .operands = it.words[it.at + 1 ..][0 .. count - 1],
            };
            it.at += count;
            return ins;
        }
    };

    pub fn instructions(m: Module) Instructions {
        return .{ .words = m.words, .at = header_words };
    }

    pub const EntryPoint = struct {
        model: ExecutionModel,
        name: []const u8,
    };

    /// Walks to the first entry point, or to a named one.
    ///
    /// Entry points appear before any function in a well-formed module, so the
    /// walk stops at the first `OpFunction` rather than reading a megabyte of
    /// instructions to find nothing.
    pub fn entryPoint(m: Module, want: ?[]const u8) Error!?EntryPoint {
        var it = m.instructions();
        while (try it.next()) |ins| {
            if (ins.opcode == op_function) return null;
            if (ins.opcode != op_entry_point) continue;
            if (ins.operands.len < 3) return error.MalformedInstruction;
            const name = literalString(ins.operands[2..]);
            if (want) |w| if (!std.mem.eql(u8, w, name)) continue;
            return .{ .model = @enumFromInt(ins.operands[0]), .name = name };
        }
        return null;
    }

    pub fn declares(m: Module, cap: Capability) Error!bool {
        var it = m.instructions();
        while (try it.next()) |ins| {
            // Capabilities come first in a module, so anything else that is
            // not a capability means there are no more.
            if (ins.opcode == op_function) break;
            if (ins.opcode != op_capability) continue;
            if (ins.operands.len < 1) return error.MalformedInstruction;
            if (@as(Capability, @enumFromInt(ins.operands[0])) == cap) return true;
        }
        return false;
    }

    /// True when this module indexes a descriptor array with a value the
    /// compiler could not prove uniform -- which is what `nonuniformEXT` in
    /// the fragment shader compiles to, and what the device has to have
    /// enabled for the single-draw-call path to be legal.
    pub fn needsNonUniformIndexing(m: Module) Error!bool {
        return try m.declares(.sampled_image_array_non_uniform_indexing) or
            try m.declares(.shader_non_uniform) or
            try m.declares(.runtime_descriptor_array);
    }

    /// The check worth making at pipeline creation: this module really is for
    /// this stage, and its entry point really is called `main`.
    pub fn isStage(m: Module, model: ExecutionModel) bool {
        const e = (m.entryPoint(null) catch return false) orelse return false;
        return e.model == model;
    }
};

/// A SPIR-V literal string: UTF-8, NUL-terminated, padded to a word boundary.
fn literalString(words: []const u32) []const u8 {
    const bytes = std.mem.sliceAsBytes(words);
    return std.mem.sliceTo(bytes, 0);
}

/// Parses a module out of bytes that are already 4-byte aligned.
///
/// The alignment is in the type rather than checked at run time because it has
/// to hold anyway: `vkCreateShaderModule` takes a `const uint32_t*` and
/// dereferences it. `@embedFile` produces a byte array with no alignment
/// guarantee, so the blobs in `shaders.zig` are declared `align(4)`, and this
/// signature is what makes forgetting that a compile error.
pub fn parse(bytes: []align(@alignOf(u32)) const u8) Error!Module {
    if (bytes.len < header_words * @sizeOf(u32)) return error.NotSpirV;
    if (bytes.len % @sizeOf(u32) != 0) return error.NotSpirV;

    const words = std.mem.bytesAsSlice(u32, bytes);
    if (words[0] != magic) {
        return if (@byteSwap(words[0]) == magic) error.WrongEndian else error.NotSpirV;
    }
    // A bound of zero means no identifiers, which no real module has and an
    // empty file zero-filled to header size does.
    if (words[3] == 0) return error.NotSpirV;
    return .{ .words = words };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Builds a tiny but structurally real module: header, a capability, an entry
/// point with a name, and a function to stop the walk.
fn build(
    comptime model: ExecutionModel,
    comptime name: []const u8,
    comptime caps: []const Capability,
) []align(4) const u8 {
    const holder = struct {
        const words: []const u32 = blk: {
            var w: []const u32 = &.{ magic, 0x0001_0300, 8 << 16, 12, 0 };
            for (caps) |c| {
                w = w ++ [_]u32{ (2 << 16) | @as(u32, op_capability), @intFromEnum(c) };
            }

            // The name: NUL-terminated, then padded out to a word boundary.
            const padded = name.len + 1 + (4 - (name.len + 1) % 4) % 4;
            var chars: [padded]u8 = @splat(0);
            for (name, 0..) |c, i| chars[i] = c;
            var name_words: [padded / 4]u32 = @splat(0);
            for (&name_words, 0..) |*word, i| {
                word.* = @as(u32, chars[i * 4]) |
                    (@as(u32, chars[i * 4 + 1]) << 8) |
                    (@as(u32, chars[i * 4 + 2]) << 16) |
                    (@as(u32, chars[i * 4 + 3]) << 24);
            }

            const entry_len: u32 = 3 + name_words.len;
            w = w ++ [_]u32{
                (entry_len << 16) | @as(u32, op_entry_point),
                @intFromEnum(model),
                4,
            } ++ name_words;
            // A function, so that the walk has something to stop at.
            w = w ++ [_]u32{ (5 << 16) | @as(u32, op_function), 1, 4, 0, 2 };
            break :blk w;
        };

        // `@bitCast` rather than `sliceAsBytes`, and a container-level
        // constant rather than a local: a pointer returned from comptime has
        // to point at something with a static lifetime.
        const bytes: [words.len * 4]u8 align(4) = @bitCast(words[0..words.len].*);
    };
    return &holder.bytes;
}

test "a real header parses and reports its version" {
    const m = try parse(build(.fragment, "main", &.{.shader}));
    try testing.expectEqual(@as(u32, 1), m.versionMajor());
    try testing.expectEqual(@as(u32, 3), m.versionMinor());
    try testing.expectEqual(@as(u32, 12), m.bound());
    try testing.expectEqual(@as(u32, 8), m.generator());
}

test "the entry point names its stage, which is the check worth making" {
    // Passing the vertex module to the fragment stage creates a pipeline that
    // draws nothing, with no error anywhere.
    const frag = try parse(build(.fragment, "main", &.{.shader}));
    try testing.expect(frag.isStage(.fragment));
    try testing.expect(!frag.isStage(.vertex));

    const e = (try frag.entryPoint(null)).?;
    try testing.expectEqualStrings("main", e.name);
    try testing.expectEqual(ExecutionModel.fragment, e.model);
}

test "an entry point can be looked up by name" {
    const m = try parse(build(.vertex, "vs_main", &.{.shader}));
    try testing.expect((try m.entryPoint("vs_main")) != null);
    try testing.expectEqual(@as(?Module.EntryPoint, null), try m.entryPoint("main"));
}

test "a name whose length is a multiple of four still terminates" {
    // The padding rule's edge: "abcd" needs a whole extra word for its NUL.
    const m = try parse(build(.vertex, "abcd", &.{.shader}));
    try testing.expectEqualStrings("abcd", (try m.entryPoint(null)).?.name);
}

test "the descriptor indexing capability is visible without a device" {
    const plain = try parse(build(.fragment, "main", &.{.shader}));
    try testing.expect(!try plain.needsNonUniformIndexing());

    const indexed = try parse(build(.fragment, "main", &.{
        .shader,
        .shader_non_uniform,
        .sampled_image_array_non_uniform_indexing,
        .runtime_descriptor_array,
    }));
    try testing.expect(try indexed.needsNonUniformIndexing());
    try testing.expect(try indexed.declares(.runtime_descriptor_array));
    try testing.expect(!try indexed.declares(.float64));
}

test "the failures a build can produce are named rather than crashed on" {
    // An empty file from a compiler that failed and exited zero.
    const empty: [0]u8 align(4) = undefined;
    try testing.expectError(error.NotSpirV, parse(&empty));

    // A header-sized file of zeroes: has the length, has no magic.
    const zeroes: [20]u8 align(4) = @splat(0);
    try testing.expectError(error.NotSpirV, parse(&zeroes));

    // Text, which is what a shader compiler writes when asked for assembly.
    const text: [20]u8 align(4) = "; SPIR-V\n; Version 1".*;
    try testing.expectError(error.NotSpirV, parse(&text));

    // Right words, wrong byte order.
    const swapped: [5]u32 align(4) = .{ @byteSwap(magic), 0, 0, 1, 0 };
    try testing.expectError(error.WrongEndian, parse(std.mem.sliceAsBytes(&swapped)));

    // Not a whole number of words.
    const ragged: [21]u8 align(4) = @splat(1);
    try testing.expectError(error.NotSpirV, parse(&ragged));
}

test "a truncated instruction stops the walk instead of reading past the end" {
    // The last instruction claims ten words and only two are present.
    const words: [7]u32 align(4) = .{ magic, 0x0001_0300, 0, 12, 0, (10 << 16) | @as(u32, op_capability), 1 };
    const m = try parse(std.mem.sliceAsBytes(&words));
    try testing.expectError(error.Truncated, m.declares(.shader));
}

test "a zero-length instruction is refused rather than looped on" {
    const words: [7]u32 align(4) = .{ magic, 0x0001_0300, 0, 12, 0, 0, 0 };
    const m = try parse(std.mem.sliceAsBytes(&words));
    try testing.expectError(error.MalformedInstruction, m.declares(.shader));
}
