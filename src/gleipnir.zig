//! Gleipnir -- the rasteriser.
//!
//! The dwarves made Gleipnir out of six things that do not exist: the sound of
//! a cat's footfall, a woman's beard, the roots of a mountain, a bear's
//! sinews, a fish's breath, a bird's spittle. It looked like a silk ribbon and
//! held what two iron chains could not. That is the pitch for this layer: a
//! few thousand lines of Zig against MuPDF's and PDFium's hundreds of
//! thousands, and the strength has to come from picking the right primitives
//! rather than from bulk.
//!
//! Two pipelines, and knowing which is which is most of the design:
//!
//!   **rects** -- axis-aligned rounded boxes with a texture, drawn from a
//!   signed distance field. Panels, borders, shadows, scrollbars, image tiles,
//!   glyph quads. One instance format, one shader, one draw call for a whole
//!   frame. This is what is written.
//!
//!   **paths** -- arbitrary filled and stroked outlines, stencil-then-cover.
//!   Everything on a PDF page that is not a rectangle, and every glyph drawn
//!   large enough that an atlas is the wrong answer. Not started.
//!
//! The split is not a rendering-quality decision, it is a batching one. A rect
//! needs no per-shape state, so ten thousand of them are one draw call; a path
//! needs a stencil pass, so each one is at least two. Anything that can be
//! expressed as a rect must be, or the frame rate is decided by the UI chrome
//! rather than by the document.
//!
//! What is here does not touch a GPU. `DrawList` produces an instance buffer
//! and `software` consumes one on the CPU, so the whole layer can be built and
//! tested with no device, no window, and no driver -- which is the same
//! arrangement that let Gelgja's trace backend exist before this did.

const std = @import("std");

pub const DrawList = @import("gleipnir/DrawList.zig");
pub const pathpipe = @import("gleipnir/pathpipe.zig");
pub const pipeline = @import("gleipnir/pipeline.zig");
pub const path = @import("gleipnir/path.zig");
pub const png = @import("gleipnir/png.zig");
pub const raster = @import("gleipnir/raster.zig");
pub const replay = @import("gleipnir/replay.zig");
pub const rect = @import("gleipnir/rect.zig");
pub const sdf = @import("gleipnir/sdf.zig");
pub const software = @import("gleipnir/software.zig");
pub const stroke = @import("gleipnir/stroke.zig");

pub const Batch = DrawList.Batch;
pub const Framebuffer = software.Framebuffer;
pub const Instance = rect.Instance;
pub const Radius = sdf.Radius;
pub const Style = DrawList.Style;
pub const TextureId = rect.TextureId;
pub const Xform = DrawList.Xform;

test {
    _ = DrawList;
    _ = pathpipe;
    _ = pipeline;
    _ = path;
    _ = png;
    _ = raster;
    _ = replay;
    _ = rect;
    _ = sdf;
    _ = software;
    _ = stroke;
}
