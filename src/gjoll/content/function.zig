//! PDF functions (§7.10).
//!
//! A function is the spec's answer to "this value depends on that one" and it
//! turns up in three places the interpreter cannot avoid: the tint transform
//! of a `/Separation` or `/DeviceN` colour space, the colour ramp of a
//! shading, and the transfer functions of an `/ExtGState`. Without one, a
//! spot-colour fill has no colour at all -- and spot colours are how every
//! printed document specifies its brand ink.
//!
//! Four types exist and all four are here:
//!
//! - **0, sampled.** A lookup table, multilinearly interpolated. The general
//!   case is `2^m` corners for `m` inputs; the case that actually occurs is
//!   `m == 1`, and the code takes that path without a special case because
//!   `2^1` is two.
//! - **2, exponential.** Two colours and an exponent. The whole thing is one
//!   line, and it is the most common function in existence.
//! - **3, stitching.** A list of sub-functions over adjacent intervals.
//! - **4, PostScript calculator.** A real, if very small, PostScript: 41
//!   operators, a hundred-deep stack, and `if`/`ifelse`. Producers emit these
//!   constantly for spot colours, and a reader that skips type 4 renders every
//!   one of them as a guess.
//!
//! Evaluation never fails. A function that cannot be loaded is null; a
//! function that *is* loaded always produces numbers, because the alternative
//! -- propagating an error out of the middle of a fill -- means a page with
//! one bad shading renders as nothing at all.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("../Document.zig");
const object = @import("../object.zig");
const Object = object.Object;

/// The spec's own limits (§7.10.1, §7.10.5). Both are generous for real files
/// and tight enough that a hostile one cannot allocate its way out.
pub const max_inputs = 8;
pub const max_outputs = 32;
const max_stack = 100;
const max_nodes = 8192;
const max_block_depth = 32;

pub const Error = Document.Error;

pub const Kind = enum { sampled, exponential, stitching, postscript };

pub const Function = struct {
    kind: Kind,
    /// `2*m` numbers: the clamp applied to every input before anything else.
    domain: []const f64,
    /// `2*n` numbers, or empty. Required for types 0 and 4, optional
    /// elsewhere; when present it clamps the output.
    range: []const f64 = &.{},
    inputs: u8,
    outputs: u8,
    body: Body,

    pub const Body = union(Kind) {
        sampled: Sampled,
        exponential: Exponential,
        stitching: Stitching,
        postscript: []const Node,
    };

    /// Evaluates into `out`, which must hold at least `outputs` values.
    /// Returns the slice actually written.
    pub fn eval(f: *const Function, in: []const f64, out: []f64) []const f64 {
        var clamped: [max_inputs]f64 = undefined;
        const m = @min(@as(usize, f.inputs), @min(in.len, max_inputs));
        for (0..m) |i| clamped[i] = clampTo(in[i], f.domain, i);
        // A caller that supplied too few inputs gets the domain minimum for
        // the rest, which is what a missing operand means everywhere else.
        for (m..f.inputs) |i| clamped[i] = if (f.domain.len > 2 * i) f.domain[2 * i] else 0;

        const n = @min(@as(usize, f.outputs), out.len);
        const args = clamped[0..@min(@as(usize, f.inputs), max_inputs)];

        switch (f.body) {
            .sampled => |s| s.eval(f, args, out[0..n]),
            .exponential => |e| e.eval(args, out[0..n]),
            .stitching => |s| s.eval(f, args, out[0..n]),
            .postscript => |program| evalPostScript(program, args, out[0..n]),
        }

        if (f.range.len != 0) {
            for (out[0..n], 0..) |*v, i| v.* = clampTo(v.*, f.range, i);
        } else {
            for (out[0..n]) |*v| {
                if (!std.math.isFinite(v.*)) v.* = 0;
            }
        }
        return out[0..n];
    }

    /// The single-output convenience the colour code wants.
    pub fn evalOne(f: *const Function, x: f64) f64 {
        var out: [max_outputs]f64 = undefined;
        const got = f.eval(&.{x}, &out);
        return if (got.len == 0) 0 else got[0];
    }
};

fn clampTo(v: f64, bounds: []const f64, i: usize) f64 {
    if (!std.math.isFinite(v)) return if (bounds.len > 2 * i) bounds[2 * i] else 0;
    if (bounds.len < 2 * i + 2) return v;
    const lo = @min(bounds[2 * i], bounds[2 * i + 1]);
    const hi = @max(bounds[2 * i], bounds[2 * i + 1]);
    return std.math.clamp(v, lo, hi);
}

/// The spec's `Interpolate` (§7.10.2), which is a line through two points and
/// appears in every function type.
fn interpolate(x: f64, x0: f64, x1: f64, y0: f64, y1: f64) f64 {
    if (x1 == x0) return y0;
    return y0 + (x - x0) * (y1 - y0) / (x1 - x0);
}

// -- type 0: sampled --------------------------------------------------------

pub const Sampled = struct {
    /// Raw sample bytes, big-endian, packed at `bits` per sample.
    samples: []const u8,
    size: []const u32,
    bits: u8,
    encode: []const f64,
    decode: []const f64,

    fn sample(s: Sampled, index: usize, output: usize, outputs: usize) f64 {
        const max: f64 = @floatFromInt((@as(u64, 1) << @intCast(s.bits)) - 1);
        const bit = (index * outputs + output) * s.bits;
        const raw = readBits(s.samples, bit, s.bits);
        return @as(f64, @floatFromInt(raw)) / max;
    }

    fn eval(s: Sampled, f: *const Function, in: []const f64, out: []f64) void {
        const m = @min(in.len, s.size.len);
        if (m == 0 or out.len == 0) {
            @memset(out, 0);
            return;
        }

        // Map each input into sample space, and split into the integer corner
        // and the fraction between it and the next.
        var base: [max_inputs]usize = undefined;
        var frac: [max_inputs]f64 = undefined;
        var strides: [max_inputs]usize = undefined;
        var stride: usize = 1;
        for (0..m) |i| {
            const d0 = f.domain[2 * i];
            const d1 = f.domain[2 * i + 1];
            const e0 = if (s.encode.len > 2 * i) s.encode[2 * i] else 0;
            const e1 = if (s.encode.len > 2 * i + 1) s.encode[2 * i + 1] else @as(f64, @floatFromInt(s.size[i] - 1));
            var e = interpolate(in[i], d0, d1, e0, e1);
            e = std.math.clamp(e, 0, @as(f64, @floatFromInt(s.size[i] - 1)));
            const floor = @floor(e);
            base[i] = @intFromFloat(floor);
            frac[i] = e - floor;
            strides[i] = stride;
            stride *= s.size[i];
        }

        // Multilinear interpolation: every corner of the m-cube, weighted by
        // the product of the fractions that select it. For m == 1 this is the
        // two-point lerp everybody actually writes, arrived at by the same
        // arithmetic.
        const corners = @as(usize, 1) << @intCast(m);
        const max_sample = @as(u64, 1) << @intCast(s.bits);
        _ = max_sample;
        for (out, 0..) |*o, j| {
            var acc: f64 = 0;
            for (0..corners) |corner| {
                var weight: f64 = 1;
                var index: usize = 0;
                for (0..m) |i| {
                    const up = (corner >> @intCast(i)) & 1 == 1;
                    const at = if (up) @min(base[i] + 1, s.size[i] - 1) else base[i];
                    weight *= if (up) frac[i] else 1 - frac[i];
                    index += at * strides[i];
                }
                if (weight == 0) continue;
                acc += weight * s.sample(index, j, out.len);
            }
            const d0 = if (s.decode.len > 2 * j) s.decode[2 * j] else 0;
            const d1 = if (s.decode.len > 2 * j + 1) s.decode[2 * j + 1] else 1;
            o.* = interpolate(acc, 0, 1, d0, d1);
        }
    }
};

/// Reads `bits` bits starting at bit offset `at`, most significant first.
/// Past the end of the buffer reads as zero, which is how a truncated sample
/// table degrades to black rather than to a crash.
fn readBits(bytes: []const u8, at: usize, bits: u8) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < bits) : (i += 1) {
        const bit = at + i;
        const byte = bit >> 3;
        const shift: u3 = @intCast(7 - (bit & 7));
        const on = byte < bytes.len and (bytes[byte] >> shift) & 1 == 1;
        value = (value << 1) | @intFromBool(on);
    }
    return value;
}

// -- type 2: exponential ----------------------------------------------------

pub const Exponential = struct {
    c0: []const f64,
    c1: []const f64,
    n: f64,

    fn eval(e: Exponential, in: []const f64, out: []f64) void {
        const x = if (in.len == 0) 0 else in[0];
        // `x^1` is the overwhelmingly common case and `pow` is not cheap.
        const t = if (e.n == 1) x else std.math.pow(f64, @max(x, 0), e.n);
        for (out, 0..) |*o, i| {
            const a = if (e.c0.len > i) e.c0[i] else 0;
            const b = if (e.c1.len > i) e.c1[i] else 1;
            o.* = a + t * (b - a);
        }
    }
};

// -- type 3: stitching ------------------------------------------------------

pub const Stitching = struct {
    functions: []const Function,
    bounds: []const f64,
    encode: []const f64,

    fn eval(s: Stitching, f: *const Function, in: []const f64, out: []f64) void {
        if (s.functions.len == 0) {
            @memset(out, 0);
            return;
        }
        const x = if (in.len == 0) 0 else in[0];
        const d0 = f.domain[0];
        const d1 = f.domain[1];

        // Which interval: the first bound greater than x, or the last.
        var k: usize = 0;
        while (k < s.bounds.len and k + 1 < s.functions.len and x >= s.bounds[k]) k += 1;

        const lo = if (k == 0) d0 else s.bounds[k - 1];
        const hi = if (k >= s.bounds.len) d1 else s.bounds[k];
        const e0 = if (s.encode.len > 2 * k) s.encode[2 * k] else 0;
        const e1 = if (s.encode.len > 2 * k + 1) s.encode[2 * k + 1] else 1;

        const mapped = interpolate(x, lo, hi, e0, e1);
        _ = s.functions[k].eval(&.{mapped}, out);
    }
};

// -- type 4: PostScript calculator ------------------------------------------

pub const Node = union(enum) {
    push: f64,
    op: Code,
    /// `{...} if` and `{...} {...} ifelse`, folded at parse time so that
    /// evaluation never has to keep procedures on a stack of its own.
    cond: struct {
        then: []const Node,
        otherwise: ?[]const Node,
    },
};

pub const Code = enum {
    abs,      add,       atan,   ceiling,  cos,       cvi,   cvr,
    div,      exp,       floor,  idiv,     ln,        log,   mod,
    mul,      neg,       round,  sin,      sqrt,      sub,   truncate,
    @"and",   bitshift,  eq,     ge,       gt,        le,    lt,
    ne,       not,       @"or",  xor,      push_true, push_false,
    copy,     dup,       exch,   index,    pop,       roll,

    fn fromName(name: []const u8) ?Code {
        const table = .{
            .{ "abs", Code.abs },         .{ "add", Code.add },
            .{ "atan", Code.atan },       .{ "ceiling", Code.ceiling },
            .{ "cos", Code.cos },         .{ "cvi", Code.cvi },
            .{ "cvr", Code.cvr },         .{ "div", Code.div },
            .{ "exp", Code.exp },         .{ "floor", Code.floor },
            .{ "idiv", Code.idiv },       .{ "ln", Code.ln },
            .{ "log", Code.log },         .{ "mod", Code.mod },
            .{ "mul", Code.mul },         .{ "neg", Code.neg },
            .{ "round", Code.round },     .{ "sin", Code.sin },
            .{ "sqrt", Code.sqrt },       .{ "sub", Code.sub },
            .{ "truncate", Code.truncate }, .{ "and", Code.@"and" },
            .{ "bitshift", Code.bitshift }, .{ "eq", Code.eq },
            .{ "ge", Code.ge },           .{ "gt", Code.gt },
            .{ "le", Code.le },           .{ "lt", Code.lt },
            .{ "ne", Code.ne },           .{ "not", Code.not },
            .{ "or", Code.@"or" },        .{ "xor", Code.xor },
            .{ "true", Code.push_true },  .{ "false", Code.push_false },
            .{ "copy", Code.copy },       .{ "dup", Code.dup },
            .{ "exch", Code.exch },       .{ "index", Code.index },
            .{ "pop", Code.pop },         .{ "roll", Code.roll },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }
};

/// Booleans live on the same stack as numbers, as `0` and `1`. PostScript
/// keeps them distinct; nothing in a calculator function can tell the
/// difference, because the only consumers are `if`, `ifelse` and the logical
/// operators, and all of them are defined on both.
const true_value: f64 = 1;
const false_value: f64 = 0;

fn evalPostScript(program: []const Node, in: []const f64, out: []f64) void {
    var stack: [max_stack]f64 = undefined;
    var top: usize = 0;
    for (in) |v| {
        if (top == max_stack) break;
        stack[top] = v;
        top += 1;
    }

    run(program, &stack, &top, 0);

    // The outputs are the top n values, bottom-most first (§7.10.5).
    const n = @min(out.len, top);
    for (0..n) |i| out[out.len - 1 - i] = stack[top - 1 - i];
    for (0..out.len - n) |i| out[i] = 0;
}

fn run(program: []const Node, stack: *[max_stack]f64, top: *usize, depth: u8) void {
    if (depth > max_block_depth) return;

    for (program) |node| switch (node) {
        .push => |v| push(stack, top, v),
        .cond => |c| {
            const condition = pop(stack, top) != 0;
            if (condition) {
                run(c.then, stack, top, depth + 1);
            } else if (c.otherwise) |branch| {
                run(branch, stack, top, depth + 1);
            }
        },
        .op => |code| apply(code, stack, top),
    };
}

fn push(stack: *[max_stack]f64, top: *usize, v: f64) void {
    // A stack overflow in a calculator function means the program is wrong.
    // Dropping the push keeps the arithmetic finite and bounded; the
    // alternative is refusing to paint anything.
    if (top.* == max_stack) return;
    stack[top.*] = v;
    top.* += 1;
}

fn pop(stack: *[max_stack]f64, top: *usize) f64 {
    if (top.* == 0) return 0;
    top.* -= 1;
    return stack[top.*];
}

fn apply(code: Code, stack: *[max_stack]f64, top: *usize) void {
    switch (code) {
        .push_true => push(stack, top, true_value),
        .push_false => push(stack, top, false_value),

        .abs => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @abs(x);
            }
        }.f),
        .neg => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return -x;
            }
        }.f),
        .sqrt => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return if (x < 0) 0 else @sqrt(x);
            }
        }.f),
        .floor => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @floor(x);
            }
        }.f),
        .ceiling => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @ceil(x);
            }
        }.f),
        .round => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @round(x);
            }
        }.f),
        .truncate, .cvi => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @trunc(x);
            }
        }.f),
        .cvr => {},
        // PostScript's sin and cos take degrees, not radians. Every reader
        // that has ever forgotten this has shipped shadings that spiral.
        .sin => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @sin(x * std.math.pi / 180.0);
            }
        }.f),
        .cos => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return @cos(x * std.math.pi / 180.0);
            }
        }.f),
        .ln => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return if (x > 0) @log(x) else 0;
            }
        }.f),
        .log => unary(stack, top, struct {
            fn f(x: f64) f64 {
                return if (x > 0) @log10(x) else 0;
            }
        }.f),
        .not => unary(stack, top, struct {
            fn f(x: f64) f64 {
                // `not` is bitwise on integers and logical on booleans; the
                // two agree on 0 and 1, which is all a colour ever holds.
                return if (x == 0) true_value else if (x == 1) false_value else @floatFromInt(~asInt(x));
            }
        }.f),

        .add => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                return a + b;
            }
        }.f),
        .sub => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                return a - b;
            }
        }.f),
        .mul => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                return a * b;
            }
        }.f),
        .div => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                return if (b == 0) 0 else a / b;
            }
        }.f),
        .idiv => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                const d = asInt(b);
                return if (d == 0) 0 else @floatFromInt(@divTrunc(asInt(a), d));
            }
        }.f),
        .mod => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                const d = asInt(b);
                return if (d == 0) 0 else @floatFromInt(@rem(asInt(a), d));
            }
        }.f),
        .exp => binary(stack, top, struct {
            fn f(a: f64, b: f64) f64 {
                const v = std.math.pow(f64, a, b);
                return if (std.math.isFinite(v)) v else 0;
            }
        }.f),
        .atan => binary(stack, top, struct {
            fn f(num: f64, den: f64) f64 {
                // Degrees, and normalised to 0..360 rather than -180..180.
                var deg = std.math.atan2(num, den) * 180.0 / std.math.pi;
                if (deg < 0) deg += 360;
                return deg;
            }
        }.f),

        .eq => compare(stack, top, struct {
            fn f(a: f64, b: f64) bool {
                return a == b;
            }
        }.f),
        .ne => compare(stack, top, struct {
            fn f(a: f64, b: f64) bool {
                return a != b;
            }
        }.f),
        .gt => compare(stack, top, struct {
            fn f(a: f64, b: f64) bool {
                return a > b;
            }
        }.f),
        .ge => compare(stack, top, struct {
            fn f(a: f64, b: f64) bool {
                return a >= b;
            }
        }.f),
        .lt => compare(stack, top, struct {
            fn f(a: f64, b: f64) bool {
                return a < b;
            }
        }.f),
        .le => compare(stack, top, struct {
            fn f(a: f64, b: f64) bool {
                return a <= b;
            }
        }.f),

        .@"and" => bitwise(stack, top, struct {
            fn f(a: i64, b: i64) i64 {
                return a & b;
            }
        }.f),
        .@"or" => bitwise(stack, top, struct {
            fn f(a: i64, b: i64) i64 {
                return a | b;
            }
        }.f),
        .xor => bitwise(stack, top, struct {
            fn f(a: i64, b: i64) i64 {
                return a ^ b;
            }
        }.f),
        .bitshift => bitwise(stack, top, struct {
            fn f(a: i64, b: i64) i64 {
                if (b >= 64 or b <= -64) return 0;
                return if (b >= 0) a << @intCast(b) else a >> @intCast(-b);
            }
        }.f),

        .pop => _ = pop(stack, top),
        .dup => {
            if (top.* == 0) return;
            push(stack, top, stack[top.* - 1]);
        },
        .exch => {
            if (top.* < 2) return;
            std.mem.swap(f64, &stack[top.* - 1], &stack[top.* - 2]);
        },
        .copy => {
            const n = asInt(pop(stack, top));
            if (n <= 0) return;
            const count: usize = @intCast(@min(n, @as(i64, max_stack)));
            if (count > top.*) return;
            const from = top.* - count;
            for (0..count) |i| push(stack, top, stack[from + i]);
        },
        .index => {
            const n = asInt(pop(stack, top));
            if (n < 0 or @as(usize, @intCast(n)) >= top.*) {
                push(stack, top, 0);
                return;
            }
            push(stack, top, stack[top.* - 1 - @as(usize, @intCast(n))]);
        },
        .roll => {
            const j = asInt(pop(stack, top));
            const n_signed = asInt(pop(stack, top));
            if (n_signed <= 0) return;
            const n: usize = @intCast(n_signed);
            if (n > top.*) return;
            const window = stack[top.* - n ..][0..n];
            // A rotation by `j`, wrapped, in either direction.
            const shift: usize = @intCast(@mod(j, @as(i64, @intCast(n))));
            if (shift == 0) return;
            var tmp: [max_stack]f64 = undefined;
            for (window, 0..) |v, i| tmp[(i + shift) % n] = v;
            @memcpy(window, tmp[0..n]);
        },
    }
}

fn asInt(v: f64) i64 {
    if (!std.math.isFinite(v)) return 0;
    const clamped = std.math.clamp(v, -9.2e18, 9.2e18);
    return @intFromFloat(@trunc(clamped));
}

fn unary(stack: *[max_stack]f64, top: *usize, comptime f: fn (f64) f64) void {
    const x = pop(stack, top);
    const v = f(x);
    push(stack, top, if (std.math.isFinite(v)) v else 0);
}

fn binary(stack: *[max_stack]f64, top: *usize, comptime f: fn (f64, f64) f64) void {
    const b = pop(stack, top);
    const a = pop(stack, top);
    const v = f(a, b);
    push(stack, top, if (std.math.isFinite(v)) v else 0);
}

fn compare(stack: *[max_stack]f64, top: *usize, comptime f: fn (f64, f64) bool) void {
    const b = pop(stack, top);
    const a = pop(stack, top);
    push(stack, top, if (f(a, b)) true_value else false_value);
}

fn bitwise(stack: *[max_stack]f64, top: *usize, comptime f: fn (i64, i64) i64) void {
    const b = pop(stack, top);
    const a = pop(stack, top);
    push(stack, top, @floatFromInt(f(asInt(a), asInt(b))));
}

// -- loading ----------------------------------------------------------------

/// Loads a function from a dictionary or stream object. Null when the object
/// is not a function, or is one this cannot make sense of; every caller has a
/// documented answer for null, because a missing tint transform is common
/// enough that erroring on it would reject real files.
pub fn load(arena: Allocator, doc: *Document, obj: Object) Error!?Function {
    const resolved = try doc.resolve(obj);
    const dict = resolved.asDict() orelse return null;

    const kind_value = (try doc.get(dict, "FunctionType") orelse return null).asInt() orelse return null;
    const domain = try numbers(arena, doc, dict, "Domain") orelse return null;
    if (domain.len < 2) return null;

    const range = try numbers(arena, doc, dict, "Range") orelse &[_]f64{};
    const inputs: u8 = @intCast(@min(domain.len / 2, max_inputs));

    switch (kind_value) {
        0 => {
            const stream = resolved.asStream() orelse return null;
            const size_values = try numbers(arena, doc, dict, "Size") orelse return null;
            if (size_values.len == 0 or range.len < 2) return null;

            const size = try arena.alloc(u32, @min(size_values.len, max_inputs));
            for (size, 0..) |*s, i| {
                const v = size_values[i];
                if (!(v >= 1) or v > 1 << 24) return null;
                s.* = @intFromFloat(v);
            }

            const bits_value = (try doc.get(dict, "BitsPerSample") orelse return null).asInt() orelse return null;
            const bits: u8 = switch (bits_value) {
                1, 2, 4, 8, 12, 16, 24, 32 => @intCast(bits_value),
                else => return null,
            };

            const data = try doc.streamData(stream);
            const outputs: u8 = @intCast(@min(range.len / 2, max_outputs));

            return .{
                .kind = .sampled,
                .domain = domain,
                .range = range,
                .inputs = @intCast(@min(size.len, inputs)),
                .outputs = outputs,
                .body = .{ .sampled = .{
                    .samples = data.data,
                    .size = size,
                    .bits = bits,
                    .encode = try numbers(arena, doc, dict, "Encode") orelse &.{},
                    .decode = try numbers(arena, doc, dict, "Decode") orelse range,
                } },
            };
        },
        2 => {
            const c0 = try numbers(arena, doc, dict, "C0") orelse try arena.dupe(f64, &.{0});
            const c1 = try numbers(arena, doc, dict, "C1") orelse try arena.dupe(f64, &.{1});
            const n = if (try doc.get(dict, "N")) |v| v.asNumber() orelse 1 else 1;
            const outputs: u8 = @intCast(@min(@max(c0.len, c1.len), max_outputs));

            return .{
                .kind = .exponential,
                .domain = domain,
                .range = range,
                .inputs = 1,
                .outputs = @max(outputs, 1),
                .body = .{ .exponential = .{ .c0 = c0, .c1 = c1, .n = n } },
            };
        },
        3 => {
            const list = (try doc.get(dict, "Functions") orelse return null).asArray() orelse return null;
            if (list.len == 0) return null;

            var subs: std.ArrayList(Function) = .empty;
            var outputs: u8 = 0;
            for (list) |entry| {
                const sub = try load(arena, doc, entry) orelse continue;
                outputs = @max(outputs, sub.outputs);
                try subs.append(arena, sub);
            }
            if (subs.items.len == 0) return null;

            return .{
                .kind = .stitching,
                .domain = domain,
                .range = range,
                .inputs = 1,
                .outputs = outputs,
                .body = .{ .stitching = .{
                    .functions = subs.items,
                    .bounds = try numbers(arena, doc, dict, "Bounds") orelse &.{},
                    .encode = try numbers(arena, doc, dict, "Encode") orelse &.{},
                } },
            };
        },
        4 => {
            const stream = resolved.asStream() orelse return null;
            if (range.len < 2) return null;
            const data = try doc.streamData(stream);
            const program = try compile(arena, data.data) orelse return null;

            return .{
                .kind = .postscript,
                .domain = domain,
                .range = range,
                .inputs = inputs,
                .outputs = @intCast(@min(range.len / 2, max_outputs)),
                .body = .{ .postscript = program },
            };
        },
        else => return null,
    }
}

/// Loads either one function of `n` outputs or an array of `n` functions of
/// one output each. Shadings and `/SMask` transfer functions are specified
/// both ways and mean the same thing (§8.7.4.5.2).
pub fn loadCombined(arena: Allocator, doc: *Document, obj: Object) Error!?[]const Function {
    const resolved = try doc.resolve(obj);
    if (resolved.asArray()) |list| {
        var out: std.ArrayList(Function) = .empty;
        for (list) |entry| {
            if (try load(arena, doc, entry)) |f| try out.append(arena, f);
        }
        return if (out.items.len == 0) null else out.items;
    }
    const single = try load(arena, doc, resolved) orelse return null;
    const one = try arena.alloc(Function, 1);
    one[0] = single;
    return one;
}

/// Evaluates a combined function list into `out`, concatenating the outputs
/// of a list of single-output functions.
pub fn evalCombined(fns: []const Function, x: f64, out: []f64) []const f64 {
    if (fns.len == 1) return fns[0].eval(&.{x}, out);

    var written: usize = 0;
    for (fns) |*f| {
        if (written == out.len) break;
        const got = f.eval(&.{x}, out[written..][0..@min(1, out.len - written)]);
        written += got.len;
    }
    return out[0..written];
}

fn numbers(arena: Allocator, doc: *Document, dict: object.Dict, key: []const u8) Error!?[]const f64 {
    const value = try doc.get(dict, key) orelse return null;
    const list = value.asArray() orelse return null;

    const out = try arena.alloc(f64, list.len);
    for (out, list) |*o, entry| {
        const resolved = try doc.resolve(entry);
        o.* = resolved.asNumber() orelse 0;
    }
    return out;
}

// -- type 4 parsing ---------------------------------------------------------

const Lexer = @import("../Lexer.zig");

/// Compiles the text of a calculator function into nodes.
///
/// `if` and `ifelse` are folded into a `cond` node at compile time, which is
/// why evaluation has no procedure stack: by the time `run` sees a branch, it
/// already knows both arms.
fn compile(arena: Allocator, src: []const u8) Allocator.Error!?[]const Node {
    var lexer: Lexer = .init(src);
    var budget: u32 = max_nodes;

    // The whole program is wrapped in one pair of braces.
    lexer.skipSpace();
    if (lexer.pos < src.len and src[lexer.pos] == '{') lexer.pos += 1;

    return compileBlock(arena, &lexer, &budget, 0) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

const CompileError = Allocator.Error || error{ TooDeep, TooLong, Malformed };

fn compileBlock(arena: Allocator, lexer: *Lexer, budget: *u32, depth: u8) CompileError![]const Node {
    if (depth > max_block_depth) return error.TooDeep;

    var out: std.ArrayList(Node) = .empty;
    // Procedures seen but not yet consumed by `if` or `ifelse`.
    var pending: [2][]const Node = undefined;
    var pending_count: usize = 0;

    while (true) {
        if (budget.* == 0) return error.TooLong;
        budget.* -= 1;

        const token = lexer.next(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A stray byte inside a calculator function is not worth
            // abandoning the whole program for.
            else => continue,
        };

        switch (token) {
            .eof, .brace_close => break,
            .brace_open => {
                const block = try compileBlock(arena, lexer, budget, depth + 1);
                if (pending_count == 2) return error.Malformed;
                pending[pending_count] = block;
                pending_count += 1;
            },
            .integer => |v| try out.append(arena, .{ .push = @floatFromInt(v) }),
            .real => |v| try out.append(arena, .{ .push = v }),
            .keyword => |word| {
                if (std.mem.eql(u8, word, "if")) {
                    if (pending_count < 1) return error.Malformed;
                    try out.append(arena, .{ .cond = .{
                        .then = pending[pending_count - 1],
                        .otherwise = null,
                    } });
                    pending_count -= 1;
                } else if (std.mem.eql(u8, word, "ifelse")) {
                    if (pending_count < 2) return error.Malformed;
                    try out.append(arena, .{ .cond = .{
                        .then = pending[0],
                        .otherwise = pending[1],
                    } });
                    pending_count = 0;
                } else if (Code.fromName(word)) |code| {
                    try out.append(arena, .{ .op = code });
                }
                // Anything else is a word this dialect does not have. Ignore
                // it: the program is still worth running.
            },
            else => {},
        }
    }
    return out.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn ps(src: []const u8, in: []const f64, outputs: u8) ![max_outputs]f64 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const program = (try compile(arena_state.allocator(), src)).?;
    var out: [max_outputs]f64 = @splat(0);
    evalPostScript(program, in, out[0..outputs]);
    return out;
}

test "an exponential function is a straight line when N is one" {
    const f: Function = .{
        .kind = .exponential,
        .domain = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 3,
        .body = .{ .exponential = .{ .c0 = &.{ 0, 0, 0 }, .c1 = &.{ 1, 0.5, 0 }, .n = 1 } },
    };
    var out: [3]f64 = undefined;
    const got = f.eval(&.{0.5}, &out);
    try testing.expectApproxEqAbs(@as(f64, 0.5), got[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), got[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), got[2], 1e-9);
}

test "the domain clamps before anything else runs" {
    const f: Function = .{
        .kind = .exponential,
        .domain = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .exponential = .{ .c0 = &.{0}, .c1 = &.{1}, .n = 1 } },
    };
    try testing.expectApproxEqAbs(@as(f64, 1), f.evalOne(5), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), f.evalOne(-5), 1e-9);
    // Including for values that are not numbers at all.
    try testing.expectApproxEqAbs(@as(f64, 0), f.evalOne(std.math.nan(f64)), 1e-9);
}

test "a stitching function picks the interval and re-maps into it" {
    const half: Function = .{
        .kind = .exponential,
        .domain = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .exponential = .{ .c0 = &.{0}, .c1 = &.{1}, .n = 1 } },
    };
    const other: Function = .{
        .kind = .exponential,
        .domain = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .exponential = .{ .c0 = &.{10}, .c1 = &.{20}, .n = 1 } },
    };
    const subs = [_]Function{ half, other };

    const f: Function = .{
        .kind = .stitching,
        .domain = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .stitching = .{
            .functions = &subs,
            .bounds = &.{0.5},
            .encode = &.{ 0, 1, 0, 1 },
        } },
    };

    // Below the bound: the first function, with 0..0.5 stretched to 0..1.
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.evalOne(0.25), 1e-9);
    // Above it: the second, with 0.5..1 stretched the same way.
    try testing.expectApproxEqAbs(@as(f64, 15), f.evalOne(0.75), 1e-9);
}

test "a sampled function interpolates between its two nearest entries" {
    // Four 8-bit samples of one output: 0, 85, 170, 255.
    const samples = [_]u8{ 0, 85, 170, 255 };
    const f: Function = .{
        .kind = .sampled,
        .domain = &.{ 0, 1 },
        .range = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .sampled = .{
            .samples = &samples,
            .size = &.{4},
            .bits = 8,
            .encode = &.{ 0, 3 },
            .decode = &.{ 0, 1 },
        } },
    };

    try testing.expectApproxEqAbs(@as(f64, 0), f.evalOne(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1), f.evalOne(1), 1e-6);
    // Exactly between samples 1 and 2.
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.evalOne(0.5), 1e-3);
}

test "sample bits smaller than a byte unpack in the right order" {
    // Two 1-bit samples per nibble: 1, 0, 1, 1 packed as 0b1011_0000.
    const samples = [_]u8{0b1011_0000};
    const f: Function = .{
        .kind = .sampled,
        .domain = &.{ 0, 3 },
        .range = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .sampled = .{
            .samples = &samples,
            .size = &.{4},
            .bits = 1,
            .encode = &.{ 0, 3 },
            .decode = &.{ 0, 1 },
        } },
    };
    try testing.expectApproxEqAbs(@as(f64, 1), f.evalOne(0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), f.evalOne(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), f.evalOne(3), 1e-9);
}

test "a truncated sample table reads as zero rather than out of bounds" {
    const f: Function = .{
        .kind = .sampled,
        .domain = &.{ 0, 1 },
        .range = &.{ 0, 1 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .sampled = .{
            .samples = &.{}, // the stream was empty
            .size = &.{4},
            .bits = 8,
            .encode = &.{ 0, 3 },
            .decode = &.{ 0, 1 },
        } },
    };
    try testing.expectApproxEqAbs(@as(f64, 0), f.evalOne(0.5), 1e-9);
}

test "calculator arithmetic, in the order PostScript pops it" {
    // `sub` is `a b sub`, not `b a sub`. Getting this backwards inverts every
    // gradient that uses one.
    const out = try ps("{ sub }", &.{ 10, 3 }, 1);
    try testing.expectApproxEqAbs(@as(f64, 7), out[0], 1e-9);

    const divided = try ps("{ div }", &.{ 10, 4 }, 1);
    try testing.expectApproxEqAbs(@as(f64, 2.5), divided[0], 1e-9);

    // Division by zero yields zero rather than an infinity that would
    // propagate into a colour component.
    const safe = try ps("{ div }", &.{ 1, 0 }, 1);
    try testing.expectApproxEqAbs(@as(f64, 0), safe[0], 1e-9);
}

test "trigonometry is in degrees" {
    const out = try ps("{ sin }", &.{90}, 1);
    try testing.expectApproxEqAbs(@as(f64, 1), out[0], 1e-9);

    const cosine = try ps("{ cos }", &.{180}, 1);
    try testing.expectApproxEqAbs(@as(f64, -1), cosine[0], 1e-9);

    const angle = try ps("{ atan }", &.{ 1, 0 }, 1);
    try testing.expectApproxEqAbs(@as(f64, 90), angle[0], 1e-9);
}

test "ifelse picks a branch and leaves one result" {
    const src = "{ 0.5 lt { 1 0 0 } { 0 0 1 } ifelse }";
    const cold = try ps(src, &.{0.2}, 3);
    try testing.expectApproxEqAbs(@as(f64, 1), cold[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), cold[2], 1e-9);

    const warm = try ps(src, &.{0.9}, 3);
    try testing.expectApproxEqAbs(@as(f64, 0), warm[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), warm[2], 1e-9);
}

test "a bare if leaves the stack alone when the condition is false" {
    const out = try ps("{ dup 0.5 gt { pop 1 } if }", &.{0.2}, 1);
    try testing.expectApproxEqAbs(@as(f64, 0.2), out[0], 1e-9);

    const fired = try ps("{ dup 0.5 gt { pop 1 } if }", &.{0.9}, 1);
    try testing.expectApproxEqAbs(@as(f64, 1), fired[0], 1e-9);
}

test "stack operators behave as the manual says" {
    // `3 2 roll` on 1 2 3 gives 2 3 1.
    const rolled = try ps("{ 3 2 roll }", &.{ 1, 2, 3 }, 3);
    try testing.expectApproxEqAbs(@as(f64, 2), rolled[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), rolled[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), rolled[2], 1e-9);

    // `1 index` copies the second-from-top.
    const indexed = try ps("{ 1 index }", &.{ 7, 9 }, 3);
    try testing.expectApproxEqAbs(@as(f64, 7), indexed[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 9), indexed[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7), indexed[2], 1e-9);

    const copied = try ps("{ 2 copy }", &.{ 4, 5 }, 4);
    try testing.expectApproxEqAbs(@as(f64, 4), copied[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), copied[3], 1e-9);
}

test "a real spot-colour tint transform" {
    // What a producer emits for a Pantone ink: one tint in, four CMYK out.
    const src = "{ dup 0.85 mul exch dup 0.2 mul exch dup 0.1 mul exch 0.05 mul }";
    const out = try ps(src, &.{1.0}, 4);
    try testing.expectApproxEqAbs(@as(f64, 0.85), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.1), out[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.05), out[3], 1e-9);
}

test "an underflowing program produces numbers rather than nonsense" {
    // Nine pops against a one-value stack, then a division.
    const out = try ps("{ pop pop pop pop pop pop pop pop pop 1 add }", &.{0.5}, 1);
    try testing.expect(std.math.isFinite(out[0]));
}

test "an unterminated program still compiles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const program = (try compile(arena_state.allocator(), "{ 1 2 add")).?;
    try testing.expectEqual(@as(usize, 3), program.len);
}

test "an if with no procedure is rejected rather than misinterpreted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(?[]const Node, null), try compile(arena_state.allocator(), "{ 1 if }"));
}

test "range clamps the result of every type" {
    const f: Function = .{
        .kind = .exponential,
        .domain = &.{ 0, 1 },
        .range = &.{ 0, 0.5 },
        .inputs = 1,
        .outputs = 1,
        .body = .{ .exponential = .{ .c0 = &.{0}, .c1 = &.{1}, .n = 1 } },
    };
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.evalOne(1), 1e-9);
}
