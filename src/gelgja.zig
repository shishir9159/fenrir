//! Gelgja -- the display list.
//!
//! In the myth Gelgja is the cord threaded through the boulder Gjöll and
//! hammered down with the stone Þviti: the piece between the binding and the
//! anchor. That is what this layer is. Gjöll's interpreter produces a display
//! list; Gleipnir's rasteriser consumes one; and this module knows about
//! neither. There is no import of the PDF layer here and none of any graphics
//! API, so a display list can be built, inspected, diffed, and replayed with
//! no document and no GPU in the process.
//!
//! That independence is the point rather than a nicety. It is what lets the
//! trace backend exist before the rasteriser does, and what will let the
//! rasteriser be tested without a parser.

const std = @import("std");

pub const Builder = @import("gelgja/Builder.zig");
pub const DisplayList = @import("gelgja/DisplayList.zig");
pub const geom = @import("gelgja/geom.zig");
pub const paint = @import("gelgja/paint.zig");
pub const trace = @import("gelgja/trace.zig");

pub const Bounds = geom.Bounds;
pub const FillRule = geom.FillRule;
pub const Point = geom.Point;
pub const Range = geom.Range;
pub const Transform = geom.Transform;
pub const Verb = geom.Verb;

pub const BlendMode = paint.BlendMode;
pub const Cap = paint.Cap;
pub const Color = paint.Color;
pub const Join = paint.Join;
pub const Layer = paint.Layer;
pub const ObjectId = paint.ObjectId;
pub const Paint = paint.Paint;
pub const Stroke = paint.Stroke;
pub const TextRenderMode = paint.TextRenderMode;

pub const DrawCmd = DisplayList.DrawCmd;
pub const FontId = DisplayList.FontId;
pub const FontInfo = DisplayList.FontInfo;
pub const Glyph = DisplayList.Glyph;
pub const Image = DisplayList.Image;
pub const Path = DisplayList.Path;
pub const TextRun = DisplayList.TextRun;

test {
    _ = Builder;
    _ = DisplayList;
    _ = geom;
    _ = paint;
    _ = trace;
}
