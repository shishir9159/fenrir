//! Þviti -- the user interface.
//!
//! When the gods had passed Gelgja through the rock Gjöll and set it deep in
//! the earth, they took a great stone called Þviti and drove it deeper still,
//! as the peg the whole binding is anchored on. It is the piece of the story
//! that does nothing dramatic and holds everything in place, which is the
//! right name for the layer whose entire contribution is that state stays put
//! between frames.
//!
//! That is not a joke about the myth. The one idea this layer has is that a
//! box exists across frames while the call site that draws it does not: the
//! caller writes `if (ui.button("Open").clicked)` in the middle of an `if`,
//! and the hover animation, the scroll offset, the keyboard focus and last
//! frame's rectangle are all still there, found by a hash of the string and
//! the parent's key. Everything else here -- the five-pass solver, the style
//! stacks, the signals -- follows from having somewhere to put that state.
//!
//! ## Layering
//!
//! Þviti is the top of the stack and the only layer that imports across:
//!
//!     Týr (fonts) ----\
//!                       Þviti ----> Gleipnir (pixels)
//!     Gelgja (geometry)/
//!
//! `UI` itself imports neither. It reaches text through a `Metrics` vtable and
//! produces nothing but a tree; `text.zig` binds that vtable to Týr and
//! `draw.zig` turns the tree into a `DrawList`. So the layout solver -- the
//! part with the most arithmetic and the least I/O -- is testable with no
//! fonts, no atlas, and no renderer, which is how most of it was written.
//!
//! ## What is here and what is not
//!
//! Here: box identity, the tree, semantic sizing and its solver, the style and
//! parent stacks, mouse and keyboard signals, focus, scrolling, animation, and
//! enough widgets to prove the core works.
//!
//! Not here: a real widget set. Text fields with selection, menus, tab bars,
//! drag-and-drop and the rest are a layer written *on* this one, and writing
//! them before there was a window to put them in would have been building
//! against an interface nobody had used. Lyngvi provides that window now.

const std = @import("std");

pub const Box = @import("thviti/Box.zig");
pub const Icons = @import("thviti/Icons.zig");
pub const Theme = @import("thviti/Theme.zig");
pub const UI = @import("thviti/UI.zig");
pub const draw = @import("thviti/draw.zig");
pub const input = @import("thviti/input.zig");
pub const key = @import("thviti/key.zig");
pub const text = @import("thviti/text.zig");
pub const widgets = @import("thviti/widgets.zig");

pub const Align = Box.Align;
pub const Axis = Box.Axis;
pub const Event = input.Event;
pub const Flags = Box.Flags;
pub const Input = input.Input;
pub const Key = key.Key;
pub const Metrics = UI.Metrics;
pub const Next = Box.Next;
pub const Signal = UI.Signal;
pub const Size = Box.Size;
pub const Style = Box.Style;
pub const StylePatch = Box.StylePatch;

test {
    _ = Box;
    _ = Icons;
    _ = Theme;
    _ = UI;
    _ = draw;
    _ = input;
    _ = key;
    _ = text;
    _ = widgets;
}
