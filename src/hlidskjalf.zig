//! **Hliðskjálf** — buffers, windows, and where each one is looking.
//!
//! Hliðskjálf is Odin's high seat, and the thing about it is not that it is a
//! throne: it is that from it he sees into every world at once. That is this
//! component. One seat, many views, and -- the part the myth gets right --
//! what is seen is the world itself and not a copy of it, so a change in one
//! is not news that has to be carried to the other.
//!
//! (It is also, of everything Odin ever did from that seat, the place he
//! watched a wolf growing up. Which seems fair.)
//!
//! ## The model
//!
//! Two things, and the whole design is which is which:
//!
//! * A **`Buffer`** is an open document: its pages, its highlights, its text.
//!   One per file, however many windows are open on it.
//! * A **`View`** is one window onto a buffer: a scroll, a zoom, a cursor.
//!   Many per buffer.
//!
//! So a highlight drawn in one split appears in the other because there was
//! never a second copy to update -- both windows were already reading the
//! buffer's one list. A `revision` counter on `Marks` is the entire
//! notification mechanism, and it is a `u64` compare per window per frame.
//!
//! `Layout` arranges the views as Vim arranges windows: a tree of rows and
//! columns, split and closed with `<C-w>`, with the space a closed window
//! leaves going back to the one it was taken from.
//!
//! Nothing here opens a file, draws anything, or talks to a device. It is the
//! model `vanagandr/read.zig` drives, which is what lets every rule in it --
//! where a split goes, what the cursor does at the end of a page, which
//! window `<C-w>l` means -- be a test rather than something to check by
//! opening a window and looking.

const std = @import("std");

pub const Buffer = @import("hlidskjalf/Buffer.zig");
pub const Layout = @import("hlidskjalf/Layout.zig");
pub const Marks = @import("hlidskjalf/Marks.zig");
pub const Tabs = @import("hlidskjalf/Tabs.zig");
pub const View = @import("hlidskjalf/View.zig");
pub const commands = @import("hlidskjalf/commands.zig");
pub const diff = @import("hlidskjalf/diff.zig");
pub const keys = @import("hlidskjalf/keys.zig");
pub const search = @import("hlidskjalf/search.zig");
pub const text = @import("hlidskjalf/text.zig");

pub const Mark = Marks.Mark;
pub const Place = View.Place;

test {
    _ = Buffer;
    _ = Layout;
    _ = Marks;
    _ = Tabs;
    _ = View;
    _ = commands;
    _ = diff;
    _ = keys;
    _ = search;
    _ = text;
}
