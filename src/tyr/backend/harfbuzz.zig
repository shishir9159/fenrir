//! HarfBuzz, behind `Shaper.VTable`. Built only with `-Dharfbuzz`.
//!
//! NOT COMPILED BY DEFAULT, AND NOT COMPILED ON THE MACHINE THIS WAS WRITTEN
//! ON -- HarfBuzz is not installed here. Same caveat as the other two C
//! bindings.
//!
//! Note where this file sits: `backend/`, but implementing `Shaper`, not
//! `Face`. HarfBuzz cannot produce an outline and is never asked for one. It
//! is reached only when Fenrir composes text of its own -- a menu, a search
//! box, a page label -- and never for a PDF page, whose glyphs and positions
//! the producer fixed long ago.
//!
//! HarfBuzz builds its own face from the font bytes rather than calling back
//! into ours. That duplicates the SFNT parse, and the alternative -- an
//! `hb_font_funcs_t` bridged onto `Face` -- would route every metric query
//! through a Zig function pointer during shaping, for a UI whose longest run
//! is a menu item. The duplicated parse happens once per font.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Face = @import("../Face.zig");
const Shaper = @import("../Shaper.zig");

// Translated by the build rather than by `@cImport`, which 0.17 removed. See
// `harfbuzz.h` beside this file, and `cHeader` in build.zig.
const c = @import("harfbuzz_c");

pub const name = "harfbuzz";

pub fn create(gpa: Allocator) Shaper.Error!Shaper {
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);

    const buf = c.hb_buffer_create() orelse return error.ShaperFailed;
    state.* = .{ .buf = buf };

    return .{ .ptr = state, .vtable = &vtable, .name = name };
}

/// One cached font, not a map. UI text draws run after run in the same face,
/// so a single slot hits almost always, and a miss costs one SFNT parse.
const State = struct {
    buf: *c.hb_buffer_t,
    cached: ?[*]const u8 = null,
    blob: ?*c.hb_blob_t = null,
    hb_face: ?*c.hb_face_t = null,
    font: ?*c.hb_font_t = null,
};

const vtable: Shaper.VTable = .{
    .shape = shape,
    .deinit = deinit,
};

fn fontFor(state: *State, face: Face) ?*c.hb_font_t {
    if (face.data.len == 0) return null;
    if (state.cached) |p| {
        if (p == face.data.ptr) return state.font;
    }
    releaseFont(state);

    const blob = c.hb_blob_create(
        @ptrCast(face.data.ptr),
        @intCast(face.data.len),
        c.HB_MEMORY_MODE_READONLY,
        null,
        null,
    ) orelse return null;
    const hb_face = c.hb_face_create(blob, 0) orelse {
        c.hb_blob_destroy(blob);
        return null;
    };
    const font = c.hb_font_create(hb_face) orelse {
        c.hb_face_destroy(hb_face);
        c.hb_blob_destroy(blob);
        return null;
    };

    // Scale in em units, so advances and offsets come back in font units and
    // match `Face.advance` and `Outline` without a second convention.
    const upem: c_int = face.info.units_per_em;
    c.hb_font_set_scale(font, upem, upem);

    state.* = .{
        .buf = state.buf,
        .cached = face.data.ptr,
        .blob = blob,
        .hb_face = hb_face,
        .font = font,
    };
    return font;
}

fn releaseFont(state: *State) void {
    if (state.font) |f| c.hb_font_destroy(f);
    if (state.hb_face) |f| c.hb_face_destroy(f);
    if (state.blob) |b| c.hb_blob_destroy(b);
    state.font = null;
    state.hb_face = null;
    state.blob = null;
    state.cached = null;
}

fn shape(
    ptr: *anyopaque,
    gpa: Allocator,
    face: Face,
    req: Shaper.Request,
    out: *std.ArrayList(Shaper.Positioned),
) Shaper.Error!void {
    const state: *State = @ptrCast(@alignCast(ptr));

    // No usable font bytes -- a standard-14 font that was never embedded, or
    // the box-drawing fallback. Shaping cannot help, so hand the run to the
    // built-in shaper rather than dropping it.
    const font = fontFor(state, face) orelse
        return Shaper.simple.shape(gpa, face, req, out);

    c.hb_buffer_reset(state.buf);
    c.hb_buffer_add_utf8(state.buf, req.text.ptr, @intCast(req.text.len), 0, @intCast(req.text.len));
    c.hb_buffer_set_direction(state.buf, switch (req.direction) {
        .ltr => c.HB_DIRECTION_LTR,
        .rtl => c.HB_DIRECTION_RTL,
        .ttb => c.HB_DIRECTION_TTB,
    });
    if (req.script.len > 0) {
        c.hb_buffer_set_script(state.buf, c.hb_script_from_string(req.script.ptr, @intCast(req.script.len)));
    }
    if (req.language.len > 0) {
        c.hb_buffer_set_language(state.buf, c.hb_language_from_string(req.language.ptr, @intCast(req.language.len)));
    }
    // Fills in whatever of direction, script and language was left unset.
    c.hb_buffer_guess_segment_properties(state.buf);

    c.hb_shape(font, state.buf, null, 0);

    var n: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(state.buf, &n);
    const pos = c.hb_buffer_get_glyph_positions(state.buf, &n);
    if (infos == null or pos == null) return;

    try out.ensureUnusedCapacity(gpa, n);
    for (infos[0..n], pos[0..n]) |info, p| {
        out.appendAssumeCapacity(.{
            // After shaping this field holds a glyph index, not a code point,
            // whatever its name says.
            .glyph = @truncate(info.codepoint),
            .cluster = info.cluster,
            .x_advance = @floatFromInt(p.x_advance),
            .y_advance = @floatFromInt(p.y_advance),
            .x_offset = @floatFromInt(p.x_offset),
            .y_offset = @floatFromInt(p.y_offset),
        });
    }
}

fn deinit(ptr: *anyopaque, gpa: Allocator) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    releaseFont(state);
    c.hb_buffer_destroy(state.buf);
    gpa.destroy(state);
}
