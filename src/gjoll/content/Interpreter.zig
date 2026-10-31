//! The content-stream interpreter (§8, §9): operators in, display list out.
//!
//! Every page in every PDF is a little stack program, and this runs it. There
//! are seventy-three operators; all of them are here, and the ones that are
//! approximated rather than implemented say so where they are handled.
//!
//! ## The four things worth knowing before reading it
//!
//! **The CTM is applied on the way in.** A path point is transformed the
//! moment its operator is scanned, so the display list holds page-space
//! geometry and no backend has to carry a matrix stack. Strokes are the
//! exception and keep their matrix, for the reason `DisplayList` gives: the
//! pen is a circle in user space, and a non-uniform CTM makes it an ellipse
//! that device-space points cannot describe.
//!
//! **`q`/`Q` restores clips by depth, not by count.** Each saved state records
//! how deep the builder's clip stack was when it was pushed, and `Q` pops back
//! to that. This is the only handling that is correct for `q W n q W n Q Q`,
//! and it makes an unbalanced stream -- which is most damaged streams -- cost
//! nothing extra.
//!
//! **`W` is deferred, and the deferral is not optional.** `W f` means fill
//! this path *and then* clip to it: the fill must not be clipped by the region
//! it establishes. So the path range is taken before the paint and used after,
//! which is what `Builder.pushClipPath` exists for.
//!
//! **Text is recorded per showing operator.** One `Tj` is one `TextRun`, which
//! is the natural unit because it is exactly what shares a font, a matrix, and
//! a paint. Glyph offsets are accumulated in a text space that does *not*
//! include horizontal scaling, because `Tz` scales the glyph shapes too and
//! therefore belongs in the run's matrix rather than in its offsets.
//!
//! ## Damage
//!
//! Nothing here fails a page. An unknown operator is counted; a missing
//! resource is counted; a recursive form XObject is refused by object number;
//! a stream longer than `max_commands` is truncated and flagged. The only
//! errors that escape are out-of-memory and a document that cannot be read at
//! all, because those are not the page's fault.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Builder = @import("../../gelgja/Builder.zig");
const DisplayList = @import("../../gelgja/DisplayList.zig");
const Document = @import("../Document.zig");
const Font = @import("Font.zig");
const Page = @import("../Page.zig");
const Scanner = @import("Scanner.zig");
const color = @import("color.zig");
const filter = @import("../filter.zig");
const function = @import("function.zig");
const geom = @import("../../gelgja/geom.zig");
const matrix = @import("matrix.zig");
const object = @import("../object.zig");
const paint = @import("../../gelgja/paint.zig");
const xref = @import("../xref.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const ColorSpace = color.ColorSpace;
const Dict = object.Dict;
const FillRule = geom.FillRule;
const FontId = DisplayList.FontId;
const Glyph = DisplayList.Glyph;
const Matrix = matrix.Matrix;
const Object = object.Object;
const Paint = paint.Paint;
const Point = geom.Point;
const Stroke = paint.Stroke;
const TextRenderMode = paint.TextRenderMode;

const Interpreter = @This();

pub const Error = Document.Error;

pub const Options = struct {
    /// How deep form XObjects, patterns, and Type 3 glyph procedures may
    /// nest. Legitimate documents rarely pass four.
    max_depth: u8 = 12,
    /// A ceiling on recorded commands, so that a generated file with a
    /// hundred million rectangles cannot exhaust memory before it is drawn.
    max_commands: u32 = 4_000_000,
    /// Apply `/Rotate`, so the list is in the orientation a reader displays.
    /// Off is useful for diffing against the numbers in the file.
    rotate: bool = true,
    /// Run Type 3 glyph procedures. Off records nothing for them, which is
    /// what a text-extraction pass wants.
    type3: bool = true,
    /// Draw the page's annotation appearance streams after its content
    /// (§12.5.5). On, because a highlight, a stamp, a filled-in form field and
    /// a signature all live there and in nothing else: a page drawn without
    /// them looks finished rather than looking stripped. Off for a pass that
    /// wants only what the content stream says.
    annotations: bool = true,
};

/// What the interpreter noticed while it ran. None of it stops a page; all of
/// it is worth printing when one comes out wrong.
pub const Diagnostics = struct {
    operators: u32 = 0,
    unknown_operators: u32 = 0,
    /// `Q` with nothing to restore, which means the stream is unbalanced in
    /// the direction that loses state rather than the one that leaks it.
    stack_underflows: u32 = 0,
    /// A `/Font`, `/XObject`, `/ColorSpace`, `/Pattern`, `/Shading` or
    /// `/ExtGState` name with nothing behind it.
    missing_resources: u32 = 0,
    forms_drawn: u32 = 0,
    images_drawn: u32 = 0,
    inline_images: u32 = 0,
    /// Form XObjects refused because they are already on the stack.
    recursive_forms: u32 = 0,
    /// Text shown with no `Tf` in effect. The glyphs are dropped, because
    /// there is no width with which to advance past them.
    text_without_font: u32 = 0,
    /// Annotations whose appearance stream was drawn onto the page.
    annotations_drawn: u32 = 0,
    /// Annotations passed over: hidden, not for the screen, a popup, or with
    /// no appearance stream to draw. A `/Link` with a border and no `/AP` is
    /// the common one, and is correctly invisible.
    annotations_skipped: u32 = 0,
    deepest_nesting: u8 = 0,
    /// True when `max_commands` cut the page short.
    truncated: bool = false,

    /// The first few unknown operators, copied rather than borrowed so that
    /// the diagnostics outlive the content stream they came from.
    ///
    /// Eight bytes, not the three that every real operator fits in: the
    /// names worth seeing here are the ones that are not operators at all.
    /// pdfTeX writes a bare `pagesize width 614.295pt height 794.97pt` line
    /// into content streams, and a four-byte buffer counts all five of its
    /// tokens and can name only `pt`.
    unknown_names: [4][8]u8 = @splat(@splat(0)),
    unknown_lens: [4]u8 = @splat(0),
    unknown_count: u8 = 0,

    pub fn unknownName(d: *const Diagnostics, i: usize) []const u8 {
        if (i >= d.unknown_count) return "";
        return d.unknown_names[i][0..d.unknown_lens[i]];
    }

    fn noteUnknown(d: *Diagnostics, name: []const u8) void {
        d.unknown_operators += 1;
        if (d.unknown_count == d.unknown_names.len) return;

        // Truncated, not skipped. A name too long to fit is exactly the case
        // worth seeing -- it means the "operator" is a run of bytes from a
        // stream that did not decode -- and skipping it leaves the count with
        // nothing to explain it.
        const take = @min(name.len, d.unknown_names[0].len);
        const kept = name[0..take];
        for (0..d.unknown_count) |i| {
            if (std.mem.eql(u8, d.unknownName(i), kept)) return;
        }
        @memcpy(d.unknown_names[d.unknown_count][0..take], kept);
        d.unknown_lens[d.unknown_count] = @intCast(take);
        d.unknown_count += 1;
    }
};

pub const Result = struct {
    list: DisplayList,
    diagnostics: Diagnostics,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.list.deinit(gpa);
        r.* = .{ .list = .{}, .diagnostics = .{} };
    }
};

// -- graphics state ---------------------------------------------------------

/// The state `q` saves and `Q` restores (§8.4). Text state is in here too,
/// because `Tf` and `Tc` survive `ET` and are saved by `q` like everything
/// else -- the text *matrices* are the part that does not.
pub const State = struct {
    ctm: Matrix = .identity,

    fill_space: ColorSpace = .device_gray,
    stroke_space: ColorSpace = .device_gray,
    fill: Paint = .{ .solid = .black },
    stroke: Paint = .{ .solid = .black },
    fill_alpha: f32 = 1,
    stroke_alpha: f32 = 1,

    line: Stroke = .{},
    blend: paint.BlendMode = .normal,
    soft_mask: paint.ObjectId = paint.no_object,

    char_spacing: f64 = 0,
    word_spacing: f64 = 0,
    horizontal_scale: f64 = 1,
    leading: f64 = 0,
    font: ?usize = null,
    font_size: f64 = 0,
    render_mode: TextRenderMode = .fill,
    rise: f64 = 0,

    /// How many clips were open when this state was pushed by `q`, so the
    /// matching `Q` pops exactly the ones opened since. Meaningful only on a
    /// state that is sitting on the stack; the live state's copy is stale by
    /// construction and nothing reads it.
    clip_depth: u32 = 0,
};

// -- fields -----------------------------------------------------------------

gpa: Allocator,
doc: *Document,
arena_state: std.heap.ArenaAllocator,
builder: Builder,
options: Options,
diag: Diagnostics = .{},

state: State = .{},
stack: std.ArrayList(State) = .empty,

/// The page's own coordinate system, which pattern and shading space are
/// measured against however deep the CTM has been pushed since.
base_ctm: Matrix = .identity,

/// Fonts, in the same order as the builder's font table, so a `FontId` is an
/// index into both.
fonts: std.ArrayList(Font) = .empty,
font_cache: std.AutoHashMapUnmanaged(u32, u32) = .empty,
space_cache: std.AutoHashMapUnmanaged(u32, ColorSpace) = .empty,
/// Object numbers of the form XObjects and patterns currently being run, to
/// refuse a stream that draws itself.
active: std.ArrayList(u32) = .empty,

// Path and clip state, which live outside `State` because they are not saved
// by `q`.
pending_clip: ?FillRule = null,

// Text object state, reset by `BT`.
tm: Matrix = .identity,
tlm: Matrix = .identity,
in_text: bool = false,
glyph_buf: std.ArrayList(Glyph) = .empty,
/// Glyph boxes accumulated while a clipping render mode is in effect.
text_clip: std.ArrayList([4]Point) = .empty,

// -- entry points -----------------------------------------------------------

/// Interprets one page. The base transform puts the crop box's lower-left
/// corner at the origin and, unless `options.rotate` is off, applies
/// `/Rotate` -- so the list's page box is `(0, 0, displayWidth,
/// displayHeight)` and a viewer needs only a scale to put it on screen.
///
/// For the common page -- crop box at the origin, no rotation -- the base
/// transform is the identity, and every coordinate in the trace is a number
/// that appears in the content stream. That is deliberate: it is what makes
/// `fenrir trace` diffable against `fenrir extract --page`.
pub fn page(gpa: Allocator, doc: *Document, p: Page, options: Options) Error!Result {
    const crop = p.crop_box.normalized();
    const rotation = if (options.rotate) p.rotate else .none;

    const w = crop.width();
    const h = crop.height();
    const shift: Matrix = .translation(-crop.x0, -crop.y0);
    const turn: Matrix = switch (rotation) {
        .none => .identity,
        // Clockwise on screen, in a Y-up space: see §7.7.3.3. The translation
        // is what keeps the rotated page in the positive quadrant.
        .cw90 => .{ .a = 0, .b = -1, .c = 1, .d = 0, .e = 0, .f = w },
        .cw180 => .{ .a = -1, .b = 0, .c = 0, .d = -1, .e = w, .f = h },
        .cw270 => .{ .a = 0, .b = 1, .c = -1, .d = 0, .e = h, .f = 0 },
    };

    const box: Bounds = if (rotation.swapsAxes())
        .fromRect(0, 0, @floatCast(h), @floatCast(w))
    else
        .fromRect(0, 0, @floatCast(w), @floatCast(h));

    const content = try p.contents(doc);
    const annots: []const Object = if (options.annotations)
        p.annotations(doc) catch &.{}
    else
        &.{};
    return run(gpa, doc, content, p.resources, box, shift.concat(turn), options, annots);
}

/// Interprets a bare content stream against a resource dictionary and a base
/// transform: everything `page` does apart from working out that transform.
///
/// Form XObjects and Type 3 glyphs do *not* come through here -- they recurse
/// inside a running interpreter so that they inherit its graphics state, which
/// is the whole point of them. This is for a stream that is a page's peer
/// rather than its child: an annotation's appearance stream, or a tiling
/// pattern's cell. Neither has a caller yet; both will, and both want exactly
/// this signature.
pub fn stream(
    gpa: Allocator,
    doc: *Document,
    content: []const u8,
    resources: Dict,
    box: Bounds,
    base: Matrix,
    options: Options,
) Error!Result {
    return run(gpa, doc, content, resources, box, base, options, &.{});
}

fn run(
    gpa: Allocator,
    doc: *Document,
    content: []const u8,
    resources: Dict,
    box: Bounds,
    base: Matrix,
    options: Options,
    annots: []const Object,
) Error!Result {
    var it: Interpreter = .{
        .gpa = gpa,
        .doc = doc,
        .arena_state = .init(gpa),
        .builder = .init(gpa, box),
        .options = options,
        .base_ctm = base,
    };
    defer it.deinit();
    errdefer it.builder.deinit();

    it.state.ctm = base;
    try it.execute(content, resources, 0);
    if (annots.len != 0) try it.drawAnnotations(annots, resources, base);

    return .{
        .list = try it.builder.finish(),
        .diagnostics = it.diag,
    };
}

fn deinit(it: *Interpreter) void {
    it.stack.deinit(it.gpa);
    it.fonts.deinit(it.gpa);
    it.font_cache.deinit(it.gpa);
    it.space_cache.deinit(it.gpa);
    it.active.deinit(it.gpa);
    it.glyph_buf.deinit(it.gpa);
    it.text_clip.deinit(it.gpa);
    it.arena_state.deinit();
}

fn arena(it: *Interpreter) Allocator {
    return it.arena_state.allocator();
}

// -- the loop ---------------------------------------------------------------

/// Packs an operator name into a `u32` so that dispatch is one switch rather
/// than seventy string comparisons. Every operator in the specification is
/// three bytes or fewer.
inline fn pack(name: []const u8) u32 {
    if (name.len == 0 or name.len > 4) return 0;
    var k: u32 = 0;
    for (name) |c| k = (k << 8) | c;
    return k;
}

fn keyOf(name: []const u8) u32 {
    return pack(name);
}

fn K(comptime name: []const u8) u32 {
    return comptime pack(name);
}

fn execute(it: *Interpreter, content: []const u8, resources: Dict, depth: u8) Error!void {
    it.diag.deepest_nesting = @max(it.diag.deepest_nesting, depth);

    var scanner: Scanner = .init(content, it.arena());
    while (true) {
        const op = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A lexing failure inside one stream should not lose the rest of
            // the page; the scanner has already advanced past the bad byte,
            // so the only safe response is to stop this stream.
            else => break,
        } orelse break;

        it.diag.operators += 1;
        if (it.builder.cmds.items.len >= it.options.max_commands) {
            it.diag.truncated = true;
            break;
        }

        try it.dispatch(op, resources, depth);
    }
}

fn dispatch(it: *Interpreter, op: Scanner.Op, resources: Dict, depth: u8) Error!void {
    if (op.image) |img| return it.inlineImage(img, resources);

    switch (keyOf(op.name)) {
        // -- graphics state --------------------------------------------------
        K("q") => {
            // The depth belongs to the *snapshot*, not to the live state: it
            // records how many clips were open at this `q` so the matching
            // `Q` pops exactly the ones opened since. Reading it off the live
            // state instead makes an inner `Q` pop an outer `q`'s clip, and
            // the page after it draws unclipped.
            var snapshot = it.state;
            snapshot.clip_depth = it.builder.clip_depth;
            try it.stack.append(it.gpa, snapshot);
        },
        K("Q") => {
            const saved = it.stack.pop() orelse {
                it.diag.stack_underflows += 1;
                return;
            };
            while (it.builder.clip_depth > saved.clip_depth) try it.builder.popClip();
            it.state = saved;
        },
        K("cm") => {
            const v = op.nums(6) orelse return;
            it.state.ctm = Matrix.fromOperands(v).concat(it.state.ctm);
        },
        K("w") => it.state.line.width = @floatCast(@max(op.num() orelse return, 0)),
        K("J") => it.state.line.cap = capOf(op.num() orelse return),
        K("j") => it.state.line.join = joinOf(op.num() orelse return),
        K("M") => it.state.line.miter_limit = @floatCast(op.num() orelse return),
        K("d") => try it.setDash(op),
        // `ri` and `i` are rendering hints with no geometry: the intent of a
        // colour conversion we do not do, and a flatness we choose ourselves.
        K("ri"), K("i") => {},
        K("gs") => try it.extGState(op.nameOperand() orelse return, resources),

        // -- path construction -----------------------------------------------
        K("m") => {
            const v = op.nums(2) orelse return;
            try it.builder.moveTo(it.state.ctm.point(v[0], v[1]));
        },
        K("l") => {
            const v = op.nums(2) orelse return;
            try it.builder.lineTo(it.state.ctm.point(v[0], v[1]));
        },
        K("c") => {
            const v = op.nums(6) orelse return;
            try it.builder.curveTo(
                it.state.ctm.point(v[0], v[1]),
                it.state.ctm.point(v[2], v[3]),
                it.state.ctm.point(v[4], v[5]),
            );
        },
        K("v") => {
            // The current point doubles as the first control point. It is
            // already in device space, so it is used as it stands rather than
            // transformed a second time.
            const v = op.nums(4) orelse return;
            try it.builder.curveTo(
                it.builder.cursor,
                it.state.ctm.point(v[0], v[1]),
                it.state.ctm.point(v[2], v[3]),
            );
        },
        K("y") => {
            const v = op.nums(4) orelse return;
            const end = it.state.ctm.point(v[2], v[3]);
            try it.builder.curveTo(it.state.ctm.point(v[0], v[1]), end, end);
        },
        K("h") => try it.builder.closePath(),
        K("re") => {
            const v = op.nums(4) orelse return;
            // Not `Builder.rect`: that one is axis-aligned in its own
            // coordinates, and a rectangle under a rotated CTM is not a
            // rectangle any more.
            const x = v[0];
            const y = v[1];
            const w = v[2];
            const h = v[3];
            try it.builder.moveTo(it.state.ctm.point(x, y));
            try it.builder.lineTo(it.state.ctm.point(x + w, y));
            try it.builder.lineTo(it.state.ctm.point(x + w, y + h));
            try it.builder.lineTo(it.state.ctm.point(x, y + h));
            try it.builder.closePath();
        },

        // -- painting --------------------------------------------------------
        K("S") => try it.paintPath(.{ .stroke = true }),
        K("s") => {
            try it.builder.closePath();
            try it.paintPath(.{ .stroke = true });
        },
        K("f"), K("F") => try it.paintPath(.{ .fill = .nonzero }),
        K("f*") => try it.paintPath(.{ .fill = .even_odd }),
        K("B") => try it.paintPath(.{ .fill = .nonzero, .stroke = true }),
        K("B*") => try it.paintPath(.{ .fill = .even_odd, .stroke = true }),
        K("b") => {
            try it.builder.closePath();
            try it.paintPath(.{ .fill = .nonzero, .stroke = true });
        },
        K("b*") => {
            try it.builder.closePath();
            try it.paintPath(.{ .fill = .even_odd, .stroke = true });
        },
        K("n") => try it.paintPath(.{}),

        // -- clipping --------------------------------------------------------
        K("W") => it.pending_clip = .nonzero,
        K("W*") => it.pending_clip = .even_odd,

        // -- colour ----------------------------------------------------------
        K("CS") => try it.setSpace(op, resources, .stroke),
        K("cs") => try it.setSpace(op, resources, .fill),
        K("SC"), K("SCN") => try it.setColor(op, resources, .stroke),
        K("sc"), K("scn") => try it.setColor(op, resources, .fill),
        K("G") => it.setDevice(op, .stroke, .device_gray),
        K("g") => it.setDevice(op, .fill, .device_gray),
        K("RG") => it.setDevice(op, .stroke, .device_rgb),
        K("rg") => it.setDevice(op, .fill, .device_rgb),
        K("K") => it.setDevice(op, .stroke, .device_cmyk),
        K("k") => it.setDevice(op, .fill, .device_cmyk),

        // -- text ------------------------------------------------------------
        K("BT") => {
            it.tm = .identity;
            it.tlm = .identity;
            it.in_text = true;
            it.text_clip.clearRetainingCapacity();
        },
        K("ET") => try it.endText(),
        // Every text-state number is guarded: an infinity in `Tz` or `Ts`
        // turns the run matrix into NaNs, and a page whose text has NaN
        // coordinates is a page a rasteriser cannot even reject cleanly.
        K("Tc") => it.state.char_spacing = finite(op.num() orelse return, 0),
        K("Tw") => it.state.word_spacing = finite(op.num() orelse return, 0),
        K("Tz") => it.state.horizontal_scale = finite(op.num() orelse return, 100) / 100.0,
        K("TL") => it.state.leading = finite(op.num() orelse return, 0),
        K("Ts") => it.state.rise = finite(op.num() orelse return, 0),
        K("Tr") => it.state.render_mode = .fromInt(@intFromFloat(std.math.clamp(op.num() orelse return, 0, 7))),
        K("Tf") => try it.selectFont(op, resources),
        K("Td") => {
            const v = op.nums(2) orelse return;
            it.tlm = Matrix.translation(v[0], v[1]).concat(it.tlm);
            it.tm = it.tlm;
        },
        K("TD") => {
            const v = op.nums(2) orelse return;
            it.state.leading = -v[1];
            it.tlm = Matrix.translation(v[0], v[1]).concat(it.tlm);
            it.tm = it.tlm;
        },
        K("Tm") => {
            const v = op.nums(6) orelse return;
            it.tlm = .fromOperands(v);
            it.tm = it.tlm;
        },
        K("T*") => it.nextLine(),
        K("Tj") => {
            const s = (op.last() orelse return).asString() orelse return;
            try it.showText(s, resources, depth);
        },
        K("TJ") => {
            const items = (op.last() orelse return).asArray() orelse return;
            try it.showArray(items, resources, depth);
        },
        K("'") => {
            const s = (op.last() orelse return).asString() orelse return;
            it.nextLine();
            try it.showText(s, resources, depth);
        },
        K("\"") => {
            const s = (op.last() orelse return).asString() orelse return;
            if (op.operands.len >= 3) {
                it.state.word_spacing = op.operands[op.operands.len - 3].asNumber() orelse it.state.word_spacing;
                it.state.char_spacing = op.operands[op.operands.len - 2].asNumber() orelse it.state.char_spacing;
            }
            it.nextLine();
            try it.showText(s, resources, depth);
        },
        // Type 3 glyph metrics. `d0` says the width; `d1` says the width and
        // a bounding box and forbids colour. Both are consumed by the caller
        // that set up the glyph, and neither draws anything.
        K("d0"), K("d1") => {},

        // -- XObjects and shadings -------------------------------------------
        K("Do") => try it.doXObject(op.nameOperand() orelse return, resources, depth),
        K("sh") => try it.shadingOperator(op.nameOperand() orelse return, resources),

        // -- marked content ---------------------------------------------------
        // `BDC` is `/tag properties BDC`, and the properties are often a name
        // too, so the tag is the *first* operand rather than the last one --
        // the only operator in the language where that is true.
        K("BMC"), K("BDC") => try it.builder.beginMarked(markedTag(op)),
        K("EMC") => try it.builder.endMarked(),
        // Marked points carry no region and nothing paints them.
        K("MP"), K("DP") => {},

        // -- compatibility ----------------------------------------------------
        // `BX`/`EX` bracket operators a later version might define. Unknown
        // operators are already ignored, so the brackets themselves are the
        // whole implementation.
        K("BX"), K("EX") => {},

        else => it.diag.noteUnknown(op.name),
    }
}

/// Replaces a non-finite operand with a default. PDF producers emit `nan`
/// and `inf` more often than seems possible, usually from a division in a
/// layout engine that nobody checked.
fn finite(v: f64, fallback: f64) f64 {
    return if (std.math.isFinite(v)) v else fallback;
}

fn markedTag(op: Scanner.Op) []const u8 {
    for (op.operands) |o| {
        if (o.asName()) |n| return n;
    }
    return "";
}

fn capOf(v: f64) paint.Cap {
    return switch (@as(i64, @intFromFloat(std.math.clamp(v, 0, 2)))) {
        1 => .round,
        2 => .square,
        else => .butt,
    };
}

fn joinOf(v: f64) paint.Join {
    return switch (@as(i64, @intFromFloat(std.math.clamp(v, 0, 2)))) {
        1 => .round,
        2 => .bevel,
        else => .miter,
    };
}

fn setDash(it: *Interpreter, op: Scanner.Op) Error!void {
    if (op.operands.len < 2) return;
    const array = op.operands[op.operands.len - 2].asArray() orelse return;
    const phase = op.operands[op.operands.len - 1].asNumber() orelse 0;

    var pattern: [32]f32 = undefined;
    const n = @min(array.len, pattern.len);
    for (0..n) |i| pattern[i] = @floatCast(array[i].asNumber() orelse 0);

    it.state.line.dash = try it.builder.dash(pattern[0..n]);
    it.state.line.dash_phase = @floatCast(phase);
}

// -- painting ---------------------------------------------------------------

const PaintKind = struct {
    fill: ?FillRule = null,
    stroke: bool = false,
};

fn paintPath(it: *Interpreter, what: PaintKind) Error!void {
    // Taken before the paint, used after it: `W f` fills unclipped and *then*
    // establishes the clip.
    const clip_path = if (it.pending_clip != null and it.builder.hasPath())
        it.builder.currentPath()
    else
        null;

    const fill_paint = withAlpha(it.state.fill, it.state.fill_alpha);
    const stroke_paint = withAlpha(it.state.stroke, it.state.stroke_alpha);

    if (what.fill != null and what.stroke) {
        try it.builder.fillThenStroke(
            what.fill.?,
            fill_paint,
            it.state.line,
            stroke_paint,
            it.state.ctm.toTransform(),
        );
    } else if (what.fill) |rule| {
        try it.builder.fill(rule, fill_paint);
    } else if (what.stroke) {
        try it.builder.stroke(it.state.line, stroke_paint, it.state.ctm.toTransform());
    } else {
        it.builder.endPath();
    }

    if (it.pending_clip) |rule| {
        // A `W n` with no path clips everything away, which is what an empty
        // path range means to a backend.
        try it.builder.pushClipPath(clip_path orelse .{}, rule);
        it.pending_clip = null;
    }
}

/// Folds the constant alpha into the paint, per `paint.Layer`'s note: `/ca`
/// and `/CA` are per-object constants, not group parameters, and a backend
/// that gets them as part of the colour needs no extra state.
fn withAlpha(p: Paint, alpha: f32) Paint {
    if (alpha >= 1) return p;
    return switch (p) {
        .solid => |c| .{ .solid = c.withAlpha(c.a * alpha) },
        // A shading or a tiling pattern carries its alpha in the layer the
        // backend opens for it; approximating it here would double-apply.
        else => p,
    };
}

// -- colour -----------------------------------------------------------------

const Which = enum { fill, stroke };

fn setDevice(it: *Interpreter, op: Scanner.Op, which: Which, space: ColorSpace) void {
    var comps: [color.max_components]f64 = undefined;
    const n = space.components;
    if (op.operands.len < n) return;
    for (0..n) |i| {
        comps[i] = op.operands[op.operands.len - n + i].asNumber() orelse 0;
    }

    const c = space.toColor(comps[0..n]);
    switch (which) {
        .fill => {
            it.state.fill_space = space;
            it.state.fill = .{ .solid = c };
        },
        .stroke => {
            it.state.stroke_space = space;
            it.state.stroke = .{ .solid = c };
        },
    }
}

fn setSpace(it: *Interpreter, op: Scanner.Op, resources: Dict, which: Which) Error!void {
    const name = op.nameOperand() orelse return;
    const space = try it.colorSpace(name, resources) orelse {
        it.diag.missing_resources += 1;
        return;
    };

    var buf: [color.max_components]f64 = undefined;
    const initial = space.initial(&buf);
    const c = space.toColor(initial);

    switch (which) {
        .fill => {
            it.state.fill_space = space;
            it.state.fill = .{ .solid = c };
        },
        .stroke => {
            it.state.stroke_space = space;
            it.state.stroke = .{ .solid = c };
        },
    }
}

fn setColor(it: *Interpreter, op: Scanner.Op, resources: Dict, which: Which) Error!void {
    const space = switch (which) {
        .fill => it.state.fill_space,
        .stroke => it.state.stroke_space,
    };

    if (space.isPattern()) {
        const name = op.nameOperand() orelse return;
        const p = try it.patternPaint(name, resources) orelse {
            it.diag.missing_resources += 1;
            return;
        };
        switch (which) {
            .fill => it.state.fill = p,
            .stroke => it.state.stroke = p,
        }
        return;
    }

    var comps: [color.max_components]f64 = undefined;
    const n = @min(space.components, color.max_components);
    if (op.operands.len < n) return;
    for (0..n) |i| {
        comps[i] = op.operands[op.operands.len - n + i].asNumber() orelse 0;
    }

    const c = space.toColor(comps[0..n]);
    switch (which) {
        .fill => it.state.fill = .{ .solid = c },
        .stroke => it.state.stroke = .{ .solid = c },
    }
}

/// Looks up a colour space by resource name, caching by object number when
/// the resource is an indirect reference -- which it is for every space worth
/// caching, because a `/Separation` is an array with a function stream in it.
fn colorSpace(it: *Interpreter, name: []const u8, resources: Dict) Error!?ColorSpace {
    if (color.load(it.arena(), it.doc, .{ .name = name }, null, 0) catch null) |device| {
        return device;
    }

    const table = try it.doc.get(resources, "ColorSpace") orelse return null;
    const dict = table.asDict() orelse return null;
    const raw = dict.get(name) orelse return null;

    if (raw.asRef()) |ref| {
        if (it.space_cache.get(ref.num)) |cached| return cached;
        const loaded = try color.load(it.arena(), it.doc, raw, resources, 0) orelse return null;
        try it.space_cache.put(it.gpa, ref.num, loaded);
        return loaded;
    }
    return try color.load(it.arena(), it.doc, raw, resources, 0);
}

fn patternPaint(it: *Interpreter, name: []const u8, resources: Dict) Error!?Paint {
    const table = try it.doc.get(resources, "Pattern") orelse return null;
    const dict = table.asDict() orelse return null;
    const raw = dict.get(name) orelse return null;
    const ref = if (raw.asRef()) |r| r.num else paint.no_object;

    const resolved = try it.doc.resolve(raw);
    const pattern_dict = resolved.asDict() orelse return null;

    const kind = if (try it.doc.get(pattern_dict, "PatternType")) |v| v.asInt() orelse 1 else 1;

    // Pattern space is measured from the page's own coordinate system, not
    // from wherever the CTM has been pushed to (§8.7.3.1). Getting this wrong
    // makes every pattern slide with the object it fills.
    var m: Matrix = it.base_ctm;
    if (try it.doc.get(pattern_dict, "Matrix")) |v| {
        if (v.asArray()) |a| {
            if (a.len >= 6) {
                var raw_matrix: [6]f64 = undefined;
                for (&raw_matrix, a[0..6]) |*slot, entry| {
                    slot.* = (try it.doc.resolve(entry)).asNumber() orelse 0;
                }
                m = Matrix.fromOperands(raw_matrix).concat(it.base_ctm);
            }
        }
    }

    if (kind == 2) {
        const sh = try it.doc.get(pattern_dict, "Shading") orelse return null;
        var shading = try it.shadingOf(sh, ref);
        shading.transform = m.toTransform();
        return .{ .shading = shading };
    }

    return .{ .tiling = .{
        .object = ref,
        .transform = m.toTransform(),
        // The average colour of a tiling pattern needs the pattern's own
        // content stream, which is a second interpretation; until a backend
        // asks for one, grey is the honest placeholder.
        .approximation = .gray(0.5),
    } };
}

// -- shadings ---------------------------------------------------------------

fn shadingOperator(it: *Interpreter, name: []const u8, resources: Dict) Error!void {
    const table = try it.doc.get(resources, "Shading") orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const dict = table.asDict() orelse return;
    const raw = dict.get(name) orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const ref = if (raw.asRef()) |r| r.num else paint.no_object;

    var shading = try it.shadingOf(raw, ref);
    // `sh` paints in the current user space, unlike a shading *pattern*.
    shading.transform = it.state.ctm.toTransform();
    try it.builder.drawShading(shading);
}

/// Reads the parts of a shading dictionary that a display list carries: the
/// type, and one colour standing in for the ramp.
fn shadingOf(it: *Interpreter, obj: Object, ref: u32) Error!paint.Shading {
    const resolved = try it.doc.resolve(obj);
    const dict = resolved.asDict() orelse return .{ .object = ref };

    const kind: u8 = if (try it.doc.get(dict, "ShadingType")) |v|
        @intCast(std.math.clamp(v.asInt() orelse 0, 0, 255))
    else
        0;

    var approximation: Color = .gray(0.5);
    if (try it.doc.get(dict, "ColorSpace")) |cs_obj| {
        if (try color.load(it.arena(), it.doc, cs_obj, null, 0)) |space| {
            if (try it.doc.get(dict, "Function")) |fn_obj| {
                if (try function.loadCombined(it.arena(), it.doc, fn_obj, 0)) |fns| {
                    // The midpoint of the ramp: a single colour that is wrong
                    // everywhere and badly wrong nowhere, which is exactly
                    // what a placeholder should be.
                    var comps: [color.max_components]f64 = @splat(0);
                    const n = @min(space.components, color.max_components);
                    const produced = function.evalCombinedOne(fns, 0.5, comps[0..n]);
                    approximation = space.toColor(produced);
                }
            }
        }
    }

    return .{
        .object = ref,
        .kind = kind,
        .transform = it.state.ctm.toTransform(),
        .approximation = approximation,
    };
}

// -- ExtGState --------------------------------------------------------------

fn extGState(it: *Interpreter, name: []const u8, resources: Dict) Error!void {
    const table = try it.doc.get(resources, "ExtGState") orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const dict = table.asDict() orelse return;
    const entry = try it.doc.get(dict, name) orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const gs = entry.asDict() orelse return;

    if (try it.doc.get(gs, "LW")) |v| {
        it.state.line.width = @floatCast(@max(v.asNumber() orelse 1, 0));
    }
    if (try it.doc.get(gs, "LC")) |v| it.state.line.cap = capOf(v.asNumber() orelse 0);
    if (try it.doc.get(gs, "LJ")) |v| it.state.line.join = joinOf(v.asNumber() orelse 0);
    if (try it.doc.get(gs, "ML")) |v| it.state.line.miter_limit = @floatCast(v.asNumber() orelse 10);
    if (try it.doc.get(gs, "CA")) |v| {
        it.state.stroke_alpha = @floatCast(std.math.clamp(v.asNumber() orelse 1, 0, 1));
    }
    if (try it.doc.get(gs, "ca")) |v| {
        it.state.fill_alpha = @floatCast(std.math.clamp(v.asNumber() orelse 1, 0, 1));
    }
    if (try it.doc.get(gs, "BM")) |v| {
        it.state.blend = switch (v) {
            .name => |n| .fromName(n),
            // An array of names is a preference list; the first one we know
            // wins, and `Normal` is what an unknown name means anyway.
            .array => |a| if (a.len != 0 and a[0].asName() != null)
                .fromName(a[0].asName().?)
            else
                .normal,
            else => .normal,
        };
    }
    if (try it.doc.get(gs, "D")) |v| {
        if (v.asArray()) |a| {
            if (a.len >= 2) {
                if ((try it.doc.resolve(a[0])).asArray()) |entries| {
                    var pattern: [32]f32 = undefined;
                    const n = @min(entries.len, pattern.len);
                    for (0..n) |i| {
                        pattern[i] = @floatCast((try it.doc.resolve(entries[i])).asNumber() orelse 0);
                    }
                    it.state.line.dash = try it.builder.dash(pattern[0..n]);
                    it.state.line.dash_phase = @floatCast((try it.doc.resolve(a[1])).asNumber() orelse 0);
                }
            }
        }
    }
    if (gs.get("SMask")) |raw| {
        const resolved = try it.doc.resolve(raw);
        it.state.soft_mask = switch (resolved) {
            .name => paint.no_object, // `/None`
            .dict => |d| if (d.get("G")) |g| (if (g.asRef()) |r| r.num else paint.no_object) else paint.no_object,
            else => paint.no_object,
        };
    }
    if (try it.doc.get(gs, "Font")) |v| {
        if (v.asArray()) |a| {
            if (a.len >= 2) {
                const font_ref = if (a[0].asRef()) |r| r.num else 0;
                const font_dict = (try it.doc.resolve(a[0])).asDict();
                if (font_dict) |d| {
                    it.state.font = try it.internFont(d, font_ref, "");
                    it.state.font_size = (try it.doc.resolve(a[1])).asNumber() orelse 0;
                }
            }
        }
    }
}

// -- text -------------------------------------------------------------------

fn nextLine(it: *Interpreter) void {
    it.tlm = Matrix.translation(0, -it.state.leading).concat(it.tlm);
    it.tm = it.tlm;
}

fn selectFont(it: *Interpreter, op: Scanner.Op, resources: Dict) Error!void {
    it.state.font_size = finite(op.num() orelse 0, 0);

    const name = op.nameOperand() orelse return;
    const table = try it.doc.get(resources, "Font") orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const dict = table.asDict() orelse return;
    const raw = dict.get(name) orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const ref = if (raw.asRef()) |r| r.num else 0;
    const font_dict = (try it.doc.resolve(raw)).asDict() orelse {
        it.diag.missing_resources += 1;
        return;
    };

    it.state.font = try it.internFont(font_dict, ref, name);
}

/// Adds a font to both tables at once. The builder interns by object number,
/// and this keeps `fonts` in lockstep so a `FontId` indexes both.
fn internFont(it: *Interpreter, dict: Dict, ref: u32, name: []const u8) Error!usize {
    if (ref != 0) {
        if (it.font_cache.get(ref)) |index| return index;
    }

    const font = try Font.load(it.arena(), it.doc, dict, ref);
    const id = try it.builder.fontId(ref, name, font.base_font, font.kind == .composite);

    // What the codes mean, recorded once per font rather than once per glyph.
    // Resolved here and not by whoever extracts the text, because the chain
    // behind it -- `/ToUnicode`, `/Differences`, `/BaseEncoding` -- is four
    // entries of a dictionary that only this layer can still see.
    const meaning = try font.unicodeSpans(it.arena());
    try it.builder.fontUnicode(id, meaning.spans, meaning.text);

    // `fontId` reuses an entry when the object matches, so the two tables can
    // only diverge if a font is interned twice under different names.
    if (id == it.fonts.items.len) {
        try it.fonts.append(it.gpa, font);
    } else if (id < it.fonts.items.len) {
        it.fonts.items[id] = font;
    }

    if (ref != 0) try it.font_cache.put(it.gpa, ref, id);
    return id;
}

fn showArray(it: *Interpreter, items: []const Object, resources: Dict, depth: u8) Error!void {
    for (items) |entry| {
        switch (entry) {
            .string => |s| try it.showText(s, resources, depth),
            .integer, .real => {
                const adjust = entry.asNumber() orelse 0;
                // Thousandths of text space, and it moves the cursor *back*.
                // The horizontal scale belongs to the matrix, not here.
                const tx = -adjust / 1000.0 * it.state.font_size * it.state.horizontal_scale;
                it.tm = Matrix.translation(tx, 0).concat(it.tm);
            },
            else => {},
        }
    }
}

/// Shows one string: the heart of §9.4.4.
///
/// Glyph offsets accumulate in a text space that excludes `Tz`, because
/// horizontal scaling stretches the glyph shapes as well as the gaps between
/// them and therefore belongs in the run's matrix. The text matrix, which
/// measures real distance, gets the scaled total.
fn showText(it: *Interpreter, bytes: []const u8, resources: Dict, depth: u8) Error!void {
    if (bytes.len == 0) return;

    const font_index = it.state.font orelse {
        it.diag.text_without_font += 1;
        return;
    };
    if (font_index >= it.fonts.items.len) return;

    // By value, not by pointer. A Type 3 glyph procedure is a content stream
    // and may contain its own `Tf`, which interns a font and can grow
    // `it.fonts` -- reallocating it out from under a borrow held across the
    // loop below. Copying is a hundred and fifty bytes once per string.
    const font = it.fonts.items[font_index];

    const size = it.state.font_size;
    const scale = it.state.horizontal_scale;

    // Text space to page space, with `Tz` and `Ts` folded in and the font
    // size deliberately left out: `TextRun.size` carries it, so a backend
    // scales glyph outlines by one number.
    const run_matrix = (Matrix{ .a = scale, .d = 1, .f = it.state.rise })
        .concat(it.tm)
        .concat(it.state.ctm);

    it.glyph_buf.clearRetainingCapacity();
    var offset: f64 = 0;

    var i: usize = 0;
    while (i < bytes.len) {
        const code = font.decode(bytes, i);
        i += code.len;

        const advance = font.advance(code) * size;
        const spacing = it.state.char_spacing +
            (if (font.isWordSpace(code)) it.state.word_spacing else 0);

        if (font.kind == .type3) {
            if (it.options.type3) {
                try it.drawType3Glyph(font, code.code, offset, run_matrix, resources, depth);
            }
        } else {
            try it.glyph_buf.append(it.gpa, .{
                .code = code.code,
                .offset = .{ .x = @floatCast(offset), .y = 0 },
            });
            if (it.state.render_mode.clips()) {
                try it.noteTextClip(run_matrix, offset, advance, size);
            }
        }

        offset += advance + spacing;
    }

    if (font.kind != .type3 and it.glyph_buf.items.len != 0) {
        try it.builder.textRun(.{
            .font = @intCast(font_index),
            .transform = run_matrix.toTransform(),
            .size = @floatCast(size),
            .mode = it.state.render_mode,
            .fill = withAlpha(it.state.fill, it.state.fill_alpha),
            .stroke = if (it.state.render_mode.strokes()) it.state.line else null,
            // Before `Tz`, like the glyph offsets beside it: this is where
            // the pen stands after the last glyph, which is the only width
            // that glyph can be given.
            .advance = @floatCast(offset),
        }, it.glyph_buf.items);
    }

    // The text matrix moves by the scaled total, which is the one place the
    // horizontal scale is a distance rather than a shape.
    it.tm = Matrix.translation(offset * scale, 0).concat(it.tm);
}

/// Records one glyph's box for a clipping render mode (`Tr 4`..`Tr 7`).
///
/// This is an approximation, and the only one in the interpreter that changes
/// what a page looks like rather than what colour it is. Real text clipping
/// needs glyph outlines, which live in Týr. A box per glyph is coarser than
/// the outline and *larger* than it, so a document that clips an image to
/// display text shows a little too much image rather than none of it -- which
/// is the failure to prefer, since the alternative is a blank region.
fn noteTextClip(it: *Interpreter, placed: Matrix, offset: f64, advance: f64, size: f64) Error!void {
    // Rough typographic extents: most fonts sit inside them, and the ones
    // that do not are decorative.
    const top = 0.75 * size;
    const bottom = -0.25 * size;
    const x0 = offset;
    const x1 = offset + advance;

    try it.text_clip.append(it.gpa, .{
        placed.point(x0, bottom),
        placed.point(x1, bottom),
        placed.point(x1, top),
        placed.point(x0, top),
    });
}

fn endText(it: *Interpreter) Error!void {
    // A stray `ET` with no `BT` would otherwise push a clip built from
    // whatever the last text object left behind.
    if (!it.in_text) return;
    it.in_text = false;
    if (it.text_clip.items.len == 0) return;

    for (it.text_clip.items) |quad| {
        try it.builder.moveTo(quad[0]);
        try it.builder.lineTo(quad[1]);
        try it.builder.lineTo(quad[2]);
        try it.builder.lineTo(quad[3]);
        try it.builder.closePath();
    }
    // The clip stays until the enclosing `Q`, which the depth-based restore
    // in `Q` already handles.
    try it.builder.pushClip(.nonzero);
    it.text_clip.clearRetainingCapacity();
}

/// Runs one Type 3 glyph procedure.
///
/// A Type 3 glyph *is* a content stream, so this is the interpreter calling
/// itself with the glyph's matrix pushed onto the CTM. No text run is
/// recorded: the glyph's own operators draw it, and recording both would
/// paint it twice.
fn drawType3Glyph(
    it: *Interpreter,
    font: Font,
    code: u32,
    offset: f64,
    placed: Matrix,
    resources: Dict,
    depth: u8,
) Error!void {
    if (depth >= it.options.max_depth) return;
    const procs = font.char_procs orelse return;
    const name = font.glyphName(code) orelse return;

    const raw = procs.get(name) orelse return;
    const ref = if (raw.asRef()) |r| r.num else 0;
    if (ref != 0 and it.isActive(ref)) {
        it.diag.recursive_forms += 1;
        return;
    }

    const glyph_stream = (try it.doc.resolve(raw)).asStream() orelse return;
    const data = (try it.doc.streamData(glyph_stream)).data;

    const saved = it.state;
    const saved_clip = it.builder.clip_depth;
    const saved_tm = it.tm;
    const saved_tlm = it.tlm;
    // A glyph procedure may open a text object of its own, and the outer one
    // is still running.
    const saved_in_text = it.in_text;
    const saved_clip_boxes = it.text_clip.items.len;

    // Glyph space -> text space -> page space, with the font size and the
    // glyph's own position along the run applied in between.
    const placement = Matrix{
        .a = it.state.font_size,
        .d = it.state.font_size,
        .e = offset,
    };
    it.state.ctm = font.font_matrix.concat(placement).concat(placed);

    if (ref != 0) try it.active.append(it.gpa, ref);
    defer if (ref != 0) {
        _ = it.active.pop();
    };

    const glyph_resources = font.resources orelse resources;
    try it.execute(data, glyph_resources, depth + 1);

    while (it.builder.clip_depth > saved_clip) try it.builder.popClip();
    it.state = saved;
    it.tm = saved_tm;
    it.tlm = saved_tlm;
    it.in_text = saved_in_text;
    it.text_clip.shrinkRetainingCapacity(@min(saved_clip_boxes, it.text_clip.items.len));
    it.pending_clip = null;
}

// -- XObjects ---------------------------------------------------------------

fn isActive(it: *const Interpreter, ref: u32) bool {
    for (it.active.items) |n| {
        if (n == ref) return true;
    }
    return false;
}

fn doXObject(it: *Interpreter, name: []const u8, resources: Dict, depth: u8) Error!void {
    const table = try it.doc.get(resources, "XObject") orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const dict = table.asDict() orelse return;
    const raw = dict.get(name) orelse {
        it.diag.missing_resources += 1;
        return;
    };
    const ref = if (raw.asRef()) |r| r.num else 0;

    const resolved = try it.doc.resolve(raw);
    const xobject = resolved.asStream() orelse {
        it.diag.missing_resources += 1;
        return;
    };

    const subtype = if (try it.doc.get(xobject.dict, "Subtype")) |v| v.asName() orelse "" else "";

    if (std.mem.eql(u8, subtype, "Image")) {
        return it.drawImage(xobject.dict, ref, name);
    }
    if (std.mem.eql(u8, subtype, "Form")) {
        return it.drawForm(xobject, ref, resources, depth);
    }
    // `/PS`, the PostScript XObject: obsolete since PDF 1.0 and defined to be
    // ignored by everything that is not a PostScript printer.
}

fn drawImage(it: *Interpreter, dict: Dict, ref: u32, name: []const u8) Error!void {
    const width = if (try it.doc.get(dict, "Width")) |v| v.asInt() orelse 0 else 0;
    const height = if (try it.doc.get(dict, "Height")) |v| v.asInt() orelse 0 else 0;
    if (width <= 0 or height <= 0) return;

    const is_mask = if (try it.doc.get(dict, "ImageMask")) |v| v.asBool() orelse false else false;
    const interpolate = if (try it.doc.get(dict, "Interpolate")) |v| v.asBool() orelse false else false;

    it.diag.images_drawn += 1;
    try it.builder.drawImage(.{
        .object = ref,
        .name = try it.builder.intern(name),
        .width = @intCast(@min(width, std.math.maxInt(u32))),
        .height = @intCast(@min(height, std.math.maxInt(u32))),
        // Every image is mapped into the unit square and placed entirely by
        // the CTM (§8.9.5), which is why this is the whole geometry.
        .transform = it.state.ctm.toTransform(),
        .is_mask = is_mask,
        .fill = withAlpha(it.state.fill, it.state.fill_alpha),
        .interpolate = interpolate,
    });
}

fn drawForm(
    it: *Interpreter,
    form: *const object.Stream,
    ref: u32,
    parent_resources: Dict,
    depth: u8,
) Error!void {
    if (depth >= it.options.max_depth) return;
    if (ref != 0 and it.isActive(ref)) {
        it.diag.recursive_forms += 1;
        return;
    }

    const saved = it.state;
    const saved_clip = it.builder.clip_depth;
    const saved_stack = it.stack.items.len;

    if (try it.doc.get(form.dict, "Matrix")) |v| {
        if (v.asArray()) |a| {
            if (a.len >= 6) {
                var m: [6]f64 = undefined;
                for (&m, a[0..6]) |*slot, entry| {
                    slot.* = (try it.doc.resolve(entry)).asNumber() orelse 0;
                }
                it.state.ctm = Matrix.fromOperands(m).concat(it.state.ctm);
            }
        }
    }

    // `/BBox` is a hard clip, not a hint: content outside it is not drawn
    // (§8.10.2). Files rely on this to crop the artwork they reuse.
    if (try it.doc.get(form.dict, "BBox")) |v| {
        if (v.asArray()) |a| {
            if (a.len >= 4) {
                var box: [4]f64 = undefined;
                for (&box, a[0..4]) |*slot, entry| {
                    slot.* = (try it.doc.resolve(entry)).asNumber() orelse 0;
                }
                const x0 = @min(box[0], box[2]);
                const y0 = @min(box[1], box[3]);
                const x1 = @max(box[0], box[2]);
                const y1 = @max(box[1], box[3]);
                try it.builder.moveTo(it.state.ctm.point(x0, y0));
                try it.builder.lineTo(it.state.ctm.point(x1, y0));
                try it.builder.lineTo(it.state.ctm.point(x1, y1));
                try it.builder.lineTo(it.state.ctm.point(x0, y1));
                try it.builder.closePath();
                try it.builder.pushClip(.nonzero);
            }
        }
    }

    // A transparency group composites as a unit: the alpha and blend mode at
    // the `Do` apply to the group's result, and reset to their defaults
    // inside it (§11.6.6).
    const group = try it.doc.get(form.dict, "Group");
    const is_transparency = if (group) |g| blk: {
        const d = g.asDict() orelse break :blk false;
        const s = try it.doc.get(d, "S") orelse break :blk false;
        break :blk s.isName("Transparency");
    } else false;

    if (is_transparency) {
        const d = group.?.asDict().?;
        try it.builder.pushLayer(.{
            .alpha = it.state.fill_alpha,
            .blend = it.state.blend,
            .soft_mask = it.state.soft_mask,
            .isolated = if (try it.doc.get(d, "I")) |v| v.asBool() orelse false else false,
            .knockout = if (try it.doc.get(d, "K")) |v| v.asBool() orelse false else false,
        });
        it.state.fill_alpha = 1;
        it.state.stroke_alpha = 1;
        it.state.blend = .normal;
        it.state.soft_mask = paint.no_object;
    }

    const own = if (try it.doc.get(form.dict, "Resources")) |v| v.asDict() else null;
    const resources = own orelse parent_resources;

    if (ref != 0) try it.active.append(it.gpa, ref);
    const data = (try it.doc.streamData(form)).data;
    it.diag.forms_drawn += 1;

    try it.execute(data, resources, depth + 1);

    if (ref != 0) _ = it.active.pop();

    if (is_transparency) try it.builder.popLayer();

    // A form that ends with unbalanced `q` must not leak state into the page
    // that drew it, which is a real failure mode: one bad form otherwise
    // shifts everything after it.
    it.stack.shrinkRetainingCapacity(@min(saved_stack, it.stack.items.len));
    while (it.builder.clip_depth > saved_clip) try it.builder.popClip();
    it.state = saved;
    it.builder.endPath();
    // A stream that ends on a dangling `W` would otherwise clip the first
    // thing the page paints after the form.
    it.pending_clip = null;
}

// -- annotations ------------------------------------------------------------

/// Reads a fixed-length array of numbers, resolving each entry. Null when the
/// key is absent, is not an array, is too short, or holds something that is
/// not a number -- all of which mean the same thing to every caller here:
/// there is nothing to place, so do not place it wrongly.
fn readNumbers(it: *Interpreter, dict: Dict, key: []const u8, comptime n: usize) Error!?[n]f64 {
    const v = try it.doc.get(dict, key) orelse return null;
    const a = v.asArray() orelse return null;
    if (a.len < n) return null;
    var out: [n]f64 = undefined;
    for (&out, a[0..n]) |*slot, entry| {
        slot.* = (try it.doc.resolve(entry)).asNumber() orelse return null;
    }
    return out;
}

/// Draws the page's annotations, in file order, after its content.
///
/// An annotation is not in the content stream. It is a dictionary beside the
/// page holding a rectangle and a form XObject -- its *appearance stream* --
/// to draw into that rectangle. A highlight, a stamp, a filled-in form field,
/// an ink scribble and a signature are all annotations and nothing else, so a
/// renderer that draws only the content stream produces a page with every
/// mark a person added to it stripped off. That failure is invisible: the
/// result is not a broken page, it is a clean one.
///
/// One bad annotation does not stop the rest. They are independent objects
/// added at different times by different tools, and the odds that all of them
/// parse are worse than the odds that any one does.
fn drawAnnotations(it: *Interpreter, annots: []const Object, resources: Dict, base: Matrix) Error!void {
    for (annots) |raw| {
        const resolved = it.doc.resolve(raw) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                it.diag.annotations_skipped += 1;
                continue;
            },
        };
        const annot = resolved.asDict() orelse {
            it.diag.annotations_skipped += 1;
            continue;
        };
        const drawn = it.drawAnnotation(annot, resources, base) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => false,
        };
        if (drawn) it.diag.annotations_drawn += 1 else it.diag.annotations_skipped += 1;
    }
}

/// One annotation. Returns whether anything was drawn.
fn drawAnnotation(it: *Interpreter, annot: Dict, page_resources: Dict, base: Matrix) Error!bool {
    // A popup is the note *window*, shown only while the note is open in a
    // viewer that has one. It is never part of the page.
    if (try it.doc.get(annot, "Subtype")) |v| {
        if (v.isName("Popup")) return false;
    }

    // §12.5.3. Bit 2 hides it everywhere; bit 6 hides it on screen and prints
    // it, which is how a "print only" watermark is written.
    const flags = if (try it.doc.get(annot, "F")) |v| v.asInt() orelse 0 else 0;
    if (flags & (1 << 1) != 0) return false;
    if (flags & (1 << 5) != 0) return false;

    const rect = (try it.readNumbers(annot, "Rect", 4)) orelse return false;
    const rx0 = @min(rect[0], rect[2]);
    const ry0 = @min(rect[1], rect[3]);
    const rx1 = @max(rect[0], rect[2]);
    const ry1 = @max(rect[1], rect[3]);

    const ap = (try it.doc.get(annot, "AP")) orelse return false;
    const ap_dict = ap.asDict() orelse return false;
    var chosen = ap_dict.get("N") orelse return false;

    // `/N` is either the appearance itself or a dictionary of them keyed by
    // appearance state -- a checkbox carries `/Off` and `/Yes` -- and `/AS`
    // says which is current. A sub-dictionary with exactly one entry and no
    // `/AS` is unambiguous whatever the file forgot to say.
    const normal = try it.doc.resolve(chosen);
    if (normal.asStream() == null) {
        const states = normal.asDict() orelse return false;
        if (try it.doc.get(annot, "AS")) |as| {
            chosen = states.get(as.asName() orelse return false) orelse return false;
        } else if (states.count() == 1) {
            chosen = states.values()[0];
        } else return false;
    }

    const form_ref = if (chosen.asRef()) |r| r.num else 0;
    const form = (try it.doc.resolve(chosen)).asStream() orelse return false;

    const box = (try it.readNumbers(form.dict, "BBox", 4)) orelse return false;
    const m: Matrix = if (try it.readNumbers(form.dict, "Matrix", 6)) |v|
        .fromOperands(v)
    else
        .identity;

    // §12.5.5, and the two steps are not interchangeable: map the four
    // corners of `/BBox` through `/Matrix`, take the bounding box of *those*,
    // and fit that to `/Rect`. Fitting the BBox itself would put the corners
    // of a rotated appearance outside the rectangle the file promised it
    // would stay inside.
    const bx0 = @min(box[0], box[2]);
    const by0 = @min(box[1], box[3]);
    const bx1 = @max(box[0], box[2]);
    const by1 = @max(box[1], box[3]);

    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    for ([4][2]f64{ .{ bx0, by0 }, .{ bx1, by0 }, .{ bx1, by1 }, .{ bx0, by1 } }) |corner| {
        const p = m.apply(corner[0], corner[1]);
        min_x = @min(min_x, p[0]);
        min_y = @min(min_y, p[1]);
        max_x = @max(max_x, p[0]);
        max_y = @max(max_y, p[1]);
    }
    if (!std.math.isFinite(min_x) or !std.math.isFinite(max_y)) return false;

    // A degenerate box scales by one rather than by infinity. The spec says
    // as much for a zero-area BBox, and it is also the only answer that does
    // not put NaN into the display list.
    const w = max_x - min_x;
    const h = max_y - min_y;
    const sx = if (w > 0) (rx1 - rx0) / w else 1;
    const sy = if (h > 0) (ry1 - ry0) / h else 1;
    const fit: Matrix = Matrix.scaling(sx, sy).concat(
        .translation(rx0 - min_x * sx, ry0 - min_y * sy),
    );

    // A fresh state, not the one the content stream happened to end on: an
    // annotation is the page's peer, and inherits its clip, colour and font
    // from nothing.
    const saved = it.state;
    defer it.state = saved;
    it.state = .{ .ctm = fit.concat(base) };

    // `drawForm` applies `/Matrix` and clips to `/BBox` itself, which is
    // exactly the rest of §12.5.5 -- so the appearance stream goes through
    // the same path a form XObject does, and inherits its recursion guard,
    // its transparency-group handling and its state restoration with it.
    try it.drawForm(form, form_ref, page_resources, 0);
    return true;
}

// -- inline images ----------------------------------------------------------

/// Records a `BI ... ID ... EI`, samples and all.
///
/// The data is decoded here rather than handed on encoded, because the
/// display list has no document to decode it against later. See
/// `DisplayList.Image.data`.
fn inlineImage(it: *Interpreter, img: Scanner.InlineImage, resources: Dict) Error!void {
    it.diag.inline_images += 1;

    const width = intOf(img.dict, "W", "Width") orelse return;
    const height = intOf(img.dict, "H", "Height") orelse return;
    if (width <= 0 or height <= 0) return;

    const is_mask = boolOf(img.dict, "IM", "ImageMask") orelse false;
    const interpolate = boolOf(img.dict, "I", "Interpolate") orelse false;
    const bpc: u8 = if (is_mask) 1 else blk: {
        const v = intOf(img.dict, "BPC", "BitsPerComponent") orelse 8;
        break :blk if (v >= 1 and v <= 16) @intCast(v) else 8;
    };

    var components: u8 = 1;
    if (!is_mask) {
        if (img.dict.get("CS") orelse img.dict.get("ColorSpace")) |cs| {
            const space = if (cs.asName()) |n|
                try it.colorSpace(n, resources)
            else
                try color.load(it.arena(), it.doc, cs, resources, 0);
            if (space) |s| components = @max(s.components, 1);
        }
    }

    // `/Decode [1 0]` inverts. On a stencil mask it is the difference between
    // a shape and its negative, which is why it is carried rather than
    // applied to the samples here.
    var inverted = false;
    if (img.dict.get("D") orelse img.dict.get("Decode")) |d| {
        if (d.asArray()) |a| {
            if (a.len >= 2) {
                const first = a[0].asNumber() orelse 0;
                const second = a[1].asNumber() orelse 1;
                inverted = first > second;
            }
        }
    }

    const decoded = it.decodeInline(img) catch img.data;

    try it.builder.drawImage(.{
        .object = paint.no_object,
        .name = try it.builder.intern("inline"),
        .width = @intCast(@min(width, std.math.maxInt(u32))),
        .height = @intCast(@min(height, std.math.maxInt(u32))),
        .transform = it.state.ctm.toTransform(),
        .is_mask = is_mask,
        .fill = withAlpha(it.state.fill, it.state.fill_alpha),
        .interpolate = interpolate,
        .data = try it.builder.blob(decoded),
        .bits_per_component = bpc,
        .components = components,
        .inverted = inverted,
    });
}

fn decodeInline(it: *Interpreter, img: Scanner.InlineImage) ![]const u8 {
    const names = img.dict.get("F") orelse img.dict.get("Filter") orelse return img.data;
    const parms = img.dict.get("DP") orelse img.dict.get("DecodeParms") orelse Object.null_object;

    var specs: std.ArrayList(filter.Spec) = .empty;
    switch (names) {
        .name => |n| try specs.append(it.arena(), xref.buildSpec(n, parms)),
        .array => |list| for (list, 0..) |entry, i| {
            const n = entry.asName() orelse continue;
            const parm = switch (parms) {
                .array => |pa| if (i < pa.len) pa[i] else Object.null_object,
                else => if (i == 0) parms else Object.null_object,
            };
            try specs.append(it.arena(), xref.buildSpec(n, parm));
        },
        else => return img.data,
    }

    const result = try filter.decode(it.arena(), img.data, specs.items);
    return result.data;
}

fn intOf(d: Dict, short: []const u8, long: []const u8) ?i64 {
    const entry = d.get(short) orelse d.get(long) orelse return null;
    return entry.asInt();
}

fn boolOf(d: Dict, short: []const u8, long: []const u8) ?bool {
    const entry = d.get(short) orelse d.get(long) orelse return null;
    return entry.asBool();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const trace = @import("../../gelgja/trace.zig");

/// Builds a one-page document around a content stream and interprets it.
///
/// The whole interpreter is testable this way -- no fonts, no window, no GPU
/// -- because a display list is text and a PDF is text. Every test below is a
/// page in a string literal and an assertion about the trace it produces.
fn interpret(content: []const u8, extra: []const u8) !Result {
    return interpretWith(content, extra, "", .{});
}

/// `extra` goes inside the page's `/Resources`; `objects` is appended to the
/// file body, so a test can define form XObjects, patterns and functions.
///
/// The `/Length` of a stream written here is deliberately wrong. `Parser`
/// verifies a direct length by checking that `endstream` follows, and falls
/// back to scanning when it does not -- exactly the path that real files with
/// bad lengths take. Making the tests take it too means that path is exercised
/// on every run rather than only by whatever broken file turns up.
fn interpretWith(
    content: []const u8,
    extra: []const u8,
    objects: []const u8,
    options: Options,
) !Result {
    return interpretFully(content, extra, objects, "", options);
}

/// `page_extra` is appended to the page dictionary, after `/Resources`. A key
/// repeated there replaces the earlier one, which is how a test overrides
/// `/MediaBox`.
fn interpretFully(
    content: []const u8,
    extra: []const u8,
    objects: []const u8,
    page_extra: []const u8,
    options: Options,
) !Result {
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();

    try body.writer.print(
        \\%PDF-1.7
        \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        \\2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        \\3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200]
        \\  /Resources << /Font << /F1 10 0 R >> {s} >> {s} /Contents 4 0 R >> endobj
        \\4 0 obj << /Length {d} >> stream
        \\{s}
        \\endstream endobj
        \\10 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica
        \\  /FirstChar 65 /LastChar 67 /Widths [500 500 500] >> endobj
        \\{s}
        \\trailer << /Root 1 0 R /Size 40 >>
        \\
    , .{ extra, page_extra, content.len, content, objects });

    const bytes = try testing.allocator.dupe(u8, body.written());
    var doc = try Document.open(testing.allocator, bytes);
    defer doc.deinit();

    const pages = @import("../pages.zig");
    const list = try pages.all(&doc);
    try testing.expect(list.len == 1);

    return page(testing.allocator, &doc, list[0], options);
}

fn traceOf(result: Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try trace.write(&out.writer, result.list, .{ .header = false, .indent = false });
    return out.toOwnedSlice();
}

test "a rectangle fill becomes one command with the numbers from the stream" {
    var result = try interpret("0 0 1 rg 10 20 100 50 re f", "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
    const cmd = result.list.cmds[0].fill_path;
    try testing.expectApproxEqAbs(@as(f32, 1), cmd.paint.solid.b, 1e-6);

    const bounds = result.list.pathBounds(cmd.path);
    try testing.expectApproxEqAbs(@as(f32, 10), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.min_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), bounds.width(), 1e-4);
}

test "cm transforms the points, not the display list" {
    var result = try interpret("2 0 0 2 10 10 cm 0 0 50 50 re f", "");
    defer result.deinit(testing.allocator);

    const bounds = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 10), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), bounds.width(), 1e-4);
}

test "q and Q restore the matrix" {
    var result = try interpret(
        \\q 2 0 0 2 0 0 cm 0 0 10 10 re f Q
        \\0 0 10 10 re f
    , "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.list.cmds.len);
    const scaled = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    const plain = result.list.pathBounds(result.list.cmds[1].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 20), scaled.width(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), plain.width(), 1e-4);
}

test "Q pops every clip the matching q left open" {
    var result = try interpret(
        \\q 0 0 50 50 re W n
        \\  q 0 0 10 10 re W n Q
        \\Q
        \\0 0 5 5 re f
    , "");
    defer result.deinit(testing.allocator);

    // Two pushes, two pops, then the fill -- and the fill is outside both.
    const s = result.list.stats();
    try testing.expectEqual(@as(u32, 2), s.clips);
    try testing.expect(!result.list.unbalanced);
    try testing.expectEqual(@import("../../gelgja/DisplayList.zig").DrawCmd.clip_pop, result.list.cmds[result.list.cmds.len - 2]);
}

test "a Q pops only the clips its own q opened" {
    // The inner `q`/`Q` pair sets no clip, so it must pop none -- and in
    // particular must not pop the outer one, which would leave the fill
    // unclipped. Properly nested clips hide this; only an *empty* inner pair
    // exposes it.
    var result = try interpret(
        \\q 0 0 50 50 re W n
        \\  q Q
        \\  0 0 5 5 re f
        \\Q
    , "");
    defer result.deinit(testing.allocator);

    // clip_push, fill, clip_pop -- with the fill inside the clip.
    try testing.expectEqual(@as(usize, 3), result.list.cmds.len);
    try testing.expectEqualStrings("clip_push", result.list.cmds[0].name());
    try testing.expectEqualStrings("fill_path", result.list.cmds[1].name());
    try testing.expectEqualStrings("clip_pop", result.list.cmds[2].name());
}

test "an unmatched Q is counted rather than corrupting the state" {
    var result = try interpret("Q Q 0 0 10 10 re f", "");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), result.diagnostics.stack_underflows);
    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
}

test "W f fills unclipped and then clips" {
    var result = try interpret("0 0 100 100 re W f 10 10 5 5 re f", "");
    defer result.deinit(testing.allocator);

    // fill, clip_push, fill, clip_pop: the clip arrives *after* the fill that
    // established it.
    try testing.expectEqualStrings("fill_path", result.list.cmds[0].name());
    try testing.expectEqualStrings("clip_push", result.list.cmds[1].name());
    try testing.expectEqualStrings("fill_path", result.list.cmds[2].name());
    // And it clips the same geometry that was filled.
    try testing.expectEqual(
        result.list.cmds[0].fill_path.path.verbs,
        result.list.cmds[1].clip_push.path.verbs,
    );
}

test "v and y reuse the right control point" {
    var result = try interpret("10 10 m 20 20 30 10 v f", "");
    defer result.deinit(testing.allocator);

    const path = result.list.cmds[0].fill_path.path;
    const points = result.list.pointsOf(path);
    // move, then a cubic whose first control is the current point.
    try testing.expectEqual(@as(usize, 4), points.len);
    try testing.expectApproxEqAbs(@as(f32, 10), points[1].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), points[1].y, 1e-4);
}

test "colour operators reach the paint" {
    var result = try interpret("1 0 0 RG 0 0 10 10 re S", "");
    defer result.deinit(testing.allocator);

    const stroke = result.list.cmds[0].stroke_path;
    try testing.expectApproxEqAbs(@as(f32, 1), stroke.paint.solid.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), stroke.paint.solid.g, 1e-6);
}

test "a cmyk fill converts on the way in" {
    var result = try interpret("0 0 0 1 k 0 0 10 10 re f", "");
    defer result.deinit(testing.allocator);
    const c = result.list.cmds[0].fill_path.paint.solid;
    try testing.expectApproxEqAbs(@as(f32, 0), c.r, 1e-6);
}

test "text records a run with the advances the widths array gives" {
    var result = try interpret("BT /F1 10 Tf 20 100 Td (ABC) Tj ET", "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
    const text_run = result.list.cmds[0].text;
    try testing.expectApproxEqAbs(@as(f32, 10), text_run.size, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 20), text_run.transform.e, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), text_run.transform.f, 1e-4);

    const glyphs = result.list.glyphsOf(text_run);
    try testing.expectEqual(@as(usize, 3), glyphs.len);
    try testing.expectEqual(@as(u32, 'A'), glyphs[0].code);
    // 500/1000 of a 10pt em is 5 units per glyph.
    try testing.expectApproxEqAbs(@as(f32, 0), glyphs[0].offset.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), glyphs[1].offset.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), glyphs[2].offset.x, 1e-4);
}

test "a positive TJ number pulls the next glyph back, and a negative one pushes it on" {
    // The sign catches everybody once: the number is *subtracted* from the
    // displacement, so positive kerns tighter and negative opens a gap.
    var tight = try interpret("BT /F1 10 Tf [(A) 1000 (B)] TJ ET", "");
    defer tight.deinit(testing.allocator);

    // Two runs, because each string is its own showing operation.
    try testing.expectEqual(@as(usize, 2), tight.list.cmds.len);
    // 5 units of advance from `A`, then 1000/1000 of a 10pt em back.
    try testing.expectApproxEqAbs(@as(f32, -5), tight.list.cmds[1].text.transform.e, 1e-4);

    var loose = try interpret("BT /F1 10 Tf [(A) -1000 (B)] TJ ET", "");
    defer loose.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 15), loose.list.cmds[1].text.transform.e, 1e-4);
}

test "character and word spacing both advance the cursor" {
    var plain = try interpret("BT /F1 10 Tf (AB) Tj ET", "");
    defer plain.deinit(testing.allocator);
    var spaced = try interpret("BT /F1 10 Tf 2 Tc (AB) Tj ET", "");
    defer spaced.deinit(testing.allocator);

    const a = result_offset(plain.list, 1);
    const b = result_offset(spaced.list, 1);
    try testing.expectApproxEqAbs(@as(f32, 5), a, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 7), b, 1e-4);
}

fn result_offset(list: DisplayList, glyph: usize) f32 {
    const text_run = list.cmds[0].text;
    return list.glyphsOf(text_run)[glyph].offset.x;
}

test "horizontal scaling lives in the matrix, not in the offsets" {
    var result = try interpret("BT /F1 10 Tf 50 Tz (AB) Tj ET", "");
    defer result.deinit(testing.allocator);

    const text_run = result.list.cmds[0].text;
    // The shapes are squeezed by the matrix...
    try testing.expectApproxEqAbs(@as(f32, 0.5), text_run.transform.a, 1e-6);
    // ...and the offsets stay in unscaled text space, so the two compose
    // rather than squeezing twice.
    try testing.expectApproxEqAbs(@as(f32, 5), result.list.glyphsOf(text_run)[1].offset.x, 1e-4);
}

test "T* and TD move down by the leading" {
    var result = try interpret("BT /F1 10 Tf 12 TL 10 100 Td (A) Tj T* (B) Tj ET", "");
    defer result.deinit(testing.allocator);

    const first = result.list.cmds[0].text;
    const second = result.list.cmds[1].text;
    try testing.expectApproxEqAbs(@as(f32, 100), first.transform.f, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 88), second.transform.f, 1e-4);
    // And back to the line's start, not to where the first string ended.
    try testing.expectApproxEqAbs(@as(f32, 10), second.transform.e, 1e-4);
}

test "invisible text is recorded, because a scan's OCR layer is invisible" {
    var result = try interpret("BT /F1 10 Tf 3 Tr (A) Tj ET", "");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
    try testing.expectEqual(TextRenderMode.invisible, result.list.cmds[0].text.mode);
}

test "text with no font is counted and dropped" {
    var result = try interpret("BT (A) Tj ET", "");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), result.diagnostics.text_without_font);
    try testing.expectEqual(@as(usize, 0), result.list.cmds.len);
}

test "every operator in the specification dispatches" {
    // All 73 of table A.1, with no operands: the point is not that any of them
    // draws the right thing -- the tests above do that -- but that none of
    // them falls through to the unknown branch. `ID` and `EI` are not
    // freestanding operators, so they appear only inside the `BI` at the end.
    const every =
        "q Q cm w J j M d ri i gs\n" ++
        "m l c v y h re\n" ++
        "S s f F f* B B* b b* n W W*\n" ++
        "CS cs SC SCN sc scn G g RG rg K k\n" ++
        "BT ET Tc Tw Tz TL Tf Tr Ts Td TD Tm T* Tj TJ ' \" d0 d1\n" ++
        "Do sh\n" ++
        "MP DP BMC BDC EMC BX EX\n" ++
        "BI /W 1 /H 1 /BPC 8 /CS /G ID x EI\n";

    var result = try interpret(every, "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), result.diagnostics.unknown_operators);
    try testing.expectEqual(@as(u8, 0), result.diagnostics.unknown_count);
    try testing.expectEqual(@as(u32, 1), result.diagnostics.inline_images);
}

test "an unknown operator is counted and named" {
    var result = try interpret("0 0 10 10 re f zz 5 qq", "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), result.diagnostics.unknown_operators);
    try testing.expectEqual(@as(u8, 2), result.diagnostics.unknown_count);
    try testing.expectEqualStrings("zz", result.diagnostics.unknownName(0));
    // And the page still drew.
    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
}

test "an over-long unknown operator is named by its prefix, not dropped" {
    // What a content stream that failed to decode looks like: a run of bytes
    // that lexes as one enormous keyword. Counting it without naming it
    // leaves a diagnostic that cannot be acted on.
    var result = try interpret("averyveryverylongtoken 0 0 10 10 re f", "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.diagnostics.unknown_operators);
    try testing.expectEqual(@as(u8, 1), result.diagnostics.unknown_count);
    try testing.expectEqualStrings("averyver", result.diagnostics.unknownName(0));
    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
}

test "marked content nests around the drawing it labels" {
    var result = try interpret("/Span BMC 0 0 10 10 re f EMC", "");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.list.cmds.len);
    try testing.expectEqualStrings("Span", result.list.stringOf(result.list.cmds[0].marked_begin));
    try testing.expectEqualStrings("marked_end", result.list.cmds[2].name());
}

test "a dash pattern reaches the stroke, and a solid one does not" {
    var dashed = try interpret("[3 2] 0 d 0 0 10 10 re S", "");
    defer dashed.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), dashed.list.cmds[0].stroke_path.stroke.dash.count);

    var solid = try interpret("[] 0 d 0 0 10 10 re S", "");
    defer solid.deinit(testing.allocator);
    try testing.expect(solid.list.cmds[0].stroke_path.stroke.dash.isEmpty());
}

test "constant alpha folds into the colour" {
    var result = try interpret(
        "/GS1 gs 0 0 10 10 re f",
        "/ExtGState << /GS1 << /ca 0.5 >> >>",
    );
    defer result.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result.list.cmds[0].fill_path.paint.solid.a, 1e-6);
}

test "an inline image carries its own samples" {
    var result = try interpret(
        "q 100 0 0 50 10 10 cm BI /W 2 /H 2 /BPC 8 /CS /G ID \x00\x40\x80\xff EI Q",
        "",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.diagnostics.inline_images);
    const img = result.list.cmds[0].image;
    try testing.expect(img.isInline());
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(usize, 4), result.list.bytesOf(img.data).len);
    // The CTM is the whole geometry: a unit square scaled to 100x50 at 10,10.
    try testing.expectApproxEqAbs(@as(f32, 100), img.transform.a, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), img.transform.e, 1e-4);
}

test "a truncated stream records what it managed to read" {
    var result = try interpret("0 0 10 10 re f 20 20 m 30", "");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.list.cmds.len);
}

test "the trace of a small page is stable text" {
    var result = try interpret(
        \\0.2 0.4 0.6 rg
        \\10 10 100 50 re f
        \\1 0 0 RG 2 w
        \\20 20 m 80 60 l S
    , "");
    defer result.deinit(testing.allocator);

    const text = try traceOf(result);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        \\fill nonzero rgb(0.200 0.400 0.600) 5v/4p [10.00 10.00 110.00 60.00]
        \\stroke w=2.00 cap=butt join=miter limit=10.0 rgb(1.000 0.000 0.000) 2v/2p [20.00 20.00 80.00 60.00]
        \\
    , text);
}

// -- resources: forms, patterns, shadings, spot colour, Type 3 --------------

const form_resources = "/XObject << /Fm 20 0 R >>";
const form_object =
    \\20 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 10 10]
    \\  /Matrix [2 0 0 2 5 5] /Length 0 >> stream
    \\0 0 10 10 re f
    \\endstream endobj
;

test "a form XObject draws through its own matrix, clipped to its bbox" {
    var result = try interpretWith("/Fm Do", form_resources, form_object, .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.diagnostics.forms_drawn);
    // clip_push for the bbox, the fill, clip_pop.
    try testing.expectEqual(@as(usize, 3), result.list.cmds.len);
    try testing.expectEqualStrings("clip_push", result.list.cmds[0].name());

    const bounds = result.list.pathBounds(result.list.cmds[1].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 5), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.width(), 1e-4);
}

test "the CTM at the Do composes with the form's own matrix" {
    var result = try interpretWith("3 0 0 3 0 0 cm /Fm Do", form_resources, form_object, .{});
    defer result.deinit(testing.allocator);

    const bounds = result.list.pathBounds(result.list.cmds[1].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 15), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 60), bounds.width(), 1e-4);
}

test "a form that leaves q unbalanced does not leak state into the page" {
    const leaky =
        \\20 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Length 0 >> stream
        \\q 9 0 0 9 0 0 cm 0 0 1 1 re f
        \\endstream endobj
    ;
    var result = try interpretWith("/Fm Do 0 0 10 10 re f", form_resources, leaky, .{});
    defer result.deinit(testing.allocator);

    // The rectangle drawn after the form is 10 units wide, not 90.
    const last_fill = result.list.cmds[result.list.cmds.len - 1].fill_path;
    try testing.expectApproxEqAbs(@as(f32, 10), result.list.pathBounds(last_fill.path).width(), 1e-4);
}

test "a form that draws itself is refused by object number" {
    const recursive =
        \\20 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 100 100]
        \\  /Resources << /XObject << /Fm 20 0 R >> >> /Length 0 >> stream
        \\0 0 5 5 re f /Fm Do
        \\endstream endobj
    ;
    var result = try interpretWith("/Fm Do", form_resources, recursive, .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.diagnostics.recursive_forms);
    // It drew once and then stopped, rather than recursing to the depth limit.
    try testing.expectEqual(@as(u32, 1), result.list.stats().fills);
}

test "a transparency group opens a layer with the alpha in force at the Do" {
    const grouped =
        \\20 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 100 100]
        \\  /Group << /S /Transparency /I true >> /Length 0 >> stream
        \\0 0 10 10 re f
        \\endstream endobj
    ;
    var result = try interpretWith(
        "/GS1 gs /Fm Do",
        form_resources ++ " /ExtGState << /GS1 << /ca 0.4 /BM /Multiply >> >>",
        grouped,
        .{},
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("clip_push", result.list.cmds[0].name());
    const layer = result.list.cmds[1].layer_push;
    try testing.expectApproxEqAbs(@as(f32, 0.4), layer.alpha, 1e-6);
    try testing.expectEqual(paint.BlendMode.multiply, layer.blend);
    try testing.expect(layer.isolated);

    // Inside the group the alpha is back to 1, or it would be applied twice.
    try testing.expectApproxEqAbs(@as(f32, 1), result.list.cmds[2].fill_path.paint.solid.a, 1e-6);
}

test "a separation colour runs its tint transform" {
    const spot =
        \\21 0 obj [/Separation /PANTONE#20185 /DeviceCMYK 22 0 R] endobj
        \\22 0 obj << /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0]
        \\  /C1 [0 1 1 0] /N 1 >> endobj
    ;
    var result = try interpretWith(
        "/Spot cs 1 scn 0 0 10 10 re f",
        "/ColorSpace << /Spot 21 0 R >>",
        spot,
        .{},
    );
    defer result.deinit(testing.allocator);

    // Full tint of a red ink: cmyk(0, 1, 1, 0).
    const c = result.list.cmds[0].fill_path.paint.solid;
    try testing.expectApproxEqAbs(@as(f32, 1), c.r, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), c.g, 1e-5);
}

test "selecting a separation space starts at full tint, not at zero" {
    const spot =
        \\21 0 obj [/Separation /Ink /DeviceGray 22 0 R] endobj
        \\22 0 obj << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >> endobj
    ;
    // No `scn` at all: §8.6.8 says the initial colour is 1 in every colorant.
    var result = try interpretWith(
        "/Spot cs 0 0 10 10 re f",
        "/ColorSpace << /Spot 21 0 R >>",
        spot,
        .{},
    );
    defer result.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 0), result.list.cmds[0].fill_path.paint.solid.r, 1e-5);
}

test "an indexed colour space looks its component up in the palette" {
    const palette =
        \\21 0 obj [/Indexed /DeviceRGB 2 <FF000000FF000000FF>] endobj
    ;
    var result = try interpretWith(
        "/Pal cs 2 sc 0 0 10 10 re f",
        "/ColorSpace << /Pal 21 0 R >>",
        palette,
        .{},
    );
    defer result.deinit(testing.allocator);

    const c = result.list.cmds[0].fill_path.paint.solid;
    try testing.expectApproxEqAbs(@as(f32, 0), c.r, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), c.b, 1e-5);
}

test "sh records a shading with a colour from the middle of its ramp" {
    const shading =
        \\21 0 obj << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0]
        \\  /Function 22 0 R >> endobj
        \\22 0 obj << /FunctionType 2 /Domain [0 1] /C0 [0 0 0]
        \\  /C1 [1 1 1] /N 1 >> endobj
    ;
    var result = try interpretWith("/Sh sh", "/Shading << /Sh 21 0 R >>", shading, .{});
    defer result.deinit(testing.allocator);

    const sh = result.list.cmds[0].shading;
    try testing.expectEqual(@as(u8, 2), sh.kind);
    // Halfway along a black-to-white ramp.
    try testing.expectApproxEqAbs(@as(f32, 0.5), sh.approximation.r, 1e-5);
}

test "a shading pattern is measured from the page, not from the current CTM" {
    const pattern =
        \\21 0 obj << /PatternType 2 /Matrix [1 0 0 1 7 7]
        \\  /Shading << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 1 0] >> >> endobj
    ;
    var result = try interpretWith(
        "q 5 0 0 5 100 100 cm /Pattern cs /P1 scn 0 0 10 10 re f Q",
        "/Pattern << /P1 21 0 R >>",
        pattern,
        .{},
    );
    defer result.deinit(testing.allocator);

    const p = result.list.cmds[0].fill_path.paint;
    // Pattern space ignores the `cm`: the offset is the pattern's own 7,7,
    // not 100,100. Getting this wrong slides every pattern with its shape.
    try testing.expectApproxEqAbs(@as(f32, 7), p.shading.transform.e, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), p.shading.transform.a, 1e-4);
}

test "a Type 3 glyph runs its own content stream" {
    const type3 =
        \\21 0 obj << /Type /Font /Subtype /Type3 /FontMatrix [0.01 0 0 0.01 0 0]
        \\  /FontBBox [0 0 100 100] /FirstChar 97 /LastChar 97 /Widths [100]
        \\  /Encoding << /Differences [97 /square] >>
        \\  /CharProcs << /square 22 0 R >> >> endobj
        \\22 0 obj << /Length 0 >> stream
        \\100 0 d0 0 0 100 100 re f
        \\endstream endobj
    ;
    var result = try interpretWith(
        "BT /T3 10 Tf 20 20 Td (aa) Tj ET",
        "/Font << /T3 21 0 R >>",
        type3,
        .{},
    );
    defer result.deinit(testing.allocator);

    // Two glyphs, each drawn by its procedure: no text run at all.
    try testing.expectEqual(@as(u32, 2), result.list.stats().fills);
    try testing.expectEqual(@as(u32, 0), result.list.stats().text_runs);

    // The glyph box is 100 units of a glyph space that is 1/100 of text
    // space, at 10pt: ten units square, and the second is one width along.
    const first = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    const second = result.list.pathBounds(result.list.cmds[1].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 20), first.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), first.width(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 30), second.min_x, 1e-4);
}

test "a Type 3 glyph that selects fonts of its own does not invalidate the outer one" {
    // A glyph procedure is a content stream, so it may contain `Tf`, and each
    // `Tf` interns a font into the same table the string being laid out is
    // reading from. Nine of them is enough to force that table to grow --
    // which, if the outer loop held a pointer into it rather than a copy,
    // reallocates the font out from under the *second* glyph of "aa".
    const many_fonts =
        \\21 0 obj << /Type /Font /Subtype /Type3 /FontMatrix [0.01 0 0 0.01 0 0]
        \\  /FirstChar 97 /LastChar 97 /Widths [100]
        \\  /Encoding << /Differences [97 /square] >>
        \\  /CharProcs << /square 22 0 R >> >> endobj
        \\22 0 obj << /Length 0 >> stream
        \\0 0 100 100 re f
        \\BT /Fa 1 Tf /Fb 1 Tf /Fc 1 Tf /Fd 1 Tf /Fe 1 Tf
        \\   /Ff 1 Tf /Fg 1 Tf /Fh 1 Tf /Fi 1 Tf ET
        \\endstream endobj
        \\30 0 obj << /Type /Font /Subtype /Type1 /BaseFont /A >> endobj
        \\31 0 obj << /Type /Font /Subtype /Type1 /BaseFont /B >> endobj
        \\32 0 obj << /Type /Font /Subtype /Type1 /BaseFont /C >> endobj
        \\33 0 obj << /Type /Font /Subtype /Type1 /BaseFont /D >> endobj
        \\34 0 obj << /Type /Font /Subtype /Type1 /BaseFont /E >> endobj
        \\35 0 obj << /Type /Font /Subtype /Type1 /BaseFont /F >> endobj
        \\36 0 obj << /Type /Font /Subtype /Type1 /BaseFont /G >> endobj
        \\37 0 obj << /Type /Font /Subtype /Type1 /BaseFont /H >> endobj
        \\38 0 obj << /Type /Font /Subtype /Type1 /BaseFont /I >> endobj
    ;
    const resources =
        "/Font << /T3 21 0 R /Fa 30 0 R /Fb 31 0 R /Fc 32 0 R /Fd 33 0 R" ++
        " /Fe 34 0 R /Ff 35 0 R /Fg 36 0 R /Fh 37 0 R /Fi 38 0 R >>";

    var result = try interpretWith(
        "BT /T3 10 Tf 20 20 Td (aa) Tj ET",
        resources,
        many_fonts,
        .{},
    );
    defer result.deinit(testing.allocator);

    // Both glyphs drew, and the second is one advance along -- which is only
    // true if its width came from the Type 3 font and not from freed memory.
    try testing.expectEqual(@as(u32, 2), result.list.stats().fills);
    const second = result.list.pathBounds(result.list.cmds[1].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 30), second.min_x, 1e-4);
}

test "Type 3 glyphs can be switched off without losing the advance" {
    const type3 =
        \\21 0 obj << /Type /Font /Subtype /Type3 /FontMatrix [0.01 0 0 0.01 0 0]
        \\  /FirstChar 97 /LastChar 97 /Widths [100]
        \\  /Encoding << /Differences [97 /square] >>
        \\  /CharProcs << /square 22 0 R >> >> endobj
        \\22 0 obj << /Length 0 >> stream
        \\0 0 100 100 re f
        \\endstream endobj
    ;
    var result = try interpretWith(
        "BT /T3 10 Tf (aa) Tj ET 0 0 1 1 re f",
        "/Font << /T3 21 0 R >>",
        type3,
        .{ .type3 = false },
    );
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), result.list.stats().fills);
}

// -- page geometry ----------------------------------------------------------

test "a page with no rotation and a crop box at the origin is untouched" {
    var result = try interpret("10 20 30 40 re f", "");
    defer result.deinit(testing.allocator);

    const bounds = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 10), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.min_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200), result.list.page.width(), 1e-4);
}

test "a rotated page turns clockwise and swaps its displayed axes" {
    // A tall page, quarter-turned: the display is 200 wide and 100 high, and
    // a rectangle in the bottom-left corner of the paper ends up in the
    // top-left of the screen -- which is where a clockwise turn puts it.
    const tall_rotated = "/MediaBox [0 0 100 200] /Rotate 90";
    var result = try interpretFully("0 0 10 20 re f", "", "", tall_rotated, .{});
    defer result.deinit(testing.allocator);

    try testing.expectApproxEqAbs(@as(f32, 200), result.list.page.width(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), result.list.page.height(), 1e-4);

    const bounds = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 0), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.max_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 90), bounds.min_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), bounds.max_y, 1e-4);
}

test "no-rotate leaves the file's own numbers alone" {
    const tall_rotated = "/MediaBox [0 0 100 200] /Rotate 90";
    var result = try interpretFully("0 0 10 20 re f", "", "", tall_rotated, .{ .rotate = false });
    defer result.deinit(testing.allocator);

    const bounds = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 0), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.max_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), result.list.page.width(), 1e-4);
}

// -- annotations ------------------------------------------------------------

/// The first `fill_path` in a list, so a test can assert on the artwork
/// without counting the clip an appearance stream's `/BBox` pushes around it.
fn onlyFill(list: DisplayList) DisplayList.DrawCmd {
    for (list.cmds) |c| {
        if (c == .fill_path) return c;
    }
    unreachable;
}

fn fillCount(list: DisplayList) usize {
    var n: usize = 0;
    for (list.cmds) |c| {
        if (c == .fill_path) n += 1;
    }
    return n;
}

/// A page carrying one annotation, and the objects behind it.
const square_annot =
    \\30 0 obj << /Type /Annot /Subtype /Square /Rect [100 100 180 140]
    \\  /AP << /N 31 0 R >> >> endobj
    \\31 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0 >> stream
    \\0 0 10 10 re f
    \\endstream endobj
;

test "an annotation's appearance is fitted to its rectangle" {
    // The BBox is ten units square and the rectangle is 80 by 40, so the
    // appearance is stretched by eight and by four -- unequally, which is
    // allowed and is what a resized sticky note does. Getting this wrong
    // draws the mark somewhere near the right place, which is the hardest
    // kind of wrong to notice.
    var result = try interpretFully("", "", square_annot, "/Annots [30 0 R]", .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.diagnostics.annotations_drawn);
    try testing.expectEqual(@as(usize, 1), fillCount(result.list));

    const bounds = result.list.pathBounds(onlyFill(result.list).fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 100), bounds.min_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 180), bounds.max_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 100), bounds.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 140), bounds.max_y, 1e-3);
}

test "the appearance's own matrix is applied before the fit, not after" {
    // Rotated a quarter turn, the ten-unit box still *bounds* ten by ten, so
    // it still fills the rectangle -- but the artwork inside it has turned.
    // A renderer that fits the BBox and then rotates puts the mark outside
    // the rectangle entirely.
    const rotated =
        \\30 0 obj << /Type /Annot /Subtype /Square /Rect [0 0 40 40]
        \\  /AP << /N 31 0 R >> >> endobj
        \\31 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 10 10]
        \\  /Matrix [0 1 -1 0 0 0] /Length 0 >> stream
        \\0 0 10 5 re f
        \\endstream endobj
    ;
    var result = try interpretFully("", "", rotated, "/Annots [30 0 R]", .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), fillCount(result.list));
    const bounds = result.list.pathBounds(onlyFill(result.list).fill_path.path);
    // The 10x5 strip lies along x before the turn and along y after it, so
    // after the fit it is the right-hand half of the 40-unit square: full
    // height, and starting halfway across.
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.min_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 40), bounds.max_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), bounds.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 40), bounds.max_y, 1e-3);
}

test "a hidden annotation is not drawn" {
    // Bit 2 of /F. The other flags a reader has to honour are bit 6, which
    // means print but do not display.
    const hidden =
        \\30 0 obj << /Type /Annot /Subtype /Square /Rect [100 100 180 140] /F 2
        \\  /AP << /N 31 0 R >> >> endobj
        \\31 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0 >> stream
        \\0 0 10 10 re f
        \\endstream endobj
    ;
    var result = try interpretFully("", "", hidden, "/Annots [30 0 R]", .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), fillCount(result.list));
    try testing.expectEqual(@as(u32, 1), result.diagnostics.annotations_skipped);
}

test "the appearance state chooses between the appearances" {
    // A checkbox: two appearances under /N, and /AS says which is current.
    const checkbox =
        \\30 0 obj << /Type /Annot /Subtype /Widget /Rect [0 0 10 10] /AS /On
        \\  /AP << /N << /Off 31 0 R /On 32 0 R >> >> >> endobj
        \\31 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0 >> stream
        \\endstream endobj
        \\32 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0 >> stream
        \\0 0 10 10 re f
        \\endstream endobj
    ;
    var result = try interpretFully("", "", checkbox, "/Annots [30 0 R]", .{});
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), fillCount(result.list));

    // With /AS pointing at the empty one, nothing is painted -- but the
    // annotation still counts as drawn, because it was.
    const off = try std.mem.replaceOwned(u8, testing.allocator, checkbox, "/AS /On", "/AS /Off");
    defer testing.allocator.free(off);
    var blank = try interpretFully("", "", off, "/Annots [30 0 R]", .{});
    defer blank.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fillCount(blank.list));
    try testing.expectEqual(@as(u32, 1), blank.diagnostics.annotations_drawn);
}

test "annotations can be turned off" {
    var result = try interpretFully("", "", square_annot, "/Annots [30 0 R]", .{ .annotations = false });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fillCount(result.list));
    try testing.expectEqual(@as(u32, 0), result.diagnostics.annotations_drawn);
}

test "an annotation with no appearance stream is skipped rather than guessed at" {
    // A /Link with a border and no /AP is the common case, and drawing a
    // rectangle for it would put a box around every cross-reference in a
    // paper that no other reader shows.
    const link =
        \\30 0 obj << /Type /Annot /Subtype /Link /Rect [0 0 10 10]
        \\  /Border [0 0 1] >> endobj
    ;
    var result = try interpretFully("", "", link, "/Annots [30 0 R]", .{});
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fillCount(result.list));
    try testing.expectEqual(@as(u32, 1), result.diagnostics.annotations_skipped);
}

test "a bare stream can be interpreted against a base transform of its own" {
    // The entry point an annotation's appearance stream will use: no page, a
    // caller-chosen box, and a caller-chosen matrix.
    const bytes = try testing.allocator.dupe(u8,
        \\%PDF-1.7
        \\1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        \\2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        \\trailer << /Root 1 0 R /Size 3 >>
        \\
    );
    var doc = try Document.open(testing.allocator, bytes);
    defer doc.deinit();

    var result = try stream(
        testing.allocator,
        &doc,
        "0 0 10 10 re f",
        .empty,
        .fromRect(0, 0, 50, 50),
        Matrix.translation(20, 30),
        .{},
    );
    defer result.deinit(testing.allocator);

    const bounds = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 30), bounds.min_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 50), result.list.page.width(), 1e-4);
}

test "a crop box off the origin moves to it" {
    // The whole point of the base transform: a page cropped to a window in
    // the middle of the sheet still starts at (0, 0) in the display list.
    const cropped = "/MediaBox [0 0 200 200] /CropBox [50 60 150 160]";
    var result = try interpretFully("50 60 10 10 re f", "", "", cropped, .{});
    defer result.deinit(testing.allocator);

    try testing.expectApproxEqAbs(@as(f32, 100), result.list.page.width(), 1e-4);
    const bounds = result.list.pathBounds(result.list.cmds[0].fill_path.path);
    try testing.expectApproxEqAbs(@as(f32, 0), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), bounds.min_y, 1e-4);
}

test "a rectangle under a rotated CTM stops being axis aligned" {
    // 30 degrees: the four corners are still four points, but no two of them
    // share an edge with the axes. This is why `re` is not `Builder.rect`.
    var result = try interpret("0.866 0.5 -0.5 0.866 0 0 cm 0 0 10 10 re f", "");
    defer result.deinit(testing.allocator);

    const points = result.list.pointsOf(result.list.cmds[0].fill_path.path);
    try testing.expectEqual(@as(usize, 4), points.len);
    try testing.expect(points[1].y != points[0].y);
    try testing.expect(points[3].x != points[0].x);
}
