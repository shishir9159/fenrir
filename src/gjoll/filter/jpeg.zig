//! Baseline JPEG, because `/DCTDecode` is how a PDF carries a photograph.
//!
//! Not a general JPEG library. It decodes what PDF generators actually emit:
//! baseline sequential DCT, eight bits a sample, Huffman coded, one to four
//! components, any subsampling, with or without restart markers. Progressive
//! and arithmetic-coded files are recognised and refused by name rather than
//! decoded wrongly, and twelve-bit is refused for the same reason.
//!
//! ## The shape of the format
//!
//! A JPEG is a sequence of marker segments, each `0xFF` followed by a code and
//! a two-byte length. The ones that matter:
//!
//!     DQT   quantisation tables, in zigzag order
//!     SOF0  frame header: size, components, sampling factors
//!     DHT   Huffman tables, as a count-per-length list and then the symbols
//!     DRI   restart interval
//!     SOS   scan header, then the entropy-coded data until the next marker
//!
//! The entropy-coded data is one bitstream with `0xFF` escaped as `0xFF 0x00`,
//! so a real marker can always be found by scanning for a `0xFF` not followed
//! by zero. That is what makes restart markers work and what makes a truncated
//! file decodable up to the point it stops.
//!
//! ## What comes out
//!
//! Interleaved samples at the frame's full size, one byte per component:
//! greyscale for one component, **YCbCr converted to RGB** for three, and raw
//! four-component data for four. Four is CMYK or YCCK and which one depends on
//! an Adobe marker, so the transform flag is reported and the caller -- which
//! knows the PDF's `/ColorSpace` and `/Decode` -- applies it. Guessing here
//! would invert every Adobe CMYK image in the corpus.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotJpeg,
    Truncated,
    Unsupported,
    Corrupt,
} || Allocator.Error;

pub const Image = struct {
    /// Interleaved, `width * height * components` bytes.
    pixels: []u8,
    width: u32,
    height: u32,
    components: u8,
    /// The Adobe APP14 colour transform, for four-component images: 0 means
    /// CMYK, 2 means YCCK. Null when there was no Adobe marker.
    adobe_transform: ?u8 = null,

    pub fn deinit(img: Image, gpa: Allocator) void {
        gpa.free(img.pixels);
    }
};

/// A ceiling on what will be allocated for one image. A corrupt SOF can claim
/// 65535 by 65535 by 4, which is seventeen gigabytes.
pub const max_pixels: u64 = 64 << 20;

const Component = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    quant: u8 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    /// Per-component plane at its own subsampled size, padded to whole MCUs.
    data: []u8 = &.{},
    stride: u32 = 0,
    rows: u32 = 0,
    /// Running DC predictor for this component, reset at every restart.
    dc: i32 = 0,
};

/// One Huffman table, as a canonical code.
///
/// Decoded by the obvious method -- read a bit, extend the code, compare
/// against the largest code of that length -- rather than by a lookup table.
/// It is a handful of comparisons per symbol against a table build per scan,
/// and the IDCT is where the time actually goes.
const Huffman = struct {
    /// `max_code[l]` is the largest code of length `l+1`, or -1 if none.
    max_code: [17]i32 = @splat(-1),
    /// `val_ptr[l]` is the index into `values` of the first symbol of length
    /// `l+1`.
    val_ptr: [17]u32 = @splat(0),
    min_code: [17]i32 = @splat(0),
    values: [256]u8 = @splat(0),
    present: bool = false,

    fn build(counts: []const u8, values: []const u8) Huffman {
        var h: Huffman = .{ .present = true };
        @memcpy(h.values[0..values.len], values);

        var code: i32 = 0;
        var k: u32 = 0;
        for (1..17) |len| {
            const n = counts[len - 1];
            if (n == 0) {
                h.max_code[len] = -1;
            } else {
                h.val_ptr[len] = k;
                h.min_code[len] = code;
                k += n;
                code += n;
                h.max_code[len] = code - 1;
            }
            code <<= 1;
        }
        return h;
    }
};

/// The bitstream inside a scan, with byte stuffing undone.
const Bits = struct {
    bytes: []const u8,
    pos: usize = 0,
    acc: u32 = 0,
    count: u5 = 0,
    /// Set once the stream runs into a marker or the end. Further reads
    /// return zeroes, so a truncated image decodes to grey rather than to an
    /// error -- which is what every other reader shows and is more useful
    /// than nothing.
    done: bool = false,

    fn bit(b: *Bits) u1 {
        if (b.count == 0) {
            if (b.pos >= b.bytes.len) {
                b.done = true;
                return 0;
            }
            var byte = b.bytes[b.pos];
            b.pos += 1;
            if (byte == 0xFF) {
                // `FF 00` is a literal 0xFF; anything else is a marker, and
                // the scan is over.
                const next: u8 = if (b.pos < b.bytes.len) b.bytes[b.pos] else 0xD9;
                if (next == 0x00) {
                    b.pos += 1;
                } else {
                    b.done = true;
                    byte = 0;
                    b.pos -= 1;
                }
            }
            b.acc = byte;
            b.count = 8;
        }
        b.count -= 1;
        return @truncate(b.acc >> b.count);
    }

    fn bits(b: *Bits, n: u5) u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) v = (v << 1) | b.bit();
        return v;
    }

    /// Aligns to a byte and steps over a restart marker, if one is next.
    fn restart(b: *Bits) void {
        b.count = 0;
        b.done = false;
        // Find the RSTn. There may be fill bytes before it.
        while (b.pos + 1 < b.bytes.len) {
            if (b.bytes[b.pos] == 0xFF) {
                const m = b.bytes[b.pos + 1];
                if (m >= 0xD0 and m <= 0xD7) {
                    b.pos += 2;
                    return;
                }
                return;
            }
            b.pos += 1;
        }
        b.done = true;
    }

    fn decode(b: *Bits, h: Huffman) Error!u8 {
        if (!h.present) return error.Corrupt;
        var code: i32 = b.bit();
        var len: u32 = 1;
        while (len < 17) : (len += 1) {
            if (h.max_code[len] >= 0 and code <= h.max_code[len]) {
                const i = h.val_ptr[len] + @as(u32, @intCast(code - h.min_code[len]));
                if (i >= h.values.len) return error.Corrupt;
                return h.values[i];
            }
            code = (code << 1) | b.bit();
            if (b.done and len > 8) return 0;
        }
        return error.Corrupt;
    }

    /// The sign-extended value of an `n`-bit coefficient (§F.2.2.1).
    ///
    /// JPEG stores a magnitude category and then that many bits; the top bit
    /// says which side of zero it is on, and a zero top bit means the value is
    /// negative and offset.
    fn receive(b: *Bits, n: u5) i32 {
        if (n == 0) return 0;
        const v: i32 = @intCast(b.bits(n));
        const half = @as(i32, 1) << (n - 1);
        return if (v < half) v - (@as(i32, 1) << n) + 1 else v;
    }
};

/// The zigzag order coefficients are stored in.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

pub fn decode(gpa: Allocator, bytes: []const u8) Error!Image {
    var d: Decoder = .{ .gpa = gpa, .bytes = bytes };
    defer d.deinit();
    return d.run();
}

const Decoder = struct {
    gpa: Allocator,
    bytes: []const u8,
    pos: usize = 0,

    quant: [4][64]u16 = @splat(@splat(0)),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),

    comps: [4]Component = @splat(.{}),
    ncomp: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcus_x: u32 = 0,
    mcus_y: u32 = 0,
    restart_interval: u32 = 0,
    adobe_transform: ?u8 = null,
    progressive: bool = false,

    fn deinit(d: *Decoder) void {
        for (&d.comps) |*c| {
            if (c.data.len != 0) d.gpa.free(c.data);
            c.data = &.{};
        }
    }

    fn u16At(d: *Decoder) Error!u16 {
        if (d.pos + 2 > d.bytes.len) return error.Truncated;
        const v = std.mem.readInt(u16, d.bytes[d.pos..][0..2], .big);
        d.pos += 2;
        return v;
    }

    fn run(d: *Decoder) Error!Image {
        if (d.bytes.len < 4 or d.bytes[0] != 0xFF or d.bytes[1] != 0xD8) return error.NotJpeg;
        d.pos = 2;

        while (d.pos + 1 < d.bytes.len) {
            if (d.bytes[d.pos] != 0xFF) {
                d.pos += 1;
                continue;
            }
            const marker = d.bytes[d.pos + 1];
            d.pos += 2;
            switch (marker) {
                0xD8, 0x01, 0xFF => continue,
                0xD9 => break, // EOI
                0xD0...0xD7 => continue, // a stray restart
                0xC0, 0xC1 => try d.frameHeader(),
                0xC2 => {
                    // Progressive. Refused rather than decoded as baseline,
                    // which produces a recognisable but wrong image.
                    d.progressive = true;
                    return error.Unsupported;
                },
                0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
                0xC4 => try d.huffmanTables(),
                0xDB => try d.quantTables(),
                0xDD => {
                    const len = try d.u16At();
                    if (len < 4) return error.Corrupt;
                    d.restart_interval = try d.u16At();
                    d.pos += len - 4;
                },
                0xDA => {
                    try d.scan();
                    // One scan is the whole of a baseline image.
                    break;
                },
                0xEE => try d.adobeMarker(),
                else => {
                    const len = try d.u16At();
                    if (len < 2) return error.Corrupt;
                    d.pos += len - 2;
                },
            }
        }

        if (d.ncomp == 0 or d.width == 0 or d.height == 0) return error.Corrupt;
        return d.assemble();
    }

    fn frameHeader(d: *Decoder) Error!void {
        const len = try d.u16At();
        if (len < 8 or d.pos + len - 2 > d.bytes.len) return error.Truncated;
        const precision = d.bytes[d.pos];
        if (precision != 8) return error.Unsupported;
        d.pos += 1;
        d.height = try d.u16At();
        d.width = try d.u16At();
        d.ncomp = d.bytes[d.pos];
        d.pos += 1;
        if (d.ncomp == 0 or d.ncomp > 4) return error.Unsupported;
        if (@as(u64, d.width) * d.height > max_pixels) return error.Unsupported;

        for (0..d.ncomp) |i| {
            if (d.pos + 3 > d.bytes.len) return error.Truncated;
            const c = &d.comps[i];
            c.id = d.bytes[d.pos];
            c.h = @max(1, d.bytes[d.pos + 1] >> 4);
            c.v = @max(1, d.bytes[d.pos + 1] & 0xF);
            c.quant = d.bytes[d.pos + 2] & 3;
            if (c.h > 4 or c.v > 4) return error.Unsupported;
            d.pos += 3;
            d.hmax = @max(d.hmax, c.h);
            d.vmax = @max(d.vmax, c.v);
        }

        d.mcus_x = (d.width + @as(u32, d.hmax) * 8 - 1) / (@as(u32, d.hmax) * 8);
        d.mcus_y = (d.height + @as(u32, d.vmax) * 8 - 1) / (@as(u32, d.vmax) * 8);

        // A plane per component, padded out to whole MCUs so the block loop
        // never has to test whether it is over the edge.
        for (0..d.ncomp) |i| {
            const c = &d.comps[i];
            c.stride = d.mcus_x * c.h * 8;
            c.rows = d.mcus_y * c.v * 8;
            const n = @as(u64, c.stride) * c.rows;
            if (n > max_pixels * 4) return error.Unsupported;
            c.data = try d.gpa.alloc(u8, @intCast(n));
            @memset(c.data, 128);
        }
    }

    fn quantTables(d: *Decoder) Error!void {
        const len = try d.u16At();
        if (len < 2) return error.Corrupt;
        const end = d.pos + len - 2;
        if (end > d.bytes.len) return error.Truncated;

        while (d.pos < end) {
            const spec = d.bytes[d.pos];
            d.pos += 1;
            const id = spec & 3;
            const wide = (spec >> 4) != 0;
            const need: usize = if (wide) 128 else 64;
            if (d.pos + need > end) return error.Truncated;
            for (0..64) |i| {
                const v: u16 = if (wide)
                    std.mem.readInt(u16, d.bytes[d.pos + i * 2 ..][0..2], .big)
                else
                    d.bytes[d.pos + i];
                d.quant[id][zigzag[i]] = v;
            }
            d.pos += need;
        }
    }

    fn huffmanTables(d: *Decoder) Error!void {
        const len = try d.u16At();
        if (len < 2) return error.Corrupt;
        const end = d.pos + len - 2;
        if (end > d.bytes.len) return error.Truncated;

        while (d.pos < end) {
            if (d.pos + 17 > end) return error.Truncated;
            const spec = d.bytes[d.pos];
            d.pos += 1;
            const id = spec & 3;
            const is_ac = (spec >> 4) != 0;

            const counts = d.bytes[d.pos..][0..16];
            d.pos += 16;
            var total: usize = 0;
            for (counts) |n| total += n;
            if (total > 256 or d.pos + total > end) return error.Corrupt;

            const table: Huffman = .build(counts, d.bytes[d.pos..][0..total]);
            d.pos += total;
            if (is_ac) d.ac[id] = table else d.dc[id] = table;
        }
    }

    fn adobeMarker(d: *Decoder) Error!void {
        const len = try d.u16At();
        if (len < 2 or d.pos + len - 2 > d.bytes.len) return error.Truncated;
        const seg = d.bytes[d.pos .. d.pos + len - 2];
        if (seg.len >= 12 and std.mem.eql(u8, seg[0..5], "Adobe")) {
            d.adobe_transform = seg[11];
        }
        d.pos += len - 2;
    }

    fn scan(d: *Decoder) Error!void {
        const len = try d.u16At();
        if (len < 3 or d.pos + len - 2 > d.bytes.len) return error.Truncated;
        const ns = d.bytes[d.pos];
        d.pos += 1;
        if (ns == 0 or ns > d.ncomp) return error.Corrupt;

        // Which components this scan covers, in scan order.
        var order: [4]usize = @splat(0);
        for (0..ns) |i| {
            if (d.pos + 2 > d.bytes.len) return error.Truncated;
            const id = d.bytes[d.pos];
            const tables = d.bytes[d.pos + 1];
            d.pos += 2;
            var found = false;
            for (0..d.ncomp) |j| {
                if (d.comps[j].id == id) {
                    d.comps[j].dc_table = tables >> 4;
                    d.comps[j].ac_table = tables & 0xF;
                    if (d.comps[j].dc_table > 3 or d.comps[j].ac_table > 3) return error.Corrupt;
                    order[i] = j;
                    found = true;
                    break;
                }
            }
            if (!found) return error.Corrupt;
        }
        // Ss, Se, Ah/Al -- meaningful only for progressive, which is refused.
        d.pos += 3;

        var bits: Bits = .{ .bytes = d.bytes[d.pos..] };
        for (&d.comps) |*c| c.dc = 0;

        var coeffs: [64]i32 = undefined;
        var since_restart: u32 = 0;

        var my: u32 = 0;
        while (my < d.mcus_y) : (my += 1) {
            var mx: u32 = 0;
            while (mx < d.mcus_x) : (mx += 1) {
                if (d.restart_interval != 0 and since_restart == d.restart_interval) {
                    bits.restart();
                    for (&d.comps) |*c| c.dc = 0;
                    since_restart = 0;
                }
                since_restart += 1;

                // A single-component scan is not interleaved, but a baseline
                // PDF image with one component has one MCU per block anyway,
                // so the same loop serves.
                for (0..ns) |i| {
                    const c = &d.comps[order[i]];
                    var by: u32 = 0;
                    while (by < c.v) : (by += 1) {
                        var bx: u32 = 0;
                        while (bx < c.h) : (bx += 1) {
                            try d.decodeBlock(&bits, c, &coeffs);
                            const px = (mx * c.h + bx) * 8;
                            const py = (my * c.v + by) * 8;
                            idct(&coeffs, c.data, c.stride, px, py);
                        }
                    }
                }
            }
        }
    }

    /// One 8x8 block: the DC difference, then the AC run-length pairs.
    fn decodeBlock(d: *Decoder, bits: *Bits, c: *Component, out: *[64]i32) Error!void {
        @memset(out, 0);
        const q = &d.quant[c.quant];

        const t = try bits.decode(d.dc[c.dc_table]);
        if (t > 15) return error.Corrupt;
        c.dc += bits.receive(@intCast(t));
        out[0] = c.dc * @as(i32, q[0]);

        var k: usize = 1;
        while (k < 64) {
            const rs = try bits.decode(d.ac[c.ac_table]);
            const zeroes = rs >> 4;
            const size = rs & 0xF;
            if (size == 0) {
                // 0x00 ends the block; 0xF0 is a run of sixteen zeroes.
                if (zeroes != 15) break;
                k += 16;
                continue;
            }
            k += zeroes;
            if (k >= 64) break;
            const at = zigzag[k];
            out[at] = bits.receive(@intCast(size)) * @as(i32, q[at]);
            k += 1;
        }
    }

    /// Interleaves the planes, upsampling any that are subsampled, and
    /// converts YCbCr to RGB.
    fn assemble(d: *Decoder) Error!Image {
        const n: usize = @intCast(d.ncomp);
        const pixels = try d.gpa.alloc(u8, @as(usize, d.width) * d.height * n);
        errdefer d.gpa.free(pixels);

        var y: u32 = 0;
        while (y < d.height) : (y += 1) {
            var x: u32 = 0;
            while (x < d.width) : (x += 1) {
                const o = (@as(usize, y) * d.width + x) * n;
                for (0..n) |i| {
                    const c = &d.comps[i];
                    // Nearest-neighbour upsampling. Bilinear would be smoother
                    // on a 4:2:0 chroma plane, and the difference is invisible
                    // once the image is scaled to a page.
                    const sx = @min(c.stride - 1, x * c.h / d.hmax);
                    const sy = @min(c.rows - 1, y * c.v / d.vmax);
                    pixels[o + i] = c.data[@as(usize, sy) * c.stride + sx];
                }
            }
        }

        // Three components are YCbCr unless an Adobe marker says otherwise;
        // four are left alone, because CMYK and YCCK need the PDF's colour
        // space to tell them apart.
        if (n == 3 and (d.adobe_transform orelse 1) != 0) {
            ycbcrToRgb(pixels, 3);
        } else if (n == 4 and (d.adobe_transform orelse 0) == 2) {
            ycbcrToRgb(pixels, 4);
        }

        return .{
            .pixels = pixels,
            .width = d.width,
            .height = d.height,
            .components = d.ncomp,
            .adobe_transform = d.adobe_transform,
        };
    }
};

/// JFIF's YCbCr, in place. The first three of every `stride` components.
fn ycbcrToRgb(pixels: []u8, stride: usize) void {
    var i: usize = 0;
    while (i + stride <= pixels.len) : (i += stride) {
        const y: f32 = @floatFromInt(pixels[i]);
        const cb = @as(f32, @floatFromInt(pixels[i + 1])) - 128.0;
        const cr = @as(f32, @floatFromInt(pixels[i + 2])) - 128.0;
        pixels[i + 0] = clamp8(y + 1.402 * cr);
        pixels[i + 1] = clamp8(y - 0.344136 * cb - 0.714136 * cr);
        pixels[i + 2] = clamp8(y + 1.772 * cb);
    }
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// Cosine table for the 1-D IDCT: `cos((2u+1)·v·π/16) · (v == 0 ? 1/√2 : 1)`.
const idct_table = blk: {
    @setEvalBranchQuota(20000);
    var t: [8][8]f32 = undefined;
    for (0..8) |u| {
        for (0..8) |v| {
            const scale: f32 = if (v == 0) 1.0 / @sqrt(2.0) else 1.0;
            t[u][v] = scale * @cos(@as(f32, @floatFromInt((2 * u + 1) * v)) *
                std.math.pi / 16.0);
        }
    }
    break :blk t;
};

/// The inverse DCT of one block, written into a plane at `(px, py)`.
///
/// Separable: the rows first, then the columns, which is 8×8×8 multiplies a
/// pass instead of the 8×8×8×8 a direct evaluation would take. Float rather
/// than the fixed-point version every codec ships, because the difference is
/// under a level of output and this one can be read.
fn idct(block: *const [64]i32, plane: []u8, stride: u32, px: u32, py: u32) void {
    var tmp: [64]f32 = undefined;

    // Rows.
    for (0..8) |row| {
        const in = block[row * 8 ..][0..8];
        for (0..8) |x| {
            var sum: f32 = 0;
            for (0..8) |v| sum += idct_table[x][v] * @as(f32, @floatFromInt(in[v]));
            tmp[row * 8 + x] = sum * 0.5;
        }
    }

    // Columns, then the level shift back to unsigned.
    for (0..8) |x| {
        for (0..8) |y| {
            var sum: f32 = 0;
            for (0..8) |v| sum += idct_table[y][v] * tmp[v * 8 + x];
            const value = sum * 0.5 + 128.0;

            const ox = px + @as(u32, @intCast(x));
            const oy = py + @as(u32, @intCast(y));
            if (ox >= stride) continue;
            const at = @as(usize, oy) * stride + ox;
            if (at >= plane.len) continue;
            plane[at] = clamp8(value);
        }
    }
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "a file that does not start with SOI is refused" {
    try testing.expectError(error.NotJpeg, decode(testing.allocator, "not a jpeg at all"));
    try testing.expectError(error.NotJpeg, decode(testing.allocator, &.{ 0xFF, 0xD9 }));
}

test "the zigzag order is a permutation of all sixty-four coefficients" {
    // A transposed or truncated table decodes every block into noise that
    // still looks like an image, which is the hardest kind of wrong to see.
    var seen: [64]bool = @splat(false);
    for (zigzag) |z| {
        try testing.expect(!seen[z]);
        seen[z] = true;
    }
    for (seen) |s| try testing.expect(s);
    // The first two steps of the scan: across, then down-left.
    try testing.expectEqual(@as(u8, 0), zigzag[0]);
    try testing.expectEqual(@as(u8, 1), zigzag[1]);
    try testing.expectEqual(@as(u8, 8), zigzag[2]);
    try testing.expectEqual(@as(u8, 63), zigzag[63]);
}

test "a flat block inverts to a flat plane at its DC level" {
    // The IDCT's one checkable identity: a block with only a DC coefficient
    // is a constant, and its value is `dc / 8 + 128` after the level shift.
    var block: [64]i32 = @splat(0);
    block[0] = 8 * 100; // 100 after the two halvings and the 1/√2 pair

    var plane: [64]u8 = @splat(0);
    idct(&block, &plane, 8, 0, 0);

    const want = plane[0];
    try testing.expect(want > 128); // positive DC lifts it off the middle
    for (plane) |p| try testing.expectEqual(want, p);

    // And a zero block is exactly the level shift.
    @memset(&block, 0);
    idct(&block, &plane, 8, 0, 0);
    for (plane) |p| try testing.expectEqual(@as(u8, 128), p);
}

test "the bit reader unstuffs FF 00 and stops at a real marker" {
    // The one piece of framing that makes a JPEG scan self-delimiting. Read
    // the stuffing wrong and every image decodes to noise after its first
    // bright pixel.
    var b: Bits = .{ .bytes = &.{ 0xFF, 0x00, 0xA5, 0xFF, 0xD9, 0x11 } };
    try testing.expectEqual(@as(u32, 0xFF), b.bits(8));
    try testing.expectEqual(@as(u32, 0xA5), b.bits(8));
    try testing.expect(!b.done);
    // The next byte is a marker, so the stream ends rather than reading it.
    _ = b.bits(8);
    try testing.expect(b.done);
}

test "receive sign-extends the way the standard does" {
    // §F.2.2.1: an n-bit value whose top bit is zero is negative. Getting
    // this backwards makes every image a photographic negative of itself in
    // the AC detail while the DC stays right, which reads as heavy noise.
    var b: Bits = .{ .bytes = &.{0b1010_0000} };
    // 3 bits of `101` = 5, top bit set, so positive 5.
    try testing.expectEqual(@as(i32, 5), b.receive(3));

    var c: Bits = .{ .bytes = &.{0b0010_0000} };
    // 3 bits of `001` = 1, top bit clear: 1 - 8 + 1 = -6.
    try testing.expectEqual(@as(i32, -6), c.receive(3));

    var z: Bits = .{ .bytes = &.{0xFF} };
    try testing.expectEqual(@as(i32, 0), z.receive(0));
}

test "a canonical Huffman table decodes the symbols it was built from" {
    // Three symbols at lengths 1, 2, 3: codes 0, 10, 110.
    var counts: [16]u8 = @splat(0);
    counts[0] = 1;
    counts[1] = 1;
    counts[2] = 1;
    const h: Huffman = .build(&counts, &.{ 'a', 'b', 'c' });

    // Eight bits exactly: a zero-padded literal pads on the left and would
    // shift every code along by one.
    var b: Bits = .{ .bytes = &.{0b0_10_110_00} };
    try testing.expectEqual(@as(u8, 'a'), try b.decode(h));
    try testing.expectEqual(@as(u8, 'b'), try b.decode(h));
    try testing.expectEqual(@as(u8, 'c'), try b.decode(h));
}

test "YCbCr conversion puts grey at grey and red at red" {
    // Y = 128, Cb = Cr = 128 is mid grey in every channel.
    var grey = [_]u8{ 128, 128, 128 };
    ycbcrToRgb(&grey, 3);
    try testing.expectEqual([3]u8{ 128, 128, 128 }, grey);

    // Full luma with maximum Cr is red.
    var red = [_]u8{ 76, 85, 255 };
    ycbcrToRgb(&red, 3);
    try testing.expect(red[0] > 240);
    try testing.expect(red[1] < 40);
    try testing.expect(red[2] < 40);
}
