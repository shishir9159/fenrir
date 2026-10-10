//! fenrir -- a PDF reader written from scratch in Zig.
//!
//! This module is the whole public surface of the library. It deals only in
//! byte slices and allocators: opening files, writing to terminals, and
//! anything else with a policy attached belongs to the CLI (or, later, to the
//! Vulkan front end).
//!
//! Layering, strictly one-way:
//!
//!     Lexer  ->  Parser  ->  xref  ->  Document  ->  pages, print
//!                  filter  ->  Document                Page  ->  content
//!
//! Nothing below `Document` knows that documents exist, which is what lets the
//! same lexer read the file body, the inside of an object stream, and a
//! content stream. Nothing at or below `Document` knows what a page is, and
//! only `content` -- the top of the layer, and the only part that reaches
//! across into Gelgja -- knows what drawing is.

const std = @import("std");

pub const Document = @import("gjoll/Document.zig");
pub const Lexer = @import("gjoll/Lexer.zig");
pub const Page = @import("gjoll/Page.zig");
pub const Parser = @import("gjoll/Parser.zig");
pub const content = @import("gjoll/content.zig");
pub const filter = @import("gjoll/filter.zig");
pub const image = @import("gjoll/image.zig");
pub const outline = @import("gjoll/outline.zig");
pub const pages = @import("gjoll/pages.zig");
pub const print = @import("gjoll/print.zig");
pub const xref = @import("gjoll/xref.zig");

/// Gelgja: the display list between the parser and the rasteriser. It imports
/// nothing from the layers above; `gjoll/content` is what fills it.
pub const gelgja = @import("gelgja.zig");

/// Gleipnir: the rasteriser. The rect pipeline and its CPU reference are
/// written; the path pipeline and the Vulkan backend are not.
pub const gleipnir = @import("gleipnir.zig");

/// Mímir: what the reader remembers between sessions -- recent files, where
/// you were in each, and the settings that are yours. The only component that
/// links a library, and `-Dsqlite=false` compiles it down to a store that
/// remembers nothing.
pub const mimir = @import("mimir.zig");

/// Lyngvi: the platform -- the window, its input, and the Vulkan device that
/// draws into it. The only layer that talks to the operating system, and the
/// only one that can fail for reasons that have nothing to do with the file
/// being read.
pub const lyngvi = @import("lyngvi.zig");

/// Þviti: the user interface -- the box tree, the layout solver, and the
/// signals. Above every other layer and the only one that imports across
/// them.
pub const thviti = @import("thviti.zig");

/// Hliðskjálf: buffers and the windows onto them. One open document, many
/// views of it, and the split tree that says where each view is -- so that a
/// highlight drawn in one window is in the other because they share the
/// document, not because anything copied it across.
pub const hlidskjalf = @import("hlidskjalf.zig");

/// Galdr: plugins, in a sandboxed Lua. `init.lua`, a `plugins/` directory, and
/// a `fenrir` table in the place Neovim has `vim`.
pub const galdr = @import("galdr.zig");

/// Týr: the font layer. Two runtime interfaces, `Face` for glyph outlines
/// and `Shaper` for UI text, with the choice of backend made in one place.
pub const tyr = @import("tyr.zig");

/// What this binary was built with: which glyph backends are linked, whether
/// there is SPIR-V in it, and which path rasterisers are compiled in. Exposed
/// so a command can say so rather than guess.
pub const build_options = @import("build_options");

pub const Rect = Page.Rect;
pub const Rotation = Page.Rotation;

const object = @import("gjoll/object.zig");

pub const Array = object.Array;
pub const Dict = object.Dict;
pub const Name = object.Name;
pub const Object = object.Object;
pub const Ref = object.Ref;
pub const Stream = object.Stream;
pub const String = object.String;

/// Opens a document from bytes the caller has already read. Ownership of
/// `bytes` transfers to the returned `Document`.
pub fn open(gpa: std.mem.Allocator, bytes: []const u8) Document.Error!Document {
    return Document.open(gpa, bytes);
}

/// Opens a second view of bytes that somebody else owns and will outlive the
/// document. See `Document.openBorrowed`: this is how one file is read on
/// more than one thread.
pub fn openBorrowed(gpa: std.mem.Allocator, bytes: []const u8) Document.Error!Document {
    return Document.openBorrowed(gpa, bytes);
}

test {
    // A file's tests run only if the file is referenced from the test root,
    // so name every one of them explicitly rather than relying on the public
    // re-exports above.
    _ = Document;
    _ = gelgja;
    _ = gleipnir;
    _ = mimir;
    _ = lyngvi;
    _ = thviti;
    _ = hlidskjalf;
    _ = galdr;
    _ = tyr;
    _ = Lexer;
    _ = Page;
    _ = Parser;
    _ = content;
    _ = filter;
    _ = image;
    _ = outline;
    _ = pages;
    _ = print;
    _ = xref;
    _ = object;
    _ = @import("gjoll/filter/ascii.zig");
    _ = @import("gjoll/filter/lzw.zig");
    _ = @import("gjoll/filter/predictor.zig");
}
