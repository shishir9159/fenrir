//! The content-stream interpreter: the piece that turns a page into drawing.
//!
//! Everything below this point in Gjöll answers "what does the file say?".
//! This module answers "what should be on the screen?", and it is the first
//! place where those two stop being the same question. `re` is four numbers
//! in the file and a transformed quadrilateral on the page; `/F1 12 Tf` is a
//! name in the file and a font program somewhere else entirely.
//!
//! ## Where it sits
//!
//!     Document ---> content ---> Gelgja's Builder ---> DisplayList
//!
//! It is the only part of the PDF layer that imports Gelgja, and it imports
//! nothing from Gleipnir, Týr, or Lyngvi. That edge is what lets the whole
//! interpreter be tested against text: write a PDF in a string literal, run
//! it, and assert on the display list. Every test in `Interpreter.zig` does
//! exactly that, and none of them needs a font program, a window, or a GPU --
//! only a `Document`, which is itself just bytes.
//!
//! ## The pieces
//!
//! - `Scanner` turns bytes into operators and operands, inline images
//!   included, and knows nothing about what any of them mean.
//! - `matrix` is the interpreter's `f64` matrix, narrowed to Gelgja's `f32`
//!   once per recorded command.
//! - `function` evaluates PDF functions, which colour needs and shadings need.
//! - `color` resolves a colour space and a list of components to one RGBA.
//! - `Font` reads the widths out of a font dictionary, because an interpreter
//!   that cannot advance the text cursor draws every glyph of a page on top of
//!   the first one.
//! - `Interpreter` is the operator table and the graphics state.

const std = @import("std");

pub const Font = @import("content/Font.zig");
pub const Interpreter = @import("content/Interpreter.zig");
pub const Scanner = @import("content/Scanner.zig");
pub const color = @import("content/color.zig");
pub const function = @import("content/function.zig");
pub const matrix = @import("content/matrix.zig");

pub const ColorSpace = color.ColorSpace;
pub const Function = function.Function;
pub const Matrix = matrix.Matrix;
pub const Op = Scanner.Op;
pub const Options = Interpreter.Options;
pub const Result = Interpreter.Result;
pub const State = Interpreter.State;

/// Interprets one page into a display list. The caller owns the result and
/// frees it with `Result.deinit`.
pub const page = Interpreter.page;

/// Interprets a bare content stream against a resource dictionary, for a
/// stream that is a page's peer rather than its child: an annotation's
/// appearance, or a tiling pattern's cell. Form XObjects and Type 3 glyphs
/// recurse inside the interpreter instead, so that they inherit its state.
pub const stream = Interpreter.stream;

test {
    _ = Font;
    _ = Interpreter;
    _ = Scanner;
    _ = color;
    _ = function;
    _ = matrix;
}
