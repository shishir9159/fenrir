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
//!                  filter  ->  Document
//!
//! Nothing below `Document` knows that documents exist, which is what lets the
//! same parser read the file body, the inside of an object stream, and (later)
//! a content stream. Nothing at or below `Document` knows what a page is.

const std = @import("std");

pub const Document = @import("pdf/Document.zig");
pub const Lexer = @import("pdf/Lexer.zig");
pub const Page = @import("pdf/Page.zig");
pub const Parser = @import("pdf/Parser.zig");
pub const filter = @import("pdf/filter.zig");
pub const pages = @import("pdf/pages.zig");
pub const print = @import("pdf/print.zig");
pub const xref = @import("pdf/xref.zig");

/// Gelgja: the display list between the parser and the rasteriser. It imports
/// nothing from the layers above, and nothing above imports it yet -- the
/// interpreter that will fill it is milestone 4.
pub const gelgja = @import("gelgja.zig");

pub const Rect = Page.Rect;
pub const Rotation = Page.Rotation;

const object = @import("pdf/object.zig");

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

test {
    // A file's tests run only if the file is referenced from the test root,
    // so name every one of them explicitly rather than relying on the public
    // re-exports above.
    _ = Document;
    _ = gelgja;
    _ = Lexer;
    _ = Page;
    _ = Parser;
    _ = filter;
    _ = pages;
    _ = print;
    _ = xref;
    _ = object;
    _ = @import("pdf/filter/ascii.zig");
    _ = @import("pdf/filter/lzw.zig");
    _ = @import("pdf/filter/predictor.zig");
}
