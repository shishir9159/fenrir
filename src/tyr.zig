//! Týr -- the font layer.
//!
//! Týr is the god who put his hand in the wolf's mouth as surety while the
//! others tied him, and lost it when the binding held. He is the one part of
//! the story that pays a price, which is the right name for the layer that
//! deals with fonts: everything else in a PDF is specified, and fonts are
//! where the specification runs out and thirty years of accumulated practice
//! begins.
//!
//! Two interfaces, on two different axes, and conflating them is the mistake
//! this layer is arranged to prevent:
//!
//!   `Face`   -- glyph index in, outline out. FreeType, stb_truetype, or one
//!               of Týr's own parsers. Used by everything that draws.
//!   `Shaper` -- Unicode string in, positioned glyphs out. HarfBuzz, or the
//!               built-in one. Used only by the UI, never by a PDF page.
//!
//! Both dispatch through a vtable at runtime; `registry.zig` is the only file
//! that knows which implementations were compiled in. See its header for why
//! the dispatch is not `comptime`.
//!
//! What Týr's core owns, and no backend ever sees: character codes. A PDF maps
//! a code to a glyph through `/Encoding`, a `/Differences` array, a CMap, or
//! `/CIDToGIDMap`, and that machinery is the same whichever backend renders
//! the result. Backends are handed glyph indices and glyph names only, so two
//! of them can be diffed against each other without their disagreements being
//! confused with an encoding bug.

const std = @import("std");

pub const Face = @import("tyr/Face.zig");
pub const Outline = @import("tyr/Outline.zig");
pub const Shaper = @import("tyr/Shaper.zig");
pub const format = @import("tyr/format.zig");
pub const registry = @import("tyr/registry.zig");

pub const Backend = Face.Backend;
pub const Bitmap = Face.Bitmap;
pub const Capabilities = Face.Capabilities;
pub const Format = format.Format;
pub const GlyphIndex = Face.GlyphIndex;
pub const notdef = Face.notdef;

/// Opens a font program with the best backend this build has for it.
pub const open = registry.open;
/// The shaper for text Fenrir composes itself.
pub const shaper = registry.shaper;
/// Whether this build has any real glyph source, or only the box-drawing
/// stand-in. Worth saying once at startup rather than leaving a user to
/// wonder why a page of text came out as rectangles.
pub const glyphs_are_real = registry.glyphs_are_real;

test {
    _ = Face;
    _ = Outline;
    _ = Shaper;
    _ = format;
    _ = registry;
    _ = @import("tyr/backend/fallback.zig");
}
